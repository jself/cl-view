//! Pushing trunk after a merge, and watching its CI (`cl project set <name>
//! --push-after-merge <remote>`), for projects where trunk goes straight to
//! its remote instead of through a PR.
//!
//! The push is a step of the after-merge run (after_merge.zig), after the
//! project's command if it has one, whatever that command's result: trunk
//! is merged either way, and CI says whether the code is broken. It pushes
//! the trunk commit with git, which refuses anything but a fast-forward: a
//! remote that has commits trunk doesn't is left alone and the tickets get
//! a push-failed flag. jj repos then import the remote's new position and
//! track `<trunk>@<remote>`, so a later `jj git push` by hand works too.
//! `cl project push` (the board's Push again) pushes again on its own,
//! without the command.
//!
//! Once pushed, a watcher of its own (`cl project ci-watch`, detached like
//! the runner) follows the commit's GitHub Actions runs with `gh run list
//! --commit`, polling with backoff for at most `Options.limit_s`. A failed
//! run flags the merged tickets ci-failed with the run's link and failed
//! jobs, and the commit on the flag's last line. Watchers of different
//! pushes run side by side and may finish in any order, so results are
//! settled by ancestry: a pass clears the ci-failed flags of commits it
//! contains (trunk is green again past them) and becomes the project's last
//! green commit (<board dir>/ci-green-<project>); a failure of a commit the
//! last green one already contains is old news and flags nothing. The
//! watcher runs apart from the runner so the next merge's after-merge
//! command doesn't wait on CI.
//!
//! Pushes and CI results are logged in push-<project>.log (`logPath`),
//! apart from the after-merge log, and a lock file keeps a project's pushes
//! (the runner's, a Push again) one at a time.
//!
//! The tickets a result goes on are the run's merged tickets, plus those
//! whose push failed before (a push now settles them too). A run with none
//! (by hand, say) puts it on the ticket merged into trunk last, so a failure
//! still shows in Needs You.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");
const after_merge = @import("after_merge.zig");

/// The after-merge run's push step: push trunk's commit to the project's
/// remote, flag the tickets (see `targets`) when that fails, and start the
/// CI watcher when it doesn't. `keys` are the run's merged tickets ("-" is
/// a run by hand).
pub fn pushAndWatch(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, p: board.Project, keys: []const []const u8) void {
    const remote = p.push_after_merge;
    const log = logPath(ctx, a, cfg, p.name) catch return;
    after_merge.rotate(ctx, a, log);
    // One push of the project at a time (the runner's and a Push again from
    // the board): the second then finds the commit pushed and watched.
    const lock_fd = lockProject(ctx, a, cfg, p.name);
    defer unlock(lock_fd);
    const on = targets(db, a, p.name, keys);
    const res = push(ctx, a, p.dir, remote);
    const pushed = res catch |e| {
        const err = lastError();
        const first = std.mem.sliceTo(err, '\n');
        const why = std.fmt.allocPrint(a, "couldn't push trunk to {s}: {s}{s}{s}", .{ remote, if (first.len > 0) first else @errorName(e), if (std.mem.indexOfScalar(u8, err, '\n') != null) "\n" else "", if (std.mem.indexOfScalar(u8, err, '\n')) |i| err[i + 1 ..] else "" }) catch "couldn't push trunk";
        after_merge.appendLog(ctx, a, log, std.fmt.allocPrint(a, "\n=== push {s}: {s}\n", .{ p.name, why }) catch "");
        for (on) |k| {
            const t = board.getTicket(db, a, k) catch continue;
            board.logEvent(ctx, db, t.id, "push failed", std.mem.sliceTo(why, '\n')) catch {};
            board.setFlagId(ctx, db, t.id, board.flag_push_failed, "auto", why) catch {};
        }
        return;
    };
    const short = pushed.commit[0..@min(pushed.commit.len, 12)];
    const what = std.fmt.allocPrint(a, "{s} {s} to {s}/{s}", .{ if (pushed.already) "already pushed:" else "pushed", short, remote, pushed.branch }) catch "pushed";
    after_merge.appendLog(ctx, a, log, std.fmt.allocPrint(a, "\n=== push {s}: {s}\n", .{ p.name, what }) catch "");
    // Pushed now: an earlier push that failed no longer matters.
    for (on) |k| {
        const t = board.getTicket(db, a, k) catch continue;
        board.clearFlagId(ctx, db, t.id, board.flag_push_failed) catch {};
        board.logEvent(ctx, db, t.id, "pushed", what) catch {};
    }
    // Pushed before and watched already (a run by hand on the same trunk):
    // watching again would only bring back a result already dealt with.
    const watched = watchedPath(ctx, a, cfg, p.name) catch return;
    if (pushed.already and alreadyWatched(ctx, a, watched, pushed.commit)) {
        after_merge.appendLog(ctx, a, log, std.fmt.allocPrint(a, "=== CI at {s} was watched already\n", .{short}) catch "");
        return;
    }
    // The watcher marks the commit watched and says so in the log itself,
    // once it's running: one that never starts leaves the commit to be
    // watched next time.
    spawnWatcher(ctx, a, p.name, pushed.commit, on) catch |e| {
        after_merge.appendLog(ctx, a, log, std.fmt.allocPrint(a, "=== couldn't start watching CI: {s}\n", .{@errorName(e)}) catch "");
    };
}

/// Take the project's push lock (see `pushAndWatch`); -1 when it can't be
/// opened (then nothing is locked). Release with `unlock`.
fn lockProject(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, project: []const u8) std.c.fd_t {
    const lock = lockPath(ctx, a, cfg, project) catch return -1;
    const fd = std.c.open(lock, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.flock(fd, std.c.LOCK.EX);
    return fd;
}

fn unlock(fd: std.c.fd_t) void {
    if (fd >= 0) _ = std.c.close(fd);
}

/// The log of a project's pushes and CI results:
/// <board dir>/push-<project>.log. Kept apart from the after-merge log,
/// whose last run's tail a failed command's flag shows.
pub fn logPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, project: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/push-{s}.log", .{ try board.dirPath(ctx, a, cfg), project });
}

