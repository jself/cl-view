//! Ticket actions that reach into a session (typing, keys, killing it),
//! shared by `cl ticket` and the web board so both do exactly the same thing.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const review = @import("review.zig");
const autoreview = @import("autoreview.zig");
const worktree = @import("worktree.zig");
const config = @import("config.zig");
const signals = @import("signals.zig");
const claude = @import("claude.zig");
const after_merge = @import("after_merge.zig");
const operator = @import("operator.zig");
const park = @import("park.zig");

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
    /// Merge or PR on a ticket Claude asked to close its own way
    /// (`Ticket.custom_close`).
    CustomClose,
    /// Moving it back would kill a session another ticket is in progress in.
    SharedSession,
    /// It is being started right now.
    Starting,
    /// `done --close` on a ticket finishing with a PR and steps for after
    /// it merges, without the PR's URL to park the follow-up on.
    NoPrUrl,
};

pub fn liveSession(ctx: Ctx, t: board.Ticket) ?[]const u8 {
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
pub const Finish = union(enum) {
    /// Nothing: move it to Done and close the session.
    close,
    /// Merge the branch into the main branch first: cl does it for a jj
    /// change (Claude settles conflicts), Claude does it for a git branch.
    merge,
    /// Claude pushes the branch and opens a PR first.
    pr,
    /// Claude does what the human typed first, whatever that is (any ticket
    /// with a session, branch or not).
    tell: []const u8,

    /// close, merge or pr by name; `tell` needs its text (see `told`).
    pub fn parse(s: []const u8) ?Finish {
        if (std.mem.eql(u8, s, "close")) return .close;
        if (std.mem.eql(u8, s, "merge")) return .merge;
        if (std.mem.eql(u8, s, "pr")) return .pr;
        return null;
    }

    /// `tell` with the human's words; null when there are none.
    pub fn told(text: []const u8) ?Finish {
        const t = std.mem.trim(u8, text, " \t\r\n");
        return if (t.len == 0) null else .{ .tell = t };
    }
};

/// Move a ticket. Reaching Done closes its session; with `finish` merge or
/// pr, a ticket with a branch of its own first stays put while Claude merges
/// or opens the PR, and goes to Done when it runs `cl ticket done --close`.
/// Moved back to Queued or Backlog while in progress, it stops: see `stopFor`.
pub fn move(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, stage: board.Stage, spin_off: bool, finish: Finish) !void {
    if (stage == .done) {
        try readyForDone(ctx, db, a, key, spin_off);
        if (try startFinish(ctx, db, a, key, finish)) return;
    }
    if (stage == .queued or stage == .backlog) {
        // Not in progress any more: a review of it stops too, session or not.
        autoreview.stop(ctx, db, a, key) catch {};
        if (try stopFor(ctx, cfg, db, a, key, stage)) return;
    }
    try board.move(ctx, db, a, key, stage);
    // Before the session closes: this may be running in it.
    if (stage == .done and finish == .close) try checkLanded(ctx, db, a, key, "It went to Done with Close, not Merge or PR");
    if (stage == .done) try closeSession(ctx, db, a, key);
}

/// A ticket that went to Done without cl merging it (closed, or finished by
/// Claude): when its branch or jj change still holds work its target (trunk,
/// or the branch it targets: `Ticket.onto`) lacks, it is flagged `unmerged`,
/// so it isn't left behind unseen. Work on its target that trunk lacks is
/// where it belongs, not left behind. Not for a custom close
/// (Claude said what to do with it instead, and you chose that). `how` says
/// how it got there.
pub fn checkLanded(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, how: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    if (t.stage != .done or t.custom_close.len > 0) return;
    if (t.change.len == 0 and t.branch.len == 0) return;
    const dir = (try board.getProject(db, a, t.project)).dir;
    const main = if (t.change.len > 0) worktree.target(ctx, a, dir, t.onto) orelse return else worktree.mergeBranch(ctx, a, dir, t.onto);
    const left = worktree.unmergedWork(ctx, a, dir, t.change, t.branch, main) orelse return;
    const fix: []const u8 = if (t.change.len > 0)
        try std.fmt.allocPrint(a, "Merge it into {s} now (the board's Not merged tab, or `cl ticket move {s} done --merge`)", .{ main, t.key })
    else
        try std.fmt.allocPrint(a, "Move it back to Review and finish it with Merge (into {s})", .{main});
    try board.setFlagId(ctx, db, t.id, board.flag_unmerged, "auto", try std.fmt.allocPrint(a, "{s}\n{s}. {s}, or dismiss this if it wasn't meant to land.", .{ left, how, fix }));
}

/// A ticket in progress (running, review, testing) moved back to Queued or
/// Backlog stops working: its session is killed as `kill` does, so Claude
/// doesn't carry on unseen (and keep the project's slot) while the board
/// says it waits. Its conversation
/// and jj change are kept; queued, the dispatcher starts it again and it
/// resumes. Refused while another ticket is in progress in that session (a
/// queue project's shared one, or a parent's): it would be cut off too.
/// True when it moved; false when there was no session of its own to end.
fn stopFor(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, stage: board.Stage) !bool {
    const t = try board.getTicket(db, a, key);
    const s = try sessionToStop(db, t, if (liveSession(ctx, t)) |_| true else false) orelse return false;
    review.stopGutter(ctx, a, key) catch {};
    autoreview.stop(ctx, db, a, key) catch {};
    review.stopLaunchesBut(ctx, a, key, tmux.ownSession(ctx, a)) catch {};
    _ = try endSession(ctx, cfg, db, a, t, s, stage);
    return true;
}

/// The session `stopFor` kills: `t`'s own while it is in progress there
/// (`live`: it is running). null when there is none to end.
pub fn sessionToStop(db: board.Db, t: board.Ticket, live: bool) !?[]const u8 {
    switch (t.stage) {
        .running, .review, .testing => {},
        // Planning runs in a session of its own, which the dispatcher ends
        // once the ticket leaves Planning. Not in progress, a session it
        // still names is no longer its own.
        else => return null,
    }
    if (t.tmux.len > 0 and t.tmux[0] == '(') return error.Starting;
    if (t.tmux.len == 0 or !live) return null;
    if (try board.sessionHasTicket(db, t.tmux, t.id)) return error.SharedSession;
    return t.tmux;
}

/// Type the merge or PR instruction into the ticket's session; false when
/// there is nothing to do first (just close, or no branch of its own).
fn startFinish(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, finish: Finish) !bool {
    if (finish == .close) return false;
    const t = try board.getTicket(db, a, key);
    if (t.custom_close.len > 0 and (finish == .merge or finish == .pr)) return error.CustomClose;
    if (finish == .tell) {
        const s = liveSession(ctx, t) orelse return error.NoSession;
        return try tell(ctx, db, a, t, s, "tell", try std.fmt.allocPrint(a, "This ticket is approved. Before it is done: {s}\nIf anything is unclear, ask me. Then run `cl ticket done {s} --close`.", .{ finish.tell, t.key }));
    }
    const dir = (try board.getProject(db, a, t.project)).dir;
    if (finish == .merge and t.change.len > 0) return mergeBack(ctx, db, a, t, dir);
    if (finish == .merge and t.mode == .queue and t.branch.len == 0 and t.base.len > 0) {
        if (try adoptStray(ctx, db, a, t, dir)) |owned| return mergeBack(ctx, db, a, owned, dir);
    }
    if (t.branch.len == 0) return false;
    const s = liveSession(ctx, t) orelse return error.NoSession;
    const main = worktree.mergeBranch(ctx, a, dir, t.onto);
    const restart = if (worktree.isTrunk(ctx, a, dir, t.onto)) try afterMergeHint(db, a, t.project, "Once it is merged:") else try std.fmt.allocPrint(a, "{s} isn't trunk: don't merge it into trunk too, and don't rebuild or restart anything for it. Once it is merged, run", .{main});
    const text = switch (finish) {
        .close, .tell => unreachable,
        .merge => try std.fmt.allocPrint(a, "This ticket is approved. Finish it by merging its branch {s} into {s}: commit anything left here first, then merge it in the project's checkout at {s} (it may have uncommitted work of its own; leave that alone). If it conflicts in a way you can't settle with confidence, or anything is unclear, ask me. {s} `cl ticket done {s} --close`.", .{ t.branch, main, dir, restart, t.key }),
        .pr => try std.fmt.allocPrint(a, "{s}{s}", .{ if (t.change.len > 0)
            try std.fmt.allocPrint(a, "This ticket is approved. Finish it with a pull request: push its jj bookmark {s} (`jj git push -b {s}`) and open a PR against {s} (gh pr create --head {s} --base {s}) with a title and description of the change. If anything is unclear, ask me. Then run `cl ticket done {s} --close --pr-url <the PR's URL>`.", .{ t.branch, t.branch, main, t.branch, main, t.key })
        else
            try std.fmt.allocPrint(a, "This ticket is approved. Finish it with a pull request: commit anything left, push its branch {s} and open a PR against {s} (gh pr create --base {s}) with a title and description of the change. If anything is unclear, ask me. Then run `cl ticket done {s} --close --pr-url <the PR's URL>`.", .{ t.branch, main, main, t.key }), if (t.pr_then.len > 0)
            try std.fmt.allocPrint(a, " Don't do what's left for after it merges ({s}): with the PR's URL, cl makes a follow-up ticket that does it once the PR merges.", .{t.pr_then})
        else
            "" }),
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
    const trunk = worktree.target(ctx, a, dir, t.onto) orelse return null;
    _ = worktree.strayWork(ctx, a, dir, trunk) orelse return null;
    const desc = try std.fmt.allocPrint(a, "{s}: {s}", .{ t.key, t.title });
    const c = worktree.adoptChange(ctx, a, dir, desc, try worktree.slug(a, t.key, t.title)) catch {
        try board.logEvent(ctx, db, t.id, "merge failed", worktree.lastError());
        try board.setFlagId(ctx, db, t.id, board.flag_merge_failed, "auto", try std.fmt.allocPrint(a, "cl couldn't make the work in {s} a change of its own, so nothing was merged\n{s}", .{ dir, worktree.lastError() }));
        return error.MergeFailed;
    };
    try board.setChange(db, t.id, c.id, c.bookmark);
    try board.logEvent(ctx, db, t.id, "adopted change", c.id);
    var owned = t;
    owned.change = c.id;
    owned.branch = c.bookmark;
    return owned;
}

/// Merge the ticket's jj change back into its target, trunk unless it has
/// one of its own (see `worktree.mergeChange`).
/// True when the ticket stays put, finishing, while Claude settles
/// conflicts or does the after-merge steps; false when it can go to Done now.
fn mergeBack(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8) !bool {
    const trunk = worktree.target(ctx, a, dir, t.onto) orelse {
        try board.logEvent(ctx, db, t.id, "merge failed", "no trunk bookmark");
        try board.setFlagId(ctx, db, t.id, board.flag_merge_failed, "auto", try std.fmt.allocPrint(a, "cl couldn't tell which bookmark is trunk in {s}, so nothing was merged", .{dir}));
        return error.MergeFailed;
    };
    switch (try merge(ctx, db, a, t, dir, trunk)) {
        .empty => return false,
        .merged => return claudeAfterMerge(ctx, db, a, t, trunk),
        .conflicts => {
            const s = liveSession(ctx, t) orelse return error.Conflicts;
            const list = conflictFlag(try board.getTicket(db, a, t.key)) orelse "";
            const p = try board.getProject(db, a, t.project);
            const after: []const u8 = if (!worktree.isTrunk(ctx, a, dir, t.onto)) "" else if (p.after_merge.len > 0) " (and runs the project's after-merge command; don't rebuild or restart anything yourself)" else if (claudeSteps(p) != null) " (and tells you what to do after the merge)" else "";
            return try tell(ctx, db, a, t, s, "merge", try std.fmt.allocPrint(a, "This ticket is approved, but its change conflicts with {s}: cl rebased it onto {s}, and jj recorded the conflicts in the change, in:\n{s}\nResolve them there: edit the conflict markers out, keeping what both sides meant (`jj resolve --list` shows what's left). If one can't be settled with confidence, ask me. Then run `cl ticket done {s} --close`; cl merges it then{s}.", .{ trunk, trunk, list, t.key, after }));
        },
    }
}

/// What Claude is asked to do after a merge: the project's own steps, or
/// rebuilding and restarting what runs from its checkout. null when that is
/// turned off ("none").
pub fn claudeSteps(p: board.Project) ?[]const u8 {
    if (std.mem.eql(u8, p.after_merge_claude, "none")) return null;
    if (p.after_merge_claude.len > 0) return p.after_merge_claude;
    return "Rebuild and restart whatever runs from the project's checkout (dev servers, an installed build; the project's CLAUDE.md may say how) so it serves the merged code.";
}

/// Claude does the after-merge steps when the project has no command: the
/// ticket's Claude while its session is there (the ticket stays finishing
/// until it runs done --close: true), else the operator (false). None after
/// a merge into a branch that isn't trunk: nothing runs from there.
fn claudeAfterMerge(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, trunk: []const u8) !bool {
    const p = try board.getProject(db, a, t.project);
    if (p.after_merge.len > 0 or !worktree.isTrunk(ctx, a, p.dir, t.onto)) return false;
    const steps = claudeSteps(p) orelse return false;
    if (liveSession(ctx, t)) |s| return try tell(ctx, db, a, t, s, "after-merge", try std.fmt.allocPrint(a, "This ticket is approved and cl merged it into {s}. Before it is done: {s} The project's checkout is at {s}. If anything fails or is unclear, ask me. Then run `cl ticket done {s} --close`.", .{ trunk, steps, p.dir, t.key }));
    try askOperator(ctx, db, a, t, try std.fmt.allocPrint(a, "cl merged ticket {s} ({s}) into {s} of project {s}, whose checkout is at {s}. Its session is gone, so please do the after-merge steps for it: {s} If something fails that needs the human, flag the ticket for them: `cl ticket flag {s} after-merge \"<what went wrong>\"`.", .{ t.key, t.title, trunk, p.name, p.dir, steps, t.key }));
    return false;
}

/// Hand the operator a job for a ticket, noting it on the ticket; a failure
/// to reach it flags the ticket instead, so nothing is dropped silently.
pub fn askOperator(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, text: []const u8) !void {
    const cfg = config.load(ctx) catch null;
    if (cfg) |c| if (operator.send(ctx, c, text)) |_| {
        try board.logEvent(ctx, db, t.id, "after-merge", "asked the operator");
        return;
    } else |_| {};
    try board.logEvent(ctx, db, t.id, "after-merge", "couldn't reach the operator");
    try board.setFlagId(ctx, db, t.id, board.flag_after_merge, "auto", try std.fmt.allocPrint(a, "cl couldn't reach the operator to do the after-merge steps\n{s}", .{text}));
}

/// The CLI's done --close just merged a change whose conflicts Claude
/// settled: with no after-merge command, the ticket stays finishing while
/// Claude does the steps, which it is told (the text, for it to print).
/// null when it can go to Done.
pub fn stepsAfterSettled(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !?[]const u8 {
    const p = try board.getProject(db, a, t.project);
    if (p.after_merge.len > 0 or !worktree.isTrunk(ctx, a, p.dir, t.onto)) return null;
    const steps = claudeSteps(p) orelse return null;
    try board.setFinishing(ctx, db, t.id, "after-merge");
    const text = try std.fmt.allocPrint(a, "cl merged it. Before it is done: {s} The project's checkout is at {s}. If anything fails or is unclear, ask me. Then run `cl ticket done {s} --close` again.", .{ steps, p.dir, t.key });
    _ = try board.addComment(ctx, db, a, t.key, "you", text, false);
    return text;
}

/// What the git merge instruction says to do once it is merged (`when`):
/// nothing when the project's after-merge command does it, else Claude's
/// steps; then finish.
fn afterMergeHint(db: board.Db, a: std.mem.Allocator, project: []const u8, when: []const u8) ![]const u8 {
    const p = try board.getProject(db, a, project);
    if (p.after_merge.len > 0) return std.fmt.allocPrint(a, "Don't rebuild or restart anything for it: cl runs the project's after-merge command on the merged code when you finish. {s} run", .{when});
    const steps = claudeSteps(p) orelse return std.fmt.allocPrint(a, "{s} run", .{when});
    return std.fmt.allocPrint(a, "{s} {s} Then run", .{ when, steps });
}

/// The conflicted files, while merging the ticket's change conflicts.
fn conflictFlag(t: board.Ticket) ?[]const u8 {
    for (t.flags) |f| if (std.mem.eql(u8, f.kind, board.flag_conflict)) return f.detail;
    return null;
}

/// Type a finishing instruction into the ticket's session; it stays put,
/// finishing `how` ("merge" while conflicts are settled, "after-merge").
fn tell(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, s: []const u8, how: []const u8, text: []const u8) !bool {
    // Finishing first, so the sent comment doesn't send it back to Running.
    try board.setFinishing(ctx, db, t.id, how);
    // Pasted when it has several lines, so a newline doesn't send it early.
    try claude.submit(ctx, s, text, true);
    _ = try board.addComment(ctx, db, a, t.key, "you", text, true);
    return true;
}

const Merged = enum { merged, empty, conflicts };

/// One try at merging the change into `trunk` (its target). Conflicts set
/// the ticket's conflict flag (the files); a clean merge clears it, forgets
/// the bookmark, moves working copies left on it up (see `catchUp`) and, for
/// a merge into trunk itself, starts the project's after-merge command (a
/// feature branch's merges run nothing: what runs is built from trunk).
/// `empty`: it had no edits, so it was dropped.
fn merge(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8, trunk: []const u8) !Merged {
    const m = worktree.mergeChange(ctx, a, dir, t.worktree, t.change, t.branch, trunk) catch {
        try board.logEvent(ctx, db, t.id, "merge failed", worktree.lastError());
        try board.setFlagId(ctx, db, t.id, board.flag_merge_failed, "auto", try std.fmt.allocPrint(a, "cl couldn't merge its change into {s}; {s} is where it was\n{s}", .{ trunk, trunk, worktree.lastError() }));
        return error.MergeFailed;
    };
    if (!m.merged) {
        try board.setFlagId(ctx, db, t.id, board.flag_conflict, "auto", if (m.conflicts.len > 0) m.conflicts else "conflicts");
        try board.logEvent(ctx, db, t.id, "conflicts", trunk);
        return .conflicts;
    }
    try board.clearFlagId(ctx, db, t.id, board.flag_conflict);
    // It landed: whatever said it hadn't no longer holds.
    try board.clearFlagId(ctx, db, t.id, board.flag_merge_failed);
    try board.clearFlagId(ctx, db, t.id, board.flag_unmerged);
    try board.setChange(db, t.id, t.change, "");
    const is_trunk = worktree.isTrunk(ctx, a, dir, t.onto);
    // The project's checkout stays where it is after a feature branch's
    // merge, unless it was on the change itself.
    _ = worktree.catchUp(ctx, a, dir, trunk, is_trunk);
    if (t.worktree.len > 0) _ = worktree.catchUp(ctx, a, t.worktree, trunk, true);
    try board.logEvent(ctx, db, t.id, if (m.empty) "nothing to merge" else "merged", trunk);
    if (!m.empty and is_trunk) _ = try after_merge.start(ctx, db, a, t.project, t.id, t.key);
    _ = try board.addComment(ctx, db, a, t.key, "claude", if (m.empty) try std.fmt.allocPrint(a, "Nothing to merge: its change had no edits, so it was dropped.", .{}) else try std.fmt.allocPrint(a, "Merged into {s}.", .{trunk}), false);
    return if (m.empty) .empty else .merged;
}

/// A ticket finishing with conflicts in its change (Claude settled them):
/// merge it now; true when that put new code on trunk. error.Conflicts while
/// some are left.
pub fn mergeSettled(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !bool {
    if (!std.mem.eql(u8, t.finishing, "merge") or t.change.len == 0 or conflictFlag(t) == null) return false;
    const dir = (try board.getProject(db, a, t.project)).dir;
    const trunk = worktree.target(ctx, a, dir, t.onto) orelse return error.MergeFailed;
    return switch (try merge(ctx, db, a, t, dir, trunk)) {
        .conflicts => error.Conflicts,
        .merged => true,
        .empty => false,
    };
}

/// Claude has merged or opened the PR (`cl ticket done --close`): the ticket
/// goes to Done, the PR link is kept as a comment, and its session closes. A
/// change whose conflicts Claude settled is merged now.
pub fn finished(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, summary: []const u8, pr: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    if (t.finishing.len == 0) return error.NotFinishing;
    // Steps for after the PR merges: they need the PR to wait on.
    const then = followsUp(t);
    if (then and pr.len == 0) return error.NoPrUrl;
    if (then) _ = try park.parsePr(a, pr, null);
    _ = try mergeSettled(ctx, db, a, t);
    // A git branch Claude merged into the main branch: it is there now.
    // Into another branch (its target): nothing runs from that.
    if (std.mem.eql(u8, t.finishing, "merge") and t.change.len == 0 and t.branch.len > 0 and
        worktree.isTrunk(ctx, a, (try board.getProject(db, a, t.project)).dir, t.onto))
        _ = try after_merge.start(ctx, db, a, t.project, t.id, t.key);
    if (summary.len > 0) _ = try board.addComment(ctx, db, a, key, "claude", summary, false);
    if (pr.len > 0) _ = try board.addComment(ctx, db, a, key, "claude", try std.fmt.allocPrint(a, "Pull request: {s}", .{pr}), false);
    try board.logEvent(ctx, db, t.id, "finished", t.finishing);
    try board.move(ctx, db, a, key, .done);
    // A PR lands through the PR; anything else should have put it on trunk.
    // Checked before the session closes: this runs in it.
    if (!std.mem.eql(u8, t.finishing, "pr") and pr.len == 0)
        try checkLanded(ctx, db, a, key, if (std.mem.eql(u8, t.finishing, "tell")) "Claude finished what you told it without merging it" else "Claude said it was merged, but it isn't");
    // It is Done already: a follow-up that couldn't be made is flagged with
    // its steps, rather than leaving the session open too.
    if (then) if (park.followUp(ctx, db, a, t, pr, t.pr_then)) |k| {
        _ = try board.addComment(ctx, db, a, key, "claude", try std.fmt.allocPrint(a, "Follow-up {s} is parked on the PR: it does what's left once the PR merges.", .{k}), false);
    } else |e| {
        try board.setFlagId(ctx, db, t.id, flag_follow_up_failed, "auto", try std.fmt.allocPrint(a, "cl couldn't make the follow-up for {s} ({s}). What was left for after it merges: {s}", .{ pr, @errorName(e), t.pr_then }));
    };
    try closeSession(ctx, db, a, key);
}

/// Finishing with a PR, with steps for after it merges: `finished` makes a
/// follow-up for them, parked on the PR.
pub const flag_follow_up_failed = "follow-up-failed";

pub fn followsUp(t: board.Ticket) bool {
    return std.mem.eql(u8, t.finishing, "pr") and std.mem.trim(u8, t.pr_then, " \t\r\n").len > 0;
}

/// What Claude is doing for a ticket finishing `how`.
pub fn finishingWhat(how: []const u8) []const u8 {
    if (std.mem.eql(u8, how, "pr")) return "opening a PR";
    if (std.mem.eql(u8, how, "after-merge")) return "doing the after-merge steps";
    if (std.mem.eql(u8, how, "tell")) return "doing what you told it";
    return "merging its branch";
}

/// A finished ticket lets go of its session, so the project's queue (or a
/// worktree slot) is free for the next ticket: its gutter and test launches
/// stop, and the tmux session is killed unless another unfinished ticket is
/// still using it. A worktree stays until `cleanup`.
///
/// What this runs in goes last or not at all: the ticket's own session
/// (`cl ticket done --close`) is killed after the rest, and a launch of the
/// ticket (a test server whose board finished it) is left for the main
/// server's sweep. Killed first, either would end this before it got to the
/// ticket's session, which then ran on unseen.
fn closeSession(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    const me = tmux.ownSession(ctx, a);
    const s = try sessionToClose(ctx, db, t);
    const mine = if (s) |x| if (me) |m| std.mem.eql(u8, x, m) else false else false;
    if (s) |x| if (!mine) try killTicketSession(ctx, db, t, x);
    review.stopGutter(ctx, a, key) catch {};
    autoreview.stop(ctx, db, a, key) catch {};
    review.stopLaunchesBut(ctx, a, key, me) catch {};
    if (mine) try killTicketSession(ctx, db, t, s.?);
}

/// The live session a Done (or deleted) ticket leaves behind, unless
/// another unfinished ticket is using it.
fn sessionToClose(ctx: Ctx, db: board.Db, t: board.Ticket) !?[]const u8 {
    const s = liveSession(ctx, t) orelse return null;
    if ((try db.int("SELECT 1 FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage != 'done'", .{ s, t.id })) != null) return null;
    return s;
}

fn killTicketSession(ctx: Ctx, db: board.Db, t: board.Ticket, s: []const u8) !void {
    // Logged first: it may be the session this runs in.
    try board.logEvent(ctx, db, t.id, "session closed", s);
    try tmux.kill(ctx, s);
}

/// Delete a ticket. Its session, gutter and test launches go with it, as
/// they do when it goes to Done: nothing on the board points at them
/// anymore. error.Exists while it has sub-tickets. Returns the tickets that
/// were linked to wait on it: they go on without it.
pub fn remove(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) ![]const []const u8 {
    const t = try board.getTicket(db, a, key);
    const me = tmux.ownSession(ctx, a);
    const s = try sessionToClose(ctx, db, t);
    const freed = try board.removeTicket(ctx, db, a, t.key);
    const mine = if (s) |x| if (me) |m| std.mem.eql(u8, x, m) else false else false;
    if (s) |x| if (!mine) tmux.kill(ctx, x) catch {};
    review.stopGutter(ctx, a, t.key) catch {};
    autoreview.killSession(ctx, a, t.key) catch {};
    review.stopLaunchesBut(ctx, a, t.key, me) catch {};
    if (mine) tmux.kill(ctx, s.?) catch {};
    return freed;
}

/// The main server's sweep: a Done ticket whose session is still alive
/// (going to Done should have closed it, but whatever did it was cut off,
/// say a `cl web` restarted mid-request) has it closed now. Not while a
/// ticket is starting: its session may not be on the board yet. The
/// sessions closed.
pub fn closeLeftSessions(ctx: Ctx, db: board.Db, a: std.mem.Allocator) ![]const []const u8 {
    if ((try db.int("SELECT 1 FROM tickets WHERE tmux LIKE '(%'", .{})) != null) return &.{};
    const names = tmux.run(ctx, &.{ "list-sessions", "-F", "#{session_name}" }) catch return &.{};
    defer ctx.gpa.free(names);
    var live: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.tokenizeScalar(u8, names, '\n');
    while (it.next()) |n| try live.put(a, try a.dupe(u8, n), {});
    var out: std.ArrayList([]const u8) = .empty;
    for (try board.listTickets(db, a, .{ .stage = .done })) |t| {
        if (!live.contains(t.tmux)) continue;
        const s = try sessionToClose(ctx, db, t) orelse continue;
        // Already taken by an earlier Done ticket with the same session.
        for (out.items) |o| {
            if (std.mem.eql(u8, o, s)) break;
        } else {
            try killTicketSession(ctx, db, t, s);
            try out.append(a, s);
        }
    }
    return out.items;
}

/// Approve. An approved plan goes to Queued: the dispatcher closes the
/// planning session and a new one builds it, told the plan. A tested ticket
/// going on to Done finishes as `move` does.
pub fn approve(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, spin_off: bool, finish: Finish) !board.Stage {
    if ((try board.getTicket(db, a, key)).stage == .testing) {
        try readyForDone(ctx, db, a, key, spin_off);
        if (try startFinish(ctx, db, a, key, finish)) return .testing;
    }
    const from = try board.approve(ctx, db, a, key);
    if (from == .testing and finish == .close) try checkLanded(ctx, db, a, key, "It went to Done with Close, not Merge or PR");
    if (from == .testing) try closeSession(ctx, db, a, key);
    return from;
}

pub const KillResult = struct {
    /// The tmux session it was in.
    session: []const u8,
    /// Other unfinished tickets that were on the same session (a queue
    /// project's shared one); they let go of it too.
    others: []const []const u8,
    /// It had a conversation of its own, which a restart picks back up.
    resumes: bool,
};

/// End the ticket's session on purpose, as `cl kill` does. The ticket keeps
/// its stage and lets go of the session with no flag raised (a kill you chose
/// doesn't need you); `cl ticket start` restarts it, resuming its conversation
/// where Claude still has it. Work in the checkout or worktree stays put.
pub fn kill(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8) !KillResult {
    const t = try board.getTicket(db, a, key);
    const s = liveSession(ctx, t) orelse return error.NoSession;
    return endSession(ctx, cfg, db, a, t, s, null);
}

/// `kill` on `t`'s live session `s`; with `to`, the ticket also moves there
/// (Queued: it waits for the dispatcher, no longer killed).
fn endSession(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, s: []const u8, to: ?board.Stage) !KillResult {
    // Its own conversation may have a new id since it started (/clear): keep
    // the one it has now, so a restart resumes that.
    if (t.session_id.len > 0) {
        if (claude.readStatuses(ctx, a, cfg)) |statuses| {
            if (statuses.get(s)) |i| if (i.session_id.len == 36 and !std.mem.eql(u8, i.session_id, t.session_id)) {
                try board.setSessionId(db, t.id, i.session_id);
            };
        } else |_| {}
    }
    var others: std.ArrayList([]const u8) = .empty;
    var st = try db.query("SELECT key FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage != 'done' ORDER BY id", .{ s, t.id });
    defer st.finalize();
    while (try st.step()) try others.append(a, try st.dupe(a, 0));
    // The board first: run from inside the session (Claude parking its own
    // ticket), this process goes with it.
    try letGo(ctx, db, a, t, s, to);
    try tmux.kill(ctx, s);
    return .{ .session = s, .others = others.items, .resumes = t.session_id.len == 36 };
}

/// The board's side of ending `s`: its tickets let go of it, and with `to`
/// `t` moves there (Queued: no longer killed, so the dispatcher starts it).
pub fn letGo(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, s: []const u8, to: ?board.Stage) !void {
    try board.sessionKilled(ctx, db, a, s);
    if (to) |stage| try board.moveTicket(ctx, db, t, stage);
}

/// A session killed outside the board (`cl kill`, the chooser): its tickets
/// let go of it as `kill` does, rather than being flagged as ended.
pub fn sessionKilled(ctx: Ctx, cfg: config.Config, tmux_name: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const db = board.open(ctx, cfg) catch return;
    defer db.close();
    board.sessionKilled(ctx, db, arena_state.allocator(), tmux_name) catch {};
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
    options: ?[]const struct { label: []const u8 = "", preview: ?[]const u8 = null } = null,

    /// Its menu shows a preview beside the options, and has no "Type
    /// something" row for your own words.
    fn hasPreview(q: Question) bool {
        for (q.options orelse &.{}) |o| if (o.preview) |p| if (p.len > 0) return true;
        return false;
    }
};

/// A step of an answer typed into the session.
pub const Press = union(enum) {
    /// Typed as is (send-keys -l).
    text: []const u8,
    /// A named key (Enter, Down).
    key: []const u8,
    /// A single-select option's number: typed, then Enter when the menu on
    /// screen has previews (there the number only moves to the option).
    pick: []const u8,
    pause: u32,
};

/// The keypresses that answer AskUserQuestion's menu, one answer per
/// question. A single-select answer is an option's number (a `pick`) or your
/// own words (typed after "Type something", which menus with previews
/// don't have). A
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
            try out.append(a, .{ .pick = ans });
        } else {
            if (n_opts == 0 or qs[i].hasPreview()) return error.BadAnswer;
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
    try std.testing.expectEqualDeep(@as([]const Press, &.{.{ .pick = "2" }}), try questionKeys(a, qs, &.{"2"}));
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
        .{ .pause = 500 },  .{ .pick = "2" },    .{ .pause = 500 },   .{ .text = "1" },
    }), try questionKeys(a, qs, &.{ "1,3,kiwi", "2" }));
    // Spaces work too, repeats count once, and no own words skips straight to Next.
    try std.testing.expectEqualDeep(@as([]const Press, &.{
        .{ .text = "2" },   .{ .pause = 200 },  .{ .key = "Down" },  .{ .key = "Down" },
        .{ .key = "Down" }, .{ .pause = 200 },  .{ .key = "Down" },  .{ .key = "Enter" },
        .{ .pause = 500 },  .{ .pick = "1" },   .{ .pause = 500 },   .{ .text = "1" },
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

test "questionKeys: a question with previews takes numbers, not your own words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qs = try std.json.parseFromSliceLeaky([]const Question, a,
        \\[{"question":"Which line?","options":[{"label":"Both lines","preview":"a\\nb"},{"label":"from one","preview":"a"}]}]
    , .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualDeep(@as([]const Press, &.{.{ .pick = "2" }}), try questionKeys(a, qs, &.{"2"}));
    try std.testing.expectError(error.BadAnswer, questionKeys(a, qs, &.{"neither"}));
}

/// Answer what the session is waiting on, by keypress, as you would in the
/// terminal. Questions: one answer per question (see `questionKeys`); a lone
/// multi-select question also takes its picks as separate answers. Permission
/// prompts: the option's number. Which of the two it is comes from the
/// session itself when it can tell (Claude's Notification hook flags an
/// AskUserQuestion menu as `input`, "Claude needs your permission"), else
/// from the flag. It returns once the session has taken the answer, or fails
/// with NotDelivered.
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
    const statuses = claude.readStatuses(ctx, a, cfg) catch claude.StatusMap.empty;
    const info = statuses.get(s);
    const pend = signals.waitingOn(ctx, a, t, info);
    const live = if (info) |i| i.status == .waiting or i.status == .blocked else false;
    const question = if (live) signals.isQuestion(pend, info) else std.mem.eql(u8, f.kind, board.flag_question);

    if (!question) {
        if (answers.len != 1 or !isNumber(answers[0])) return error.BadAnswer;
        try tmux.typeText(ctx, s, answers[0]);
    } else {
        const Detail = struct { questions: ?[]const Question = null };
        const d = std.json.parseFromSliceLeaky(Detail, a, f.detail, .{ .ignore_unknown_fields = true }) catch Detail{};
        var qs = d.questions orelse &.{};
        if (pend) |p| if (std.mem.eql(u8, p.name, "AskUserQuestion") and p.input == .object) {
            if (p.input.object.get("questions")) |v| {
                qs = std.json.parseFromValueLeaky([]const Question, a, v, .{ .ignore_unknown_fields = true }) catch qs;
            }
        };
        if (qs.len == 0) {
            // Not known in detail (a session started without the hook that
            // keeps it): the menu on screen says how many.
            const pane = tmux.capturePlainLines(ctx, s, 60) catch "";
            defer if (pane.len > 0) ctx.gpa.free(pane);
            const n = signals.menuQuestions(pane);
            if (n > 0 and n != answers.len) return error.BadAnswer;
            const unknown = try a.alloc(Question, answers.len);
            @memset(unknown, .{});
            qs = unknown;
        }
        if (qs.len == 1 and qs[0].multiSelect and answers.len > 1) {
            const joined = try std.mem.join(a, ",", answers);
            answers = try a.dupe([]const u8, &.{joined});
        }
        for (try questionKeys(a, qs, answers)) |p| switch (p) {
            .text => |x| try tmux.typeText(ctx, s, x),
            .key => |x| try tmux.runQuiet(ctx, &.{ "send-keys", "-t", s, x }),
            .pick => |x| {
                const pane = tmux.capturePlainLines(ctx, s, 60) catch "";
                defer if (pane.len > 0) ctx.gpa.free(pane);
                const preview = signals.previewMenu(pane);
                try tmux.typeText(ctx, s, x);
                if (preview) {
                    ctx.sleepMs(200);
                    try tmux.runQuiet(ctx, &.{ "send-keys", "-t", s, "Enter" });
                }
            },
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
/// which starts another round. One with no comments or note (submitted
/// empty, or the window closed) sends nothing and leaves the ticket alone.
pub fn gutterSubmitted(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !CommentResult {
    const t = try board.getTicket(db, a, key);
    const path = try review.reviewPath(a, try review.ticketDir(db, a, t));
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(4 << 20)) catch return error.NoReview;
    if (!review.reviewHasFeedback(text)) {
        std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
        try board.logEvent(ctx, db, t.id, "gutter", "closed with no comments; nothing sent");
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

/// Send the ticket's automated review findings to its session ("Send
/// findings to Claude", `cl ticket autoreview <key> --send`): pasted in like
/// a gutter review and kept as a comment, which starts another round.
/// error.NoFindings unless a finished review has some (or your edit).
pub fn autoreviewSend(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !CommentResult {
    const t = try board.getTicket(db, a, key);
    var r = autoreview.load(a, t) orelse return error.NoFindings;
    if (!autoreview.usable(r)) return error.NoFindings;
    if (!autoreview.current(r, t)) return error.OldFindings;
    const s = liveSession(ctx, t) orelse return error.NoSession;
    const msg = try autoreview.message(a, r);
    try tmux.pasteText(ctx, s, msg);
    r.sent = ctx.nowSeconds();
    // Marked sent only if it is still the review that was sent (not a new
    // one started meanwhile).
    _ = try board.setAutoreviewIf(db, t.id, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})}), t.autoreview);
    const br = try board.addComment(ctx, db, a, key, "you", msg, true);
    return .{ .sent = true, .sent_back = br.sent_back, .round = (try board.getTicket(db, a, key)).round };
}

/// An automated review just finished (its reviewer's Stop hook, or
/// `--findings`): one cl started under --auto-review send has its findings
/// sent to the ticket's session now, for one round (`autoreview.sendsItself`).
/// One it can't send (no live session) stays on the board for you, and the
/// ticket is back in Needs You (`autoreview.submit` left that to this); why
/// is logged on the ticket.
pub fn afterAutoreview(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) void {
    const t = board.getTicket(db, a, key) catch return;
    const r = autoreview.load(a, t) orelse return;
    if (!autoreview.sendsItself(r, t)) return;
    if (autoreviewSend(ctx, db, a, key)) |_| {
        board.logEvent(ctx, db, t.id, "autoreview sent by itself", "") catch {};
        return;
    } else |e| board.logEvent(ctx, db, t.id, "autoreview not sent", switch (e) {
        error.NoSession => "the ticket has no live session",
        else => @errorName(e),
    }) catch {};
    board.raiseAfterReview(ctx, db, t.id, t.stage) catch {};
}

test "afterAutoreview: findings cl can't send itself stay for you" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = &env, .home = "/tmp", .tmux_blocked = true };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;
    // One you started: left alone.
    try board.setAutoreview(db, id, "{\"status\":\"done\",\"round\":1,\"findings\":[{\"title\":\"x\",\"body\":\"y\"}]}");
    afterAutoreview(ctx, db, a, k);
    try std.testing.expectEqual(@as(usize, 1), (try board.events(db, a, id)).len);
    // Started under send, but its session is gone: logged, not sent, still
    // in Review, and back in Needs You with its flag.
    try board.setAutoreview(db, id, "{\"status\":\"done\",\"round\":1,\"auto\":\"send\",\"findings\":[{\"title\":\"x\",\"body\":\"y\"}]}");
    afterAutoreview(ctx, db, a, k);
    var logged = false;
    for (try board.events(db, a, id)) |e| logged = logged or std.mem.eql(u8, e.kind, "autoreview not sent");
    try std.testing.expect(logged);
    const needs = try board.listTickets(db, a, .{ .needs = true });
    try std.testing.expectEqual(@as(usize, 1), needs.len);
    try std.testing.expectEqualStrings(board.flag_review, needs[0].flags[0].kind);
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqual(board.Stage.review, t.stage);
    try std.testing.expectEqual(@as(i64, 0), autoreview.load(a, t).?.sent);
}

test "findings from an earlier round aren't sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = &env, .home = "/tmp", .tmux_blocked = true };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;
    try board.setAutoreview(db, id, "{\"status\":\"done\",\"round\":1,\"findings\":[{\"title\":\"x\",\"body\":\"y\"}]}");
    // Round 1, current: on to the session (which it hasn't).
    try std.testing.expectError(error.NoSession, autoreviewSend(ctx, db, a, k));
    try db.exec("UPDATE tickets SET round = 2 WHERE id = ?1", .{id});
    try std.testing.expectError(error.OldFindings, autoreviewSend(ctx, db, a, k));
}

pub const TestOutcome = struct {
    passed: bool,
    /// Went to Claude: a failure, or comments you chose to send.
    sent: bool = false,
    /// It has no session to send them to; they're kept as a comment.
    unsent: bool = false,
    /// A ticket in Testing went on to Done (or to finishing).
    approved: bool = false,
};

/// Record test results. A failure goes to Claude for another round, as do
/// comments when everything passed if `send` says so (null: whenever there
/// are any). Everything passing and nothing sent approves a ticket in
/// Testing; earlier, the results are only kept on the ticket.
pub fn testResults(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, steps: []const review.StepResult, note: []const u8, send: ?bool, spin_off: bool, finish: Finish) !TestOutcome {
    const res = try review.recordResults(a, steps, note);
    const t = try board.getTicket(db, a, key);
    // Sent: the next try starts over.
    try board.setTestProgress(db, t.id, "");
    var o: TestOutcome = .{ .passed = res.passed };
    if (!res.passed or (send orelse res.commented)) {
        if (t.stage == .review) try board.move(ctx, db, a, key, .testing);
        const r = try comment(ctx, db, a, key, "you", res.text, true);
        o.sent = r.sent;
        o.unsent = r.unsent;
    } else {
        if (t.stage == .testing) try readyForDone(ctx, db, a, key, spin_off);
        _ = try board.addComment(ctx, db, a, key, "you", res.text, false);
        if (t.stage == .testing) {
            _ = try approve(ctx, db, a, key, spin_off, finish);
            o.approved = true;
        }
    }
    review.stopLaunch(ctx, a, key, null) catch {};
    return o;
}

test "gutterSubmitted: an empty review sends nothing and leaves the ticket alone" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    try tmp.dir.createDirPath(ctx.io, ".claude");
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = dir });
    const key = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Fix it" });
    try board.done(ctx, db, a, key, "fixed");
    const before = try board.getTicket(db, a, key);
    const count = "SELECT COUNT(*) FROM comments WHERE ticket = ?1";
    const comments = try db.int(count, .{before.id});

    // Window closed (gutter prints nothing), then Submit with nothing in it.
    for ([_][]const u8{ "", "# Review of `@` (jj)\n\n_(no feedback)_\n" }) |md| {
        try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/review.md", .data = md });
        try std.testing.expectEqual(CommentResult{}, try gutterSubmitted(ctx, db, a, key));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(ctx.io, ".claude/review.md", .{}));
    }
    const after = try board.getTicket(db, a, key);
    try std.testing.expectEqual(before.stage, after.stage);
    try std.testing.expectEqual(before.round, after.round);
    try std.testing.expectEqual(before.flags.len, after.flags.len);
    try std.testing.expectEqual(comments, try db.int(count, .{before.id}));
}

