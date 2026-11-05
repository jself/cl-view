//! Ticket actions that reach into a session (typing, keys), shared by
//! `cl ticket` and the web board so both do exactly the same thing.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const review = @import("review.zig");
const worktree = @import("worktree.zig");
const config = @import("config.zig");
const signals = @import("signals.zig");

pub const Error = error{
    /// The ticket has no live session to act on.
    NoSession,
    /// Nothing is waiting for an answer.
    NothingAsked,
    /// The answers don't fit what is asked.
    BadAnswer,
    /// The answer was typed but the session still waits on the same thing.
    NotDelivered,
    /// No review submitted in gutter.
    NoReview,
    /// It has sub-tickets that aren't Done; spin them off to finish it.
    OpenSubtickets,
    /// `done --close` on a ticket that isn't finishing.
    NotFinishing,
    /// Its change conflicts with trunk (the ticket has the "conflict" flag).
    Conflicts,
    /// jj couldn't merge it (`worktree.lastError()` says why).
    MergeFailed,
};

fn liveSession(ctx: Ctx, t: board.Ticket) ?[]const u8 {
    if (t.tmux.len == 0 or t.tmux[0] == '(' or !tmux.hasSession(ctx, t.tmux)) return null;
    return t.tmux;
}

pub const CommentResult = struct {
    /// Typed into the session.
    sent: bool = false,
    /// Sending was asked for but the ticket has no session yet.
    unsent: bool = false,
    /// It was in review or testing and went back to running.
    sent_back: bool = false,
    round: i64 = 1,
};

/// Add a comment; with `send`, also type it into the ticket's session.
pub fn comment(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, author: []const u8, text: []const u8, send: bool) !CommentResult {
    var r: CommentResult = .{};
    if (send) {
        const t = try board.getTicket(db, a, key);
        if (liveSession(ctx, t)) |s| {
            try tmux.sendLine(ctx, s, text);
            r.sent = true;
        } else r.unsent = true;
    }
    const br = try board.addComment(ctx, db, a, key, author, text, r.sent);
    r.sent_back = br.sent_back;
    r.round = (try board.getTicket(db, a, key)).round;
    return r;
}

/// Before a ticket goes to Done: refuse while it has unfinished sub-tickets,
/// unless `spin_off` makes them tickets of their own.
fn readyForDone(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, spin_off: bool) !void {
    if ((try board.openSubtickets(db, a, key)).len == 0) return;
    if (!spin_off) return error.OpenSubtickets;
    try board.spinOff(ctx, db, a, key);
}

/// What going to Done does with a ticket's branch.
pub const Finish = enum {
    /// Nothing: move it to Done and close the session.
    close,
    /// Merge the branch into the main branch first: cl does it for a jj
    /// change (Claude settles conflicts), Claude does it for a git branch.
    merge,
    /// Claude pushes the branch and opens a PR first.
    pr,

    pub fn parse(s: []const u8) ?Finish {
        return std.meta.stringToEnum(Finish, s);
    }
};

/// Move a ticket. Reaching Done closes its session; with `finish` merge or
/// pr, a ticket with a branch of its own first stays put while Claude merges
/// or opens the PR, and goes to Done when it runs `cl ticket done --close`.
pub fn move(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, stage: board.Stage, spin_off: bool, finish: Finish) !void {
    if (stage == .done) {
        try readyForDone(ctx, db, a, key, spin_off);
        if (try startFinish(ctx, db, a, key, finish)) return;
    }
    try board.move(ctx, db, a, key, stage);
    if (stage == .done) try closeSession(ctx, db, a, key);
}