fn lockPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, project: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/push-{s}.lock", .{ try board.dirPath(ctx, a, cfg), project }, 0);
}

/// The file listing the commits whose CI was watched, newest last.
fn watchedPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, project: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/ci-watched-{s}", .{ try board.dirPath(ctx, a, cfg), project });
}

fn alreadyWatched(ctx: Ctx, a: std.mem.Allocator, path: []const u8, commit: []const u8) bool {
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 16)) catch return false;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, commit)) return true;
    return false;
}

/// Add `commit` to the list, keeping the newest 100.
fn markWatched(ctx: Ctx, a: std.mem.Allocator, path: []const u8, commit: []const u8) void {
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 16)) catch "";
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| lines.append(a, l) catch return;
    lines.append(a, commit) catch return;
    const keep = lines.items[lines.items.len -| 100..];
    var out: std.ArrayList(u8) = .empty;
    for (keep) |l| out.print(a, "{s}\n", .{l}) catch return;
    writeAtomic(ctx, a, path, out.items);
}

/// Write `path` whole, through a temporary file and a rename, so a reader
/// never sees it half written.
fn writeAtomic(ctx: Ctx, a: std.mem.Allocator, path: []const u8, data: []const u8) void {
    const tmp = std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ path, std.c.getpid() }) catch return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = data }) catch return;
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, ctx.io) catch {};
}

/// The board's Push again: refused (error.NoPush) for a project that
/// doesn't push; otherwise `cl project push` starts, detached.
pub fn pushFromBoard(ctx: Ctx, db: board.Db, a: std.mem.Allocator, project: []const u8) !void {
    if ((try board.getProject(db, a, project)).push_after_merge.len == 0) return error.NoPush;
    try spawnPush(ctx, project);
}

/// `cl project push <name>` (the board's Push again): push trunk as it is
/// and watch its CI, without the after-merge command.
pub fn pushByHand(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, project: []const u8) !void {
    const p = try board.getProject(db, a, project);
    if (p.push_after_merge.len == 0) return error.NoPush;
    pushAndWatch(ctx, cfg, db, a, p, &.{"-"});
}

/// Start `cl project push <project>` detached (`Ctx.detach`), for the
/// board: the push may take a while.
pub fn spawnPush(ctx: Ctx, project: []const u8) !void {
    return spawn(ctx, &.{ "project", "push", project });
}

/// Who a push's result goes on: `keys` but "-", and the project's tickets
/// whose push failed before; when that is nobody, the ticket merged into
/// trunk last.
fn targets(db: board.Db, a: std.mem.Allocator, project: []const u8, keys: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (keys) |k| if (!std.mem.eql(u8, k, "-")) addKey(a, &out, k);
    const flagged = board.listTickets(db, a, .{ .project = project, .flag = board.flag_push_failed }) catch &.{};
    for (flagged) |t| addKey(a, &out, t.key);
    if (out.items.len == 0) if (board.lastMergedTicket(db, a, project) catch null) |k| addKey(a, &out, k);
    return out.items;
}

fn addKey(a: std.mem.Allocator, out: *std.ArrayList([]const u8), k: []const u8) void {
    for (out.items) |x| if (std.mem.eql(u8, x, k)) return;
    out.append(a, k) catch {};
}

const Pushed = struct {
    commit: []const u8,
    branch: []const u8,
    /// The remote had it already; nothing was pushed.
    already: bool,
};

/// Push trunk (jj's trunk bookmark, git's main branch) to `remote`, as a
/// fast-forward only.
fn push(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, remote: []const u8) !Pushed {
    setError("");
    const jj = worktree.trunkBookmark(ctx, a, dir);
    const branch = jj orelse worktree.mainBranch(ctx, a, dir);
    // These two keep their errors in after_merge.zig.
    const commit = after_merge.trunkCommit(ctx, a, dir) catch |e| {
        setError(after_merge.lastError());
        return e;
    };
    const gd = after_merge.gitDir(ctx, a, dir) catch |e| {
        setError(after_merge.lastError());
        return e;
    };
    const ref = try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch});
    const ls = try runNet(ctx, a, &.{ "git", "--git-dir", gd, "ls-remote", remote, ref });
    var it = std.mem.tokenizeAny(u8, ls, " \t\n");
    const theirs = it.next() orelse "";
    const already = std.mem.eql(u8, theirs, commit);
    if (!already) {
        // git would refuse it too, but this says why in words.
        if (theirs.len > 0 and !isAncestor(ctx, a, gd, theirs, commit)) {
            setError(try std.fmt.allocPrint(a, "{s}'s {s} is at {s}, which trunk doesn't have: something was pushed there that isn't merged here. Fetch it and sort it out by hand.", .{ remote, branch, theirs[0..@min(theirs.len, 12)] }));
            return error.RemoteAhead;
        }
        _ = try runNet(ctx, a, &.{ "git", "--git-dir", gd, "push", "--quiet", remote, try std.fmt.allocPrint(a, "{s}:{s}", .{ commit, ref }) });
    }
    // Where the remote is now, for git's remote-tracking branch and jj's
    // `<trunk>@<remote>`; tracked, so jj pushes it by itself next time.
    // Best effort: the push itself is what counts.
    _ = runNet(ctx, a, &.{ "git", "--git-dir", gd, "fetch", "--quiet", remote, branch }) catch {};
    if (jj != null) {
        _ = run(ctx, a, &.{ "jj", "-R", dir, "--ignore-working-copy", "git", "import" }) catch {};
        _ = run(ctx, a, &.{ "jj", "-R", dir, "--ignore-working-copy", "bookmark", "track", try std.fmt.allocPrint(a, "{s}@{s}", .{ branch, remote }) }) catch {};
    }
    return .{ .commit = commit, .branch = branch, .already = already };
}

/// `older` is `newer` or one of its ancestors (false when git doesn't know
/// either).
fn isAncestor(ctx: Ctx, a: std.mem.Allocator, gd: []const u8, older: []const u8, newer: []const u8) bool {
    _ = run(ctx, a, &.{ "git", "--git-dir", gd, "merge-base", "--is-ancestor", older, newer }) catch return false;
    return true;
}

