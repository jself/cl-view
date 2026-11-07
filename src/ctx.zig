//! Process-wide context handed to every module: Io, allocator, environment.
const std = @import("std");

const Ctx = @This();

io: std.Io,
gpa: std.mem.Allocator,
/// Process-lifetime allocator (never freed).
perm: std.mem.Allocator,
env: *std.process.Environ.Map,
home: []const u8,
/// The tmux server's socket (`tmux -S`), from CL_TMUX_SOCKET or tmux.socket;
/// null for tmux's default. Set by `tmux.configure`.
tmux_socket: ?[]const u8 = null,
/// A sandbox (HOME isn't the user's home) with no socket set: cl won't run
/// tmux at all, as it could reach the real server. Set by `tmux.configure`.
tmux_blocked: bool = false,

pub fn init(i: std.process.Init) Ctx {
    return .{
        .io = i.io,
        .gpa = i.gpa,
        .perm = i.arena.allocator(),
        .env = i.environ_map,
        .home = i.environ_map.get("HOME") orelse "/",
    };
}

/// This program's path, for commands cl hands out that run it again (hooks,
/// detached runners, the board's terminals). A binary rebuilt or installed
/// over while it runs reads as "<path> (deleted)" in /proc/self/exe; the path
/// itself is where its new build is, which is what those commands want (the
/// old file is gone).
pub fn exePath(self: Ctx, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return liveExe(buf[0..try std.process.executablePath(self.io, buf)]);
}

fn liveExe(path: []const u8) []const u8 {
    const gone = " (deleted)";
    return if (std.mem.endsWith(u8, path, gone)) path[0 .. path.len - gone.len] else path;
}

test liveExe {
    try std.testing.expectEqualStrings("/w/zig-out/bin/cl", liveExe("/w/zig-out/bin/cl (deleted)"));
    try std.testing.expectEqualStrings("/home/u/.local/bin/cl", liveExe("/home/u/.local/bin/cl"));
}

/// Expand a leading `~` to $HOME. Caller owns the result.
pub fn expandHome(self: Ctx, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        return std.fmt.allocPrint(self.gpa, "{s}{s}", .{ self.home, path[1..] });
    }
    return self.gpa.dupe(u8, path);
}

/// Replace a leading $HOME with `~` for display. Caller owns the result.
pub fn shortenHome(self: Ctx, path: []const u8) ![]const u8 {
    return self.shortenHomeIn(self.gpa, path);
}

pub fn shortenHomeIn(self: Ctx, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, self.home)) {
        return std.fmt.allocPrint(alloc, "~{s}", .{path[self.home.len..]});
    }
    return alloc.dupe(u8, path);
}

/// The first argument of a cl that `detach` started: `main` makes it a
/// session of its own (setsid) before anything else.
pub const detached_arg = "--detached";

/// Run cl itself with `args`, detached, so it outlives this process, the
/// server it came from and the tmux session that started that. It runs in a
/// session of its own with no controlling terminal (`detached_arg`), so
/// something in it that opens /dev/tty (an ssh or git prompt) fails at once
/// instead of stopping on SIGTTIN. Its stdio is /dev/null, and it isn't this
/// process's child, so nothing is left to reap. `setsid -f` did this, but
/// macOS has no setsid command.
pub fn detach(self: Ctx, args: []const []const u8) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = try self.gpa.alloc([]const u8, args.len + 2);
    defer self.gpa.free(full);
    full[0] = try self.exePath(&exe_buf);
    full[1] = detached_arg;
    @memcpy(full[2..], args);
    return self.detachArgv(full);
}

/// Start `argv` in the background through `sh … &`: in a process group of
/// its own (never a terminal's foreground group) and immune to hangups
/// (nohup) until it is in a session of its own. The shell exits at once,
/// so it isn't this process's child.
fn detachArgv(self: Ctx, argv: []const []const u8) !void {
    const pre = [_][]const u8{ "sh", "-c", "nohup \"$@\" </dev/null >/dev/null 2>&1 &", "sh" };
    const full = try self.gpa.alloc([]const u8, pre.len + argv.len);
    defer self.gpa.free(full);
    @memcpy(full[0..pre.len], &pre);
    @memcpy(full[pre.len..], argv);
    var child = try std.process.spawn(self.io, .{
        .argv = full,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const term = try child.wait(self.io);
    if (term != .exited or term.exited != 0) return error.SpawnFailed;
}

pub fn nowSeconds(self: Ctx) i64 {
    return std.Io.Timestamp.now(self.io, .real).toSeconds();
}

pub fn sleepMs(self: Ctx, ms: i64) void {
    self.io.sleep(.fromMilliseconds(ms), .real) catch {};
}

test detach {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&path_buf, "{s}/out", .{dir});
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    // It returns before the command has run; the command still runs, in a
    // process group of its own (its pgid is its own pid's group, not ours).
    try ctx.detachArgv(&.{ "sh", "-c", "sleep 0.2; ps -o pgid= -p $$ > \"$1\"", "sh", out });
    var tries: usize = 0;
    const got = while (tries < 50) : (tries += 1) {
        ctx.sleepMs(100);
        const s = tmp.dir.readFileAlloc(std.testing.io, "out", std.testing.allocator, .limited(64)) catch continue;
        if (s.len > 0) break s;
        std.testing.allocator.free(s);
    } else return error.NeverRan;
    defer std.testing.allocator.free(got);
    const pgid = try std.fmt.parseInt(i64, std.mem.trim(u8, got, " \n"), 10);
    try std.testing.expect(pgid != getpgrp());
}

extern "c" fn getpgrp() std.c.pid_t;
