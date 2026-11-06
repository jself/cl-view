//! A project's after-merge command (`cl project set <name> --after-merge`):
//! once cl has merged a ticket into trunk, it runs the command on the merged
//! code, detached, so it outlives the request (or the `cl web` it may
//! restart).
//!
//! It runs with `sh -c` in a clean checkout of the merged trunk commit, kept
//! at <board dir>/after-merge/<project> (a detached git worktree of the
//! project's repo, so build outputs it ignores stay between runs), not in the
//! project's own checkout, which may hold another ticket's unfinished work.
//! Environment: CL_TICKET (the last merged ticket), CL_TICKETS (all of them,
//! space separated), CL_PROJECT, CL_COMMIT, CL_PROJECT_DIR (the project's
//! checkout) and CL_CHECKOUT (the clean one, also the working directory).
//! Output goes to <board dir>/after-merge-<project>.log. Each ticket's
//! activity gets the start and the result; a failure flags it (after-merge)
//! with the log's tail.
//!
//! One run per project at a time: merges that land during a run get one more
//! run after it, on the newest trunk (see board.claimAfterMerge).
//!
//! When it fails, the operator is asked to sort it out (unless the project
//! turned Claude's after-merge steps off; see actions.claudeSteps). Without a
//! command, Claude does the after-merge steps instead (actions.zig).
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");
const actions = @import("actions.zig");
const operator = @import("operator.zig");

/// Lines of the log a failure flag shows.
const tail_lines = 20;

/// The log of a project's runs.
pub fn logPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, project: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/after-merge-{s}.log", .{ try board.dirPath(ctx, a, cfg), project });
}

/// A ticket was merged into the project's trunk: queue it for the project's
/// after-merge command and start a runner, detached (it exits at once if one
/// is running already; that one runs again for it). False when the project
/// has no command.
pub fn start(ctx: Ctx, db: board.Db, a: std.mem.Allocator, project: []const u8, ticket_id: i64, key: []const u8) !bool {
    const p = try board.getProject(db, a, project);
    if (p.after_merge.len == 0) return false;
    try board.queueAfterMerge(db, project, key);
    try board.logEvent(ctx, db, ticket_id, "after-merge queued", "");
    spawnRunner(ctx, a, project) catch |e| {
        try board.logEvent(ctx, db, ticket_id, "after-merge failed", @errorName(e));
        try board.setFlagId(ctx, db, ticket_id, board.flag_after_merge, "auto", "cl couldn't start the after-merge run");
    };
    return true;
}

/// Run `cl project after-merge <project> --run` in a session of its own
/// (setsid), so killing the server or the tmux session it came from leaves
/// it running.
fn spawnRunner(ctx: Ctx, a: std.mem.Allocator, project: []const u8) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];
    const r = try std.process.run(a, ctx.io, .{ .argv = &.{
        "sh", "-c", "exec setsid -f \"$@\" </dev/null >/dev/null 2>&1", "sh", exe, "project", "after-merge", project, "--run",
    } });
    if (r.term != .exited or r.term.exited != 0) return error.SpawnFailed;
}

/// Queue a run by hand (`cl project after-merge <name>`, the board's Run it
/// again), on trunk as it is; `key` is the ticket it is for, "-" for none.
pub fn startByHand(ctx: Ctx, db: board.Db, a: std.mem.Allocator, project: []const u8, key: []const u8) !void {
    try board.queueAfterMerge(db, project, key);
    try spawnRunner(ctx, a, project);
}

fn alive(pid: i64) bool {
    var buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}", .{pid}) catch return false;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

