//! cl: launch and manage Claude Code sessions in tmux.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const ui = @import("ui.zig");
const operator = @import("operator.zig");
const history = @import("history.zig");
const web = @import("web.zig");
const window = @import("window.zig");
const board = @import("board.zig");
const ticket_cli = @import("ticket_cli.zig");
const actions = @import("actions.zig");
const alerts = @import("alerts.zig");

pub const panic = @import("vaxis").panic_handler;
pub const std_options: std.Options = .{ .log_level = .warn };

const usage =
    \\cl: Claude Code sessions in tmux
    \\
    \\  cl [options] [dir]        launch claude in dir (default: cwd) and attach
    \\  cl list | ls              interactive chooser (--plain / --json for scripts)
    \\  cl attach <name>          attach to a session (Ctrl-Q detaches)
    \\  cl kill <name>            kill a session
    \\  cl hide | unhide <name>   hide a running session from the chooser (h), or show it again
    \\  cl send <name> <text>     type text + Enter into a session
    \\  cl output <name> [lines]  status, latest reply, and pane tail (default 40 lines)
    \\  cl watch                  print a line whenever a session's status changes
    \\  cl closed                 closed sessions, most recently closed first (R in the chooser)
    \\  cl operator               attach to the operator session (o in the chooser)
    \\  cl alert <text> | --clear  alert the human from this session (the operator's outside one):
    \\                            the chooser and the web board's Needs You show it
    \\  cl say <text>             the operator's short spoken answer to a voice message (voice.*)
    \\  cl web                    serve the chooser to a browser (see web.* in the config)
    \\  cl web password | start | stop
    \\                            set the web password, or run the server in the background
    \\  cl window [install]       the web UI in its own desktop window (install: app launcher entry)
    \\  cl board                  the ticket board in the terminal (b in the chooser)
    \\  cl ticket | t <command>   the ticket board (cl ticket for the commands)
    \\  cl project <command>      projects tickets belong to (cl project for the commands)
    \\
    \\options for launch:
    \\  -p, --profile <name>      profile from ~/.config/cl/config
    \\  -n, --name <name>         session name (default: basename of dir)
    \\  -m, --message <text>      send an initial prompt once claude is ready
    \\  -r, --resume [id]         resume a claude session (claude -r)
    \\  -c, --continue            continue the last claude session in dir (claude -c)
    \\  -d, --detach              create the session without attaching
    \\  -- <args...>              remaining args are passed to claude verbatim
    \\
;

const launch = @import("launch.zig");
const voice = @import("voice.zig");
pub const LaunchOptions = launch.Options;

pub fn main(init: std.process.Init) !void {
    var ctx = Ctx.init(init);
    var args_it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args_it.next(); // argv[0]
    var args: std.ArrayList([]const u8) = .empty;
    while (args_it.next()) |a| try args.append(ctx.perm, a);
    const argv = args.items;

    const cfg = try config.load(ctx);
    try tmux.configure(&ctx, cfg);

    // In a sandbox with no tmux socket, only the board's commands (which
    // mostly don't need tmux; those that do fail at tmux.run) and help run.
    const cmd0 = if (argv.len > 0) argv[0] else "";
    const tmux_free = for ([_][]const u8{ "ticket", "t", "project", "help", "-h", "--help" }) |c| {
        if (std.mem.eql(u8, cmd0, c)) break true;
    } else false;
    if (!tmux_free) tmux.requireServer(ctx);

    if (argv.len > 0) {
        const cmd = argv[0];
        if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) return cmdList(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "attach")) return cmdAttach(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "kill")) return cmdKill(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "hide")) return cmdHide(ctx, argv[1..], true);
        if (std.mem.eql(u8, cmd, "unhide")) return cmdHide(ctx, argv[1..], false);
        if (std.mem.eql(u8, cmd, "send")) return cmdSend(ctx, argv[1..]);
        if (std.mem.eql(u8, cmd, "output")) return cmdOutput(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "watch")) return cmdWatch(ctx, cfg);
        if (std.mem.eql(u8, cmd, "closed")) return cmdClosed(ctx, cfg);
        if (std.mem.eql(u8, cmd, "operator")) return cmdOperator(ctx, cfg);
        if (std.mem.eql(u8, cmd, "board")) return cmdBoard(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "alert")) return cmdAlert(ctx, argv[1..]);
        if (std.mem.eql(u8, cmd, "say")) return cmdSay(ctx, argv[1..]);
        if (std.mem.eql(u8, cmd, "web")) return web.main(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "window")) return window.main(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "ticket") or std.mem.eql(u8, cmd, "t")) return ticket_cli.ticketMain(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "project")) return ticket_cli.projectMain(ctx, cfg, argv[1..]);
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return out(usage);
    }
    const opts = parseLaunch(argv) catch {
        try out(usage);
        std.process.exit(2);
    };
    const tty = std.Io.File.stdin().isTty(ctx.io) catch false;
    switch (launchMode(argv.len, opts.detach, tty)) {
        .launch => {},
        .usage => return out(usage),
        .no_terminal => fail("no terminal to attach the new session to; add -d to start it in the background", .{}),
    }
    try cmdLaunch(ctx, cfg, opts);
}

