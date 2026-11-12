//! Feedback on the pull request a ticket was finished with, for its park
//! (park.zig, a park with `review` set): what gh says about the PR, and
//! whether that is something its session should address.
//!
//! It keeps no state of its own beyond what the ticket says was handed over
//! (`Ticket.pr_seen`, `pr_seen_sha`). Feedback is new when someone other
//! than the PR's author (and not a bot) left a review, a comment or an
//! inline comment after the cutoff: until its session is first woken, the
//! PR's last commit (what came before the PR was opened is in the code
//! already); after that, what was handed over (a later commit doesn't
//! answer a comment its session never saw). A required check that
//! failed on the head commit is new until the session is told about that
//! commit. Approving without a word isn't feedback.
const std = @import("std");

/// What a check of the PR found.
pub const Assessment = struct {
    state: State,
    /// The PR's head commit, and when it was committed (0: unknown).
    head: []const u8 = "",
    pushed: i64 = 0,
    /// New outside feedback, oldest first.
    items: []const Item = &.{},
    /// The newest of `items` (0: none).
    newest: i64 = 0,
    /// Feedback up to this time didn't count. Woken, everything up to
    /// max(cutoff, newest) has been handed over (`handed`).
    cutoff: i64 = 0,
    /// GitHub's review decision is "changes requested".
    changes_requested: bool = false,
    /// Required checks that failed on `head`, when the session hasn't been
    /// told about that commit's.
    failed: []const Check = &.{},

    /// Something for the session to address.
    pub fn wakes(self: Assessment) bool {
        return self.state == .open and (self.items.len > 0 or self.failed.len > 0);
    }

    /// What the ticket's `pr_seen` becomes once its session is told this.
    pub fn handed(self: Assessment) i64 {
        return @max(self.cutoff, self.newest);
    }
};

pub const State = enum { open, merged, closed };

pub const Item = struct {
    who: []const u8,
    kind: Kind,
    /// A review's state ("CHANGES_REQUESTED", "COMMENTED", "APPROVED").
    state: []const u8 = "",
    body: []const u8,
    /// An inline comment's file and line (0: unknown).
    path: []const u8 = "",
    line: i64 = 0,
    url: []const u8 = "",
    at: i64,
};

pub const Kind = enum { review, comment, inline_comment };

pub const Check = struct { name: []const u8, link: []const u8 = "" };

// What gh prints. The view: `gh pr view --json` with `view_fields`.
pub const view_fields = "state,author,headRefOid,commits,reviews,comments,reviewDecision";
const Who = struct { login: []const u8 = "", is_bot: bool = false };
const View = struct {
    state: []const u8 = "",
    author: ?Who = null,
    headRefOid: []const u8 = "",
    commits: []const struct { committedDate: []const u8 = "" } = &.{},
    reviews: []const struct { author: ?Who = null, body: []const u8 = "", state: []const u8 = "", submittedAt: ?[]const u8 = null } = &.{},
    comments: []const struct { author: ?Who = null, body: []const u8 = "", createdAt: []const u8 = "", url: []const u8 = "" } = &.{},
    reviewDecision: ?[]const u8 = null,
};
/// Inline comments: `gh api` on the PR's comments, one object a line, as
/// `inline_jq` shapes them.
pub const inline_jq = "{path, line, original_line, url: .html_url, at: .created_at, body, user: .user.login, bot: (.user.type == \"Bot\")}";
const Inline = struct { path: []const u8 = "", line: ?i64 = null, original_line: ?i64 = null, url: []const u8 = "", at: []const u8 = "", body: []const u8 = "", user: []const u8 = "", bot: bool = false };
/// Required checks: `gh pr checks --required --json` with `check_fields`.
pub const check_fields = "name,bucket,link";
const CheckRow = struct { name: []const u8 = "", bucket: []const u8 = "", link: []const u8 = "" };

