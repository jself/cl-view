//! One worktree per ticket: `git worktree` in git repos, `jj workspace` in jj
//! repos, at <board.worktrees>/<project>/<slug>, where the slug is the
//! ticket's key and title (qa-17-flaky-login-spec). For git the slug is also
//! the branch; for jj it names the workspace.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");

pub const Vcs = enum { git, jj };

pub const Error = error{ NotARepo, CommandFailed, OutOfMemory };

pub const Worktree = struct {
    path: []const u8,
    /// git: the branch; jj: the workspace name, and the bookmark on its change.
    branch: []const u8,
    /// jj: the ticket's change, "" for git or a worktree made earlier.
    change: []const u8 = "",
};

/// The worktrees root from the config, or ~/.local/share/cl/worktrees.
pub fn root(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    if (cfg.board.worktrees.len > 0) return cfg.board.worktrees;
    return std.fmt.allocPrint(a, "{s}/.local/share/cl/worktrees", .{ctx.home});
}

/// jj when the directory has a .jj (colocated repos too), else git.
pub fn detect(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) Error!Vcs {
    const jj_path = try std.fmt.allocPrint(a, "{s}/.jj", .{dir});
    if (std.Io.Dir.cwd().access(ctx.io, jj_path, .{})) |_| return .jj else |_| {}
    _ = run(ctx, a, &.{ "git", "-C", dir, "rev-parse", "--git-dir" }) catch return error.NotARepo;
    return .git;
}

/// Give a project jj: `jj git init --colocate` when `dir` isn't in a jj repo
/// yet, so git keeps working and worktrees become jj workspaces. Left alone
/// when `dir` sits inside a bigger git repo (that would nest a new repo) or
/// jj isn't installed. True when it ran.
pub fn ensureJj(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) bool {
    if (run(ctx, a, &.{ "jj", "root", "-R", dir })) |_| return false else |_| {}
    if (run(ctx, a, &.{ "git", "-C", dir, "rev-parse", "--show-toplevel" })) |top| {
        if (!std.mem.eql(u8, std.mem.trim(u8, top, " \n"), dir)) return false;
    } else |_| {}
    _ = run(ctx, a, &.{ "jj", "git", "init", "--colocate", dir }) catch return false;
    return true;
}

