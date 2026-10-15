//! All tmux interaction. tmux is the session store: every cl session is a tmux
//! session named `cl_<name>_<id>` carrying @cl_* user options.
const std = @import("std");
const Ctx = @import("ctx.zig");

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
    /// "operator" for the operator session, "" otherwise.
    role: []const u8,
};

pub const operator_role = "operator";

pub const Error = error{TmuxFailed};

/// Run tmux with argv and return stdout (trailing newline trimmed). Caller owns result.
pub fn run(ctx: Ctx, argv: []const []const u8) ![]u8 {
    const full = try ctx.gpa.alloc([]const u8, argv.len + 1);
    defer ctx.gpa.free(full);
    full[0] = "tmux";
    @memcpy(full[1..], argv);
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
    /// Stored as @cl_role; "operator" hides the session from listings.
    role: []const u8 = "",
    /// Command to run as the pane's initial process.
    command: []const []const u8,
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
        "set-option", "-t", tmux_name, "status", "off", ";",
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

/// Ctrl-Q detaches any client attached to a cl_* session. Idempotent.
pub fn ensureDetachBinding(ctx: Ctx) !void {
    try runQuiet(ctx, &.{
        "bind-key", "-n", "C-q", "if-shell", "-F", "#{m:cl_*,#{session_name}}", "detach-client", "",
    });
}

const list_format = "#{session_name}\t#{@cl_name}\t#{@cl_dir}\t#{@cl_profile}\t#{@cl_created}\t#{pane_dead}\t#{session_activity}\t#{@cl_role}\t#{pane_title}";

/// List cl sessions, oldest first, leaving out the operator. Caller owns the
/// slice and its strings (use an arena).
pub fn list(ctx: Ctx, arena: std.mem.Allocator) ![]Session {
    const all = try listAll(ctx, arena);
    var n: usize = 0;
    for (all) |s| if (!std.mem.eql(u8, s.role, operator_role)) {
        all[n] = s;
        n += 1;
    };
    return all[0..n];
}

/// The operator session, if it is running.
pub fn operator(ctx: Ctx, arena: std.mem.Allocator) !?Session {
    for (try listAll(ctx, arena)) |s| if (std.mem.eql(u8, s.role, operator_role)) return s;
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

pub fn rename(ctx: Ctx, tmux_name: []const u8, new_name: []const u8) !void {
    try runQuiet(ctx, &.{ "set-option", "-t", tmux_name, "@cl_name", new_name });
}

/// Capture the last `lines` lines of the pane with ANSI escapes. Caller owns result.
pub fn capture(ctx: Ctx, tmux_name: []const u8, lines: usize) ![]u8 {
    var buf: [16]u8 = undefined;
    const start = try std.fmt.bufPrint(&buf, "-{d}", .{lines});
    return run(ctx, &.{ "capture-pane", "-t", tmux_name, "-p", "-e", "-S", start });
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
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ "tmux", "attach-session", "-t", tmux_name },
        .environ_map = &env,
    });
    const term = try child.wait(ctx.io);
    switch (term) {
        .exited => |code| if (code > 1) return error.TmuxFailed,
        else => return error.TmuxFailed,
    }
}