/// Type the merge or PR instruction into the ticket's session; false when
/// there is nothing to do first (just close, or no branch of its own).
fn startFinish(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, finish: Finish) !bool {
    if (finish == .close) return false;
    const t = try board.getTicket(db, a, key);
    const dir = (try board.getProject(db, a, t.project)).dir;
    if (finish == .merge and t.change.len > 0) return mergeBack(ctx, db, a, t, dir);
    if (finish == .merge and t.mode == .queue and t.branch.len == 0 and t.base.len > 0) {
        if (try adoptStray(ctx, db, a, t, dir)) |owned| return mergeBack(ctx, db, a, owned, dir);
    }
    if (t.branch.len == 0) return false;
    const s = liveSession(ctx, t) orelse return error.NoSession;
    const main = worktree.mainBranch(ctx, a, dir);
    const text = switch (finish) {
        .close => unreachable,
        .merge => try std.fmt.allocPrint(a, "This ticket is approved. Finish it by merging its branch {s} into {s}: commit anything left here first, then merge it in the project's checkout at {s} (it may have uncommitted work of its own; leave that alone). If it conflicts in a way you can't settle with confidence, or anything is unclear, ask me. Once it is merged, rebuild and restart whatever runs from that checkout (dev servers, an installed build; the project's CLAUDE.md may say how) so it serves the merged code, then run `cl ticket done {s} --close`.", .{ t.branch, main, dir, t.key }),
        .pr => if (t.change.len > 0)
            try std.fmt.allocPrint(a, "This ticket is approved. Finish it with a pull request: push its jj bookmark {s} (`jj git push -b {s}`) and open a PR against {s} (gh pr create --head {s}) with a title and description of the change. If anything is unclear, ask me. Then run `cl ticket done {s} --close --pr-url <the PR's URL>`.", .{ t.branch, t.branch, main, t.branch, t.key })
        else
            try std.fmt.allocPrint(a, "This ticket is approved. Finish it with a pull request: commit anything left, push its branch {s} and open a PR against {s} (gh pr create) with a title and description of the change. If anything is unclear, ask me. Then run `cl ticket done {s} --close --pr-url <the PR's URL>`.", .{ t.branch, main, t.key }),
    };
    // Finishing first, so the sent comment doesn't send it back to Running.
    try board.setFinishing(ctx, db, t.id, @tagName(finish));
    try tmux.sendLine(ctx, s, text);
    _ = try board.addComment(ctx, db, a, key, "you", text, true);
    return true;
}

/// A queue ticket with no change of its own (it ran before tickets had
/// them) whose work sits uncommitted in the project's checkout: that work
/// becomes its change, so approving it merges the work instead of closing
/// the ticket and leaving it behind. null when the checkout holds none.
fn adoptStray(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8) !?board.Ticket {
    const trunk = worktree.trunkBookmark(ctx, a, dir) orelse return null;
    _ = worktree.strayWork(ctx, a, dir, trunk) orelse return null;
    const desc = try std.fmt.allocPrint(a, "{s}: {s}", .{ t.key, t.title });
    const c = worktree.adoptChange(ctx, a, dir, desc, try worktree.slug(a, t.key, t.title)) catch {
        try board.logEvent(ctx, db, t.id, "merge failed", worktree.lastError());
        return error.MergeFailed;
    };
    try board.setChange(db, t.id, c.id, c.bookmark);
    try board.logEvent(ctx, db, t.id, "adopted change", c.id);
    var owned = t;
    owned.change = c.id;
    owned.branch = c.bookmark;
    return owned;
}