/// Read what gh said. `seen` and `seen_sha`: what was handed over already.
/// `checks` that aren't JSON (gh says there are no required checks) count
/// as none failing.
pub fn assess(a: std.mem.Allocator, view_json: []const u8, inline_lines: []const u8, checks_json: []const u8, seen: i64, seen_sha: []const u8) !Assessment {
    const v = std.json.parseFromSliceLeaky(View, a, view_json, .{ .ignore_unknown_fields = true }) catch return error.BadGhOutput;
    const state: State = if (std.mem.eql(u8, v.state, "MERGED")) .merged else if (std.mem.eql(u8, v.state, "CLOSED")) .closed else if (std.mem.eql(u8, v.state, "OPEN")) .open else return error.BadGhOutput;
    var r: Assessment = .{ .state = state, .head = v.headRefOid };
    if (state != .open) return r;
    r.changes_requested = if (v.reviewDecision) |d| std.mem.eql(u8, d, "CHANGES_REQUESTED") else false;
    if (v.commits.len > 0) r.pushed = parseTime(v.commits[v.commits.len - 1].committedDate) orelse 0;
    const author = if (v.author) |w| w.login else "";
    // Woken before (`seen`), that is the line: commits since may have been
    // made without seeing what came in meanwhile, and a rewrite redates them.
    const cutoff = if (seen > 0) seen else r.pushed;
    r.cutoff = cutoff;
    var items: std.ArrayList(Item) = .empty;
    for (v.reviews) |rv| {
        const w = rv.author orelse continue;
        if (!outside(w.login, w.is_bot, author)) continue;
        if (std.mem.eql(u8, rv.state, "PENDING") or std.mem.eql(u8, rv.state, "DISMISSED")) continue;
        // A review's inline comments come on their own; its body is what's left.
        const body = std.mem.trim(u8, rv.body, " \t\r\n");
        if (body.len == 0 and !std.mem.eql(u8, rv.state, "CHANGES_REQUESTED")) continue;
        const at = parseTime(rv.submittedAt orelse "") orelse continue;
        if (at > cutoff) try items.append(a, .{ .who = w.login, .kind = .review, .state = rv.state, .body = body, .at = at });
    }
    for (v.comments) |c| {
        const w = c.author orelse continue;
        if (!outside(w.login, w.is_bot, author)) continue;
        const at = parseTime(c.createdAt) orelse continue;
        if (at > cutoff) try items.append(a, .{ .who = w.login, .kind = .comment, .body = std.mem.trim(u8, c.body, " \t\r\n"), .url = c.url, .at = at });
    }
    var lines = std.mem.splitScalar(u8, inline_lines, '\n');
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
        const c = std.json.parseFromSliceLeaky(Inline, a, l, .{ .ignore_unknown_fields = true }) catch return error.BadGhOutput;
        if (!outside(c.user, c.bot, author)) continue;
        const at = parseTime(c.at) orelse continue;
        if (at > cutoff) try items.append(a, .{ .who = c.user, .kind = .inline_comment, .body = std.mem.trim(u8, c.body, " \t\r\n"), .path = c.path, .line = c.line orelse c.original_line orelse 0, .url = c.url, .at = at });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.at < y.at;
        }
    }.lt);
    r.items = items.items;
    for (r.items) |it| r.newest = @max(r.newest, it.at);
    if (r.head.len > 0 and !std.mem.eql(u8, r.head, seen_sha)) {
        if (std.json.parseFromSliceLeaky([]const CheckRow, a, checks_json, .{ .ignore_unknown_fields = true })) |rows| {
            var failed: std.ArrayList(Check) = .empty;
            for (rows) |c| if (std.mem.eql(u8, c.bucket, "fail")) try failed.append(a, .{ .name = c.name, .link = c.link });
            r.failed = failed.items;
        } else |_| {}
    }
    return r;
}

/// Not the PR's author, and not a bot.
fn outside(login: []const u8, bot: bool, author: []const u8) bool {
    if (bot or login.len == 0 or std.mem.eql(u8, login, author)) return false;
    return !std.mem.endsWith(u8, login, "[bot]") and !std.mem.eql(u8, login, "github-actions");
}

