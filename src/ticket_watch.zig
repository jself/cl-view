//! `cl ticket watch`: one line each time a ticket's flags or stage change,
//! until killed. It reads the board every two seconds and compares it with
//! the last read, so it sees changes made by anything (the CLI, the web
//! board, the dispatcher), logged or not.
//!
//! Lines are `<key> <project> <change> <what> <title>`:
//!
//!   CL-37 cl-wrapper set question Add cl ticket watch
//!   CL-37 cl-wrapper cleared question Add cl ticket watch
//!   CL-37 cl-wrapper moved running->review Add cl ticket watch
//!   CL-90 cl-wrapper new backlog Fix the login page
//!   CL-37 cl-wrapper needs question,review Add cl ticket watch
//!   CL-37 cl-wrapper left question,review Add cl ticket watch
//!
//! `needs` and `left` follow the board's Needs You: `needs` when a ticket
//! lands there (or, while there, raises something new), with the flags it
//! asks about; `left` when it goes (answered, hidden, dismissed, parked, or
//! Claude started working on it), with the flags it had.
//!
//! The title is the rest of the line. Options narrow what is printed (see
//! Filter): keys, --project, --change, --flag and --stage. Tickets of hidden projects, and
//! tickets whose session is hidden (`cl hide`), stay quiet, as `cl watch`
//! does for hidden sessions. Unhiding them doesn't replay what changed
//! meanwhile; a `needs` line comes for each one now waiting in Needs You.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const board = @import("board.zig");
const autoreview = @import("autoreview.zig");

/// A ticket as the watch sees it: its stage and active flags.
pub const Seen = struct {
    id: i64,
    key: []const u8,
    project: []const u8,
    title: []const u8,
    stage: board.Stage,
    /// Its project is hidden, or its session is.
    hidden: bool,
    /// Its project is hidden (Needs You leaves it out).
    project_hidden: bool = false,
    parked: bool = false,
    /// Claude is working on it now (Needs You leaves it out until it stops).
    working: bool = false,
    flags: []const SeenFlag,

    /// In Needs You, as the board decides it: a flag the human hasn't hidden
    /// that still asks something, not parked, Claude not working on it, and
    /// not in a hidden project.
    pub fn inNeeds(self: Seen) bool {
        if (self.parked or self.working or self.project_hidden) return false;
        for (self.flags) |f| if (self.asks(f)) return true;
        return false;
    }

    /// A flag that puts it in Needs You. On a Done ticket only work that
    /// didn't land or a failed after-merge run still asks (board.asksWhenDone).
    fn asks(self: Seen, f: SeenFlag) bool {
        return !f.hidden and (self.stage != .done or board.asksWhenDone(f.kind));
    }

    /// The kinds of the flags that put it in Needs You, comma-separated.
    fn needsKinds(self: Seen, a: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.flags) |f| if (self.asks(f)) {
            if (out.items.len > 0) try out.append(a, ',');
            try out.appendSlice(a, f.kind);
        };
        return out.toOwnedSlice(a);
    }

    /// Asks about something it didn't in `was`: a flag that wasn't there, or
    /// was hidden (a hidden flag comes back when it asks something new).
    fn asksMoreThan(self: Seen, was: Seen) bool {
        for (self.flags) |f| if (self.asks(f)) {
            for (was.flags) |g| {
                if (g.id == f.id and was.asks(g)) break;
            } else return true;
        };
        return false;
    }
};

/// The tmux sessions that matter to the watch: hidden ones (their tickets
/// stay quiet) and busy ones (their tickets are out of Needs You).
pub const Sessions = struct {
    hidden: []const []const u8 = &.{},
    busy: []const []const u8 = &.{},
};

pub const SeenFlag = struct {
    /// The flag's row: cleared and set again is a new row, so it shows up
    /// even when both happen between two reads.
    id: i64,
    kind: []const u8,
    detail: []const u8,
    /// Hidden from Needs You (its Hide).
    hidden: bool = false,
};