/// The flag of `kind` on the ticket, if it has it.
fn flagOf(t: board.Ticket, kind: []const u8) ?board.Flag {
    for (t.flags) |f| if (std.mem.eql(u8, f.kind, kind)) return f;
    return null;
}

/// The ticket is in Needs You (as `cl ticket needs` lists it), done or not.
fn inNeeds(db: board.Db, a: std.mem.Allocator, key: []const u8) !bool {
    for (try board.listTickets(db, a, .{ .needs = true })) |t| if (std.mem.eql(u8, t.key, key)) return true;
    return false;
}

test "work that doesn't land is flagged in Needs You until it does: conflicts, closed unmerged" {
    // tmux blocked: no session is live, and nothing reaches a real server.
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp", .tmux_blocked = true };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sh = struct {
        fn run(c: Ctx, al: std.mem.Allocator, argv: []const []const u8) !void {
            const r = try std.process.run(al, c.io, .{ .argv = argv });
            if (r.term != .exited or r.term.exited != 0) return error.CommandFailed;
        }
    }.run;
    sh(ctx, a, &.{ "jj", "--version" }) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    sh(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "base\n" });
    try sh(ctx, a, &.{ "git", "-C", repo, "add", "a.txt" });
    try sh(ctx, a, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" });
    try std.testing.expect(worktree.ensureJj(ctx, a, repo));
    const trunk = worktree.trunkBookmark(ctx, a, repo).?;

    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    // No after-merge command or steps: a merge runs nothing after it.
    try board.addProject(db, .{ .name = "qa", .dir = repo, .after_merge_claude = "none" });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    const ticket = struct {
        fn make(c: Ctx, d: board.Db, al: std.mem.Allocator, dir: []const u8, tr: []const u8, title: []const u8, text: []const u8) ![]const u8 {
            const k = try board.createTicket(c, d, al, .{ .project = "qa", .title = title, .stage = .testing });
            const ch = try worktree.newChange(c, al, dir, tr, title, try worktree.slug(al, k, title));
            var f = try std.Io.Dir.cwd().openDir(c.io, dir, .{});
            defer f.close(c.io);
            try f.writeFile(c.io, .{ .sub_path = "a.txt", .data = text });
            try board.setChange(d, (try board.getTicket(d, al, k)).id, ch.id, ch.bookmark);
            return k;
        }
    }.make;
    const one = try ticket(ctx, db, a, repo, trunk, "One", "one\n");
    const two = try ticket(ctx, db, a, repo, trunk, "Two", "two\n");

    // One merges; Two now conflicts. It stays in Testing, in Needs You with
    // the file that conflicts.
    try move(ctx, cfg, db, a, one, .done, false, .merge);
    try std.testing.expectEqual(board.Stage.done, (try board.getTicket(db, a, one)).stage);
    try std.testing.expectError(error.Conflicts, move(ctx, cfg, db, a, two, .done, false, .merge));
    const t2 = try board.getTicket(db, a, two);
    try std.testing.expectEqual(board.Stage.testing, t2.stage);
    try std.testing.expect(std.mem.startsWith(u8, flagOf(t2, board.flag_conflict).?.detail, "a.txt"));
    try std.testing.expect(try inNeeds(db, a, two));

    // Closed as it is, it is Done with its work left out of master: still in
    // Needs You, saying so.
    try move(ctx, cfg, db, a, two, .done, false, .close);
    const closed = try board.getTicket(db, a, two);
    try std.testing.expectEqual(board.Stage.done, closed.stage);
    const un = flagOf(closed, board.flag_unmerged).?;
    try std.testing.expect(std.mem.indexOf(u8, un.detail, "isn't in master") != null);
    try std.testing.expect(try inNeeds(db, a, two));

    // Settled in its change, merging it (Done already) clears it all.
    _ = try worktree.editChange(ctx, a, repo, closed.change);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "one and two\n" });
    try move(ctx, cfg, db, a, two, .done, false, .merge);
    const landed = try board.getTicket(db, a, two);
    try std.testing.expect(flagOf(landed, board.flag_unmerged) == null);
    try std.testing.expect(flagOf(landed, board.flag_conflict) == null);
    try std.testing.expect(!try inNeeds(db, a, two));
    const shown = try std.process.run(a, ctx.io, .{ .argv = &.{ "git", "-C", repo, "show", "master:a.txt" } });
    try std.testing.expectEqualStrings("one and two\n", shown.stdout);

    // Closing a ticket whose work is on master already raises nothing.
    try std.testing.expect(flagOf(try board.getTicket(db, a, one), board.flag_unmerged) == null);
    const three = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Three", .stage = .testing });
    try board.setChange(db, (try board.getTicket(db, a, three)).id, (try board.getTicket(db, a, one)).change, "");
    try move(ctx, cfg, db, a, three, .done, false, .close);
    try std.testing.expect(!try inNeeds(db, a, three));
}

