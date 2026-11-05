//! `cl window`: the web UI (board, terminals, chat) in its own desktop window.
//!
//! Starts `cl web` if nothing answers on its port, then opens cl-window (a
//! GTK 4 + WebKitGTK window built next to cl when webkitgtk-6.0 is installed;
//! see src/window/cl-window.c). Without cl-window it falls back to a
//! Chromium-family browser in app mode, then to the default browser, where
//! the browser keeps some shortcuts (Ctrl+W, Ctrl+T) for itself.
//!
//! The window runs on its own, outside cl web's tmux session, so closing it
//! leaves the server and every session running.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const web = @import("web.zig");

/// GTK application id: the .desktop file and icon are named after it, which
/// is how Wayland compositors find the window's icon.
pub const app_id = "io.github.jself.cl";
const icon_svg = @embedFile("window/cl.svg");
const app_mode_browsers = [_][]const u8{ "chromium", "google-chrome-stable", "google-chrome", "brave", "vivaldi-stable", "microsoft-edge-stable" };

pub fn main(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len > 0) {
        if (std.mem.eql(u8, argv[0], "install")) return install(ctx);
        fail("usage: cl window [install]", .{});
    }
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ip_buf: [64]u8 = undefined;
    const addr = pickAddr(cfg.web.listen) orelse fail("web.listen has no address to open", .{});
    const host = if (std.mem.eql(u8, addr.host, "tailscale"))
        web.tailscaleIp(ctx, &ip_buf) catch fail("web.listen only has tailscale, and tailscale has no IPv4", .{})
    else
        addr.host;
    const ip = std.Io.net.IpAddress.parse(host, addr.port) catch fail("bad host in web.listen: {s}", .{host});
    try ensureServer(ctx, cfg, ip);

    const url = try std.fmt.allocPrint(arena, "http://{f}/board", .{ip});
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];
    const helper = try std.fs.path.join(arena, &.{ std.fs.path.dirname(exe).?, "cl-window" });
    const log = try statePath(ctx, arena, "window.log");
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(log).?);

    if (std.Io.Dir.cwd().access(ctx.io, helper, .{})) |_| {
        const data = try dataPath(ctx, arena, "window");
        // setsid -f: the window outlives this command and the terminal it ran in.
        try detach(ctx, &.{ "sh", "-c", "log=$1; shift; exec setsid -f \"$@\" </dev/null >>\"$log\" 2>&1", "sh", log, helper, url, data });
        return;
    } else |_| {}

    say("cl: no cl-window next to {s} (built when webkitgtk-6.0 is installed); using a browser window, which keeps some shortcuts like Ctrl+W", .{exe});
    var script: std.ArrayList(u8) = .empty;
    try script.appendSlice(arena, "url=$1; log=$2; for b in");
    for (app_mode_browsers) |b| try script.print(arena, " {s}", .{b});
    try script.print(arena, "; do command -v \"$b\" >/dev/null && exec setsid -f \"$b\" --app=\"$url\" --class={s} </dev/null >>\"$log\" 2>&1; done; exec setsid -f xdg-open \"$url\" </dev/null >>\"$log\" 2>&1", .{app_id});
    try detach(ctx, &.{ "sh", "-c", script.items, "sh", url, log });
}

const Addr = struct { host: []const u8, port: u16 };

/// The web.listen address the window should open: the first loopback or
/// all-interfaces entry (as 127.0.0.1), or else the first entry.
fn pickAddr(listen: []const u8) ?Addr {
    var first: ?Addr = null;
    var it = std.mem.splitScalar(u8, listen, ',');
    while (it.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse continue;
        const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch continue;
        const host = std.mem.trim(u8, text[0..colon], "[]");
        for ([_][]const u8{ "127.0.0.1", "localhost", "0.0.0.0", "::", "::1" }) |local| {
            if (std.mem.eql(u8, host, local)) return .{ .host = if (std.mem.eql(u8, host, "::1")) "::1" else "127.0.0.1", .port = port };
        }
        if (first == null) first = .{ .host = host, .port = port };
    }
    return first;
}

