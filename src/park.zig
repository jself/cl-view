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
//!
//! Parked on a pull request (`--pr`), cl writes the check itself (gh asks
//! for the PR's state): merged wakes it, and closed without merging ends the
//! park with a `pr-closed` flag rather than checking until it gives up. A
//! ticket finished with a PR and steps for after it merges (`pr_then`) gets
//! a follow-up sub-ticket parked that way (`followUp`).
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const actions = @import("actions.zig");
const dispatch = @import("dispatch.zig");
const review = @import("review.zig");

pub const default_every = 3600;
pub const default_max = 7 * 86400;
/// How long a park on a PR waits for the merge: reviews take longer.
pub const default_max_pr = 14 * 86400;
/// What the check cl writes for a PR exits with when the PR was closed
/// without merging (only a park on a PR reads it so).
const pr_closed_exit = 3;
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
    /// "" with a PR: "PR #n: waiting to merge".
    reason: []const u8 = "",
    /// Shell command; "" for none.
    until: []const u8 = "",
    /// A pull request to wait on instead of `until`: its URL, "#n" or "n"
    /// (the ticket's origin remote's), or "owner/repo#n".
    pr: []const u8 = "",
    every: i64 = default_every,
    /// null: default_max, or default_max_pr on a PR.
    max: ?i64 = null,
};

/// A pull request on a GitHub host.
pub const Pr = struct {
    /// As gh's -R takes it: "owner/repo", or "host/owner/repo" off github.com.
    repo: []const u8,
    number: u32,
    url: []const u8,

    /// The check: exit 0 once it's merged, `pr_closed_exit` once it's
    /// closed without merging, 1 otherwise (open, or gh failed). It prints
    /// the state, which the board shows as the last check.
    pub fn check(p: Pr, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "s=$(gh pr view {d} -R {s} --json state -q .state) || exit 1; echo \"PR #{d}: $s\"; case \"$s\" in MERGED) exit 0;; CLOSED) exit {d};; esac; exit 1", .{ p.number, p.repo, p.number, pr_closed_exit });
    }
};

/// A host and "owner/repo" path as a Pr's repo.
fn repoOf(a: std.mem.Allocator, host: []const u8, path: []const u8) !?[]const u8 {
    const p = std.mem.trim(u8, path, "/");
    const p2 = if (std.mem.endsWith(u8, p, ".git")) p[0 .. p.len - 4] else p;
    const slash = std.mem.indexOfScalar(u8, p2, '/') orelse return null;
    if (slash == 0 or slash + 1 == p2.len or std.mem.indexOfScalar(u8, p2[slash + 1 ..], '/') != null) return null;
    if (host.len == 0) return null;
    // It goes into the check's shell command: names only, nothing to quote.
    for ([_][]const u8{ host, p2 }) |part| for (part) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and c != '/') return null;
    };
    return if (std.ascii.eqlIgnoreCase(host, "github.com")) try a.dupe(u8, p2) else try std.fmt.allocPrint(a, "{s}/{s}", .{ host, p2 });
}

/// The repo a git remote's URL points at ("git@github.com:o/r.git",
/// "https://github.com/o/r", "ssh://git@host:22/o/r.git"); null when it
/// isn't one of those.
pub fn remoteRepo(a: std.mem.Allocator, url_in: []const u8) !?[]const u8 {
    var url = std.mem.trim(u8, url_in, " \t\r\n");
    var scp = true;
    if (std.mem.indexOf(u8, url, "://")) |i| {
        url = url[i + 3 ..];
        scp = false;
    }
    if (std.mem.indexOfScalar(u8, url, '@')) |i| url = url[i + 1 ..];
    // scp-like: host:path. Otherwise host[:port]/path.
    const cut = if (scp) std.mem.indexOfAny(u8, url, ":/") else std.mem.indexOfScalar(u8, url, '/');
    const i = cut orelse return null;
    var host = url[0..i];
    if (std.mem.indexOfScalar(u8, host, ':')) |c| host = host[0..c];
    return repoOf(a, host, url[i + 1 ..]);
}

