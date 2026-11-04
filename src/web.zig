//! `cl web`: the chooser in a browser. Each page gets its own `cl list`
//! on a pseudo-terminal, bridged to xterm.js over a WebSocket and kept for a
//! while when the connection drops. A password (argon2id hash in the config)
//! guards everything but the static files.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const pty = @import("pty.zig");
const dispatch = @import("dispatch.zig");
const review = @import("review.zig");
const web_board = @import("web_board.zig");

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
    /// Live terminals, by page. Guarded by `mutex`.
    terms: std.ArrayList(*Terminal) = .empty,
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
    const exe_len = try std.process.executablePath(ctx.io, &exe_buf);
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
    (try std.Thread.spawn(.{}, reapLoop, .{&state})).detach();
    if (cfg.board.dispatch) (try std.Thread.spawn(.{}, dispatch.loop, .{ ctx, cfg, &logLine })).detach();
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

// ---- gutter relay ----

/// gutter listens on 127.0.0.1 only. To open it from another machine (the
/// phone, over tailscale), the same port is opened on this server's other
/// listen addresses and relayed to it, only while that ticket's gutter runs.
const Relay = struct { port: u16, key: [32]u8, key_len: usize };
var relays: [32]Relay = undefined;
var relay_count: usize = 0;
var relay_mutex: std.Io.Mutex = .init;

/// Make the ticket's gutter on 127.0.0.1:`port` reachable on the other
/// web.listen addresses.
pub fn relayGutter(ctx: Ctx, cfg: config.Config, key: []const u8, port: u16) void {
    relay_mutex.lockUncancelable(ctx.io);
    defer relay_mutex.unlock(ctx.io);
    for (relays[0..relay_count]) |*r| if (r.port == port) {
        // Same port, maybe a new ticket: point it there.
        r.key_len = @min(key.len, r.key.len);
        @memcpy(r.key[0..r.key_len], key[0..r.key_len]);
        return;
    };
    if (relay_count == relays.len) return;
    var r: Relay = .{ .port = port, .key = undefined, .key_len = @min(key.len, 32) };
    @memcpy(r.key[0..r.key_len], key[0..r.key_len]);
    relays[relay_count] = r;
    relay_count += 1;
    var it = std.mem.splitScalar(u8, cfg.web.listen, ',');
    while (it.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        if (text.len == 0) continue;
        const spec = parseSpec(text);
        var ip_buf: [64]u8 = undefined;
        const host = if (std.mem.eql(u8, spec.host, "tailscale")) tailscaleIp(ctx, &ip_buf) catch continue else spec.host;
        if (std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "localhost")) continue;
        const addr = std.Io.net.IpAddress.parse(host, port) catch continue;
        const t = std.Thread.spawn(.{}, relayListen, .{ ctx, addr, port }) catch continue;
        t.detach();
    }
}

