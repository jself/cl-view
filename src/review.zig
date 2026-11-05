//! Reviewing and trying a ticket: gutter's window on its changes (with the
//! review guide Claude wrote), whose submitted review goes to the session, and
//! the test plan Claude wrote (.claude/test-plan.md): setup steps, one
//! Launch command run in a hidden tmux session, and checks.
//!
//! gutter and launches run in tmux sessions named clg_<key> and clrun_<key>,
//! outside cl's `cl_` names so the chooser doesn't list them.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");

/// Where the ticket's files are: its worktree, else the project's directory.
pub fn ticketDir(db: board.Db, a: std.mem.Allocator, t: board.Ticket) ![]const u8 {
    if (t.worktree.len > 0) return t.worktree;
    return (try board.getProject(db, a, t.project)).dir;
}

fn exists(ctx: Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

pub fn guidePath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/review-guide.md", .{dir});
}

pub fn reviewPath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/review.md", .{dir});
}

pub fn testPlanPath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/test-plan.md", .{dir});
}

pub fn hasGuide(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) bool {
    return exists(ctx, guidePath(a, dir) catch return false);
}

fn sessionName(a: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(a, key);
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, lower });
}

// ---- gutter ----

/// The port of the ticket's running gutter, or null.
pub fn gutterPort(ctx: Ctx, a: std.mem.Allocator, key: []const u8) !?u16 {
    const name = try sessionName(a, "clg_", key);
    if (!gutterRunning(ctx, name)) return null;
    const pane = tmux.capturePlain(ctx, name) catch return null;
    defer ctx.gpa.free(pane);
    return parsePort(pane);
}

/// Whether gutter still runs in `name` (its pane stays after it exits).
fn gutterRunning(ctx: Ctx, name: []const u8) bool {
    if (!tmux.hasSession(ctx, name)) return false;
    const dead = tmux.run(ctx, &.{ "display", "-p", "-t", name, "#{pane_dead}" }) catch return false;
    defer ctx.gpa.free(dead);
    return !std.mem.eql(u8, dead, "1");
}

fn parsePort(text: []const u8) ?u16 {
    const marker = "http://127.0.0.1:";
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    var end = at + marker.len;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u16, text[at + marker.len .. end], 10) catch null;
}

test parsePort {
    try std.testing.expectEqual(@as(?u16, 43575), parsePort("No changes\ngutter: http://127.0.0.1:43575\noutput: x"));
    try std.testing.expect(parsePort("nothing") == null);
}

pub const GutterError = error{GutterFailed};

/// Open gutter's window on the ticket's changes in clg_<key> (or reuse the
/// open one) and return its port on 127.0.0.1. gutter waits for Submit; the
/// review then lands in <dir>/.claude/review.md and the pane runs `cl ticket
/// gutter <key> --submitted`, which sends it to the session. Closing gutter
/// without submitting writes nothing.
pub fn startGutter(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !u16 {
    if (try gutterPort(ctx, a, t.key)) |p| return p;
    const name = try sessionName(a, "clg_", t.key);
    // A gutter that already exited: start a fresh one.
    if (tmux.hasSession(ctx, name)) tmux.runQuiet(ctx, &.{ "kill-session", "-t", name }) catch {};
    const dir = try ticketDir(db, a, t);
    std.Io.Dir.cwd().createDirPath(ctx.io, try std.fmt.allocPrint(a, "{s}/.claude", .{dir})) catch {};
    std.Io.Dir.cwd().deleteFile(ctx.io, try reviewPath(a, dir)) catch {};
    const rev = try worktree.reviewRev(ctx, a, dir, t.base, t.change);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];
    const script =
        \\cl=$1 key=$2; shift 2
        \\if gutter -sync -window "$@" > .claude/review.md; then exec "$cl" ticket gutter "$key" --submitted; fi
        \\rm -f .claude/review.md; exit 1
    ;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "new-session", "-d", "-s", name, "-c", dir, "--", "sh", "-c", script, "sh", exe, t.key });
    if (rev.len > 0) try argv.appendSlice(a, &.{ "-r", rev });
    tmux.runQuiet(ctx, argv.items) catch return error.GutterFailed;
    tmux.runQuiet(ctx, &.{ "set-option", "-t", name, "remain-on-exit", "on" }) catch {};
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        ctx.sleepMs(100);
        if (try gutterPort(ctx, a, t.key)) |p| return p;
    }
    stopGutter(ctx, a, t.key) catch {};
    return error.GutterFailed;
}