/// Read a PR as `park --pr` takes it. `origin`: the ticket's origin
/// remote's repo, for "#n" (null when it has none).
pub fn parsePr(a: std.mem.Allocator, spec_in: []const u8, origin: ?[]const u8) !Pr {
    const spec = std.mem.trim(u8, spec_in, " \t\r\n");
    if (std.mem.indexOf(u8, spec, "://")) |i| {
        // https://<host>/<owner>/<repo>/pull/<n>[/files...]
        const rest = spec[i + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadPr;
        const host = rest[0..slash];
        var it = std.mem.splitScalar(u8, rest[slash + 1 ..], '/');
        const owner = it.next() orelse return error.BadPr;
        const name = it.next() orelse return error.BadPr;
        if (!std.mem.eql(u8, it.next() orelse "", "pull")) return error.BadPr;
        const n = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return error.BadPr;
        const repo = try repoOf(a, host, try std.fmt.allocPrint(a, "{s}/{s}", .{ owner, name })) orelse return error.BadPr;
        return pr(a, repo, n);
    }
    const hash = std.mem.lastIndexOfScalar(u8, spec, '#');
    const num = if (hash) |h| spec[h + 1 ..] else spec;
    const n = std.fmt.parseInt(u32, num, 10) catch return error.BadPr;
    if (n == 0) return error.BadPr;
    const before = if (hash) |h| spec[0..h] else "";
    if (before.len > 0) return pr(a, try repoOf(a, "github.com", before) orelse return error.BadPr, n);
    return pr(a, origin orelse return error.NoRemote, n);
}

fn pr(a: std.mem.Allocator, repo: []const u8, n: u32) !Pr {
    // "host/owner/repo" has two slashes; on github.com it's just owner/repo.
    const off_github = std.mem.count(u8, repo, "/") == 2;
    return .{ .repo = repo, .number = n, .url = if (off_github)
        try std.fmt.allocPrint(a, "https://{s}/pull/{d}", .{ repo, n })
    else
        try std.fmt.allocPrint(a, "https://github.com/{s}/pull/{d}", .{ repo, n }) };
}

test parsePr {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const u = try parsePr(a, "https://github.com/epoch/qa-tool/pull/31/files", null);
    try std.testing.expectEqualStrings("epoch/qa-tool", u.repo);
    try std.testing.expectEqual(@as(u32, 31), u.number);
    try std.testing.expectEqualStrings("https://github.com/epoch/qa-tool/pull/31", u.url);
    const h = try parsePr(a, "#30", "epoch/qa-tool");
    try std.testing.expectEqualStrings("https://github.com/epoch/qa-tool/pull/30", h.url);
    try std.testing.expectEqual(@as(u32, 7), (try parsePr(a, "7", "o/r")).number);
    try std.testing.expectEqualStrings("o/r", (try parsePr(a, "o/r#7", null)).repo);
    const ghe = try parsePr(a, "https://git.corp.io/team/app/pull/5", null);
    try std.testing.expectEqualStrings("git.corp.io/team/app", ghe.repo);
    try std.testing.expectEqualStrings("https://git.corp.io/team/app/pull/5", ghe.url);
    try std.testing.expectError(error.NoRemote, parsePr(a, "#30", null));
    for ([_][]const u8{ "", "#", "#0", "abc", "https://github.com/o/r/issues/3", "https://github.com/o", "a/b/c#1", "https://github.com/o;touch${IFS}x/r/pull/1", "o$(id)/r#2", "https://git hub.com/o/r/pull/1" }) |bad|
        try std.testing.expectError(error.BadPr, parsePr(a, bad, "o/r"));
    try std.testing.expectEqualStrings("o/r", (try remoteRepo(a, "git@github.com:o/r.git\n")).?);
    try std.testing.expectEqualStrings("o/r", (try remoteRepo(a, "https://github.com/o/r")).?);
    try std.testing.expectEqualStrings("o/r", (try remoteRepo(a, "ssh://git@github.com:22/o/r.git")).?);
    try std.testing.expectEqualStrings("git.corp.io/t/app", (try remoteRepo(a, "git@git.corp.io:t/app.git")).?);
    try std.testing.expect(try remoteRepo(a, "/srv/git/app.git") == null);
}

/// The repo of the origin remote of the checkout at `dir` (jj's remotes
/// first: a jj workspace has no .git of its own); null without one.
fn originRepo(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    if (runOut(ctx, a, dir, &.{ "jj", "git", "remote", "list" })) |out| {
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |l| {
            const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
            if (std.mem.eql(u8, l[0..sp], "origin")) return remoteRepo(a, l[sp + 1 ..]) catch null;
        }
    }
    const url = runOut(ctx, a, dir, &.{ "git", "remote", "get-url", "origin" }) orelse return null;
    return remoteRepo(a, url) catch null;
}

fn runOut(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, argv: []const []const u8) ?[]const u8 {
    const r = std.process.run(a, ctx.io, .{ .argv = argv, .cwd = .{ .path = dir } }) catch return null;
    if (r.term != .exited or r.term.exited != 0) return null;
    return r.stdout;
}

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
    var reason = std.mem.trim(u8, o.reason, " \t\r\n");
    var until = std.mem.trim(u8, o.until, " \t\r\n");
    const pr_spec = std.mem.trim(u8, o.pr, " \t\r\n");
    var the_pr: ?Pr = null;
    if (pr_spec.len > 0) {
        if (until.len > 0) return error.BadInput;
        const origin = if (std.mem.indexOfScalar(u8, pr_spec, '/') == null) originRepo(ctx, a, try review.ticketDir(db, a, t)) else null;
        the_pr = try parsePr(a, pr_spec, origin);
        until = try the_pr.?.check(a);
        if (reason.len == 0) reason = try std.fmt.allocPrint(a, "PR #{d}: waiting to merge", .{the_pr.?.number});
    }
    if (reason.len == 0) return error.BadInput;
    const now = ctx.nowSeconds();
    try board.setPark(ctx, db, t.id, .{
        .reason = reason,
        .until = until,
        .every = if (until.len > 0) o.every else 0,
        .at = now,
        .deadline = if (until.len > 0) now + (o.max orelse @as(i64, if (the_pr != null) default_max_pr else default_max)) else 0,
        // The first check right away: it may be over already, and a broken
        // command shows at once.
        .next = now,
        .pr = if (the_pr) |x| x.url else "",
    });
    // What an earlier park left is settled by this one.
    try board.clearFlagId(ctx, db, t.id, board.flag_unparked);
    try board.clearFlagId(ctx, db, t.id, board.flag_park_expired);
    try board.clearFlagId(ctx, db, t.id, board.flag_pr_closed);
    // A todo's wait is yours: its talk session (if any) is no work to stop,
    // so it stays open (Claude may be the one parking it, from inside), and
    // the dispatcher leaves a todo alone anyway.
    if (t.todo) return .{};
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

/// Kill the parked ticket's session, as `cl ticket kill` does. Not a
/// todo's talk session: see `park`.
pub fn stopSession(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    if ((try board.getTicket(db, a, key)).todo) return;
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
/// told so. A todo has no session to resume: its park just ends.
pub fn unpark(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, @"resume": bool) !Unparked {
    const t = try board.getTicket(db, a, key);
    const p = try board.takePark(ctx, db, a, t.id, null) orelse return error.NotParked;
    try board.logEvent(ctx, db, t.id, "unparked", "by you");
    if (!@"resume" or t.todo) return .{ .reason = p.reason, .resumed = null };
    const r = try resumeWith(ctx, cfg, db, a, t.key, try std.fmt.allocPrint(a, "Unparked by you: {s}. Continue.", .{p.reason}));
    return .{ .reason = p.reason, .resumed = r };
}

/// Start the ticket's session again (resuming its conversation where Claude
/// still has it) with `note` for it.
fn resumeWith(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, note: []const u8) !Resumed {
    _ = try board.addComment(ctx, db, a, key, "cl", note, false);
    const t = try board.getTicket(db, a, key);
    dispatch.start(ctx, cfg, db, a, t, false) catch |e| switch (e) {
        // It waits in Queued; the dispatcher starts it there, note and all.
        // One that was already there (parked without a session) is still
        // marked killed, which the dispatcher would wait on forever.
        error.TargetBusy => {
            try db.exec("UPDATE tickets SET killed = 0 WHERE id = ?1", .{t.id});
            return .waiting;
        },
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

/// `cl ticket park-check <key> --at <when>` detached (`Ctx.detach`), so a
/// restart of `cl web` leaves it running.
fn spawnCheck(ctx: Ctx, a: std.mem.Allocator, key: []const u8, at: i64) !void {
    try ctx.detach(&.{ "ticket", "park-check", key, "--at", try std.fmt.allocPrint(a, "{d}", .{at}) });
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
    if (result.ok) wake(ctx, cfg, db, a, t, p) else if (result.closed) prClosed(ctx, db, a, t, p) catch {};
}

/// `closed`: a park on a PR whose PR was closed without merging.
const CheckResult = struct { ok: bool, closed: bool = false, text: []const u8 };

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
    // Not `exec sh -c`: this shell keeps the output open until the check
    // ends, so a check that closes its own (`exec >/dev/null`) is still
    // timed out (`runLimited` times the output). `exit` keeps it from
    // being exec'd away as the last command.
    const res = try runLimited(ctx, a, &.{ "sh", "-c", "exec </dev/null 2>&1; sh -c \"$CL_PARK_UNTIL\"; exit $?" }, dir, &env, limit);
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    const what = if (res.timed_out)
        try std.fmt.allocPrint(a, "timed out after {s}", .{try formatDuration(a, limit)})
    else if (code == null)
        "killed"
    else
        try std.fmt.allocPrint(a, "exit {d}", .{code.?});
    const last = lastLine(res.out);
    return .{
        .ok = code == 0 and !res.timed_out,
        .closed = p.pr.len > 0 and code == pr_closed_exit and !res.timed_out,
        .text = if (last.len > 0) try std.fmt.allocPrint(a, "{s}: {s}", .{ what, last }) else what,
    };
}

const Limited = struct { term: std.process.Child.Term, out: []const u8, timed_out: bool };

/// Run `argv` in `dir` with its stdout, in a process group of its own, and
/// stop the whole group once it has run `limit` seconds: TERM, then KILL 10
/// s on. What GNU `timeout` did, done here because macOS has no `timeout`.
/// The limit holds until its stdout closes, so `argv` must keep it open
/// while it runs (checkIn's shell does).
fn runLimited(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8, dir: []const u8, env: *const std.process.Environ.Map, limit: i64) !Limited {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer child.kill(ctx.io);
    const group = -child.id.?;
    var buf: std.Io.File.MultiReader.Buffer(1) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, ctx.io, buf.toStreams(), &.{child.stdout.?});
    defer mr.deinit();
    var timed_out = false;
    var deadline: std.Io.Timeout = .{ .deadline = .fromNow(ctx.io, .{ .raw = .fromSeconds(limit), .clock = .awake }) };
    while (true) {
        mr.fill(64, deadline) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (!timed_out) {
                    timed_out = true;
                    std.posix.kill(group, .TERM) catch {};
                    deadline = .{ .deadline = .fromNow(ctx.io, .{ .raw = .fromSeconds(10), .clock = .awake }) };
                } else {
                    std.posix.kill(group, .KILL) catch {};
                    deadline = .none;
                }
                continue;
            },
            else => |e| return e,
        };
        if (mr.reader(0).buffered().len > 256 * 1024) {
            std.posix.kill(group, .KILL) catch {};
            return error.StreamTooLong;
        }
    }
    try mr.checkAnyError();
    const term = try child.wait(ctx.io);
    return .{ .term = term, .out = try mr.toOwnedSlice(0), .timed_out = timed_out };
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

test runLimited {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = a, .env = &env, .home = "/tmp" };
    const done = try runLimited(ctx, a, &.{ "sh", "-c", "echo one; echo two; exit 4" }, "/", &env, 5);
    try testing.expect(!done.timed_out);
    try testing.expectEqual(@as(u8, 4), done.term.exited);
    try testing.expectEqualStrings("one\ntwo\n", done.out);
    // Over its time: the whole group goes, the background sleep (which holds
    // the output open) too, so it's over in about a second, not thirty.
    const start = ctx.nowSeconds();
    const slow = try runLimited(ctx, a, &.{ "sh", "-c", "echo started; sleep 30 & sleep 30" }, "/", &env, 1);
    try testing.expect(slow.timed_out);
    try testing.expectEqualStrings("started\n", slow.out);
    try testing.expect(ctx.nowSeconds() - start < 10);
}

