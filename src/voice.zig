//! Talking to the operator from the web board (a prototype).
//!
//! The board records the human (a 16 kHz mono WAV), and `cl web` runs
//! `voice.stt` on it and types the words into the operator as
//! "[voice] <words>", the way the Quick Ticket button does. The operator's
//! instructions tell it to answer those with `cl say "<a sentence or two>"`,
//! which keeps the text on the operator's tmux session (@cl_say, stamped in
//! ms). The board polls for a newer one and plays it, through `voice.tts`
//! when that is set and the browser's own speech otherwise.
//!
//! The terminal page uses `voice.stt` too, to dictate into a session: it
//! gets the words back (POST /api/voice/text) and pastes them itself.
//!
//! Nothing here runs unless `voice.stt` is set: cl works the same without it.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");

/// Starts every message the operator gets by voice; its instructions key off it.
pub const prefix = "[voice] ";

/// Longest stretch of speech (or spoken reply) cl takes on.
pub const max_wav = 8 * 1024 * 1024; // ~4 minutes at 16 kHz, 16-bit mono
pub const max_say = 600;

/// Run `voice.stt` on a WAV and return the words, cleaned up (`cleanTranscript`).
pub fn transcribe(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, wav: []const u8) ![]const u8 {
    if (cfg.voice.stt.len == 0) return error.VoiceOff;
    const path = try tempPath(ctx, a, "wav");
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = wav });
    defer std.Io.Dir.deleteFileAbsolute(ctx.io, path) catch {};
    const script = try std.fmt.allocPrint(a, "{s} \"$1\" </dev/null", .{cfg.voice.stt});
    const out = try runCommand(ctx, a, &.{ "sh", "-c", script, "sh", path });
    return cleanTranscript(a, out);
}

/// Is `voice.tts` a URL (a resident TTS server) rather than a command?
pub fn ttsIsUrl(tts: []const u8) bool {
    return std.mem.startsWith(u8, tts, "http://") or std.mem.startsWith(u8, tts, "https://");
}

/// Run `voice.tts` on `text` and return the WAV it writes. When it is a URL
/// (Piper's HTTP server: `.../synthesize`), POST {"text": ...} to it instead,
/// so the model stays loaded between answers.
pub fn speak(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, text: []const u8) ![]const u8 {
    if (cfg.voice.tts.len == 0) return error.VoiceOff;
    if (ttsIsUrl(cfg.voice.tts)) return speakUrl(ctx, a, cfg.voice.tts, cfg.voice.tts_voice, cfg.voice.tts_speed / cfg.voice.tts_pitch, text);
    const path = try tempPath(ctx, a, "wav");
    defer std.Io.Dir.deleteFileAbsolute(ctx.io, path) catch {};
    const script = try std.fmt.allocPrint(a, "printf '%s\\n' \"$2\" | {s} \"$1\"", .{cfg.voice.tts});
    _ = try runCommand(ctx, a, &.{ "sh", "-c", script, "sh", path, text });
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(64 * 1024 * 1024)) catch {
        setLastError("it wrote no WAV file (does it take the output file as its last argument?)");
        return error.SpeechFailed;
    };
}

fn speakUrl(ctx: Ctx, a: std.mem.Allocator, url: []const u8, voice_name: []const u8, speed: f32, text: []const u8) ![]const u8 {
    last_error_len = 0;
    var client: std.http.Client = .{ .allocator = a, .io = ctx.io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(a);
    const payload = try ttsPayload(a, text, voice_name, speed);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &body.writer,
    }) catch |err| {
        std.log.err("voice: POST {s} failed: {s}", .{ url, @errorName(err) });
        setLastError(if (err == error.ConnectionRefused) "nothing answers at its URL (is the Piper server running?)" else @errorName(err));
        return error.SpeechFailed;
    };
    if (res.status != .ok) {
        std.log.err("voice: POST {s}: {d}\n{s}", .{ url, @intFromEnum(res.status), body.written() });
        setLastError(try std.fmt.allocPrint(a, "its server answered {d} {s}", .{ @intFromEnum(res.status), res.status.phrase() orelse "" }));
        return error.SpeechFailed;
    }
    return body.written();
}

