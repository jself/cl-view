//! The ticket board in the chooser (`b` there, or `cl board`): a column per
//! stage with the tickets as cards, a ticket's details, and the common
//! actions. Every action is the call `cl ticket` makes (board.zig,
//! actions.zig), so the three agree. What it shows follows the web board:
//! hidden projects and sub-tickets stay out unless switched on, Done is a
//! column only when asked for, and the Needs you pane over the columns is
//! `cl ticket needs`, each with what it asks.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const board = @import("board.zig");
const actions = @import("actions.zig");
const sgr = @import("sgr.zig");
const ui = @import("ui.zig");

const Stage = board.Stage;
const stage_count = std.enums.values(Stage).len;

pub fn stageName(s: Stage) []const u8 {
    return switch (s) {
        .backlog => "Backlog",
        .planning => "Planning",
        .queued => "Queued",
        .running => "Running",
        .review => "Review",
        .testing => "Testing",
        .done => "Done",
    };
}

/// The key that picks a stage after `m` (move).
fn stageKey(s: Stage) u8 {
    return switch (s) {
        .backlog => 'b',
        .planning => 'p',
        .queued => 'q',
        .running => 'r',
        .review => 'v',
        .testing => 't',
        .done => 'd',
    };
}

// ---- what the board shows ----

/// The switches over what the board shows.
pub const Options = struct {
    /// A Done column.
    done: bool = false,
    /// Sub-tickets as cards of their own.
    subs: bool = false,
    /// The tickets of hidden projects (`cl project hide`).
    hidden_projects: bool = false,
    /// Parked tickets (`cl t park`).
    parked: bool = true,
    /// Case-insensitive text in the key, title or body.
    search: []const u8 = "",
};

pub const Column = struct {
    stage: Stage,
    /// Indices into the tickets, top to bottom.
    cards: []const usize,
};

fn projectHidden(projects: []const board.Project, name: []const u8) bool {
    for (projects) |p| if (std.mem.eql(u8, p.name, name)) return p.hidden;
    return false;
}

fn projectPaused(projects: []const board.Project, name: []const u8) bool {
    for (projects) |p| if (std.mem.eql(u8, p.name, name)) return p.paused;
    return false;
}

/// Whether the board shows `t` (apart from which columns there are).
pub fn shows(t: board.Ticket, projects: []const board.Project, o: Options) bool {
    if (!o.hidden_projects and projectHidden(projects, t.project)) return false;
    if (!o.subs and t.parent.len > 0) return false;
    if (!o.done and t.stage == .done) return false;
    if (!o.parked and t.park != null) return false;
    if (o.search.len > 0) {
        for ([_][]const u8{ t.key, t.title, t.body }) |f| {
            if (std.ascii.indexOfIgnoreCase(f, o.search) != null) return true;
        }
        return false;
    }
    return true;
}

/// The columns and their cards. Each runs in priority order (rank), as the
/// web board's do, except Done: latest first, the order `tickets` comes in
/// (board.listTickets). Done is a column when switched on.
pub fn columns(a: std.mem.Allocator, tickets: []const board.Ticket, projects: []const board.Project, o: Options) ![]Column {
    var out: std.ArrayList(Column) = .empty;
    for (std.enums.values(Stage)) |s| {
        var cards: std.ArrayList(usize) = .empty;
        for (tickets, 0..) |t, i| if (t.stage == s and shows(t, projects, o)) try cards.append(a, i);
        if (s == .done and !o.done) continue;
        if (s != .done) std.sort.insertion(usize, cards.items, tickets, byRank);
        try out.append(a, .{ .stage = s, .cards = cards.items });
    }
    return out.items;
}

fn byRank(tickets: []const board.Ticket, x: usize, y: usize) bool {
    const a = tickets[x];
    const b = tickets[y];
    return a.rank < b.rank or (a.rank == b.rank and a.id < b.id);
}

/// A ticket's session as the board shows it (the web board's statusOf).
pub const CardStatus = enum {
    working,
    waiting,
    idle,
    starting,
    gone,
    unknown,
    killed,
    parked,
    /// Queued in a paused project (`cl project pause`).
    paused,
    /// Queued, waiting on other tickets to be done (board.hold).
    blocked,
    waiting_slot,
    not_started,
    done,
    /// An umbrella under way: its sub-tickets are, it never has a session.
    umbrella,
    /// A todo (yours) in Backlog: to do.
    todo,
    /// A todo in Running: you're doing it.
    doing,

    pub fn label(s: CardStatus) []const u8 {
        return switch (s) {
            .working => "working",
            .waiting => "waiting on you",
            .idle => "idle",
            .starting => "starting",
            .gone => "session ended",
            .unknown => "unknown",
            .killed => "killed; restart it",
            .parked => "parked",
            .paused => "paused",
            .blocked => "waits on other tickets",
            .waiting_slot => "waiting for a slot",
            .not_started => "not started",
            .done => "done",
            .umbrella => "umbrella",
            .todo => "to do",
            .doing => "doing",
        };
    }

    pub fn color(s: CardStatus) vaxis.Color {
        return switch (s) {
            .working => .{ .index = 3 },
            .waiting => .{ .index = 1 },
            .idle => .{ .index = 2 },
            .starting => .{ .index = 4 },
            .parked => .{ .index = 5 },
            .paused => .{ .index = 6 },
            .blocked => .{ .index = 6 },
            .umbrella => .{ .index = 166 }, // burnt orange, apart from parked's magenta
            .todo, .doing => .{ .index = 37 }, // teal: yours, apart from Claude's statuses
            .gone, .killed => .{ .index = 8 },
            else => .default,
        };
    }

    /// It has a session running.
    pub fn live(s: CardStatus) bool {
        return switch (s) {
            .working, .waiting, .idle, .starting, .unknown => true,
            else => false,
        };
    }
};

/// `live`: the status of its tmux session, when there is one. `paused`: its
/// project is paused.
pub fn cardStatus(t: board.Ticket, live: ?claude.Status, paused: bool) CardStatus {
    if (live) |st| return switch (st) {
        .busy => .working,
        .waiting, .blocked => .waiting,
        .idle, .shell => .idle,
        .starting => .starting,
        .gone => .gone,
        .unknown => .unknown,
    };
    if (t.tmux.len > 0 and t.tmux[0] == '(') return .starting;
    if (t.park != null) return .parked;
    // Yours: where you are with it, whatever an old kill left behind.
    if (t.todo and t.stage != .done) return if (t.stage == .running) .doing else .todo;
    if (t.killed) return .killed;
    if (t.stage == .done) return .done;
    if (t.umbrella) return .umbrella;
    if (t.tmux.len > 0 and t.stage != .backlog and t.stage != .queued) return .gone;
    if (t.stage != .queued) return .not_started;
    if (paused) return .paused;
    return switch (board.hold(t) orelse return .waiting_slot) {
        .blocked => .blocked,
        .subtickets => .umbrella, // caught above
        .todo => .todo, // caught above
    };
}

pub fn flagLabel(f: board.Flag) []const u8 {
    if (std.mem.eql(u8, f.kind, board.flag_review) and std.mem.eql(u8, f.detail, "plan")) return "plan ready";
    return f.kind;
}

fn flagColor(kind: []const u8) vaxis.Color {
    const eql = std.mem.eql;
    if (eql(u8, kind, board.flag_question) or eql(u8, kind, board.flag_input)) return .{ .index = 1 };
    if (eql(u8, kind, board.flag_review) or eql(u8, kind, board.flag_unparked) or eql(u8, kind, board.flag_ready_to_close)) return .{ .index = 2 };
    if (eql(u8, kind, board.flag_testing)) return .{ .index = 6 };
    if (board.todayFlag(kind)) return .{ .index = 37 }; // teal: a todo's, as its card
    if (eql(u8, kind, board.flag_conflict) or eql(u8, kind, board.flag_after_merge) or eql(u8, kind, board.flag_park_expired) or
        eql(u8, kind, board.flag_push_failed) or eql(u8, kind, board.flag_ci_failed) or
        eql(u8, kind, board.flag_pr_closed) or eql(u8, kind, board.flag_merge_failed) or eql(u8, kind, board.flag_unmerged)) return .{ .index = 5 };
    return .{ .index = 3 };
}

// ---- the cursor ----

/// Text kept across refreshes (the tickets live in an arena that each
/// refresh starts over); longer text is cut to `n` bytes.
pub fn TextBuf(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn get(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, n);
            @memcpy(self.buf[0..self.len], text[0..self.len]);
        }
    };
}

/// A ticket key.
pub const KeyBuf = TextBuf(64);

/// Which card is selected: a column and a place in it, and the ticket there.
pub const Cursor = struct {
    col: usize = 0,
    row: usize = 0,
    key: KeyBuf = .{},

    /// The selected ticket (an index into the tickets), if the column has any.
    pub fn selected(self: Cursor, cols: []const Column) ?usize {
        if (self.col >= cols.len) return null;
        const cards = cols[self.col].cards;
        if (self.row >= cards.len) return null;
        return cards[self.row];
    }

    /// After the board changed: back on the same ticket, wherever it went;
    /// if it is gone, the same place, kept inside the board.
    pub fn restore(self: *Cursor, cols: []const Column, tickets: []const board.Ticket) void {
        if (self.key.len > 0) {
            for (cols, 0..) |c, ci| for (c.cards, 0..) |ti, ri| {
                if (std.mem.eql(u8, tickets[ti].key, self.key.get())) {
                    self.col = ci;
                    self.row = ri;
                    return;
                }
            };
        }
        self.clamp(cols, tickets);
    }

    fn clamp(self: *Cursor, cols: []const Column, tickets: []const board.Ticket) void {
        if (cols.len == 0) {
            self.col = 0;
            self.row = 0;
            self.key.len = 0;
            return;
        }
        if (self.col >= cols.len) self.col = cols.len - 1;
        const n = cols[self.col].cards.len;
        if (self.row >= n) self.row = n -| 1;
        if (self.selected(cols)) |ti| self.key.set(tickets[ti].key) else self.key.len = 0;
    }

    /// Left or right a column, at the same height (or the last card there).
    pub fn moveCol(self: *Cursor, cols: []const Column, tickets: []const board.Ticket, delta: isize) void {
        if (cols.len == 0) return;
        const to: isize = @as(isize, @intCast(self.col)) + delta;
        self.col = @intCast(std.math.clamp(to, 0, @as(isize, @intCast(cols.len - 1))));
        self.clamp(cols, tickets);
    }

    /// Up or down; `to_end` goes to the top (delta < 0) or bottom.
    pub fn moveRow(self: *Cursor, cols: []const Column, tickets: []const board.Ticket, delta: isize, to_end: bool) void {
        if (self.col >= cols.len) return;
        const n = cols[self.col].cards.len;
        if (n == 0) return;
        if (to_end) {
            self.row = if (delta < 0) 0 else n - 1;
        } else {
            const to: isize = @as(isize, @intCast(self.row)) + delta;
            self.row = @intCast(std.math.clamp(to, 0, @as(isize, @intCast(n - 1))));
        }
        self.clamp(cols, tickets);
    }
};

