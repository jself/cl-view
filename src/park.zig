//! Parked tickets (`cl ticket park` / `unpark`): a ticket that waits on
//! something outside cl (a PR review, a deploy) without a live session.
//!
//! Parking kills its session as `cl ticket kill` does (stage and
//! conversation kept) and keeps it out of Needs You. With a check (`--until`,
//! a shell command), the dispatcher runs it every interval from the ticket's
//! directory, detached, in the environment the dispatcher has (so the user's
//! own `gh` login and the like). Exit 0 means the wait is over: the park
//! ends, the ticket is flagged `unparked` and its session resumes, told why.
//! A check that hasn't passed by the deadline gives up: the park ends with a
//! `park-expired` flag and the session stays stopped.
//!
//! `unpark` ends it by hand, resuming the session unless told not to.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const actions = @import("actions.zig");
const dispatch = @import("dispatch.zig");
const review = @import("review.zig");

pub const default_every = 3600;
pub const default_max = 7 * 86400;
/// The longest one check may run, in seconds (less when checks are more often).
const max_check = 600;

/// "90s", "30m", "1h", "7d", "2w" or a mix ("1h30m"), in seconds; null when
/// it isn't one, or is zero.
pub fn parseDuration(s: []const u8) ?i64 {
    var total: i64 = 0;
    var i: usize = 0;
    if (s.len == 0) return null;
    while (i < s.len) {
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start or i == s.len) return null;
        const n = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
        const unit: i64 = switch (s[i]) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 7 * 86400,
            else => return null,
        };
        i += 1;
        total = std.math.add(i64, total, std.math.mul(i64, n, unit) catch return null) catch return null;
    }
    return if (total > 0) total else null;
}

/// A duration the way parseDuration reads it, largest units first ("1h30m").
pub fn formatDuration(a: std.mem.Allocator, secs: i64) ![]const u8 {
    if (secs <= 0) return "0s";
    var aw: std.Io.Writer.Allocating = .init(a);
    var left = secs;
    for ([_]struct { i64, u8 }{ .{ 86400, 'd' }, .{ 3600, 'h' }, .{ 60, 'm' }, .{ 1, 's' } }) |u| {
        if (left >= u[0]) {
            try aw.writer.print("{d}{c}", .{ @divFloor(left, u[0]), u[1] });
            left = @mod(left, u[0]);
        }
    }
    return aw.written();
}

test parseDuration {
    try std.testing.expectEqual(@as(?i64, 3600), parseDuration("1h"));
    try std.testing.expectEqual(@as(?i64, 5400), parseDuration("1h30m"));
    try std.testing.expectEqual(@as(?i64, 7 * 86400), parseDuration("7d"));
    try std.testing.expectEqual(@as(?i64, 90), parseDuration("90s"));
    try std.testing.expectEqual(@as(?i64, 14 * 86400), parseDuration("2w"));
    for ([_][]const u8{ "", "1", "h", "0m", "1x", "1h30", "-1h" }) |bad| try std.testing.expectEqual(@as(?i64, null), parseDuration(bad));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("1h30m", try formatDuration(arena_state.allocator(), 5400));
    try std.testing.expectEqualStrings("7d", try formatDuration(arena_state.allocator(), 7 * 86400));
}

pub const Options = struct {
    reason: []const u8,
    /// Shell command; "" for none.
    until: []const u8 = "",
    every: i64 = default_every,
    max: i64 = default_max,
};

pub const Parked = struct {
    /// Its live session, which `stopSession` kills; null without one.
    session: ?[]const u8 = null,
    /// Other unfinished tickets on that session (a queue project's shared
    /// one): they let go of it too.
    others: []const []const u8 = &.{},
};

/// Park a ticket (parking it again replaces the park). The session keeps
/// running until `stopSession`, so the caller can say what happened first:
/// from inside the session (Claude parking its own ticket) nothing gets out
/// after it.
pub fn park(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, o: Options) !Parked {
    const t = try board.getTicket(db, a, key);
    if (t.stage == .done) return error.Finished;
    const reason = std.mem.trim(u8, o.reason, " \t\r\n");
    if (reason.len == 0) return error.BadInput;
    const until = std.mem.trim(u8, o.until, " \t\r\n");
    const now = ctx.nowSeconds();
    try board.setPark(ctx, db, t.id, .{
        .reason = reason,
        .until = until,
        .every = if (until.len > 0) o.every else 0,
        .at = now,
        .deadline = if (until.len > 0) now + o.max else 0,
        // The first check right away: it may be over already, and a broken
        // command shows at once.
        .next = now,
    });
    // What an earlier park left is settled by this one.
    try board.clearFlagId(ctx, db, t.id, board.flag_unparked);
    try board.clearFlagId(ctx, db, t.id, board.flag_park_expired);
    const live = actions.liveSession(ctx, t) orelse {
        // No session: it still waits for the park, not for the dispatcher.
        try db.exec("UPDATE tickets SET killed = 1 WHERE id = ?1", .{t.id});
        return .{};
    };
    var others: std.ArrayList([]const u8) = .empty;
    var st = try db.query("SELECT key FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage != 'done' ORDER BY id", .{ live, t.id });
    defer st.finalize();
    while (try st.step()) try others.append(a, try st.dupe(a, 0));
    return .{ .session = live, .others = others.items };
}