pub const Kind = enum { set, cleared, moved, new, needs, left };

pub const Change = struct {
    key: []const u8,
    project: []const u8,
    change: Kind,
    /// The flag's kind (set, cleared), or the kinds it asks about,
    /// comma-separated (needs, left), else null.
    flag: ?[]const u8 = null,
    /// What the flag says (set): the question, the prompt, why it ended.
    detail: ?[]const u8 = null,
    /// The stage it left (moved), else null.
    from: ?[]const u8 = null,
    /// The stage it is in now (moved, new), else null.
    to: ?[]const u8 = null,
    title: []const u8,

    /// `<key> <project> <change> <what> <title>`, no newline.
    pub fn format(self: Change, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {s} {s} ", .{ self.key, self.project, @tagName(self.change) });
        switch (self.change) {
            .set, .cleared, .needs, .left => try w.writeAll(self.flag.?),
            .moved => try w.print("{s}->{s}", .{ self.from.?, self.to.? }),
            .new => try w.writeAll(self.to.?),
        }
        try w.writeByte(' ');
        // One line, whatever the title holds.
        for (self.title) |ch| try w.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
    }
};

/// Every ticket on the board with its active flags.
pub fn snapshot(db: board.Db, a: std.mem.Allocator, sessions: Sessions) ![]Seen {
    var st = try db.query(
        \\SELECT t.id, t.key, t.project, t.title, t.stage, t.tmux,
        \\  EXISTS (SELECT 1 FROM projects p WHERE p.name = t.project AND p.hidden != 0),
        \\  f.id, f.kind, f.detail, f.hidden,
        \\  EXISTS (SELECT 1 FROM parks k WHERE k.ticket = t.id),
        \\  instr(t.autoreview, ?1) > 0
        \\FROM tickets t LEFT JOIN flags f ON f.ticket = t.id AND f.cleared IS NULL
        \\ORDER BY t.id, f.id
    , .{board.reviewing_json});
    defer st.finalize();
    var out: std.ArrayList(Seen) = .empty;
    var flags: std.ArrayList(SeenFlag) = .empty;
    while (try st.step()) {
        const id = st.int(0);
        if (out.items.len == 0 or out.items[out.items.len - 1].id != id) {
            if (out.items.len > 0) out.items[out.items.len - 1].flags = try flags.toOwnedSlice(a);
            const session = st.text(5);
            const project_hidden = st.int(6) != 0;
            // Its session is busy on it, or an automated review of it runs.
            const working = st.int(12) != 0 or (session.len > 0 and anyEql(sessions.busy, session, false) and
                (try board.sessionTicket(db, session)) == id);
            try out.append(a, .{
                .id = id,
                .key = try st.dupe(a, 1),
                .project = try st.dupe(a, 2),
                .title = try st.dupe(a, 3),
                .stage = board.Stage.parse(st.text(4)) orelse .backlog,
                .hidden = project_hidden or (session.len > 0 and anyEql(sessions.hidden, session, false)),
                .project_hidden = project_hidden,
                .parked = st.int(11) != 0,
                .working = working,
                .flags = &.{},
            });
        }
        if (!st.isNull(7)) try flags.append(a, .{ .id = st.int(7), .kind = try st.dupe(a, 8), .detail = try st.dupe(a, 9), .hidden = st.int(10) != 0 });
    }
    if (out.items.len > 0) out.items[out.items.len - 1].flags = try flags.toOwnedSlice(a);
    return out.toOwnedSlice(a);
}