/// Run `cl project ci-watch <project> <commit> <keys>...` detached
/// (`Ctx.detach`), like the after-merge runner.
fn spawnWatcher(ctx: Ctx, a: std.mem.Allocator, project: []const u8, commit: []const u8, keys: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "project", "ci-watch", project, commit });
    try args.appendSlice(a, keys);
    return spawn(ctx, args.items);
}

/// Run this cl with `args`, detached. Not from tests: that would be the
/// test binary.
fn spawn(ctx: Ctx, args: []const []const u8) !void {
    if (builtin.is_test) return;
    try ctx.detach(args);
}

/// How the watcher polls: the first wait, doubling up to `max_ms`; no run
/// for the commit after `appear_s` means it has no CI; still running after
/// `limit_s`, it stops watching.
pub const Options = struct {
    /// The gh to run (tests use a fake one).
    gh: []const u8 = "gh",
    first_ms: i64 = 20 * std.time.ms_per_s,
    max_ms: i64 = 5 * std.time.ms_per_min,
    appear_s: i64 = 10 * std.time.s_per_min,
    limit_s: i64 = 3 * std.time.s_per_hour,
    /// gh failing this many times in a row ends the watch.
    max_errors: u32 = 5,
    /// One watcher per commit: a second for a commit already watched exits.
    /// (Tests turn it off to replay results.)
    once: bool = true,
};

/// What a watch knows about where it reports.
const Watch = struct {
    ctx: Ctx,
    db: board.Db,
    project: []const u8,
    /// The repo's git directory, for ancestry.
    gd: []const u8,
    log: []const u8,
    /// The file holding the project's last green commit.
    green: []const u8,
    commit: []const u8,
    short: []const u8,
    keys: []const []const u8,
};

/// The watcher (`cl project ci-watch`): follow `commit`'s CI runs to their
/// end and put the result on `keys`.
pub fn watch(ctx: Ctx, cfg: config.Config, db: board.Db, project: []const u8, commit: []const u8, keys: []const []const u8, opts: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const pa = arena_state.allocator();
    const short = commit[0..@min(commit.len, 12)];
    var w: Watch = .{
        .ctx = ctx,
        .db = db,
        .project = project,
        .gd = "",
        .log = try logPath(ctx, pa, cfg, project),
        .green = try std.fmt.allocPrint(pa, "{s}/ci-green-{s}", .{ try board.dirPath(ctx, pa, cfg), project }),
        .commit = commit,
        .short = short,
        .keys = keys,
    };
    // What it needs, each failure said in the log: this runs detached, and
    // its errors would go nowhere. The commit isn't marked watched yet, so
    // the next push watches it.
    const p = board.getProject(db, pa, project) catch |e|
        return note(w, pa, try std.fmt.allocPrint(pa, "couldn't watch CI at {s}: project {s}: {s}", .{ short, project, @errorName(e) }));
    w.gd = after_merge.gitDir(ctx, pa, p.dir) catch |e|
        return note(w, pa, try std.fmt.allocPrint(pa, "couldn't watch CI at {s}: no git repo at {s}: {s}", .{ short, p.dir, @errorName(e) }));
    const repo = std.mem.trim(u8, run(ctx, pa, &.{ "git", "--git-dir", w.gd, "remote", "get-url", p.push_after_merge }) catch {
        return note(w, pa, try std.fmt.allocPrint(pa, "couldn't watch CI at {s}: no URL for remote {s}", .{ short, p.push_after_merge }));
    }, " \n");
    // Running now: claim the commit (under the push lock, so two watchers
    // started for it at once settle on one), then say so.
    if (opts.once) {
        const fd = lockProject(ctx, pa, cfg, project);
        defer unlock(fd);
        const watched = try watchedPath(ctx, pa, cfg, project);
        if (alreadyWatched(ctx, pa, watched, commit)) return;
        markWatched(ctx, pa, watched, commit);
    }
    after_merge.appendLog(ctx, pa, w.log, try std.fmt.allocPrint(pa, "=== watching CI at {s}{s}{s}; the result follows when it finishes\n", .{ short, if (keys.len > 0) " for " else "", try std.mem.join(pa, ", ", keys) }));
    // A pass counts once two polls in a row see the same finished runs: a
    // slower workflow may not be listed yet the first time.
    var passes: ?usize = null;
    const start = ctx.nowSeconds();
    var delay = opts.first_ms;
    var errors: u32 = 0;
    while (true) {
        ctx.sleepMs(delay);
        delay = @min(delay * 2, opts.max_ms);
        var iter_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer iter_state.deinit();
        const a = iter_state.allocator();
        const elapsed = ctx.nowSeconds() - start;
        const out = runNet(ctx, a, &.{ opts.gh, "run", "list", "-R", repo, "--commit", commit, "--json", "databaseId,status,conclusion,workflowName,url" }) catch {
            errors += 1;
            if (errors >= opts.max_errors) return note(w, pa, try std.fmt.allocPrint(pa, "stopped watching CI at {s}: gh failed: {s}", .{ w.short, try pa.dupe(u8, std.mem.sliceTo(lastError(), '\n')) }));
            continue;
        };
        // Not the JSON asked for (a notice, a proxy's error page): as if gh
        // had failed, so it ends with a note rather than in silence.
        const v = verdict(a, out) catch {
            errors += 1;
            if (errors >= opts.max_errors) return note(w, pa, try std.fmt.allocPrint(pa, "stopped watching CI at {s}: gh's answer isn't JSON: {s}", .{ w.short, try pa.dupe(u8, std.mem.sliceTo(std.mem.trim(u8, out, " \n"), '\n')) }));
            continue;
        };
        errors = 0;
        const was = passes;
        passes = null;
        switch (v) {
            .none => if (elapsed >= opts.appear_s) return note(w, pa, try std.fmt.allocPrint(pa, "no CI run for {s}", .{w.short})),
            .pending => if (elapsed >= opts.limit_s) return note(w, pa, try std.fmt.allocPrint(pa, "CI at {s} still running after {d} min; stopped watching", .{ w.short, @divFloor(elapsed, 60) })),
            .inconclusive => return note(w, pa, try std.fmt.allocPrint(pa, "CI at {s} was cancelled or skipped", .{w.short})),
            .passed => |n| {
                if (was == n) return passed(w, pa);
                passes = n;
            },
            .failed => |runs| return failed(w, pa, opts.gh, repo, runs),
        }
    }
}

