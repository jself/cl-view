//! Reviewing and trying a ticket: gutter's window on its changes (with the
//! review guide Claude wrote), whose submitted review goes to the session, and
//! the test plan Claude gave `cl ticket done --test-plan` (kept in the
//! ticket): setup steps, one Launch command run in a hidden tmux session, and
//! checks.
//!
//! gutter and launches run in tmux sessions named clg_<key> and clrun_<key>,
//! outside cl's `cl_` names so the chooser doesn't list them.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");

/// Where the ticket's files are: its worktree, else its parent's when it went
/// on in its parent's session, else the project's directory.
pub fn ticketDir(db: board.Db, a: std.mem.Allocator, t: board.Ticket) ![]const u8 {
    if (t.worktree.len > 0) return t.worktree;
    if (t.parent.len > 0 and t.tmux.len > 0) {
        const p = try board.getTicket(db, a, t.parent);
        if (p.worktree.len > 0 and std.mem.eql(u8, p.tmux, t.tmux)) return p.worktree;
    }
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

/// One step of the walk-through, shown on its own: what to do by hand, a
/// command to run and a page to open (buttons, nothing runs by itself), and
/// what you should see.
pub const Step = struct {
    title: []const u8 = "",
    /// What to do by hand, line by line.
    do: []const []const u8 = &.{},
    /// A command run from the ticket's directory in clrun_<key>_s<n>, "" for none.
    run: []const u8 = "",
    /// A URL that answers once what `run` started is up, "" for none.
    wait: []const u8 = "",
    open: []const []const u8 = &.{},
    checks: []const []const u8 = &.{},
};

pub const TestPlan = struct {
    steps: []const Step = &.{},

    pub fn checkCount(p: TestPlan) usize {
        var n: usize = 0;
        for (p.steps) |st| n += st.checks.len;
        return n;
    }

    /// The step `n` (1-based), or else the first with a command.
    pub fn runStep(p: TestPlan, n: ?usize) ?usize {
        if (n) |i| return if (i >= 1 and i <= p.steps.len and p.steps[i - 1].run.len > 0) i else null;
        for (p.steps, 1..) |st, i| if (st.run.len > 0) return i;
        return null;
    }
};

/// What `cl ticket testplan --format` prints, and what Claude writes.
pub const format_help =
    \\A test plan is markdown that walks the human through trying the change, one
    \\step at a time, like a wizard. Give it to `cl ticket done <key> --test-plan -`
    \\on stdin. Each "## " heading is a step, in order. In a step:
    \\
    \\  run: <command>     a button that runs it from the ticket's directory in the
    \\                     background (a server, a seed script); its output shows
    \\  wait: <url>        shows whether it answers yet (a server that is starting)
    \\  open: <url>        a button that opens the page in the browser
    \\  - [ ] <check>      what to try and what they should see: Pass or Fail
    \\  other lines        what to do by hand ("- " and "1. " lists too)
    \\
    \\Nothing runs or opens until the human presses its button. A step can have
    \\any of these; the plan needs at least one check. Keep each step one focused
    \\task. Example:
    \\
    \\  ## Start the dev server
    \\  run: npm run dev
    \\  wait: http://localhost:4321
    \\
    \\  ## Log in
    \\  open: http://localhost:4321/login
    \\  Sign in as admin@example.com (password in 1Password, "staging admin").
    \\
    \\  ## The hero image
    \\  open: http://localhost:4321/
    \\  - [ ] The hero loads as AVIF (Network tab shows image/avif)
    \\  - [ ] In Safari it falls back to WebP
    \\
;

/// Read a test plan (format_help). The older shape, "## Setup", "## Launch"
/// (a fenced command, then "Open <url>") and "## Checks", reads as three steps.
pub fn parseTestPlan(a: std.mem.Allocator, md: []const u8) !TestPlan {
    var steps: std.ArrayList(Step) = .empty;
    var cur: ?Step = null;
    var do: std.ArrayList([]const u8) = .empty;
    var open: std.ArrayList([]const u8) = .empty;
    var checks: std.ArrayList([]const u8) = .empty;
    var cmd: std.ArrayList(u8) = .empty;
    var legacy_launch = false;
    var in_code = false;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (true) {
        const next = lines.next();
        const line = if (next) |raw| std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), " \t") else "";
        const heading = next != null and !in_code and std.mem.startsWith(u8, line, "#");
        if (next == null or heading) {
            if (cur) |*st| {
                if (cmd.items.len > 0 and st.run.len == 0) st.run = try cmd.toOwnedSlice(a);
                st.do = try do.toOwnedSlice(a);
                st.open = try open.toOwnedSlice(a);
                st.checks = try checks.toOwnedSlice(a);
                if (st.do.len + st.open.len + st.checks.len > 0 or st.run.len + st.wait.len > 0) try steps.append(a, st.*);
            }
            cmd = .empty;
            cur = null;
            if (next == null) break;
            // "# Title" names the whole plan; "## ..." and deeper are steps.
            if (!std.mem.startsWith(u8, line, "##")) continue;
            const title = stepTitle(std.mem.trimStart(u8, line, "# "));
            var low_buf: [32]u8 = undefined;
            const low = std.ascii.lowerString(&low_buf, title[0..@min(title.len, low_buf.len)]);
            legacy_launch = std.mem.indexOf(u8, low, "launch") != null;
            cur = .{ .title = title };
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            in_code = !in_code;
            continue;
        }
        if (cur == null) continue;
        const st = &cur.?;
        if (in_code) {
            if (line.len > 0) {
                if (cmd.items.len > 0) try cmd.appendSlice(a, " && ");
                try cmd.appendSlice(a, line);
            }
            continue;
        }
        if (line.len == 0) continue;
        if (keyed(line, "run:")) |v| {
            st.run = v;
        } else if (keyed(line, "wait:")) |v| {
            st.wait = v;
        } else if (keyed(line, "open:")) |v| {
            try open.append(a, v);
        } else if (keyed(line, "check:")) |v| {
            try checks.append(a, v);
        } else if (checkItem(line)) |v| {
            try checks.append(a, v);
        } else if (legacy_launch and st.run.len == 0 and cmd.items.len == 0 and line.len > 2 and line[0] == '`' and line[line.len - 1] == '`') {
            st.run = line[1 .. line.len - 1];
        } else {
            // "Open http://..." (the older Launch section) is a page to open.
            if (keyed(line, "open ")) |v| if (urlIn(v)) |u| try open.append(a, u);
            try do.append(a, listItem(line) orelse line);
        }
    }
    return .{ .steps = try steps.toOwnedSlice(a) };
}

