//! Profiles: a name -> Claude config dir mapping, read from ~/.config/cl/config.
//!
//!   default = work
//!   operator = work
//!   operator.model = sonnet            (the operator's model; default: the profile's)
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
//!   board.todo_project = me              (the project `cl todo` puts todos in)
//!   board.morning = 08:00                (when a todo due or reminded on a date, with no time, comes up)
//!
//!   gutter.path = ~/bin/gutter           (gutter for reviews; "" looks it up on PATH)
//!   review.model = sonnet                (the automated reviewer's model; default: the profile's)
//!
//!   tmux.socket = /run/user/1000/cl-try/tmux   (tmux -S for every tmux call; CL_TMUX_SOCKET overrides)
//!
//!   voice.stt = whisper-cli -m ~/.local/share/whisper/ggml-base.en.bin -nt -np -f
//!   voice.tts = ~/.local/bin/piper -m ~/.local/share/piper/en_US-lessac-medium.onnx -f
//!               (or http://127.0.0.1:5005/synthesize, a resident Piper server)
//!   voice.tts_voice = en_GB-alba-medium  (with a server: which of its voices)
//!   voice.tts_speed = 1.2               (speaking speed; 1 is normal)
//!   voice.tts_pitch = 1.08              (a bit higher; the board shifts it)
//!   voice.model = haiku                 (the voice operator's model; the default)
//!                                        (talking to the operator from the board: see voice.zig)
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
const when = @import("when.zig");

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
    /// `operator.model`: the operator's Claude model (`--model`, e.g. sonnet);
    /// "" leaves it to the profile's default.
    operator_model: []const u8 = "",
    /// `review.model`: the automated reviewer's Claude model (autoreview.zig);
    /// "" leaves it to the profile's default.
    review_model: []const u8 = "",
    web: Web = .{},
    board: Board = .{},
    gutter: Gutter = .{},
    tmux: Tmux = .{},
    voice: Voice = .{},

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
    /// The project `cl todo` puts todos in when it isn't given one; "" for
    /// none (then the only project that isn't a code repo, if there is one).
    todo_project: []const u8 = "",
    /// When a todo's date with no time comes up (its reminder, or showing
    /// as due), in minutes after local midnight: `board.morning = 08:00`.
    morning: i64 = when.default_morning,
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

/// Talking to the operator from the board (voice.zig). Both are shell
/// commands; the file they read or write is added as the last argument.
pub const Voice = struct {
    /// Speech to text: gets a 16 kHz mono WAV file, prints the words. ""
    /// turns voice off (the board shows no mic button).
    stt: []const u8 = "",
    /// Text to speech: gets the text on stdin, writes a WAV file; or the URL
    /// of a TTS server (Piper's `.../synthesize`), which keeps the model
    /// loaded. "" leaves speaking to the browser.
    tts: []const u8 = "",
    /// With a URL `tts`: the voice to ask it for (Piper: a model name in its
    /// --data-dir, like en_GB-alba-medium); "" for the server's own.
    tts_voice: []const u8 = "",
    /// How fast the answer is spoken: 1 is normal, 1.2 is 20% faster. With
    /// a URL `tts` it is Piper's length_scale (1 / speed); the browser's own
    /// voice uses it as its rate.
    tts_speed: f32 = 1,
    /// Raise (or lower) the voice: the board plays each clip this much faster
    /// without keeping its pitch (1.08 is about a semitone up). With a URL
    /// `tts`, the speech is made that much slower first, so `tts_speed` holds.
    tts_pitch: f32 = 1,
    /// The voice operator's Claude model (`--model`): voice messages go to a
    /// session of their own (operator.zig), so the chat keeps `operator.model`.
    /// "" for the profile's default.
    model: []const u8 = "haiku",
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
    var operator_model: []const u8 = "";
    var review_model: []const u8 = "";
    var web: Web = .{};
    var board: Board = .{};
    var gutter: Gutter = .{};
    var tmux: Tmux = .{};
    var voice: Voice = .{};
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
        } else if (std.mem.eql(u8, key, "operator.model")) {
            operator_model = val;
        } else if (std.mem.eql(u8, key, "review.model")) {
            review_model = val;
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
        } else if (std.mem.eql(u8, key, "board.todo_project")) {
            board.todo_project = val;
        } else if (std.mem.eql(u8, key, "board.morning")) {
            board.morning = when.parseMorning(val) orelse board.morning;
        } else if (std.mem.eql(u8, key, "board.dispatch")) {
            board.dispatch = !(std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "off"));
        } else if (std.mem.eql(u8, key, "gutter.path")) {
            gutter.path = try expandHomePerm(ctx, val);
        } else if (std.mem.eql(u8, key, "tmux.socket")) {
            tmux.socket = try expandHomePerm(ctx, val);
        } else if (std.mem.eql(u8, key, "voice.stt")) {
            voice.stt = val;
        } else if (std.mem.eql(u8, key, "voice.tts")) {
            voice.tts = val;
        } else if (std.mem.eql(u8, key, "voice.model")) {
            voice.model = val;
        } else if (std.mem.eql(u8, key, "voice.tts_voice")) {
            voice.tts_voice = val;
        } else if (std.mem.eql(u8, key, "voice.tts_speed")) {
            const speed = std.fmt.parseFloat(f32, val) catch 1;
            voice.tts_speed = std.math.clamp(speed, 0.5, 2);
        } else if (std.mem.eql(u8, key, "voice.tts_pitch")) {
            const pitch = std.fmt.parseFloat(f32, val) catch 1;
            voice.tts_pitch = std.math.clamp(pitch, 0.8, 1.25);
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
        c.voice = voice;
        c.operator_model = operator_model;
        c.review_model = review_model;
        return c;
    }
    const operator_profile = operator orelse default orelse profiles.items[0].name;
    if (ctx.env.get("CLAUDE_CONFIG_DIR")) |env_dir| {
        default = try fromEnv(ctx, &profiles, env_dir);
    }
    // Before toOwnedSlice, which empties `profiles`.
    const default_profile = default orelse profiles.items[0].name;
    return .{
        .profiles = try profiles.toOwnedSlice(ctx.perm),
        .default = default_profile,
        .operator = operator_profile,
        .operator_model = operator_model,
        .review_model = review_model,
        .web = web,
        .board = board,
        .gutter = gutter,
        .tmux = tmux,
        .voice = voice,
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

test "voice.model: haiku by default, set or emptied in the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = &env, .home = home };
    try tmp.dir.createDirPath(std.testing.io, ".config/cl");
    const cases = [_]struct { file: []const u8, model: []const u8 }{
        .{ .file = "w = /tmp/w\noperator.model = opus\n", .model = "haiku" },
        .{ .file = "w = /tmp/w\noperator.model = opus\nvoice.model = sonnet\n", .model = "sonnet" },
        .{ .file = "w = /tmp/w\noperator.model = opus\nvoice.model =\n", .model = "" },
    };
    for (cases) |c| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".config/cl/config", .data = c.file });
        const cfg = try loadFile(ctx);
        try std.testing.expectEqualStrings(c.model, cfg.voice.model);
        try std.testing.expectEqualStrings("w", cfg.default);
        try std.testing.expectEqualStrings("opus", cfg.operator_model);
    }
}
