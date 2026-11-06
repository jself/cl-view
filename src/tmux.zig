//! All tmux interaction. tmux is the session store: every cl session is a tmux
//! session named `cl_<name>_<id>` carrying @cl_* user options.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");

pub const prefix = "cl_";

pub const Session = struct {
    /// Full tmux session name (cl_<name>_<id>).
    tmux_name: []const u8,
    name: []const u8,
    dir: []const u8,
    profile: []const u8,
    created: i64,
    pane_title: []const u8,
    pane_dead: bool,
    activity: i64,
    /// "operator" or "web" for cl's own hidden sessions, "" for Claude sessions.
    role: []const u8,
    /// The operator's pending alert for the human (@cl_alert), "" if none.
    alert: []const u8,
    /// Hidden from the chooser (h) while it keeps running (@cl_hidden).
    hidden: bool = false,
};

pub const operator_role = "operator";
pub const web_role = "web";

pub const Error = error{ TmuxFailed, NoTmuxSocket };

pub const socket_env = "CL_TMUX_SOCKET";

/// Which tmux server cl talks to, decided once at startup.
pub const Server = struct {
    /// `tmux -S` on every call; null for tmux's default server.
    socket: ?[]const u8,
    /// A sandbox with no socket: cl runs no tmux at all.
    blocked: bool,
};

/// CL_TMUX_SOCKET (`env_socket`) wins over tmux.socket (`cfg_socket`); either
/// must be an absolute path short enough for a Unix socket. With neither, cl uses tmux's default server,
/// unless HOME isn't the user's home from the passwd database (`real_home`):
/// then cl is running in a sandbox, whose default server is very likely the
/// real one (a sandbox's TMUX_TMPDIR that doesn't exist yet falls back to
/// /tmp), so it is blocked. `real_home` null (no passwd entry) can't tell, so
/// doesn't block.
pub fn decide(env_socket: ?[]const u8, cfg_socket: []const u8, home: []const u8, real_home: ?[]const u8) error{ RelativeSocket, SocketPathTooLong }!Server {
    const sock: ?[]const u8 = if (env_socket) |e| (if (e.len > 0) e else null) else null;
    if (sock orelse (if (cfg_socket.len > 0) cfg_socket else null)) |p| {
        if (!std.fs.path.isAbsolute(p)) return error.RelativeSocket;
        // sockaddr_un's sun_path; tmux would only say so on stderr, which cl drops.
        if (p.len >= 104) return error.SocketPathTooLong;
        return .{ .socket = p, .blocked = false };
    }
    const real = real_home orelse return .{ .socket = null, .blocked = false };
    const same = std.mem.eql(u8, std.mem.trimEnd(u8, home, "/"), std.mem.trimEnd(u8, real, "/"));
    return .{ .socket = null, .blocked = !same };
}

/// The user's home directory from the passwd database, not $HOME.
fn realHome() ?[]const u8 {
    const pw = std.c.getpwuid(std.c.getuid()) orelse return null;
    const dir = pw.dir orelse return null;
    return std.mem.sliceTo(dir, 0);
}

/// Pick the tmux server for this process (see `decide`) and record it in
/// `ctx`. A socket is also put in the environment as CL_TMUX_SOCKET, so the
/// processes cl starts (web terminals' `cl list`, `cl web` itself) use it too;
/// `newSession` passes it into every session for the same reason.
pub fn configure(ctx: *Ctx, cfg: config.Config) !void {
    const server = decide(ctx.env.get(socket_env), cfg.tmux.socket, ctx.home, realHome()) catch |err| {
        std.debug.print("cl: the tmux socket ({s} or tmux.socket) must be {s}\n", .{ socket_env, switch (err) {
            error.RelativeSocket => "an absolute path",
            error.SocketPathTooLong => "shorter than 104 bytes (a Unix socket path)",
        } });
        std.process.exit(1);
    };
    // A copy: the socket may be the environment's own value, which `put` frees.
    ctx.tmux_socket = if (server.socket) |p| try ctx.perm.dupe(u8, p) else null;
    ctx.tmux_blocked = server.blocked;
    if (ctx.tmux_socket) |p| try ctx.env.put(socket_env, p);
}