/// Kill the parked ticket's session, as `cl ticket kill` does.
pub fn stopSession(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    _ = actions.kill(ctx, cfg, db, a, key) catch |e| switch (e) {
        error.NoSession => {},
        else => return e,
    };
}

pub const Resumed = enum {
    /// Its session is back.
    started,
    /// It waits in Queued for its session (busy with another ticket).
    waiting,
    /// It already had a live session: the note waits for its next prompt.
    running,
};

pub const Unparked = struct {
    reason: []const u8,
    resumed: ?Resumed,
};

/// End the park by hand; unless `resume` is false, its session resumes,
/// told so.
pub fn unpark(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, @"resume": bool) !Unparked {
    const t = try board.getTicket(db, a, key);
    const p = try board.takePark(ctx, db, a, t.id, null) orelse return error.NotParked;
    try board.logEvent(ctx, db, t.id, "unparked", "by you");
    if (!@"resume") return .{ .reason = p.reason, .resumed = null };
    const r = try resumeWith(ctx, cfg, db, a, t.key, try std.fmt.allocPrint(a, "Unparked by you: {s}. Continue.", .{p.reason}));
    return .{ .reason = p.reason, .resumed = r };
}

/// Start the ticket's session again (resuming its conversation where Claude
/// still has it) with `note` for it.
fn resumeWith(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, note: []const u8) !Resumed {
    _ = try board.addComment(ctx, db, a, key, "cl", note, false);
    const t = try board.getTicket(db, a, key);
    dispatch.start(ctx, cfg, db, a, t, false) catch |e| switch (e) {
        // It moved to Queued; the dispatcher starts it there, note and all.
        error.TargetBusy => return .waiting,
        error.AlreadyStarted => return .running,
        else => return e,
    };
    return .started;
}

/// The dispatcher's part, each pass: give up on parks whose time is up, and
/// start each check that is due, detached (`cl ticket park-check`).
pub fn checkDue(ctx: Ctx, db: board.Db) !void {
    // Cheap enough to ask every pass: nothing parked with a check, nothing to do.
    if ((try db.int("SELECT 1 FROM parks WHERE until_cmd != '' LIMIT 1", .{})) == null) return;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now = ctx.nowSeconds();
    for (try board.dueParks(db, a, now)) |d| {
        if (d.park.deadline > 0 and d.park.deadline <= now) {
            try expire(ctx, db, a, d);
            continue;
        }
        if (!try board.claimParkCheck(db, d.id, d.park.at, now)) continue;
        spawnCheck(ctx, a, d.key, d.park.at) catch |e| {
            try board.recordParkCheck(db, d.id, d.park.at, now, try std.fmt.allocPrint(a, "cl couldn't start the check: {s}", .{@errorName(e)}));
        };
    }
}

fn expire(ctx: Ctx, db: board.Db, a: std.mem.Allocator, d: board.DuePark) !void {
    const p = try board.takePark(ctx, db, a, d.id, d.park.at) orelse return;
    const detail = try std.fmt.allocPrint(a, "Parked {s} waiting for: {s}. The check never passed{s}{s}; its session stays stopped.", .{
        try formatDuration(a, p.deadline - p.at), p.reason, if (p.result.len > 0) " (last: " else "", if (p.result.len > 0) try std.fmt.allocPrint(a, "{s})", .{p.result}) else "",
    });
    try board.logEvent(ctx, db, d.id, "park expired", p.reason);
    try board.setFlagId(ctx, db, d.id, board.flag_park_expired, "auto", detail);
}

/// `cl ticket park-check <key> --at <when>` in a session of its own (setsid),
/// so a restart of `cl web` leaves it running.
fn spawnCheck(ctx: Ctx, a: std.mem.Allocator, key: []const u8, at: i64) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];
    const r = try std.process.run(a, ctx.io, .{ .argv = &.{
        "sh", "-c", "exec setsid -f \"$@\" </dev/null >/dev/null 2>&1", "sh", exe, "ticket", "park-check", key, "--at", try std.fmt.allocPrint(a, "{d}", .{at}),
    } });
    if (r.term != .exited or r.term.exited != 0) return error.SpawnFailed;
}