test "a ticket with a target branch merges into it, runs no after-merge, and isn't flagged for missing trunk" {
    // tmux blocked: no session is live, and nothing reaches a real server.
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp", .tmux_blocked = true };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sh = struct {
        fn run(c: Ctx, al: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
            const r = try std.process.run(al, c.io, .{ .argv = argv });
            if (r.term != .exited or r.term.exited != 0) return error.CommandFailed;
            return r.stdout;
        }
    }.run;
    _ = sh(ctx, a, &.{ "jj", "--version" }) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    _ = sh(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    const git = [_][]const u8{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t" };
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "base\n" });
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "add", "a.txt" }));
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "commit", "-q", "-m", "init" }));
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "branch", "feature/venues" }));
    try std.testing.expect(worktree.ensureJj(ctx, a, repo));
    const master_at = try sh(ctx, a, &.{ "git", "-C", repo, "rev-parse", "master" });

    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    // Claude's after-merge steps are on (the default): a merge into trunk
    // would ask for them; one into the feature branch doesn't.
    try board.addProject(db, .{ .name = "qa", .dir = repo, .onto = "feature/venues" });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Venues", .stage = .testing });
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqualStrings("feature/venues", t.onto);
    try std.testing.expectEqualStrings("", t.onto_own);
    const ch = try worktree.newChange(ctx, a, repo, worktree.target(ctx, a, repo, t.onto).?, "QA-1: Venues", try worktree.slug(a, k, "Venues"));
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "venues\n" });
    try board.setChange(db, t.id, ch.id, ch.bookmark);

    try move(ctx, cfg, db, a, k, .done, false, .merge);
    const done = try board.getTicket(db, a, k);
    try std.testing.expectEqual(board.Stage.done, done.stage);
    try std.testing.expectEqualStrings("venues\n", try sh(ctx, a, &.{ "git", "-C", repo, "show", "feature/venues:a.txt" }));
    try std.testing.expectEqualStrings(master_at, try sh(ctx, a, &.{ "git", "-C", repo, "rev-parse", "master" }));
    try std.testing.expectEqual(@as(usize, 0), done.flags.len);
    for (try board.events(db, a, done.id)) |e| try std.testing.expect(!std.mem.startsWith(u8, e.kind, "after-merge"));
    // Its Done check measures against the feature branch: on it, not on
    // master, raises nothing (DI-24's false alarm).
    try checkLanded(ctx, db, a, k, "test");
    try std.testing.expect(flagOf(try board.getTicket(db, a, k), board.flag_unmerged) == null);

    // A ticket closed with work on neither is flagged, naming the feature branch.
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Left", .stage = .testing });
    const ch2 = try worktree.newChange(ctx, a, repo, "feature/venues", "QA-2: Left", "qa-2-left");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "b.txt", .data = "left\n" });
    try board.setChange(db, (try board.getTicket(db, a, k2)).id, ch2.id, ch2.bookmark);
    try move(ctx, cfg, db, a, k2, .done, false, .close);
    const un = flagOf(try board.getTicket(db, a, k2), board.flag_unmerged).?;
    try std.testing.expect(std.mem.indexOf(u8, un.detail, "isn't in feature/venues") != null);
    try std.testing.expect(std.mem.indexOf(u8, un.detail, "Merge it into feature/venues now") != null);
}