/// The first of `len` items to show in a window of `fits`, starting from
/// `scroll`, so that `row` is in it and it isn't scrolled past the end.
pub fn keepVisible(scroll: usize, row: usize, fits: usize, len: usize) usize {
    if (fits == 0) return row;
    var s = scroll;
    if (row < s) s = row;
    if (row >= s + fits) s = row + 1 - fits;
    if (s + fits > len) s = len -| fits;
    return s;
}

// ---- answers ----

/// An answer line as `cl ticket answer` takes its arguments: one per
/// question, separated by "|" ("2 | use the staging DB"); a multi-select
/// one is a single answer like "1,3".
pub fn splitAnswers(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '|');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == 0) return error.BadAnswer;
        try out.append(a, p);
    }
    return out.items;
}

/// What a `question` or `input` flag asks (signals.Ask, as stored), read
/// leniently for showing.
const AskView = struct {
    kind: []const u8 = "",
    tool: []const u8 = "",
    summary: []const u8 = "",
    questions: ?[]const struct {
        question: []const u8 = "",
        header: []const u8 = "",
        multiSelect: bool = false,
        options: ?[]const struct { label: []const u8 = "", description: []const u8 = "" } = null,
    } = null,
    options: []const struct { n: u8 = 0, label: []const u8 = "" } = &.{},
};

/// The flag a ticket waits for an answer on (question or input), if any.
pub fn askFlag(t: board.Ticket) ?board.Flag {
    for (t.flags) |f| {
        if (std.mem.eql(u8, f.kind, board.flag_question) or std.mem.eql(u8, f.kind, board.flag_input)) return f;
    }
    return null;
}

/// The flag Needs you shows for a ticket: its first one not hidden from
/// it (on a Done ticket only a failed after-merge run still asks).
pub fn needsFlag(t: board.Ticket) ?board.Flag {
    for (t.flags) |f| {
        if (f.hidden) continue;
        if (t.stage == .done and !board.asksWhenDone(f.kind)) continue;
        // Parked, only a todo's reminder or due date still asks.
        if (t.park != null and !board.todayFlag(f.kind)) continue;
        return f;
    }
    return null;
}

/// What a flag asks of you, on one line (the web board's Needs you card,
/// with a question's options and a prompt's command spelled out).
pub fn askLine(a: std.mem.Allocator, t: board.Ticket, f: board.Flag) ![]const u8 {
    const out = try a.dupe(u8, try askLineRaw(a, t, f));
    for (out) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    return out;
}

fn askLineRaw(a: std.mem.Allocator, t: board.Ticket, f: board.Flag) ![]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, f.kind, board.flag_question) or eql(u8, f.kind, board.flag_input)) {
        const v = std.json.parseFromSliceLeaky(AskView, a, f.detail, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch AskView{};
        const qs = v.questions orelse &.{};
        if (qs.len > 1) {
            var out: std.ArrayList(u8) = .empty;
            try out.print(a, "{d} questions: ", .{qs.len});
            for (qs, 0..) |q, i| try out.print(a, "{s}{s}", .{ if (i > 0) " · " else "", q.question });
            return out.items;
        }
        if (qs.len == 1) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, qs[0].question);
            for (qs[0].options orelse &.{}, 0..) |o, i| try out.print(a, "{s}{d} {s}", .{ if (i == 0) " — " else " · ", i + 1, o.label });
            return out.items;
        }
        if (eql(u8, f.kind, board.flag_question)) return "Claude asked something (enter shows the session)";
        var out: std.ArrayList(u8) = .empty;
        if (v.tool.len > 0) try out.print(a, "Wants permission: {s}{s}{s}", .{ v.tool, if (v.summary.len > 0) ": " else "", v.summary }) else try out.appendSlice(a, if (v.summary.len > 0) v.summary else "Waiting on a prompt");
        for (v.options, 0..) |o, i| try out.print(a, "{s}{d} {s}", .{ if (i == 0) " — " else " · ", o.n, o.label });
        return out.items;
    }
    if (eql(u8, f.kind, board.flag_review)) {
        if (eql(u8, f.detail, "plan")) return "Plan ready for approval";
        return if (t.summary.len > 0) try std.fmt.allocPrint(a, "Ready for review: {s}", .{t.summary}) else "Ready for review";
    }
    if (eql(u8, f.kind, board.flag_testing)) return if (t.summary.len > 0) try std.fmt.allocPrint(a, "Ready to test: {s}", .{t.summary}) else "Ready to test";
    if (eql(u8, f.kind, board.flag_conflict)) {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "Merging it back conflicts in: ");
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, f.detail, '\n');
        while (it.next()) |l| {
            const file = std.mem.trim(u8, l, " ");
            if (file.len == 0) continue;
            const end = std.mem.indexOfAny(u8, file, " \t") orelse file.len;
            try out.print(a, "{s}{s}", .{ if (n > 0) ", " else "", file[0..end] });
            n += 1;
        }
        return out.items;
    }
    if (eql(u8, f.kind, board.flag_after_merge)) {
        const first = std.mem.sliceTo(f.detail, '\n');
        return std.fmt.allocPrint(a, "After-merge command failed{s}{s}", .{ if (first.len > 0) ": " else "", first });
    }
    if (eql(u8, f.kind, board.flag_push_failed)) {
        const first = std.mem.sliceTo(f.detail, '\n');
        return std.fmt.allocPrint(a, "Push after merge failed{s}{s}", .{ if (first.len > 0) ": " else "", first });
    }
    // Its detail starts "CI failed at <commit>: ...".
    if (eql(u8, f.kind, board.flag_ci_failed)) return std.mem.sliceTo(f.detail, '\n');
    if (eql(u8, f.kind, board.flag_merge_failed)) {
        const first = std.mem.sliceTo(f.detail, '\n');
        return std.fmt.allocPrint(a, "Merge didn't land{s}{s}", .{ if (first.len > 0) ": " else "", first });
    }
    if (eql(u8, f.kind, board.flag_unmerged)) {
        const first = std.mem.sliceTo(f.detail, '\n');
        return std.fmt.allocPrint(a, "Done but not merged{s}{s}", .{ if (first.len > 0) ": " else "", first });
    }
    if (eql(u8, f.kind, "start-failed")) return std.fmt.allocPrint(a, "Its session didn't start ({s})", .{if (f.detail.len > 0) f.detail else "no reason given"});
    if (eql(u8, f.kind, board.flag_park_expired)) return std.fmt.allocPrint(a, "Its park's check never passed{s}{s}", .{ if (f.detail.len > 0) ": " else "", f.detail });
    if (eql(u8, f.kind, board.flag_pr_closed)) return std.fmt.allocPrint(a, "PR closed without merging{s}{s}", .{ if (f.detail.len > 0) ": " else "", f.detail });
    if (eql(u8, f.kind, board.flag_unparked)) return std.fmt.allocPrint(a, "Woke from its park{s}{s}", .{ if (f.detail.len > 0) ": " else "", f.detail });
    return if (f.detail.len > 0) f.detail else f.kind;
}

/// The key that acts on a flag from Needs you, for its row's hint.
fn askHint(t: board.Ticket, f: board.Flag) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, f.kind, board.flag_question) or eql(u8, f.kind, board.flag_input)) return "A answer";
    if (eql(u8, f.kind, board.flag_review) or (eql(u8, f.kind, board.flag_testing) and t.stage == .testing)) return "a approve";
    if (board.todayFlag(f.kind)) return "m d done";
    return "enter open";
}

// ---- details ----

pub const Line = struct {
    text: []const u8,
    style: vaxis.Style = .{},
    /// Columns to indent it by (wrapped lines keep it).
    indent: u16 = 0,
};

const heading: vaxis.Style = .{ .bold = true };
const dim: vaxis.Style = .{ .dim = true };

/// Where a ticket that plans first stands (board.planState), for its detail line.
fn planLabel(t: board.Ticket) []const u8 {
    return switch (board.planState(t)) {
        .none => "",
        .plan_first => " · plans first",
        .planned => " · planned",
        .planned_umbrella => " · planned, now an umbrella",
    };
}

