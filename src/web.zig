//! `cl web`: the chooser in a browser. Each page load gets its own `cl list`
//! on a pseudo-terminal, bridged to xterm.js over a WebSocket. A password
//! (argon2id hash in the config) guards everything but the static files.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const pty = @import("pty.zig");

const index_html = @embedFile("web/index.html");
const login_html = @embedFile("web/login.html");
const vendor = .{
    .{ "/xterm.js", "text/javascript", @embedFile("web/vendor/xterm.js") },
    .{ "/xterm.css", "text/css", @embedFile("web/vendor/xterm.css") },
    .{ "/addon-fit.js", "text/javascript", @embedFile("web/vendor/addon-fit.js") },
};

const cookie_name = "cl_session";
const session_days = 30;

const State = struct {
    ctx: Ctx,
    cfg: config.Config,
    /// HMAC key for session cookies, derived from the password hash, so
    /// sessions survive restarts and a new password logs everyone out.
    key: [32]u8,
    exe: []const u8,
    mutex: std.Io.Mutex = .init,
    /// Unix seconds of recent failed logins, for rate limiting.
    failures: [8]i64 = @splat(0),
};

pub fn main(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len > 0) {
        if (std.mem.eql(u8, argv[0], "password")) return setPassword(ctx);
        if (std.mem.eql(u8, argv[0], "start")) return start(ctx, cfg, true);
        if (std.mem.eql(u8, argv[0], "stop")) return stop(ctx);
        return fail("usage: cl web [password | start | stop]", .{});
    }
    return serve(ctx, cfg);
}

fn serve(ctx: Ctx, cfg: config.Config) !void {
    if (cfg.web.password.len == 0) fail("no web.password in ~/.config/cl/config; run `cl web password`", .{});

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.Io.Dir.readLinkAbsolute(ctx.io, "/proc/self/exe", &exe_buf);
    var state: State = .{ .ctx = ctx, .cfg = cfg, .key = undefined, .exe = exe_buf[0..exe_len] };
    std.crypto.hash.sha2.Sha256.hash(cfg.web.password, &state.key, .{});

    // One listener per comma-separated address. Mistakes in the config stop us
    // here; an address that is not available yet (tailscale) is retried.
    var threads: std.ArrayList(std.Thread) = .empty;
    var it = std.mem.splitScalar(u8, cfg.web.listen, ',');
    while (it.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        if (text.len == 0) continue;
        const spec = parseSpec(text);
        try threads.append(ctx.perm, try std.Thread.spawn(.{}, listenLoop, .{ &state, spec }));
    }
    if (threads.items.len == 0) fail("web.listen is empty", .{});
    for (threads.items) |t| t.join();
}

/// One web.listen entry: "host:port", where host `tailscale` means this
/// machine's tailnet IPv4.
const Spec = struct { host: []const u8, port: u16 };

fn parseSpec(text: []const u8) Spec {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse fail("web.listen entries are host:port, got {s}", .{text});
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch fail("bad port in web.listen: {s}", .{text});
    const host = text[0..colon];
    if (!std.mem.eql(u8, host, "tailscale")) {
        _ = std.Io.net.IpAddress.parse(host, port) catch fail("bad host in web.listen: {s}", .{host});
    }
    return .{ .host = host, .port = port };
}