pub fn stopGutter(ctx: Ctx, a: std.mem.Allocator, key: []const u8) !void {
    const name = try sessionName(a, "clg_", key);
    if (tmux.hasSession(ctx, name)) try tmux.runQuiet(ctx, &.{ "kill-session", "-t", name });
}

/// Whether gutter's sync output holds anything for Claude: an overall note
/// or an inline comment. Closing the window prints nothing and still exits 0;
/// Submit with nothing prints the title and `_(no feedback)_`, or just the
/// title when the note is only whitespace.
pub fn reviewHasFeedback(md: []const u8) bool {
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, " \r");
        if (std.mem.eql(u8, l, "## General feedback") or std.mem.eql(u8, l, "## Inline comments")) return true;
    }
    return false;
}

test reviewHasFeedback {
    try std.testing.expect(!reviewHasFeedback(""));
    try std.testing.expect(!reviewHasFeedback("# Review of `@` (jj)\n\n_(no feedback)_\n"));
    try std.testing.expect(!reviewHasFeedback("# Review of `@` (jj)\n\n"));
    try std.testing.expect(reviewHasFeedback("# Review of `@` (jj)\n\n## General feedback\n\nLooks good.\n\n"));
    try std.testing.expect(reviewHasFeedback("# Review of `@` (jj)\n\n## Inline comments\n\n### src/a.zig:3\n\nWhy?\n\n"));
}

// ---- test plans ----

pub const TestPlan = struct {
    setup: []const []const u8 = &.{},
    /// The one command that starts everything ("" if none).
    launch: []const u8 = "",
    /// What to open once it runs (a URL or port line), "" if none.
    open: []const u8 = "",
    checks: []const []const u8 = &.{},
};

/// Read Claude's .claude/test-plan.md: "## Setup" (a numbered or bulleted
/// list), "## Launch" (a fenced command, then what to open) and "## Checks"
/// ("- [ ] ..." items).
pub fn parseTestPlan(a: std.mem.Allocator, md: []const u8) !TestPlan {
    var setup: std.ArrayList([]const u8) = .empty;
    var checks: std.ArrayList([]const u8) = .empty;
    var cmd: std.ArrayList(u8) = .empty;
    var open: []const u8 = "";
    const Section = enum { none, setup, launch, checks };
    var sec: Section = .none;
    var in_code = false;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        const trimmed = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code = !in_code;
            continue;
        }
        if (in_code) {
            if (sec == .launch and trimmed.len > 0) {
                if (cmd.items.len > 0) try cmd.appendSlice(a, " && ");
                try cmd.appendSlice(a, trimmed);
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) {
            const h = std.mem.trimStart(u8, trimmed, "# ");
            var buf: [32]u8 = undefined;
            const low = std.ascii.lowerString(&buf, h[0..@min(h.len, buf.len)]);
            sec = if (std.mem.indexOf(u8, low, "setup") != null)
                .setup
            else if (std.mem.indexOf(u8, low, "launch") != null or std.mem.indexOf(u8, low, "run") != null)
                .launch
            else if (std.mem.indexOf(u8, low, "check") != null)
                .checks
            else
                .none;
            continue;
        }
        if (trimmed.len == 0) continue;
        switch (sec) {
            .setup => if (listItem(trimmed)) |item| try setup.append(a, item),
            .checks => if (listItem(trimmed)) |item| try checks.append(a, item),
            .launch => {
                // An inline `command` when there is no code block.
                if (cmd.items.len == 0 and trimmed[0] == '`' and trimmed.len > 2 and trimmed[trimmed.len - 1] == '`') {
                    try cmd.appendSlice(a, trimmed[1 .. trimmed.len - 1]);
                } else if (open.len == 0) open = trimmed;
            },
            .none => {},
        }
    }
    return .{ .setup = setup.items, .launch = cmd.items, .open = open, .checks = checks.items };
}