/// A ticket in full, as `cl ticket show` has it: what it is, what it asks,
/// its description, plan, sub-tickets, comments and activity.
pub fn detailLines(a: std.mem.Allocator, now: i64, t: board.Ticket, status: CardStatus, subs: []const board.Ticket, cs: []const board.Comment, evs: []const board.Event) ![]Line {
    var l: std.ArrayList(Line) = .empty;
    const add = struct {
        fn f(al: std.mem.Allocator, list: *std.ArrayList(Line), text: []const u8, style: vaxis.Style, indent: u16) !void {
            try list.append(al, .{ .text = text, .style = style, .indent = indent });
        }
    }.f;
    try add(a, &l, try std.fmt.allocPrint(a, "{s} · {s} · {s}{s} · round {d} · {s}", .{
        stageName(t.stage), t.project, @tagName(t.mode), planLabel(t), t.round, status.label(),
    }), dim, 0);
    if (t.parent.len > 0) try add(a, &l, try std.fmt.allocPrint(a, "sub-ticket of {s}", .{t.parent}), dim, 0);
    if (t.children > 0) try add(a, &l, try std.fmt.allocPrint(a, "sub-tickets {d}/{d} done", .{ t.children_done, t.children }), dim, 0);
    if (t.tmux.len > 0 and t.tmux[0] != '(') try add(a, &l, try std.fmt.allocPrint(a, "session {s}", .{t.tmux}), dim, 0);
    if (t.worktree.len > 0) try add(a, &l, try std.fmt.allocPrint(a, "worktree {s}  branch {s}", .{ t.worktree, t.branch }), dim, 0);
    if (t.park) |p| try add(a, &l, try std.fmt.allocPrint(a, "parked {s} ago: {s}", .{ try ui.ageText(a, now - p.at), p.reason }), .{ .fg = .{ .index = 5 } }, 0);
    if (t.drift) |d| if (t.stage != .done) try add(a, &l, try std.fmt.allocPrint(a, "will conflict with {s}: {s} (`cl ticket rebase {s}`)", .{ d.onto, try std.mem.replaceOwned(u8, a, std.mem.trim(u8, d.files, "\n"), "\n", ", "), t.key }), .{ .fg = .{ .index = 3 } }, 0);
    if (t.killed and t.park == null) try add(a, &l, try std.fmt.allocPrint(a, "its session was killed; `cl ticket start {s}` restarts it", .{t.key}), dim, 0);
    if (t.finishing.len > 0) try add(a, &l, try std.fmt.allocPrint(a, "finishing ({s}): it goes to Done once Claude is through", .{t.finishing}), .{ .fg = .{ .index = 2 } }, 0);
    if (t.custom_close.len > 0) try add(a, &l, try std.fmt.allocPrint(a, "custom close: {s}", .{t.custom_close}), .{ .fg = .{ .index = 2 } }, 0);

    if (t.flags.len > 0) {
        try add(a, &l, "", .{}, 0);
        try add(a, &l, "Flags", heading, 0);
        for (t.flags) |f| {
            try add(a, &l, try std.fmt.allocPrint(a, "{s}{s} · {s}", .{ flagLabel(f), if (f.hidden) " (hidden from needs you)" else "", try ui.ageText(a, now - f.at) }), .{ .fg = flagColor(f.kind), .bold = true }, 2);
            try askLines(a, &l, t, f);
        }
    }
    if (t.body.len > 0) {
        try add(a, &l, "", .{}, 0);
        try add(a, &l, "Description", heading, 0);
        try add(a, &l, t.body, .{}, 2);
    }
    if (t.plan_md.len > 0) {
        try add(a, &l, "", .{}, 0);
        try add(a, &l, "Plan", heading, 0);
        try add(a, &l, t.plan_md, .{}, 2);
    }
    if (subs.len > 0) {
        try add(a, &l, "", .{}, 0);
        try add(a, &l, "Sub-tickets", heading, 0);
        for (subs) |c| try add(a, &l, try std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ c.key, stageName(c.stage), c.title }), .{}, 2);
    }
    if (cs.len > 0) {
        try add(a, &l, "", .{}, 0);
        try add(a, &l, "Comments", heading, 0);
        for (cs) |c| {
            try add(a, &l, try std.fmt.allocPrint(a, "{s} · {s}{s}", .{ c.author, try ui.ageText(a, now - c.at), if (c.sent) " · sent" else "" }), .{ .dim = true, .italic = true }, 2);
            try add(a, &l, c.body, .{}, 4);
        }
    }
    if (evs.len > 0) {
        try add(a, &l, "", .{}, 0);
        try add(a, &l, "Activity", heading, 0);
        // Newest first: the latest is what you came for.
        var i = evs.len;
        while (i > 0) {
            i -= 1;
            const e = evs[i];
            try add(a, &l, try std.fmt.allocPrint(a, "{s:>4}  {s}{s}{s}", .{ try ui.ageText(a, now - e.at), e.kind, if (e.detail.len > 0) " " else "", e.detail }), dim, 2);
        }
    }
    return l.items;
}

/// What a flag says, under it: a question with its options, a permission
/// prompt, or the flag's own detail.
fn askLines(a: std.mem.Allocator, l: *std.ArrayList(Line), t: board.Ticket, f: board.Flag) !void {
    const eql = std.mem.eql;
    if (eql(u8, f.kind, board.flag_question) or eql(u8, f.kind, board.flag_input)) {
        const v = std.json.parseFromSliceLeaky(AskView, a, f.detail, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            if (f.detail.len > 0) try l.append(a, .{ .text = f.detail, .indent = 4 });
            return;
        };
        const qs = v.questions orelse &.{};
        for (qs, 0..) |q, qi| {
            const head = if (q.header.len > 0) try std.fmt.allocPrint(a, "{s}: ", .{q.header}) else "";
            const n = if (qs.len > 1) try std.fmt.allocPrint(a, "{d}) ", .{qi + 1}) else "";
            try l.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ n, head, q.question, if (q.multiSelect) " (pick any: \"1,3\")" else "" }), .indent = 4 });
            for (q.options orelse &.{}, 0..) |o, oi| {
                try l.append(a, .{ .text = try std.fmt.allocPrint(a, "{d}. {s}{s}{s}", .{ oi + 1, o.label, if (o.description.len > 0) " — " else "", o.description }), .indent = 6 });
            }
        }
        if (qs.len == 0) {
            if (v.tool.len > 0 or v.summary.len > 0) try l.append(a, .{ .text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (v.tool.len > 0) v.tool else "permission", if (v.summary.len > 0) ": " else "", v.summary }), .indent = 4 });
            for (v.options) |o| try l.append(a, .{ .text = try std.fmt.allocPrint(a, "{d}. {s}", .{ o.n, o.label }), .indent = 6 });
        }
        if (qs.len > 1) try l.append(a, .{ .text = "A answers: one per question, separated by |", .style = dim, .indent = 4 });
        return;
    }
    if (eql(u8, f.kind, board.flag_review)) {
        const text = if (eql(u8, f.detail, "plan")) (if (!t.umbrella) "the plan is ready: a approves it (Queued, a new session builds it)" else if (t.children > 0) "the plan is ready: a approves it (Queued, and its sub-tickets with it)" else "the plan is ready, but it's an umbrella with no sub-tickets yet: have Claude file them first") else if (t.summary.len > 0) try std.fmt.allocPrint(a, "{s}\n(a approves it and finishes it: the Done dialog)", .{t.summary}) else "ready for review: a approves it and finishes it (the Done dialog)";
        try l.append(a, .{ .text = text, .indent = 4 });
        return;
    }
    if (eql(u8, f.kind, board.flag_testing)) {
        if (t.summary.len > 0) try l.append(a, .{ .text = t.summary, .indent = 4 });
        try l.append(a, .{ .text = try std.fmt.allocPrint(a, "ready to test (`cl ticket test {s}` walks the test plan); a when it's tested, on to Review", .{t.key}), .indent = 4 });
        return;
    }
    if (f.detail.len > 0) try l.append(a, .{ .text = f.detail, .indent = 4 });
}

/// `lines` cut to `width` columns at spaces (a word longer than the width
/// is cut where it must), each piece keeping its line's style and indent.
/// Newlines in a line start new lines.
pub fn wrap(a: std.mem.Allocator, lines: []const Line, width: usize) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    for (lines) |line| {
        const room = @max(width -| line.indent, 8);
        var paras = std.mem.splitScalar(u8, line.text, '\n');
        while (paras.next()) |para_raw| {
            const para = std.mem.trimEnd(u8, para_raw, " \r\t");
            if (para.len == 0) {
                try out.append(a, .{ .text = "", .style = line.style, .indent = line.indent });
                continue;
            }
            var rest = para;
            while (rest.len > 0) {
                const cut = breakAt(rest, room);
                try out.append(a, .{ .text = std.mem.trimEnd(u8, rest[0..cut], " "), .style = line.style, .indent = line.indent });
                rest = std.mem.trimStart(u8, rest[cut..], " ");
            }
        }
    }
    return out.items;
}

/// Bytes of `text` that fit in `room` columns, ending at a space when one is
/// in reach; always at least one codepoint.
fn breakAt(text: []const u8, room: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    var end: usize = 0;
    var last_space: ?usize = null;
    while (it.nextCodepointSlice()) |cp| {
        if (n == room) {
            // The next one is a space: the line ends right here.
            if (cp[0] == ' ') return end;
            return last_space orelse end;
        }
        if (cp[0] == ' ' and n > 0) last_space = end;
        n += 1;
        end += cp.len;
    }
    return end;
}

// ---- the view ----

/// What the chooser should do after a key or a prompt.
pub const Outcome = union(enum) {
    none,
    /// Re-read everything (something changed).
    reload,
    /// Back to the session list.
    leave,
    quit,
    /// Attach to this tmux session.
    attach: []const u8,
    /// Open the operator (as `o` in the session list does).
    operator,
    /// Ask for a line of text (`label`, starting out as `prefill`); the
    /// answer goes to `submit`.
    prompt: struct { label: []const u8, prefill: []const u8 = "" },
};

/// What the chooser has that the board needs, per call.
pub const Env = struct {
    ctx: Ctx,
    cfg: config.Config,
    db: board.Db,
    /// Lives until the next refresh.
    a: std.mem.Allocator,
    sessions: []const tmux.Session,
    statuses: claude.StatusMap,
};

const Prompt = enum { search, note, send, answer, tell, new_project, new_title, new_body };

/// A question asked by single keys at the bottom line.
const Choice = enum { stage, spin_off, finish };

/// What is going to Done, between the questions on the way (sub-tickets,
/// how to finish).
const Pending = struct {
    key: KeyBuf = .{},
    /// approve (from Testing) rather than a move.
    approve: bool = false,
    spin_off: bool = false,
};

