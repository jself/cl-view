//! `cl web install | uninstall`: run the main `cl web` as a systemd user
//! service, so it starts on boot (README, "Start on boot"). While the unit is
//! installed, `cl web start | stop` and autostart go through systemctl instead
//! of the hidden tmux session.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig");

pub const unit_name = "cl-web.service";

/// Variables of the installing shell copied into the unit, when set: what cl
/// and tmux read, and the editor, which the user manager doesn't have.
/// Anything else (tokens, SSH_AUTH_SOCK) goes in ~/.config/cl/web.env, which
/// the unit reads when it exists (README, "Start on boot"). Not CLAUDE_CONFIG_DIR:
/// the server in tmux doesn't get the shell's either, and sessions would
/// switch to another Claude config.
const pass_env = [_][]const u8{ "CL_TMUX_SOCKET", "TMUX_TMPDIR", "XDG_STATE_HOME", "XDG_DATA_HOME", "LANG", "LC_ALL", "EDITOR", "VISUAL" };

pub const supported = builtin.os.tag == .linux;

/// ~/.config/systemd/user/cl-web.service.
pub fn unitPath(alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/.config/systemd/user/{s}", .{ home, unit_name });
}

/// Whether `cl web install` wrote the unit (and `uninstall` hasn't removed it).
pub fn installed(ctx: Ctx) bool {
    if (!supported) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.config/systemd/user/{s}", .{ ctx.home, unit_name }) catch return false;
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

/// Whether this process runs in cl-web.service (its cgroup, from
/// /proc/self/cgroup, ends in it).
/// Read once: a process doesn't change cgroup.
pub fn inUnit(ctx: Ctx) bool {
    if (!supported) return false;
    const cached = in_unit.load(.monotonic);
    if (cached != 0) return cached == 1;
    var buf: [4096]u8 = undefined;
    const yes = if (std.Io.Dir.cwd().readFile(ctx.io, "/proc/self/cgroup", &buf)) |text| isUnitCgroup(text) else |_| false;
    in_unit.store(if (yes) 1 else 2, .monotonic);
    return yes;
}

/// 0 unknown, 1 in cl-web.service, 2 not.
var in_unit = std.atomic.Value(u8).init(0);

fn isUnitCgroup(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.endsWith(u8, line, "/" ++ unit_name)) return true;
    return false;
}

test isUnitCgroup {
    try std.testing.expect(isUnitCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/cl-web.service\n"));
    try std.testing.expect(!isUnitCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/tmux-spawn-1.scope\n"));
    try std.testing.expect(!isUnitCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/xcl-web.service.d\n"));
}

pub const Unit = struct {
    exe: []const u8,
    home: []const u8,
    log: []const u8,
    path: []const u8,
    /// Extra `NAME=value` pairs (from `pass_env`).
    env: []const []const u8 = &.{},
};

/// The unit file (`alloc` is meant to be an arena). Restart=always with RestartSec=10 is the tmux loop's
/// restart: the after-merge command pkills `cl web` and expects it back.
/// KillMode=process stops only cl web itself, never the tmux server (and
/// every session) when cl web happened to start it.
pub fn unitText(alloc: std.mem.Allocator, u: Unit) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll(
        \\# Written by `cl web install`; `cl web uninstall` removes it.
        \\[Unit]
        \\Description=cl web: the board, web terminals and the dispatcher
        \\StartLimitIntervalSec=0
        \\
        \\[Service]
        \\
    );
    try w.writeAll("ExecStart=");
    try quoted(w, u.exe);
    // WorkingDirectory= and append: take a path as is, without quotes.
    try w.writeAll(" web\nWorkingDirectory=");
    try escaped(w, u.home);
    try w.writeAll("\nEnvironment=");
    try quoted(w, try std.fmt.allocPrint(alloc, "PATH={s}", .{u.path}));
    for (u.env) |kv| {
        try w.writeAll("\nEnvironment=");
        try quoted(w, kv);
    }
    // The user's own additions; `-`: fine when it doesn't exist.
    try w.writeAll("\nEnvironmentFile=-");
    try escaped(w, u.home);
    try w.writeAll("/.config/cl/web.env");
    try w.writeAll("\nStandardOutput=append:");
    try escaped(w, u.log);
    try w.writeAll(
        \\
        \\StandardError=inherit
        \\Restart=always
        \\RestartSec=10
        \\KillMode=process
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    );
    return aw.toOwnedSlice();
}

/// A double-quoted unit-file word: `\` and `"` escaped, `%` doubled (it
/// starts a specifier).
fn quoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try escaped(w, s);
    try w.writeByte('"');
}

/// `%` doubled, and in a quoted word `\` and `"` escaped.
fn escaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\', '"' => try w.print("\\{c}", .{c}),
        '%' => try w.writeAll("%%"),
        else => try w.writeByte(c),
    };
}