/// The runner: claim the project, then run once per batch of merged tickets
/// until none are waiting.
pub fn runLoop(ctx: Ctx, cfg: config.Config, db: board.Db, project: []const u8) !void {
    const pid: i64 = std.os.linux.getpid();
    if (!try board.claimAfterMerge(db, project, pid, alive)) return;
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const pending = (try board.takeAfterMerge(db, a, project)) orelse return;
        var keys: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, pending, " \n");
        while (it.next()) |k| {
            // By hand ("-"): also for the tickets whose run failed, so one
            // that passes now clears their flags.
            if (std.mem.eql(u8, k, "-")) {
                for (try board.listTickets(db, a, .{ .project = project, .flag = board.flag_after_merge })) |t| try addKey(a, &keys, t.key);
            }
            try addKey(a, &keys, k);
        }
        runOnce(ctx, cfg, db, a, project, keys.items) catch |e| {
            var buf: [128]u8 = undefined;
            record(ctx, db, a, keys.items, .{ .ok = false, .detail = std.fmt.bufPrint(&buf, "cl: {s}", .{@errorName(e)}) catch "cl failed" });
        };
    }
}

/// The same ticket twice (merged, reopened, merged): once is enough.
fn addKey(a: std.mem.Allocator, keys: *std.ArrayList([]const u8), k: []const u8) !void {
    for (keys.items) |x| if (std.mem.eql(u8, x, k)) return;
    try keys.append(a, k);
}

const Result = struct { ok: bool, detail: []const u8 };

fn runOnce(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, project: []const u8, keys: []const []const u8) !void {
    // Read now: the command may have changed since the merge.
    const p = try board.getProject(db, a, project);
    if (p.after_merge.len == 0) return;
    const log = try logPath(ctx, a, cfg, project);
    rotate(ctx, a, log);
    const commit = trunkCommit(ctx, a, p.dir) catch |e| {
        appendLog(ctx, a, log, try std.fmt.allocPrint(a, "\n=== {s}: no trunk commit to run on: {s}\n", .{ project, lastError() }));
        return e;
    };
    const short = commit[0..@min(commit.len, 12)];
    for (keys) |k| {
        const t = board.getTicket(db, a, k) catch continue;
        try board.clearFlagId(ctx, db, t.id, board.flag_after_merge);
        try board.logEvent(ctx, db, t.id, "after-merge started", short);
    }
    const checkout = try std.fmt.allocPrint(a, "{s}/after-merge/{s}", .{ try board.dirPath(ctx, a, cfg), project });
    cleanCheckout(ctx, a, p.dir, checkout, commit) catch |e| {
        appendLog(ctx, a, log, try std.fmt.allocPrint(a, "\n=== {s}: couldn't check out {s} at {s}: {s}\n", .{ project, short, checkout, lastError() }));
        const detail = try std.fmt.allocPrint(a, "couldn't check out {s}: {s}\n{s}", .{ short, @errorName(e), lastError() });
        record(ctx, db, a, keys, .{ .ok = false, .detail = detail });
        return askOperator(ctx, cfg, db, a, p, keys, detail, checkout);
    };

    var real: std.ArrayList([]const u8) = .empty;
    for (keys) |k| if (!std.mem.eql(u8, k, "-")) try real.append(a, k);
    var env = try ctx.env.clone(a);
    // It isn't in the ticket's tmux session, whatever started it.
    _ = env.swapRemove("TMUX");
    _ = env.swapRemove("TMUX_PANE");
    try env.put("CL_TICKET", if (real.items.len > 0) real.items[real.items.len - 1] else "");
    try env.put("CL_TICKETS", try std.mem.join(a, " ", real.items));
    try env.put("CL_PROJECT", project);
    try env.put("CL_COMMIT", commit);
    try env.put("CL_PROJECT_DIR", p.dir);
    try env.put("CL_CHECKOUT", checkout);
    try env.put("CL_AFTER_MERGE_LOG", log);
    try env.put("CL_AFTER_MERGE_CMD", p.after_merge);
    const script =
        \\exec </dev/null >>"$CL_AFTER_MERGE_LOG" 2>&1
        \\printf '\n=== %s %s %s at %s\n$ %s\n' "$(date '+%F %T')" "$CL_PROJECT" "${CL_TICKETS:-(by hand)}" "$CL_COMMIT" "$CL_AFTER_MERGE_CMD"
        \\sh -c "$CL_AFTER_MERGE_CMD"
        \\s=$?
        \\echo "=== exit $s"
        \\exit $s
    ;
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ "sh", "-c", script },
        .cwd = .{ .path = checkout },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(ctx.io);
    const code: ?u8 = switch (term) {
        .exited => |c| c,
        else => null,
    };
    if (code == 0) return record(ctx, db, a, keys, .{ .ok = true, .detail = short });
    const why = if (code) |c| try std.fmt.allocPrint(a, "exit {d}", .{c}) else "killed";
    const detail = try std.fmt.allocPrint(a, "{s} at {s} (log: {s})\n{s}", .{ why, short, try ctx.shortenHomeIn(a, log), lastRunTail(ctx, a, log) });
    record(ctx, db, a, keys, .{ .ok = false, .detail = detail });
    askOperator(ctx, cfg, db, a, p, keys, detail, checkout);
}