pub const View = struct {
    opts: Options = .{},
    cursor: Cursor = .{},
    /// Per column (by stage): the first card shown.
    scroll: [stage_count]usize = @splat(0),
    /// The first column shown, when they don't all fit.
    col_off: usize = 0,
    /// Showing one ticket in full (this one) instead of the columns.
    detail: ?KeyBuf = null,
    detail_scroll: usize = 0,
    search: KeyBuf = .{},
    /// The Needs you pane over the columns: unfolded, and whether the
    /// cursor is in it (on `needs_key`, at `needs_row`).
    needs_open: bool = true,
    in_needs: bool = false,
    needs_row: usize = 0,
    needs_key: KeyBuf = .{},
    needs_scroll: usize = 0,
    prompt: Prompt = .note,
    choice: ?Choice = null,
    pending: Pending = .{},
    /// A new ticket, between its prompts: it goes in the column the cursor
    /// was on (as the web board's + does).
    new_project: TextBuf(128) = .{},
    new_title: TextBuf(1024) = .{},
    new_stage: Stage = .backlog,
    /// The last thing an action said (a fixed buffer: it outlives refreshes).
    msg_buf: [512]u8 = undefined,
    msg_len: usize = 0,
    msg_err: bool = false,
    pending_g: bool = false,

    // Re-read each refresh, in the refresh's arena.
    tickets: []board.Ticket = &.{},
    projects: []board.Project = &.{},
    cols: []Column = &.{},
    /// What `cl ticket needs` lists (hidden projects' too when shown),
    /// oldest ask first: the Needs you pane.
    needs: []board.Ticket = &.{},
    live: std.StringHashMapUnmanaged(claude.Status) = .empty,
    /// The ticket in full, when `detail` is set.
    full: ?board.Ticket = null,
    full_lines: []Line = &.{},
    preview: [][]sgr.Segment = &.{},

    pub fn setMsg(self: *View, err: bool, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg_buf, fmt, args) catch blk: {
            @memcpy(self.msg_buf[self.msg_buf.len - 3 ..], "...");
            break :blk self.msg_buf[0..];
        };
        self.msg_len = s.len;
        self.msg_err = err;
    }

    pub fn message(self: *const View) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    /// Re-read the board (each refresh). The cursor stays on its ticket.
    pub fn load(self: *View, env: Env) !void {
        var busy: std.ArrayList([]const u8) = .empty;
        self.live = .empty;
        for (env.sessions) |s| {
            const st = claude.statusFor(env.ctx, env.statuses, s);
            try self.live.put(env.a, s.tmux_name, st);
            if (st == .busy) try busy.append(env.a, s.tmux_name);
        }
        self.projects = try board.listProjects(env.db, env.a);
        // Exactly what `cl ticket needs` lists (with --hidden-projects when
        // they are switched on).
        self.needs = try board.listTickets(env.db, env.a, .{ .needs = true, .busy = busy.items, .shown = !self.opts.hidden_projects });
        // Todos' reminders and due dates last, as the web board's Today group.
        std.sort.insertion(board.Ticket, self.needs, {}, struct {
            fn lt(_: void, x: board.Ticket, y: board.Ticket) bool {
                return !board.todayOnly(x) and board.todayOnly(y);
            }
        }.lt);
        self.restoreNeeds();
        self.tickets = try board.listTickets(env.db, env.a, .{});
        var o = self.opts;
        o.search = self.search.get();
        self.cols = try columns(env.a, self.tickets, self.projects, o);
        self.cursor.restore(self.cols, self.tickets);
        try self.loadDetail(env);
    }

    /// Back on the same ticket in Needs you, or the same row; out of the
    /// pane when it's empty or folded.
    fn restoreNeeds(self: *View) void {
        for (self.needs, 0..) |t, i| if (std.mem.eql(u8, t.key, self.needs_key.get())) {
            self.needs_row = i;
        };
        if (self.needs_row >= self.needs.len) self.needs_row = self.needs.len -| 1;
        if (self.needs.len == 0 or !self.needs_open) self.in_needs = false;
        if (self.needs.len > 0) self.needs_key.set(self.needs[self.needs_row].key);
    }

    fn moveNeeds(self: *View, delta: isize, to_end: bool) void {
        if (self.needs.len == 0) return;
        if (to_end) {
            self.needs_row = if (delta < 0) 0 else self.needs.len - 1;
        } else {
            const to: isize = @as(isize, @intCast(self.needs_row)) + delta;
            self.needs_row = @intCast(std.math.clamp(to, 0, @as(isize, @intCast(self.needs.len - 1))));
        }
        self.needs_key.set(self.needs[self.needs_row].key);
    }

    fn loadDetail(self: *View, env: Env) !void {
        self.full = null;
        self.full_lines = &.{};
        self.preview = &.{};
        const k = self.detail orelse return;
        const t = board.getTicket(env.db, env.a, k.get()) catch |e| switch (e) {
            error.NotFound => {
                self.detail = null;
                self.setMsg(true, "{s} is gone (deleted)", .{k.get()});
                return;
            },
            else => return e,
        };
        self.full = t;
        const st = cardStatus(t, self.live.get(t.tmux), projectPaused(self.projects, t.project));
        const subs = try board.listTickets(env.db, env.a, .{ .parent = t.key });
        self.full_lines = try detailLines(env.a, env.ctx.nowSeconds(), t, st, subs, try board.comments(env.db, env.a, t.id), try board.events(env.db, env.a, t.id));
        if (st.live() and t.tmux.len > 0) self.preview = try capturePane(env, t.tmux, 40);
    }

    /// The ticket actions apply to: the one open in full, else the selected card.
    fn target(self: *View) ?board.Ticket {
        if (self.detail != null) return self.full;
        if (self.in_needs) return if (self.needs_row < self.needs.len) self.needs[self.needs_row] else null;
        const i = self.cursor.selected(self.cols) orelse return null;
        return self.tickets[i];
    }

    pub fn handleKey(self: *View, env: Env, key: vaxis.Key) !Outcome {
        if (key.matches('c', .{ .ctrl = true })) return .quit;
        self.msg_len = 0;
        if (self.choice) |c| return self.handleChoice(env, c, key);
        if (key.matches('g', .{})) {
            if (self.pending_g) self.scrollTo(true);
            self.pending_g = !self.pending_g;
            return .none;
        }
        self.pending_g = false;
        if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
            self.scrollTo(false);
            return .none;
        }
        if (self.detail != null) {
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches(vaxis.Key.backspace, .{})) {
                self.detail = null;
                return .reload;
            }
            if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                self.detail_scroll += 1;
                return .none;
            }
            if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                self.detail_scroll -|= 1;
                return .none;
            }
            if (key.matches(' ', .{}) or key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
                self.detail_scroll += 10;
                return .none;
            }
            if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
                self.detail_scroll -|= 10;
                return .none;
            }
        } else {
            if (key.matches(vaxis.Key.escape, .{}) and self.in_needs) {
                self.in_needs = false;
                return .none;
            }
            if (key.matches(vaxis.Key.escape, .{}) and self.search.len > 0) {
                self.search.len = 0;
                return .reload;
            }
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches('b', .{})) return .leave;
            if (key.matches(vaxis.Key.tab, .{})) {
                if (!self.in_needs and self.needs.len == 0) {
                    self.setMsg(false, "nothing needs you", .{});
                    return .none;
                }
                self.in_needs = !self.in_needs;
                if (self.in_needs) self.needs_open = true;
                return .none;
            }
            if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                if (self.in_needs) self.in_needs = false else self.cursor.moveCol(self.cols, self.tickets, -1);
                return .none;
            }
            if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                if (self.in_needs) self.in_needs = false else self.cursor.moveCol(self.cols, self.tickets, 1);
                return .none;
            }
            if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                // Down off the end of Needs you goes on into the columns.
                if (self.in_needs and self.needs_row + 1 >= self.needs.len) self.in_needs = false else if (self.in_needs) self.moveNeeds(1, false) else self.cursor.moveRow(self.cols, self.tickets, 1, false);
                return .none;
            }
            if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                if (self.in_needs) self.moveNeeds(-1, false) else self.cursor.moveRow(self.cols, self.tickets, -1, false);
                return .none;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                const t = self.target() orelse return .none;
                self.openDetail(t.key);
                return .reload;
            }
            if (key.matches('N', .{}) or key.matches('n', .{ .shift = true })) {
                self.needs_open = !self.needs_open;
                if (!self.needs_open) self.in_needs = false;
                return .none;
            }
            if (key.matches('n', .{})) return self.startNew(env);
            if (key.matches('D', .{}) or key.matches('d', .{ .shift = true })) return self.toggle(&self.opts.done, "Done column shown", "Done column hidden");
            if (key.matches('S', .{}) or key.matches('s', .{ .shift = true })) return self.toggle(&self.opts.subs, "sub-tickets shown", "sub-tickets hidden");
            if (key.matches('H', .{}) or key.matches('h', .{ .shift = true })) return self.toggle(&self.opts.hidden_projects, "hidden projects shown", "hidden projects hidden");
            if (key.matches('P', .{}) or key.matches('p', .{ .shift = true })) return self.toggle(&self.opts.parked, "parked tickets shown", "parked tickets hidden");
            if (key.matches('/', .{})) {
                self.prompt = .search;
                return .{ .prompt = .{ .label = " search: ", .prefill = self.search.get() } };
            }
        }
        if (key.matches('r', .{ .ctrl = true })) return .reload;
        if (key.matches('o', .{})) return .operator;
        // Actions on the ticket.
        const t = self.target() orelse return .none;
        // Enter goes in a step: card, ticket in full, its session.
        if (key.matches('t', .{}) or (self.detail != null and key.matches(vaxis.Key.enter, .{}))) {
            const s = actions.liveSession(env.ctx, t) orelse {
                self.setMsg(true, "{s} has no session running", .{t.key});
                return .none;
            };
            return .{ .attach = s };
        }
        if (key.matches('m', .{})) {
            self.pending.key.set(t.key);
            self.choice = .stage;
            return .none;
        }
        if (key.matches('<', .{}) or key.matches('>', .{})) {
            const i: usize = @intFromEnum(t.stage);
            const back = key.matches('<', .{});
            if ((back and i == 0) or (!back and i + 1 == stage_count)) return .none;
            return self.move(env, t, @enumFromInt(if (back) i - 1 else i + 1));
        }
        if (key.matches('a', .{})) return self.approve(env, t);
        if (key.matches('A', .{}) or key.matches('a', .{ .shift = true })) {
            if (askFlag(t) == null) {
                self.setMsg(true, "{s} isn't waiting for an answer", .{t.key});
                return .none;
            }
            if (self.detail == null) self.openDetail(t.key);
            self.pending.key.set(t.key);
            self.prompt = .answer;
            return .{ .prompt = .{ .label = try std.fmt.allocPrint(env.a, " answer {s} (option number or your words): ", .{t.key}) } };
        }
        if (key.matches('c', .{})) {
            self.pending.key.set(t.key);
            self.prompt = .note;
            return .{ .prompt = .{ .label = try std.fmt.allocPrint(env.a, " note on {s} (goes with its next prompt): ", .{t.key}) } };
        }
        if (key.matches('s', .{})) {
            self.pending.key.set(t.key);
            self.prompt = .send;
            return .{ .prompt = .{ .label = try std.fmt.allocPrint(env.a, " send to {s}'s session: ", .{t.key}) } };
        }
        return .none;
    }

    /// `n`: a new ticket in the cursor's column (Backlog from Done), in the
    /// selected ticket's project to start with.
    fn startNew(self: *View, env: Env) !Outcome {
        if (self.projects.len == 0) {
            self.setMsg(true, "no projects yet: cl project add <name> <dir>", .{});
            return .none;
        }
        const stage = if (self.cursor.col < self.cols.len) self.cols[self.cursor.col].stage else .backlog;
        self.new_stage = if (stage == .done) .backlog else stage;
        const project = if (self.target()) |t| t.project else for (self.projects) |p| {
            if (!p.hidden) break p.name;
        } else self.projects[0].name;
        self.prompt = .new_project;
        return .{ .prompt = .{ .label = try std.fmt.allocPrint(env.a, " new ticket in {s} - project: ", .{stageName(self.new_stage)}), .prefill = project } };
    }

    fn openDetail(self: *View, key: []const u8) void {
        var k: KeyBuf = .{};
        k.set(key);
        self.detail = k;
        self.detail_scroll = 0;
    }

    fn toggle(self: *View, flag: *bool, on: []const u8, off: []const u8) Outcome {
        flag.* = !flag.*;
        self.setMsg(false, "{s}", .{if (flag.*) on else off});
        return .reload;
    }

    fn scrollTo(self: *View, top: bool) void {
        if (self.detail != null) {
            self.detail_scroll = if (top) 0 else std.math.maxInt(u32);
        } else if (self.in_needs) {
            self.moveNeeds(if (top) -1 else 1, true);
        } else self.cursor.moveRow(self.cols, self.tickets, if (top) -1 else 1, true);
    }

    fn handleChoice(self: *View, env: Env, c: Choice, key: vaxis.Key) !Outcome {
        self.choice = null;
        if (key.matches(vaxis.Key.escape, .{})) return .none;
        const t = board.getTicket(env.db, env.a, self.pending.key.get()) catch |e| return self.fail(e);
        switch (c) {
            .stage => for (std.enums.values(Stage)) |s| {
                if (key.matches(stageKey(s), .{})) return self.move(env, t, s);
            },
            .spin_off => if (key.matches('y', .{})) {
                self.pending.spin_off = true;
                return self.askFinish(env, t);
            },
            .finish => {
                const branch = t.branch.len > 0 or t.change.len > 0;
                if (branch and t.custom_close.len == 0 and key.matches('m', .{})) return self.finish(env, t, .merge);
                if (branch and t.custom_close.len == 0 and key.matches('p', .{})) return self.finish(env, t, .pr);
                if (key.matches('c', .{})) return self.finish(env, t, .close);
                if (key.matches('t', .{})) {
                    self.prompt = .tell;
                    return .{ .prompt = .{ .label = " tell Claude what to do before Done: ", .prefill = t.custom_close } };
                }
                // Anything else asks again rather than closing it unasked.
                self.choice = .finish;
            },
        }
        return .none;
    }

    /// The bottom line while a choice is asked.
    pub fn choiceText(self: *View, a: std.mem.Allocator) !?[]const u8 {
        const c = self.choice orelse return null;
        const key = self.pending.key.get();
        return switch (c) {
            .stage => try std.fmt.allocPrint(a, " move {s} to: [b]acklog [p]lanning [q]ueued [r]unning re[v]iew [t]esting [d]one", .{key}),
            .spin_off => try std.fmt.allocPrint(a, " {s} has unfinished sub-tickets. y spin them off and finish  esc cancel", .{key}),
            .finish => blk: {
                const t = for (self.tickets) |x| {
                    if (std.mem.eql(u8, x.key, key)) break x;
                } else self.full;
                const custom = if (t) |x| x.custom_close else "";
                const branch = if (t) |x| x.branch.len > 0 or x.change.len > 0 else false;
                if (custom.len > 0) break :blk try std.fmt.allocPrint(a, " finish {s}: t tell Claude  c just close  esc cancel · Claude asks: {s}", .{ key, custom });
                if (branch) break :blk try std.fmt.allocPrint(a, " finish {s}: m merge  p open a PR  c just close  t tell Claude  esc cancel", .{key});
                break :blk try std.fmt.allocPrint(a, " finish {s}: c close it  t tell Claude first  esc cancel", .{key});
            },
        };
    }

    fn move(self: *View, env: Env, t: board.Ticket, stage: Stage) !Outcome {
        if (t.stage == stage) return .none;
        if (stage == .done) return self.startDone(env, t, false);
        actions.move(env.ctx, env.cfg, env.db, env.a, t.key, stage, false, .close) catch |e| return self.fail(e);
        self.setMsg(false, "{s} to {s}", .{ t.key, stageName(stage) });
        self.follow(t.key);
        return .reload;
    }

    fn approve(self: *View, env: Env, t: board.Ticket) !Outcome {
        if (t.todo) {
            self.setMsg(true, "{s} is a todo: it's yours, nothing to approve (m d moves it to Done)", .{t.key});
            return .none;
        }
        const to = board.approvedStage(t.stage) orelse {
            self.setMsg(true, "nothing to approve in {s} (planning, testing and review are)", .{stageName(t.stage)});
            return .none;
        };
        if (t.stage == .planning) {
            const ready = for (t.flags) |f| {
                if (std.mem.eql(u8, f.kind, board.flag_review)) break true;
            } else false;
            if (!ready) {
                self.setMsg(true, "{s}'s plan isn't ready yet", .{t.key});
                return .none;
            }
        }
        if (to == .done) return self.startDone(env, t, true);
        _ = actions.approve(env.ctx, env.db, env.a, t.key, false, .close) catch |e| return self.fail(e);
        self.setMsg(false, "{s} approved: to {s}", .{ t.key, stageName(to) });
        self.follow(t.key);
        return .reload;
    }

    /// On its way to Done, as the web board asks: unfinished sub-tickets
    /// first, then how to finish.
    fn startDone(self: *View, env: Env, t: board.Ticket, approving: bool) !Outcome {
        self.pending = .{ .approve = approving };
        self.pending.key.set(t.key);
        // A todo's open tasks carry on under it (actions.readyForDone): nothing to spin off.
        const open: []const board.Ticket = if (t.todo) &.{} else board.openSubtickets(env.db, env.a, t.key) catch |e| return self.fail(e);
        if (open.len > 0) {
            self.choice = .spin_off;
            return .none;
        }
        return self.askFinish(env, t);
    }

    fn askFinish(self: *View, env: Env, t: board.Ticket) !Outcome {
        // Nothing of its own to merge and nothing Claude asked: it just closes.
        if (t.branch.len == 0 and t.change.len == 0 and t.custom_close.len == 0) return self.finish(env, t, .close);
        self.choice = .finish;
        return .none;
    }

    fn finish(self: *View, env: Env, t: board.Ticket, f: actions.Finish) !Outcome {
        const spin = self.pending.spin_off;
        if (self.pending.approve) {
            _ = actions.approve(env.ctx, env.db, env.a, t.key, spin, f) catch |e| return self.fail(e);
        } else {
            actions.move(env.ctx, env.cfg, env.db, env.a, t.key, .done, spin, f) catch |e| return self.fail(e);
        }
        switch (f) {
            .merge => self.setMsg(false, "{s}: Claude is merging it; it goes to Done after", .{t.key}),
            .pr => self.setMsg(false, "{s}: Claude is opening a PR; then it waits on the PR, parked", .{t.key}),
            .tell => self.setMsg(false, "{s}: Claude got your instructions; it goes to Done after", .{t.key}),
            .close => self.setMsg(false, "{s} is done", .{t.key}),
        }
        self.follow(t.key);
        return .reload;
    }

    /// Keep the cursor on a ticket that just moved.
    fn follow(self: *View, key: []const u8) void {
        if (self.detail == null) self.cursor.key.set(key);
    }

    pub fn submit(self: *View, env: Env, text: []const u8) !Outcome {
        const key = self.pending.key.get();
        switch (self.prompt) {
            .search => {
                self.search.set(std.mem.trim(u8, text, " "));
                return .reload;
            },
            .note, .send => {
                if (std.mem.trim(u8, text, " ").len == 0) return .none;
                const send = self.prompt == .send;
                const r = actions.comment(env.ctx, env.db, env.a, key, "you", text, send) catch |e| return self.fail(e);
                if (r.sent_back) {
                    self.setMsg(false, "sent; {s} is back in Running (round {d})", .{ key, r.round });
                } else if (r.unsent) {
                    self.setMsg(false, "{s} has no session yet; saved as a note for its next prompt", .{key});
                } else self.setMsg(false, "{s} {s}", .{ if (send) "sent to" else "noted on", key });
                return .reload;
            },
            .answer => {
                const answers = splitAnswers(env.a, text) catch |e| return self.fail(e);
                actions.answer(env.ctx, env.cfg, env.db, env.a, key, answers) catch |e| return self.fail(e);
                self.setMsg(false, "{s}: Claude got your answer", .{key});
                return .reload;
            },
            .new_project => {
                const name = std.mem.trim(u8, text, " ");
                _ = board.getProject(env.db, env.a, name) catch {
                    var names: std.ArrayList(u8) = .empty;
                    for (self.projects) |p| {
                        if (names.items.len > 0) try names.appendSlice(env.a, ", ");
                        try names.appendSlice(env.a, p.name);
                    }
                    self.setMsg(true, "no project \"{s}\" (there are {s}); not created", .{ name, names.items });
                    return .none;
                };
                self.new_project.set(name);
                self.prompt = .new_title;
                return .{ .prompt = .{ .label = try std.fmt.allocPrint(env.a, " new ticket in {s} - title: ", .{name}) } };
            },
            .new_title => {
                const title = std.mem.trim(u8, text, " ");
                if (title.len == 0) {
                    self.setMsg(true, "no title; not created", .{});
                    return .none;
                }
                self.new_title.set(title);
                self.prompt = .new_body;
                return .{ .prompt = .{ .label = " description (optional): " } };
            },
            .new_body => {
                const stage = self.new_stage;
                const k = board.createTicket(env.ctx, env.db, env.a, .{
                    .project = self.new_project.get(),
                    .title = self.new_title.get(),
                    .body = std.mem.trim(u8, text, " "),
                    .stage = stage,
                    // A ticket made in Planning plans first, as on the web board.
                    .plan = stage == .planning,
                }) catch |e| return self.fail(e);
                self.setMsg(false, "{s} created in {s}", .{ k, stageName(stage) });
                self.follow(k);
                return .reload;
            },
            .tell => {
                const f = actions.Finish.told(text) orelse {
                    self.setMsg(true, "nothing to tell Claude; not finished", .{});
                    return .none;
                };
                const t = board.getTicket(env.db, env.a, key) catch |e| return self.fail(e);
                return self.finish(env, t, f);
            },
        }
    }

    fn fail(self: *View, err: anyerror) Outcome {
        self.setMsg(true, "{s}", .{errText(err)});
        return .reload;
    }

    // ---- drawing ----

    /// Everything but the bottom line (the chooser's).
    /// Returns where the header line's text ends.
    pub fn draw(self: *View, a: std.mem.Allocator, win: vaxis.Window, now: i64) !u16 {
        if (self.detail != null) return self.drawDetail(a, win);
        const bold: vaxis.Style = .{ .bold = true };
        var shown: usize = 0;
        for (self.cols) |c| shown += c.cards.len;
        var hidden_n: usize = 0;
        for (self.projects) |p| if (p.hidden) {
            hidden_n += 1;
        };
        var notes: std.ArrayList(u8) = .empty;
        if (!self.needs_open and self.needs.len > 0) try notes.appendSlice(a, " · N shows what needs you");
        if (self.opts.done) try notes.appendSlice(a, " · with Done");
        if (self.opts.subs) try notes.appendSlice(a, " · with sub-tickets");
        if (!self.opts.parked) try notes.appendSlice(a, " · without parked (P)");
        if (hidden_n > 0) try notes.appendSlice(a, if (self.opts.hidden_projects) " · with hidden projects" else try std.fmt.allocPrint(a, " · {d} hidden project{s} (H)", .{ hidden_n, if (hidden_n == 1) "" else "s" }));
        for (self.projects) |p| if (p.paused) try notes.appendSlice(a, try std.fmt.allocPrint(a, " · {s} paused", .{p.name}));
        if (self.search.len > 0) try notes.appendSlice(a, try std.fmt.allocPrint(a, " · matching \"{s}\"", .{self.search.get()}));
        const header_end = win.print(&.{
            .{ .text = " BOARD  ", .style = bold },
            .{ .text = try std.fmt.allocPrint(a, "{d} ticket{s}", .{ shown, if (shown == 1) "" else "s" }), .style = dim },
            .{ .text = " · ", .style = dim },
            .{ .text = try std.fmt.allocPrint(a, "{d} need{s} you", .{ self.needs.len, if (self.needs.len == 1) "s" else "" }), .style = .{ .fg = if (self.needs.len > 0) .{ .index = 1 } else .default, .dim = self.needs.len == 0 } },
            .{ .text = notes.items, .style = .{ .dim = true, .italic = true } },
        }, .{ .wrap = .none }).col;

        const pane_h = try self.drawNeeds(a, win.child(.{ .y_off = 2, .height = win.height -| 2 }), now);
        if (self.cols.len == 0) return header_end;
        const body = win.child(.{ .y_off = 2 + pane_h, .height = win.height -| 2 -| pane_h });
        const min_w: u16 = 22;
        const fit: usize = @max(1, @min(self.cols.len, body.width / min_w));
        if (self.cursor.col < self.col_off) self.col_off = self.cursor.col;
        if (self.cursor.col >= self.col_off + fit) self.col_off = self.cursor.col + 1 - fit;
        if (self.col_off + fit > self.cols.len) self.col_off = self.cols.len - fit;
        const col_w: u16 = @intCast(body.width / fit);
        for (self.cols[self.col_off..][0..fit], 0..) |c, ci| {
            const x: u16 = @intCast(ci * col_w);
            const col = body.child(.{ .x_off = x, .width = col_w -| 1, .height = body.height });
            try self.drawColumn(a, col, self.col_off + ci, c, now);
        }
        if (self.col_off > 0) _ = body.printSegment(.{ .text = "◀", .style = dim }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
        if (self.col_off + fit < self.cols.len) _ = body.printSegment(.{ .text = "▶", .style = dim }, .{ .row_offset = 0, .col_offset = body.width -| 1, .wrap = .none });
        return header_end;
    }

    /// The Needs you pane at the top of `win`, as tall as it needs up to a
    /// third of the board; returns the rows it took (with a gap under it).
    fn drawNeeds(self: *View, a: std.mem.Allocator, win: vaxis.Window, now: i64) !u16 {
        if (!self.needs_open or self.needs.len == 0) return 0;
        const max_rows: usize = @max(2, win.height / 3);
        const rows: usize = @min(self.needs.len, max_rows);
        self.needs_scroll = keepVisible(self.needs_scroll, self.needs_row, rows, self.needs.len);
        _ = win.print(&.{
            .{ .text = try std.fmt.allocPrint(a, " Needs you {d}", .{self.needs.len}), .style = .{ .bold = true, .fg = .{ .index = 1 }, .ul_style = if (self.in_needs) .single else .off } },
            .{ .text = if (self.in_needs) "  tab back to the board · N folds it" else "  tab steps in · N folds it", .style = dim },
        }, .{ .wrap = .none });
        var widest_key: usize = 0;
        for (self.needs) |t| widest_key = @max(widest_key, ui.cols(t.key));
        for (self.needs[self.needs_scroll..][0..rows], 0..) |t, y| {
            const sel = self.in_needs and self.needs_scroll + y == self.needs_row;
            const row = win.child(.{ .y_off = @intCast(1 + y), .height = 1 });
            if (sel) row.fill(.{ .style = .{ .reverse = true } });
            const f = needsFlag(t) orelse t.flags[0];
            const hint = askHint(t, f);
            const age = try ui.ageText(a, now - f.at);
            const key_pad = try a.alloc(u8, widest_key - ui.cols(t.key) + 2);
            @memset(key_pad, ' ');
            const label = try std.fmt.allocPrint(a, "{s:<11}", .{flagLabel(f)});
            // " KEY  label  ask · title    hint  age"
            const tail = try std.fmt.allocPrint(a, "  {s}  {s:>3} ", .{ hint, age });
            const fixed = 1 + ui.cols(t.key) + key_pad.len + ui.cols(label) + 1 + ui.cols(tail);
            const room = row.width -| @as(u16, @intCast(@min(fixed, row.width)));
            const ask = try askLine(a, t, f);
            const what = try ui.truncate(a, try std.fmt.allocPrint(a, "{s}  · {s}", .{ ask, t.title }), room);
            var segs = [_]vaxis.Segment{
                .{ .text = " " },
                .{ .text = t.key, .style = .{ .bold = true } },
                .{ .text = key_pad },
                .{ .text = label, .style = .{ .fg = flagColor(f.kind), .bold = true } },
                .{ .text = " " },
                .{ .text = what },
            };
            if (sel) for (&segs) |*sg| {
                sg.style.reverse = true;
            };
            _ = row.print(&segs, .{ .wrap = .none });
            _ = row.printSegment(.{ .text = tail, .style = .{ .dim = true, .reverse = sel } }, .{ .col_offset = row.width -| @as(u16, @intCast(ui.cols(tail))), .wrap = .none });
        }
        if (self.needs.len > rows) {
            const more = try std.fmt.allocPrint(a, " {d}-{d} of {d} ", .{ self.needs_scroll + 1, self.needs_scroll + rows, self.needs.len });
            _ = win.printSegment(.{ .text = more, .style = dim }, .{ .col_offset = win.width -| @as(u16, @intCast(more.len)), .wrap = .none });
        }
        return @intCast(1 + rows + 1);
    }

    const card_h = 5; // four lines and a gap

    fn drawColumn(self: *View, a: std.mem.Allocator, col: vaxis.Window, ci: usize, c: Column, now: i64) !void {
        const here = ci == self.cursor.col and !self.in_needs;
        const title = try std.fmt.allocPrint(a, " {s} {d}", .{ stageName(c.stage), c.cards.len });
        _ = col.printSegment(.{ .text = title, .style = .{ .bold = true, .reverse = here and c.cards.len == 0, .ul_style = if (here) .single else .off } }, .{ .wrap = .none });
        const cards = col.child(.{ .y_off = 2, .height = col.height -| 2 });
        const fits: usize = @max(1, (cards.height + 1) / card_h);
        const si = @intFromEnum(c.stage);
        if (here) self.scroll[si] = keepVisible(self.scroll[si], self.cursor.row, fits, c.cards.len);
        self.scroll[si] = @min(self.scroll[si], c.cards.len -| fits);
        const first = self.scroll[si];
        const last = @min(c.cards.len, first + fits);
        for (c.cards[first..last], 0..) |ti, n| {
            const sel = here and first + n == self.cursor.row;
            const card = cards.child(.{ .y_off = @intCast(n * card_h), .height = card_h - 1 });
            try self.drawCard(a, card, self.tickets[ti], sel, now);
        }
        if (first > 0) _ = col.printSegment(.{ .text = try std.fmt.allocPrint(a, "↑{d}", .{first}), .style = dim }, .{ .row_offset = 0, .col_offset = col.width -| 4, .wrap = .none });
        if (last < c.cards.len) _ = col.printSegment(.{ .text = try std.fmt.allocPrint(a, "↓{d}", .{c.cards.len - last}), .style = dim }, .{ .row_offset = col.height -| 1, .col_offset = col.width -| 4, .wrap = .none });
    }

    fn drawCard(self: *View, a: std.mem.Allocator, card: vaxis.Window, t: board.Ticket, sel: bool, now: i64) !void {
        const st = cardStatus(t, self.live.get(t.tmux), projectPaused(self.projects, t.project));
        const w: usize = card.width;
        if (sel) card.fill(.{ .style = .{ .reverse = true } });
        const age = try ui.ageText(a, now - t.updated);
        const row1 = card.child(.{ .height = 1 });
        var segs = [_]vaxis.Segment{
            .{ .text = if (st.live()) "●" else "○", .style = .{ .fg = st.color() } },
            .{ .text = " " },
            .{ .text = t.key, .style = .{ .bold = true } },
            .{ .text = if (t.parent.len > 0) try std.fmt.allocPrint(a, " ↳{s}", .{t.parent}) else "", .style = dim },
            .{ .text = if (t.children > 0) try std.fmt.allocPrint(a, " {d}/{d}", .{ t.children_done, t.children }) else "", .style = dim },
        };
        if (sel) for (&segs) |*s| {
            s.style.reverse = true;
        };
        _ = row1.print(&segs, .{ .wrap = .none });
        _ = row1.printSegment(.{ .text = age, .style = .{ .dim = true, .reverse = sel } }, .{ .col_offset = @intCast(w -| age.len), .wrap = .none });
        // The title on two lines, cut short after that.
        const title = try wrap(a, &.{.{ .text = t.title }}, w);
        for (title[0..@min(title.len, 2)], 0..) |l, i| {
            const text = if (i == 1 and title.len > 2) try ui.truncate(a, t.title[@intFromPtr(l.text.ptr) - @intFromPtr(t.title.ptr) ..], w) else l.text;
            _ = card.printSegment(.{ .text = text, .style = .{ .reverse = sel } }, .{ .row_offset = @intCast(1 + i), .wrap = .none });
        }
        // Last line: what it needs (flags), else where it is.
        var line3: std.ArrayList(vaxis.Segment) = .empty;
        var used: usize = 0;
        if (t.park) |p| {
            try line3.append(a, .{ .text = try ui.truncate(a, try std.fmt.allocPrint(a, "parked: {s}", .{p.reason}), w), .style = .{ .fg = .{ .index = 5 } } });
            used = w;
        }
        if (t.finishing.len > 0 and used < w) {
            try line3.append(a, .{ .text = "finishing ", .style = .{ .fg = .{ .index = 2 } } });
            used += "finishing ".len;
        }
        for (t.flags) |f| {
            if (used >= w) break;
            const s = try ui.truncate(a, try std.fmt.allocPrint(a, "{s} ", .{flagLabel(f)}), w - used);
            try line3.append(a, .{ .text = s, .style = .{ .fg = flagColor(f.kind), .bold = !f.hidden, .dim = f.hidden } });
            used += ui.cols(s);
        }
        if (line3.items.len == 0) try line3.append(a, .{ .text = st.label(), .style = .{ .fg = st.color(), .dim = !st.live() } });
        if (sel) for (line3.items) |*s| {
            s.style.reverse = true;
        };
        _ = card.child(.{ .y_off = 3, .height = 1 }).print(line3.items, .{ .wrap = .none });
    }

    fn drawDetail(self: *View, a: std.mem.Allocator, win: vaxis.Window) !u16 {
        const t = self.full orelse return 0;
        const header_end = win.print(&.{
            .{ .text = " " },
            .{ .text = t.key, .style = .{ .bold = true } },
            .{ .text = "  " },
            .{ .text = try ui.truncate(a, t.title, win.width -| @as(u16, @intCast(ui.cols(t.key) + 4))), .style = .{ .bold = true } },
        }, .{ .wrap = .none }).col;
        // The session's pane below, when it has one, as the chooser shows it.
        const pane_h: u16 = if (self.preview.len > 0) @min(@as(u16, @intCast(self.preview.len)), (win.height -| 2) / 2) else 0;
        const text_h: u16 = win.height -| 2 -| (if (pane_h > 0) pane_h + 1 else 0);
        const text = win.child(.{ .x_off = 1, .y_off = 2, .width = win.width -| 2, .height = text_h });
        const lines = try wrap(a, self.full_lines, text.width);
        self.detail_scroll = @min(self.detail_scroll, lines.len -| text_h);
        for (lines[self.detail_scroll..@min(lines.len, self.detail_scroll + text_h)], 0..) |l, y| {
            _ = text.printSegment(.{ .text = l.text, .style = l.style }, .{ .row_offset = @intCast(y), .col_offset = l.indent, .wrap = .none });
        }
        if (lines.len > text_h) {
            const pos = try std.fmt.allocPrint(a, " {d}/{d} ", .{ @min(lines.len, self.detail_scroll + text_h), lines.len });
            // Under the header: the operator's alert may take its right end.
            _ = win.printSegment(.{ .text = pos, .style = dim }, .{ .row_offset = 1, .col_offset = win.width -| @as(u16, @intCast(pos.len)), .wrap = .none });
        }
        if (pane_h == 0) return header_end;
        const sep_y: u16 = 2 + text_h;
        var x: u16 = 0;
        while (x < win.width) : (x += 1) win.writeCell(x, sep_y, .{ .char = .{ .grapheme = "─" }, .style = dim });
        _ = win.printSegment(.{ .text = try std.fmt.allocPrint(a, " {s} · enter opens it ", .{t.tmux}), .style = dim }, .{ .row_offset = sep_y, .col_offset = 1, .wrap = .none });
        const pane = win.child(.{ .y_off = sep_y + 1, .height = pane_h });
        const shown = self.preview[self.preview.len - pane_h ..];
        for (shown, 0..) |segs, py| _ = pane.child(.{ .y_off = @intCast(py), .height = 1 }).print(segs, .{ .wrap = .none });
        return header_end;
    }

    /// The keys, most used first (the bottom line shows what fits).
    pub fn help(self: *const View) []const []const u8 {
        if (self.detail != null) return &.{
            "enter/t its session", "j/k scroll",       "a approve", "A answer",    "m move",     "</> stage back/on",
            "c note",              "s send to session", "o operator", "gg/G top/end", "esc back",
        };
        return &.{
            "enter details",  "t session",        "n new ticket",       "a approve",       "A answer",
            "m move",         "</> stage back/on", "c note",            "s send to session", "o operator",
            "tab needs you/board", "N fold needs you", "D done column",    "S sub-tickets",      "H hidden projects", "P parked", "/ search",
            "h/j/k/l move",   "gg/G top/bottom",  "esc back to sessions",
        };
    }
};