/// The ticket the relay on `port` is for, while its gutter still uses that port.
fn relayLive(ctx: Ctx, port: u16) bool {
    var key_buf: [32]u8 = undefined;
    var key: []const u8 = "";
    {
        relay_mutex.lockUncancelable(ctx.io);
        defer relay_mutex.unlock(ctx.io);
        for (relays[0..relay_count]) |r| if (r.port == port) {
            @memcpy(key_buf[0..r.key_len], r.key[0..r.key_len]);
            key = key_buf[0..r.key_len];
        };
    }
    if (key.len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const live = review.gutterPort(ctx, arena_state.allocator(), key) catch return false;
    return live == port;
}

fn relayListen(ctx: Ctx, addr: std.Io.net.IpAddress, port: u16) void {
    var server = addr.listen(ctx.io, .{ .reuse_address = true }) catch |err| {
        logf("gutter relay on {f}: {s}", .{ addr, @errorName(err) });
        return;
    };
    defer server.deinit(ctx.io);
    while (true) {
        const client = server.accept(ctx.io) catch return;
        if (!relayLive(ctx, port)) {
            client.close(ctx.io);
            continue;
        }
        const t = std.Thread.spawn(.{}, relayConn, .{ ctx, client, port }) catch {
            client.close(ctx.io);
            continue;
        };
        t.detach();
    }
}

fn relayConn(ctx: Ctx, client: std.Io.net.Stream, port: u16) void {
    defer client.close(ctx.io);
    const local = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    const upstream = local.connect(ctx.io, .{ .mode = .stream }) catch return;
    defer upstream.close(ctx.io);
    const back = std.Thread.spawn(.{}, pipe, .{ ctx, upstream, client }) catch return;
    pipe(ctx, client, upstream);
    back.join();
}

/// Copy `from` to `to` until `from` ends, then end `to`'s sending side.
fn pipe(ctx: Ctx, from: std.Io.net.Stream, to: std.Io.net.Stream) void {
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var r = from.reader(ctx.io, &rbuf);
    var w = to.writer(ctx.io, &wbuf);
    while (true) {
        const n = r.interface.stream(&w.interface, .limited(wbuf.len)) catch break;
        if (n == 0) break;
        w.interface.flush() catch break;
    }
    w.interface.flush() catch {};
    to.shutdown(ctx.io, .send) catch {};
}

/// The tailscale CLI: on PATH, or inside the app on macOS (Mac App Store and
/// standalone installs don't put it on PATH).
const tailscale_clis = [_][]const u8{ "tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale" };

fn tailscaleIp(ctx: Ctx, buf: []u8) ![]const u8 {
    for (tailscale_clis) |cli| {
        const r = std.process.run(ctx.gpa, ctx.io, .{ .argv = &.{ cli, "ip", "-4" } }) catch continue;
        defer ctx.gpa.free(r.stdout);
        defer ctx.gpa.free(r.stderr);
        const ip = std.mem.trim(u8, std.mem.sliceTo(r.stdout, '\n'), " \r\t");
        if (ip.len == 0) return error.TailscaleHasNoIp;
        _ = std.Io.net.IpAddress.parse(ip, 0) catch return error.TailscaleHasNoIp;
        if (ip.len > buf.len) return error.TailscaleHasNoIp;
        @memcpy(buf[0..ip.len], ip);
        return buf[0..ip.len];
    }
    return error.TailscaleNotRunnable;
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
    if (try web_board.handle(state.ctx, state.cfg, req, path, authed)) return false;
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
pub fn sameOrigin(req: *const std.http.Server.Request) bool {
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

/// How long a terminal outlives its page's connection, so a phone that drops
/// the socket in the background picks up where it left off.
const detach_grace_s = 15 * 60;

/// A page's `cl list` on a pseudo-terminal. It outlives the WebSocket that
/// started it: a page that reconnects with the same id gets it back.
const Terminal = struct {
    id_buf: [32]u8,
    id_len: usize,
    pty: pty.Pty,
    arena: std.heap.ArenaAllocator,
    /// Guards `ws` and `detached_at`; held while writing to `ws`.
    mutex: std.Io.Mutex = .init,
    /// The connection output goes to; null while detached.
    ws: ?*std.http.Server.WebSocket = null,
    detached_at: i64 = 0,
    /// The registry's reference (dropped when the child exits) plus one per
    /// connection using it. Guarded by `State.mutex`.
    refs: u32 = 1,

    fn id(self: *const Terminal) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// Find the page's terminal (taking a reference) or start a new one.
/// `attach` names a tmux session to open instead of the chooser ("" for the chooser).
fn acquireTerminal(state: *State, term_id: []const u8, attach: []const u8, cols: u16, rows: u16) !struct { *Terminal, bool } {
    const ctx = state.ctx;
    state.mutex.lockUncancelable(ctx.io);
    defer state.mutex.unlock(ctx.io);
    if (term_id.len > 0) for (state.terms.items) |t| if (std.mem.eql(u8, t.id(), term_id)) {
        t.refs += 1;
        return .{ t, false };
    };

    const t = try ctx.gpa.create(Terminal);
    errdefer ctx.gpa.destroy(t);
    t.* = .{ .id_buf = undefined, .id_len = term_id.len, .pty = undefined, .arena = .init(ctx.gpa), .refs = 2 };
    errdefer t.arena.deinit();
    @memcpy(t.id_buf[0..term_id.len], term_id);
    const arena = t.arena.allocator();
    var env: std.ArrayList([]const u8) = .empty;
    var it = ctx.env.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "TMUX") or std.mem.eql(u8, k, "TMUX_PANE") or
            std.mem.eql(u8, k, "TERM") or std.mem.eql(u8, k, "COLORTERM")) continue;
        try env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ k, e.value_ptr.* }));
    }
    try env.appendSlice(arena, &.{ "TERM=xterm-256color", "COLORTERM=truecolor" });
    // "operator" (the board's Chat button) starts the operator if it isn't
    // running; tmux names all start with "cl", so it can't be a session's.
    const argv: []const []const u8 = if (std.mem.eql(u8, attach, operator_target))
        &.{ state.exe, "operator" }
    else if (attach.len > 0) &.{ state.exe, "attach", try arena.dupe(u8, attach) } else &.{ state.exe, "list" };
    t.pty = pty.spawn(arena, argv, env.items, cols, rows) catch |err| {
        logf("pty: {s}", .{@errorName(err)});
        return err;
    };
    errdefer t.pty.close();
    try state.terms.append(ctx.gpa, t);
    errdefer _ = state.terms.pop();
    const pump = try std.Thread.spawn(.{}, pumpOutput, .{ state, t });
    pump.detach();
    logf("terminal opened ({d}x{d})", .{ cols, rows });
    return .{ t, true };
}