test "git: a ticket closed with its branch merged into its target isn't flagged; one that isn't names the target" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp", .tmux_blocked = true };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const sh = struct {
        fn run(c: Ctx, al: std.mem.Allocator, argv: []const []const u8) !void {
            const r = try std.process.run(al, c.io, .{ .argv = argv });
            if (r.term != .exited or r.term.exited != 0) return error.CommandFailed;
        }
    }.run;
    sh(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    const git = [_][]const u8{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t" };
    try sh(ctx, a, &(git ++ [_][]const u8{ "commit", "-q", "--allow-empty", "-m", "init" }));
    try sh(ctx, a, &(git ++ [_][]const u8{ "branch", "feature" }));
    // Two ticket branches off the feature branch; one is merged into it.
    for ([_][]const u8{ "qa-1-in", "qa-2-out" }) |b| {
        try sh(ctx, a, &(git ++ [_][]const u8{ "checkout", "-q", "-b", b, "feature" }));
        try sh(ctx, a, &(git ++ [_][]const u8{ "commit", "-q", "--allow-empty", "-m", b }));
    }
    try sh(ctx, a, &(git ++ [_][]const u8{ "checkout", "-q", "feature" }));
    try sh(ctx, a, &(git ++ [_][]const u8{ "merge", "-q", "--ff-only", "qa-1-in" }));
    try sh(ctx, a, &(git ++ [_][]const u8{ "checkout", "-q", "master" }));

    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = repo, .mode = .worktree });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    // The ticket's own target (the project has none).
    const k1 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "In", .stage = .testing, .onto = "feature" });
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Out", .stage = .testing, .onto = "feature" });
    try board.setSession(ctx, db, (try board.getTicket(db, a, k1)).id, "", "", "", "qa-1-in");
    try board.setSession(ctx, db, (try board.getTicket(db, a, k2)).id, "", "", "", "qa-2-out");
    try move(ctx, cfg, db, a, k1, .done, false, .close);
    try std.testing.expect(flagOf(try board.getTicket(db, a, k1), board.flag_unmerged) == null);
    try move(ctx, cfg, db, a, k2, .done, false, .close);
    const un = flagOf(try board.getTicket(db, a, k2), board.flag_unmerged).?;
    try std.testing.expect(std.mem.startsWith(u8, un.detail, "1 commit on qa-2-out isn't in feature\n"));
    try std.testing.expect(std.mem.indexOf(u8, un.detail, "finish it with Merge (into feature)") != null);
}