/// Merge the ticket's jj change back into trunk (see `worktree.mergeChange`).
/// True when the ticket stays put, finishing, while Claude settles
/// conflicts or restarts what runs from the checkout; false when it can go
/// to Done now.
fn mergeBack(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8) !bool {
    const trunk = worktree.trunkBookmark(ctx, a, dir) orelse {
        try board.logEvent(ctx, db, t.id, "merge failed", "no trunk bookmark");
        return error.MergeFailed;
    };
    const before = worktree.workingCommit(ctx, a, dir) catch "";
    if (!try merge(ctx, db, a, t, dir, trunk)) {
        const s = liveSession(ctx, t) orelse return error.Conflicts;
        const list = conflictFlag(try board.getTicket(db, a, t.key)) orelse "";
        return try tell(ctx, db, a, t, s, try std.fmt.allocPrint(a, "This ticket is approved, but its change conflicts with {s}: cl rebased it onto {s}, and jj recorded the conflicts in the change, in:\n{s}\nResolve them there: edit the conflict markers out, keeping what both sides meant (`jj resolve --list` shows what's left). If one can't be settled with confidence, ask me. Then rebuild and restart whatever runs from the project's checkout (the project's CLAUDE.md may say how), and run `cl ticket done {s} --close`; cl merges it then.", .{ trunk, trunk, list, t.key }));
    }
    // The checkout's files changed (trunk had moved on, or it caught up with
    // the merge): what runs from it needs restarting, by Claude while it is there.
    if (before.len > 0 and worktree.filesDiffer(ctx, a, dir, before)) {
        if (liveSession(ctx, t)) |s| return try tell(ctx, db, a, t, s, try std.fmt.allocPrint(a, "This ticket is approved and cl merged it into {s}, so the project's checkout at {s} has new code. Rebuild and restart whatever runs from that checkout (dev servers, an installed build; the project's CLAUDE.md may say how), then run `cl ticket done {s} --close`.", .{ trunk, dir, t.key }));
    }
    return false;
}

/// The conflicted files, while merging the ticket's change conflicts.
fn conflictFlag(t: board.Ticket) ?[]const u8 {
    for (t.flags) |f| if (std.mem.eql(u8, f.kind, board.flag_conflict)) return f.detail;
    return null;
}

/// Type a finishing instruction into the ticket's session; it stays put.
fn tell(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, s: []const u8, text: []const u8) !bool {
    // Finishing first, so the sent comment doesn't send it back to Running.
    try board.setFinishing(ctx, db, t.id, "merge");
    try tmux.sendLine(ctx, s, text);
    _ = try board.addComment(ctx, db, a, t.key, "you", text, true);
    return true;
}

/// One try at merging the change: true when trunk has it. Conflicts set the
/// ticket's conflict flag (the files); a clean merge clears it, forgets the
/// bookmark and moves working copies left on trunk up (see `catchUp`).
fn merge(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8, trunk: []const u8) !bool {
    const m = worktree.mergeChange(ctx, a, dir, t.worktree, t.change, t.branch, trunk) catch {
        try board.logEvent(ctx, db, t.id, "merge failed", worktree.lastError());
        return error.MergeFailed;
    };
    if (!m.merged) {
        try board.setFlagId(ctx, db, t.id, board.flag_conflict, "auto", if (m.conflicts.len > 0) m.conflicts else "conflicts");
        try board.logEvent(ctx, db, t.id, "conflicts", trunk);
        return false;
    }
    try board.clearFlagId(ctx, db, t.id, board.flag_conflict);
    try board.setChange(db, t.id, t.change, "");
    _ = worktree.catchUp(ctx, a, dir, trunk);
    if (t.worktree.len > 0) _ = worktree.catchUp(ctx, a, t.worktree, trunk);
    try board.logEvent(ctx, db, t.id, if (m.empty) "nothing to merge" else "merged", trunk);
    _ = try board.addComment(ctx, db, a, t.key, "claude", if (m.empty) try std.fmt.allocPrint(a, "Nothing to merge: its change had no edits, so it was dropped.", .{}) else try std.fmt.allocPrint(a, "Merged into {s}.", .{trunk}), false);
    return true;
}