test ensureJj {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = run(ctx, a, &.{ "jj", "--version" }) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    _ = run(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    try tmp.dir.createDirPath(ctx.io, "sub");
    // A directory inside the git repo is left alone.
    try std.testing.expect(!ensureJj(ctx, a, try std.fmt.allocPrint(a, "{s}/sub", .{repo})));
    try std.testing.expectEqual(Vcs.git, try detect(ctx, a, repo));
    // The repo itself gets jj, once.
    try std.testing.expect(ensureJj(ctx, a, repo));
    try std.testing.expectEqual(Vcs.jj, try detect(ctx, a, repo));
    try std.testing.expect(!ensureJj(ctx, a, repo));
    // Colocated, so the merge target is still a git branch.
    try std.testing.expectEqualStrings("master", mainBranch(ctx, a, repo));
}

/// `<key>-<title words>`, lower case, at most 48 characters.
pub fn slug(a: std.mem.Allocator, key: []const u8, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (key) |ch| try out.append(a, std.ascii.toLower(ch));
    var it = std.mem.tokenizeAny(u8, title, " \t-_/.,:;()[]{}'\"!?");
    while (it.next()) |w| {
        var word_buf: [48]u8 = undefined;
        var n: usize = 0;
        for (w) |ch| if (std.ascii.isAlphanumeric(ch) and n < word_buf.len) {
            word_buf[n] = std.ascii.toLower(ch);
            n += 1;
        };
        if (n == 0) continue;
        if (out.items.len + 1 + n > 48) break;
        try out.append(a, '-');
        try out.appendSlice(a, word_buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

test slug {
    const a = std.testing.allocator;
    const s = try slug(a, "QA-17", "Flaky login spec (on CI)!");
    defer a.free(s);
    try std.testing.expectEqualStrings("qa-17-flaky-login-spec-on-ci", s);
}

/// The revision a ticket starts from in `dir`: git HEAD, or for jj the parent
/// of the working copy (new workspaces start on top of it). "" if unknown.
pub fn baseRev(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) []const u8 {
    const vcs = detect(ctx, a, dir) catch return "";
    const outp = switch (vcs) {
        .git => run(ctx, a, &.{ "git", "-C", dir, "rev-parse", "HEAD" }),
        .jj => run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", "@-", "-T", "commit_id" }),
    } catch return "";
    return std.mem.trim(u8, outp, " \n");
}

/// What a ticket's branch merges into (git): origin's default branch, else
/// main or master, else the branch the project's checkout is on. The checkout
/// itself may be on a ticket's branch, so that comes last. jj: trunk().
pub fn mainBranch(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) []const u8 {
    const vcs = detect(ctx, a, dir) catch return "master";
    // A colocated jj repo still has git's branches; only pure jj needs trunk().
    if (vcs == .jj) _ = run(ctx, a, &.{ "git", "-C", dir, "rev-parse", "--git-dir" }) catch return "trunk()";
    if (run(ctx, a, &.{ "git", "-C", dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })) |outp| {
        const b = std.mem.trim(u8, outp, " \n");
        if (std.mem.startsWith(u8, b, "origin/") and b.len > "origin/".len) return b["origin/".len..];
    } else |_| {}
    for ([_][]const u8{ "main", "master" }) |b| {
        if (run(ctx, a, &.{ "git", "-C", dir, "rev-parse", "--verify", "--quiet", std.fmt.allocPrint(a, "refs/heads/{s}", .{b}) catch continue })) |_| return b else |_| {}
    }
    const outp = run(ctx, a, &.{ "git", "-C", dir, "symbolic-ref", "--short", "HEAD" }) catch return "master";
    const b = std.mem.trim(u8, outp, " \n");
    return if (b.len > 0) b else "master";
}

test "mainBranch prefers the default branch over the checked-out one" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    _ = run(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    _ = try run(ctx, a, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init" });
    _ = try run(ctx, a, &.{ "git", "-C", repo, "checkout", "-q", "-b", "de-1-work" });
    try std.testing.expectEqualStrings("master", mainBranch(ctx, a, repo));
}

/// gutter's -r for a ticket started at `base`: jj shows the ticket's change
/// (with any changes on top of it), else git diffs the working tree against
/// `base` and jj takes the range up to the working copy.
pub fn reviewRev(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, base: []const u8, change: []const u8) ![]const u8 {
    if (change.len > 0) return std.fmt.allocPrint(a, "{s}::", .{change});
    if (base.len == 0) return "";
    return switch (detect(ctx, a, dir) catch return base) {
        .git => base,
        .jj => std.fmt.allocPrint(a, "{s}..@", .{base}),
    };
}

/// Create the ticket's worktree: git from the repo's current revision, jj as
/// a new change on top of `trunk` described `desc` (see `newChange`).
pub fn create(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, repo: []const u8, project: []const u8, key: []const u8, title: []const u8, trunk: []const u8, desc: []const u8) Error!Worktree {
    const vcs = try detect(ctx, a, repo);
    const name = try slug(a, key, title);
    const base = root(ctx, a, cfg) catch return error.OutOfMemory;
    const parent = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, project });
    std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch return error.CommandFailed;
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, name });
    // Left by an earlier start that failed later on: use it again.
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| return .{ .path = path, .branch = name } else |_| {}
    switch (vcs) {
        .git => {
            // Reuse the branch if an earlier attempt made it.
            const exists = if (run(ctx, a, &.{ "git", "-C", repo, "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(a, "refs/heads/{s}", .{name}) })) |_| true else |_| false;
            if (exists) {
                _ = try run(ctx, a, &.{ "git", "-C", repo, "worktree", "add", path, name });
            } else {
                _ = try run(ctx, a, &.{ "git", "-C", repo, "worktree", "add", "-b", name, path, "HEAD" });
            }
        },
        .jj => {
            if (trunk.len == 0) {
                _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "add", "--name", name, path });
                return .{ .path = path, .branch = name };
            }
            _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "add", "--name", name, "-r", try sym(a, trunk), "-m", desc, path });
            const c = try mark(ctx, a, path, name);
            return .{ .path = path, .branch = c.bookmark, .change = c.id };
        },
    }
    return .{ .path = path, .branch = name };
}