/// "Run: x" → "x", any case; null when `line` doesn't start with `key`.
fn keyed(line: []const u8, key: []const u8) ?[]const u8 {
    if (line.len < key.len or !std.ascii.eqlIgnoreCase(line[0..key.len], key)) return null;
    const v = std.mem.trim(u8, line[key.len..], " \t");
    // A command or URL in backticks.
    if (v.len > 2 and v[0] == '`' and v[v.len - 1] == '`') return v[1 .. v.len - 1];
    return v;
}

/// The first http(s) URL in `s`, without trailing punctuation.
fn urlIn(s: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, "http://") orelse std.mem.indexOf(u8, s, "https://") orelse return null;
    var e = i;
    while (e < s.len and s[e] != ' ' and s[e] != ')' and s[e] != '`' and s[e] != '>') e += 1;
    return std.mem.trimEnd(u8, s[i..e], ".,;");
}

/// "1. Start it" / "Step 1: Start it" → "Start it".
fn stepTitle(h: []const u8) []const u8 {
    var s = h;
    if (s.len > 5 and std.ascii.eqlIgnoreCase(s[0..5], "step ")) s = s[5..];
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    if (n > 0 and n < s.len and (s[n] == '.' or s[n] == ')' or s[n] == ':')) s = s[n + 1 ..];
    const t = std.mem.trim(u8, s, " ");
    return if (t.len > 0) t else h;
}

/// The text of a "- [ ] x" item, or null.
fn checkItem(line: []const u8) ?[]const u8 {
    if (line.len < 6 or (line[0] != '-' and line[0] != '*') or line[1] != ' ') return null;
    const s = line[2..];
    if (std.mem.startsWith(u8, s, "[ ] ") or std.mem.startsWith(u8, s, "[x] ") or std.mem.startsWith(u8, s, "[X] ")) return std.mem.trim(u8, s[4..], " ");
    return null;
}

/// The text of a list item ("1. x", "- x"), or null.
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
    return std.mem.trim(u8, s, " ");
}