/// What the launch fallback does. Without a terminal there is nothing to
/// attach to, so starting a session would only leave it behind: a bare `cl`
/// (what agents run to read the help) prints the help instead, and a launch
/// that would attach is refused before it starts anything. The operator
/// running bare `cl` in its own folder left untagged "operator" sessions
/// that other sessions then messaged instead of it.
const LaunchMode = enum { launch, usage, no_terminal };

fn launchMode(argc: usize, detach: bool, tty: bool) LaunchMode {
    if (detach or tty) return .launch;
    return if (argc == 0) .usage else .no_terminal;
}

test launchMode {
    try std.testing.expectEqual(LaunchMode.usage, launchMode(0, false, false));
    try std.testing.expectEqual(LaunchMode.no_terminal, launchMode(1, false, false));
    try std.testing.expectEqual(LaunchMode.launch, launchMode(2, true, false));
    try std.testing.expectEqual(LaunchMode.launch, launchMode(0, false, true));
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

fn parseLaunch(argv: []const []const u8) !LaunchOptions {
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
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= argv.len) return error.BadArgs;
            o.profile = argv[i];
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
    autostartWeb(ctx, cfg);
    var fresh = false;
    var opts = o;
    opts.started_fresh = &fresh;
    const tmux_name = launch.create(ctx, cfg, opts) catch |err| switch (err) {
        error.NoSuchDir => fail("no such directory: {s}", .{o.dir orelse "."}),
        error.NoSuchProfile => fail("no such profile: {s}", .{o.profile orelse ""}),
        error.OperatorReserved => fail("that folder and the name \"operator\" belong to the operator; run `cl operator` to open it, or pick another name with -n", .{}),
        error.PromptTimeout => fail("claude never showed a prompt; message not sent", .{}),
        else => return err,
    };
    if (fresh) std.Io.File.stderr().writeStreamingAll(ctx.io, "cl: no transcript left to resume (Claude deleted it); started a new session\n") catch {};
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
    if (!plain and !json) {
        autostartWeb(ctx, cfg);
        return ui.run(ctx, cfg, null);
    }

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
            try w.print("{{\"name\":{f},\"tmux\":{f},\"dir\":{f},\"profile\":{f},\"status\":\"{s}\",\"created\":{d},\"hidden\":{}}}", .{
                std.json.fmt(s.name, .{}), std.json.fmt(s.tmux_name, .{}), std.json.fmt(s.dir, .{}),
                std.json.fmt(s.profile, .{}), st.label(), s.created, s.hidden,
            });
        } else {
            const short = try ctx.shortenHome(s.dir);
            defer ctx.gpa.free(short);
            // A sixth column, "hidden", only for hidden sessions.
            try w.print("{s}\t{s}\t{s}\t{s}\t{s}{s}\n", .{ s.name, s.profile, short, st.label(), s.tmux_name, if (s.hidden) "\thidden" else "" });
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
    autostartWeb(ctx, cfg);
    try tmux.attach(ctx, s.tmux_name);
    try ui.run(ctx, cfg, s.tmux_name);
}