test "a park check that closes its output is still timed out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = a, .env = &env, .home = "/tmp" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try board.addProject(db, .{ .name = "qa", .dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a) });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Waits", .stage = .review });
    _ = try park(ctx, db, a, k, .{ .reason = "x", .until = "echo going quiet; exec >/dev/null 2>&1; sleep 30", .every = 1 });
    const t = try board.getTicket(db, a, k);
    const start = ctx.nowSeconds();
    const r = check(ctx, db, a, t, t.park.?);
    try testing.expect(!r.ok);
    try testing.expect(std.mem.startsWith(u8, r.text, "timed out after "));
    try testing.expect(std.mem.endsWith(u8, r.text, ": going quiet"));
    try testing.expect(ctx.nowSeconds() - start < 10);
}

test lastLine {
    try std.testing.expectEqualStrings("no checks reported", lastLine("pending\nno checks reported\n\n"));
    try std.testing.expectEqualStrings("", lastLine("  \n"));
}

/// The PR it waited on was closed without merging: the park ends with a
/// `pr-closed` flag (it won't merge now), and the session stays stopped.
fn prClosed(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, p: board.Park) !void {
    _ = try board.takePark(ctx, db, a, t.id, p.at) orelse return;
    try board.logEvent(ctx, db, t.id, "pr closed", p.pr);
    try board.setFlagId(ctx, db, t.id, board.flag_pr_closed, "auto", try std.fmt.allocPrint(a, "{s} was closed without merging, so the park ended; its session stays stopped{s}.", .{
        p.pr, if (t.started) "" else " (it never started: `cl ticket start` runs it anyway, `cl ticket rm` drops it)",
    }));
}