/// Run the check of the park made at `at` once, and wake the ticket when it
/// passes. Never fails: there is nobody to tell but the board.
pub fn runCheck(ctx: Ctx, cfg: config.Config, db: board.Db, key: []const u8, at: i64) void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = board.getTicket(db, a, key) catch return;
    const p = t.park orelse return;
    if (p.at != at or p.until.len == 0) return;
    const result = check(ctx, db, a, t, p);
    board.recordParkCheck(db, t.id, at, ctx.nowSeconds(), result.text) catch {};
    if (result.ok) wake(ctx, cfg, db, a, t, p);
}

const CheckResult = struct { ok: bool, text: []const u8 };

fn check(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, p: board.Park) CheckResult {
    return checkIn(ctx, db, a, t, p) catch |e| .{ .ok = false, .text = std.fmt.allocPrint(a, "cl couldn't run it: {s}", .{@errorName(e)}) catch "cl couldn't run it" };
}

fn checkIn(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, p: board.Park) !CheckResult {
    const dir = try review.ticketDir(db, a, t);
    var env = try ctx.env.clone(a);
    // It isn't in the session that started the dispatcher.
    _ = env.swapRemove("TMUX");
    _ = env.swapRemove("TMUX_PANE");
    try env.put("CL_TICKET", t.key);
    try env.put("CL_PARK_UNTIL", p.until);
    const limit = @min(@max(p.every, 1), max_check);
    const res = try std.process.run(a, ctx.io, .{
        .argv = &.{ "timeout", "-k", "10", try std.fmt.allocPrint(a, "{d}", .{limit}), "sh", "-c", "exec </dev/null 2>&1; exec sh -c \"$CL_PARK_UNTIL\"" },
        .cwd = .{ .path = dir },
        .environ_map = &env,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    const what = if (code == null)
        "killed"
    else if (code.? == 124 or code.? == 137)
        try std.fmt.allocPrint(a, "timed out after {s}", .{try formatDuration(a, limit)})
    else
        try std.fmt.allocPrint(a, "exit {d}", .{code.?});
    const last = lastLine(res.stdout);
    return .{
        .ok = code == 0,
        .text = if (last.len > 0) try std.fmt.allocPrint(a, "{s}: {s}", .{ what, last }) else what,
    };
}

/// The last line of output with something on it, cut to a sensible length.
fn lastLine(out: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, out, '\n');
    while (it.next()) |l| {
        const s = std.mem.trim(u8, l, " \t\r");
        if (s.len > 0) return s[0..@min(s.len, 200)];
    }
    return "";
}

test lastLine {
    try std.testing.expectEqualStrings("no checks reported", lastLine("pending\nno checks reported\n\n"));
    try std.testing.expectEqualStrings("", lastLine("  \n"));
}

/// The check passed: the park ends, the ticket comes back to Needs You and
/// its session resumes, told what happened.
fn wake(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, p: board.Park) void {
    const took = board.takePark(ctx, db, a, t.id, p.at) catch return;
    if (took == null) return; // Unparked (or parked again) meanwhile.
    board.logEvent(ctx, db, t.id, "park condition met", p.reason) catch {};
    board.setFlagId(ctx, db, t.id, board.flag_unparked, "auto", std.fmt.allocPrint(a, "Parked condition met: {s}", .{p.reason}) catch p.reason) catch {};
    // Its project is paused: it waits in Queued, note and all, and the
    // dispatcher resumes it there once the project resumes.
    if (board.projectPaused(db, t.project) catch false) {
        holdForPause(ctx, db, a, t, std.fmt.allocPrint(a, "Parked condition met: {s}. Continue.", .{p.reason}) catch return) catch |e| {
            board.setFlagId(ctx, db, t.id, "start-failed", "auto", dispatch.failureReason(e)) catch {};
        };
        return;
    }
    _ = resumeWith(ctx, cfg, db, a, t.key, std.fmt.allocPrint(a, "Parked condition met: {s}. Continue.", .{p.reason}) catch return) catch |e| {
        board.setFlagId(ctx, db, t.id, "start-failed", "auto", dispatch.failureReason(e)) catch {};
    };
}

fn holdForPause(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, note: []const u8) !void {
    _ = try board.addComment(ctx, db, a, t.key, "cl", note, false);
    try board.requeue(ctx, db, t);
    try board.logEvent(ctx, db, t.id, "held: project paused", "");
}

// ---- tests ----

const testing = std.testing;

fn testCtx() Ctx {
    return .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = undefined, .home = "/tmp" };
}