test "going to Done closes the ticket's session, even when a test server of its own (or its own session) is what moved it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const probe = std.process.run(gpa, io, .{ .argv = &.{ "tmux", "-V" } }) catch return error.SkipZigTest;
    gpa.free(probe.stdout);
    gpa.free(probe.stderr);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A tmux server of the test's own, named on every call; never the real one.
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const sock = try std.fmt.allocPrint(a, "/tmp/cl-test-tmux-{x}", .{rnd});
    defer std.Io.Dir.deleteFileAbsolute(io, sock) catch {};
    defer if (std.process.run(gpa, io, .{ .argv = &.{ "tmux", "-S", sock, "kill-server" } })) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {};
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const ctx: Ctx = .{ .io = io, .gpa = gpa, .perm = a, .env = &env, .home = "/tmp", .tmux_socket = sock };
    const T = struct {
        fn start(c: Ctx, name: []const u8) !void {
            const out = try tmux.run(c, &.{ "new-session", "-d", "-s", name, "sleep", "600" });
            c.gpa.free(out);
        }
        fn alive(c: Ctx, name: []const u8) bool {
            return tmux.hasSession(c, std.fmt.allocPrint(c.perm, "={s}", .{name}) catch unreachable);
        }
        /// This process "runs in" `name`: TMUX and TMUX_PANE as tmux sets them.
        fn runIn(c: Ctx, name: []const u8) !void {
            const pane = try tmux.run(c, &.{ "display-message", "-p", "-t", name, "#{pane_id}" });
            defer c.gpa.free(pane);
            try c.env.put("TMUX", try std.fmt.allocPrint(c.perm, "{s},1,0", .{c.tmux_socket.?}));
            try c.env.put("TMUX_PANE", std.mem.trimEnd(u8, pane, "\n"));
        }
        fn ticket(c: Ctx, d: board.Db, al: std.mem.Allocator, title: []const u8, session: []const u8) ![]const u8 {
            const k = try board.createTicket(c, d, al, .{ .project = "qa", .title = title, .stage = .review });
            try board.setSession(c, d, (try board.getTicket(d, al, k)).id, session, "", "", "");
            return k;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = dir, .after_merge_claude = "none" });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };

    // QA-1 has a test server running (its launch) and the human finishes it
    // from that server's board: its session closes, and so does gutter; the
    // launch running this is left for the sweep, or this would end halfway.
    const one = try T.ticket(ctx, db, a, "One", "cl_qa-1_aa");
    try T.start(ctx, "cl_qa-1_aa");
    try T.start(ctx, "clg_qa-1");
    try T.start(ctx, "clrun_qa-1_s1");
    try T.start(ctx, "clrun_qa-1_s2");
    try T.runIn(ctx, "clrun_qa-1_s1");
    try move(ctx, cfg, db, a, one, .done, false, .close);
    try std.testing.expect(!T.alive(ctx, "cl_qa-1_aa"));
    try std.testing.expect(!T.alive(ctx, "clg_qa-1"));
    try std.testing.expect(!T.alive(ctx, "clrun_qa-1_s2"));
    try std.testing.expect(T.alive(ctx, "clrun_qa-1_s1"));

    // QA-2 finishes from its own session (`cl ticket done --close`): its
    // launches stop before the session goes.
    const two = try T.ticket(ctx, db, a, "Two", "cl_qa-2_bb");
    try T.start(ctx, "cl_qa-2_bb");
    try T.start(ctx, "clrun_qa-2_s1");
    try T.runIn(ctx, "cl_qa-2_bb");
    try move(ctx, cfg, db, a, two, .done, false, .close);
    try std.testing.expect(!T.alive(ctx, "clrun_qa-2_s1"));
    try std.testing.expect(!T.alive(ctx, "cl_qa-2_bb"));
    _ = env.swapRemove("TMUX");
    _ = env.swapRemove("TMUX_PANE");

    // Whatever moved QA-3 to Done was cut off before it closed the session:
    // the sweep closes it. Not QA-4's: QA-5, not done, is using it.
    const three = try T.ticket(ctx, db, a, "Three", "cl_qa-3_cc");
    try T.start(ctx, "cl_qa-3_cc");
    try board.move(ctx, db, a, three, .done);
    const four = try T.ticket(ctx, db, a, "Four", "cl_qa_shared");
    _ = try T.ticket(ctx, db, a, "Five", "cl_qa_shared");
    try T.start(ctx, "cl_qa_shared");
    try board.move(ctx, db, a, four, .done);
    const closed = try closeLeftSessions(ctx, db, a);
    try std.testing.expectEqual(@as(usize, 1), closed.len);
    try std.testing.expectEqualStrings("cl_qa-3_cc", closed[0]);
    try std.testing.expect(!T.alive(ctx, "cl_qa-3_cc"));
    try std.testing.expect(T.alive(ctx, "cl_qa_shared"));
    try std.testing.expectEqual(@as(usize, 0), (try closeLeftSessions(ctx, db, a)).len);

    // A deleted ticket's session and launches go with it.
    const six = try T.ticket(ctx, db, a, "Six", "cl_qa-6_dd");
    try T.start(ctx, "cl_qa-6_dd");
    try T.start(ctx, "clrun_qa-6_s1");
    _ = try remove(ctx, db, a, six);
    try std.testing.expect(!T.alive(ctx, "cl_qa-6_dd"));
    try std.testing.expect(!T.alive(ctx, "clrun_qa-6_s1"));
    try std.testing.expectError(error.NotFound, board.getTicket(db, a, six));
}

