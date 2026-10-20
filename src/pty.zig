//! A child process on a pseudo-terminal, for the web terminal. Linux uses raw
//! syscalls (the binaries are static, without libc); macOS goes through libc.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = posix.system;
const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,

    /// Read output from the child; 0 once it has exited.
    pub fn read(self: Pty, buf: []u8) usize {
        while (true) {
            const rc = sys.read(self.master, buf.ptr, buf.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                else => return 0, // EIO: the slave side closed
            }
        }
    }

    pub fn write(self: Pty, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const rc = sys.write(self.master, rest.ptr, rest.len);
            switch (posix.errno(rc)) {
                .SUCCESS => rest = rest[@intCast(rc)..],
                .INTR, .AGAIN => continue,
                else => return,
            }
        }
    }

    pub fn resize(self: Pty, cols: u16, rows: u16) void {
        var ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        _ = ioctl(self.master, T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Hang up on the child, reap it, and close the terminal.
    pub fn close(self: Pty) void {
        posix.kill(self.pid, .HUP) catch {};
        if (is_linux) {
            var status: u32 = 0;
            _ = linux.waitpid(self.pid, &status, 0);
        } else {
            var status: c_int = 0;
            _ = std.c.waitpid(self.pid, &status, 0);
        }
        _ = sys.close(self.master);
    }
};

pub const Error = error{ PtyFailed, ForkFailed, OutOfMemory };

/// Start `argv` on a new terminal of `cols` x `rows`. `argv[0]` must be an
/// absolute path; `env` entries are "KEY=value".
pub fn spawn(arena: std.mem.Allocator, argv: []const []const u8, env: []const []const u8, cols: u16, rows: u16) Error!Pty {
    // Everything the child needs is prepared before fork: after it, only syscalls.
    const c_argv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| c_argv[i] = try arena.dupeZ(u8, a);
    const c_env = try arena.allocSentinel(?[*:0]const u8, env.len, null);
    for (env, 0..) |e, i| c_env[i] = try arena.dupeZ(u8, e);

    const fds = try openPair(arena);
    errdefer _ = sys.close(fds.master);
    // The parent's copy of the slave goes once the child has its own; until
    // then it is close-on-exec, so other children started meanwhile don't
    // hold it open (which would keep `read` from seeing the hangup).
    defer _ = sys.close(fds.slave);

    var pty: Pty = .{ .master = fds.master, .pid = 0 };
    pty.resize(cols, rows);

    const pid_rc = sys.fork();
    if (posix.errno(pid_rc) != .SUCCESS) return error.ForkFailed;
    if (pid_rc == 0) {
        // Child: new session with the slave as its controlling terminal.
        _ = sys.setsid();
        _ = ioctl(fds.slave, T.IOCSCTTY, 0);
        _ = sys.dup2(fds.slave, 0);
        _ = sys.dup2(fds.slave, 1);
        _ = sys.dup2(fds.slave, 2);
        _ = sys.execve(c_argv[0].?, c_argv.ptr, c_env.ptr);
        exitChild();
    }
    pty.pid = @intCast(pid_rc);
    return pty;
}

const Pair = struct { master: posix.fd_t, slave: posix.fd_t };

fn openPair(arena: std.mem.Allocator) Error!Pair {
    if (is_linux) {
        const mrc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        if (linux.errno(mrc) != .SUCCESS) return error.PtyFailed;
        const master: posix.fd_t = @intCast(mrc);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyFailed;
        var n: c_uint = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.PtyFailed;
        const path = std.fmt.allocPrintSentinel(arena, "/dev/pts/{d}", .{n}, 0) catch return error.OutOfMemory;
        const src = linux.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        if (linux.errno(src) != .SUCCESS) return error.PtyFailed;
        return .{ .master = master, .slave = @intCast(src) };
    }
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.PtyFailed;
    _ = std.c.fcntl(master, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    _ = std.c.fcntl(slave, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    return .{ .master = master, .slave = slave };
}

/// Terminal ioctls. std's macOS table lacks these; values from <sys/ttycom.h>.
const T = if (is_linux) struct {
    const IOCSWINSZ = linux.T.IOCSWINSZ;
    const IOCSCTTY = linux.T.IOCSCTTY;
} else struct {
    const IOCSWINSZ = 0x80087467; // _IOW('t', 103, struct winsize)
    const IOCSCTTY = 0x20007461; // _IO('t', 97)
};

fn ioctl(fd: posix.fd_t, request: u32, arg: usize) usize {
    if (is_linux) return linux.ioctl(fd, request, arg);
    // libc takes the request as unsigned long; std.c declares it as int,
    // which can't hold the high bit these requests have.
    const rc = c_ioctl(fd, request, arg);
    return @bitCast(@as(isize, rc));
}

const c_ioctl = @extern(*const fn (c_int, c_ulong, ...) callconv(.c) c_int, .{ .name = "ioctl" });

extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const posix.winsize) c_int;

fn exitChild() noreturn {
    if (is_linux) linux.exit(127);
    std.c._exit(127);
}

test "spawn runs a child on a terminal of the given size" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const term = try spawn(arena_state.allocator(), &.{ "/bin/sh", "-c", "printf 'hi '; stty size" }, &.{"PATH=/bin:/usr/bin"}, 91, 17);
    var out: [256]u8 = undefined;
    var n: usize = 0;
    while (n < out.len) {
        const got = term.read(out[n..]);
        if (got == 0) break;
        n += got;
    }
    term.close();
    try std.testing.expectEqualStrings("hi 17 91", std.mem.trimEnd(u8, out[0..n], "\r\n"));
}
