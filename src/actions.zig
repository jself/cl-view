//! Ticket actions that reach into a session (typing, keys), shared by
//! `cl ticket` and the web board so both do exactly the same thing.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const review = @import("review.zig");

pub const Error = error{
    /// The ticket has no live session to act on.
    NoSession,
    /// Nothing is waiting for an answer.
    NothingAsked,
    /// The answers don't fit what is asked.
    BadAnswer,
    /// No review submitted in gutter yet.
    NoReview,
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

/// Approve; an approved plan also tells Claude to go ahead.
pub fn approve(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !board.Stage {
    const from = try board.approve(ctx, db, a, key);
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
pub fn testResults(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, checks: []const review.Check, note: []const u8) !bool {
    const res = try review.recordResults(a, checks, note);
    if (res.passed) {
        _ = try board.addComment(ctx, db, a, key, "you", res.text, false);
        const t = try board.getTicket(db, a, key);
        if (t.stage == .testing) _ = try board.approve(ctx, db, a, key);
    } else {
        const t = try board.getTicket(db, a, key);
        if (t.stage == .review) try board.move(ctx, db, a, key, .testing);
        _ = try comment(ctx, db, a, key, "you", res.text, true);
    }
    review.stopLaunch(ctx, a, key) catch {};
    return res.passed;
}