/// What changed from `old` to `new` (both from `snapshot`), in ticket order:
/// a ticket's stage move comes before its flags, cleared flags before set
/// ones, and Needs You last. Hidden tickets (in `new`) are left out; removed
/// tickets too.
pub fn diff(a: std.mem.Allocator, old: []const Seen, new: []const Seen) ![]Change {
    var before: std.AutoHashMapUnmanaged(i64, Seen) = .empty;
    for (old) |t| try before.put(a, t.id, t);
    var out: std.ArrayList(Change) = .empty;
    for (new) |t| {
        if (t.hidden) continue;
        const base: Change = .{ .key = t.key, .project = t.project, .title = t.title, .change = .new };
        const was = before.get(t.id) orelse {
            try out.append(a, withFields(base, .{ .change = .new, .to = @tagName(t.stage) }));
            for (t.flags) |f| try out.append(a, withFields(base, .{ .change = .set, .flag = f.kind, .detail = f.detail }));
            if (t.inNeeds()) try out.append(a, withFields(base, .{ .change = .needs, .flag = try t.needsKinds(a) }));
            continue;
        };
        if (was.stage != t.stage) try out.append(a, withFields(base, .{ .change = .moved, .from = @tagName(was.stage), .to = @tagName(t.stage) }));
        for (was.flags) |f| if (!hasFlag(t.flags, f.id)) try out.append(a, withFields(base, .{ .change = .cleared, .flag = f.kind }));
        for (t.flags) |f| if (!hasFlag(was.flags, f.id)) try out.append(a, withFields(base, .{ .change = .set, .flag = f.kind, .detail = f.detail }));
        const was_in = was.inNeeds();
        const now_in = t.inNeeds();
        if (now_in and (!was_in or t.asksMoreThan(was))) {
            try out.append(a, withFields(base, .{ .change = .needs, .flag = try t.needsKinds(a) }));
        } else if (was_in and !now_in) {
            try out.append(a, withFields(base, .{ .change = .left, .flag = try was.needsKinds(a) }));
        }
    }
    return out.toOwnedSlice(a);
}

const Fields = struct {
    change: Kind,
    flag: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
};

fn withFields(b: Change, f: Fields) Change {
    var c = b;
    c.change = f.change;
    c.flag = f.flag;
    c.detail = f.detail;
    c.from = f.from;
    c.to = f.to;
    return c;
}

fn hasFlag(flags: []const SeenFlag, id: i64) bool {
    for (flags) |f| if (f.id == id) return true;
    return false;
}

fn readSessions(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator) Sessions {
    // No tmux (a sandbox without a socket, no server): no sessions.
    if (ctx.tmux_blocked) return .{};
    const sessions = tmux.list(ctx, a) catch return .{};
    const statuses = claude.readStatuses(ctx, a, cfg) catch null;
    var hidden: std.ArrayList([]const u8) = .empty;
    var busy: std.ArrayList([]const u8) = .empty;
    for (sessions) |s| {
        if (s.hidden) hidden.append(a, s.tmux_name) catch {};
        if (statuses) |sts| if (claude.statusFor(ctx, sts, s) == .busy) busy.append(a, s.tmux_name) catch {};
    }
    return .{ .hidden = hidden.items, .busy = busy.items };
}

/// What to print: each list empty means any. Lists come from comma-separated
/// options (`--flag question,input`).
pub const Filter = struct {
    /// Ticket keys (case-insensitive).
    keys: []const []const u8 = &.{},
    projects: []const []const u8 = &.{},
    /// set, cleared, moved, new, needs, left.
    changes: []const Kind = &.{},
    /// Flag kinds; set and cleared lines for other flags are left out, and
    /// needs and left lines that are about none of them.
    flags: []const []const u8 = &.{},
    /// Stages; moved and new lines into other stages are left out.
    stages: []const []const u8 = &.{},

    pub fn match(self: Filter, c: Change) bool {
        if (self.keys.len > 0 and !anyEql(self.keys, c.key, true)) return false;
        if (self.projects.len > 0 and !anyEql(self.projects, c.project, false)) return false;
        if (self.changes.len > 0 and std.mem.indexOfScalar(Kind, self.changes, c.change) == null) return false;
        if (c.flag) |f| if (self.flags.len > 0) {
            var it = std.mem.tokenizeScalar(u8, f, ',');
            while (it.next()) |k| {
                if (anyEql(self.flags, k, false)) break;
            } else return false;
        };
        if (c.to) |t| if (self.stages.len > 0 and !anyEql(self.stages, t, false)) return false;
        return true;
    }
};