/// A jj workspace for a change that exists already (a queue ticket moving to
/// a worktree of its own): its working copy is `change` itself, bookmark and
/// all. `repo`'s working copy leaves the change first for a new one on top
/// of `trunk`, so only the workspace works on it.
pub fn createOn(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, repo: []const u8, project: []const u8, key: []const u8, title: []const u8, change: []const u8, bookmark: []const u8, trunk: []const u8) Error!Worktree {
    const name = try slug(a, key, title);
    const base = root(ctx, a, cfg) catch return error.OutOfMemory;
    const parent = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, project });
    std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch return error.CommandFailed;
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, name });
    const wt: Worktree = .{ .path = path, .branch = bookmark, .change = change };
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| return wt else |_| {}
    // Snapshots the checkout's files into the change before it leaves.
    if (std.mem.eql(u8, try workingChange(ctx, a, repo), change)) _ = try run(ctx, a, &.{ "jj", "-R", repo, "new", try sym(a, trunk) });
    _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "add", "--name", name, "-r", change, path });
    // The workspace starts on a new empty change on top; editing the change
    // itself drops that one.
    _ = try run(ctx, a, &.{ "jj", "-R", path, "edit", change });
    return wt;
}

/// Let go of a jj workspace but keep its work: what its files hold goes into
/// its change first, then the workspace is forgotten and its directory goes.
pub fn forget(ctx: Ctx, a: std.mem.Allocator, repo: []const u8, path: []const u8) Error!void {
    _ = try workingChange(ctx, a, path);
    _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "forget", std.fs.path.basename(path) });
    std.Io.Dir.cwd().deleteTree(ctx.io, path) catch return error.CommandFailed;
}

// ---- planning workspaces ----
//
// A planning session reads the code but writes none, so it gets a checkout
// of its own on trunk: not the project's checkout, which may hold another
// ticket's unmerged work. It goes when planning ends.

/// Where the ticket's planning workspace goes: <worktrees>/<project>/<key>-plan.
pub fn planPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, project: []const u8, key: []const u8) ![]const u8 {
    const base = try root(ctx, a, cfg);
    return std.fmt.allocPrint(a, "{s}/{s}/{s}-plan", .{ base, project, try std.ascii.allocLowerString(a, key) });
}

/// Make the planning workspace at `path` (kept if it is there already): jj
/// on `trunk` (trunk() when null or not a local bookmark), git detached at the repo's HEAD. The
/// project's local Claude settings come along, so its allowed commands
/// don't ask again.
pub fn createPlan(ctx: Ctx, a: std.mem.Allocator, repo: []const u8, path: []const u8, trunk: ?[]const u8) Error!void {
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| return else |_| {}
    const vcs = try detect(ctx, a, repo);
    std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path) orelse ".") catch return error.CommandFailed;
    switch (vcs) {
        .jj => _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "add", "--name", std.fs.path.basename(path), "-r", if (trunk) |t| try std.fmt.allocPrint(a, "coalesce(present({s}), trunk())", .{try sym(a, t)}) else "trunk()", path }),
        .git => _ = try run(ctx, a, &.{ "git", "-C", repo, "worktree", "add", "--detach", path, "HEAD" }),
    }
    const settings = try std.fmt.allocPrint(a, "{s}/.claude/settings.local.json", .{repo});
    if (std.Io.Dir.cwd().access(ctx.io, settings, .{})) |_| {
        const dst = try std.fmt.allocPrint(a, "{s}/.claude", .{path});
        std.Io.Dir.cwd().createDirPath(ctx.io, dst) catch return;
        _ = run(ctx, a, &.{ "cp", "-n", settings, dst }) catch {};
    } else |_| {}
}

/// Remove the planning workspace at `path`, if there is one. jj drops its
/// working copy with it when nothing was written there.
pub fn removePlan(ctx: Ctx, a: std.mem.Allocator, repo: []const u8, path: []const u8) void {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return;
    switch (detect(ctx, a, repo) catch .jj) {
        .jj => _ = run(ctx, a, &.{ "jj", "-R", repo, "workspace", "forget", std.fs.path.basename(path) }) catch {},
        .git => _ = run(ctx, a, &.{ "git", "-C", repo, "worktree", "remove", "--force", path }) catch {},
    }
    std.Io.Dir.cwd().deleteTree(ctx.io, path) catch {};
    if ((detect(ctx, a, repo) catch .jj) == .git) _ = run(ctx, a, &.{ "git", "-C", repo, "worktree", "prune" }) catch {};
}

