//! Claude-specific bits: the per-process session registry Claude writes under
//! <config_dir>/sessions/<pid>.json, launch arguments, and prompt readiness.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const config = @import("config.zig");

pub const Status = enum {
    busy,
    idle,
    blocked,
    starting,
    gone,
    unknown,

    pub fn label(s: Status) []const u8 {
        return @tagName(s);
    }

    /// Display order in the chooser: sessions that need a human come first.
    pub fn rank(s: Status) u8 {
        return switch (s) {
            .blocked => 0,
            .busy => 1,
            .idle => 2,
            .starting => 3,
            .unknown => 4,
            .gone => 5,
        };
    }

    pub fn groupLabel(s: Status) []const u8 {
        return switch (s) {
            .blocked => "NEEDS INPUT",
            .busy => "WORKING",
            .idle => "IDLE",
            .starting => "STARTING",
            .unknown => "UNKNOWN",
            .gone => "GONE",
        };
    }
};

const Registry = struct {
    pid: ?i64 = null,
    tmux: ?[]const u8 = null,
    status: ?[]const u8 = null,
    state: ?[]const u8 = null,
    name: ?[]const u8 = null,
    nameSource: ?[]const u8 = null,
    statusUpdatedAt: ?i64 = null,
};

/// What Claude reports about one of our sessions (same source `claude agents` uses).
pub const Info = struct {
    status: Status,
    /// Claude's own session name (auto-generated summary or user-set).
    name: []const u8,
    /// Unix ms of the last status change, 0 if unknown.
    status_since_ms: i64,
};

pub const StatusMap = std.StringHashMapUnmanaged(Info);

/// Read every profile's registry; keys are tmux session names. Strings live in `arena`.
pub fn readStatuses(ctx: Ctx, arena: std.mem.Allocator, cfg: config.Config) !StatusMap {
    var map: StatusMap = .empty;
    for (cfg.profiles) |p| {
        const dir_path = try std.fmt.allocPrint(arena, "{s}/sessions", .{p.config_dir orelse try defaultConfigDir(ctx, arena)});
        var dir = std.Io.Dir.openDirAbsolute(ctx.io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const data = dir.readFileAlloc(ctx.io, entry.name, arena, .limited(64 * 1024)) catch continue;
            const reg = std.json.parseFromSliceLeaky(Registry, arena, data, .{ .ignore_unknown_fields = true }) catch continue;
            const target = reg.tmux orelse continue;
            if (!std.mem.startsWith(u8, target, tmux.prefix)) continue;
            if (reg.pid) |pid| if (!pidAlive(ctx, pid)) continue;
            const colon = std.mem.indexOfScalar(u8, target, ':') orelse target.len;
            const key = try arena.dupe(u8, target[0..colon]);
            const st = parseStatus(reg.status orelse reg.state orelse "");
            try map.put(arena, key, .{
                .status = st,
                .name = try arena.dupe(u8, reg.name orelse ""),
                .status_since_ms = reg.statusUpdatedAt orelse 0,
            });
        }
    }
    return map;
}

fn defaultConfigDir(ctx: Ctx, arena: std.mem.Allocator) ![]const u8 {
    if (ctx.env.get("CLAUDE_CONFIG_DIR")) |d| return d;
    return std.fmt.allocPrint(arena, "{s}/.claude", .{ctx.home});
}

fn parseStatus(s: []const u8) Status {
    if (std.mem.eql(u8, s, "busy")) return .busy;
    if (std.mem.eql(u8, s, "idle")) return .idle;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "running")) return .busy;
    if (std.mem.eql(u8, s, "waiting")) return .blocked;
    return .unknown;
}

fn pidAlive(ctx: Ctx, pid: i64) bool {
    var buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}", .{pid}) catch return false;
    std.Io.Dir.accessAbsolute(ctx.io, path, .{}) catch return false;
    return true;
}

/// Decide the displayed status for one session.
pub fn statusFor(ctx: Ctx, map: StatusMap, s: tmux.Session) Status {
    if (s.pane_dead) return .gone;
    if (map.get(s.tmux_name)) |info| if (info.status != .unknown) return info.status;
    // Fallback: Claude puts a Braille spinner (U+2800..U+28FF) in the title while working.
    if (hasBraille(s.pane_title)) return .busy;
    if (ctx.nowSeconds() - s.created < 120) return .starting;
    return .unknown;
}

fn hasBraille(s: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x2800 and cp <= 0x28FF) return true;
    }
    return false;
}

pub fn uuid4(ctx: Ctx, buf: *[36]u8) []const u8 {
    var b: [16]u8 = undefined;
    ctx.io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return std.fmt.bufPrint(buf, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) catch unreachable;
}

/// Does the pane show Claude's composer prompt? That is a line starting with
/// ">" or "❯" directly under the composer's top border (a run of "─"). Menu
/// cursors (trust dialog, pickers) also start with "❯" but have no border above.
pub fn promptVisible(text: []const u8) bool {
    var prev: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " ");
        defer prev = line;
        // The composer puts a non-breaking space after the marker, so only check the marker.
        const is_prompt = std.mem.startsWith(u8, line, ">") or std.mem.startsWith(u8, line, "❯");
        if (is_prompt and std.mem.indexOf(u8, prev, "──") != null) return true;
    }
    return false;
}

test "promptVisible ignores menus" {
    try std.testing.expect(promptVisible("──────\n❯ \n──────\n"));
    try std.testing.expect(promptVisible("────\n❯\u{a0}Try \"edit\"\n"));
    try std.testing.expect(!promptVisible("Security guide\n ❯ No, exit\n   Yes, I trust this folder\n"));
    try std.testing.expect(!promptVisible("\n  ❯ 1. Yes\n    2. Not now\n"));
}

/// Wait (up to 60 s) for the prompt, then type `message` and press Enter.
pub fn sendInitialMessage(ctx: Ctx, tmux_name: []const u8, message: []const u8) !void {
    var tries: usize = 0;
    while (tries < 300) : (tries += 1) {
        const text = tmux.capturePlain(ctx, tmux_name) catch return error.TmuxFailed;
        defer ctx.gpa.free(text);
        if (promptVisible(text)) break;
        ctx.sleepMs(200);
    } else return error.PromptTimeout;
    ctx.sleepMs(300);
    try tmux.sendLine(ctx, tmux_name, message);
    // If the text is still sitting in the composer after a moment, press Enter again.
    ctx.sleepMs(1500);
    const text = tmux.capturePlain(ctx, tmux_name) catch return;
    defer ctx.gpa.free(text);
    const tail = message[0..@min(message.len, 40)];
    if (std.mem.indexOf(u8, text, tail) != null and promptVisible(text)) {
        tmux.runQuiet(ctx, &.{ "send-keys", "-t", tmux_name, "Enter" }) catch {};
    }
}

/// Does the passthrough argument list already choose a session (resume/continue)?
pub fn argsPickSession(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--resume") or std.mem.eql(u8, a, "-r") or
            std.mem.eql(u8, a, "--continue") or std.mem.eql(u8, a, "-c") or
            std.mem.eql(u8, a, "--session-id")) return true;
    }
    return false;
}