fn anyEql(list: []const []const u8, s: []const u8, nocase: bool) bool {
    for (list) |x| if (if (nocase) std.ascii.eqlIgnoreCase(x, s) else std.mem.eql(u8, x, s)) return true;
    return false;
}

/// "a,b, c" -> {"a", "b", "c"}; null or "" -> {}.
pub fn splitList(a: std.mem.Allocator, s: ?[]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s orelse "", ", ");
    while (it.next()) |x| try out.append(a, x);
    return out.toOwnedSlice(a);
}

/// Watch the board until killed, writing a line (or a JSON object) per
/// change that passes `filter`.
pub fn run(ctx: Ctx, cfg: config.Config, db: board.Db, json: bool, filter: Filter) !void {
    var prev = std.heap.ArenaAllocator.init(ctx.gpa);
    defer prev.deinit();
    var last: []const Seen = try snapshot(db, prev.allocator(), readSessions(ctx, cfg, prev.allocator()));
    const stdout = std.Io.File.stdout();
    while (true) {
        ctx.sleepMs(2000);
        var cur = std.heap.ArenaAllocator.init(ctx.gpa);
        const a = cur.allocator();
        // A review whose reviewer died stops keeping its ticket out of Needs
        // You, cl web running or not.
        _ = autoreview.checkAll(ctx, db, a) catch {};
        // A busy board (a write in progress) just means the next read.
        const now = snapshot(db, a, readSessions(ctx, cfg, a)) catch {
            cur.deinit();
            continue;
        };
        var aw: std.Io.Writer.Allocating = .init(a);
        for (try diff(a, last, now)) |c| {
            if (!filter.match(c)) continue;
            if (json) try aw.writer.print("{f}\n", .{std.json.fmt(c, .{})}) else try aw.writer.print("{f}\n", .{c});
        }
        if (aw.writer.buffered().len > 0) try stdout.writeStreamingAll(ctx.io, aw.writer.buffered());
        prev.deinit();
        prev = cur;
        last = now;
    }
}

const testing = std.testing;

fn testCtx() Ctx {
    return .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = undefined, .home = "/tmp" };
}

fn lines(a: std.mem.Allocator, cs: []const Change) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    for (cs) |c| try aw.writer.print("{f}\n", .{c});
    return aw.writer.buffered();
}

