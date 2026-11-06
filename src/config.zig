//! Profiles: a name -> Claude config dir mapping, read from ~/.config/cl/config.
//!
//!   default = work
//!   operator = work
//!   work = ~/.claude-work
//!   personal = ~/.claude
//!
//!   web.autostart = true
//!   web.listen = 127.0.0.1:8421, tailscale:8421
//!   web.password = $argon2id$...      (from `cl web hash`)
//!   web.font_size = 16                  (board and terminal text, px)
//!
//!   board.dir = ~/.local/state/cl       (where board.db lives)
//!   board.worktrees = ~/.local/share/cl/worktrees
//!   board.dispatch = true                (cl web starts queued tickets)
//!   board.trust_projects = true          (yes to Claude's folder-trust dialog in project folders and
//!                                          ticket worktrees; board.trust_worktrees is the old name)
//!
//!   gutter.path = ~/bin/gutter           (gutter for reviews; "" looks it up on PATH)
//!
//!   tmux.socket = /run/user/1000/cl-try/tmux   (tmux -S for every tmux call; CL_TMUX_SOCKET overrides)
//!
//! `default`, `operator` and dotted keys are settings; every other key is a
//! profile. `operator` picks the operator's profile and falls back to `default`.
//!
//! When CLAUDE_CONFIG_DIR is set in the environment it overrides `default`:
//! the profile with that directory is used, or one named after the directory
//! is added if none matches.
//!
//! When CL_PORT is set (or `cl web --port` is given) it replaces the port of
//! every web.listen entry, for running a second `cl web` next to the main one:
//! see `overridePort`.
const std = @import("std");
const Ctx = @import("ctx.zig");

pub const Profile = struct {
    name: []const u8,
    /// Absolute Claude config dir, or null to leave CLAUDE_CONFIG_DIR alone.
    config_dir: ?[]const u8,
};

pub const Config = struct {
    profiles: []Profile,
    default: []const u8,
    /// Profile for the operator session. Not affected by CLAUDE_CONFIG_DIR.
    operator: []const u8,
    web: Web = .{},
    board: Board = .{},
    gutter: Gutter = .{},
    tmux: Tmux = .{},

    pub fn find(self: Config, name: []const u8) ?Profile {
        for (self.profiles) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    pub fn defaultProfile(self: Config) Profile {
        return self.find(self.default) orelse self.profiles[0];
    }

    /// Serve on `port` instead of the configured one, on every web.listen
    /// host, as a second server next to the main one (trying a branch's
    /// build, say). That one keeps the board's dispatcher and web.autostart:
    /// two dispatchers on one board.db would start each ticket twice.
    pub fn overridePort(self: *Config, alloc: std.mem.Allocator, port: u16) !void {
        self.web.listen = try withPort(alloc, self.web.listen, port);
        self.web.port = port;
        self.web.autostart = false;
        self.board.dispatch = false;
    }
};

pub const Web = struct {
    /// Start `cl web` in the background whenever cl launches, lists or attaches.
    autostart: bool = false,
    /// Comma-separated host:port list; the host `tailscale` means this machine's tailnet IPv4.
    listen: []const u8 = "127.0.0.1:8421",
    /// argon2id PHC string; the server refuses to start without one.
    password: []const u8 = "",
    /// Base text size of the board and the terminal page, in px; the board's
    /// whole layout scales with it. 14 was the size before this setting.
    font_size: u8 = 16,
    /// Set by `overridePort` (CL_PORT, `cl web --port`): this is a second
    /// server next to the one on the configured port.
    port: ?u16 = null,
};

pub const Board = struct {
    /// Directory holding board.db; "" means ~/.local/state/cl.
    dir: []const u8 = "",
    /// Where ticket worktrees go, as <worktrees>/<project>/<key>; "" means
    /// ~/.local/share/cl/worktrees.
    worktrees: []const u8 = "",
    /// `cl web` starts queued tickets (the dispatcher).
    dispatch: bool = true,
    /// Say yes to Claude's folder-trust dialog when the dispatcher starts a
    /// session in a project's folder or a ticket worktree.
    trust_projects: bool = true,
};

pub const Gutter = struct {
    /// The gutter binary reviews open in; "" means `gutter` on PATH. A path
    /// that isn't an executable file counts as gutter not being installed.
    path: []const u8 = "",
};

pub const Tmux = struct {
    /// Absolute path of the tmux server's socket, passed as `tmux -S` on
    /// every call; "" for tmux's default server. CL_TMUX_SOCKET overrides it.
    /// For sandboxes: see `tmux.configure`.
    socket: []const u8 = "",
};

pub fn load(ctx: Ctx) !Config {
    var cfg = try loadFile(ctx);
    if (ctx.env.get("CL_PORT")) |v| if (v.len > 0) {
        const port = std.fmt.parseInt(u16, v, 10) catch {
            std.debug.print("cl: CL_PORT is not a port: {s}\n", .{v});
            std.process.exit(1);
        };
        try cfg.overridePort(ctx.perm, port);
    };
    return cfg;
}

fn loadFile(ctx: Ctx) !Config {
    const path = try std.fmt.allocPrint(ctx.perm, "{s}/.config/cl/config", .{ctx.home});
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.perm, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return fallback(ctx),
        else => return err,
    };

    var profiles: std.ArrayList(Profile) = .empty;
    var default: ?[]const u8 = null;
    var operator: ?[]const u8 = null;
    var web: Web = .{};
    var board: Board = .{};
    var gutter: Gutter = .{};
    var tmux: Tmux = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "default")) {
            default = val;
        } else if (std.mem.eql(u8, key, "operator")) {
            operator = val;
        } else if (std.mem.eql(u8, key, "web.autostart")) {
            web.autostart = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "on");
        } else if (std.mem.eql(u8, key, "web.listen")) {
            web.listen = val;
        } else if (std.mem.eql(u8, key, "web.password")) {
            web.password = val;
        } else if (std.mem.eql(u8, key, "web.font_size")) {
            const size = std.fmt.parseInt(u8, val, 10) catch web.font_size;
            web.font_size = std.math.clamp(size, 8, 40);
        } else if (std.mem.eql(u8, key, "board.dir")) {
            board.dir = try expandHomePerm(ctx, val);
        } else if (std.mem.eql(u8, key, "board.worktrees")) {
            board.worktrees = try expandHomePerm(ctx, val);
        } else if (std.mem.eql(u8, key, "board.trust_projects") or std.mem.eql(u8, key, "board.trust_worktrees")) {
            board.trust_projects = !(std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "off"));
        } else if (std.mem.eql(u8, key, "board.dispatch")) {
            board.dispatch = !(std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "off"));
        } else if (std.mem.eql(u8, key, "gutter.path")) {
            gutter.path = try expandHomePerm(ctx, val);
        } else if (std.mem.eql(u8, key, "tmux.socket")) {
            tmux.socket = try expandHomePerm(ctx, val);
        } else if (std.mem.indexOfScalar(u8, key, '.') != null) {
            continue; // unknown setting
        } else {
            try profiles.append(ctx.perm, .{ .name = key, .config_dir = try expandHomePerm(ctx, val) });
        }
    }
    if (profiles.items.len == 0) {
        var c = try fallback(ctx);
        c.web = web;
        c.board = board;
        c.gutter = gutter;
        c.tmux = tmux;
        return c;
    }
    const operator_profile = operator orelse default orelse profiles.items[0].name;
    if (ctx.env.get("CLAUDE_CONFIG_DIR")) |env_dir| {
        default = try fromEnv(ctx, &profiles, env_dir);
    }
    return .{
        .profiles = try profiles.toOwnedSlice(ctx.perm),
        .default = default orelse profiles.items[0].name,
        .operator = operator_profile,
        .web = web,
        .board = board,
        .gutter = gutter,
        .tmux = tmux,
    };
}