/// Activity on each ticket and a line in the log; no flag.
fn note(w: Watch, a: std.mem.Allocator, what: []const u8) void {
    after_merge.appendLog(w.ctx, a, w.log, std.fmt.allocPrint(a, "=== {s}\n", .{what}) catch return);
    for (w.keys) |k| {
        const t = board.getTicket(w.db, a, k) catch continue;
        board.logEvent(w.ctx, w.db, t.id, "CI", what) catch {};
    }
}

/// The project's last green commit ("" for none).
fn lastGreen(w: Watch, a: std.mem.Allocator) []const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(w.ctx.io, w.green, a, .limited(256)) catch return "";
    return std.mem.trim(u8, text, " \n");
}

/// The commit a ci-failed flag is for: its detail's last line, "commit <sha>".
fn flagCommit(detail: []const u8) []const u8 {
    const last = detail[if (std.mem.lastIndexOfScalar(u8, detail, '\n')) |i| i + 1 else 0..];
    return if (std.mem.startsWith(u8, last, "commit ")) last["commit ".len..] else "";
}

test flagCommit {
    try std.testing.expectEqualStrings("abc", flagCommit("CI failed at abc: ci\nhttps://x\ncommit abc"));
    try std.testing.expectEqualStrings("", flagCommit("CI failed"));
}

fn passed(w: Watch, a: std.mem.Allocator) void {
    after_merge.appendLog(w.ctx, a, w.log, std.fmt.allocPrint(a, "=== CI passed at {s}\n", .{w.short}) catch return);
    // The green commit first, then the flags: a failure flagged meanwhile
    // either shows in the list below or sees this commit when it checks
    // again (see `failed`).
    const green = lastGreen(w, a);
    if (green.len == 0 or isAncestor(w.ctx, a, w.gd, green, w.commit)) writeAtomic(w.ctx, a, w.green, w.commit);
    for (w.keys) |k| {
        const t = board.getTicket(w.db, a, k) catch continue;
        board.logEvent(w.ctx, w.db, t.id, "CI passed", w.short) catch {};
    }
    // Trunk is green past these: the failures it contains are fixed. A newer
    // commit's failure (one this doesn't contain) still stands.
    const flagged = board.listTickets(w.db, a, .{ .project = w.project, .flag = board.flag_ci_failed }) catch &.{};
    for (flagged) |t| for (t.flags) |f| {
        if (!std.mem.eql(u8, f.kind, board.flag_ci_failed)) continue;
        const c = flagCommit(f.detail);
        if (c.len > 0 and !isAncestor(w.ctx, a, w.gd, c, w.commit)) continue;
        board.clearFlagId(w.ctx, w.db, t.id, board.flag_ci_failed) catch {};
        board.logEvent(w.ctx, w.db, t.id, "CI passed", std.fmt.allocPrint(a, "trunk is green again at {s}", .{w.short}) catch w.short) catch {};
    };
}

fn failed(w: Watch, a: std.mem.Allocator, gh: []const u8, repo: []const u8, runs: []const Run) void {
    var names: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(u8) = .empty;
    for (runs, 0..) |r, i| {
        // The jobs that failed, when gh says (best effort).
        const id = std.fmt.allocPrint(a, "{d}", .{r.id}) catch continue;
        const jobs = runNet(w.ctx, a, &.{ gh, "run", "view", id, "-R", repo, "--json", "jobs", "-q", "[.jobs[] | select(.conclusion == \"failure\" or .conclusion == \"timed_out\") | .name] | join(\", \")" }) catch "";
        const j = std.mem.trim(u8, jobs, " \n");
        names.print(a, "{s}{s}{s}{s}{s}", .{ if (i > 0) "; " else "", r.workflow, if (j.len > 0) " (" else "", j, if (j.len > 0) ")" else "" }) catch {};
        links.print(a, "\n{s}", .{r.url}) catch {};
    }
    const head = std.fmt.allocPrint(a, "CI failed at {s}: {s}", .{ w.short, names.items }) catch return;
    // A newer commit passed already (its watcher finished first): old news.
    if (greenPast(w, a)) |green|
        return note(w, a, std.fmt.allocPrint(a, "{s}; not flagged: {s}, which contains it, passed already", .{ head, green[0..@min(green.len, 12)] }) catch return);
    const detail = std.fmt.allocPrint(a, "{s}{s}\ncommit {s}", .{ head, links.items, w.commit }) catch return;
    after_merge.appendLog(w.ctx, a, w.log, std.fmt.allocPrint(a, "=== {s}{s}\n", .{ head, links.items }) catch return);
    for (w.keys) |k| {
        const t = board.getTicket(w.db, a, k) catch continue;
        board.logEvent(w.ctx, w.db, t.id, "CI failed", head) catch {};
        board.setFlagId(w.ctx, w.db, t.id, board.flag_ci_failed, "auto", detail) catch {};
    }
    // A pass of a commit containing this one may have finished between the
    // check above and the flags: it would have missed them, so look again.
    if (greenPast(w, a) != null) for (w.keys) |k| {
        const t = board.getTicket(w.db, a, k) catch continue;
        board.clearFlagId(w.ctx, w.db, t.id, board.flag_ci_failed) catch {};
    };
}

/// The project's last green commit when it contains this watch's commit
/// (and isn't it): a newer commit passed already.
fn greenPast(w: Watch, a: std.mem.Allocator) ?[]const u8 {
    const green = lastGreen(w, a);
    if (green.len == 0 or std.mem.eql(u8, green, w.commit) or !isAncestor(w.ctx, a, w.gd, w.commit, green)) return null;
    return green;
}

const Run = struct { id: i64, workflow: []const u8, url: []const u8 };