test "ticket watch: flags set and cleared, stage moves, new tickets, hidden ones quiet" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try board.addProject(db, .{ .name = "web", .dir = "/x/web" });
    const k1 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Fix the\nlogin spec" });
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "web", .title = "Hidden work" });
    try board.setProjectHidden(db, "web", true);

    // Nothing changed: nothing to say.
    const s0 = try snapshot(db, a, .{});
    try testing.expectEqual(@as(usize, 0), (try diff(a, s0, try snapshot(db, a, .{}))).len);

    try board.setFlag(ctx, db, a, k1, board.flag_question, "auto", "{\"q\":\"which?\"}");
    try board.setFlag(ctx, db, a, k2, board.flag_question, "auto", "{}");
    const s1 = try snapshot(db, a, .{});
    const d1 = try diff(a, s0, s1);
    try testing.expectEqualStrings("QA-1 qa set question Fix the login spec\nQA-1 qa needs question Fix the login spec\n", try lines(a, d1));
    try testing.expectEqualStrings("{\"q\":\"which?\"}", d1[0].detail.?);

    // Asked again with new words: the same flag, so no line.
    try board.setFlag(ctx, db, a, k1, board.flag_question, "auto", "again");
    const s2 = try snapshot(db, a, .{});
    try testing.expectEqual(@as(usize, 0), (try diff(a, s1, s2)).len);

    // Cleared and raised again between two reads still shows both, and it
    // asks something new.
    try board.clearFlag(ctx, db, a, k1, board.flag_question);
    try board.setFlag(ctx, db, a, k1, board.flag_question, "auto", "another");
    const s3 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa cleared question Fix the login spec\nQA-1 qa set question Fix the login spec\nQA-1 qa needs question Fix the login spec\n", try lines(a, try diff(a, s2, s3)));

    // A move to Testing: the stage, then the flag it brings.
    try board.move(ctx, db, a, k1, .testing);
    const s4 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa moved backlog->testing Fix the login spec\nQA-1 qa set testing Fix the login spec\nQA-1 qa needs question,testing Fix the login spec\n", try lines(a, try diff(a, s3, s4)));

    // A ticket whose session is hidden stays quiet; so does a new one in a
    // hidden project. A new shown one is announced with its flags.
    try db.exec("UPDATE tickets SET tmux = 'cl_qa_1' WHERE key = ?1", .{k1});
    try board.clearFlag(ctx, db, a, k1, board.flag_question);
    _ = try board.createTicket(ctx, db, a, .{ .project = "web", .title = "Also hidden" });
    const k3 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "New one", .stage = .queued });
    try board.setFlag(ctx, db, a, k3, "ended", "auto", "gone");
    const s5 = try snapshot(db, a, .{ .hidden = &.{"cl_qa_1"} });
    try testing.expectEqualStrings("QA-2 qa new queued New one\nQA-2 qa set ended New one\nQA-2 qa needs ended New one\n", try lines(a, try diff(a, s4, s5)));

    // Unhidden: what changed while hidden isn't replayed, but what waits in
    // Needs You now is.
    try board.setProjectHidden(db, "web", false);
    try testing.expectEqualStrings("WE-1 web needs question Hidden work\n", try lines(a, try diff(a, s5, try snapshot(db, a, .{ .hidden = &.{"cl_qa_1"} }))));

    // JSON carries the same, with nulls for what doesn't apply.
    const j = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(Change{ .key = "QA-1", .project = "qa", .change = .moved, .from = "running", .to = "review", .title = "T" }, .{})});
    try testing.expectEqualStrings("{\"key\":\"QA-1\",\"project\":\"qa\",\"change\":\"moved\",\"flag\":null,\"detail\":null,\"from\":\"running\",\"to\":\"review\",\"title\":\"T\"}", j);
}