fn releaseTerminal(state: *State, t: *Terminal) void {
    state.mutex.lockUncancelable(state.ctx.io);
    t.refs -= 1;
    const last = t.refs == 0;
    state.mutex.unlock(state.ctx.io);
    if (!last) return;
    t.pty.close();
    t.arena.deinit();
    state.ctx.gpa.destroy(t);
    logf("terminal closed", .{});
}

/// Hang up terminals whose page has been gone longer than the grace period.
fn reapLoop(state: *State) void {
    const ctx = state.ctx;
    while (true) {
        ctx.sleepMs(30_000);
        const now = ctx.nowSeconds();
        state.mutex.lockUncancelable(ctx.io);
        defer state.mutex.unlock(ctx.io);
        for (state.terms.items) |t| {
            t.mutex.lockUncancelable(ctx.io);
            defer t.mutex.unlock(ctx.io);
            if (t.ws == null and now - t.detached_at > detach_grace_s) {
                // The chooser and any tmux client it started; the pump sees
                // EOF once they are gone.
                std.posix.kill(-t.pty.pid, .HUP) catch {};
            }
        }
    }
}

/// Bridge a WebSocket to the page's terminal: its `cl list` on a
/// pseudo-terminal, new or (when the page reconnects with the same id) kept
/// from its last connection. Client messages: "0<input bytes>",
/// "1<cols>,<rows>", "2<1 hidden | 0 shown>", "3" (are you there?). Server
/// sends "new" or "resumed" as text first, then output as binary.
fn serveTerminal(state: *State, req: *std.http.Server.Request, key: []const u8) !void {
    const ctx = state.ctx;
    // Copied: reading from the socket reuses the buffer the request is in.
    var id_buf: [32]u8 = undefined;
    const raw_id = termId(req.head.target);
    @memcpy(id_buf[0..raw_id.len], raw_id);
    const term_id = id_buf[0..raw_id.len];
    var attach_buf: [64]u8 = undefined;
    const raw_attach = attachTarget(req.head.target);
    @memcpy(attach_buf[0..raw_attach.len], raw_attach);
    const attach = attach_buf[0..raw_attach.len];
    var ws = try req.respondWebSocket(.{ .key = key });
    try ws.flush();

    // The page sends its size first; start the chooser at that size.
    var cols: u16 = 80;
    var rows: u16 = 24;
    const first = ws.readSmallMessage() catch return;
    if (first.data.len > 0 and first.data[0] == '1') parseSize(first.data[1..], &cols, &rows);

    const t, const fresh = acquireTerminal(state, term_id, attach, cols, rows) catch return;
    defer releaseTerminal(state, t);
    const tty = t.pty.tty;
    {
        t.mutex.lockUncancelable(ctx.io);
        defer t.mutex.unlock(ctx.io);
        // Another connection still holds it (a duplicated tab, or a socket
        // the phone dropped without a word): send that page away.
        if (t.ws) |old| old.writeMessage("", .connection_close) catch {};
        t.ws = &ws;
        // The page resets its terminal only for a new one: a resumed one
        // keeps the modes (mouse reporting, say) its programs turned on.
        ws.writeMessage(if (fresh) "new" else "resumed", .text) catch {};
    }
    // Repaint for the new page: tmux redraws its client on request, and with
    // no client on this tty the chooser is in front, which redraws on Ctrl-L.
    t.pty.resize(cols, rows);
    tmux.runQuiet(ctx, &.{ "refresh-client", "-t", tty }) catch t.pty.write("\x0c");

    while (true) {
        const msg = ws.readSmallMessage() catch break;
        if (msg.data.len == 0) continue;
        t.mutex.lockUncancelable(ctx.io);
        const current = t.ws == &ws;
        if (current and msg.data[0] == '3') ws.writeMessage("", .binary) catch {};
        t.mutex.unlock(ctx.io);
        if (!current) break;
        switch (msg.data[0]) {
            '0' => t.pty.write(msg.data[1..]),
            '1' => {
                parseSize(msg.data[1..], &cols, &rows);
                t.pty.resize(cols, rows);
            },
            // The page was hidden ("21") or shown ("20"). With window-size
            // latest, a resize alone (the keyboard or address bar on a phone)
            // makes this client the one that sizes the window, shrinking it on
            // the desktop. While hidden, it doesn't count.
            '2' => {
                const flag = if (std.mem.eql(u8, msg.data[1..], "1")) "ignore-size" else "!ignore-size";
                tmux.runQuiet(ctx, &.{ "refresh-client", "-t", tty, "-f", flag }) catch {};
            },
            else => {},
        }
    }
    t.mutex.lockUncancelable(ctx.io);
    const was_current = t.ws == &ws;
    if (was_current) {
        t.ws = null;
        t.detached_at = ctx.nowSeconds();
    }
    t.mutex.unlock(ctx.io);
    // Detached, its size shouldn't drive the session's window either.
    if (was_current) tmux.runQuiet(ctx, &.{ "refresh-client", "-t", tty, "-f", "ignore-size" }) catch {};
}