/// Move cl's ticket files (review guide, review, test plan in .claude/) from
/// one checkout to another, where it has none of its own yet.
pub fn carryClFiles(ctx: Ctx, a: std.mem.Allocator, from: []const u8, to: []const u8) void {
    const dst = std.fmt.allocPrint(a, "{s}/.claude", .{to}) catch return;
    std.Io.Dir.cwd().createDirPath(ctx.io, dst) catch return;
    for ([_][]const u8{ "review-guide.md", "review.md", "test-plan.md" }) |name| {
        const src = std.fmt.allocPrint(a, "{s}/.claude/{s}", .{ from, name }) catch return;
        std.Io.Dir.cwd().access(ctx.io, src, .{}) catch continue;
        _ = run(ctx, a, &.{ "mv", "-n", src, std.fmt.allocPrint(a, "{s}/{s}", .{ dst, name }) catch return }) catch {};
    }
}

/// Remove a ticket's worktree. git refuses when it has uncommitted changes;
/// `delete_branch` also deletes a fully merged branch.
pub fn remove(ctx: Ctx, a: std.mem.Allocator, repo: []const u8, wt: Worktree, delete_branch: bool) Error!void {
    switch (try detect(ctx, a, repo)) {
        .git => {
            _ = try run(ctx, a, &.{ "git", "-C", repo, "worktree", "remove", wt.path });
            if (delete_branch) _ = try run(ctx, a, &.{ "git", "-C", repo, "branch", "-d", wt.branch });
        },
        .jj => {
            // Named after its directory; its bookmark may be "" (name taken).
            _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "forget", std.fs.path.basename(wt.path) });
            std.Io.Dir.cwd().deleteTree(ctx.io, wt.path) catch return error.CommandFailed;
            // Merging it back deleted the bookmark already.
            if (delete_branch and wt.branch.len > 0) _ = run(ctx, a, &.{ "jj", "-R", repo, "bookmark", "delete", wt.branch }) catch {};
        },
    }
}

// ---- jj: a change per ticket ----
//
// Every ticket gets a change of its own on top of trunk, with a bookmark on
// it so git sees a branch. Queue tickets share the project's checkout, which
// switches to a ticket's change (`jj edit`) when its session takes the ticket
// up; jj snapshots the files into the change it leaves, so nothing has to be
// committed by hand. Done merges the change back into trunk.

/// What a ticket's change merges into, as a bookmark: the default branch
/// (colocated repos), else trunk()'s local bookmark. null for git repos or
/// when there is no such bookmark.
pub fn trunkBookmark(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    if ((detect(ctx, a, dir) catch return null) != .jj) return null;
    const b = mainBranch(ctx, a, dir);
    if (!std.mem.eql(u8, b, "trunk()")) return b;
    const outp = run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", "trunk()", "-T", "local_bookmarks.map(|b| b.name()).join(\"\\n\")" }) catch return null;
    var it = std.mem.tokenizeAny(u8, outp, " \n");
    return it.next();
}

/// A bookmark or change id as a revset symbol (bookmarks may hold '-' or '/').
fn sym(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "\"{s}\"", .{name});
}

pub const Change = struct {
    id: []const u8,
    /// "" when the name was taken by a branch that isn't merged.
    bookmark: []const u8,
};

/// Give `dir`'s working copy a new change on top of `trunk`, described `desc`
/// and with `bookmark` on it. What the working copy had stays in the change
/// it leaves (jj snapshots it first).
pub fn newChange(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, trunk: []const u8, desc: []const u8, bookmark: []const u8) Error!Change {
    _ = try run(ctx, a, &.{ "jj", "-R", dir, "new", try sym(a, trunk), "-m", desc });
    return mark(ctx, a, dir, bookmark);
}

/// The working copy's change when it holds work nobody has claimed: edits,
/// no description, not in trunk. jj keeps such a change when the working
/// copy moves off it, but nothing points at it, so it is easily lost.
pub fn strayWork(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, trunk: []const u8) ?[]const u8 {
    const revs = std.fmt.allocPrint(a, "@ & description(exact:\"\") & ~empty() & ~::{s}", .{sym(a, trunk) catch return null}) catch return null;
    const hit = changes(ctx, a, dir, revs) catch return null;
    return if (hit.len == 1) hit[0] else null;
}

/// Make the working copy's change a ticket's own: describe it `desc` and
/// put `bookmark` on it (see `mark`).
pub fn adoptChange(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, desc: []const u8, bookmark: []const u8) Error!Change {
    _ = try run(ctx, a, &.{ "jj", "-R", dir, "describe", "-r", "@", "-m", desc });
    return mark(ctx, a, dir, bookmark);
}