/// A ticket finishing with conflicts in its change (Claude settled them):
/// merge it now. error.Conflicts while some are left.
pub fn mergeSettled(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !void {
    if (!std.mem.eql(u8, t.finishing, "merge") or t.change.len == 0 or conflictFlag(t) == null) return;
    const dir = (try board.getProject(db, a, t.project)).dir;
    const trunk = worktree.trunkBookmark(ctx, a, dir) orelse return error.MergeFailed;
    if (!try merge(ctx, db, a, t, dir, trunk)) return error.Conflicts;
}

/// Claude has merged or opened the PR (`cl ticket done --close`): the ticket
/// goes to Done, the PR link is kept as a comment, and its session closes. A
/// change whose conflicts Claude settled is merged now.
pub fn finished(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, summary: []const u8, pr: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    if (t.finishing.len == 0) return error.NotFinishing;
    try mergeSettled(ctx, db, a, t);
    if (summary.len > 0) _ = try board.addComment(ctx, db, a, key, "claude", summary, false);
    if (pr.len > 0) _ = try board.addComment(ctx, db, a, key, "claude", try std.fmt.allocPrint(a, "Pull request: {s}", .{pr}), false);
    try board.logEvent(ctx, db, t.id, "finished", t.finishing);
    try board.move(ctx, db, a, key, .done);
    try closeSession(ctx, db, a, key);
}

/// A finished ticket lets go of its session, so the project's queue (or a
/// worktree slot) is free for the next ticket: its gutter and test launch
/// stop, and the tmux session is killed unless another unfinished ticket is
/// still using it. A worktree stays until `cleanup`.
fn closeSession(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    review.stopGutter(ctx, a, key) catch {};
    review.stopLaunch(ctx, a, key) catch {};
    const t = try board.getTicket(db, a, key);
    const s = liveSession(ctx, t) orelse return;
    if ((try db.int("SELECT 1 FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage != 'done'", .{ s, t.id })) != null) return;
    // Logged first: `cl ticket done --close` runs in the session it kills.
    try board.logEvent(ctx, db, t.id, "session closed", s);
    try tmux.kill(ctx, s);
}

/// Approve; an approved plan also tells Claude to go ahead, and a tested
/// ticket going on to Done finishes as `move` does.
pub fn approve(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, spin_off: bool, finish: Finish) !board.Stage {
    if ((try board.getTicket(db, a, key)).stage == .testing) {
        try readyForDone(ctx, db, a, key, spin_off);
        if (try startFinish(ctx, db, a, key, finish)) return .testing;
    }
    const from = try board.approve(ctx, db, a, key);
    if (from == .testing) try closeSession(ctx, db, a, key);
    if (from == .planning) {
        const t = try board.getTicket(db, a, key);
        const go = "The plan is approved. Leave plan mode and build it.";
        if (liveSession(ctx, t)) |s| {
            try tmux.sendLine(ctx, s, go);
            _ = try board.addComment(ctx, db, a, key, "you", go, true);
        }
    }
    return from;
}

pub const Key = enum { esc, interrupt, enter, up, down };

/// Press a key in the ticket's session (Esc, Ctrl-C, ...).
pub fn press(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, k: Key) !void {
    const t = try board.getTicket(db, a, key);
    const s = liveSession(ctx, t) orelse return error.NoSession;
    try tmux.runQuiet(ctx, &.{ "send-keys", "-t", s, switch (k) {
        .esc => "Escape",
        .interrupt => "C-c",
        .enter => "Enter",
        .up => "Up",
        .down => "Down",
    } });
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 2) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// One AskUserQuestion question, as the flag detail holds it.
pub const Question = struct {
    multiSelect: bool = false,
    options: ?[]const struct { label: []const u8 = "" } = null,
};

/// A step of an answer typed into the session.
pub const Press = union(enum) {
    /// Typed as is (send-keys -l).
    text: []const u8,
    /// A named key (Enter, Down).
    key: []const u8,
    pause: u32,
};

/// The keypresses that answer AskUserQuestion's menu, one answer per
/// question. A single-select answer is an option's number (pressing it picks
/// it and moves on) or your own words (typed after "Type something"). A
/// multi-select answer lists option numbers, by commas or spaces, and may end
/// in your own words ("1,3", "2 4 something else", "1;3 more"): each number toggles its
/// option without moving the cursor, Down from the first row reaches "Type
/// something", where typing checks it, and one more Down is Next (or Submit),
/// taken with Enter. Several questions, or a multi-select one, end on the
/// review screen, whose first option submits.
pub fn questionKeys(a: std.mem.Allocator, qs: []const Question, answers: []const []const u8) ![]const Press {
    var out: std.ArrayList(Press) = .empty;
    const count = if (qs.len > 0) qs.len else 1;
    if (answers.len != count) return error.BadAnswer;
    var review_screen = count > 1;
    for (answers, 0..) |ans, i| {
        if (i > 0) try out.append(a, .{ .pause = 500 });
        const n_opts = if (i < qs.len) (if (qs[i].options) |o| o.len else 0) else 0;
        if (i < qs.len and qs[i].multiSelect) {
            review_screen = true;
            if (n_opts == 0) return error.BadAnswer;
            const m = try multiAnswer(a, ans, n_opts);
            for (m.picks) |p| {
                try out.append(a, .{ .text = p });
                try out.append(a, .{ .pause = 200 });
            }
            for (0..n_opts) |_| try out.append(a, .{ .key = "Down" });
            if (m.own.len > 0) {
                try out.append(a, .{ .pause = 200 });
                try out.append(a, .{ .text = m.own });
            }
            try out.append(a, .{ .pause = 200 });
            try out.append(a, .{ .key = "Down" });
            try out.append(a, .{ .key = "Enter" });
        } else if (isNumber(ans)) {
            try out.append(a, .{ .text = ans });
        } else {
            if (n_opts == 0) return error.BadAnswer;
            try out.append(a, .{ .text = try std.fmt.allocPrint(a, "{d}", .{n_opts + 1}) });
            try out.append(a, .{ .pause = 300 });
            try out.append(a, .{ .text = ans });
            try out.append(a, .{ .pause = 200 });
            try out.append(a, .{ .key = "Enter" });
        }
    }
    if (review_screen) {
        try out.append(a, .{ .pause = 500 });
        try out.append(a, .{ .text = "1" }); // Submit answers
    }
    return out.items;
}

/// A multi-select answer split into the options picked (leading numbers,
/// each once) and your own words after them. A ";" after the numbers marks
/// where your own words start, so they can begin with a number ("1;2 more").
fn multiAnswer(a: std.mem.Allocator, ans: []const u8, n_opts: usize) !struct { picks: []const []const u8, own: []const u8 } {
    var picks: std.ArrayList([]const u8) = .empty;
    var nums = ans;
    var own: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, ans, ';')) |semi| {
        if (std.mem.indexOfNone(u8, ans[0..semi], "0123456789 ,") == null) {
            nums = ans[0..semi];
            own = std.mem.trim(u8, ans[semi + 1 ..], " ");
        }
    }
    var rest = std.mem.trim(u8, nums, " ,");
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, " ,") orelse rest.len;
        const tok = rest[0..end];
        if (!isNumber(tok)) break;
        const n = std.fmt.parseInt(usize, tok, 10) catch break;
        if (n < 1 or n > n_opts) return error.BadAnswer;
        for (picks.items) |p| {
            if (std.mem.eql(u8, p, tok)) break;
        } else try picks.append(a, tok);
        rest = std.mem.trimStart(u8, rest[end..], " ,");
    }
    const words = own orelse rest;
    if (picks.items.len == 0 and words.len == 0) return error.BadAnswer;
    return .{ .picks = picks.items, .own = words };
}