/// Why cl won't run tmux, for `ctx.tmux_blocked`.
pub fn blockedMessage(ctx: Ctx, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\cl: HOME is {s}, not your home directory {s}, so this looks like a sandbox,
        \\and no tmux socket is set. cl won't run tmux here: tmux's default server is
        \\probably your real one. Set {s} (or tmux.socket in the config) to the
        \\sandbox's own socket, an absolute path; to really use the default server,
        \\set it to that server's socket (tmux display -p '#{{socket_path}}').
        \\
    , .{ ctx.home, realHome() orelse "?", socket_env }) catch "cl: no tmux socket set in a sandbox; set " ++ socket_env ++ "\n";
}

/// Exit with `blockedMessage` when cl can't use tmux: for commands that
/// can't do anything without it, and for `cl web` and the dispatcher, which
/// would otherwise run (and start ticket sessions) with no sessions at all.
pub fn requireServer(ctx: Ctx) void {
    if (!ctx.tmux_blocked) return;
    var buf: [1024]u8 = undefined;
    std.debug.print("{s}", .{blockedMessage(ctx, &buf)});
    std.process.exit(1);
}

var warned = std.atomic.Value(bool).init(false);

/// "tmux" and, with a socket, "-S <socket>": the start of every tmux argv.
/// Blocked: says why once (on stderr) and fails.
fn prefixArgs(ctx: Ctx, buf: *[3][]const u8) Error![]const []const u8 {
    if (ctx.tmux_blocked) {
        if (!builtin.is_test and !warned.swap(true, .monotonic)) {
            var mbuf: [1024]u8 = undefined;
            std.debug.print("{s}", .{blockedMessage(ctx, &mbuf)});
        }
        return error.NoTmuxSocket;
    }
    buf[0] = "tmux";
    if (ctx.tmux_socket) |p| {
        buf[1] = "-S";
        buf[2] = p;
        return buf[0..3];
    }
    return buf[0..1];
}

/// The full argv for tmux `argv` on ctx's server. Caller frees the slice.
fn fullArgv(ctx: Ctx, argv: []const []const u8) ![]const []const u8 {
    var pbuf: [3][]const u8 = undefined;
    const pre = try prefixArgs(ctx, &pbuf);
    const full = try ctx.gpa.alloc([]const u8, pre.len + argv.len);
    @memcpy(full[0..pre.len], pre);
    @memcpy(full[pre.len..], argv);
    return full;
}

/// Run tmux with argv and return stdout (trailing newline trimmed). Caller owns result.
pub fn run(ctx: Ctx, argv: []const []const u8) ![]u8 {
    const full = try fullArgv(ctx, argv);
    defer ctx.gpa.free(full);
    const res = try std.process.run(ctx.gpa, ctx.io, .{ .argv = full });
    defer ctx.gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            ctx.gpa.free(res.stdout);
            return error.TmuxFailed;
        },
        else => {
            ctx.gpa.free(res.stdout);
            return error.TmuxFailed;
        },
    }
    const out = std.mem.trimEnd(u8, res.stdout, "\n");
    return ctx.gpa.realloc(res.stdout, out.len) catch res.stdout[0..out.len];
}

pub fn runQuiet(ctx: Ctx, argv: []const []const u8) !void {
    const out = try run(ctx, argv);
    ctx.gpa.free(out);
}

