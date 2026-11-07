//! `cl dictate`: push-to-talk for a plain terminal attached to tmux (README,
//! "Dictating from a terminal"). The web terminal page records in the
//! browser; a terminal has no page, so cl records the mic itself with
//! `pw-record` and pastes the words into the session's pane.
//!
//! A terminal never says when a key goes up, so it's a toggle: the first
//! press starts `pw-record` in the background and the second stops it, runs
//! `voice.stt` on the WAV and pastes the words (bracketed, with a space
//! after, not sent), the same as the page does. The recording in progress is
//! the tmux server option @cl_dictate ("<pid>\t<start>\t<wav>\t<session>"):
//! there is one mic, so one recording, and the second press pastes into the
//! session the first one started in. While it records, that session's
//! status-right says so (`marker`). Messages go to the status line of every
//! client showing the session (display-message), since the binding runs it
//! with no terminal of its own. `.claude/test-dictate.sh` runs it all on a
//! sandbox tmux server with stand-ins for pw-record and voice.stt.
//!
//! Each press is its own process (the binding's run-shell -b), so a held key
//! (autorepeat) or a double tap runs several at once: a lock file serializes
//! their decisions, and a press within `debounce_ms` of the last one is
//! dropped, so holding the key just starts one recording. The recorder is
//! known by its PID and its start time (/proc/<pid>/stat), so a PID reused
//! by some other process after the recorder ended is never signaled.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const voice = @import("voice.zig");

const option = "@cl_dictate";

/// The session's status-right while it records: a toggle is easy to forget,
/// and a message goes at the next key. Unset again (back to the global one)
/// when it stops. It stays after the 4-minute cap, where the next press
/// still types the words in.
const marker = "#[reverse] ● dictating: Alt+` types it in #[default] ";
/// When the last press came, in ms (presses that were dropped included).
const last_option = "@cl_dictate_at";

/// Presses closer together than this are one press: longer than a
/// keyboard's autorepeat delay (KDE's is 600 ms), much shorter than saying
/// anything.
const debounce_ms = 1000;

/// Longest recording: `voice.max_wav` (8 MB) holds ~260 s of 16 kHz 16-bit
/// mono. A forgotten recording stops itself here; the next press still
/// types it in.
const max_seconds = 240;

pub const Recording = struct {
    pid: std.posix.pid_t,
    /// The recorder's start time (/proc/<pid>/stat field 22): with the PID,
    /// tells it apart from a later process that got the same PID.
    started: u64,
    wav: []const u8,
    session: []const u8,
};

/// What the next press does, from @cl_dictate's value and whether its
/// recorder is still running and its WAV is still there.
pub const Next = enum { start, stop };

pub fn next(rec: ?Recording, running: bool, wav_exists: bool) Next {
    if (rec == null) return .start;
    // Stopped by itself at max_seconds: still worth typing in.
    return if (running or wav_exists) .stop else .start;
}

pub fn parse(raw: []const u8) ?Recording {
    var it = std.mem.splitScalar(u8, raw, '\t');
    const pid = std.fmt.parseInt(std.posix.pid_t, it.next() orelse return null, 10) catch return null;
    const started = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const wav = it.next() orelse return null;
    const session = it.next() orelse return null;
    if (pid <= 0 or wav.len == 0 or session.len == 0) return null;
    return .{ .pid = pid, .started = started, .wav = wav, .session = session };
}

/// Is a press at `now` (ms) part of the one at `last` (ms, 0 for none)?
pub fn bounce(last: i64, now: i64) bool {
    return last > 0 and now >= last and now - last < debounce_ms;
}

/// `cl dictate [name]` (start or stop) and `cl dictate --cancel`.
pub fn main(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cancelling = argv.len == 1 and std.mem.eql(u8, argv[0], "--cancel");
    if (!cancelling and (argv.len > 1 or (argv.len == 1 and std.mem.startsWith(u8, argv[0], "-"))))
        return fail(ctx, null, "usage: cl dictate [name] | --cancel", .{});

    // Held until this press has started a recording or taken one over
    // (released early by `stop`; on exit, whatever happens).
    const lock = try takeLock(ctx, a);
    defer lock.close(ctx.io);
    if (cancelling) return cancel(ctx, a);

    const now = voice.nowMs(ctx);
    const last = blk: {
        const raw = tmux.run(ctx, &.{ "show-options", "-gqv", last_option }) catch break :blk 0;
        defer ctx.gpa.free(raw);
        break :blk std.fmt.parseInt(i64, raw, 10) catch 0;
    };
    var now_buf: [24]u8 = undefined;
    tmux.runQuiet(ctx, &.{ "set-option", "-g", last_option, std.fmt.bufPrint(&now_buf, "{d}", .{now}) catch "0" }) catch {};
    if (bounce(last, now)) return;

    const rec = current(ctx, a);
    const running = if (rec) |r| alive(ctx, r) else false;
    const wav_exists = if (rec) |r| exists(ctx, r.wav) else false;
    switch (next(rec, running, wav_exists)) {
        .stop => return stop(ctx, cfg, a, rec.?, lock),
        .start => {
            if (rec) |r| clear(ctx, r);
            return start(ctx, cfg, a, if (argv.len == 1) argv[0] else null);
        },
    }
}