/// The last `rows` lines of a pane, colors kept (as the chooser's preview).
fn capturePane(env: Env, tmux_name: []const u8, rows: usize) ![][]sgr.Segment {
    const raw = tmux.capture(env.ctx, tmux_name, rows) catch return &.{};
    defer env.ctx.gpa.free(raw);
    var lines: std.ArrayList([]sgr.Segment) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\n "), '\n');
    var style: vaxis.Style = .{};
    while (it.next()) |line| {
        const segs = try sgr.parseLine(env.a, try env.a.dupe(u8, line), style);
        if (segs.len > 0) style = segs[segs.len - 1].style;
        try lines.append(env.a, segs);
    }
    const all = lines.items;
    return if (all.len > rows) all[all.len - rows ..] else all;
}

/// What went wrong, in the words the web board uses.
pub fn errText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "no such ticket",
        error.BadInput => "invalid input",
        error.NoSession => "the ticket has no live session",
        error.NothingAsked => "nothing is waiting for an answer",
        error.BadAnswer => "one answer per question, separated by |: an option number or your own words (\"1,3\" for a multi-select one)",
        error.NotDelivered => "Claude didn't take the answer; it's still waiting. Check the session (o)",
        error.Umbrella => "it's an umbrella: its sub-tickets run, not it",
        error.Todo => board.todo_refused,
        error.NoSubtickets => actions.no_subtickets,
        error.OpenSubtickets => "it has sub-tickets that aren't done yet; finish them or spin them off",
        error.CustomClose => "Claude asked to close it its own way; tell Claude, or just close it",
        error.Conflicts => "merging it back conflicts (the files are on the ticket); it stays in Review",
        error.SharedSession => "another ticket is in progress in its session, so stopping it would cut that one off",
        error.Starting => "it is starting right now; try again in a moment",
        error.Busy => "Claude is working in its session or waiting on you; it can move once it is idle",
        error.MergeFailed => "jj couldn't merge it",
        else => @errorName(err),
    };
}