/// The note a park's session resumes with once its check passes.
fn metNote(a: std.mem.Allocator, t: board.Ticket, p: board.Park) ![]const u8 {
    // A follow-up that never ran has nothing to continue: its body says what to do.
    const go = if (t.session_id.len > 0) " Continue." else "";
    if (p.pr.len > 0) return std.fmt.allocPrint(a, "The PR it waited on has merged: {s}.{s}", .{ p.pr, go });
    return std.fmt.allocPrint(a, "Parked condition met: {s}.{s}", .{ p.reason, go });
}

/// The check passed: the park ends, the ticket comes back to Needs You and
/// its session resumes, told what happened.
fn wake(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, p: board.Park) void {
    const took = board.takePark(ctx, db, a, t.id, p.at) catch return;
    if (took == null) return; // Unparked (or parked again) meanwhile.
    board.logEvent(ctx, db, t.id, "park condition met", p.reason) catch {};
    board.setFlagId(ctx, db, t.id, board.flag_unparked, "auto", (if (p.pr.len > 0) std.fmt.allocPrint(a, "PR merged: {s}", .{p.pr}) else std.fmt.allocPrint(a, "Parked condition met: {s}", .{p.reason})) catch p.reason) catch {};
    // A todo is yours: the flag tells you, and there is no session to resume.
    if (t.todo) return;
    const note = metNote(a, t, p) catch return;
    // Shelved in Backlog: it isn't to start now. The note waits for whenever
    // it is queued again.
    if (t.stage == .backlog) {
        holdInBacklog(ctx, db, a, t, note) catch {};
        return;
    }
    // Its project is paused: it waits in Queued, note and all, and the
    // dispatcher resumes it there once the project resumes.
    if (board.projectPaused(db, t.project) catch false) {
        holdForPause(ctx, db, a, t, note) catch |e| {
            board.setFlagId(ctx, db, t.id, "start-failed", "auto", dispatch.failureReason(e)) catch {};
        };
        return;
    }
    _ = resumeWith(ctx, cfg, db, a, t.key, note) catch |e| {
        board.setFlagId(ctx, db, t.id, "start-failed", "auto", dispatch.failureReason(e)) catch {};
    };
}