fn start(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, name: ?[]const u8) !void {
    const session = try target(ctx, a, name);
    if (cfg.voice.stt.len == 0)
        return fail(ctx, session, "Dictation needs voice.stt in ~/.config/cl/config (README, Voice).", .{});
    const dir = ctx.env.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const wav = try std.fmt.allocPrint(a, "{s}/cl-dictate-{d}.wav", .{ dir, std.Io.Timestamp.now(ctx.io, .real).nanoseconds });
    // setsid: the recorder outlives this command (and tmux's run-shell job);
    // `timeout` stops a forgotten one, and passes our SIGINT on to it.
    // pw-record writes the WAV's header when it gets SIGINT.
    const script = std.fmt.comptimePrint(
        "setsid timeout -k 5 -s INT {d} pw-record --rate 16000 --channels 1 --format s16 \"$1\" </dev/null >/dev/null 2>&1 & echo $!",
        .{max_seconds},
    );
    const res = std.process.run(a, ctx.io, .{ .argv = &.{ "sh", "-c", script, "sh", wav } }) catch |err|
        return fail(ctx, session, "Couldn't start pw-record: {s}", .{@errorName(err)});
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, res.stdout, " \n"), 10) catch
        return fail(ctx, session, "Couldn't start pw-record.", .{});
    const rec: Recording = .{ .pid = pid, .started = startTime(ctx, pid) orelse 0, .wav = wav, .session = session };
    ctx.sleepMs(150);
    if (rec.started == 0 or !alive(ctx, rec)) {
        clear(ctx, rec);
        return fail(ctx, session, "pw-record stopped at once (is PipeWire running? is pw-record installed?)", .{});
    }

    const value = try std.fmt.allocPrint(a, "{d}\t{d}\t{s}\t{s}", .{ pid, rec.started, wav, session });
    tmux.runQuiet(ctx, &.{ "set-option", "-g", option, value }) catch {
        // Nothing would know it's running, so nothing could stop it.
        clear(ctx, rec);
        return fail(ctx, session, "Couldn't keep track of the recording: {s}", .{tmux.lastError()});
    };
    tmux.runQuiet(ctx, &.{ "set-option", "-t", session, "status-right", marker }) catch {};
    show(ctx, session, 5000, "Listening…  press the key again (Alt+` or Ctrl+Shift+Space) to type it in; cl dictate --cancel drops it.");
}

fn stop(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, rec: Recording, lock: std.Io.File) !void {
    // Unset first and let go of the lock, so a press while this works out
    // the words starts afresh.
    forget(ctx, rec);
    lock.unlock(ctx.io);
    if (!halt(ctx, rec)) {
        kill(ctx, rec);
        std.Io.Dir.deleteFileAbsolute(ctx.io, rec.wav) catch {};
        return fail(ctx, rec.session, "pw-record didn't finish the recording, so nothing was typed in (is PipeWire stuck?)", .{});
    }
    show(ctx, rec.session, 60_000, "Working out the words…");
    const read = std.Io.Dir.cwd().readFileAlloc(ctx.io, rec.wav, a, .limited(voice.max_wav));
    // Gone before anything can fail (`fail` exits, skipping defers).
    std.Io.Dir.deleteFileAbsolute(ctx.io, rec.wav) catch {};
    const wav = read catch |err| return fail(ctx, rec.session, "Couldn't read the recording: {s}", .{@errorName(err)});
    const words = voice.transcribe(ctx, a, cfg, wav) catch |err| return switch (err) {
        error.VoiceOff => fail(ctx, rec.session, "Dictation needs voice.stt in ~/.config/cl/config (README, Voice).", .{}),
        else => fail(ctx, rec.session, "voice.stt failed: {s}", .{if (voice.lastError().len > 0) voice.lastError() else @errorName(err)}),
    };
    if (words.len == 0) return fail(ctx, rec.session, "Heard nothing to type in.", .{});
    if (!tmux.hasSession(ctx, rec.session))
        return fail(ctx, null, "{s} has gone, so it wasn't typed in. You said: {s}", .{ rec.session, words });
    // A paste, so Claude Code (which asked tmux for bracketed paste) takes
    // it as text and doesn't send it: read it, fix it, press Enter.
    try tmux.paste(ctx, rec.session, try std.fmt.allocPrint(a, "{s} ", .{words}));
    show(ctx, rec.session, 1500, "Typed in.");
}