/// Replace the program in a session's first pane with `command`, in `dir`.
/// The session, its name and its other windows stay; the session's
/// environment (profile, config dir) carries over, plus `env`.
pub fn respawn(ctx: Ctx, tmux_name: []const u8, dir: []const u8, env: []const []const u8, command: []const []const u8) !void {
    const target = try std.fmt.allocPrint(ctx.gpa, "={s}", .{tmux_name});
    defer ctx.gpa.free(target);
    const panes = try run(ctx, &.{ "list-panes", "-s", "-t", target, "-F", "#{pane_id}" });
    defer ctx.gpa.free(panes);
    const pane = std.mem.sliceTo(panes, '\n');
    if (pane.len == 0) return error.TmuxFailed;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.appendSlice(ctx.gpa, &.{ "respawn-pane", "-k", "-t", pane, "-c", dir });
    for (env) |e| try argv.appendSlice(ctx.gpa, &.{ "-e", e });
    try argv.append(ctx.gpa, "--");
    try argv.appendSlice(ctx.gpa, command);
    try runQuiet(ctx, argv.items);
    try runQuiet(ctx, &.{ "clear-history", "-t", pane });
}

pub fn hasSession(ctx: Ctx, tmux_name: []const u8) bool {
    runQuiet(ctx, &.{ "has-session", "-t", tmux_name }) catch return false;
    return true;
}

/// Replace everything but [A-Za-z0-9-] with '-'.
pub fn sanitize(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '-') c else '-';
    }
    return out;
}

pub fn shortId(ctx: Ctx, buf: *[8]u8) []const u8 {
    var raw: [4]u8 = undefined;
    ctx.io.random(&raw);
    return std.fmt.bufPrint(buf, "{x:0>8}", .{std.mem.readInt(u32, &raw, .big)}) catch unreachable;
}

pub const NewOptions = struct {
    name: []const u8,
    dir: []const u8,
    profile: []const u8,
    config_dir: ?[]const u8,
    /// Stored as @cl_role; any role hides the session from listings.
    role: []const u8 = "",
    /// Command to run as the pane's initial process.
    command: []const []const u8,
    /// Extra "KEY=value" environment for the session (CL_TICKET, say).
    env: []const []const u8 = &.{},
};