/// "2026-11-10T16:14:54Z" (UTC, as GitHub gives times) in Unix seconds.
pub fn parseTime(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[s.len - 1] != 'Z') return null;
    const n = struct {
        fn f(x: []const u8) ?i64 {
            return std.fmt.parseInt(i64, x, 10) catch null;
        }
    }.f;
    const y = n(s[0..4]) orelse return null;
    const m = n(s[5..7]) orelse return null;
    const d = n(s[8..10]) orelse return null;
    const hh = n(s[11..13]) orelse return null;
    const mm = n(s[14..16]) orelse return null;
    const ss = n(s[17..19]) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/// One line for the board: what woke it.
pub fn headline(a: std.mem.Allocator, r: Assessment) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    if (r.items.len > 0) {
        var who: std.ArrayList([]const u8) = .empty;
        for (r.items) |it| {
            for (who.items) |x| {
                if (std.mem.eql(u8, x, it.who)) break;
            } else try who.append(a, it.who);
        }
        try w.print("{d} new review comment{s} from {s}", .{ r.items.len, if (r.items.len == 1) "" else "s", try std.mem.join(a, ", ", who.items) });
        if (r.changes_requested) try w.writeAll("; changes requested");
    }
    if (r.failed.len > 0) {
        if (r.items.len > 0) try w.writeAll("; ");
        var names: std.ArrayList([]const u8) = .empty;
        for (r.failed) |c| try names.append(a, c.name);
        try w.print("required check{s} failed: {s}", .{ if (r.failed.len == 1) "" else "s", try std.mem.join(a, ", ", names.items) });
    }
    return aw.written();
}

/// The longest a comment's text goes into the note; the link has all of it.
const max_body = 4000;

/// What the ticket's session is told: the feedback, and how to finish the
/// round. `push`: how to push to the PR's branch.
pub fn note(a: std.mem.Allocator, key: []const u8, pr_url: []const u8, push: []const u8, r: Assessment) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("New feedback on this ticket's pull request {s}", .{pr_url});
    if (r.changes_requested) try w.writeAll(" (changes requested)");
    try w.writeAll(":\n");
    for (r.items) |it| {
        switch (it.kind) {
            .review => try w.print("\n- {s} reviewed it ({s})", .{ it.who, reviewState(it.state) }),
            .comment => try w.print("\n- {s} commented", .{it.who}),
            .inline_comment => if (it.line > 0)
                try w.print("\n- {s} commented on {s}:{d}", .{ it.who, it.path, it.line })
            else
                try w.print("\n- {s} commented on {s}", .{ it.who, it.path }),
        }
        if (it.url.len > 0) try w.print(" ({s})", .{it.url});
        try w.writeAll(":\n");
        const body = if (it.body.len > max_body) it.body[0..max_body] else it.body;
        var ls = std.mem.splitScalar(u8, body, '\n');
        while (ls.next()) |l| try w.print("  > {s}\n", .{l});
        if (it.body.len > max_body) try w.writeAll("  > [cut: the link has the rest]\n");
    }
    if (r.failed.len > 0) {
        try w.print("\nRequired checks failed on the PR's head commit {s}:\n", .{r.head[0..@min(r.head.len, 12)]});
        for (r.failed) |c| if (c.link.len > 0) try w.print("- {s}: {s}\n", .{ c.name, c.link }) else try w.print("- {s}\n", .{c.name});
    }
    try w.print(
        \\
        \\Address it: check each point against the code and fix what is real, then push to the PR's branch ({s}). Don't merge the PR, and don't post replies on GitHub unless I've said to: put a proposed reply to each comment in your summary instead (and say which points you disagree with, and why). The whole thread is in `gh pr view {s} --comments` and `gh api` on the PR's review comments. When you're through, run `cl ticket done {s}` as usual: cl parks it on the PR again.
    , .{ push, pr_url, key });
    return aw.written();
}