/// The working copy's change, with `bookmark` put on it. A bookmark of that
/// name already elsewhere only moves forward (an old merged branch); else the
/// change goes without one.
fn mark(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, bookmark: []const u8) Error!Change {
    const id = try workingChange(ctx, a, dir);
    if (run(ctx, a, &.{ "jj", "-R", dir, "bookmark", "set", bookmark, "-r", id })) |_| {
        return .{ .id = id, .bookmark = bookmark };
    } else |_| return .{ .id = id, .bookmark = "" };
}

/// The change id of `dir`'s working copy.
pub fn workingChange(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) Error![]const u8 {
    return std.mem.trim(u8, try run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", "@", "-T", "change_id" }), " \n");
}

/// The commit id of `dir`'s working copy (it changes with every snapshot).
pub fn workingCommit(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) Error![]const u8 {
    return std.mem.trim(u8, try run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", "@", "-T", "commit_id" }), " \n");
}

/// The working copy's files differ from those of commit `from`.
pub fn filesDiffer(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, from: []const u8) bool {
    const outp = run(ctx, a, &.{ "jj", "-R", dir, "diff", "--summary", "--from", from, "--to", "@" }) catch return true;
    return std.mem.trim(u8, outp, " \n").len > 0;
}

/// Switch `dir`'s working copy to `change`; false when it is there already.
pub fn editChange(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, change: []const u8) Error!bool {
    if (std.mem.eql(u8, try workingChange(ctx, a, dir), change)) return false;
    _ = try run(ctx, a, &.{ "jj", "-R", dir, "edit", change });
    return true;
}

pub const ChangeState = enum {
    /// Still its own: work goes on in it.
    open,
    /// In trunk already (merged), or no longer there: the ticket needs a new one.
    merged,
    gone,
};

pub fn changeState(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, change: []const u8, trunk: []const u8) ChangeState {
    const revs = std.fmt.allocPrint(a, "present({s})", .{change}) catch return .gone;
    const there = run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", revs, "-T", "change_id" }) catch return .gone;
    if (std.mem.trim(u8, there, " \n").len == 0) return .gone;
    const in = std.fmt.allocPrint(a, "{s} & ::{s}", .{ change, sym(a, trunk) catch return .open }) catch return .open;
    const merged = run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", in, "-T", "change_id" }) catch return .open;
    return if (std.mem.trim(u8, merged, " \n").len > 0) .merged else .open;
}

/// What of a ticket's work isn't on trunk, said in a line ("2 changes on
/// cl-9-x aren't in master"), or null when it all is (or there is none, or
/// it can't tell). jj: `change`, unless it is in `main`, and what was built
/// on top of it, that hold edits. git (no change): commits on `branch` that
/// `main` lacks.
pub fn unmergedWork(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, change: []const u8, branch: []const u8, main: []const u8) ?[]const u8 {
    const m = sym(a, main) catch return null;
    if (change.len > 0) {
        // In trunk itself: it landed (and what came later on top of it is
        // other tickets' work).
        if (changeState(ctx, a, dir, change, main) != .open) return null;
        const revs = std.fmt.allocPrint(a, "({s}:: ~ empty()) ~ ::{s}", .{ change, m }) catch return null;
        const left = changes(ctx, a, dir, revs) catch return null;
        if (left.len == 0) return null;
        const on = if (branch.len > 0) branch else change[0..@min(change.len, 12)];
        return std.fmt.allocPrint(a, "{d} change{s} on {s} {s} in {s}", .{ left.len, if (left.len == 1) "" else "s", on, if (left.len == 1) "isn't" else "aren't", main }) catch null;
    }
    if (branch.len == 0) return null;
    const range = std.fmt.allocPrint(a, "{s}..{s}", .{ main, branch }) catch return null;
    const outp = run(ctx, a, &.{ "git", "-C", dir, "rev-list", "--count", range }) catch return null;
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, outp, " \n"), 10) catch return null;
    if (n == 0) return null;
    return std.fmt.allocPrint(a, "{d} commit{s} on {s} {s} in {s}", .{ n, if (n == 1) "" else "s", branch, if (n == 1) "isn't" else "aren't", main }) catch null;
}

/// Lines of `jj log` output for `revs` (one change id each).
fn changes(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, revs: []const u8) Error![][]const u8 {
    const outp = try run(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", revs, "-T", "change_id ++ \"\\n\"" });
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, outp, " \n");
    while (it.next()) |l| try list.append(a, l);
    return list.items;
}

pub const Merge = struct {
    /// Trunk has it now (or it had nothing to merge).
    merged: bool,
    /// The conflicted files, one per line, when it didn't merge.
    conflicts: []const u8 = "",
    /// It held no changes; it was dropped instead.
    empty: bool = false,
};