test unitText {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try unitText(arena.allocator(), .{
        .exe = "/home/u/.local/bin/cl",
        .home = "/home/u",
        .log = "/home/u/.local/state/cl/web.log",
        .path = "/home/u/.local/bin:/usr/bin",
        .env = &.{"LANG=en_US.UTF-8"},
    });
    // The after-merge command's `pkill -f "^$HOME/.local/bin/cl web$"` matches it.
    try std.testing.expect(std.mem.indexOf(u8, text, "\nExecStart=\"/home/u/.local/bin/cl\" web\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nEnvironment=\"PATH=/home/u/.local/bin:/usr/bin\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nEnvironment=\"LANG=en_US.UTF-8\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nEnvironmentFile=-/home/u/.config/cl/web.env\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nStandardOutput=append:/home/u/.local/state/cl/web.log\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\nRestart=always\nRestartSec=10\nKillMode=process\n") != null);
}

test quoted {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try quoted(&aw.writer, "a \"b\" 50% c\\d");
    try std.testing.expectEqualStrings("\"a \\\"b\\\" 50%% c\\\\d\"", aw.written());
}

/// The unit's PATH: ~/.local/bin and the directory cl runs from first, then
/// the installing shell's PATH (absolute entries only, each once), then the
/// usual system directories in case that PATH lacks them. The user manager's
/// own PATH has no ~/.local/bin, and the tmux server cl web may start at boot
/// (and so every session) inherits this one.
pub fn unitPathVar(alloc: std.mem.Allocator, home: []const u8, exe: []const u8, shell_path: []const u8) ![]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    try addDir(alloc, &dirs, try std.fmt.allocPrint(alloc, "{s}/.local/bin", .{home}));
    if (std.fs.path.dirname(exe)) |d| try addDir(alloc, &dirs, d);
    var it = std.mem.splitScalar(u8, shell_path, ':');
    while (it.next()) |d| try addDir(alloc, &dirs, d);
    for ([_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" }) |d| try addDir(alloc, &dirs, d);
    return std.mem.join(alloc, ":", dirs.items);
}

fn addDir(alloc: std.mem.Allocator, dirs: *std.ArrayList([]const u8), dir: []const u8) !void {
    const d = if (dir.len > 1) std.mem.trimEnd(u8, dir, "/") else dir;
    if (d.len == 0 or d[0] != '/') return;
    for (dirs.items) |x| if (std.mem.eql(u8, x, d)) return;
    try dirs.append(alloc, d);
}

test unitPathVar {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "/home/u/.local/bin:/usr/bin:/opt/x/bin:/usr/local/bin:/bin",
        try unitPathVar(a, "/home/u", "/home/u/.local/bin/cl", "/usr/bin:.:/home/u/.local/bin/:/opt/x/bin::rel/bin"),
    );
    try std.testing.expectEqualStrings(
        "/home/u/.local/bin:/w/zig-out/bin:/usr/local/bin:/usr/bin:/bin",
        try unitPathVar(a, "/home/u", "/w/zig-out/bin/cl", ""),
    );
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    say("cl: " ++ fmt, args);
    std.process.exit(1);
}

/// Run a command; on failure, the first line of what it said (or why it
/// didn't run) in `err`.
fn run(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8, err: *[]const u8) bool {
    const res = std.process.run(a, ctx.io, .{ .argv = argv }) catch |e| {
        err.* = std.fmt.allocPrint(a, "{s}: {s}", .{ argv[0], @errorName(e) }) catch argv[0];
        return false;
    };
    if (res.term == .exited and res.term.exited == 0) return true;
    const out = std.mem.trim(u8, if (res.stderr.len > 0) res.stderr else res.stdout, " \n");
    err.* = if (out.len > 0) out else std.fmt.allocPrint(a, "{s} failed", .{argv[0]}) catch argv[0];
    return false;
}

fn systemctl(ctx: Ctx, a: std.mem.Allocator, args: []const []const u8, err: *[]const u8) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "systemctl", "--user" }) catch return false;
    argv.appendSlice(a, args) catch return false;
    return run(ctx, a, argv.items, err);
}