/// Create a detached session running `command`. Returns the tmux session name.
pub fn newSession(ctx: Ctx, opts: NewOptions) ![]const u8 {
    const san = try sanitize(ctx.gpa, opts.name);
    defer ctx.gpa.free(san);
    var idbuf: [8]u8 = undefined;
    var tmux_name: []const u8 = undefined;
    while (true) {
        tmux_name = try std.fmt.allocPrint(ctx.perm, "{s}{s}_{s}", .{ prefix, san, shortId(ctx, &idbuf) });
        if (!hasSession(ctx, tmux_name)) break;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.appendSlice(ctx.gpa, &.{ "new-session", "-d", "-s", tmux_name, "-c", opts.dir });
    const sess_env = try std.fmt.allocPrint(ctx.gpa, "CL_SESSION={s}", .{opts.name});
    defer ctx.gpa.free(sess_env);
    try argv.appendSlice(ctx.gpa, &.{ "-e", sess_env });
    const prof_env = try std.fmt.allocPrint(ctx.gpa, "CL_PROFILE={s}", .{opts.profile});
    defer ctx.gpa.free(prof_env);
    try argv.appendSlice(ctx.gpa, &.{ "-e", prof_env });
    var cfg_env: ?[]const u8 = null;
    defer if (cfg_env) |e| ctx.gpa.free(e);
    if (opts.config_dir) |cd| {
        cfg_env = try std.fmt.allocPrint(ctx.gpa, "CLAUDE_CONFIG_DIR={s}", .{cd});
        try argv.appendSlice(ctx.gpa, &.{ "-e", cfg_env.? });
    }
    var sock_env: ?[]const u8 = null;
    defer if (sock_env) |e| ctx.gpa.free(e);
    if (ctx.tmux_socket) |p| {
        sock_env = try std.fmt.allocPrint(ctx.gpa, "{s}={s}", .{ socket_env, p });
        try argv.appendSlice(ctx.gpa, &.{ "-e", sock_env.? });
    }
    for (opts.env) |e| try argv.appendSlice(ctx.gpa, &.{ "-e", e });
    try argv.append(ctx.gpa, "--");
    try argv.appendSlice(ctx.gpa, opts.command);
    try runQuiet(ctx, argv.items);

    var created_buf: [24]u8 = undefined;
    const created = try std.fmt.bufPrint(&created_buf, "{d}", .{ctx.nowSeconds()});
    // One batched call; a literal ";" argv element separates tmux commands.
    try runQuiet(ctx, &.{
        "set-option", "-t", tmux_name, "@cl_name", opts.name, ";",
        "set-option", "-t", tmux_name, "@cl_dir", opts.dir, ";",
        "set-option", "-t", tmux_name, "@cl_profile", opts.profile, ";",
        "set-option", "-t", tmux_name, "@cl_created", created, ";",
        "set-option", "-t", tmux_name, "@cl_role", opts.role, ";",
        "set-option", "-t", tmux_name, "mouse", "on", ";",
        "set-option", "-t", tmux_name, "-q", "allow-passthrough", "on", ";",
        "set-option", "-t", tmux_name, "set-clipboard", "on", ";",
        "set-option", "-t", tmux_name, "escape-time", "10", ";",
        "set-option", "-t", tmux_name, "set-titles", "on", ";",
        "set-option", "-t", tmux_name, "set-titles-string", "[cl] #{@cl_name}", ";",
        "set-option", "-t", tmux_name, "window-size", "latest", ";",
        "set-option", "-t", tmux_name, "-w", "aggressive-resize", "on", ";",
        "set-option", "-sq", "extended-keys", "on", ";",
        "set-option", "-asq", "terminal-features", ",*:hyperlinks:extkeys",
    });
    try ensureDetachBinding(ctx);
    return tmux_name;
}

/// Ctrl-Q detaches any client attached to a cl_* session. Ctrl-L there also
/// fits the window back to this client (after the web page on a phone sized
/// it) and repaints, then passes Ctrl-L on to Claude. Left is dropped in
/// Claude's own pane when the cursor is at the start of the prompt, where it
/// would open Claude's agents view (which can't be turned off); everywhere
/// else, shells and other panes included, it is a normal Left. Idempotent.
pub fn ensureDetachBinding(ctx: Ctx) !void {
    try runQuiet(ctx, &.{
        "bind-key", "-n", "C-q", "if-shell", "-F", "#{m:cl_*,#{session_name}}", "detach-client", "", ";",
        "bind-key", "-n", "C-l", "if-shell", "-F", "#{m:cl_*,#{session_name}}", "resize-window -A ; set-option window-size latest ; refresh-client ; send-keys C-l", "send-keys C-l", ";",
        "bind-key", "-n", "Left", "if-shell", "-F", agents_guard, "", "send-keys Left",
    });
}

/// In a cl_* session's Claude pane with the cursor at column 2 or less (just
/// after "❯ "). Menus hide the cursor, so their Left still works.
const agents_guard = "#{&&:#{m:cl_*,#{session_name}},#{&&:#{==:#{pane_current_command},claude},#{&&:#{cursor_flag},#{e|<=:#{cursor_x},2}}}}";

const list_format = "#{session_name}\t#{@cl_name}\t#{@cl_dir}\t#{@cl_profile}\t#{@cl_created}\t#{pane_dead}\t#{session_activity}\t#{@cl_role}\t#{@cl_alert}\t#{@cl_hidden}\t#{pane_title}";

/// List Claude sessions, oldest first, leaving out cl's own (operator, web).
/// Caller owns the slice and its strings (use an arena).
pub fn list(ctx: Ctx, arena: std.mem.Allocator) ![]Session {
    const all = try listAll(ctx, arena);
    var n: usize = 0;
    for (all) |s| if (s.role.len == 0) {
        all[n] = s;
        n += 1;
    };
    return all[0..n];
}

/// The operator session, if it is running.
pub fn operator(ctx: Ctx, arena: std.mem.Allocator) !?Session {
    return findRole(ctx, arena, operator_role);
}

pub fn findRole(ctx: Ctx, arena: std.mem.Allocator, role: []const u8) !?Session {
    for (try listAll(ctx, arena)) |s| if (std.mem.eql(u8, s.role, role)) return s;
    return null;
}

fn listAll(ctx: Ctx, arena: std.mem.Allocator) ![]Session {
    const out = run(ctx, &.{ "list-sessions", "-F", list_format }) catch |err| switch (err) {
        error.TmuxFailed => return &.{}, // no server running
        else => return err,
    };
    defer ctx.gpa.free(out);
    var sessions: std.ArrayList(Session) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const tmux_name = f.next() orelse continue;
        const name = f.next() orelse continue;
        const dir = f.next() orelse continue;
        const profile = f.next() orelse continue;
        const created_s = f.next() orelse continue;
        const dead_s = f.next() orelse continue;
        const act_s = f.next() orelse continue;
        const role = f.next() orelse continue;
        const alert = f.next() orelse continue;
        const hidden_s = f.next() orelse continue;
        const title = f.rest();
        try sessions.append(arena, .{
            .tmux_name = try arena.dupe(u8, tmux_name),
            .name = try arena.dupe(u8, if (name.len == 0) tmux_name else name),
            .dir = try arena.dupe(u8, dir),
            .profile = try arena.dupe(u8, profile),
            .created = std.fmt.parseInt(i64, created_s, 10) catch 0,
            .pane_dead = std.mem.eql(u8, dead_s, "1"),
            .activity = std.fmt.parseInt(i64, act_s, 10) catch 0,
            .role = try arena.dupe(u8, role),
            .alert = try arena.dupe(u8, alert),
            .hidden = std.mem.eql(u8, hidden_s, "1"),
            .pane_title = try arena.dupe(u8, title),
        });
    }
    std.mem.sort(Session, sessions.items, {}, struct {
        fn lt(_: void, a: Session, b: Session) bool {
            return a.created < b.created;
        }
    }.lt);
    return sessions.toOwnedSlice(arena);
}