/// Merge a ticket's change back: rebase it (with anything on top of it)
/// onto trunk, then, with no conflicts, move trunk to it and drop its
/// bookmark. jj records conflicts in the rebased change; trunk stays put and
/// they are listed so they can be resolved there. `work_dir` is the ticket's
/// own workspace when it has one: jj only sees its edits once it snapshots
/// there.
pub fn mergeChange(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, work_dir: []const u8, change: []const u8, bookmark: []const u8, trunk: []const u8) Error!Merge {
    if (work_dir.len > 0) _ = try workingChange(ctx, a, work_dir);
    const t = try sym(a, trunk);
    _ = try run(ctx, a, &.{ "jj", "-R", dir, "rebase", "-b", change, "-d", t });
    // Its work may go on in changes on top (`jj commit`, `jj new`): take
    // the last one that holds anything.
    const heads = try changes(ctx, a, dir, try std.fmt.allocPrint(a, "heads({s}:: ~ empty())", .{change}));
    const tip = if (heads.len == 1) heads[0] else change;
    const range = try std.fmt.allocPrint(a, "{s}..{s}", .{ t, tip });
    if ((try changes(ctx, a, dir, try std.fmt.allocPrint(a, "({s}) & conflicts()", .{range}))).len > 0) {
        // Run there, so the paths are the repo's own.
        const files = runIn(ctx, a, dir, &.{ "jj", "-R", dir, "resolve", "--list", "-r", tip }) catch "";
        return .{ .merged = false, .conflicts = std.mem.trim(u8, files, " \n") };
    }
    var res: Merge = .{ .merged = true };
    if ((try changes(ctx, a, dir, try std.fmt.allocPrint(a, "({s}) ~ empty()", .{range}))).len == 0) {
        // Nothing in it: no empty commit on trunk.
        _ = try run(ctx, a, &.{ "jj", "-R", dir, "abandon", range });
        res.empty = true;
    } else {
        _ = try run(ctx, a, &.{ "jj", "-R", dir, "bookmark", "set", trunk, "-r", tip });
    }
    if (bookmark.len > 0) _ = run(ctx, a, &.{ "jj", "-R", dir, "bookmark", "delete", bookmark }) catch {};
    return res;
}

/// After a merge: a working copy left on a change that is in trunk now gets
/// a new change on top (or its edits would rewrite trunk), and one with
/// nothing of its own moves up to trunk so it has the merged code. A working
/// copy with work of its own stays where it is. True when it moved.
pub fn catchUp(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, trunk: []const u8) bool {
    const t = sym(a, trunk) catch return false;
    const revs = std.fmt.allocPrint(a, "@ & (::{0s} | ((empty() & description(exact:\"\") & (::{0s})+) ~ {0s}+))", .{t}) catch return false;
    const hit = changes(ctx, a, dir, revs) catch return false;
    if (hit.len == 0) return false;
    _ = run(ctx, a, &.{ "jj", "-R", dir, "new", t }) catch return false;
    return true;
}

/// Keep cl's own files (the review guide, review and test plan in .claude/)
/// out of every change: they belong to the ticket, not the code.
pub fn excludeClFiles(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) void {
    const path = std.fmt.allocPrint(a, "{s}/.git/info/exclude", .{dir}) catch return;
    const old = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return,
    };
    const lines = "/.claude/review-guide.md\n/.claude/review.md\n/.claude/test-plan.md\n";
    if (std.mem.indexOf(u8, old, "/.claude/test-plan.md") != null) return;
    std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?) catch return;
    const sep = if (old.len > 0 and old[old.len - 1] != '\n') "\n" else "";
    const data = std.fmt.allocPrint(a, "{s}{s}# cl's ticket files\n{s}", .{ old, sep, lines }) catch return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data }) catch {};
}

/// The last failure's stderr, for messages.
pub var last_error: [512]u8 = undefined;
pub var last_error_len: usize = 0;

pub fn lastError() []const u8 {
    return std.mem.trim(u8, last_error[0..last_error_len], " \n");
}

/// Run a command; stdout on success. On failure stderr goes to last_error.
fn run(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8) Error![]const u8 {
    return runIn(ctx, a, null, argv);
}