test "park: out of Needs You, checks due at once then each interval, expiry flags it" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Waits on a PR", .stage = .review });
    try board.setFlag(ctx, db, a, k, board.flag_review, "auto", "");
    try testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);

    try testing.expectError(error.BadInput, park(ctx, db, a, k, .{ .reason = "  " }));
    const r = try park(ctx, db, a, k, .{ .reason = "PR #30", .until = "gh pr view 30", .every = 3600, .max = 7200 });
    try testing.expect(r.session == null);
    const t = try board.getTicket(db, a, k);
    try testing.expect(t.killed);
    try testing.expectEqualStrings("PR #30", t.park.?.reason);
    try testing.expectEqual(t.park.?.at + 7200, t.park.?.deadline);
    // Parked, it waits on the PR, not on you; its flag stays on the card.
    try testing.expectEqual(@as(usize, 0), (try board.listTickets(db, a, .{ .needs = true })).len);
    try testing.expectEqual(@as(usize, 0), (try board.listTickets(db, a, .{ .needs = true, .hidden = true })).len);
    try testing.expectEqual(@as(usize, 1), t.flags.len);

    // Due at once; claimed, it is due again an interval on (one dispatcher runs it).
    const at = t.park.?.at;
    try testing.expectEqual(@as(usize, 1), (try board.dueParks(db, a, at)).len);
    try testing.expect(try board.claimParkCheck(db, t.id, at, at));
    try testing.expect(!try board.claimParkCheck(db, t.id, at, at));
    try testing.expectEqual(@as(usize, 0), (try board.dueParks(db, a, at + 10)).len);
    try testing.expectEqual(@as(usize, 1), (try board.dueParks(db, a, at + 3600)).len);
    try board.recordParkCheck(db, t.id, at, at + 5, "exit 1: not merged");
    try testing.expectEqualStrings("exit 1: not merged", (try board.getTicket(db, a, k)).park.?.result);

    // A check of an older park doesn't end this one.
    try testing.expectEqual(@as(?board.Park, null), try board.takePark(ctx, db, a, t.id, at - 1));
    // Past the deadline: the park ends with a flag, the session stays stopped.
    const due = try board.dueParks(db, a, at + 7200);
    try testing.expectEqual(@as(usize, 1), due.len);
    try expire(ctx, db, a, due[0]);
    const after = try board.getTicket(db, a, k);
    try testing.expect(after.park == null);
    try testing.expect(after.killed);
    var expired = false;
    for (after.flags) |f| if (std.mem.eql(u8, f.kind, board.flag_park_expired)) {
        expired = true;
        try testing.expect(std.mem.indexOf(u8, f.detail, "exit 1: not merged") != null);
    };
    try testing.expect(expired);
    try testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);
}

test "park without a check: no checks, no deadline; a new session ends it" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Waits", .stage = .running });
    try testing.expectError(error.Finished, park(ctx, db, a, try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Over", .stage = .done }), .{ .reason = "x" }));
    _ = try park(ctx, db, a, k, .{ .reason = "the deploy", .until = "", .every = 60 });
    const t = try board.getTicket(db, a, k);
    try testing.expectEqual(@as(i64, 0), t.park.?.deadline);
    try testing.expectEqual(@as(i64, 0), t.park.?.every);
    try testing.expectEqual(@as(usize, 0), (try board.dueParks(db, a, t.park.?.at + 86400 * 30)).len);
    try board.setSession(ctx, db, t.id, "cl_qa_1", "", "", "");
    try testing.expect((try board.getTicket(db, a, k)).park == null);
}

test "a park whose check passes in a paused project waits in Queued with its note" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Waits on a PR", .stage = .review });
    _ = try park(ctx, db, a, k, .{ .reason = "PR #30", .until = "true" });
    try board.setProjectPaused(db, "qa", true);
    const t = try board.getTicket(db, a, k);
    // Not resumed (that would start its session): back in Queued, not killed,
    // with the note it resumes with once the project resumes.
    wake(ctx, .{ .profiles = &.{}, .default = "", .operator = "" }, db, a, t, t.park.?);
    const after = try board.getTicket(db, a, k);
    try testing.expect(after.park == null);
    try testing.expectEqual(board.Stage.queued, after.stage);
    try testing.expect(!after.killed);
    try testing.expectEqualStrings("", after.tmux);
    const notes = try board.unsentNotes(db, a, after.id);
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expect(std.mem.indexOf(u8, notes[0].body, "PR #30") != null);
}