const Verdict = union(enum) {
    /// No run for the commit (yet).
    none,
    /// Some run hasn't finished.
    pending,
    /// All finished, none failed, and at least one passed: how many runs.
    passed: usize,
    /// All finished, none failed or passed (cancelled, skipped).
    inconclusive,
    /// All finished; these failed.
    failed: []const Run,
};

/// What `gh run list --json databaseId,status,conclusion,workflowName,url`
/// says about the commit.
fn verdict(a: std.mem.Allocator, json: []const u8) !Verdict {
    const Item = struct {
        databaseId: i64 = 0,
        status: []const u8 = "",
        conclusion: []const u8 = "",
        workflowName: []const u8 = "",
        url: []const u8 = "",
    };
    const items = try std.json.parseFromSliceLeaky([]const Item, a, json, .{ .ignore_unknown_fields = true });
    if (items.len == 0) return .none;
    var bad: std.ArrayList(Run) = .empty;
    var ok = false;
    for (items) |it| {
        if (!std.mem.eql(u8, it.status, "completed")) return .pending;
        const c = it.conclusion;
        if (std.mem.eql(u8, c, "success")) {
            ok = true;
        } else if (std.mem.eql(u8, c, "failure") or std.mem.eql(u8, c, "timed_out") or std.mem.eql(u8, c, "startup_failure") or std.mem.eql(u8, c, "action_required")) {
            try bad.append(a, .{ .id = it.databaseId, .workflow = it.workflowName, .url = it.url });
        }
    }
    if (bad.items.len > 0) return .{ .failed = bad.items };
    return if (ok) .{ .passed = items.len } else .inconclusive;
}

test verdict {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(Verdict.none, try verdict(a, "[]"));
    try std.testing.expectEqual(Verdict.pending, try verdict(a,
        \\[{"databaseId":1,"status":"completed","conclusion":"failure","workflowName":"ci","url":"u1"},
        \\ {"databaseId":2,"status":"in_progress","conclusion":"","workflowName":"lint","url":"u2"}]
    ));
    try std.testing.expectEqual(Verdict{ .passed = 2 }, try verdict(a,
        \\[{"databaseId":1,"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"},
        \\ {"databaseId":2,"status":"completed","conclusion":"skipped","workflowName":"docs","url":"u2"}]
    ));
    try std.testing.expectEqual(Verdict.inconclusive, try verdict(a,
        \\[{"databaseId":1,"status":"completed","conclusion":"cancelled","workflowName":"ci","url":"u1"}]
    ));
    const v = try verdict(a,
        \\[{"databaseId":7,"status":"completed","conclusion":"success","workflowName":"lint","url":"u1"},
        \\ {"databaseId":8,"status":"completed","conclusion":"failure","workflowName":"ci","url":"https://x/runs/8"}]
    );
    try std.testing.expectEqual(@as(usize, 1), v.failed.len);
    try std.testing.expectEqual(@as(i64, 8), v.failed[0].id);
    try std.testing.expectEqualStrings("https://x/runs/8", v.failed[0].url);
}

var last_error: [512]u8 = undefined;
var last_error_len: usize = 0;

fn lastError() []const u8 {
    return std.mem.trim(u8, last_error[0..last_error_len], " \n");
}

fn setError(text: []const u8) void {
    const n = @min(text.len, last_error.len);
    @memcpy(last_error[0..n], text[0..n]);
    last_error_len = n;
}

/// How long a command that talks to the remote (git, gh) may take.
const net_timeout = "120";

/// `run` for a command that talks to the remote: killed after
/// `net_timeout` seconds, so a stalled remote can't hold up the after-merge
/// runner (and every merge after it) for good. That takes timeout(1)
/// (coreutils; `gtimeout` from Homebrew on macOS); without either it runs
/// unbounded, and only ssh's own ConnectTimeout (see `run`) limits it.
fn runNet(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const tool = timeoutTool(ctx, a) orelse return run(ctx, a, argv);
    const full = try std.mem.concat(a, []const u8, &.{ &.{ tool, "-k", "10", net_timeout }, argv });
    return run(ctx, a, full) catch |e| {
        if (std.mem.eql(u8, lastError(), "timed out")) setError(try std.fmt.allocPrint(a, "{s} {s} timed out after {s}s", .{ argv[0], if (std.mem.eql(u8, argv[0], "git") and argv.len > 3) argv[3] else if (argv.len > 1) argv[1] else "", net_timeout }));
        return e;
    };
}

/// The timeout(1) on PATH: `timeout`, or `gtimeout` (macOS with coreutils);
/// null for neither.
fn timeoutTool(ctx: Ctx, a: std.mem.Allocator) ?[]const u8 {
    const path = ctx.env.get("PATH") orelse return null;
    for ([_][]const u8{ "timeout", "gtimeout" }) |name| {
        var it = std.mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |dir| {
            const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch return null;
            std.Io.Dir.cwd().access(ctx.io, full, .{ .execute = true }) catch continue;
            return full;
        }
    }
    return null;
}

/// Run a command with cl's environment, where git and ssh never prompt
/// (nobody is there to answer: no terminal, no askpass helper, ssh in batch
/// mode); its stdout, or error.CommandFailed with its stderr kept for
/// `lastError`.
fn run(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var env = try ctx.env.clone(a);
    try env.put("GIT_TERMINAL_PROMPT", "0");
    if (env.get("GIT_SSH") == null) try env.put("GIT_SSH_COMMAND", try std.fmt.allocPrint(a, "{s} -o BatchMode=yes -o ConnectTimeout=30", .{env.get("GIT_SSH_COMMAND") orelse "ssh"}));
    _ = env.swapRemove("SSH_ASKPASS");
    _ = env.swapRemove("SSH_ASKPASS_REQUIRE");
    _ = env.swapRemove("GIT_ASKPASS");
    const res = std.process.run(a, ctx.io, .{ .argv = argv, .environ_map = &env }) catch |e| {
        setError(argv[0]);
        return e;
    };
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        // timeout(1): 124 when it timed out, 137 when it had to kill.
        const timed_out = (std.mem.endsWith(u8, argv[0], "/timeout") or std.mem.endsWith(u8, argv[0], "/gtimeout")) and switch (res.term) {
            .exited => |code| code == 124 or code == 137,
            else => false,
        };
        setError(if (timed_out) "timed out" else if (res.stderr.len > 0) res.stderr else argv[0]);
        return error.CommandFailed;
    }
    return res.stdout;
}