fn reviewState(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "CHANGES_REQUESTED")) return "changes requested";
    if (std.mem.eql(u8, s, "APPROVED")) return "approved";
    return "commented";
}

// ---- tests ----

const testing = std.testing;

/// gh's output for a PR (the shapes of a real one's), in tests.
pub const fake_view =
    \\{"state":"OPEN","author":{"login":"jself","is_bot":false},"headRefOid":"e8e708df549eba172bb197f9ea04e8e002a5bc0c","reviewDecision":"CHANGES_REQUESTED",
    \\ "commits":[{"committedDate":"2026-11-06T22:24:20Z"},{"committedDate":"2026-11-10T12:00:00Z"}],
    \\ "reviews":[{"author":{"login":"hryanjones"},"body":"","state":"COMMENTED","submittedAt":"2026-11-10T16:15:00Z"},
    \\            {"author":{"login":"hryanjones"},"body":"Two things to fix first.","state":"CHANGES_REQUESTED","submittedAt":"2026-11-10T16:16:00Z"},
    \\            {"author":{"login":"sam"},"body":"","state":"APPROVED","submittedAt":"2026-11-10T17:00:00Z"},
    \\            {"author":{"login":"old"},"body":"Before the push","state":"COMMENTED","submittedAt":"2026-11-09T10:00:00Z"}],
    \\ "comments":[{"author":{"login":"jself"},"body":"My own note","createdAt":"2026-11-10T18:00:00Z","url":"https://github.com/o/r/pull/31#issuecomment-1"},
    \\             {"author":{"login":"codecov","is_bot":true},"body":"Coverage 80%","createdAt":"2026-11-10T18:00:00Z","url":"https://github.com/o/r/pull/31#issuecomment-2"},
    \\             {"author":{"login":"sam"},"body":"Does this need a migration?","createdAt":"2026-11-10T18:30:00Z","url":"https://github.com/o/r/pull/31#issuecomment-3"}]}
;
pub const fake_inline =
    \\{"at":"2026-11-10T16:14:54Z","body":"This puts a GitHub request in front of the row write.","line":null,"original_line":52,"path":"apps/web/src/app/api/items/[id]/route.ts","url":"https://github.com/o/r/pull/31#discussion_r1","user":"hryanjones","bot":false}
    \\{"at":"2026-11-10T16:14:58Z","body":"Fires on adoption too.","line":196,"original_line":196,"path":"snapshot.ts","url":"https://github.com/o/r/pull/31#discussion_r2","user":"hryanjones","bot":false}
    \\{"at":"2026-11-10T16:20:00Z","body":"Thanks","line":196,"original_line":196,"path":"snapshot.ts","url":"https://github.com/o/r/pull/31#discussion_r3","user":"jself","bot":false}
    \\
;
pub const fake_checks =
    \\[{"name":"Typecheck, lint, test, build","bucket":"fail","link":"https://github.com/o/r/actions/runs/1/job/2"},{"name":"Deploy preview","bucket":"pass","link":""}]
;

test parseTime {
    try testing.expectEqual(@as(?i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1762791294), parseTime("2025-11-10T16:14:54Z"));
    try testing.expectEqual(@as(?i64, 951782400), parseTime("2000-02-29T00:00:00Z"));
    for ([_][]const u8{ "", "2026-11-10", "2026-13-01T00:00:00Z", "2026-11-10 16:14:54Z", "2026-11-10T16:14:54+01:00" }) |bad| try testing.expectEqual(@as(?i64, null), parseTime(bad));
}

