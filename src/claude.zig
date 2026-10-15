//! Claude-specific bits: the per-process session registry Claude writes under
//! <config_dir>/sessions/<pid>.json, launch arguments, and prompt readiness.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const config = @import("config.zig");

pub const Status = enum {
    busy,
    /// Idle at the prompt, but a background shell task (e.g. a dev server) is still running.
    shell,
    /// Background session waiting on something external.
    waiting,
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
            .idle => 0,
            .shell => 1,
            .blocked => 2,
            .waiting => 3,
            .starting => 4,
            .unknown => 5,
            .gone => 6,
            .busy => 7,
        };
    }

    pub fn groupLabel(s: Status) []const u8 {
        return switch (s) {
            .blocked => "NEEDS INPUT",
            .busy => "WORKING",
            .waiting => "WAITING",
            .shell => "IDLE, BACKGROUND TASKS RUNNING",
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
    updatedAt: ?i64 = null,
    sessionId: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

/// What Claude reports about one of our sessions (same source `claude agents` uses).
pub const Info = struct {
    status: Status,
    /// Claude's own session name (auto-generated summary or user-set).
    name: []const u8,
    /// Unix ms of the last status change, 0 if unknown.
    status_since_ms: i64,
    /// Unix ms of the last registry update, 0 if unknown.
    updated_ms: i64,
    /// Start of Claude's most recent reply (whitespace squashed), "" if unknown.
    summary: []const u8,
    /// Claude's current session id, "" if unknown.
    session_id: []const u8,
};

pub const StatusMap = std.StringHashMapUnmanaged(Info);

/// Read every profile's registry; keys are tmux session names. Strings live in `arena`.
pub fn readStatuses(ctx: Ctx, arena: std.mem.Allocator, cfg: config.Config) !StatusMap {
    var map: StatusMap = .empty;
    for (cfg.profiles) |p| {
        const config_dir = p.config_dir orelse try defaultConfigDir(ctx, arena);
        const dir_path = try std.fmt.allocPrint(arena, "{s}/sessions", .{config_dir});
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
                .updated_ms = reg.updatedAt orelse 0,
                .summary = lastReply(ctx, arena, config_dir, reg.cwd, reg.sessionId) catch "",
                .session_id = try arena.dupe(u8, reg.sessionId orelse ""),
            });
        }
    }
    return map;
}

/// Claude stores transcripts under <config>/projects/<cwd with non-alphanumerics as '-'>/<sessionId>.jsonl.
pub fn transcriptPath(arena: std.mem.Allocator, config_dir: []const u8, cwd: []const u8, session_id: []const u8) ![]const u8 {
    const enc = try arena.dupe(u8, cwd);
    for (enc) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
        c.* = '-';
    };
    return std.fmt.allocPrint(arena, "{s}/projects/{s}/{s}.jsonl", .{ config_dir, enc, session_id });
}

/// Tool results can be large; look back far enough to find Claude's last prose.
const tail_bytes = 256 * 1024;

/// Read the last assistant text block from the session transcript.
pub fn lastReply(ctx: Ctx, arena: std.mem.Allocator, config_dir: []const u8, cwd: ?[]const u8, session_id: ?[]const u8) ![]const u8 {
    const path = try transcriptPath(arena, config_dir, cwd orelse return "", session_id orelse return "");
    const file = try std.Io.Dir.openFileAbsolute(ctx.io, path, .{});
    defer file.close(ctx.io);
    const len = try file.length(ctx.io);
    const start = len -| tail_bytes;
    const buf = try arena.alloc(u8, @intCast(len - start));
    const n = try file.readPositionalAll(ctx.io, buf, start);
    var data = buf[0..n];
    // A tail that starts mid-file begins with a partial line; drop it.
    if (start > 0) {
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return "";
        data = data[nl + 1 ..];
    }
    return lastAssistantText(arena, data);
}

/// Scan JSONL from the end for the newest assistant message with a text block.
pub fn lastAssistantText(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        const obj = switch (parsed) {
            .object => |o| o,
            else => continue,
        };
        const kind = obj.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "assistant")) continue;
        const msg = obj.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            const pt = part.object.get("type") orelse continue;
            if (pt != .string or !std.mem.eql(u8, pt.string, "text")) continue;
            const text = part.object.get("text") orelse continue;
            if (text != .string) continue;
            return squash(arena, text.string);
        }
    }
    return "";
}

/// Collapse runs of whitespace (including newlines) into single spaces.
fn squash(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_space = true;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!in_space) try out.append(arena, ' ');
            in_space = true;
        } else {
            try out.append(arena, c);
            in_space = false;
        }
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

test "lastAssistantText picks the newest text block" {
    const data =
        \\{"type":"user","message":{"content":"hi"}}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Hello\n  there"}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}
        \\not json
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try lastAssistantText(arena_state.allocator(), data);
    try std.testing.expectEqualStrings("Hello there", got);
    try std.testing.expectEqualStrings("/c/projects/-home-u-a-b/sid.jsonl", try transcriptPath(arena_state.allocator(), "/c", "/home/u/a.b", "sid"));
}

pub fn defaultConfigDir(ctx: Ctx, arena: std.mem.Allocator) ![]const u8 {
    if (ctx.env.get("CLAUDE_CONFIG_DIR")) |d| return d;
    return std.fmt.allocPrint(arena, "{s}/.claude", .{ctx.home});
}

fn parseStatus(s: []const u8) Status {
    if (std.mem.eql(u8, s, "busy")) return .busy;
    if (std.mem.eql(u8, s, "idle")) return .idle;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "shell")) return .shell;
    if (std.mem.eql(u8, s, "waiting")) return .waiting;
    if (std.mem.eql(u8, s, "running") or std.mem.eql(u8, s, "working")) return .busy;
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
