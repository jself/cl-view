//! cl: launch and manage Claude Code sessions in tmux.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const ui = @import("ui.zig");

pub const panic = @import("vaxis").panic_handler;
pub const std_options: std.Options = .{ .log_level = .warn };

const usage =
    \\cl: Claude Code sessions in tmux
    \\
    \\  cl [options] [dir]        launch claude in dir (default: cwd) and attach
    \\  cl list | ls              interactive chooser (--plain / --json for scripts)
    \\  cl attach <name>          attach to a session (Ctrl-Q detaches)
    \\  cl kill <name>            kill a session
    \\  cl send <name> <text>     type text + Enter into a session
    \\
    \\options for launch:
    \\  --<profile>               choose profile from ~/.config/cl/config (e.g. --work, --personal)
    \\  -n, --name <name>         session name (default: basename of dir)
    \\  -m, --message <text>      send an initial prompt once claude is ready
    \\  -r, --resume [id]         resume a claude session (claude -r)
    \\  -c, --continue            continue the last claude session in dir (claude -c)
    \\  -d, --detach              create the session without attaching
    \\  -- <args...>              remaining args are passed to claude verbatim
    \\
;

const launch = @import("launch.zig");
pub const LaunchOptions = launch.Options;

pub fn main(init: std.process.Init) !void {
    const ctx = Ctx.init(init);
    var args_it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args_it.next(); // argv[0]
    var args: std.ArrayList([]const u8) = .empty;
    while (args_it.next()) |a| try args.append(ctx.perm, a);
    const argv = args.items;

    const cfg = try config.load(ctx);

    if (argv.len > 0) {
        const cmd = argv[0];
        if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) return cmdList(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "attach")) return cmdAttach(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "kill")) return cmdKill(ctx, argv[1..]);
        if (std.mem.eql(u8, cmd, "send")) return cmdSend(ctx, argv[1..]);
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return out(usage);
    }
    const opts = parseLaunch(cfg, argv) catch {
        try out(usage);
        std.process.exit(2);
    };
    try cmdLaunch(ctx, cfg, opts);
}

fn out(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), text);
}

fn fail(comptime fmt: []const u8, a: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cl: " ++ fmt ++ "\n", a) catch "cl: error\n";
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
    std.process.exit(1);
}

fn parseLaunch(cfg: config.Config, argv: []const []const u8) !LaunchOptions {
    var o: LaunchOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            o.extra = argv[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= argv.len) return error.BadArgs;
            o.name = argv[i];
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--message")) {
            i += 1;
            if (i >= argv.len) return error.BadArgs;
            o.message = argv[i];
        } else if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--resume")) {
            o.resume_flag = true;
            if (i + 1 < argv.len and argv[i + 1][0] != '-') {
                i += 1;
                o.resume_id = argv[i];
            }
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--continue")) {
            o.continue_flag = true;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--detach")) {
            o.detach = true;
        } else if (std.mem.startsWith(u8, a, "--") and cfg.find(a[2..]) != null) {
            o.profile = a[2..];
        } else if (a[0] == '-') {
            return error.BadArgs;
        } else {
            if (o.dir != null) return error.BadArgs;
            o.dir = a;
        }
    }
    return o;
}

fn cmdLaunch(ctx: Ctx, cfg: config.Config, o: LaunchOptions) !void {
    const tmux_name = launch.create(ctx, cfg, o) catch |err| switch (err) {
        error.NoSuchDir => fail("no such directory: {s}", .{o.dir orelse "."}),
        error.NoSuchProfile => fail("no such profile: {s}", .{o.profile orelse ""}),
        error.PromptTimeout => fail("claude never showed a prompt; message not sent", .{}),
        else => return err,
    };
    if (o.detach) {
        var buf: [256]u8 = undefined;
        return out(try std.fmt.bufPrint(&buf, "{s}\n", .{tmux_name}));
    }
    try tmux.attach(ctx, tmux_name);
    try ui.run(ctx, cfg, tmux_name);
}

fn cmdList(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    const plain = argv.len > 0 and std.mem.eql(u8, argv[0], "--plain");
    const json = argv.len > 0 and std.mem.eql(u8, argv[0], "--json");
    if (!plain and !json) return ui.run(ctx, cfg, null);

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sessions = try tmux.list(ctx, arena);
    const statuses = try claude.readStatuses(ctx, arena, cfg);

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    if (json) try w.writeAll("[");
    for (sessions, 0..) |s, i| {
        const st = claude.statusFor(ctx, statuses, s);
        if (json) {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":{f},\"tmux\":{f},\"dir\":{f},\"profile\":{f},\"status\":\"{s}\",\"created\":{d}}}", .{
                std.json.fmt(s.name, .{}), std.json.fmt(s.tmux_name, .{}), std.json.fmt(s.dir, .{}),
                std.json.fmt(s.profile, .{}), st.label(), s.created,
            });
        } else {
            const short = try ctx.shortenHome(s.dir);
            defer ctx.gpa.free(short);
            try w.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ s.name, s.profile, short, st.label(), s.tmux_name });
        }
    }
    if (json) try w.writeAll("]\n");
    try out(aw.writer.buffered());
}

fn cmdAttach(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len != 1) fail("usage: cl attach <name>", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.find(ctx, arena_state.allocator(), argv[0])) orelse fail("no session named {s}", .{argv[0]});
    try tmux.attach(ctx, s.tmux_name);
    try ui.run(ctx, cfg, s.tmux_name);
}

fn cmdKill(ctx: Ctx, argv: []const []const u8) !void {
    if (argv.len != 1) fail("usage: cl kill <name>", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.find(ctx, arena_state.allocator(), argv[0])) orelse fail("no session named {s}", .{argv[0]});
    try tmux.kill(ctx, s.tmux_name);
}

fn cmdSend(ctx: Ctx, argv: []const []const u8) !void {
    if (argv.len != 2) fail("usage: cl send <name> <text>", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.find(ctx, arena_state.allocator(), argv[0])) orelse fail("no session named {s}", .{argv[0]});
    try tmux.sendLine(ctx, s.tmux_name, argv[1]);
}

test {
    std.testing.refAllDecls(@This());
}
