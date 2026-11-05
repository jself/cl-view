//! Ticket actions that reach into a session (typing, keys), shared by
//! `cl ticket` and the web board so both do exactly the same thing.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const review = @import("review.zig");
const worktree = @import("worktree.zig");

pub const Error = error{
    /// The ticket has no live session to act on.
    NoSession,
    /// Nothing is waiting for an answer.
    NothingAsked,
    /// The answers don't fit what is asked.
    BadAnswer,
    /// No review submitted in gutter yet.
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

/// Answer what the session is waiting on, by keypress, as you would in the
/// terminal. Questions: one answer per question, each an option's number or
/// your own words (typed as "Type something"); several questions end with
/// Submit. Permission prompts: the option's number.
pub fn answer(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, answers: []const []const u8) !void {
    const t = try board.getTicket(db, a, key);
    const s = liveSession(ctx, t) orelse return error.NoSession;
    var flag: ?board.Flag = null;
    for (t.flags) |f| if (std.mem.eql(u8, f.kind, board.flag_question) or std.mem.eql(u8, f.kind, board.flag_input)) {
        flag = f;
    };
    const f = flag orelse return error.NothingAsked;
    if (answers.len == 0) return error.BadAnswer;

    if (std.mem.eql(u8, f.kind, board.flag_input)) {
        if (answers.len != 1 or !isNumber(answers[0])) return error.BadAnswer;
        try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, answers[0] });
    } else {
        // How many options each question has, for its "Type something" number.
        const Detail = struct {
            questions: ?[]const struct { options: ?[]const struct { label: []const u8 = "" } = null } = null,
        };
        const d = std.json.parseFromSliceLeaky(Detail, a, f.detail, .{ .ignore_unknown_fields = true }) catch Detail{};
        const qs = d.questions orelse &.{};
        const count = if (qs.len > 0) qs.len else 1;
        if (answers.len != count) return error.BadAnswer;
        for (answers, 0..) |ans, i| {
            if (i > 0) ctx.sleepMs(500);
            if (isNumber(ans)) {
                try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, ans });
            } else {
                const n_opts = if (i < qs.len) (if (qs[i].options) |o| o.len else 0) else 0;
                if (n_opts == 0) return error.BadAnswer;
                var buf: [4]u8 = undefined;
                try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, try std.fmt.bufPrint(&buf, "{d}", .{n_opts + 1}) });
                ctx.sleepMs(300);
                try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, ans });
                ctx.sleepMs(200);
                try tmux.runQuiet(ctx, &.{ "send-keys", "-t", s, "Enter" });
            }
        }
        if (count > 1) {
            ctx.sleepMs(500);
            try tmux.runQuiet(ctx, &.{ "send-keys", "-l", "-t", s, "1" }); // Submit answers
        }
    }
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

/// Send the review you submitted in gutter to Claude: another round.
pub fn sendReview(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !CommentResult {
    const t = try board.getTicket(db, a, key);
    const dir = try review.ticketDir(db, a, t);
    if (!review.hasReview(ctx, a, dir)) return error.NoReview;
    const r = try comment(ctx, db, a, key, "you", "I reviewed this in gutter. My comments are in .claude/review.md; please address them, then finish the same way as before.", true);
    review.stopGutter(ctx, a, key) catch {};
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