/// A ticket finished with a PR (`pr_url`) and steps for after it merges
/// (`steps`): a sub-ticket that does them, in Queued and parked on the PR,
/// so a fresh session starts on it once the PR merges. Returns its key.
pub fn followUp(ctx: Ctx, db: board.Db, a: std.mem.Allocator, parent: board.Ticket, pr_url: []const u8, steps: []const u8) ![]const u8 {
    const the_pr = try parsePr(a, pr_url, null);
    const title = try std.fmt.allocPrint(a, "After PR #{d} merges: {s}", .{ the_pr.number, parent.title });
    const body = try std.fmt.allocPrint(a,
        \\Follow-up of {s} ({s}), which was finished with the pull request {s}. That PR has merged now; what's left to do after it:
        \\
        \\{s}
        \\
        \\It merged on the remote, so the local checkout may not have it yet: fetch it first (`jj git fetch`, or `git pull`) if these steps need it.
    , .{ parent.key, parent.title, the_pr.url, std.mem.trim(u8, steps, " \t\r\n") });
    // Made in Backlog and queued only once parked: a dispatcher pass in
    // between would otherwise start it before the PR merged.
    const key = try board.createTicket(ctx, db, a, .{ .project = parent.project, .parent = parent.key, .title = title, .body = body, .stage = .backlog });
    _ = try park(ctx, db, a, key, .{ .pr = the_pr.url });
    // Queued and not killed: once the park ends, it starts there or waits its turn.
    try board.requeue(ctx, db, try board.getTicket(db, a, key));
    return key;
}