test "a command that talks to the remote is cut off when it hangs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", std.mem.span(std.c.getenv("PATH") orelse return error.SkipZigTest));
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = &env, .home = "/tmp" };
    // A shorter limit than net_timeout, through the same path. No
    // timeout(1) here (stock macOS): nothing to test.
    const tool = timeoutTool(ctx, a) orelse return error.SkipZigTest;
    _ = run(ctx, a, &.{ tool, "-k", "1", "0.2", "sleep", "5" }) catch {
        try std.testing.expectEqualStrings("timed out", lastError());
        return;
    };
    return error.TestUnexpectedResult;
}

test "without timeout(1) on PATH, a remote command runs unbounded rather than failing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/nonexistent");
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = &env, .home = "/tmp" };
    try std.testing.expectEqual(@as(?[]const u8, null), timeoutTool(ctx, a));
    try std.testing.expectEqualStrings("hi\n", try runNet(ctx, a, &.{ "/bin/echo", "hi" }));
}

// ---- tests ----

pub const TestEnv = struct {
    a: std.mem.Allocator,
    ctx: Ctx,
    cfg: config.Config,
    db: board.Db,
    base: []const u8,
    repo: []const u8,
    remote: []const u8,
};

pub fn testGit(t: TestEnv, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t.a, &.{ "git", "-C", t.repo, "-c", "user.name=t", "-c", "user.email=t@t" });
    try argv.appendSlice(t.a, args);
    return run(t.ctx, t.a, argv.items);
}

/// A git repo on master with a bare remote `origin` that has its first
/// commit, and a board with project qa pushing to it.
pub fn testSetup(a: std.mem.Allocator, env: *std.process.Environ.Map, base: []const u8) !TestEnv {
    try env.put("PATH", std.mem.span(std.c.getenv("PATH") orelse return error.SkipZigTest));
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = env, .home = "/tmp", .tmux_blocked = true };
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    const remote = try std.fmt.allocPrint(a, "{s}/remote.git", .{base});
    _ = run(ctx, a, &.{ "git", "init", "-q", "--bare", remote }) catch return error.SkipZigTest;
    _ = try run(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo });
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    cfg.board.dir = try std.fmt.allocPrint(a, "{s}/state", .{base});
    try std.Io.Dir.cwd().createDirPath(ctx.io, cfg.board.dir);
    const db = try board.Db.open(":memory:");
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = repo, .push_after_merge = "origin" });
    const t: TestEnv = .{ .a = a, .ctx = ctx, .cfg = cfg, .db = db, .base = base, .repo = repo, .remote = remote };
    _ = try testGit(t, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    _ = try testGit(t, &.{ "remote", "add", "origin", remote });
    _ = try testGit(t, &.{ "push", "-q", "origin", "master" });
    return t;
}

pub fn hasFlag(t: TestEnv, key: []const u8, kind: []const u8) !bool {
    for ((try board.getTicket(t.db, t.a, key)).flags) |f| if (std.mem.eql(u8, f.kind, kind)) return true;
    return false;
}

test "trunk is pushed as a fast-forward; a remote with commits trunk lacks is left alone and the ticket flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const t = try testSetup(a, &env, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    defer t.db.close();

    _ = try testGit(t, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
    const head = std.mem.trim(u8, try testGit(t, &.{ "rev-parse", "HEAD" }), "\n");
    const p = try push(t.ctx, a, t.repo, "origin");
    try std.testing.expect(!p.already);
    try std.testing.expectEqualStrings("master", p.branch);
    try std.testing.expectEqualStrings(head, p.commit);
    try std.testing.expectEqualStrings(head, std.mem.trim(u8, try run(t.ctx, a, &.{ "git", "--git-dir", t.remote, "rev-parse", "master" }), "\n"));
    try std.testing.expect((try push(t.ctx, a, t.repo, "origin")).already);

    // Someone pushed elsewhere: trunk doesn't have it, so nothing is pushed.
    const other = try std.fmt.allocPrint(a, "{s}/other", .{t.base});
    _ = try run(t.ctx, a, &.{ "git", "clone", "-q", t.remote, other });
    _ = try run(t.ctx, a, &.{ "git", "-C", other, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "theirs" });
    _ = try run(t.ctx, a, &.{ "git", "-C", other, "push", "-q", "origin", "master" });
    const theirs = std.mem.trim(u8, try run(t.ctx, a, &.{ "git", "-C", other, "rev-parse", "HEAD" }), "\n");
    _ = try testGit(t, &.{ "commit", "-q", "--allow-empty", "-m", "three" });
    const k = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Merged", .stage = .done });
    pushAndWatch(t.ctx, t.cfg, t.db, a, try board.getProject(t.db, a, "qa"), &.{k});
    try std.testing.expect(try hasFlag(t, k, board.flag_push_failed));
    try std.testing.expectEqualStrings(theirs, std.mem.trim(u8, try run(t.ctx, a, &.{ "git", "--git-dir", t.remote, "rev-parse", "master" }), "\n"));
    // Done, and still in Needs You.
    try std.testing.expectEqual(@as(usize, 1), (try board.listTickets(t.db, a, .{ .needs = true })).len);

    // Its flag dismissed, a push by hand (no ticket of its own) fails again:
    // the ticket merged last gets the flag, so it still shows.
    try board.clearFlagId(t.ctx, t.db, (try board.getTicket(t.db, a, k)).id, board.flag_push_failed);
    const k2 = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Merged last", .stage = .done });
    try board.logEvent(t.ctx, t.db, (try board.getTicket(t.db, a, k2)).id, "after-merge queued", "");
    try pushByHand(t.ctx, t.cfg, t.db, a, "qa");
    try std.testing.expect(try hasFlag(t, k2, board.flag_push_failed));
    try std.testing.expect(!try hasFlag(t, k, board.flag_push_failed));
    // Its first line (what Needs You shows) says why, not an error name.
    const f = (try board.getTicket(t.db, a, k2)).flags[0];
    try std.testing.expect(std.mem.startsWith(u8, f.detail, "couldn't push trunk to origin: origin's master is at "));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(f.detail, '\n'), "which trunk doesn't have") != null);
}