/// {"text": ...}, plus "voice" when one is set and "length_scale" when the
/// speed isn't 1 (Piper's /synthesize: a shorter length is faster speech).
/// `speed` is tts_speed / tts_pitch: the board's pitch shift plays the clip
/// tts_pitch times faster, so it is made that much slower here.
fn ttsPayload(a: std.mem.Allocator, text: []const u8, voice_name: []const u8, speed: f32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try w.beginObject();
    try w.objectField("text");
    try w.write(text);
    if (voice_name.len > 0) {
        try w.objectField("voice");
        try w.write(voice_name);
    }
    if (speed != 1) {
        try w.objectField("length_scale");
        try w.print("{d:.3}", .{1 / speed});
    }
    try w.endObject();
    return out.written();
}

/// Why the last voice command on this thread failed: the last line of its
/// stderr ("sh: line 1: piper: command not found"), for the board to show.
threadlocal var last_error_buf: [300]u8 = undefined;
threadlocal var last_error_len: usize = 0;

pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

fn setLastError(text: []const u8) void {
    const t = lastLine(text);
    last_error_len = @min(t.len, last_error_buf.len);
    @memcpy(last_error_buf[0..last_error_len], t[0..last_error_len]);
}

/// The last non-empty line of a command's stderr.
fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    return std.mem.trim(u8, it.first(), " \t\r");
}

/// Run a voice command, giving up after a minute; its stdout. On failure the
/// whole stderr goes to the server's log and its last line to `lastError`.
fn runCommand(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    last_error_len = 0;
    const res = std.process.run(a, ctx.io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    }) catch |err| {
        std.log.err("voice: `{s}` failed: {s}", .{ argv[2], @errorName(err) });
        setLastError(if (err == error.Timeout) "it took over a minute" else @errorName(err));
        return error.SpeechFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        std.log.err("voice: `{s}` failed:\n{s}", .{ argv[2], std.mem.trim(u8, res.stderr, " \n") });
        setLastError(if (std.mem.trim(u8, res.stderr, " \t\r\n").len > 0) res.stderr else "it failed with no message");
        return error.SpeechFailed;
    }
    return res.stdout;
}

fn tempPath(ctx: Ctx, a: std.mem.Allocator, ext: []const u8) ![]const u8 {
    const dir = ctx.env.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const now = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    return std.fmt.allocPrint(a, "{s}/cl-voice-{d}-{d}.{s}", .{ dir, now, std.Thread.getCurrentId(), ext });
}

/// The words in a transcript: whitespace collapsed, and whisper's notes on
/// what it heard instead of speech ("[BLANK_AUDIO]", "(wind blowing)")
/// dropped. "" when nothing was said.
pub fn cleanTranscript(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    var space = false;
    for (raw) |c| {
        switch (c) {
            '[', '(' => depth += 1,
            ']', ')' => depth -|= 1,
            ' ', '\t', '\r', '\n' => space = true,
            else => if (depth == 0) {
                if (space and out.items.len > 0) try out.append(a, ' ');
                space = false;
                try out.append(a, c);
            },
        }
    }
    for (out.items) |c| if (std.ascii.isAlphanumeric(c) or c >= 0x80) return out.items;
    return "";
}

/// What the operator gets for spoken `words`.
pub fn message(a: std.mem.Allocator, words: []const u8) ![]const u8 {
    if (words.len == 0) return error.BadInput;
    return std.fmt.allocPrint(a, prefix ++ "{s}", .{words});
}

pub const Said = struct {
    /// When `cl say` ran, in ms since the epoch.
    at: i64,
    text: []const u8,
};

pub fn nowMs(ctx: Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
}