fn holdInBacklog(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, note: []const u8) !void {
    _ = try board.addComment(ctx, db, a, t.key, "cl", note, false);
    try board.logEvent(ctx, db, t.id, "held: in Backlog", "");
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

test "park --pr: cl writes the check; a PR closed without merging ends the park with a flag" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    // tmux, should anything reach for it, is a socket of the test's own (no server).
    const ctx: Ctx = .{ .io = testing.io, .gpa = gpa, .perm = a, .env = &env, .home = "/tmp", .tmux_socket = "/tmp/cl-test-park-pr-none" };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = dir });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };

    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Waits on a PR", .stage = .review });
    try testing.expectError(error.BadInput, park(ctx, db, a, k, .{ .pr = "#31", .until = "true" }));
    try testing.expectError(error.BadPr, park(ctx, db, a, k, .{ .pr = "https://github.com/o/r/issues/31" }));
    _ = try park(ctx, db, a, k, .{ .pr = "https://github.com/o/r/pull/31" });
    const t = try board.getTicket(db, a, k);
    const p = t.park.?;
    try testing.expectEqualStrings("PR #31: waiting to merge", p.reason);
    try testing.expectEqualStrings("https://github.com/o/r/pull/31", p.pr);
    try testing.expect(std.mem.startsWith(u8, p.until, "s=$(gh pr view 31 -R o/r --json state -q .state)"));
    try testing.expectEqual(@as(i64, default_max_pr), p.deadline - p.at);
    try testing.expectEqual(@as(i64, default_every), p.every);

    // Still open: it goes on waiting.
    try board.setPark(ctx, db, t.id, .{ .reason = p.reason, .until = "echo 'PR #31: OPEN'; exit 1", .every = 3600, .at = p.at, .deadline = p.deadline, .pr = p.pr });
    runCheck(ctx, cfg, db, k, p.at);
    try testing.expectEqualStrings("exit 1: PR #31: OPEN", (try board.getTicket(db, a, k)).park.?.result);
    // Closed without merging: the park ends, flagged; nothing resumes it.
    try board.setPark(ctx, db, t.id, .{ .reason = p.reason, .until = "echo 'PR #31: CLOSED'; exit 3", .every = 3600, .at = p.at, .deadline = p.deadline, .pr = p.pr });
    runCheck(ctx, cfg, db, k, p.at);
    const after = try board.getTicket(db, a, k);
    try testing.expect(after.park == null);
    try testing.expect(after.killed);
    try testing.expectEqual(@as(usize, 1), after.flags.len);
    try testing.expectEqualStrings(board.flag_pr_closed, after.flags[0].kind);
    try testing.expect(std.mem.indexOf(u8, after.flags[0].detail, "https://github.com/o/r/pull/31") != null);
    try testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);
    // Parked again, the flag goes; exit 3 from a check of your own is just a failed check.
    _ = try park(ctx, db, a, k, .{ .reason = "the deploy", .until = "exit 3" });
    const own = try board.getTicket(db, a, k);
    try testing.expectEqual(@as(usize, 0), own.flags.len);
    runCheck(ctx, cfg, db, k, own.park.?.at);
    try testing.expectEqualStrings("exit 3", (try board.getTicket(db, a, k)).park.?.result);
}

test "a follow-up is a queued sub-ticket parked on the PR, told the parent, the PR and the steps" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Redact metadata", .stage = .done });
    const parent = try board.getTicket(db, a, kp);
    const k = try followUp(ctx, db, a, parent, "https://github.com/epoch/qa/pull/30", "Deploy, back up, dry run, then run metadata:redact on prod.\n");
    const t = try board.getTicket(db, a, k);
    try testing.expectEqualStrings(kp, t.parent);
    try testing.expectEqual(board.Stage.queued, t.stage);
    // Queued but parked: the dispatcher leaves it alone until the PR merges.
    try testing.expect(!t.killed);
    try testing.expectEqual(@as(usize, 0), (try dispatch.waitingToStart(db, a)).len);
    try testing.expectEqualStrings("After PR #30 merges: Redact metadata", t.title);
    for ([_][]const u8{ kp, "https://github.com/epoch/qa/pull/30", "then run metadata:redact on prod." }) |s| try testing.expect(std.mem.indexOf(u8, t.body, s) != null);
    try testing.expectEqualStrings("https://github.com/epoch/qa/pull/30", t.park.?.pr);
    // Out of Needs You, and not started by the dispatcher, until the PR merges.
    try testing.expectEqual(@as(usize, 0), (try board.listTickets(db, a, .{ .needs = true })).len);
    // Never run: woken, it starts fresh rather than "continuing".
    const note = try metNote(a, t, t.park.?);
    try testing.expectEqualStrings("The PR it waited on has merged: https://github.com/epoch/qa/pull/30.", note);
    try testing.expectEqual(@as(i64, 1), (try board.getTicket(db, a, kp)).children);
}