/// `run` from directory `cwd` (jj prints paths relative to where it runs).
fn runIn(ctx: Ctx, a: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) Error![]const u8 {
    const res = std.process.run(a, ctx.io, .{ .argv = argv, .cwd = if (cwd) |d| .{ .path = d } else .inherit }) catch {
        setError(argv[0]);
        return error.CommandFailed;
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
    last_error_len = @min(text.len, last_error.len);
    @memcpy(last_error[0..last_error_len], text[0..last_error_len]);
}

test "git worktree create and remove" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    _ = run(ctx, a, &.{ "git", "init", "-q", repo }) catch return error.SkipZigTest; // no git here
    _ = try run(ctx, a, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init" });
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    cfg.board.worktrees = try std.fmt.allocPrint(a, "{s}/wt", .{base});
    const wt = try create(ctx, a, cfg, repo, "demo", "DE-1", "Try it", "", "");
    try std.testing.expectEqualStrings("de-1-try-it", wt.branch);
    try std.Io.Dir.cwd().access(ctx.io, try std.fmt.allocPrint(a, "{s}/.git", .{wt.path}), .{});
    try remove(ctx, a, repo, wt, true);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, wt.path, .{}));
}

test "a change per ticket: switch, merge back, conflicts" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = run(ctx, a, &.{ "jj", "--version" }) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    _ = run(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "base\n" });
    _ = try run(ctx, a, &.{ "git", "-C", repo, "add", "a.txt" });
    _ = try run(ctx, a, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" });
    try std.testing.expect(ensureJj(ctx, a, repo));
    const trunk = trunkBookmark(ctx, a, repo).?;
    try std.testing.expectEqualStrings("master", trunk);
    const read = struct {
        fn f(c: Ctx, d: std.Io.Dir, al: std.mem.Allocator, name: []const u8) []const u8 {
            return d.readFileAlloc(c.io, name, al, .limited(1024)) catch "";
        }
    }.f;

    // Two tickets, each with a change of its own on master.
    const one = try newChange(ctx, a, repo, trunk, "T-1: one", "t-1-one");
    try std.testing.expectEqualStrings("t-1-one", one.bookmark);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "one\n" });
    const before = try workingCommit(ctx, a, repo);
    const two = try newChange(ctx, a, repo, trunk, "T-2: two", "t-2-two");
    // T-1's edit went with its change.
    try std.testing.expectEqualStrings("base\n", read(ctx, tmp.dir, a, "a.txt"));
    try std.testing.expect(filesDiffer(ctx, a, repo, before));
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "b.txt", .data = "two\n" });
    try std.testing.expect(try editChange(ctx, a, repo, one.id));
    try std.testing.expectEqualStrings("one\n", read(ctx, tmp.dir, a, "a.txt"));
    try std.testing.expect(!try editChange(ctx, a, repo, one.id));
    try std.testing.expectEqual(ChangeState.open, changeState(ctx, a, repo, two.id, trunk));

    // T-2 merges cleanly: master moves to it and its bookmark goes.
    const m2 = try mergeChange(ctx, a, repo, "", two.id, two.bookmark, trunk);
    try std.testing.expect(m2.merged and !m2.empty);
    try std.testing.expectEqual(ChangeState.merged, changeState(ctx, a, repo, two.id, trunk));
    try std.testing.expect(run(ctx, a, &.{ "git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/t-2-two" }) == error.CommandFailed);
    try std.testing.expectEqual(ChangeState.gone, changeState(ctx, a, repo, "wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww", trunk));

    // A third edits a.txt too and merges first; T-1 then conflicts, and
    // master stays where it is.
    const three = try newChange(ctx, a, repo, trunk, "T-3: three", "t-3-three");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "three\n" });
    try std.testing.expect((try mergeChange(ctx, a, repo, "", three.id, three.bookmark, trunk)).merged);
    // The checkout sat on T-3, which is master now: it gets a change on top.
    try std.testing.expect(catchUp(ctx, a, repo, trunk));
    try std.testing.expect(!catchUp(ctx, a, repo, trunk));
    const master_before = try run(ctx, a, &.{ "git", "-C", repo, "rev-parse", "master" });
    const m1 = try mergeChange(ctx, a, repo, "", one.id, one.bookmark, trunk);
    try std.testing.expect(!m1.merged);
    try std.testing.expect(std.mem.startsWith(u8, m1.conflicts, "a.txt"));
    try std.testing.expectEqualStrings(master_before, try run(ctx, a, &.{ "git", "-C", repo, "rev-parse", "master" }));

    // Settled in its change, it merges.
    _ = try editChange(ctx, a, repo, one.id);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "one and three\n" });
    try std.testing.expect((try mergeChange(ctx, a, repo, "", one.id, one.bookmark, trunk)).merged);
    const shown = try run(ctx, a, &.{ "git", "-C", repo, "show", "master:a.txt" });
    try std.testing.expectEqualStrings("one and three\n", shown);
    try std.testing.expectEqualStrings("two\n", try run(ctx, a, &.{ "git", "-C", repo, "show", "master:b.txt" }));

    // A change with nothing in it is dropped, not merged.
    _ = catchUp(ctx, a, repo, trunk);
    const master_now = try run(ctx, a, &.{ "git", "-C", repo, "rev-parse", "master" });
    const four = try newChange(ctx, a, repo, trunk, "T-4: nothing", "t-4-nothing");
    try std.testing.expect((try mergeChange(ctx, a, repo, "", four.id, four.bookmark, trunk)).empty);
    try std.testing.expectEqualStrings(master_now, try run(ctx, a, &.{ "git", "-C", repo, "rev-parse", "master" }));
    try std.testing.expectEqual(ChangeState.gone, changeState(ctx, a, repo, four.id, trunk));

    // Undescribed edits in the working copy are stray work; an adopted one
    // is a ticket's change and merges like one.
    _ = catchUp(ctx, a, repo, trunk);
    try std.testing.expect(strayWork(ctx, a, repo, trunk) == null);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "c.txt", .data = "stray\n" });
    const stray = strayWork(ctx, a, repo, trunk).?;
    const five = try adoptChange(ctx, a, repo, "T-5: legacy", "t-5-legacy");
    try std.testing.expectEqualStrings(stray, five.id);
    try std.testing.expect(strayWork(ctx, a, repo, trunk) == null);
    try std.testing.expect((try mergeChange(ctx, a, repo, "", five.id, five.bookmark, trunk)).merged);
    try std.testing.expectEqualStrings("stray\n", try run(ctx, a, &.{ "git", "-C", repo, "show", "master:c.txt" }));

    // A ticket's change moves to a workspace of its own and back, with the
    // edits it has in either place.
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    var wt_root = std.testing.tmpDir(.{});
    defer wt_root.cleanup();
    cfg.board.worktrees = try wt_root.dir.realPathFileAlloc(ctx.io, ".", a);
    _ = catchUp(ctx, a, repo, trunk);
    const six = try newChange(ctx, a, repo, trunk, "T-6: moves", "t-6-moves");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "d.txt", .data = "main\n" });
    const wt = try createOn(ctx, a, cfg, repo, "demo", "T-6", "moves", six.id, six.bookmark, trunk);
    try std.testing.expectEqualStrings(six.id, try workingChange(ctx, a, wt.path));
    try std.testing.expect(!std.mem.eql(u8, six.id, try workingChange(ctx, a, repo)));
    var wdir = try std.Io.Dir.cwd().openDir(ctx.io, wt.path, .{});
    defer wdir.close(ctx.io);
    try std.testing.expectEqualStrings("main\n", read(ctx, wdir, a, "d.txt"));
    try wdir.writeFile(ctx.io, .{ .sub_path = "d.txt", .data = "worktree\n" });
    try forget(ctx, a, repo, wt.path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, wt.path, .{}));
    try std.testing.expect(try editChange(ctx, a, repo, six.id));
    try std.testing.expectEqualStrings("worktree\n", read(ctx, tmp.dir, a, "d.txt"));
    try std.testing.expectEqual(ChangeState.open, changeState(ctx, a, repo, six.id, trunk));
    // Its work isn't on master; merged work (T-5's) and a change that's gone aren't reported.
    try std.testing.expectEqualStrings("1 change on t-6-moves isn't in master", unmergedWork(ctx, a, repo, six.id, six.bookmark, trunk).?);
    try std.testing.expect(unmergedWork(ctx, a, repo, five.id, "", trunk) == null);
    try std.testing.expect(unmergedWork(ctx, a, repo, four.id, "", trunk) == null);

    // cl's own files stay out of changes.
    excludeClFiles(ctx, a, repo);
    excludeClFiles(ctx, a, repo);
    try tmp.dir.createDirPath(ctx.io, ".claude");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/test-plan.md", .data = "## Checks\n" });
    const diff = try run(ctx, a, &.{ "jj", "-R", repo, "diff", "--summary" });
    try std.testing.expect(std.mem.indexOf(u8, diff, "test-plan") == null);
    const excl = read(ctx, tmp.dir, a, ".git/info/exclude");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, excl, "/.claude/test-plan.md"));
}