test "questionKeys: single-select keeps the old keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qs = try std.json.parseFromSliceLeaky([]const Question, a,
        \\[{"question":"Color?","options":[{"label":"Red"},{"label":"Blue"}]}]
    , .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualDeep(@as([]const Press, &.{.{ .text = "2" }}), try questionKeys(a, qs, &.{"2"}));
    try std.testing.expectEqualDeep(@as([]const Press, &.{
        .{ .text = "3" }, .{ .pause = 300 }, .{ .text = "green" }, .{ .pause = 200 }, .{ .key = "Enter" },
    }), try questionKeys(a, qs, &.{"green"}));
}

test "questionKeys: multi-select toggles each pick, types its own words, then Next and Submit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qs = try std.json.parseFromSliceLeaky([]const Question, a,
        \\[{"question":"Fruits?","multiSelect":true,"options":[{"label":"Apple"},{"label":"Banana"},{"label":"Cherry"}]},
        \\ {"question":"Color?","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}]}]
    , .{ .ignore_unknown_fields = true });
    // The sequence that answered "Apple, Cherry, kiwi" and "Blue" in a live session.
    try std.testing.expectEqualDeep(@as([]const Press, &.{
        .{ .text = "1" },   .{ .pause = 200 },   .{ .text = "3" },    .{ .pause = 200 },
        .{ .key = "Down" }, .{ .key = "Down" },  .{ .key = "Down" },  .{ .pause = 200 },
        .{ .text = "kiwi" }, .{ .pause = 200 },  .{ .key = "Down" },  .{ .key = "Enter" },
        .{ .pause = 500 },  .{ .text = "2" },    .{ .pause = 500 },   .{ .text = "1" },
    }), try questionKeys(a, qs, &.{ "1,3,kiwi", "2" }));
    // Spaces work too, repeats count once, and no own words skips straight to Next.
    try std.testing.expectEqualDeep(@as([]const Press, &.{
        .{ .text = "2" },   .{ .pause = 200 },  .{ .key = "Down" },  .{ .key = "Down" },
        .{ .key = "Down" }, .{ .pause = 200 },  .{ .key = "Down" },  .{ .key = "Enter" },
        .{ .pause = 500 },  .{ .text = "1" },   .{ .pause = 500 },   .{ .text = "1" },
    }), try questionKeys(a, qs, &.{ "2 2", "1" }));
    try std.testing.expectError(error.BadAnswer, questionKeys(a, qs, &.{ "4", "1" }));
    try std.testing.expectError(error.BadAnswer, questionKeys(a, qs, &.{ ",", "1" }));
}