// ---- tests ----

const testing = std.testing;

const test_cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };

fn testTicket(key: []const u8, stage: Stage, rank: i64) board.Ticket {
    return .{
        .id = rank,          .key = key,      .project = "qa",  .title = key,   .body = "",       .stage = stage,
        .mode = .queue,      .plan = false,   .skill = "",      .target = "",   .worktree = "",   .branch = "",
        .profile = "",       .tmux = "",      .session_id = "", .summary = "",  .round = 1,       .created = 0,
        .updated = 0,        .parent = "",    .children = 0,    .rank = rank,
    };
}

test "columns: by stage in rank order; Done, sub-tickets and hidden projects only when asked, parked unless hidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ts = [_]board.Ticket{
        testTicket("QA-1", .queued, 30),
        testTicket("QA-2", .queued, 10),
        testTicket("QA-3", .done, 5),
        testTicket("QA-4", .running, 1),
        testTicket("QA-5", .queued, 20),
        testTicket("WEB-1", .queued, 15),
    };
    ts[4].parent = "QA-1";
    ts[5].project = "web";
    const projects = [_]board.Project{
        .{ .name = "qa", .dir = "/x", .prefix = "QA", .slots = 1, .mode = .queue, .profile = "" },
        .{ .name = "web", .dir = "/y", .prefix = "WEB", .slots = 1, .mode = .queue, .profile = "", .hidden = true },
    };
    const cols = try columns(a, &ts, &projects, .{});
    try testing.expectEqual(@as(usize, 6), cols.len);
    try testing.expectEqual(Stage.queued, cols[2].stage);
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, cols[2].cards);
    try testing.expectEqualSlices(usize, &.{3}, cols[3].cards);

    const all = try columns(a, &ts, &projects, .{ .done = true, .subs = true, .hidden_projects = true });
    try testing.expectEqual(@as(usize, 7), all.len);
    try testing.expectEqualSlices(usize, &.{ 1, 5, 4, 0 }, all[2].cards);
    try testing.expectEqualSlices(usize, &.{2}, all[6].cards);

    ts[0].park = .{ .reason = "PR", .at = 0 };
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, (try columns(a, &ts, &projects, .{}))[2].cards);
    try testing.expectEqualSlices(usize, &.{1}, (try columns(a, &ts, &projects, .{ .parked = false }))[2].cards);


    const found = try columns(a, &ts, &projects, .{ .search = "qa-2" });
    try testing.expectEqualSlices(usize, &.{1}, found[2].cards);
    try testing.expectEqual(@as(usize, 0), found[3].cards.len);
}