/// Resolve, listen, and accept forever, retrying every 30 s while the address
/// is unavailable (tailscale down or logged out).
fn listenLoop(state: *State, spec: Spec) void {
    const ctx = state.ctx;
    var last_err: ?[]const u8 = null;
    while (true) : (ctx.sleepMs(30_000)) {
        var ip_buf: [64]u8 = undefined;
        const host = if (std.mem.eql(u8, spec.host, "tailscale"))
            tailscaleIp(ctx, &ip_buf) catch |err| {
                if (last_err == null or !std.mem.eql(u8, last_err.?, @errorName(err)))
                    logf("{s}:{d}: no tailscale IPv4 yet ({s}); retrying every 30s", .{ spec.host, spec.port, @errorName(err) });
                last_err = @errorName(err);
                continue;
            }
        else
            spec.host;
        const addr = std.Io.net.IpAddress.parse(host, spec.port) catch unreachable; // checked in parseSpec / tailscaleIp
        var server = addr.listen(ctx.io, .{ .reuse_address = true }) catch |err| {
            if (last_err == null or !std.mem.eql(u8, last_err.?, @errorName(err)))
                logf("cannot listen on {f}: {s}; retrying every 30s", .{ addr, @errorName(err) });
            last_err = @errorName(err);
            continue;
        };
        defer server.deinit(ctx.io);
        last_err = null;
        logf("cl web listening on http://{f}", .{addr});
        while (true) {
            const stream = server.accept(ctx.io) catch |err| {
                logf("accept on {f}: {s}", .{ addr, @errorName(err) });
                break;
            };
            const t = std.Thread.spawn(.{}, handleConnection, .{ state, stream }) catch {
                stream.close(ctx.io);
                continue;
            };
            t.detach();
        }
    }
}

fn tailscaleIp(ctx: Ctx, buf: []u8) ![]const u8 {
    const r = std.process.run(ctx.gpa, ctx.io, .{ .argv = &.{ "tailscale", "ip", "-4" } }) catch return error.TailscaleNotRunnable;
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    const ip = std.mem.trim(u8, std.mem.sliceTo(r.stdout, '\n'), " \r\t");
    if (ip.len == 0) return error.TailscaleHasNoIp;
    _ = std.Io.net.IpAddress.parse(ip, 0) catch return error.TailscaleHasNoIp;
    if (ip.len > buf.len) return error.TailscaleHasNoIp;
    @memcpy(buf[0..ip.len], ip);
    return buf[0..ip.len];
}

fn handleConnection(state: *State, stream: std.Io.net.Stream) void {
    const io = state.ctx.io;
    defer stream.close(io);
    // Large enough for a WebSocket message (a paste) to fit in one read.
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    while (true) {
        var req = http.receiveHead() catch return;
        const upgraded = handleRequest(state, &req) catch return;
        if (upgraded) return;
    }
}

/// Returns true when the connection became a WebSocket (and is finished).
fn handleRequest(state: *State, req: *std.http.Server.Request) !bool {
    const target = req.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    inline for (vendor) |v| {
        if (std.mem.eql(u8, path, v[0])) {
            try req.respond(v[2], .{ .extra_headers = &.{
                .{ .name = "content-type", .value = v[1] },
                .{ .name = "cache-control", .value = "public, max-age=86400" },
            } });
            return false;
        }
    }

    if (std.mem.eql(u8, path, "/login") and req.head.method == .POST) {
        try handleLogin(state, req);
        return false;
    }

    const authed = checkCookie(state, header(req, "cookie") orelse "");
    if (std.mem.eql(u8, path, "/ws")) {
        if (!authed or !sameOrigin(req)) {
            try req.respond("forbidden\n", .{ .status = .forbidden, .keep_alive = false });
            return false;
        }
        switch (req.upgradeRequested()) {
            .websocket => |key| {
                try serveTerminal(state, req, key orelse return error.BadRequest);
                return true;
            },
            else => {
                try req.respond("expected a websocket\n", .{ .status = .bad_request });
                return false;
            },
        }
    }
    if (std.mem.eql(u8, path, "/logout")) {
        try req.respond("", .{ .status = .see_other, .extra_headers = &.{
            .{ .name = "location", .value = "/" },
            .{ .name = "set-cookie", .value = cookie_name ++ "=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" },
        } });
        return false;
    }
    if (std.mem.eql(u8, path, "/")) {
        try req.respond(if (authed) index_html else loginPage(""), .{ .extra_headers = &html_headers });
        return false;
    }
    try req.respond("not found\n", .{ .status = .not_found });
    return false;
}

const html_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
};

fn loginPage(comptime err: []const u8) []const u8 {
    const marker = "<!--error-->";
    const at = comptime std.mem.indexOf(u8, login_html, marker).?;
    return login_html[0..at] ++ err ++ login_html[at + marker.len ..];
}