test parseTestPlan {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const md =
        \\# Test plan
        \\## 1. Start the server
        \\run: `npm run dev`
        \\wait: http://localhost:4321
        \\
        \\## Step 2: Log in
        \\open: http://localhost:4321/login
        \\Sign in as admin.
        \\- Then pick the staging site
        \\
        \\## The hero
        \\open: http://localhost:4321/
        \\- [ ] The hero loads AVIF
        \\check: Safari falls back to WebP
    ;
    const p = try parseTestPlan(arena_state.allocator(), md);
    try std.testing.expectEqual(@as(usize, 3), p.steps.len);
    try std.testing.expectEqualStrings("Start the server", p.steps[0].title);
    try std.testing.expectEqualStrings("npm run dev", p.steps[0].run);
    try std.testing.expectEqualStrings("http://localhost:4321", p.steps[0].wait);
    try std.testing.expectEqualStrings("Log in", p.steps[1].title);
    try std.testing.expectEqualStrings("http://localhost:4321/login", p.steps[1].open[0]);
    try std.testing.expectEqualStrings("Then pick the staging site", p.steps[1].do[1]);
    try std.testing.expectEqualStrings("Safari falls back to WebP", p.steps[2].checks[1]);
    try std.testing.expectEqual(@as(usize, 2), p.checkCount());
    try std.testing.expectEqual(@as(?usize, 1), p.runStep(null));
    try std.testing.expectEqual(@as(?usize, null), p.runStep(2));
}

test "parseTestPlan: the older Setup, Launch, Checks shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const md =
        \\## Setup
        \\1. Log in to staging
        \\2. Plug in the phone
        \\## Launch
        \\```sh
        \\npm install
        \\npm run dev
        \\```
        \\Open http://localhost:4321.
        \\## Checks
        \\- [ ] The hero loads AVIF
        \\- [ ] Safari falls back to WebP
    ;
    const p = try parseTestPlan(arena_state.allocator(), md);
    try std.testing.expectEqual(@as(usize, 3), p.steps.len);
    try std.testing.expectEqualStrings("Plug in the phone", p.steps[0].do[1]);
    try std.testing.expectEqualStrings("npm install && npm run dev", p.steps[1].run);
    try std.testing.expectEqualStrings("http://localhost:4321", p.steps[1].open[0]);
    try std.testing.expectEqualStrings("Open http://localhost:4321.", p.steps[1].do[0]);
    try std.testing.expectEqualStrings("Safari falls back to WebP", p.steps[2].checks[1]);
}

/// The ticket's own test plan, kept when its session said done; null for none.
pub fn readTestPlan(a: std.mem.Allocator, t: board.Ticket) ?TestPlan {
    if (t.test_plan.len == 0) return null;
    return parseTestPlan(a, t.test_plan) catch null;
}

/// `done`, with the test plan Claude gives for something to try: null keeps
/// the one from an earlier round, "" drops it. A plan without checks is
/// refused (error.BadTestPlan), as is one during Planning (a plan being
/// approved has nothing to try yet).
pub fn done(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, summary: []const u8, test_plan: ?[]const u8) !void {
    const t = try board.getTicket(db, a, key);
    if (test_plan) |md| {
        if (t.stage == .planning) return error.BadTestPlan;
        if (md.len > 0 and (try parseTestPlan(a, md)).checkCount() == 0) return error.BadTestPlan;
        try board.setTestPlan(ctx, db, t.id, md);
    }
    try board.done(ctx, db, a, key, summary);
}

/// clrun_<key>_s<n>: where step `n`'s command runs.
fn runName(a: std.mem.Allocator, key: []const u8, n: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}_s{d}", .{ try sessionName(a, "clrun_", key), n });
}

/// Run step `n`'s command (1-based; null: the first step with one) in its
/// own tmux session, replacing a previous run of it. Returns the step.
pub fn launch(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, n: ?usize) !usize {
    const dir = try ticketDir(db, a, t);
    const plan = readTestPlan(a, t) orelse return error.NoTestPlan;
    const i = plan.runStep(n) orelse return error.NoLaunch;
    const cmd = plan.steps[i - 1].run;
    const name = try runName(a, t.key, i);
    try killExact(ctx, a, name);
    try tmux.runQuiet(ctx, &.{ "new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", dir, "--", "sh", "-c", cmd });
    tmux.runQuiet(ctx, &.{ "set-option", "-t", try std.fmt.allocPrint(a, "={s}:", .{name}), "remain-on-exit", "on" }) catch {};
    try board.logEvent(ctx, db, t.id, "launched", cmd);
    return i;
}

/// "=name": tmux otherwise takes a prefix (clrun_cl-1 would find clrun_cl-16_s1).
fn exact(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "={s}", .{name});
}

