//! A child process on a pseudo-terminal (Linux only), for the web terminal.
const std = @import("std");
const linux = std.os.linux;

pub const Pty = struct {
    master: linux.fd_t,
    pid: linux.pid_t,

    /// Read output from the child; 0 once it has exited.
    pub fn read(self: Pty, buf: []u8) usize {
        while (true) {
            const rc = linux.read(self.master, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                else => return 0, // EIO: the slave side closed
            }
        }
    }

    pub fn write(self: Pty, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const rc = linux.write(self.master, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => rest = rest[rc..],
                .INTR, .AGAIN => continue,
                else => return,
            }
        }
    }

    pub fn resize(self: Pty, cols: u16, rows: u16) void {
        var ws: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Hang up on the child, reap it, and close the terminal.
    pub fn close(self: Pty) void {
        _ = linux.kill(self.pid, .HUP);
        var status: u32 = 0;
        _ = linux.waitpid(self.pid, &status, 0);
        _ = linux.close(self.master);
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

    const mrc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(mrc) != .SUCCESS) return error.PtyFailed;
    const master: linux.fd_t = @intCast(mrc);
    errdefer _ = linux.close(master);
    var unlock: c_int = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyFailed;
    var n: c_uint = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.PtyFailed;
    const slave_path = std.fmt.allocPrintSentinel(arena, "/dev/pts/{d}", .{n}, 0) catch return error.OutOfMemory;

    var pty: Pty = .{ .master = master, .pid = 0 };
    pty.resize(cols, rows);

    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return error.ForkFailed;
    if (pid_rc == 0) {
        // Child: new session with the slave as its controlling terminal.
        _ = linux.setsid();
        const src = linux.open(slave_path, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(src) != .SUCCESS) linux.exit(127);
        const slave: linux.fd_t = @intCast(src);
        _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);
        _ = linux.dup2(slave, 0);
        _ = linux.dup2(slave, 1);
        _ = linux.dup2(slave, 2);
        if (slave > 2) _ = linux.close(slave);
        _ = linux.execve(c_argv[0].?, c_argv.ptr, c_env.ptr);
        linux.exit(127);
    }
    pty.pid = @intCast(pid_rc);
    return pty;
}