fn cmdKill(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len != 1) fail("usage: cl kill <name>", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.find(ctx, arena_state.allocator(), argv[0])) orelse fail("no session named {s}", .{argv[0]});
    try tmux.kill(ctx, s.tmux_name);
    actions.sessionKilled(ctx, cfg, s.tmux_name);
}

fn cmdHide(ctx: Ctx, argv: []const []const u8, hidden: bool) !void {
    if (argv.len != 1) fail("usage: cl {s} <name>", .{if (hidden) "hide" else "unhide"});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.find(ctx, arena_state.allocator(), argv[0])) orelse fail("no session named {s}", .{argv[0]});
    try tmux.setHidden(ctx, s.tmux_name, hidden);
}

fn cmdSend(ctx: Ctx, argv: []const []const u8) !void {
    if (argv.len != 2) fail("usage: cl send <name> <text>", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.find(ctx, arena_state.allocator(), argv[0])) orelse fail("no session named {s}", .{argv[0]});
    try tmux.sendLine(ctx, s.tmux_name, argv[1]);
}

fn cmdOutput(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len < 1 or argv.len > 2) fail("usage: cl output <name> [lines]", .{});
    const lines = if (argv.len == 2) std.fmt.parseInt(usize, argv[1], 10) catch fail("not a line count: {s}", .{argv[1]}) else 40;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try tmux.find(ctx, arena, argv[0])) orelse fail("no session named {s}", .{argv[0]});
    const statuses = try claude.readStatuses(ctx, arena, cfg);
    const reply = if (statuses.get(s.tmux_name)) |info| info.summary else "";
    const pane = try tmux.capturePlainLines(ctx, s.tmux_name, lines);
    defer ctx.gpa.free(pane);
    try out(try std.fmt.allocPrint(arena, "status: {s}\nlatest reply: {s}\n--- pane ---\n{s}\n", .{
        claude.statusFor(ctx, statuses, s).label(), reply, std.mem.trimEnd(u8, pane, "\n"),
    }));
}

/// Poll every two seconds and print `<name> <old> -> <new>` on each change,
/// plus `<name> new <status>` and `<name> ended` as sessions come and go.
/// Hidden sessions are tracked but stay quiet: hiding means "not now".
fn cmdWatch(ctx: Ctx, cfg: config.Config) !void {
    var prev = std.heap.ArenaAllocator.init(ctx.gpa);
    defer prev.deinit();
    var last: std.StringHashMapUnmanaged(claude.Status) = .empty;
    var last_hidden: std.StringHashMapUnmanaged(void) = .empty;
    var first = true;
    while (true) : (ctx.sleepMs(2000)) {
        var cur = std.heap.ArenaAllocator.init(ctx.gpa);
        const arena = cur.allocator();
        const sessions = try tmux.list(ctx, arena);
        const statuses = try claude.readStatuses(ctx, arena, cfg);
        var now: std.StringHashMapUnmanaged(claude.Status) = .empty;
        var now_hidden: std.StringHashMapUnmanaged(void) = .empty;
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (sessions) |s| {
            const st = claude.statusFor(ctx, statuses, s);
            try now.put(arena, s.tmux_name, st);
            if (s.hidden) try now_hidden.put(arena, s.tmux_name, {});
            if (first or s.hidden) continue;
            if (last.get(s.tmux_name)) |old| {
                if (old != st) try aw.writer.print("{s} {s} -> {s}\n", .{ s.name, old.label(), st.label() });
            } else try aw.writer.print("{s} new {s}\n", .{ s.name, st.label() });
        }
        if (!first) {
            var it = last.iterator();
            while (it.next()) |e| if (!now.contains(e.key_ptr.*) and !last_hidden.contains(e.key_ptr.*)) {
                try aw.writer.print("{s} ended\n", .{nameFromTmux(e.key_ptr.*)});
            };
        }
        if (aw.writer.buffered().len > 0) try out(aw.writer.buffered());
        first = false;
        // Keep this tick's map; free the one before it.
        prev.deinit();
        prev = cur;
        last = now;
        last_hidden = now_hidden;
    }
}