/// Resolve a user-supplied name (cl name or full tmux name) to a session.
pub fn find(ctx: Ctx, arena: std.mem.Allocator, name: []const u8) !?Session {
    const sessions = try list(ctx, arena);
    for (sessions) |s| {
        if (std.mem.eql(u8, s.name, name) or std.mem.eql(u8, s.tmux_name, name)) return s;
    }
    return null;
}

pub fn kill(ctx: Ctx, tmux_name: []const u8) !void {
    try runQuiet(ctx, &.{ "kill-session", "-t", tmux_name });
}

/// Set (or with "" clear) the alert shown in the chooser's header.
pub fn setAlert(ctx: Ctx, tmux_name: []const u8, text: []const u8) !void {
    try runQuiet(ctx, &.{ "set-option", "-t", tmux_name, "@cl_alert", text });
}

/// Hide a session from the chooser (it keeps running), or show it again.
pub fn setHidden(ctx: Ctx, tmux_name: []const u8, hidden: bool) !void {
    if (hidden) {
        try runQuiet(ctx, &.{ "set-option", "-t", tmux_name, "@cl_hidden", "1" });
    } else {
        try runQuiet(ctx, &.{ "set-option", "-u", "-t", tmux_name, "@cl_hidden" });
    }
}

pub fn rename(ctx: Ctx, tmux_name: []const u8, new_name: []const u8) !void {
    try runQuiet(ctx, &.{ "set-option", "-t", tmux_name, "@cl_name", new_name });
}

/// Capture the last `lines` lines of the pane with ANSI escapes. Caller owns result.
pub fn capture(ctx: Ctx, tmux_name: []const u8, lines: usize) ![]u8 {
    var buf: [16]u8 = undefined;
    const start = try std.fmt.bufPrint(&buf, "-{d}", .{lines});
    return run(ctx, &.{ "capture-pane", "-t", tmux_name, "-p", "-e", "-S", start });
}

/// The width of the session's active pane, in columns.
pub fn paneWidth(ctx: Ctx, tmux_name: []const u8) !u16 {
    const out = try run(ctx, &.{ "display-message", "-p", "-t", tmux_name, "#{pane_width}" });
    defer ctx.gpa.free(out);
    return std.fmt.parseInt(u16, std.mem.trim(u8, out, " \n"), 10);
}

