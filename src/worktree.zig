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
    /// git: the branch; jj: the workspace name.
    branch: []const u8,
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

/// What a ticket's branch merges into: the branch the project's own checkout
/// is on (git), or trunk() (jj).
pub fn mainBranch(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) []const u8 {
    const vcs = detect(ctx, a, dir) catch return "master";
    if (vcs == .jj) return "trunk()";
    const outp = run(ctx, a, &.{ "git", "-C", dir, "symbolic-ref", "--short", "HEAD" }) catch return "master";
    const b = std.mem.trim(u8, outp, " \n");
    return if (b.len > 0) b else "master";
}

/// gutter's -r for a ticket started at `base`: git diffs the working tree
/// against it, jj takes the range up to the working copy.
pub fn reviewRev(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, base: []const u8) ![]const u8 {
    if (base.len == 0) return "";
    return switch (detect(ctx, a, dir) catch return base) {
        .git => base,
        .jj => std.fmt.allocPrint(a, "{s}..@", .{base}),
    };
}

/// Create the ticket's worktree from the repo's current revision.
pub fn create(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, repo: []const u8, project: []const u8, key: []const u8, title: []const u8) Error!Worktree {
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
        .jj => _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "add", "--name", name, path }),
    }
    return .{ .path = path, .branch = name };
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
            _ = try run(ctx, a, &.{ "jj", "-R", repo, "workspace", "forget", wt.branch });
            std.Io.Dir.cwd().deleteTree(ctx.io, wt.path) catch return error.CommandFailed;
        },
    }
}

/// The last failure's stderr, for messages.
pub var last_error: [512]u8 = undefined;
pub var last_error_len: usize = 0;

pub fn lastError() []const u8 {
    return std.mem.trim(u8, last_error[0..last_error_len], " \n");
}

/// Run a command; stdout on success. On failure stderr goes to last_error.
fn run(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8) Error![]const u8 {
    const res = std.process.run(a, ctx.io, .{ .argv = argv }) catch {
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
    const wt = try create(ctx, a, cfg, repo, "demo", "DE-1", "Try it");
    try std.testing.expectEqualStrings("de-1-try-it", wt.branch);
    try std.Io.Dir.cwd().access(ctx.io, try std.fmt.allocPrint(a, "{s}/.git", .{wt.path}), .{});
    try remove(ctx, a, repo, wt, true);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, wt.path, .{}));
}