test "ticket watch: Needs You, as the board decides it" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .running });
    try db.exec("UPDATE tickets SET tmux = 'cl_qa_1' WHERE key = ?1", .{k});
    const needsLines = struct {
        fn f(al: std.mem.Allocator, old: []const Seen, new: []const Seen) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(al);
            for (try diff(al, old, new)) |c| if (c.change == .needs or c.change == .left) try aw.writer.print("{f}\n", .{c});
            return aw.writer.buffered();
        }
    }.f;

    const s0 = try snapshot(db, a, .{});
    try board.setFlag(ctx, db, a, k, board.flag_question, "auto", "{}");
    const s1 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa needs question T\n", try needsLines(a, s0, s1));

    // Another flag while it's there: asks something new.
    try board.setFlag(ctx, db, a, k, "ended", "auto", "");
    const s2 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa needs question,ended T\n", try needsLines(a, s1, s2));

    // Hide takes it out; asking something new brings it back.
    _ = try board.hideNeeds(ctx, db, a, k, true);
    const s3 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa left question,ended T\n", try needsLines(a, s2, s3));
    try board.setFlag(ctx, db, a, k, board.flag_question, "auto", "{\"q\":\"new\"}");
    const s4 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa needs question T\n", try needsLines(a, s3, s4));

    // Claude working on it takes it out until it stops.
    const s5 = try snapshot(db, a, .{ .busy = &.{"cl_qa_1"} });
    try testing.expectEqualStrings("QA-1 qa left question T\n", try needsLines(a, s4, s5));
    const s6 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa needs question T\n", try needsLines(a, s5, s6));
    // So does an automated review of it, until it is done.
    const id = (try board.getTicket(db, a, k)).id;
    try board.setAutoreview(db, id, "{\"status\":\"running\",\"started\":1}");
    const s6r = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa left question T\n", try needsLines(a, s6, s6r));
    try board.setAutoreview(db, id, "{\"status\":\"done\",\"started\":1}");
    try testing.expectEqualStrings("QA-1 qa needs question T\n", try needsLines(a, s6r, try snapshot(db, a, .{})));

    // Parked: out. Done: out too (only work that didn't land, or a failed
    // after-merge run, stays).
    try db.exec("INSERT INTO parks (ticket, reason, at) VALUES ((SELECT id FROM tickets WHERE key = ?1), 'pr', 0)", .{k});
    const s7 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa left question T\n", try needsLines(a, s6, s7));
    try db.exec("DELETE FROM parks", .{});
    try board.move(ctx, db, a, k, .done);
    const s8 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("", try needsLines(a, s7, s8));
    try board.setFlag(ctx, db, a, k, board.flag_after_merge, "auto", "build failed");
    const s9 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa needs after-merge T\n", try needsLines(a, s8, s9));
    try board.setFlag(ctx, db, a, k, board.flag_unmerged, "auto", "2 changes on qa-1-t aren't in master");
    const s10 = try snapshot(db, a, .{});
    try testing.expectEqualStrings("QA-1 qa needs after-merge,unmerged T\n", try needsLines(a, s9, s10));
}

test "ticket watch: filters" {
    const a = testing.allocator;
    const q: Change = .{ .key = "QA-1", .project = "qa", .change = .set, .flag = "question", .title = "T" };
    const r: Change = .{ .key = "QA-2", .project = "qa", .change = .set, .flag = "review", .title = "T" };
    const qc: Change = .{ .key = "QA-1", .project = "qa", .change = .cleared, .flag = "question", .title = "T" };
    const mv: Change = .{ .key = "WEB-3", .project = "web", .change = .moved, .from = "running", .to = "review", .title = "T" };
    const nw: Change = .{ .key = "WEB-4", .project = "web", .change = .new, .to = "backlog", .title = "T" };

    // No filter: everything.
    for ([_]Change{ q, r, qc, mv, nw }) |c| try testing.expect((Filter{}).match(c));

    const flags = try splitList(a, "question, input");
    defer a.free(flags);
    const only_q: Filter = .{ .flags = flags, .changes = &.{.set} };
    try testing.expect(only_q.match(q));
    try testing.expect(!only_q.match(r));
    try testing.expect(!only_q.match(qc));
    try testing.expect(!only_q.match(mv));

    // A flag filter leaves stage lines alone, a stage filter flag lines.
    const flag_only: Filter = .{ .flags = flags };
    try testing.expect(flag_only.match(mv));
    const to_review: Filter = .{ .stages = &.{"review"} };
    try testing.expect(to_review.match(mv));
    try testing.expect(!to_review.match(nw));
    try testing.expect(to_review.match(q));

    // A needs line passes --flag when any of its kinds is listed.
    const nd: Change = .{ .key = "QA-1", .project = "qa", .change = .needs, .flag = "review,input", .title = "T" };
    try testing.expect(flag_only.match(nd));
    try testing.expect(!(Filter{ .flags = &.{"testing"} }).match(nd));

    // Keys are case-insensitive; projects narrow too.
    const keys = try splitList(a, "qa-1");
    defer a.free(keys);
    try testing.expect((Filter{ .keys = keys }).match(qc));
    try testing.expect(!(Filter{ .keys = keys }).match(r));
    try testing.expect((Filter{ .projects = &.{"web"} }).match(nw));
    try testing.expect(!(Filter{ .projects = &.{"web"} }).match(q));
    try testing.expectEqual(@as(usize, 0), (try splitList(a, null)).len);
}