/// `cl say`: keep `text` as the operator's latest spoken reply. One line,
/// cut to `max_say` bytes.
pub fn say(ctx: Ctx, a: std.mem.Allocator, op_tmux: []const u8, text: []const u8) !void {
    const value = try std.fmt.allocPrint(a, "{d}\t{s}", .{ nowMs(ctx), try oneLine(a, text) });
    try tmux.runQuiet(ctx, &.{ "set-option", "-t", op_tmux, "@cl_say", value });
}

/// The operator's latest `cl say`, or null if it never said anything.
pub fn lastSaid(ctx: Ctx, a: std.mem.Allocator, op_tmux: []const u8) !?Said {
    const raw = tmux.run(ctx, &.{ "show-options", "-v", "-t", op_tmux, "@cl_say" }) catch return null;
    defer ctx.gpa.free(raw);
    return parseSaid(try a.dupe(u8, raw));
}

fn parseSaid(raw: []const u8) ?Said {
    const tab = std.mem.indexOfScalar(u8, raw, '\t') orelse return null;
    const at = std.fmt.parseInt(i64, raw[0..tab], 10) catch return null;
    return .{ .at = at, .text = raw[tab + 1 ..] };
}

fn oneLine(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const buf = try a.dupe(u8, t[0..@min(t.len, max_say)]);
    for (buf) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    return buf;
}

/// A short spoken stand-in when the operator answered without `cl say`:
/// the first sentence of its written reply, without markdown.
pub fn firstSentence(a: std.mem.Allocator, reply: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (reply) |c| {
        switch (c) {
            '*', '_', '`', '#', '>' => continue,
            ' ', '\t', '\r', '\n' => space = true,
            else => {
                if (space and out.items.len > 0) try out.append(a, ' ');
                space = false;
                try out.append(a, c);
                if ((c == '.' or c == '?' or c == '!') and out.items.len >= 20) break;
                if (out.items.len >= 200) break;
            },
        }
    }
    return out.items;
}

test cleanTranscript {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("What needs me?", try cleanTranscript(aa, "  What needs\n me?\n"));
    try std.testing.expectEqualStrings("", try cleanTranscript(aa, " [BLANK_AUDIO]\n"));
    try std.testing.expectEqualStrings("", try cleanTranscript(aa, "(wind blowing) ..."));
    try std.testing.expectEqualStrings("add a ticket", try cleanTranscript(aa, "[Music] add a ticket"));
}

test ttsPayload {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("{\"text\":\"Say \\\"hi\\\"\"}", try ttsPayload(aa, "Say \"hi\"", "", 1));
    try std.testing.expectEqualStrings("{\"text\":\"hi\",\"voice\":\"en_GB-alba-medium\"}", try ttsPayload(aa, "hi", "en_GB-alba-medium", 1));
    try std.testing.expectEqualStrings("{\"text\":\"hi\",\"length_scale\":0.800}", try ttsPayload(aa, "hi", "", 1.25));
}

test ttsIsUrl {
    try std.testing.expect(ttsIsUrl("http://127.0.0.1:5005/synthesize"));
    try std.testing.expect(!ttsIsUrl("~/.local/bin/piper -m x.onnx -f"));
}

test lastLine {
    try std.testing.expectEqualStrings("sh: line 1: piper: command not found", lastLine("loading\nsh: line 1: piper: command not found\n\n"));
    try std.testing.expectEqualStrings("", lastLine(""));
}

test message {
    const a = std.testing.allocator;
    const m = try message(a, "what needs me?");
    defer a.free(m);
    try std.testing.expectEqualStrings("[voice] what needs me?", m);
    try std.testing.expectError(error.BadInput, message(a, ""));
}

test parseSaid {
    const s = parseSaid("1762300000123\tTwo tickets need you.").?;
    try std.testing.expectEqual(@as(i64, 1762300000123), s.at);
    try std.testing.expectEqualStrings("Two tickets need you.", s.text);
    try std.testing.expect(parseSaid("garbage") == null);
}

test oneLine {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("one two three", try oneLine(arena.allocator(), "  one\ntwo\tthree \n"));
}

test firstSentence {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("CL-39 is blocked on a question.", try firstSentence(aa, "**CL-39** is blocked\non a question. Then more."));
}