/// Plain-text capture of the last `lines` lines of the pane. Caller owns result.
pub fn capturePlainLines(ctx: Ctx, tmux_name: []const u8, lines: usize) ![]u8 {
    var buf: [16]u8 = undefined;
    const start = try std.fmt.bufPrint(&buf, "-{d}", .{lines});
    return run(ctx, &.{ "capture-pane", "-t", tmux_name, "-p", "-S", start });
}

/// Plain-text capture of the visible pane. Caller owns result.
pub fn capturePlain(ctx: Ctx, tmux_name: []const u8) ![]u8 {
    return run(ctx, &.{ "capture-pane", "-t", tmux_name, "-p" });
}

/// Type `text` literally, then press Enter (the pause lets bracketed paste settle).
pub fn sendLine(ctx: Ctx, tmux_name: []const u8, text: []const u8) !void {
    try runQuiet(ctx, &.{ "send-keys", "-l", "-t", tmux_name, "--", text });
    ctx.sleepMs(100);
    try runQuiet(ctx, &.{ "send-keys", "-t", tmux_name, "Enter" });
}

/// Paste the file at `path` into the session as one bracketed paste (so its
/// newlines don't submit it early), then press Enter.
pub fn pasteFile(ctx: Ctx, tmux_name: []const u8, path: []const u8) !void {
    const buf = "cl-paste";
    try runQuiet(ctx, &.{ "load-buffer", "-b", buf, path });
    try runQuiet(ctx, &.{ "paste-buffer", "-p", "-d", "-b", buf, "-t", tmux_name });
    ctx.sleepMs(300);
    try runQuiet(ctx, &.{ "send-keys", "-t", tmux_name, "Enter" });
}

/// Paste `text` into the session as one bracketed paste, then press Enter.
pub fn pasteText(ctx: Ctx, tmux_name: []const u8, text: []const u8) !void {
    // A buffer per session, so two pastes into different sessions can't mix.
    var buf_name: [128]u8 = undefined;
    const buf = std.fmt.bufPrint(&buf_name, "cl-paste-{s}", .{tmux_name}) catch "cl-paste";
    try runQuiet(ctx, &.{ "set-buffer", "-b", buf, "--", text });
    try runQuiet(ctx, &.{ "paste-buffer", "-p", "-d", "-b", buf, "-t", tmux_name });
    ctx.sleepMs(300);
    try runQuiet(ctx, &.{ "send-keys", "-t", tmux_name, "Enter" });
}

/// Attach the current terminal to a session; returns when the client detaches.
pub fn attach(ctx: Ctx, tmux_name: []const u8) !void {
    try ensureDetachBinding(ctx);
    // Drop TMUX so attaching from inside another tmux works (nested client).
    var env = try ctx.env.clone(ctx.gpa);
    defer env.deinit();
    _ = env.swapRemove("TMUX");
    _ = env.swapRemove("TMUX_PANE");
    // Clear scrollback so the previous screen doesn't linger above.
    std.Io.File.stdout().writeStreamingAll(ctx.io, "\x1b[3J\x1b[H\x1b[2J") catch {};
    const argv = try fullArgv(ctx, &.{ "attach-session", "-t", tmux_name });
    defer ctx.gpa.free(argv);
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = &env,
    });
    const term = try child.wait(ctx.io);
    switch (term) {
        .exited => |code| if (code > 1) return error.TmuxFailed,
        else => return error.TmuxFailed,
    }
}

test "decide: CL_TMUX_SOCKET wins over tmux.socket, and must be absolute" {
    const s = try decide("/run/a.sock", "/run/b.sock", "/sandbox", "/home/me");
    try std.testing.expectEqualStrings("/run/a.sock", s.socket.?);
    try std.testing.expect(!s.blocked);
    try std.testing.expectEqualStrings("/run/b.sock", (try decide(null, "/run/b.sock", "/sandbox", "/home/me")).socket.?);
    try std.testing.expectEqualStrings("/run/b.sock", (try decide("", "/run/b.sock", "/sandbox", "/home/me")).socket.?);
    try std.testing.expectError(error.RelativeSocket, decide("cl-try/tmux", "", "/home/me", "/home/me"));
    try std.testing.expectError(error.RelativeSocket, decide(null, "sock", "/home/me", "/home/me"));
    try std.testing.expectError(error.SocketPathTooLong, decide("/" ++ "x" ** 110, "", "/home/me", "/home/me"));
}