/// Start `cl web` unless something already answers at `ip`, and wait for it.
fn ensureServer(ctx: Ctx, cfg: config.Config, ip: std.Io.net.IpAddress) !void {
    if (answers(ctx, ip)) return;
    try web.start(ctx, cfg, true);
    // The tmux loop restarts a stopped server after 10 s, so wait past that.
    var waited: i64 = 0;
    while (waited < 15_000) : (waited += 250) {
        if (answers(ctx, ip)) return;
        ctx.sleepMs(250);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const log = web.logPath(ctx, fba.allocator(), cfg) catch "the web log";
    fail("cl web is not answering on {f}; see {s}", .{ ip, log });
}

fn answers(ctx: Ctx, ip: std.Io.net.IpAddress) bool {
    const s = ip.connect(ctx.io, .{ .mode = .stream }) catch return false;
    s.close(ctx.io);
    return true;
}

fn detach(ctx: Ctx, argv: []const []const u8) !void {
    const r = try std.process.run(ctx.gpa, ctx.io, .{ .argv = argv });
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) fail("could not open the window: {s}", .{std.mem.trim(u8, r.stderr, "\n")});
}

/// Write the app launcher entry and icon for the current user.
fn install(ctx: Ctx) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];

    const desktop = try dataPath(ctx, arena, "../applications/" ++ app_id ++ ".desktop");
    const icon = try dataPath(ctx, arena, "../icons/hicolor/scalable/apps/" ++ app_id ++ ".svg");
    const entry = try desktopEntry(arena, exe);
    const cwd = std.Io.Dir.cwd();
    for ([_][2][]const u8{ .{ desktop, entry }, .{ icon, icon_svg } }) |f| {
        try cwd.createDirPath(ctx.io, std.fs.path.dirname(f[0]).?);
        try cwd.writeFile(ctx.io, .{ .sub_path = f[0], .data = f[1] });
        say("wrote {s}", .{f[0]});
    }
}

fn desktopEntry(alloc: std.mem.Allocator, exe: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=cl
        \\GenericName=Claude Code board
        \\Comment=The cl board and session terminals in their own window
        \\Exec="{s}" window
        \\Icon={s}
        \\Terminal=false
        \\Categories=Development;
        \\StartupWMClass={s}
        \\StartupNotify=true
        \\
    , .{ exe, app_id, app_id });
}

/// $XDG_DATA_HOME/cl/<name>, default ~/.local/share/cl/<name>.
fn dataPath(ctx: Ctx, alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const base = if (ctx.env.get("XDG_DATA_HOME")) |d| (if (d.len > 0) d else null) else null;
    const path = if (base) |d|
        try std.fmt.allocPrint(alloc, "{s}/cl/{s}", .{ d, name })
    else
        try std.fmt.allocPrint(alloc, "{s}/.local/share/cl/{s}", .{ ctx.home, name });
    return std.fs.path.resolve(alloc, &.{path});
}

/// $XDG_STATE_HOME/cl/<name>, default ~/.local/state/cl/<name> (as web.log).
fn statePath(ctx: Ctx, alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (ctx.env.get("XDG_STATE_HOME")) |d| if (d.len > 0) return std.fmt.allocPrint(alloc, "{s}/cl/{s}", .{ d, name });
    return std.fmt.allocPrint(alloc, "{s}/.local/state/cl/{s}", .{ ctx.home, name });
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}

/// Started from the app launcher there is no terminal to read an error in,
/// so show it as a desktop notification too.
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "error";
    say("cl: {s}", .{msg});
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.process.run(std.heap.page_allocator, io, .{ .argv = &.{ "notify-send", "--app-name=cl", "-i", app_id, "cl window", msg } })) |r| {
        std.heap.page_allocator.free(r.stdout);
        std.heap.page_allocator.free(r.stderr);
    } else |_| {}
    std.process.exit(1);
}

test pickAddr {
    const eq = std.testing.expectEqualDeep;
    try eq(Addr{ .host = "127.0.0.1", .port = 8421 }, pickAddr("127.0.0.1:8421").?);
    try eq(Addr{ .host = "127.0.0.1", .port = 8421 }, pickAddr("tailscale:8421, 127.0.0.1:8421").?);
    try eq(Addr{ .host = "127.0.0.1", .port = 9000 }, pickAddr("0.0.0.0:9000").?);
    try eq(Addr{ .host = "tailscale", .port = 8421 }, pickAddr("tailscale:8421").?);
    try eq(Addr{ .host = "::1", .port = 8421 }, pickAddr("[::1]:8421").?);
    try std.testing.expect(pickAddr("") == null);
}

test desktopEntry {
    const e = try desktopEntry(std.testing.allocator, "/home/me/.local/bin/cl");
    defer std.testing.allocator.free(e);
    try std.testing.expect(std.mem.indexOf(u8, e, "Exec=\"/home/me/.local/bin/cl\" window\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "StartupWMClass=" ++ app_id ++ "\n") != null);
}