fn header(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Refuse cross-site WebSocket connections: the Origin must name this host.
fn sameOrigin(req: *const std.http.Server.Request) bool {
    const origin = header(req, "origin") orelse return false;
    const host = header(req, "host") orelse return false;
    const rest = if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else
        return false;
    return std.mem.eql(u8, rest, host);
}

fn handleLogin(state: *State, req: *std.http.Server.Request) !void {
    const ctx = state.ctx;
    const now = ctx.nowSeconds();
    if (rateLimited(state, now)) {
        try req.respond(loginPage("<p class=err>Too many attempts. Wait a minute.</p>"), .{ .status = .too_many_requests, .extra_headers = &html_headers });
        return;
    }
    var body_buf: [4096]u8 = undefined;
    const len: usize = @intCast(@min(req.head.content_length orelse 0, body_buf.len));
    const body_reader = try req.readerExpectContinue(&.{});
    body_reader.readSliceAll(body_buf[0..len]) catch return error.BadRequest;
    var pw_buf: [1024]u8 = undefined;
    const password = formValue(body_buf[0..len], "password", &pw_buf) orelse "";

    const ok = blk: {
        std.crypto.pwhash.argon2.strVerify(state.cfg.web.password, password, .{ .allocator = ctx.gpa }, ctx.io) catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        recordFailure(state, now);
        logf("failed login", .{});
        try req.respond(loginPage("<p class=err>Wrong password.</p>"), .{ .status = .unauthorized, .extra_headers = &html_headers });
        return;
    }
    var token_buf: [128]u8 = undefined;
    const token = makeToken(state, now + session_days * 86400, &token_buf);
    var cookie_buf: [256]u8 = undefined;
    const cookie = try std.fmt.bufPrint(&cookie_buf, cookie_name ++ "={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Strict", .{ token, session_days * 86400 });
    try req.respond("", .{ .status = .see_other, .extra_headers = &.{
        .{ .name = "location", .value = "/" },
        .{ .name = "set-cookie", .value = cookie },
    } });
}

/// More than five failures within a minute locks logins until they age out.
fn rateLimited(state: *State, now: i64) bool {
    state.mutex.lockUncancelable(state.ctx.io);
    defer state.mutex.unlock(state.ctx.io);
    var recent: usize = 0;
    for (state.failures) |t| if (now - t < 60) {
        recent += 1;
    };
    return recent > 5;
}

fn recordFailure(state: *State, now: i64) void {
    state.mutex.lockUncancelable(state.ctx.io);
    defer state.mutex.unlock(state.ctx.io);
    var oldest: usize = 0;
    for (state.failures, 0..) |t, i| if (t < state.failures[oldest]) {
        oldest = i;
    };
    state.failures[oldest] = now;
}

/// "<expiry>.<hex hmac>"
fn makeToken(state: *const State, expiry: i64, buf: []u8) []const u8 {
    var exp_buf: [24]u8 = undefined;
    const exp = std.fmt.bufPrint(&exp_buf, "{d}", .{expiry}) catch unreachable;
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, exp, &state.key);
    return std.fmt.bufPrint(buf, "{s}.{x}", .{ exp, &mac }) catch unreachable;
}

fn checkCookie(state: *const State, cookies: []const u8) bool {
    var it = std.mem.splitScalar(u8, cookies, ';');
    while (it.next()) |raw| {
        const c = std.mem.trim(u8, raw, " ");
        if (!std.mem.startsWith(u8, c, cookie_name ++ "=")) continue;
        const token = c[cookie_name.len + 1 ..];
        const dot = std.mem.indexOfScalar(u8, token, '.') orelse return false;
        const expiry = std.fmt.parseInt(i64, token[0..dot], 10) catch return false;
        if (expiry < state.ctx.nowSeconds()) return false;
        var want_buf: [128]u8 = undefined;
        const want = makeToken(state, expiry, &want_buf);
        if (want.len != token.len) return false;
        var diff: u8 = 0;
        for (want, token) |a, b| diff |= a ^ b;
        return diff == 0;
    }
    return false;
}