test "decide: a sandbox HOME without a socket is blocked" {
    const real = try decide(null, "", "/home/me/", "/home/me");
    try std.testing.expect(real.socket == null and !real.blocked);
    try std.testing.expect((try decide(null, "", "/tmp/cl-try", "/home/me")).blocked);
    // No passwd entry: can't tell, so the default server.
    try std.testing.expect(!(try decide(null, "", "/tmp/cl-try", null)).blocked);
}

fn testCtx(socket: ?[]const u8, blocked: bool) Ctx {
    return .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp", .tmux_socket = socket, .tmux_blocked = blocked };
}

test "every tmux argv names the socket when one is set" {
    const a = std.testing.allocator;
    const with = try fullArgv(testCtx("/run/x/tmux", false), &.{ "list-sessions", "-F", "#{session_name}" });
    defer a.free(with);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "tmux", "-S", "/run/x/tmux", "list-sessions", "-F", "#{session_name}" }), with);
    const without = try fullArgv(testCtx(null, false), &.{"list-sessions"});
    defer a.free(without);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "tmux", "list-sessions" }), without);
    try std.testing.expectError(error.NoTmuxSocket, run(testCtx(null, true), &.{"list-sessions"}));
    try std.testing.expectError(error.NoTmuxSocket, fullArgv(testCtx(null, true), &.{"kill-server"}));
}

test "sessions go to the socket's server, not the default one" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    // Skip without tmux on PATH.
    const probe = std.process.run(a, io, .{ .argv = &.{ "tmux", "-V" } }) catch return error.SkipZigTest;
    a.free(probe.stdout);
    a.free(probe.stderr);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const sock = try std.fmt.allocPrint(a, "{s}/tmux", .{dir});
    defer a.free(sock);
    // The server is stopped with an explicit -S, never through the code under test.
    defer if (std.process.run(a, io, .{ .argv = &.{ "tmux", "-S", sock, "kill-server" } })) |r| {
        a.free(r.stdout);
        a.free(r.stderr);
    } else |_| {};

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(sock, false);
    ctx.perm = arena;
    const name = try newSession(ctx, .{ .name = "socket-test", .dir = dir, .profile = "", .config_dir = null, .command = &.{ "sleep", "60" } });

    const sessions = try list(ctx, arena);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings(name, sessions[0].tmux_name);
    // The session's processes get the socket too.
    const env = try run(ctx, &.{ "show-environment", "-t", name, socket_env });
    defer a.free(env);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}={s}", .{ socket_env, sock }), env);
    // And the default server never saw it.
    try std.testing.expect(!hasSession(testCtx(null, false), name));
}

test "configure keeps CL_TMUX_SOCKET from the environment, and passes on tmux.socket" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The testing allocator poisons freed memory, so a use-after-free shows.
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(socket_env, "/run/user/1000/cl-try/tmux");
    var ctx = testCtx(null, false);
    ctx.perm = a;
    ctx.env = &env;
    try configure(&ctx, .{ .profiles = &.{}, .default = "", .operator = "" });
    try std.testing.expectEqualStrings("/run/user/1000/cl-try/tmux", ctx.tmux_socket.?);
    try std.testing.expectEqualStrings("/run/user/1000/cl-try/tmux", env.get(socket_env).?);

    var env2: std.process.Environ.Map = .init(std.testing.allocator);
    defer env2.deinit();
    ctx.env = &env2;
    try configure(&ctx, .{ .profiles = &.{}, .default = "", .operator = "", .tmux = .{ .socket = "/run/cfg.sock" } });
    try std.testing.expectEqualStrings("/run/cfg.sock", ctx.tmux_socket.?);
    try std.testing.expectEqualStrings("/run/cfg.sock", env2.get(socket_env).?);
}