/// Write the unit, enable it, and (re)start it, so it also picks up a
/// reinstall. The caller has stopped the tmux one already, and starts it
/// again on error.InstallFailed (said why, and removed the unit).
pub fn install(ctx: Ctx, a: std.mem.Allocator, exe: []const u8, log: []const u8) !void {
    var err: []const u8 = "";
    if (!supported or !systemctl(ctx, a, &.{"--version"}, &err)) {
        say("cl: cl web install sets up a systemd user service, and systemctl --user doesn't work here: {s}", .{if (supported) err else "not Linux"});
        return error.InstallFailed;
    }

    var env: std.ArrayList([]const u8) = .empty;
    for (pass_env) |name| if (ctx.env.get(name)) |v| if (v.len > 0)
        try env.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, v }));
    const path_var = try unitPathVar(a, ctx.home, exe, ctx.env.get("PATH") orelse "");
    const text = try unitText(a, .{ .exe = exe, .home = ctx.home, .log = log, .path = path_var, .env = env.items });
    const path = try unitPath(a, ctx.home);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(log).?);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = text });
    say("wrote {s}: it runs {s} web, logs to {s}, and starts it again 10s after it exits", .{ path, exe, log });

    // A unit cl can't run must not stay, or `cl web start` and autostart
    // would keep handing the server to it.
    if (!systemctl(ctx, a, &.{"daemon-reload"}, &err) or
        !systemctl(ctx, a, &.{ "enable", unit_name }, &err) or
        !systemctl(ctx, a, &.{ "restart", unit_name }, &err))
    {
        const why = err;
        // Also drops default.target.wants/ if enable got that far.
        _ = systemctl(ctx, a, &.{ "disable", unit_name }, &err);
        std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
        _ = systemctl(ctx, a, &.{"daemon-reload"}, &err);
        say("cl: systemctl --user failed, so the unit is removed again: {s}", .{why});
        return error.InstallFailed;
    }
    say("enabled and started {s}: the user's systemd starts it at login (systemctl --user status {s})", .{ unit_name, unit_name });
    say("its PATH: {s}", .{path_var});

    linger(ctx, a);
}

/// The user's systemd only runs from boot, without anyone logged in, with
/// lingering on: /var/lib/systemd/linger/<user>.
fn linger(ctx: Ctx, a: std.mem.Allocator) void {
    const user = ctx.env.get("USER") orelse ctx.env.get("LOGNAME") orelse "";
    if (user.len > 0) {
        const flag = std.fmt.allocPrint(a, "/var/lib/systemd/linger/{s}", .{user}) catch return;
        if (std.Io.Dir.cwd().access(ctx.io, flag, .{})) |_| {
            say("lingering is already on for {s}, so it starts at boot, before anyone logs in", .{user});
            return;
        } else |_| {}
    }
    var err: []const u8 = "";
    if (run(ctx, a, &.{ "loginctl", "enable-linger" }, &err)) {
        say("turned on lingering (loginctl enable-linger): your systemd user services, this one included, now start at boot without a login and keep running after you log out; `loginctl disable-linger` turns it off", .{});
    } else {
        say("lingering is off, so it starts when you log in, not at boot. To start it at boot, run `sudo loginctl enable-linger {s}` (your user services then start at boot and keep running after logout). loginctl said: {s}", .{ if (user.len > 0) user else "$USER", err });
    }
}

/// Stop, disable and remove the unit. Lingering stays as it is: other user
/// services may count on it.
pub fn uninstall(ctx: Ctx, a: std.mem.Allocator) !void {
    if (!supported or !installed(ctx)) fail("cl web is not installed as a service (cl web install)", .{});
    var err: []const u8 = "";
    // Keep the unit when the service may still run: removing it and then
    // starting a tmux one would make two main servers (two dispatchers).
    if (!systemctl(ctx, a, &.{ "disable", "--now", unit_name }, &err))
        fail("systemctl --user disable --now {s} failed, so the unit stays; run that yourself, then cl web uninstall again: {s}", .{ unit_name, err });
    const path = try unitPath(a, ctx.home);
    try std.Io.Dir.cwd().deleteFile(ctx.io, path);
    _ = systemctl(ctx, a, &.{"daemon-reload"}, &err);
    say("stopped and removed {s} ({s}). Lingering is left as it was (`loginctl disable-linger` turns it off)", .{ unit_name, path });
}

/// `systemctl --user start` (a no-op while it runs) or `stop`; on failure,
/// what systemctl said is in `err` (allocated with `a`).
pub fn control(ctx: Ctx, a: std.mem.Allocator, verb: enum { start, stop }, err: *[]const u8) bool {
    return systemctl(ctx, a, &.{ @tagName(verb), unit_name }, err);
}