test "Needs you lists what cl ticket needs does, and actions go to its row" {
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try board.addProject(db, .{ .name = "web", .dir = "/x/web" });
    const asking = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Asking", .stage = .running });
    const sub = try board.createTicket(ctx, db, a, .{ .parent = asking, .title = "Sub, in review", .stage = .review });
    _ = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Quiet", .stage = .running });
    const hidden = try board.createTicket(ctx, db, a, .{ .project = "web", .title = "Hidden project", .stage = .review });
    const tucked = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Hidden from needs", .stage = .queued });
    try board.setFlag(ctx, db, a, asking, board.flag_question, "auto", "{}");
    try board.done(ctx, db, a, sub, "did it");
    try board.done(ctx, db, a, hidden, "did it");
    try board.setFlag(ctx, db, a, tucked, "start-failed", "auto", "");
    _ = try board.hideNeeds(ctx, db, a, tucked, true);
    try board.setProjectHidden(db, "web", true);
    const env: Env = .{ .ctx = ctx, .cfg = test_cfg, .db = db, .a = a, .sessions = &.{}, .statuses = .empty };

    var v: View = .{};
    try v.load(env);
    const want = try board.listTickets(db, a, .{ .needs = true, .shown = true });
    try testing.expectEqual(@as(usize, 2), want.len);
    try testing.expectEqual(want.len, v.needs.len);
    for (want, v.needs) |w, got| try testing.expectEqualStrings(w.key, got.key);
    // The sub-ticket is in Needs you though the columns leave it out.
    var n: usize = 0;
    for (v.cols) |c| n += c.cards.len;
    try testing.expectEqual(@as(usize, 3), n);

    // Tab steps into the pane: the selected row is what actions act on.
    const tab: vaxis.Key = .{ .codepoint = vaxis.Key.tab };
    _ = try v.handleKey(env, tab);
    try testing.expect(v.in_needs);
    try testing.expectEqualStrings(want[0].key, v.target().?.key);
    _ = try v.handleKey(env, .{ .codepoint = 'j' });
    try testing.expectEqualStrings(want[1].key, v.target().?.key);
    // Down off its end goes back to the columns.
    _ = try v.handleKey(env, .{ .codepoint = 'j' });
    try testing.expect(!v.in_needs);

    // Hidden projects shown: theirs need you too.
    v.opts.hidden_projects = true;
    try v.load(env);
    try testing.expectEqual(@as(usize, 3), v.needs.len);

    // A todo's reminder or due date goes last, even when it asked first.
    v.opts.hidden_projects = false;
    const todo = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Mine", .todo = true });
    try board.setFlag(ctx, db, a, todo, board.flag_due, "auto", "due today");
    try db.exec("UPDATE flags SET at = 1 WHERE kind = 'due'", .{});
    try v.load(env);
    try testing.expectEqual(@as(usize, 3), v.needs.len);
    try testing.expectEqualStrings(todo, v.needs[2].key);
    try testing.expectEqualStrings("m d done", askHint(v.needs[2], needsFlag(v.needs[2]).?));
}