test "questionKeys: a lone multi-select question still submits on the review screen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qs = try std.json.parseFromSliceLeaky([]const Question, a,
        \\[{"question":"Pets?","multiSelect":true,"options":[{"label":"Cat"},{"label":"Dog"},{"label":"Fish"}]}]
    , .{ .ignore_unknown_fields = true });
    const keys = try questionKeys(a, qs, &.{"hamster"});
    try std.testing.expectEqualDeep(Press{ .text = "hamster" }, keys[4]);
    try std.testing.expectEqualDeep(Press{ .text = "1" }, keys[keys.len - 1]);
    // After ";" it's all your own words, numbers too.
    const semi = try questionKeys(a, qs, &.{"3;2 goldfish"});
    try std.testing.expectEqualDeep(Press{ .text = "3" }, semi[0]);
    try std.testing.expectEqualDeep(Press{ .text = "2 goldfish" }, semi[6]);
    try std.testing.expectEqualDeep(Press{ .text = "hamster; gerbil" }, (try questionKeys(a, qs, &.{"hamster; gerbil"}))[4]);
}

/// Answer what the session is waiting on, by keypress, as you would in the
/// terminal. Questions: one answer per question (see `questionKeys`); a lone
/// multi-select question also takes its picks as separate answers. Permission
/// prompts: the option's number. It returns once the session has taken the
/// answer, or fails with NotDelivered.
pub fn answer(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, answers_in: []const []const u8) !void {
    const t = try board.getTicket(db, a, key);
    const s = liveSession(ctx, t) orelse return error.NoSession;
    var flag: ?board.Flag = null;
    for (t.flags) |f| if (std.mem.eql(u8, f.kind, board.flag_question) or std.mem.eql(u8, f.kind, board.flag_input)) {
        flag = f;
    };
    const f = flag orelse return error.NothingAsked;
    if (answers_in.len == 0) return error.BadAnswer;
    var answers = answers_in;
    const before = signals.Waiting.of(ctx, cfg, a, s);

    if (std.mem.eql(u8, f.kind, board.flag_input)) {
        if (answers.len != 1 or !isNumber(answers[0])) return error.BadAnswer;
        try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, answers[0] });
    } else {
        const Detail = struct { questions: ?[]const Question = null };
        const d = std.json.parseFromSliceLeaky(Detail, a, f.detail, .{ .ignore_unknown_fields = true }) catch Detail{};
        const qs = d.questions orelse &.{};
        if (qs.len == 1 and qs[0].multiSelect and answers.len > 1) {
            const joined = try std.mem.join(a, ",", answers);
            answers = try a.dupe([]const u8, &.{joined});
        }
        for (try questionKeys(a, qs, answers)) |p| switch (p) {
            .text => |x| try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, x }),
            .key => |x| try tmux.runQuiet(ctx, &.{ "send-keys", "-t", s, x }),
            .pause => |ms| ctx.sleepMs(ms),
        };
    }
    if (!before.answered(ctx, cfg, s, 6000)) return error.NotDelivered;
    // Keep the answer in the ticket's history (this also clears the flag; the
    // dispatcher sets it again if the session is still waiting).
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "Answered: ");
    for (answers, 0..) |ans, i| {
        if (i > 0) try text.appendSlice(a, " · ");
        try text.appendSlice(a, ans);
    }
    _ = try board.addComment(ctx, db, a, key, "you", text.items, true);
}