/// Return the name of the profile whose config dir is `env_dir`, adding one if needed.
fn fromEnv(ctx: Ctx, profiles: *std.ArrayList(Profile), env_dir: []const u8) ![]const u8 {
    const want = std.mem.trimEnd(u8, try expandHomePerm(ctx, env_dir), "/");
    for (profiles.items) |p| {
        const have = std.mem.trimEnd(u8, p.config_dir orelse continue, "/");
        if (std.mem.eql(u8, have, want)) return p.name;
    }
    const base = std.fs.path.basename(want);
    const name = std.mem.trimStart(u8, base, ".");
    try profiles.append(ctx.perm, .{ .name = if (name.len > 0) name else "env", .config_dir = want });
    return profiles.items[profiles.items.len - 1].name;
}

/// `listen` with each host:port entry's port replaced by `port`. Entries
/// without a port are kept for the server to reject.
fn withPort(alloc: std.mem.Allocator, listen: []const u8, port: u16) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, listen, ',');
    while (it.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        if (text.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(alloc, ", ");
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse {
            try out.appendSlice(alloc, text);
            continue;
        };
        try out.print(alloc, "{s}:{d}", .{ text[0..colon], port });
    }
    return out.toOwnedSlice(alloc);
}

test withPort {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "127.0.0.1:8421", "127.0.0.1:8422" },
        .{ "127.0.0.1:8421, tailscale:8421", "127.0.0.1:8422, tailscale:8422" },
        .{ "[::1]:8421,0.0.0.0:9000", "[::1]:8422, 0.0.0.0:8422" },
        .{ "nonsense", "nonsense" },
    };
    for (cases) |c| {
        const got = try withPort(a, c[0], 8422);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "overridePort makes a second server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{ .profiles = &.{}, .default = "", .operator = "", .web = .{ .autostart = true } };
    try cfg.overridePort(arena.allocator(), 8422);
    try std.testing.expectEqualStrings("127.0.0.1:8422", cfg.web.listen);
    try std.testing.expectEqual(@as(?u16, 8422), cfg.web.port);
    try std.testing.expect(!cfg.web.autostart);
    try std.testing.expect(!cfg.board.dispatch);
}

fn fallback(ctx: Ctx) !Config {
    const profiles = try ctx.perm.alloc(Profile, 1);
    profiles[0] = .{ .name = "default", .config_dir = null };
    return .{ .profiles = profiles, .default = "default", .operator = "default" };
}

fn expandHomePerm(ctx: Ctx, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        return std.fmt.allocPrint(ctx.perm, "{s}{s}", .{ ctx.home, path[1..] });
    }
    return path;
}