fn killExact(ctx: Ctx, a: std.mem.Allocator, name: []const u8) !void {
    const t = try exact(a, name);
    if (tmux.hasSession(ctx, t)) try tmux.runQuiet(ctx, &.{ "kill-session", "-t", t });
}

/// Stop step `n`'s command, or (null) every one the ticket started.
pub fn stopLaunch(ctx: Ctx, a: std.mem.Allocator, key: []const u8, n: ?usize) !void {
    if (n) |i| return killExact(ctx, a, try runName(a, key, i));
    const prefix = try std.fmt.allocPrint(a, "{s}_s", .{try sessionName(a, "clrun_", key)});
    const names = tmux.run(ctx, &.{ "list-sessions", "-F", "#{session_name}" }) catch return;
    defer ctx.gpa.free(names);
    var it = std.mem.tokenizeScalar(u8, names, '\n');
    while (it.next()) |name| {
        const rest = if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else continue;
        if (rest.len > 0 and std.fmt.parseInt(usize, rest, 10) catch null != null) try killExact(ctx, a, name);
    }
    // Before steps, a ticket had one: clrun_<key>.
    try killExact(ctx, a, try sessionName(a, "clrun_", key));
}

pub const LaunchState = struct {
    running: bool,
    /// The end of its output.
    output: []const u8,
};

/// Each step's run: its state, or null when it was never started (or was
/// stopped, or the step has no command).
pub fn launchStates(ctx: Ctx, a: std.mem.Allocator, key: []const u8, plan: TestPlan) ![]?LaunchState {
    const out = try a.alloc(?LaunchState, plan.steps.len);
    for (plan.steps, out, 1..) |st, *o, i| {
        o.* = null;
        if (st.run.len == 0) continue;
        const name = try exact(a, try runName(a, key, i));
        if (!tmux.hasSession(ctx, name)) continue;
        const pane = try std.fmt.allocPrint(a, "{s}:", .{name});
        const dead = tmux.run(ctx, &.{ "display", "-p", "-t", pane, "#{pane_dead}" }) catch continue;
        defer ctx.gpa.free(dead);
        const raw = tmux.capturePlainLines(ctx, pane, 200) catch "";
        defer if (raw.len > 0) ctx.gpa.free(raw);
        o.* = .{ .running = !std.mem.eql(u8, dead, "1"), .output = try a.dupe(u8, std.mem.trimEnd(u8, raw, "\n")) };
    }
    return out;
}

/// Whether each step's `wait` URL answers yet; null when it has none or it
/// isn't on this machine (only a local port is tried, so a check never hangs).
pub fn waitStates(ctx: Ctx, a: std.mem.Allocator, plan: TestPlan) ![]?bool {
    const out = try a.alloc(?bool, plan.steps.len);
    for (plan.steps, out) |st, *o| {
        o.* = null;
        const ip = localAddress(st.wait) orelse continue;
        const s = ip.connect(ctx.io, .{ .mode = .stream }) catch {
            o.* = false;
            continue;
        };
        s.close(ctx.io);
        o.* = true;
    }
    return out;
}

/// The loopback address and port of a local URL (localhost, *.localhost,
/// 127.x, [::1]), else null.
fn localAddress(url: []const u8) ?std.Io.net.IpAddress {
    if (url.len == 0) return null;
    const uri = std.Uri.parse(url) catch return null;
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&buf) catch return null).bytes;
    const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;
    const lit = if (std.mem.eql(u8, host, "localhost") or std.mem.endsWith(u8, host, ".localhost")) "127.0.0.1" else host;
    const ip = std.Io.net.IpAddress.parse(std.mem.trim(u8, lit, "[]"), port) catch return null;
    const loopback = switch (ip) {
        .ip4 => |v| v.bytes[0] == 127,
        .ip6 => |v| std.mem.eql(u8, &v.bytes, &(@as([15]u8, @splat(0)) ++ [_]u8{1})),
    };
    return if (loopback) ip else null;
}

test localAddress {
    try std.testing.expect(localAddress("http://localhost:4321/x") != null);
    try std.testing.expect(localAddress("http://events.localhost:4002/panel") != null);
    try std.testing.expect(localAddress("http://127.0.0.1:8422/board") != null);
    try std.testing.expect(localAddress("https://example.com/") == null);
    try std.testing.expect(localAddress("http://100.64.0.1:80/") == null);
    try std.testing.expect(localAddress("") == null);
}

pub const Check = struct {
    text: []const u8,
    pass: bool,
    note: []const u8 = "",
};