/// A gh that answers from files: <base>/runs.json for `run list`, a job
/// name for `run view`. Returns its path.
fn fakeGh(t: TestEnv) ![]const u8 {
    const bin = try std.fmt.allocPrint(t.a, "{s}/bin", .{t.base});
    try std.Io.Dir.cwd().createDirPath(t.ctx.io, bin);
    const gh = try std.fmt.allocPrint(t.a, "{s}/gh", .{bin});
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = gh, .data = try std.fmt.allocPrint(t.a,
        \\#!/bin/sh
        \\case "$2" in list) cat {s}/runs.json ;; view) echo test-macos ;; esac
        \\
    , .{t.base}) });
    _ = try run(t.ctx, t.a, &.{ "chmod", "+x", gh });
    return gh;
}

test "a commit's CI is watched once: by the first watcher that runs, and not again on a later push" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const t = try testSetup(a, &env, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    defer t.db.close();
    const gh = try fakeGh(t);
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/runs.json", .{t.base}), .data =
        \\[{"databaseId":8,"status":"completed","conclusion":"failure","workflowName":"ci","url":"https://x/runs/8"}]
    });
    const once: Options = .{ .gh = gh, .first_ms = 1, .max_ms = 1, .appear_s = 0, .limit_s = 0 };
    const k = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Merged", .stage = .done });
    _ = try testGit(t, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
    const head = try a.dupe(u8, std.mem.trim(u8, try testGit(t, &.{ "rev-parse", "HEAD" }), "\n"));
    const p = try board.getProject(t.db, a, "qa");
    const logFile = try logPath(t.ctx, a, t.cfg, "qa");

    // Pushed, but no watcher ran (it never started): a push by hand on the
    // same trunk still starts one.
    pushAndWatch(t.ctx, t.cfg, t.db, a, p, &.{k});
    pushAndWatch(t.ctx, t.cfg, t.db, a, p, &.{"-"});
    var log = try std.Io.Dir.cwd().readFileAlloc(t.ctx.io, logFile, a, .limited(1 << 20));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, log, "was watched already"));

    // The watcher runs: it says so, and reports.
    try watch(t.ctx, t.cfg, t.db, "qa", head, &.{k}, once);
    log = try std.Io.Dir.cwd().readFileAlloc(t.ctx.io, logFile, a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, log, try std.fmt.allocPrint(a, "=== watching CI at {s} for {s};", .{ head[0..12], k })) != null);
    try std.testing.expect(try hasFlag(t, k, board.flag_ci_failed));

    // The flag dismissed, a second watcher for the commit (two pushes at
    // once) exits without a word, and a later push doesn't start one.
    try board.clearFlagId(t.ctx, t.db, (try board.getTicket(t.db, a, k)).id, board.flag_ci_failed);
    try watch(t.ctx, t.cfg, t.db, "qa", head, &.{k}, once);
    try std.testing.expect(!try hasFlag(t, k, board.flag_ci_failed));
    pushAndWatch(t.ctx, t.cfg, t.db, a, p, &.{"-"});
    log = try std.Io.Dir.cwd().readFileAlloc(t.ctx.io, logFile, a, .limited(1 << 20));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log, "was watched already"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log, "=== watching CI at "));
}

test "a watcher that can't set up says so in the log, and leaves the commit to be watched next time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const t = try testSetup(a, &env, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    defer t.db.close();
    try board.updateProject(t.db, "qa", .{ .name = "", .dir = "", .push_after_merge = "nosuchremote" });
    try watch(t.ctx, t.cfg, t.db, "qa", "abcdefabcdefabcdef", &.{}, .{ .first_ms = 1 });
    const log = try std.Io.Dir.cwd().readFileAlloc(t.ctx.io, try logPath(t.ctx, a, t.cfg, "qa"), a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, log, "couldn't watch CI at abcdefabcdef: no URL for remote nosuchremote") != null);
    try std.testing.expect(!alreadyWatched(t.ctx, a, try watchedPath(t.ctx, a, t.cfg, "qa"), "abcdefabcdefabcdef"));
}

test "the board's Push again is refused for a project that doesn't push" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const t = try testSetup(a, &env, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    defer t.db.close();
    try pushFromBoard(t.ctx, t.db, a, "qa");
    try board.updateProject(t.db, "qa", .{ .name = "", .dir = "", .push_after_merge = "" });
    try std.testing.expectError(error.NoPush, pushFromBoard(t.ctx, t.db, a, "qa"));
}

test "a jj repo whose remote trunk bookmark is untracked pushes, and tracks it after" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const t = try testSetup(a, &env, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    defer t.db.close();
    try env.put("HOME", t.base);
    try env.put("JJ_USER", "t");
    try env.put("JJ_EMAIL", "t@t");
    _ = run(t.ctx, a, &.{ "jj", "git", "init", "--colocate", t.repo }) catch return error.SkipZigTest;
    const jj = &[_][]const u8{ "jj", "-R", t.repo, "--ignore-working-copy" };
    // master@origin isn't tracked (as `jj git init --colocate` leaves it), and
    // trunk moved on.
    _ = run(t.ctx, a, try std.mem.concat(a, []const u8, &.{ jj, &.{ "bookmark", "untrack", "master@origin" } })) catch {};
    _ = try run(t.ctx, a, try std.mem.concat(a, []const u8, &.{ jj, &.{ "new", "master", "-m", "two" } }));
    _ = try run(t.ctx, a, try std.mem.concat(a, []const u8, &.{ jj, &.{ "bookmark", "set", "master", "-r", "@" } }));
    const p = try push(t.ctx, a, t.repo, "origin");
    try std.testing.expect(!p.already);
    try std.testing.expectEqualStrings("master", p.branch);
    try std.testing.expectEqualStrings(p.commit, std.mem.trim(u8, try run(t.ctx, a, &.{ "git", "--git-dir", t.remote, "rev-parse", "master" }), "\n"));
    const tracked = try run(t.ctx, a, try std.mem.concat(a, []const u8, &.{ jj, &.{ "bookmark", "list", "--tracked", "-T", "name ++ \"@\" ++ remote ++ \" \" ++ normal_target.commit_id() ++ \"\\n\"" } }));
    try std.testing.expect(std.mem.indexOf(u8, tracked, try std.fmt.allocPrint(a, "master@origin {s}", .{p.commit})) != null);
}