/// Decode one field of an application/x-www-form-urlencoded body.
fn formValue(body: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        var n: usize = 0;
        var i: usize = eq + 1;
        while (i < pair.len and n < out.len) : (n += 1) {
            if (pair[i] == '+') {
                out[n] = ' ';
                i += 1;
            } else if (pair[i] == '%' and i + 2 < pair.len) {
                out[n] = std.fmt.parseInt(u8, pair[i + 1 .. i + 3], 16) catch '?';
                i += 3;
            } else {
                out[n] = pair[i];
                i += 1;
            }
        }
        return out[0..n];
    }
    return null;
}

test formValue {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a b&c=%", formValue("x=1&password=a+b%26c%3D%25", "password", &buf).?);
    try std.testing.expect(formValue("x=1", "password", &buf) == null);
}

/// Bridge a WebSocket to a fresh `cl list` on a pseudo-terminal.
/// Client messages: "0<input bytes>" or "1<cols>,<rows>". Server sends output as binary.
fn serveTerminal(state: *State, req: *std.http.Server.Request, key: []const u8) !void {
    const ctx = state.ctx;
    var ws = try req.respondWebSocket(.{ .key = key });
    try ws.flush();

    // The page sends its size first; start the chooser at that size.
    var cols: u16 = 80;
    var rows: u16 = 24;
    const first = ws.readSmallMessage() catch return;
    if (first.data.len > 0 and first.data[0] == '1') parseSize(first.data[1..], &cols, &rows);

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.ArrayList([]const u8) = .empty;
    var it = ctx.env.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "TMUX") or std.mem.eql(u8, k, "TMUX_PANE") or
            std.mem.eql(u8, k, "TERM") or std.mem.eql(u8, k, "COLORTERM")) continue;
        try env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ k, e.value_ptr.* }));
    }
    try env.appendSlice(arena, &.{ "TERM=xterm-256color", "COLORTERM=truecolor" });

    const term = pty.spawn(arena, &.{ state.exe, "list" }, env.items, cols, rows) catch |err| {
        logf("pty: {s}", .{@errorName(err)});
        return;
    };
    logf("terminal opened ({d}x{d})", .{ cols, rows });
    const pump = try std.Thread.spawn(.{}, pumpOutput, .{ term, &ws });

    while (true) {
        const msg = ws.readSmallMessage() catch break;
        if (msg.data.len == 0) continue;
        switch (msg.data[0]) {
            '0' => term.write(msg.data[1..]),
            '1' => {
                parseSize(msg.data[1..], &cols, &rows);
                term.resize(cols, rows);
            },
            else => {},
        }
    }
    // Hang up the whole session (the chooser and any tmux client it started);
    // the pump sees EOF once they are gone.
    _ = std.os.linux.kill(-term.pid, .HUP);
    pump.join();
    term.close();
    logf("terminal closed", .{});
}

fn pumpOutput(term: pty.Pty, ws: *std.http.Server.WebSocket) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = term.read(&buf);
        if (n == 0) break;
        ws.writeMessage(buf[0..n], .binary) catch break;
    }
    // The chooser exited (q) or was hung up: tell the page.
    ws.writeMessage("", .connection_close) catch {};
}

fn parseSize(text: []const u8, cols: *u16, rows: *u16) void {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return;
    const c = std.fmt.parseInt(u16, text[0..comma], 10) catch return;
    const r = std.fmt.parseInt(u16, text[comma + 1 ..], 10) catch return;
    if (c >= 10 and r >= 5) {
        cols.* = c;
        rows.* = r;
    }
}

// ---- background server, password ----