test "finished with a PR and steps for after it: done, plus a follow-up parked on the PR" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    // A socket of the test's own with no server: closing its (missing)
    // session never reaches the real tmux.
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = gpa, .perm = a, .env = &env, .home = "/tmp", .tmux_socket = "/tmp/cl-test-followup-none" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = dir });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Redact metadata", .stage = .testing });
    const t = try board.getTicket(db, a, k);
    try board.setPrThen(ctx, db, t.id, "Deploy, then run the backfill.");
    try board.setFinishing(ctx, db, t.id, "pr");
    try std.testing.expect(followsUp(try board.getTicket(db, a, k)));

    // Without the PR there's nothing to park the follow-up on.
    try std.testing.expectError(error.NoPrUrl, finished(ctx, db, a, k, "", ""));
    try std.testing.expectEqual(board.Stage.testing, (try board.getTicket(db, a, k)).stage);

    try finished(ctx, db, a, k, "Opened the PR", "https://github.com/o/r/pull/31");
    const done = try board.getTicket(db, a, k);
    try std.testing.expectEqual(board.Stage.done, done.stage);
    try std.testing.expectEqual(@as(i64, 1), done.children);
    const fk = (try board.listTickets(db, a, .{ .parent = k }))[0].key;
    const f = try board.getTicket(db, a, fk);
    try std.testing.expectEqual(board.Stage.queued, f.stage);
    try std.testing.expectEqualStrings("https://github.com/o/r/pull/31", f.park.?.pr);
    try std.testing.expect(std.mem.indexOf(u8, f.body, "Deploy, then run the backfill.") != null);
    const comments = try board.comments(db, a, done.id);
    try std.testing.expect(std.mem.indexOf(u8, comments[comments.len - 1].body, fk) != null);

    // Finished with a PR and no steps: nothing follows.
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Plain PR", .stage = .testing });
    try board.setFinishing(ctx, db, (try board.getTicket(db, a, k2)).id, "pr");
    try finished(ctx, db, a, k2, "", "https://github.com/o/r/pull/32");
    try std.testing.expectEqual(@as(i64, 0), (try board.getTicket(db, a, k2)).children);
}