test "the CI watcher flags a failed run, and only a pass on a commit containing it clears it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const t = try testSetup(a, &env, base);
    defer t.db.close();

    const gh = try fakeGh(t);
    const runs = try std.fmt.allocPrint(a, "{s}/runs.json", .{base});
    const fast: Options = .{ .gh = gh, .first_ms = 1, .max_ms = 1, .appear_s = 0, .limit_s = 0, .once = false };
    const fail_json =
        \\[{"databaseId":8,"status":"completed","conclusion":"failure","workflowName":"ci","url":"https://github.com/o/r/actions/runs/8"}]
    ;
    const pass_json =
        \\[{"databaseId":9,"status":"completed","conclusion":"success","workflowName":"ci","url":"u"}]
    ;
    // Trunk's commits A, then B on A, then C on B.
    var commits: [3][]const u8 = undefined;
    for (&commits, [_][]const u8{ "A", "B", "C" }) |*c, m| {
        _ = try testGit(t, &.{ "commit", "-q", "--allow-empty", "-m", m });
        c.* = try a.dupe(u8, std.mem.trim(u8, try testGit(t, &.{ "rev-parse", "HEAD" }), "\n"));
    }
    const A, const B, const C = commits;

    // A fails: its ticket is flagged, with the run's link and the commit.
    const ka = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Broke it", .stage = .done });
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = runs, .data = fail_json });
    try watch(t.ctx, t.cfg, t.db, "qa", A, &.{ka}, fast);
    const f = (try board.getTicket(t.db, a, ka)).flags;
    try std.testing.expectEqual(@as(usize, 1), f.len);
    try std.testing.expectEqualStrings(board.flag_ci_failed, f[0].kind);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "CI failed at {s}: ci (test-macos)\nhttps://github.com/o/r/actions/runs/8\ncommit {s}", .{ A[0..12], A }), f[0].detail);

    // B (the fix, on A) passes: trunk is green, A's flag goes.
    const kb = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Fixed it", .stage = .done });
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = runs, .data = pass_json });
    try watch(t.ctx, t.cfg, t.db, "qa", B, &.{kb}, fast);
    try std.testing.expect(!try hasFlag(t, ka, board.flag_ci_failed));
    try std.testing.expectEqual(@as(usize, 0), (try board.listTickets(t.db, a, .{ .needs = true })).len);

    // A's watcher only now sees another failure of A: B passed after it, so
    // nothing is flagged.
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = runs, .data = fail_json });
    try watch(t.ctx, t.cfg, t.db, "qa", A, &.{ka}, fast);
    try std.testing.expect(!try hasFlag(t, ka, board.flag_ci_failed));

    // C fails, then a late pass of B arrives: B doesn't contain C, so C's
    // flag stays.
    const kc = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Broke it again", .stage = .done });
    try watch(t.ctx, t.cfg, t.db, "qa", C, &.{kc}, fast);
    try std.testing.expect(try hasFlag(t, kc, board.flag_ci_failed));
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = runs, .data = pass_json });
    try watch(t.ctx, t.cfg, t.db, "qa", B, &.{kb}, fast);
    try std.testing.expect(try hasFlag(t, kc, board.flag_ci_failed));

    // No run ever shows up: no flag, just a note.
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = runs, .data = "[]" });
    try watch(t.ctx, t.cfg, t.db, "qa", C, &.{kb}, fast);
    try std.testing.expectEqual(@as(usize, 0), (try board.getTicket(t.db, a, kb)).flags.len);

    // gh answers with something other than JSON: the watch ends with a note
    // in the log, not in silence.
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = runs, .data = "A new release of gh is available\n" });
    var noisy = fast;
    noisy.max_errors = 2;
    try watch(t.ctx, t.cfg, t.db, "qa", C, &.{kb}, noisy);
    const log = try std.Io.Dir.cwd().readFileAlloc(t.ctx.io, try logPath(t.ctx, a, t.cfg, "qa"), a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, log, "gh's answer isn't JSON: A new release of gh is available") != null);
}

test "a workflow that shows up after the first all-green poll still counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const t = try testSetup(a, &env, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    defer t.db.close();
    // The first `run list` sees only the quick workflow, passed; later ones
    // see the slow one too, failed.
    const gh = try std.fmt.allocPrint(a, "{s}/gh", .{t.base});
    try std.Io.Dir.cwd().writeFile(t.ctx.io, .{ .sub_path = gh, .data = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\[ "$2" = view ] && exit 0
        \\if [ -e {s}/seen ]; then
        \\  echo '[{{"databaseId":1,"status":"completed","conclusion":"success","workflowName":"lint","url":"u1"}},{{"databaseId":2,"status":"completed","conclusion":"failure","workflowName":"ci","url":"u2"}}]'
        \\else
        \\  touch {s}/seen
        \\  echo '[{{"databaseId":1,"status":"completed","conclusion":"success","workflowName":"lint","url":"u1"}}]'
        \\fi
        \\
    , .{ t.base, t.base }) });
    _ = try run(t.ctx, a, &.{ "chmod", "+x", gh });
    _ = try testGit(t, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
    const head = try a.dupe(u8, std.mem.trim(u8, try testGit(t, &.{ "rev-parse", "HEAD" }), "\n"));
    const k = try board.createTicket(t.ctx, t.db, a, .{ .project = "qa", .title = "Merged", .stage = .done });
    try watch(t.ctx, t.cfg, t.db, "qa", head, &.{k}, .{ .gh = gh, .first_ms = 1, .max_ms = 1, .appear_s = 0, .limit_s = 60 });
    try std.testing.expect(try hasFlag(t, k, board.flag_ci_failed));
}