/// The page's terminal id, from `/ws?t=<id>`: up to 32 letters and digits.
fn termId(target: []const u8) []const u8 {
    const q = std.mem.indexOf(u8, target, "?t=") orelse return "";
    const v = target[q + 3 ..];
    const v_end = std.mem.indexOfScalar(u8, v, '&') orelse v.len;
    const val = v[0..v_end];
    if (val.len > 32) return "";
    for (val) |c| if (!std.ascii.isAlphanumeric(c)) return "";
    return val;
}

/// `/ws?a=operator` opens the operator, creating it if needed.
const operator_target = "operator";

/// The session to open, from `/ws?t=<id>&a=<tmux name>`: letters, digits, - and _.
fn attachTarget(target: []const u8) []const u8 {
    const q = std.mem.indexOf(u8, target, "&a=") orelse return "";
    const v = target[q + 3 ..];
    const val = v[0 .. std.mem.indexOfScalar(u8, v, '&') orelse v.len];
    if (val.len > 64) return "";
    for (val) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return "";
    return val;
}

test attachTarget {
    try std.testing.expectEqualStrings("cl_qa-1_ab12", attachTarget("/ws?t=x&a=cl_qa-1_ab12"));
    try std.testing.expectEqualStrings("", attachTarget("/ws?t=x&a=a;b"));
    try std.testing.expectEqualStrings("", attachTarget("/ws?t=x"));
}

test termId {
    try std.testing.expectEqualStrings("ab12", termId("/ws?t=ab12"));
    try std.testing.expectEqualStrings("ab12", termId("/ws?t=ab12&x=1"));
    try std.testing.expectEqualStrings("", termId("/ws"));
    try std.testing.expectEqualStrings("", termId("/ws?t=a/b"));
}

/// Copy the terminal's output to whichever page holds it, until the chooser
/// exits (q, or hung up after the grace period).
fn pumpOutput(state: *State, t: *Terminal) void {
    const io = state.ctx.io;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = t.pty.read(&buf);
        if (n == 0) break;
        t.mutex.lockUncancelable(io);
        defer t.mutex.unlock(io);
        // Output while detached is dropped; reattaching repaints.
        if (t.ws) |ws| ws.writeMessage(buf[0..n], .binary) catch {};
    }
    state.mutex.lockUncancelable(io);
    for (state.terms.items, 0..) |x, i| if (x == t) {
        _ = state.terms.swapRemove(i);
        break;
    };
    state.mutex.unlock(io);
    {
        // Tell the page it's over, and let no one else attach.
        t.mutex.lockUncancelable(io);
        defer t.mutex.unlock(io);
        if (t.ws) |ws| ws.writeMessage("", .connection_close) catch {};
    }
    releaseTerminal(state, t);
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
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];
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
    const posix = std.posix;
    std.Io.File.stderr().writeStreamingAll(ctx.io, prompt) catch {};
    const saved: ?posix.termios = posix.tcgetattr(0) catch null;
    if (saved) |t| {
        var quiet = t;
        quiet.lflag.ECHO = false;
        posix.tcsetattr(0, .NOW, quiet) catch {};
    }
    defer if (saved) |t| {
        posix.tcsetattr(0, .NOW, t) catch {};
        std.Io.File.stderr().writeStreamingAll(ctx.io, "\n") catch {};
    };
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        const got = posix.read(0, &c) catch break;
        if (got == 0 or c[0] == '\n') break;
        buf[n] = c[0];
        n += 1;
    }
    return std.mem.trimEnd(u8, buf[0..n], "\r");
}

/// Server log line, timestamped.
fn logLine(text: []const u8) void {
    logf("{s}", .{text});
}

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