/// Start the server in a hidden tmux session unless it is running. `force`
/// ignores web.autostart (for `cl web start`).
pub fn start(ctx: Ctx, cfg: config.Config, force: bool) !void {
    if (!force and !cfg.web.autostart) return;
    if (cfg.web.password.len == 0) {
        if (force) fail("no web.password in ~/.config/cl/config; run `cl web password`", .{});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (try tmux.findRole(ctx, arena, tmux.web_role) != null) {
        if (force) say("cl web is already running (cl web stop to stop it)", .{});
        return;
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.Io.Dir.readLinkAbsolute(ctx.io, "/proc/self/exe", &exe_buf)];
    const log = try logPath(ctx, arena);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(log).?);
    _ = try tmux.newSession(ctx, .{
        .name = "web",
        .dir = ctx.home,
        .profile = "",
        .config_dir = null,
        .role = tmux.web_role,
        // Restart after a crash, and record how each run ended.
        .command = &.{ "sh", "-c", "while :; do \"$0\" web >>\"$1\" 2>&1; echo \"$(date '+%F %T') cl web exited with status $?; restarting in 10s\" >>\"$1\"; sleep 10; done", exe, log },
    });
    if (force) say("cl web started (log: {s})", .{log});
}

fn stop(ctx: Ctx) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const s = (try tmux.findRole(ctx, arena_state.allocator(), tmux.web_role)) orelse fail("cl web is not running", .{});
    try tmux.kill(ctx, s.tmux_name);
}

fn logPath(ctx: Ctx, alloc: std.mem.Allocator) ![]const u8 {
    if (ctx.env.get("XDG_STATE_HOME")) |d| if (d.len > 0) return std.fmt.allocPrint(alloc, "{s}/cl/web.log", .{d});
    return std.fmt.allocPrint(alloc, "{s}/.local/state/cl/web.log", .{ctx.home});
}

/// Prompt for a password (twice, without echo), hash it, and store it as
/// web.password in the config, replacing any previous one.
fn setPassword(ctx: Ctx) !void {
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const a = try readSecret(ctx, "new web password: ", &a_buf);
    if (a.len < 8) fail("use at least 8 characters", .{});
    const b = try readSecret(ctx, "again: ", &b_buf);
    if (!std.mem.eql(u8, a, b)) fail("passwords differ", .{});

    var hash_buf: [128]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(a, .{
        .allocator = ctx.gpa,
        .params = .interactive_2id,
    }, &hash_buf, ctx.io);

    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/.config/cl/config", .{ctx.home});
    defer ctx.gpa.free(path);
    const old = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try ctx.gpa.dupe(u8, ""),
        else => return err,
    };
    defer ctx.gpa.free(old);
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        const key = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '=') orelse 0], " \t");
        if (std.mem.eql(u8, key, "web.password")) continue;
        try aw.writer.print("{s}\n", .{line});
    }
    try aw.writer.print("web.password = {s}\n", .{hash});
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = aw.writer.buffered() });
    say("saved web.password to {s}; restart the server (cl web stop) to use it", .{path});
}

fn readSecret(ctx: Ctx, prompt: []const u8, buf: []u8) ![]const u8 {
    const linux = std.os.linux;
    std.Io.File.stderr().writeStreamingAll(ctx.io, prompt) catch {};
    var saved: linux.termios = undefined;
    const tty = linux.errno(linux.tcgetattr(0, &saved)) == .SUCCESS;
    if (tty) {
        var quiet = saved;
        quiet.lflag.ECHO = false;
        _ = linux.tcsetattr(0, .NOW, &quiet);
    }
    defer if (tty) {
        _ = linux.tcsetattr(0, .NOW, &saved);
        std.Io.File.stderr().writeStreamingAll(ctx.io, "\n") catch {};
    };
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        const rc = linux.read(0, &c, 1);
        if (linux.errno(rc) != .SUCCESS or rc == 0 or c[0] == '\n') break;
        buf[n] = c[0];
        n += 1;
    }
    return std.mem.trimEnd(u8, buf[0..n], "\r");
}

/// Server log line, timestamped.
fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const secs: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    const msg = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC " ++ fmt ++ "\n", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    } ++ args) catch return;
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}

/// Plain message for interactive commands (no timestamp).
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    say("cl: " ++ fmt, args);
    std.process.exit(1);
}