/// cl_<name>_<id> -> <name> (sanitized; the real name is gone with the session).
fn nameFromTmux(tmux_name: []const u8) []const u8 {
    const rest = tmux_name[@min(tmux.prefix.len, tmux_name.len)..];
    const us = std.mem.lastIndexOfScalar(u8, rest, '_') orelse return rest;
    return rest[0..us];
}

/// One tab-separated line per closed session: name, profile, dir, closed (unix s), session id, reply.
fn cmdClosed(ctx: Ctx, cfg: config.Config) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sessions = try tmux.list(ctx, arena);
    const statuses = try claude.readStatuses(ctx, arena, cfg);
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (try history.closed(ctx, arena, cfg, sessions, statuses)) |c| {
        try aw.writer.print("{s}\t{s}\t{s}\t{d}\t{s}\t{s}\n", .{
            c.entry.name, c.entry.profile, c.entry.dir, c.closed, c.entry.session_id, c.reply[0..@min(c.reply.len, 200)],
        });
    }
    try out(aw.writer.buffered());
}

/// Raise (or clear) the alert of the session this runs in: the operator's when
/// run outside any cl session. In a ticket's session it is about $CL_TICKET.
fn cmdAlert(ctx: Ctx, argv: []const []const u8) !void {
    if (argv.len != 1) fail("usage: cl alert <text> | --clear", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const caller = try tmux.callerSession(ctx, a);
    const target = caller orelse (try tmux.operator(ctx, a)) orelse fail("the operator is not running", .{});
    const text = try alerts.oneLine(a, argv[0]);
    if (std.mem.eql(u8, argv[0], "--clear") or text.len == 0) return tmux.clearAlert(ctx, target.tmux_name);
    const ticket = if (caller != null) ctx.env.get("CL_TICKET") orelse "" else "";
    try tmux.setAlert(ctx, target.tmux_name, text, ticket);
}

fn cmdSay(ctx: Ctx, argv: []const []const u8) !void {
    if (argv.len != 1 or std.mem.trim(u8, argv[0], " \n").len == 0) fail("usage: cl say <text>", .{});
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const op = (try tmux.operator(ctx, a)) orelse fail("the operator is not running", .{});
    try voice.say(ctx, a, op.tmux_name, argv[0]);
}

/// With web.autostart, make sure `cl web` is running in the background.
fn autostartWeb(ctx: Ctx, cfg: config.Config) void {
    web.start(ctx, cfg, false) catch {};
}

fn cmdBoard(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len != 0) fail("usage: cl board", .{});
    autostartWeb(ctx, cfg);
    try ui.runBoard(ctx, cfg);
}

fn cmdOperator(ctx: Ctx, cfg: config.Config) !void {
    autostartWeb(ctx, cfg);
    const tmux_name = operator.ensure(ctx, cfg) catch |err| switch (err) {
        error.NoSuchProfile => fail("operator profile not found: {s}", .{cfg.operator}),
        else => return err,
    };
    try tmux.attach(ctx, tmux_name); // which clears its alert
    try ui.run(ctx, cfg, null);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(board);
    std.testing.refAllDecls(@import("db.zig"));
    std.testing.refAllDecls(ticket_cli);
    std.testing.refAllDecls(@import("dispatch.zig"));
    std.testing.refAllDecls(@import("worktree.zig"));
    std.testing.refAllDecls(@import("signals.zig"));
    std.testing.refAllDecls(@import("actions.zig"));
    std.testing.refAllDecls(@import("review.zig"));
    std.testing.refAllDecls(@import("autoreview.zig"));
    std.testing.refAllDecls(Ctx);
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(@import("web_board.zig"));
    std.testing.refAllDecls(operator);
    std.testing.refAllDecls(voice);
    std.testing.refAllDecls(@import("after_merge.zig"));
    std.testing.refAllDecls(@import("park.zig"));
    std.testing.refAllDecls(@import("ticket_watch.zig"));
    std.testing.refAllDecls(@import("board_view.zig"));
    std.testing.refAllDecls(@import("images.zig"));
    std.testing.refAllDecls(alerts);
}