test "a parked ticket woken while its queue is busy waits in Queued for the dispatcher" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    // A socket of the test's own with no server behind it: never the real tmux.
    const ctx: Ctx = .{ .io = testing.io, .gpa = gpa, .perm = a, .env = &env, .home = "/tmp", .tmux_socket = "/tmp/cl-test-park-busy-none" };
    // Skip without tmux on PATH (the macOS CI runner has none): starting a
    // ticket lists the sessions first, and tmux that can't run at all fails
    // that, before the busy parent is seen.
    _ = std.process.run(a, testing.io, .{ .argv = &.{ "tmux", "-V" } }) catch return error.SkipZigTest;
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    // Its parent is still being planned, so starting it says TargetBusy, as
    // a busy queue session does.
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Parent", .stage = .planning });
    const k = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "Waits on a PR", .stage = .queued });
    // Parked in Queued with no session: marked killed, as a follow-up was.
    _ = try park(ctx, db, a, k, .{ .pr = "https://github.com/o/r/pull/31" });
    const t = try board.getTicket(db, a, k);
    try testing.expect(t.killed);
    wake(ctx, cfg, db, a, t, t.park.?);
    const after = try board.getTicket(db, a, k);
    try testing.expect(after.park == null);
    try testing.expectEqual(board.Stage.queued, after.stage);
    try testing.expect(!after.killed);
    try board.setProjectPaused(db, "qa", false);
    // Once the planning is done, the dispatcher starts it, note and all.
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{kp});
    const w = try dispatch.waitingToStart(db, a);
    try testing.expectEqual(@as(usize, 1), w.len);
    try testing.expectEqualStrings(k, w[0].key);
    try testing.expectEqual(@as(usize, 1), (try board.unsentNotes(db, a, after.id)).len);
}

test "Done ends a park without resuming, also when an umbrella closes; Backlog keeps it; removing a ticket drops it" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };

    // Parked in Review on a PR, then closed by hand: no park, no checks, and
    // no note waiting to resume its session with.
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "On a PR", .stage = .review });
    _ = try park(ctx, db, a, k, .{ .pr = "https://github.com/o/r/pull/31" });
    const at = (try board.getTicket(db, a, k)).park.?.at;
    // Moving within the workflow keeps it: it still waits on the PR.
    try board.move(ctx, db, a, k, .testing);
    try board.move(ctx, db, a, k, .queued);
    try testing.expect((try board.getTicket(db, a, k)).park != null);
    try board.move(ctx, db, a, k, .done);
    const t = try board.getTicket(db, a, k);
    try testing.expect(t.park == null);
    try testing.expectEqual(@as(usize, 0), (try board.dueParks(db, a, at + 86400)).len);
    try testing.expectEqual(@as(usize, 0), (try board.unsentNotes(db, a, t.id)).len);
    try testing.expect((try db.int("SELECT 1 FROM events WHERE ticket = ?1 AND kind = 'unparked' AND detail = 'moved to Done'", .{t.id})) != null);

    // An umbrella closed by cl once its last sub-ticket is Done: the same.
    const ku = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Umbrella", .stage = .running, .umbrella = true });
    const kc = try board.createTicket(ctx, db, a, .{ .parent = ku, .title = "Its part", .stage = .review });
    _ = try park(ctx, db, a, ku, .{ .reason = "the deploy", .until = "true" });
    try board.move(ctx, db, a, kc, .done);
    const u = try board.getTicket(db, a, ku);
    try testing.expectEqual(board.Stage.done, u.stage);
    try testing.expect(u.park == null);

    // A parked follow-up shelved (with its umbrella) and queued again still
    // waits on its PR: the dispatcher doesn't start it.
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Parent", .stage = .queued, .umbrella = true });
    const kf = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "Follow-up", .stage = .backlog });
    _ = try park(ctx, db, a, kf, .{ .pr = "https://github.com/o/r/pull/32" });
    try board.requeue(ctx, db, try board.getTicket(db, a, kf));
    try board.move(ctx, db, a, kp, .backlog);
    try testing.expectEqual(board.Stage.backlog, (try board.getTicket(db, a, kf)).stage);
    try board.move(ctx, db, a, kp, .queued);
    const f = try board.getTicket(db, a, kf);
    try testing.expectEqual(board.Stage.queued, f.stage);
    try testing.expect(f.park != null);
    for (try dispatch.waitingToStart(db, a)) |w| try testing.expect(!std.mem.eql(u8, w.key, kf));

    // Its check passing while it's in Backlog ends the park and says so,
    // but doesn't start it: the note waits until it's queued again.
    try board.move(ctx, db, a, kf, .backlog);
    const fb = try board.getTicket(db, a, kf);
    wake(ctx, cfg, db, a, fb, fb.park.?);
    const fw = try board.getTicket(db, a, kf);
    try testing.expect(fw.park == null);
    try testing.expectEqual(board.Stage.backlog, fw.stage);
    try testing.expectEqualStrings("", fw.tmux);
    try testing.expectEqual(@as(usize, 1), (try board.unsentNotes(db, a, fw.id)).len);
    var unparked = false;
    for (fw.flags) |fl| unparked = unparked or std.mem.eql(u8, fl.kind, board.flag_unparked);
    try testing.expect(unparked);

    // Removed: its park goes with it, and a ticket that gets its id back
    // doesn't find it parked.
    const kr = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Removed", .stage = .review });
    const id = (try board.getTicket(db, a, kr)).id;
    _ = try park(ctx, db, a, kr, .{ .reason = "the deploy", .until = "true" });
    _ = try board.removeTicket(ctx, db, a, kr);
    try testing.expectEqual(@as(?i64, null), try db.int("SELECT 1 FROM parks WHERE ticket = ?1", .{id}));
    const kn = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "New", .stage = .review });
    try testing.expectEqual(id, (try board.getTicket(db, a, kn)).id);
    try testing.expect((try board.getTicket(db, a, kn)).park == null);
}