fn cancel(ctx: Ctx, a: std.mem.Allocator) !void {
    const rec = current(ctx, a) orelse return fail(ctx, null, "Not dictating.", .{});
    clear(ctx, rec);
    show(ctx, rec.session, 1500, "Dictation canceled.");
}

/// Stop a recording and forget it, without typing anything in.
fn clear(ctx: Ctx, rec: Recording) void {
    forget(ctx, rec);
    if (!halt(ctx, rec)) kill(ctx, rec);
    std.Io.Dir.deleteFileAbsolute(ctx.io, rec.wav) catch {};
}

/// Drop @cl_dictate and the session's marker.
fn forget(ctx: Ctx, rec: Recording) void {
    tmux.runQuiet(ctx, &.{ "set-option", "-gu", option }) catch {};
    tmux.runQuiet(ctx, &.{ "set-option", "-t", rec.session, "-u", "status-right" }) catch {};
}

fn current(ctx: Ctx, a: std.mem.Allocator) ?Recording {
    const raw = tmux.run(ctx, &.{ "show-options", "-gqv", option }) catch return null;
    defer ctx.gpa.free(raw);
    return parse(a.dupe(u8, raw) catch return null);
}

/// SIGINT the recorder (`timeout`, which hands it to pw-record) and wait up
/// to 3 s for it to finish the WAV. False when it is still running.
fn halt(ctx: Ctx, rec: Recording) bool {
    if (!alive(ctx, rec)) return true;
    std.posix.kill(rec.pid, .INT) catch return !alive(ctx, rec);
    var i: usize = 0;
    while (i < 60 and alive(ctx, rec)) : (i += 1) ctx.sleepMs(50);
    return !alive(ctx, rec);
}

/// SIGKILL a recorder that didn't stop: `timeout` and pw-record, its whole
/// process group (setsid made `timeout` its leader). Only while `alive`
/// says it is still ours.
fn kill(ctx: Ctx, rec: Recording) void {
    if (alive(ctx, rec)) std.posix.kill(-rec.pid, .KILL) catch {};
}

/// Is the recorder still running? Its PID with the same start time: a
/// process that got the PID later started later.
fn alive(ctx: Ctx, rec: Recording) bool {
    return startTime(ctx, rec.pid) == rec.started;
}

/// A process's start time (clock ticks after boot), or null when there is
/// no such process (or it is a zombie, which has finished).
fn startTime(ctx: Ctx, pid: std.posix.pid_t) ?u64 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(ctx.io, path, &buf) catch return null;
    return parseStartTime(stat);
}

/// Field 22 of /proc/<pid>/stat; null for a zombie ("Z"). The command
/// (field 2) is in parentheses and may hold spaces, so count from its ")".
pub fn parseStartTime(stat: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var field: usize = 3;
    while (it.next()) |tok| : (field += 1) {
        if (field == 3 and std.mem.eql(u8, tok, "Z")) return null;
        if (field == 22) return std.fmt.parseInt(u64, tok, 10) catch null;
    }
    return null;
}

/// The lock that serializes presses, in $XDG_RUNTIME_DIR. Not inherited by
/// the recorder (Zig opens files close-on-exec), so it ends with this press.
fn takeLock(ctx: Ctx, a: std.mem.Allocator) !std.Io.File {
    const dir = ctx.env.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(a, "{s}/cl-dictate.lock", .{dir});
    return std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = false, .lock = .exclusive });
}

fn exists(ctx: Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

/// The tmux session to type into: `name` (a cl name or tmux name), else
/// the one this runs in, else the one the most recently used client shows
/// (for a desktop hotkey, which runs it outside tmux).
fn target(ctx: Ctx, a: std.mem.Allocator, name: ?[]const u8) ![]const u8 {
    if (name) |n| {
        for (try tmux.listAll(ctx, a)) |s|
            if (std.mem.eql(u8, s.name, n) or std.mem.eql(u8, s.tmux_name, n)) return s.tmux_name;
        // Any tmux session will do: the binding passes #{session_name}.
        if (tmux.hasSession(ctx, n)) return n;
        return fail(ctx, null, "no session named {s}", .{n});
    }
    if (ctx.env.get("TMUX_PANE")) |pane| {
        // Empty when the pane is on another server (a nested tmux).
        if (tmux.run(ctx, &.{ "display-message", "-p", "-t", pane, "#{session_name}" })) |v| {
            defer ctx.gpa.free(v);
            if (v.len > 0) return a.dupe(u8, v);
        } else |_| {}
    }
    const clients = tmux.run(ctx, &.{ "list-clients", "-F", "#{client_activity}\t#{session_name}" }) catch
        return fail(ctx, null, "no tmux client to dictate into; name a session", .{});
    defer ctx.gpa.free(clients);
    return latestClientSession(a, clients) orelse fail(ctx, null, "no tmux client to dictate into; name a session", .{});
}

/// The session of the client with the latest activity, from list-clients
/// lines "<activity>\t<session>".
pub fn latestClientSession(a: std.mem.Allocator, lines: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_at: i64 = -1;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const at = std.fmt.parseInt(i64, line[0..tab], 10) catch continue;
        if (at > best_at and tab + 1 < line.len) {
            best_at = at;
            best = line[tab + 1 ..];
        }
    }
    return if (best) |b| a.dupe(u8, b) catch null else null;
}