/// The command failed: the operator (Claude) is asked to sort it out, unless
/// the project turned Claude's after-merge steps off. The flag stays until a
/// run passes.
fn askOperator(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, p: board.Project, keys: []const []const u8, detail: []const u8, checkout: []const u8) void {
    const steps = actions.claudeSteps(p) orelse return;
    var real: std.ArrayList([]const u8) = .empty;
    for (keys) |k| if (!std.mem.eql(u8, k, "-")) real.append(a, k) catch return;
    const which = if (real.items.len > 0) std.fmt.allocPrint(a, "after cl merged {s} into trunk", .{std.mem.join(a, ", ", real.items) catch return}) catch return else "on a run started by hand";
    const text = std.fmt.allocPrint(a, "The after-merge command of project {s} failed {s}: {s}\nIt runs with sh -c in a clean checkout of the merged commit at {s} (the project's own checkout is {s}): {s}\nFind out why. If it's the environment (a missing tool, a stale process, a full disk), fix that and run it again with `cl project after-merge {s}`; a run that passes clears the tickets' after-merge flags. If the merged code itself is broken, don't fix it on trunk yourself: make a ticket for the fix (`cl ticket new {s} \"<title>\" -m \"<what broke>\"`) and tell me. What the project wants done after a merge: {s}", .{ p.name, which, detail, checkout, p.dir, p.after_merge, p.name, p.name, steps }) catch return;
    const sent = if (operator.send(ctx, cfg, text)) |_| true else |_| false;
    for (real.items) |k| {
        const t = board.getTicket(db, a, k) catch continue;
        board.logEvent(ctx, db, t.id, "after-merge", if (sent) "asked the operator to look into it" else "couldn't reach the operator") catch {};
    }
}

/// The result goes on each ticket: its activity, and a flag when it failed.
fn record(ctx: Ctx, db: board.Db, a: std.mem.Allocator, keys: []const []const u8, r: Result) void {
    for (keys) |k| {
        const t = board.getTicket(db, a, k) catch continue;
        const first = std.mem.sliceTo(r.detail, '\n');
        board.logEvent(ctx, db, t.id, if (r.ok) "after-merge ok" else "after-merge failed", first) catch {};
        if (!r.ok) board.setFlagId(ctx, db, t.id, board.flag_after_merge, "auto", r.detail) catch {};
    }
}

/// The commit trunk is on now: jj's trunk bookmark, git's main branch.
fn trunkCommit(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    if (worktree.trunkBookmark(ctx, a, dir)) |b| {
        const rev = try std.fmt.allocPrint(a, "\"{s}\"", .{b});
        return std.mem.trim(u8, try run(ctx, a, null, &.{ "jj", "-R", dir, "--ignore-working-copy", "log", "--no-graph", "-r", rev, "-T", "commit_id" }), " \n");
    }
    const main = worktree.mainBranch(ctx, a, dir);
    return std.mem.trim(u8, try run(ctx, a, null, &.{ "git", "-C", dir, "rev-parse", "--verify", try std.fmt.allocPrint(a, "{s}^{{commit}}", .{main}) }), " \n");
}

/// The repo's git directory: git's own, or a non-colocated jj repo's store.
fn gitDir(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    if (run(ctx, a, null, &.{ "git", "-C", dir, "rev-parse", "--absolute-git-dir" })) |o| return std.mem.trim(u8, o, " \n") else |_| {}
    const store = try std.fmt.allocPrint(a, "{s}/.jj/repo/store/git", .{dir});
    try std.Io.Dir.cwd().access(ctx.io, store, .{});
    return store;
}

