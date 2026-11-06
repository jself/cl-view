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

pub fn nowSeconds(self: Ctx) i64 {
    return std.Io.Timestamp.now(self.io, .real).toSeconds();
}

pub fn sleepMs(self: Ctx, ms: i64) void {
    self.io.sleep(.fromMilliseconds(ms), .real) catch {};
}