/// The review you submitted in gutter (`cl ticket gutter <key> --submitted`,
/// run by gutter's pane): kept on the ticket and pasted into its session,
/// which starts another round. One with no comments changes nothing.
pub fn gutterSubmitted(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !CommentResult {
    const t = try board.getTicket(db, a, key);
    const path = try review.reviewPath(a, try review.ticketDir(db, a, t));
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(4 << 20)) catch return error.NoReview;
    if (std.mem.indexOf(u8, text, "_(no feedback)_") != null) {
        try board.logEvent(ctx, db, t.id, "gutter", "submitted with no comments");
        return .{};
    }
    var r: CommentResult = .{};
    // The file now holds what the session gets: the review, and what to do with it.
    const msg = try std.fmt.allocPrint(a, "I reviewed your changes in gutter. Address my review, then finish the same way as before.\n\n{s}", .{std.mem.trimEnd(u8, text, "\n")});
    if (liveSession(ctx, t)) |s| {
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = msg });
        try tmux.pasteFile(ctx, s, path);
        r.sent = true;
    } else r.unsent = true;
    const br = try board.addComment(ctx, db, a, key, "you", text, r.sent);
    r.sent_back = br.sent_back;
    r.round = (try board.getTicket(db, a, key)).round;
    return r;
}

/// Record test results: all passed approves the ticket on to Done; any
/// failure sends the results to Claude for another round.
pub fn testResults(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, checks: []const review.Check, note: []const u8, spin_off: bool, finish: Finish) !bool {
    const res = try review.recordResults(a, checks, note);
    if (res.passed) {
        const t = try board.getTicket(db, a, key);
        if (t.stage == .testing) try readyForDone(ctx, db, a, key, spin_off);
        _ = try board.addComment(ctx, db, a, key, "you", res.text, false);
        if (t.stage == .testing) _ = try approve(ctx, db, a, key, spin_off, finish);
    } else {
        const t = try board.getTicket(db, a, key);
        if (t.stage == .review) try board.move(ctx, db, a, key, .testing);
        _ = try comment(ctx, db, a, key, "you", res.text, true);
    }
    review.stopLaunch(ctx, a, key) catch {};
    return res.passed;
}