/// Put `path` on `commit`, clean: a detached worktree of the project's repo,
/// reset to it with untracked files removed (ignored ones, like build
/// output, stay). Made, or made again, when it isn't a working one.
fn cleanCheckout(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, path: []const u8, commit: []const u8) !void {
    const reuse = blk: {
        _ = run(ctx, a, null, &.{ "git", "-C", path, "checkout", "--quiet", "--detach", "--force", commit }) catch break :blk false;
        _ = run(ctx, a, null, &.{ "git", "-C", path, "clean", "-fdq" }) catch break :blk false;
        break :blk true;
    };
    if (reuse) return;
    const gd = try gitDir(ctx, a, dir);
    std.Io.Dir.cwd().deleteTree(ctx.io, path) catch {};
    _ = run(ctx, a, null, &.{ "git", "--git-dir", gd, "worktree", "prune" }) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?);
    _ = try run(ctx, a, null, &.{ "git", "--git-dir", gd, "worktree", "add", "--quiet", "--detach", "--force", path, commit });
}

/// Keep the log from growing without end: past 1 MB it moves to .log.1.
fn rotate(ctx: Ctx, a: std.mem.Allocator, log: []const u8) void {
    const st = std.Io.Dir.cwd().statFile(ctx.io, log, .{}) catch return;
    if (st.size < 1 << 20) return;
    const old = std.fmt.allocPrint(a, "{s}.1", .{log}) catch return;
    std.Io.Dir.rename(std.Io.Dir.cwd(), log, std.Io.Dir.cwd(), old, ctx.io) catch {};
}

fn appendLog(ctx: Ctx, a: std.mem.Allocator, log: []const u8, text: []const u8) void {
    const old = std.Io.Dir.cwd().readFileAlloc(ctx.io, log, a, .limited(4 << 20)) catch "";
    const data = std.mem.concat(a, u8, &.{ old, text }) catch return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = log, .data = data }) catch {};
}

/// The last lines of the newest run in the log.
fn lastRunTail(ctx: Ctx, a: std.mem.Allocator, log: []const u8) []const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, log, a, .limited(4 << 20)) catch return "";
    return tailOfLastRun(text);
}

fn tailOfLastRun(text: []const u8) []const u8 {
    const from = if (std.mem.lastIndexOf(u8, text, "\n=== ")) |i| blk: {
        // The newest run starts at the header before its "=== exit" line.
        const before = std.mem.lastIndexOf(u8, text[0..i], "\n=== ") orelse i;
        break :blk if (std.mem.startsWith(u8, text[i..], "\n=== exit")) before else i;
    } else 0;
    const run_text = std.mem.trimEnd(u8, text[from..], " \n");
    var n: usize = 0;
    var i = run_text.len;
    while (i > 0) : (i -= 1) {
        if (run_text[i - 1] == '\n') {
            n += 1;
            if (n == tail_lines) break;
        }
    }
    return std.mem.trimStart(u8, run_text[i..], "\n");
}

test tailOfLastRun {
    const log = "\n=== old run\nold output\n=== exit 0\n\n=== new run\n$ make\nbuild failed\n=== exit 2\n";
    try std.testing.expectEqualStrings("=== new run\n$ make\nbuild failed\n=== exit 2", tailOfLastRun(log));
}

var last_error: [512]u8 = undefined;
var last_error_len: usize = 0;

fn lastError() []const u8 {
    return std.mem.trim(u8, last_error[0..last_error_len], " \n");
}

fn run(ctx: Ctx, a: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) ![]const u8 {
    const res = std.process.run(a, ctx.io, .{ .argv = argv, .cwd = if (cwd) |d| .{ .path = d } else .inherit }) catch |e| {
        setError(argv[0]);
        return e;
    };
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        setError(if (res.stderr.len > 0) res.stderr else argv[0]);
        return error.CommandFailed;
    }
    return res.stdout;
}

fn setError(text: []const u8) void {
    const n = @min(text.len, last_error.len);
    @memcpy(last_error[0..n], text[0..n]);
    last_error_len = n;
}