/// The text of a list item ("1. x", "- x", "- [ ] x"), or null.
fn listItem(line: []const u8) ?[]const u8 {
    var s = line;
    if (s.len > 2 and (s[0] == '-' or s[0] == '*') and s[1] == ' ') {
        s = s[2..];
    } else {
        var n: usize = 0;
        while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
        if (n == 0 or n + 1 >= s.len or (s[n] != '.' and s[n] != ')') or s[n + 1] != ' ') return null;
        s = s[n + 2 ..];
    }
    if (std.mem.startsWith(u8, s, "[ ] ") or std.mem.startsWith(u8, s, "[x] ") or std.mem.startsWith(u8, s, "[X] ")) s = s[4..];
    return std.mem.trim(u8, s, " ");
}

test parseTestPlan {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const md =
        \\# Test plan
        \\## Setup
        \\1. Log in to staging
        \\2. Plug in the phone
        \\## Launch
        \\```sh
        \\npm run dev
        \\```
        \\Open http://localhost:4321
        \\## Checks
        \\- [ ] The hero loads AVIF
        \\- [ ] Safari falls back to WebP
    ;
    const p = try parseTestPlan(arena_state.allocator(), md);
    try std.testing.expectEqual(@as(usize, 2), p.setup.len);
    try std.testing.expectEqualStrings("npm run dev", p.launch);
    try std.testing.expectEqualStrings("Open http://localhost:4321", p.open);
    try std.testing.expectEqualStrings("Safari falls back to WebP", p.checks[1]);
}

pub fn readTestPlan(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ?TestPlan {
    const path = testPlanPath(a, dir) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(256 * 1024)) catch return null;
    return parseTestPlan(a, data) catch null;
}

/// Run the test plan's Launch command in clrun_<key> (replacing a previous run).
pub fn launch(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !void {
    const dir = try ticketDir(db, a, t);
    const plan = readTestPlan(ctx, a, dir) orelse return error.NoTestPlan;
    if (plan.launch.len == 0) return error.NoLaunch;
    try stopLaunch(ctx, a, t.key);
    const name = try sessionName(a, "clrun_", t.key);
    try tmux.runQuiet(ctx, &.{ "new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", dir, "--", "sh", "-c", plan.launch });
    tmux.runQuiet(ctx, &.{ "set-option", "-t", name, "remain-on-exit", "on" }) catch {};
    try board.logEvent(ctx, db, t.id, "launched", plan.launch);
}

pub fn stopLaunch(ctx: Ctx, a: std.mem.Allocator, key: []const u8) !void {
    const name = try sessionName(a, "clrun_", key);
    if (tmux.hasSession(ctx, name)) try tmux.runQuiet(ctx, &.{ "kill-session", "-t", name });
}

pub const LaunchState = struct {
    running: bool,
    /// The end of its output.
    output: []const u8,
};

/// The launch's state, or null when it was never started (or was stopped).
pub fn launchState(ctx: Ctx, a: std.mem.Allocator, key: []const u8) !?LaunchState {
    const name = try sessionName(a, "clrun_", key);
    if (!tmux.hasSession(ctx, name)) return null;
    const dead = tmux.run(ctx, &.{ "display", "-p", "-t", name, "#{pane_dead}" }) catch return null;
    defer ctx.gpa.free(dead);
    const raw = tmux.capturePlainLines(ctx, name, 200) catch "";
    defer if (raw.len > 0) ctx.gpa.free(raw);
    return .{ .running = !std.mem.eql(u8, dead, "1"), .output = try a.dupe(u8, std.mem.trimEnd(u8, raw, "\n")) };
}

pub const Check = struct {
    text: []const u8,
    pass: bool,
    note: []const u8 = "",
};

/// What you found, as a comment for the ticket, and whether all passed.
pub fn recordResults(a: std.mem.Allocator, checks: []const Check, note: []const u8) !struct { passed: bool, text: []const u8 } {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    var passed = true;
    for (checks) |c| if (!c.pass) {
        passed = false;
    };
    try w.writeAll(if (passed) "Tested: everything passed.\n" else "Tested: some checks failed. Please fix them, then finish the same way as before.\n");
    for (checks) |c| {
        try w.print("- [{s}] {s}{s}{s}\n", .{ if (c.pass) "x" else " ", c.text, if (c.note.len > 0) " — " else "", c.note });
    }
    if (note.len > 0) try w.print("\n{s}\n", .{note});
    return .{ .passed = passed, .text = aw.written() };
}