test "outside feedback newer than the last push and what was handed over wakes it, once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try assess(a, fake_view, fake_inline, fake_checks, 0, "");
    try testing.expect(r.wakes());
    try testing.expect(r.changes_requested);
    // Not the author's own, the bot's, a bare approval, an empty review that
    // only holds inline comments, or what came before the push.
    try testing.expectEqual(@as(usize, 4), r.items.len);
    try testing.expectEqual(Kind.inline_comment, r.items[0].kind);
    try testing.expectEqualStrings("apps/web/src/app/api/items/[id]/route.ts", r.items[0].path);
    try testing.expectEqual(@as(i64, 52), r.items[0].line);
    try testing.expectEqual(Kind.review, r.items[2].kind);
    try testing.expectEqualStrings("CHANGES_REQUESTED", r.items[2].state);
    try testing.expectEqualStrings("Does this need a migration?", r.items[3].body);
    try testing.expectEqual(parseTime("2026-11-10T18:30:00Z").?, r.newest);
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("Typecheck, lint, test, build", r.failed[0].name);

    const n = try note(a, "QA-6", "https://github.com/o/r/pull/31", "jj git push -b qa-6", r);
    for ([_][]const u8{ "hryanjones commented on apps/web/src/app/api/items/[id]/route.ts:52 (https://github.com/o/r/pull/31#discussion_r1)", "  > Fires on adoption too.", "sam commented (https://github.com/o/r/pull/31#issuecomment-3)", "hryanjones reviewed it (changes requested)", "Typecheck, lint, test, build: https://github.com/o/r/actions/runs/1/job/2", "jj git push -b qa-6", "Don't merge the PR", "proposed reply", "cl ticket done QA-6" }) |s| {
        if (std.mem.indexOf(u8, n, s) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ s, n });
            return error.TestExpectedEqual;
        }
    }
    try testing.expect(std.mem.indexOf(u8, n, "My own note") == null);
    try testing.expectEqualStrings("4 new review comments from hryanjones, sam; changes requested; required check failed: Typecheck, lint, test, build", try headline(a, r));

    // Handed over: the same comments and the same commit's failure don't wake it again.
    try testing.expectEqual(r.newest, r.handed());
    const again = try assess(a, fake_view, fake_inline, fake_checks, r.handed(), r.head);
    try testing.expect(!again.wakes());
    // Before it was ever woken, a commit after them answers them (they came
    // before the PR was opened); a failed check is the new commit's to have.
    const pushed = try std.mem.replaceOwned(u8, a, fake_view, "2026-11-10T12:00:00Z", "2026-11-11T09:00:00Z");
    const after_push = try assess(a, pushed, fake_inline, "no required checks reported on the 'x' branch", 0, r.head);
    try testing.expect(!after_push.wakes());
    // Woken, a comment that came in during the round is still new, even
    // though the round's commit (11-11 09:00) is newer than it.
    const during = try std.mem.concat(a, u8, &.{ fake_inline, "{\"at\":\"2026-11-10T20:00:00Z\",\"body\":\"While you work\",\"line\":3,\"path\":\"a.zig\",\"url\":\"u\",\"user\":\"sam\",\"bot\":false}\n" });
    const more = try assess(a, pushed, during, "", r.handed(), r.head);
    try testing.expectEqual(@as(usize, 1), more.items.len);
    try testing.expectEqualStrings("While you work", more.items[0].body);
    // Woken only for a failed check, what came before the cutoff stays handled.
    const ci_only = try assess(a, pushed, "", fake_checks, 0, "");
    try testing.expectEqual(@as(usize, 0), ci_only.items.len);
    try testing.expect(ci_only.wakes());
    try testing.expectEqual(parseTime("2026-11-11T09:00:00Z").?, ci_only.handed());
}

test "a merged or closed PR, and gh output that isn't the PR" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const merged = try assess(a, "{\"state\":\"MERGED\",\"headRefOid\":\"abc\"}", "", "", 0, "");
    try testing.expectEqual(State.merged, merged.state);
    try testing.expect(!merged.wakes());
    try testing.expectEqual(State.closed, (try assess(a, "{\"state\":\"CLOSED\"}", "", "", 0, "")).state);
    try testing.expectError(error.BadGhOutput, assess(a, "GraphQL: Could not resolve to a Repository", "", "", 0, ""));
    try testing.expectError(error.BadGhOutput, assess(a, "{\"state\":\"\"}", "", "", 0, ""));
}