test "a parked todo isn't killed; waking or unparking it only ends the wait, flagged when a check passed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = a, .env = undefined, .home = "/tmp", .tmux_blocked = true };
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    // Doing, waiting on Josh; his reply (the check) comes.
    const k = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Reply to Josh", .todo = true, .stage = .running });
    _ = try park(ctx, db, a, k, .{ .reason = "waiting on Josh", .until = "true" });
    var t = try board.getTicket(db, a, k);
    try testing.expect(!t.killed);
    wake(ctx, cfg, db, a, t, t.park.?);
    t = try board.getTicket(db, a, k);
    try testing.expect(t.park == null);
    try testing.expectEqual(board.Stage.running, t.stage);
    try testing.expectEqual(@as(usize, 1), t.flags.len);
    try testing.expectEqualStrings(board.flag_unparked, t.flags[0].kind);
    try testing.expectEqual(@as(usize, 0), (try board.unsentNotes(db, a, t.id)).len);
    // In a paused project the same: never queued.
    try board.setProjectPaused(db, "me", true);
    _ = try park(ctx, db, a, k, .{ .reason = "again", .until = "true" });
    t = try board.getTicket(db, a, k);
    wake(ctx, cfg, db, a, t, t.park.?);
    try testing.expectEqual(board.Stage.running, (try board.getTicket(db, a, k)).stage);
    // Unparked by hand ("Resume now"): it ends, with nothing started or said.
    _ = try park(ctx, db, a, k, .{ .reason = "waiting on Sam" });
    const r = try unpark(ctx, cfg, db, a, k, true);
    try testing.expect(r.resumed == null);
    t = try board.getTicket(db, a, k);
    try testing.expect(t.park == null);
    try testing.expect(!t.killed);
    try testing.expectEqualStrings("", t.tmux);
    try testing.expectEqual(@as(usize, 0), (try board.unsentNotes(db, a, t.id)).len);
}

test "parking a todo leaves its talk session open, from the board or from inside it" {
    const gpa = testing.allocator;
    const io = testing.io;
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
    const tmux = @import("tmux.zig");
    gpa.free(try tmux.run(ctx, &.{ "new-session", "-d", "-s", "cl_me-1", "sleep", "600" }));
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    const k = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Reply to Josh", .todo = true });
    try db.exec("UPDATE tickets SET tmux = 'cl_me-1' WHERE key = ?1", .{k});
    const r = try park(ctx, db, a, k, .{ .reason = "waiting on Josh" });
    try testing.expect(r.session == null);
    // What the CLI and the board do after parking: nothing, for a todo.
    try stopSession(ctx, cfg, db, a, k);
    const t = try board.getTicket(db, a, k);
    try testing.expect(t.park != null);
    try testing.expectEqualStrings("cl_me-1", t.tmux);
    try testing.expect(!t.killed);
    try testing.expect(actions.liveSession(ctx, t) != null);
}