/// One step's results: its checks and your comment on it.
pub const StepResult = struct {
    title: []const u8 = "",
    comment: []const u8 = "",
    checks: []const Check = &.{},
};

/// What you found, step by step, as a comment for the ticket, and whether all
/// passed. Steps with nothing to say (no checks, no comment) are left out.
pub fn recordResults(a: std.mem.Allocator, steps: []const StepResult, note: []const u8) !struct { passed: bool, commented: bool, text: []const u8 } {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    var passed = true;
    var commented = std.mem.trim(u8, note, " \n").len > 0;
    for (steps) |st| {
        for (st.checks) |c| if (!c.pass) {
            passed = false;
        };
        if (std.mem.trim(u8, st.comment, " \n").len > 0) commented = true;
    }
    try w.writeAll(if (!passed)
        "Tested: some checks failed. Please fix them, then finish the same way as before.\n"
    else if (commented)
        "Tested: everything passed, with comments. Please look at them, then finish the same way as before.\n"
    else
        "Tested: everything passed.\n");
    for (steps, 1..) |st, i| {
        if (st.checks.len == 0 and st.comment.len == 0) continue;
        if (st.title.len > 0) try w.print("\nStep {d}: {s}\n", .{ i, st.title }) else try w.writeAll("\n");
        for (st.checks) |c| try w.print("- [{s}] {s}{s}{s}\n", .{ if (c.pass) "x" else " ", c.text, if (c.note.len > 0) " — " else "", c.note });
        if (st.comment.len > 0) try w.print("Comment: {s}\n", .{st.comment});
    }
    if (note.len > 0) try w.print("\n{s}\n", .{note});
    return .{ .passed = passed, .commented = commented, .text = aw.written() };
}

test recordResults {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try recordResults(arena_state.allocator(), &.{
        .{ .title = "Start it", .comment = "Took a while to come up" },
        .{ .title = "Nothing here" },
        .{ .title = "The hero", .checks = &.{ .{ .text = "AVIF", .pass = true }, .{ .text = "WebP", .pass = false, .note = "blank in Safari" } } },
    }, "Otherwise fine");
    try std.testing.expect(!r.passed);
    try std.testing.expect(r.commented);
    const quiet = try recordResults(arena_state.allocator(), &.{.{ .title = "x", .checks = &.{.{ .text = "y", .pass = true }} }}, " ");
    try std.testing.expect(quiet.passed and !quiet.commented);
    const said = try recordResults(arena_state.allocator(), &.{.{ .title = "x", .comment = "I don't see it", .checks = &.{.{ .text = "y", .pass = true }} }}, "");
    try std.testing.expect(said.passed and said.commented);
    try std.testing.expect(std.mem.startsWith(u8, said.text, "Tested: everything passed, with comments."));
    try std.testing.expectEqualStrings(
        \\Tested: some checks failed. Please fix them, then finish the same way as before.
        \\
        \\Step 1: Start it
        \\Comment: Took a while to come up
        \\
        \\Step 3: The hero
        \\- [x] AVIF
        \\- [ ] WebP — blank in Safari
        \\
        \\Otherwise fine
        \\
    , r.text);
}

test "done: each ticket keeps the test plan its own done gave" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    // Both queue tickets, working in the same directory.
    try board.addProject(db, .{ .name = "qa", .dir = "/nonexistent" });
    const one = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "One" });
    const two = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Two" });
    const checks = struct {
        fn of(al: std.mem.Allocator, d: board.Db, key: []const u8) ![]const u8 {
            const p = readTestPlan(al, try board.getTicket(d, al, key)) orelse return "";
            return p.steps[0].checks[0];
        }
    }.of;

    try done(ctx, db, a, one, "did one", "## Checks\n- [ ] one works\n");
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try std.testing.expectEqualStrings("", try checks(a, db, two));

    // Two finishing with its own plan leaves One's alone; without one, it has none.
    try done(ctx, db, a, two, "did two", null);
    try std.testing.expectEqualStrings("", try checks(a, db, two));
    try done(ctx, db, a, two, "did two", "## Checks\n- [ ] two works\n");
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try std.testing.expectEqualStrings("two works", try checks(a, db, two));

    // A later round: no plan keeps it, "" drops it, one without checks is refused.
    try done(ctx, db, a, one, "again", null);
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try std.testing.expectError(error.BadTestPlan, done(ctx, db, a, one, "again", "## Setup\n1. x\n"));
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try done(ctx, db, a, one, "again", "");
    try std.testing.expectEqualStrings("", try checks(a, db, one));
}