test askLine {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = testTicket("QA-1", .review, 1);
    t.summary = "Fixed the race";
    const q: board.Flag = .{ .kind = "question", .source = "auto", .at = 0, .detail =
        \\{"kind":"question","questions":[{"question":"Which DB?","options":[{"label":"Staging"},{"label":"Prod"}]}],"options":[]}
    };
    try testing.expectEqualStrings("Which DB? — 1 Staging · 2 Prod", try askLine(a, t, q));
    const p: board.Flag = .{ .kind = "input", .source = "auto", .at = 0, .detail =
        \\{"kind":"permission","tool":"Bash","summary":"rm -rf zig-out","options":[{"n":1,"label":"Yes"},{"n":2,"label":"No"}]}
    };
    try testing.expectEqualStrings("Wants permission: Bash: rm -rf zig-out — 1 Yes · 2 No", try askLine(a, t, p));
    try testing.expectEqualStrings("Ready for review: Fixed the race", try askLine(a, t, .{ .kind = "review", .source = "auto", .at = 0, .detail = "" }));
    try testing.expectEqualStrings("Plan ready for approval", try askLine(a, t, .{ .kind = "review", .source = "auto", .at = 0, .detail = "plan" }));
    try testing.expectEqualStrings("Ready to test: Fixed the race", try askLine(a, t, .{ .kind = "testing", .source = "auto", .at = 0, .detail = "" }));
    // Test first, review last: the columns (and < >) go Running, Testing, Review, Done.
    const order = std.enums.values(Stage);
    try testing.expectEqualStrings("Running Testing Review Done", try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ stageName(order[3]), stageName(order[4]), stageName(order[5]), stageName(order[6]) }));
    try testing.expectEqualStrings("Merging it back conflicts in: src/a.zig, b.md", try askLine(a, t, .{ .kind = "conflict", .source = "auto", .at = 0, .detail = "src/a.zig (content)\nb.md\n" }));
    try testing.expectEqualStrings("After-merge command failed: make: error 2", try askLine(a, t, .{ .kind = "after-merge", .source = "auto", .at = 0, .detail = "make: error 2\nmore" }));
    try testing.expectEqualStrings("Push after merge failed: couldn't push trunk to origin: rejected", try askLine(a, t, .{ .kind = "push-failed", .source = "auto", .at = 0, .detail = "couldn't push trunk to origin: rejected\nmore" }));
    try testing.expectEqualStrings("CI failed at abc: ci (test-macos)", try askLine(a, t, .{ .kind = "ci-failed", .source = "auto", .at = 0, .detail = "CI failed at abc: ci (test-macos)\nhttps://x\ncommit abc" }));
    try testing.expectEqualStrings("my own words", try askLine(a, t, .{ .kind = "note", .source = "manual", .at = 0, .detail = "my own\nwords" }));
}

test "the cursor stays on its ticket as the board changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ts = [_]board.Ticket{ testTicket("QA-1", .queued, 1), testTicket("QA-2", .queued, 2), testTicket("QA-3", .running, 3) };
    var cols = try columns(a, &ts, &.{}, .{});
    var c: Cursor = .{};
    c.restore(cols, &ts);
    try testing.expectEqualStrings("", c.key.get()); // Backlog is empty
    c.moveCol(cols, &ts, 2);
    try testing.expectEqualStrings("QA-1", c.key.get());
    c.moveRow(cols, &ts, 1, false);
    try testing.expectEqualStrings("QA-2", c.key.get());
    c.moveRow(cols, &ts, 5, false);
    try testing.expectEqualStrings("QA-2", c.key.get());
    c.moveCol(cols, &ts, 1);
    try testing.expectEqualStrings("QA-3", c.key.get());
    try testing.expectEqual(@as(usize, 0), c.row);

    // QA-2 moves on to Running, ahead of QA-3: the cursor goes with it.
    c.moveCol(cols, &ts, -1);
    c.moveRow(cols, &ts, 1, false);
    ts[1].stage = .running;
    cols = try columns(a, &ts, &.{}, .{});
    c.restore(cols, &ts);
    try testing.expectEqual(@as(usize, 3), c.col);
    try testing.expectEqual(@as(usize, 0), c.row);
    try testing.expectEqualStrings("QA-2", c.key.get());

    // Gone from the board: the same place, kept inside the column.
    ts[1].stage = .done;
    cols = try columns(a, &ts, &.{}, .{});
    c.restore(cols, &ts);
    try testing.expectEqual(@as(usize, 3), c.col);
    try testing.expectEqualStrings("QA-3", c.key.get());
}

test keepVisible {
    try testing.expectEqual(@as(usize, 0), keepVisible(0, 2, 5, 10));
    try testing.expectEqual(@as(usize, 3), keepVisible(0, 7, 5, 10));
    try testing.expectEqual(@as(usize, 2), keepVisible(4, 2, 5, 10));
    // Scrolled past the end after cards left: pulled back.
    try testing.expectEqual(@as(usize, 1), keepVisible(6, 3, 5, 6));
    try testing.expectEqual(@as(usize, 0), keepVisible(3, 0, 5, 2));
}

test splitAnswers {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualDeep(@as([]const []const u8, &.{"2"}), try splitAnswers(a, " 2 "));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "1,3", "use the staging DB" }), try splitAnswers(a, "1,3 | use the staging DB"));
    try testing.expectError(error.BadAnswer, splitAnswers(a, "1 ||"));
    try testing.expectError(error.BadAnswer, splitAnswers(a, ""));
}

test cardStatus {
    var t = testTicket("QA-1", .running, 1);
    try testing.expectEqual(CardStatus.not_started, cardStatus(t, null, false));
    t.tmux = "cl_qa_1";
    try testing.expectEqual(CardStatus.gone, cardStatus(t, null, false));
    try testing.expectEqual(CardStatus.working, cardStatus(t, .busy, false));
    try testing.expectEqual(CardStatus.waiting, cardStatus(t, .blocked, false));
    t.tmux = "(starting)";
    try testing.expectEqual(CardStatus.starting, cardStatus(t, null, false));
    t.tmux = "";
    t.killed = true;
    try testing.expectEqual(CardStatus.killed, cardStatus(t, null, false));
    t.stage = .queued;
    t.killed = false;
    try testing.expectEqual(CardStatus.waiting_slot, cardStatus(t, null, false));
    // In a paused project it says so rather than waiting for a slot.
    try testing.expectEqual(CardStatus.paused, cardStatus(t, null, true));
    // Waiting on another ticket, or running as its sub-tickets: not on a slot.
    var deps = [_]board.Dep{.{ .id = 2, .key = "QA-2", .title = "First", .stage = .running }};
    t.blocked_by = &deps;
    try testing.expectEqual(CardStatus.blocked, cardStatus(t, null, false));
    deps[0].stage = .done;
    try testing.expectEqual(CardStatus.waiting_slot, cardStatus(t, null, false));
    t.umbrella = true;
    try testing.expectEqual(CardStatus.umbrella, cardStatus(t, null, false));
    t.umbrella = false;
    // A todo says where you are with it, not what Claude is doing.
    t.todo = true;
    t.stage = .backlog;
    try testing.expectEqual(CardStatus.todo, cardStatus(t, null, false));
    t.stage = .running;
    try testing.expectEqual(CardStatus.doing, cardStatus(t, null, false));
    // An old kill doesn't hide where you are with it.
    t.killed = true;
    try testing.expectEqual(CardStatus.doing, cardStatus(t, null, false));
    t.killed = false;
    t.todo = false;
    t.stage = .done;
    t.tmux = "cl_qa_1";
    try testing.expectEqual(CardStatus.done, cardStatus(t, null, false));
}

test wrap {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try wrap(a, &.{
        .{ .text = "the quick brown fox jumps", .indent = 2 },
        .{ .text = "line one\n\nline three" },
        .{ .text = "abcdefghijklmnop" },
    }, 12);
    const want = [_][]const u8{ "the quick", "brown fox", "jumps", "line one", "", "line three", "abcdefghijkl", "mnop" };
    try testing.expectEqual(want.len, out.len);
    for (want, out) |w, o| try testing.expectEqualStrings(w, o.text);
    try testing.expectEqual(@as(u16, 2), out[1].indent);
}

test "details show what a question asks, with its options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = testTicket("QA-1", .running, 1);
    var flags = [_]board.Flag{.{ .kind = "question", .source = "auto", .at = 0, .detail =
        \\{"kind":"question","tool":"AskUserQuestion","questions":[{"question":"Which DB?","header":"DB","multiSelect":false,"options":[{"label":"Staging","description":"safe"},{"label":"Prod"}]}],"options":[]}
    }};
    t.flags = &flags;
    const lines = try detailLines(a, 100, t, .waiting, &.{}, &.{}, &.{});
    var text: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try text.appendSlice(a, l.text);
        try text.append(a, '\n');
    }
    try testing.expect(std.mem.indexOf(u8, text.items, "DB: Which DB?\n") != null);
    try testing.expect(std.mem.indexOf(u8, text.items, "1. Staging — safe\n") != null);
    try testing.expect(std.mem.indexOf(u8, text.items, "2. Prod\n") != null);
}

test "n makes a ticket in the cursor's column, asking project, title and description" {
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    _ = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Already planning", .stage = .planning });
    const env: Env = .{ .ctx = ctx, .cfg = test_cfg, .db = db, .a = a, .sessions = &.{}, .statuses = .empty };
    var v: View = .{};
    try v.load(env);
    v.cursor.moveCol(v.cols, v.tickets, 1); // Planning, on QA-1

    const first = try v.startNew(env);
    try testing.expectEqualStrings("qa", first.prompt.prefill);
    try testing.expect(std.mem.indexOf(u8, first.prompt.label, "Planning") != null);
    // A project that doesn't exist stops it there.
    try testing.expectEqual(Outcome.none, try v.submit(env, "nope"));
    try testing.expect(v.msg_err);

    _ = try v.startNew(env);
    _ = (try v.submit(env, "qa")).prompt;
    _ = (try v.submit(env, "Plan the export")).prompt;
    try testing.expectEqual(Outcome.reload, try v.submit(env, "CSV, with quoting"));
    const t = try board.getTicket(db, a, "QA-2");
    try testing.expectEqualStrings("Plan the export", t.title);
    try testing.expectEqualStrings("CSV, with quoting", t.body);
    try testing.expectEqual(Stage.planning, t.stage);
    try testing.expect(t.plan);
    try v.load(env);
    try testing.expectEqualStrings("QA-2", v.cursor.key.get());
}