/// A message on the status line of every client showing `session`
/// (display-message's -t only sets the format's context; -c picks the
/// client, else tmux's current one, which may be showing something else).
fn show(ctx: Ctx, session: []const u8, ms: u32, text: []const u8) void {
    var buf: [16]u8 = undefined;
    const d = std.fmt.bufPrint(&buf, "{d}", .{ms}) catch "3000";
    const clients = tmux.run(ctx, &.{ "list-clients", "-t", session, "-F", "#{client_name}" }) catch return;
    defer ctx.gpa.free(clients);
    var it = std.mem.tokenizeScalar(u8, clients, '\n');
    // -l: the text as it is, not a format (a "#" in the words stays).
    while (it.next()) |c| tmux.runQuiet(ctx, &.{ "display-message", "-c", c, "-l", "-d", d, text }) catch {};
}

/// Say why on stderr and, when there's a session to show it on, its status
/// line (the binding's run-shell has nowhere else to show it); exit 1.
fn fail(ctx: Ctx, session: ?[]const u8, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "cl dictate failed";
    if (session) |s| show(ctx, s, 8000, msg) else {
        // No session yet: whatever client tmux picks (from a binding, the one pressing it).
        tmux.runQuiet(ctx, &.{ "display-message", "-l", "-d", "8000", msg }) catch {};
    }
    std.debug.print("cl dictate: {s}\n", .{msg});
    std.process.exit(1);
}

test next {
    const r: Recording = .{ .pid = 42, .started = 7, .wav = "/run/user/1000/cl-dictate-1.wav", .session = "cl_x" };
    try std.testing.expectEqual(Next.start, next(null, false, false));
    try std.testing.expectEqual(Next.stop, next(r, true, true));
    try std.testing.expectEqual(Next.stop, next(r, false, true)); // stopped at max_seconds
    try std.testing.expectEqual(Next.start, next(r, false, false)); // stale (a reboot, say)
}

test parse {
    const r = parse("123\t4567\t/run/user/1000/cl-dictate-9.wav\tcl_web-ui").?;
    try std.testing.expectEqual(@as(std.posix.pid_t, 123), r.pid);
    try std.testing.expectEqual(@as(u64, 4567), r.started);
    try std.testing.expectEqualStrings("/run/user/1000/cl-dictate-9.wav", r.wav);
    try std.testing.expectEqualStrings("cl_web-ui", r.session);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("x\ty\tz") == null);
    try std.testing.expect(parse("12\t5\t/w.wav") == null);
    try std.testing.expect(parse("12\t/w.wav\tcl_x") == null); // the old form
}

test bounce {
    try std.testing.expect(!bounce(0, 5000));
    try std.testing.expect(bounce(5000, 5030)); // autorepeat
    try std.testing.expect(bounce(5000, 5600)); // the repeat delay
    try std.testing.expect(!bounce(5000, 8000)); // said something, pressed again
    try std.testing.expect(!bounce(9000, 5000)); // the clock went back
}

test parseStartTime {
    const stat = "3367974 (time out) S 1 3367974 3367974 0 -1 4194560 120 0 0 0 0 0 0 0 20 0 1 0 98765432 5 6";
    try std.testing.expectEqual(@as(?u64, 98765432), parseStartTime(stat));
    try std.testing.expectEqual(@as(?u64, null), parseStartTime("12 (pw-record) Z 1 12 12 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 0 0"));
    try std.testing.expectEqual(@as(?u64, null), parseStartTime("garbage"));
    // The real thing: this test's own process.
    try std.testing.expect(startTime(.{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/" }, @intCast(std.os.linux.getpid())) != null);
}

test latestClientSession {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("cl_b", latestClientSession(a, "100\tcl_a\n300\tcl_b\n200\tcl_c").?);
    try std.testing.expect(latestClientSession(a, "") == null);
}
