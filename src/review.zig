//! Reviewing and trying a ticket: gutter's window on its changes (with the
//! review guide Claude wrote, kept in the ticket at `done`), whose submitted review goes to the session, and
//! the handoff Claude gave `cl ticket done --test-plan` (kept in the
//! ticket): what it verified itself, a test plan of steps (commands run in
//! hidden tmux sessions, pages to open, checks) and an optional demo.
//!
//! gutter and launches run in tmux sessions named clg_<key> and clrun_<key>
//! (and automated reviews in clrv_<key>, autoreview.zig), outside cl's `cl_`
//! names so the chooser doesn't list them.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");
const config = @import("config.zig");

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

pub fn guidePath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/review-guide.md", .{dir});
}

pub fn reviewPath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/review.md", .{dir});
}

/// Where gutter keeps the review you haven't submitted yet (its output
/// file's name plus .draft.json; cl runs it with -dir .claude), restored
/// when it opens on the same -r. Out of the ticket's change, as .claude/ is.
pub fn draftPath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/review.md.draft.json", .{dir});
}

/// Move the review guide Claude wrote in `dir` into the ticket, so the next
/// ticket working there (a queue project's tickets share its checkout) can't
/// pick it up. No guide keeps the one from an earlier round. One written
/// before the ticket's session took it up is someone else's: dropped.
fn takeGuide(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8) !void {
    const path = try guidePath(a, dir);
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return;
    if (freshGuide(ctx, db, a, t, dir)) |p| {
        const md = try std.Io.Dir.cwd().readFileAlloc(ctx.io, p, a, .limited(4 << 20));
        try board.setReviewGuide(ctx, db, t.id, md);
    }
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

/// <dir>/.claude/review-guide.md when it was written since the ticket's
/// session took it up, else null.
fn freshGuide(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8) ?[]const u8 {
    const path = guidePath(a, dir) catch return null;
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return null;
    const started = board.startedAt(db, t.id) catch return null;
    return if (st.mtime.toSeconds() >= started) path else null;
}

/// Whether gutter has a guide for the ticket: its own, or one its session
/// wrote and hasn't said done with yet (or wrote before cl kept guides).
pub fn hasGuide(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) bool {
    if (t.review_guide.len > 0) return true;
    return freshGuide(ctx, db, a, t, ticketDir(db, a, t) catch return false) != null;
}

/// The ticket's guide as a file for gutter's -guide: its own, written to
/// the board's directory (guides/<key>.md), else `freshGuide`, else
/// /dev/null, so gutter doesn't fall back to a .claude/review-guide.md
/// another ticket left in the checkout.
fn guideFile(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, dir: []const u8) ![]const u8 {
    if (t.review_guide.len == 0) return freshGuide(ctx, db, a, t, dir) orelse "/dev/null";
    const guides = try std.fmt.allocPrint(a, "{s}/guides", .{try board.dirPath(ctx, a, cfg)});
    try std.Io.Dir.cwd().createDirPath(ctx.io, guides);
    const path = try std.fmt.allocPrint(a, "{s}/{s}.md", .{ guides, t.key });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = t.review_guide });
    return path;
}

fn sessionName(a: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(a, key);
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, lower });
}

// ---- gutter ----

/// Where gutter is: gutter.path when it is set, else `gutter` on PATH. Null
/// when it isn't installed (or gutter.path isn't an executable file): cl then
/// offers no gutter review.
pub fn findGutter(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) ?[]const u8 {
    if (cfg.gutter.path.len > 0) return if (isExecutable(ctx, cfg.gutter.path)) cfg.gutter.path else null;
    var dirs = std.mem.splitScalar(u8, ctx.env.get("PATH") orelse "", ':');
    while (dirs.next()) |d| {
        if (!std.fs.path.isAbsolute(d)) continue;
        const path = std.fs.path.join(a, &.{ d, "gutter" }) catch return null;
        if (isExecutable(ctx, path)) return path;
    }
    return null;
}

fn isExecutable(ctx: Ctx, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    if (st.kind == .directory) return false;
    std.Io.Dir.cwd().access(ctx.io, path, .{ .execute = true }) catch return false;
    return true;
}

test findGutter {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    try tmp.dir.createDirPath(io, "bin/gutter.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/gutter", .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/plain", .data = "x" });
    const bin = try std.fs.path.join(a, &.{ dir, "bin" });
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = io, .gpa = a, .perm = a, .env = &env, .home = "/tmp" };
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    // Nothing on PATH, nothing set: not installed.
    try env.put("PATH", "relative/bin:/nonexistent");
    try std.testing.expect(findGutter(ctx, a, cfg) == null);
    // On PATH.
    try env.put("PATH", try std.fmt.allocPrint(a, "/nonexistent:{s}", .{bin}));
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ bin, "gutter" }), findGutter(ctx, a, cfg).?);
    // gutter.path wins over PATH, and must be an executable file.
    cfg.gutter.path = try std.fs.path.join(a, &.{ bin, "plain" });
    try std.testing.expect(findGutter(ctx, a, cfg) == null);
    cfg.gutter.path = try std.fs.path.join(a, &.{ bin, "gutter.d" });
    try std.testing.expect(findGutter(ctx, a, cfg) == null);
    cfg.gutter.path = try std.fs.path.join(a, &.{ bin, "gutter" });
    try std.testing.expectEqualStrings(cfg.gutter.path, findGutter(ctx, a, cfg).?);
}

pub const not_installed = "gutter isn't installed: put it on PATH, or set gutter.path in ~/.config/cl/config";

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

pub const GutterError = error{ GutterFailed, GutterMissing };

/// Open gutter's window on the ticket's changes in clg_<key> (or reuse the
/// open one) and return its port on 127.0.0.1. gutter waits for Submit; the
/// review then lands in <dir>/.claude/review.md and the pane runs `cl ticket
/// gutter <key> --submitted`, which sends it to the session. Closing gutter
/// without submitting writes nothing. error.GutterMissing when gutter isn't
/// installed (`findGutter`).
pub fn startGutter(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !u16 {
    if (try gutterPort(ctx, a, t.key)) |p| return p;
    // Nothing to diff (`Project.repo`), and gutter would show a repo around it.
    if (!t.repo) return error.NoRepo;
    const gutter = findGutter(ctx, a, cfg) orelse return error.GutterMissing;
    const name = try sessionName(a, "clg_", t.key);
    // A gutter that already exited: start a fresh one.
    if (tmux.hasSession(ctx, name)) tmux.runQuiet(ctx, &.{ "kill-session", "-t", name }) catch {};
    const dir = try ticketDir(db, a, t);
    std.Io.Dir.cwd().createDirPath(ctx.io, try std.fmt.allocPrint(a, "{s}/.claude", .{dir})) catch {};
    std.Io.Dir.cwd().deleteFile(ctx.io, try reviewPath(a, dir)) catch {};
    const rev = try worktree.reviewRev(ctx, a, dir, t.base, t.change);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try ctx.exePath(&exe_buf);
    const script =
        \\cl=$1 key=$2 gutter=$3; shift 3
        \\if "$gutter" -sync -window "$@" > .claude/review.md; then exec "$cl" ticket gutter "$key" --submitted; fi
        \\rm -f .claude/review.md; exit 1
    ;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "new-session", "-d", "-s", name, "-c", dir, "--", "sh", "-c", script, "sh", exe, t.key, gutter });
    // -dir: its draft (`draftPath`) goes in .claude/, not the change.
    try argv.appendSlice(a, &.{ "-dir", ".claude", "-guide", guideFile(ctx, cfg, db, a, t, dir) catch "/dev/null" });
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
    \\The handoff is markdown given to `cl ticket done <key> --test-plan -` on stdin,
    \\in up to three sections, each under its own "# " heading:
    \\
    \\  # Verified     what you checked yourself, and what you saw
    \\  # Test plan    only what needs the human
    \\  # Demo         optional: a guided tour of something new to look at
    \\
    \\What goes where:
    \\
    \\- Check everything you can yourself before you finish: builds and tests,
    \\  commands and their output, scripts, API calls (curl), pages in a headless
    \\  browser, a separate sandbox board. List each in # Verified with what you
    \\  saw ("- `zig build test`: all 312 pass"). The board shows it read-only, as
    \\  "Checked by Claude". Never hand the human a step you could run and read.
    \\- # Test plan is for what you can't do (a real browser or phone, voice, the
    \\  human's accounts, how it looks or feels) and anything where you want their
    \\  judgment. Keep the step that starts what they'd try it on. With nothing
    \\  specific to check, give just that step: the board adds "Works as expected".
    \\- # Demo, when the change is something they'd want to see (a new feature, new
    \\  UI, a new command): a few steps with run:/open: buttons and what to look
    \\  at. It has no checks and never gates anything.
    \\
    \\Without any of these headings, the whole document is the test plan.
    \\
    \\The test plan and the demo walk the human through, one step at a time, like a
    \\wizard. Each "## " heading is a step, in order, and everything in them goes in
    \\a step (text before the first "## " is refused). In a step:
    \\
    \\  run: <command>     a button that runs it from the ticket's directory in the
    \\                     background (a server, a seed script); its output shows
    \\  wait: <url>        shows whether it answers yet (a server that is starting)
    \\  open: <url>        a button that opens the page in the browser
    \\  - [ ] <check>      test plan only: what to try and what they should see,
    \\                     Pass or Fail
    \\  other lines        what to do or look at ("- " and "1. " lists too)
    \\
    \\Nothing runs or opens until the human presses its button. Keep each step one
    \\focused task. Example:
    \\
    \\  # Verified
    \\  - `npm test`: 48 pass
    \\  - `curl -s localhost:4321/ | grep -c avif`: 3, the hero's sources
    \\  - The home page in headless Chromium: the hero is image/avif
    \\
    \\  # Test plan
    \\  ## Start the dev server
    \\  run: npm run dev
    \\  wait: http://localhost:4321
    \\
    \\  ## The hero in Safari
    \\  open: http://localhost:4321/
    \\  - [ ] In Safari on the phone it falls back to WebP and looks as sharp
    \\
    \\  # Demo
    \\  ## Start it
    \\  run: npm run dev
    \\  wait: http://localhost:4321
    \\
    \\  ## The new gallery
    \\  open: http://localhost:4321/gallery
    \\  Scroll down: images load as you reach them, with a blurred preview first.
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

/// The three parts of a handoff (format_help), trimmed; "" for a part it
/// doesn't have.
pub const Handoff = struct {
    verified: []const u8 = "",
    test_plan: []const u8 = "",
    demo: []const u8 = "",
};

/// Split a handoff at its "# Verified", "# Test plan" (or "# Test", "# Tests")
/// and "# Demo" headings, any case. Without any of them it is all test plan,
/// as handoffs were before. Another "# " line stays in the section it is in
/// (parseTestPlan skips it). Text before the first section goes at the start
/// of the test plan, and a section given twice is both, one after the other:
/// nothing is dropped here (`done` refuses text outside a step).
pub fn splitHandoff(a: std.mem.Allocator, md: []const u8) !Handoff {
    const Part = enum { verified, test_plan, demo };
    var parts: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    var cur: Part = .test_plan;
    var cur_start: usize = 0;
    var any = false;
    var in_code = false;
    var pos: usize = 0;
    const add = struct {
        fn to(al: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
            const t = std.mem.trim(u8, text, " \t\r\n");
            if (t.len == 0) return;
            if (buf.items.len > 0) try buf.appendSlice(al, "\n\n");
            try buf.appendSlice(al, t);
        }
    }.to;
    while (pos <= md.len) {
        const nl = std.mem.indexOfScalarPos(u8, md, pos, '\n') orelse md.len;
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, md[pos..nl], "\r"), " \t");
        if (std.mem.startsWith(u8, line, "```")) in_code = !in_code;
        const part: ?Part = if (in_code or !std.mem.startsWith(u8, line, "# ")) null else blk: {
            const h = std.mem.trim(u8, line[2..], " #:");
            if (std.ascii.eqlIgnoreCase(h, "verified")) break :blk .verified;
            if (std.ascii.eqlIgnoreCase(h, "demo")) break :blk .demo;
            if (std.ascii.eqlIgnoreCase(h, "test") or std.ascii.eqlIgnoreCase(h, "tests") or std.ascii.eqlIgnoreCase(h, "test plan")) break :blk .test_plan;
            break :blk null;
        };
        if (part) |p| {
            // Before the first: the test plan's (a "# CL-1: x" title, say).
            try add(a, &parts[@intFromEnum(cur)], md[cur_start..pos]);
            any = true;
            cur = p;
            cur_start = @min(nl + 1, md.len);
        }
        pos = nl + 1;
    }
    if (!any) return .{ .test_plan = std.mem.trim(u8, md, " \t\r\n") };
    try add(a, &parts[@intFromEnum(cur)], md[cur_start..]);
    return .{ .verified = parts[0].items, .test_plan = parts[1].items, .demo = parts[2].items };
}

/// Whether a test plan or demo has text before its first "## " step, which
/// parseTestPlan would skip (a "# " title is fine).
pub fn textOutsideSteps(md: []const u8) bool {
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "##")) return false;
        if (line.len > 0 and line[0] != '#') return true;
    }
    return false;
}

test textOutsideSteps {
    try std.testing.expect(!textOutsideSteps("# Title\n\n## A\n- [ ] a\nanything after\n"));
    try std.testing.expect(textOutsideSteps("- [ ] The new tab looks right\n"));
    try std.testing.expect(textOutsideSteps("Intro\n## A\n- [ ] a\n"));
    try std.testing.expect(!textOutsideSteps(""));
}

test splitHandoff {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const h = try splitHandoff(a,
        \\# Verified
        \\- `zig build test`: all pass
        \\
        \\# test plan
        \\## Start it
        \\run: x
        \\```
        \\# Demo inside a fence stays put
        \\```
        \\# Demo
        \\## Look
        \\open: http://localhost:1/
    );
    try std.testing.expectEqualStrings("- `zig build test`: all pass", h.verified);
    try std.testing.expectEqualStrings("## Start it\nrun: x\n```\n# Demo inside a fence stays put\n```", h.test_plan);
    try std.testing.expectEqualStrings("## Look\nopen: http://localhost:1/", h.demo);
    // No section headings: all test plan, its "# Title" included.
    const old = try splitHandoff(a, "# Test plan for CL-1\n## Checks\n- [ ] works\n");
    try std.testing.expectEqualStrings("# Test plan for CL-1\n## Checks\n- [ ] works", old.test_plan);
    try std.testing.expectEqualStrings("", old.verified);
    // "# Tests" counts; a part left out is "".
    const t = try splitHandoff(a, "# Tests\n## A\n- [ ] a\n");
    try std.testing.expectEqualStrings("## A\n- [ ] a", t.test_plan);
    try std.testing.expectEqualStrings("", t.demo);
    const v = try splitHandoff(a, "# Verified\n- ran it\n");
    try std.testing.expectEqualStrings("- ran it", v.verified);
    try std.testing.expectEqualStrings("", v.test_plan);
    // A preface goes before the test plan; a section given twice keeps both.
    const twice = try splitHandoff(a, "Intro\n# Verified\n- one\n# Test plan\n## A\n- [ ] a\n# Verified\n- two\n");
    try std.testing.expectEqualStrings("- one\n\n- two", twice.verified);
    try std.testing.expectEqualStrings("Intro\n\n## A\n- [ ] a", twice.test_plan);
}

/// The step the board adds to a test plan with no checks of its own.
pub const try_it_title = "Try it";
pub const try_it_check = "Works as expected";

/// The ticket's own test plan, from its session's handoff; null for none.
/// A plan without checks (only the step that starts the server, or none
/// beside a Verified list or a demo) ends with "Try it": "Works as expected", so the
/// human still records that they tried it.
pub fn ticketTestPlan(a: std.mem.Allocator, t: board.Ticket) ?TestPlan {
    if (t.test_plan.len == 0 and t.verified.len == 0 and t.demo.len == 0) return null;
    const p = if (t.test_plan.len > 0) parseTestPlan(a, t.test_plan) catch return null else TestPlan{};
    if (p.checkCount() > 0) return p;
    const steps = a.alloc(Step, p.steps.len + 1) catch return null;
    @memcpy(steps[0..p.steps.len], p.steps);
    steps[p.steps.len] = .{ .title = try_it_title, .checks = &.{try_it_check} };
    return .{ .steps = steps };
}

/// The ticket's demo (the same steps as a test plan, without checks); null
/// for none.
pub fn ticketDemo(a: std.mem.Allocator, t: board.Ticket) ?TestPlan {
    if (t.demo.len == 0) return null;
    const p = parseTestPlan(a, t.demo) catch return null;
    return if (p.steps.len > 0) p else null;
}

test ticketTestPlan {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tk = struct {
        fn of(f: anytype) board.Ticket {
            return std.mem.zeroInit(board.Ticket, f);
        }
    }.of;
    // A plan with checks is as given.
    const full = ticketTestPlan(a, tk(.{ .test_plan = "## Start\nrun: x\n## Look\n- [ ] it works\n", .verified = "- ran it" })).?;
    try std.testing.expectEqual(@as(usize, 2), full.steps.len);
    try std.testing.expectEqualStrings("it works", full.steps[1].checks[0]);
    // Only the step that starts it: "Try it" follows.
    const start = ticketTestPlan(a, tk(.{ .test_plan = "## Start\nrun: x\nwait: http://localhost:1\n" })).?;
    try std.testing.expectEqual(@as(usize, 2), start.steps.len);
    try std.testing.expectEqualStrings("x", start.steps[0].run);
    try std.testing.expectEqualStrings(try_it_title, start.steps[1].title);
    try std.testing.expectEqualStrings(try_it_check, start.steps[1].checks[0]);
    // Verified alone: just "Try it".
    const ver = ticketTestPlan(a, tk(.{ .verified = "- ran it" })).?;
    try std.testing.expectEqual(@as(usize, 1), ver.steps.len);
    try std.testing.expectEqual(@as(usize, 1), ver.checkCount());
    // A demo alone: just "Try it" too, so there is still a Test tab.
    const dem = ticketTestPlan(a, tk(.{ .demo = "## Look\nopen: http://x/\n" })).?;
    try std.testing.expectEqualStrings(try_it_title, dem.steps[0].title);
    // Nothing: none.
    try std.testing.expect(ticketTestPlan(a, tk(.{})) == null);
    try std.testing.expect(ticketDemo(a, tk(.{})) == null);
    try std.testing.expectEqualStrings("Look", ticketDemo(a, tk(.{ .demo = "## Look\nopen: http://x/\n" })).?.steps[0].title);
}

/// `board.finishRound` (the caller moves it on: `autoreview.startOnDone`),
/// with the handoff Claude gives (format_help: what it verified, the
/// test plan, a demo): null keeps the one from an earlier round, "" drops
/// it, and otherwise it replaces all three parts. The review guide Claude
/// wrote moves into the ticket (`takeGuide`). A handoff with nothing in it
/// is refused (error.BadTestPlan), as is one during Planning (a plan being
/// approved has nothing to try yet), and a demo with checks
/// (error.DemoChecks: they belong in the test plan), and text in the test
/// plan or demo before its first "## " step (error.TextOutsideSteps). `plan`, from a planning session, is
/// kept for the session that builds it and shown on the board; outside
/// Planning it is refused (error.BadPlan).
pub fn done(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, summary: []const u8, test_plan: ?[]const u8, plan: ?[]const u8) !void {
    const t = try board.getTicket(db, a, key);
    if (plan) |md| {
        if (t.stage != .planning or std.mem.trim(u8, md, " \n\t").len == 0) return error.BadPlan;
        try board.setPlan(ctx, db, t.id, md);
        _ = try board.addComment(ctx, db, a, key, "claude", md, false);
    }
    if (test_plan) |md| {
        if (t.stage == .planning) return error.BadTestPlan;
        const h = try splitHandoff(a, md);
        if (md.len > 0 and h.verified.len + h.test_plan.len + h.demo.len == 0) return error.BadTestPlan;
        // parseTestPlan would drop it, a check included, without a word.
        if (textOutsideSteps(h.test_plan) or textOutsideSteps(h.demo)) return error.TextOutsideSteps;
        if (h.demo.len > 0 and (try parseTestPlan(a, h.demo)).checkCount() > 0) return error.DemoChecks;
        try board.setHandoff(ctx, db, t.id, h.verified, h.test_plan, h.demo);
    }
    if (t.stage != .planning) if (ticketDir(db, a, t)) |dir| try takeGuide(ctx, db, a, t, dir) else |_| {};
    try board.finishRound(ctx, db, a, key, summary);
}

/// Which walk-through a launch belongs to: the test plan's steps or the demo's.
pub const Kind = enum {
    test_plan,
    demo,

    fn suffix(k: Kind) []const u8 {
        return switch (k) {
            .test_plan => "_s",
            .demo => "_d",
        };
    }
};

/// clrun_<key>_s<n> (a demo step: _d<n>): where step `n`'s command runs.
fn runName(a: std.mem.Allocator, key: []const u8, kind: Kind, n: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{d}", .{ try sessionName(a, "clrun_", key), kind.suffix(), n });
}

/// Run step `n`'s command (1-based; null: the first step with one) of the
/// test plan or the demo in its own tmux session, replacing a previous run
/// of it. Returns the step.
pub fn launch(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, kind: Kind, n: ?usize) !usize {
    const dir = try ticketDir(db, a, t);
    const plan = switch (kind) {
        .test_plan => ticketTestPlan(a, t) orelse return error.NoTestPlan,
        .demo => ticketDemo(a, t) orelse return error.NoDemo,
    };
    const i = plan.runStep(n) orelse return error.NoLaunch;
    const cmd = plan.steps[i - 1].run;
    const name = try runName(a, t.key, kind, i);
    try killExact(ctx, a, name);
    // `cl ...` steps run this cl, as the session's own would.
    try tmux.runQuiet(ctx, &.{ "new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", dir, "-e", try tmux.sessionPathEnv(ctx, a), "--", "sh", "-c", cmd });
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

/// Stop step `n`'s command (of the test plan or the demo), or (null) every
/// one the ticket started, the demo's too.
pub fn stopLaunch(ctx: Ctx, a: std.mem.Allocator, key: []const u8, kind: Kind, n: ?usize) !void {
    if (n) |i| return killExact(ctx, a, try runName(a, key, kind, i));
    return stopLaunchesBut(ctx, a, key, null);
}

/// Stop every command the ticket started but the one in session `spare`:
/// the session this process runs in (a test server finishing its own
/// ticket), which would end it halfway. The main server's sweep stops that
/// one a minute later.
pub fn stopLaunchesBut(ctx: Ctx, a: std.mem.Allocator, key: []const u8, spare: ?[]const u8) !void {
    const base = try sessionName(a, "clrun_", key);
    const names = tmux.run(ctx, &.{ "list-sessions", "-F", "#{session_name}" }) catch return;
    defer ctx.gpa.free(names);
    var it = std.mem.tokenizeScalar(u8, names, '\n');
    while (it.next()) |name| {
        if (spare) |s| if (std.mem.eql(u8, s, name)) continue;
        // Before steps, a ticket had one: clrun_<key>.
        if (std.mem.eql(u8, name, base)) {
            try killExact(ctx, a, name);
            continue;
        }
        if (std.mem.eql(u8, launchBase(name) orelse continue, base)) try killExact(ctx, a, name);
    }
}

/// The launch sessions (clrun_<key>_s<n>, a demo's _d<n>, or an old clrun_<key>) and
/// automated reviews (clrv_<key>) of tickets not in `live`: finished or
/// deleted ones.
pub fn staleLaunches(ctx: Ctx, a: std.mem.Allocator, live: []const []const u8) ![]const []const u8 {
    const names = tmux.run(ctx, &.{ "list-sessions", "-F", "#{session_name}" }) catch return &.{};
    defer ctx.gpa.free(names);
    var lower: std.ArrayList([]const u8) = .empty;
    for (live) |k| try lower.append(a, try std.ascii.allocLowerString(a, k));
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, names, '\n');
    while (it.next()) |name| {
        const key = launchKey(name) orelse continue;
        for (lower.items) |k| {
            if (std.mem.eql(u8, k, key)) break;
        } else try out.append(a, try a.dupe(u8, name));
    }
    return out.items;
}

/// The (lowercase) ticket key a launch session (or automated review)
/// belongs to.
fn launchKey(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "clrv_")) return if (name.len > "clrv_".len) name["clrv_".len..] else null;
    if (!std.mem.startsWith(u8, name, "clrun_")) return null;
    return (launchBase(name) orelse return name["clrun_".len..])["clrun_".len..];
}

/// clrun_<key> of a step's session (clrun_<key>_s<n> or _d<n>), else null.
fn launchBase(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "clrun_")) return null;
    const i = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    if (i < "clrun_".len) return null;
    const rest = name[i + 1 ..];
    if (rest.len < 2 or (rest[0] != 's' and rest[0] != 'd')) return null;
    _ = std.fmt.parseInt(usize, rest[1..], 10) catch return null;
    return name[0..i];
}

test "launchKey" {
    try std.testing.expectEqualStrings("cl-50", launchKey("clrun_cl-50_s1").?);
    try std.testing.expectEqualStrings("cl-50", launchKey("clrun_cl-50_s12").?);
    try std.testing.expectEqualStrings("cl-50", launchKey("clrun_cl-50").?);
    try std.testing.expectEqualStrings("cl-50", launchKey("clrun_cl-50_d2").?);
    try std.testing.expectEqualStrings("cl-50_x", launchKey("clrun_cl-50_x").?);
    try std.testing.expectEqualStrings("clrun_cl-50", launchBase("clrun_cl-50_d1").?);
    try std.testing.expect(launchBase("clrun_cl-50") == null);
    try std.testing.expect(launchBase("clrun_cl-50_s") == null);
    try std.testing.expect(launchKey("cl_cl-50_ab12") == null);
    try std.testing.expectEqualStrings("cl-50", launchKey("clrv_cl-50").?);
}

/// Stop one launch session by its full name.
pub fn killLaunch(ctx: Ctx, a: std.mem.Allocator, name: []const u8) !void {
    return killExact(ctx, a, name);
}

pub const LaunchState = struct {
    running: bool,
    /// The end of its output.
    output: []const u8,
};

/// Each step's run: its state, or null when it was never started (or was
/// stopped, or the step has no command).
pub fn launchStates(ctx: Ctx, a: std.mem.Allocator, key: []const u8, kind: Kind, plan: TestPlan) ![]?LaunchState {
    const out = try a.alloc(?LaunchState, plan.steps.len);
    for (plan.steps, out, 1..) |st, *o, i| {
        o.* = null;
        if (st.run.len == 0) continue;
        const name = try exact(a, try runName(a, key, kind, i));
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

/// A local app a test plan links to: how its URLs name it
/// ("events.localhost:4002", as a browser's `URL.host` does) and where it listens.
pub const LocalOrigin = struct { host: []const u8, addr: std.Io.net.IpAddress };

/// The local http apps the plan's pages (open: and URLs in what to do) are
/// on, each once: what cl web relays so they open from the phone.
pub fn localOrigins(a: std.mem.Allocator, plan: TestPlan) ![]LocalOrigin {
    var out: std.ArrayList(LocalOrigin) = .empty;
    for (plan.steps) |st| {
        var urls: std.ArrayList([]const u8) = .empty;
        try urls.appendSlice(a, st.open);
        for (st.do) |line| {
            var rest = line;
            while (urlIn(rest)) |u| {
                try urls.append(a, u);
                rest = rest[@intFromPtr(u.ptr) - @intFromPtr(rest.ptr) + u.len ..];
            }
        }
        for (urls.items) |url| {
            if (!std.ascii.startsWithIgnoreCase(url, "http://")) continue;
            const addr = localAddress(url) orelse continue;
            const uri = std.Uri.parse(url) catch continue;
            var buf: [std.Io.net.HostName.max_len]u8 = undefined;
            const name = std.ascii.lowerString(&buf, (uri.getHost(&buf) catch continue).bytes);
            const host = if (uri.port) |p| (if (p == 80) try a.dupe(u8, name) else try std.fmt.allocPrint(a, "{s}:{d}", .{ name, p })) else try a.dupe(u8, name);
            for (out.items) |o| {
                if (std.mem.eql(u8, o.host, host)) break;
            } else try out.append(a, .{ .host = host, .addr = addr });
        }
    }
    return out.toOwnedSlice(a);
}

test localOrigins {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md =
        \\## Start
        \\run: npm run dev
        \\wait: http://localhost:9999
        \\## Look
        \\open: http://localhost:4002/x
        \\open: http://Events.localhost:4002/
        \\open: https://localhost:4443/
        \\open: https://example.com/
        \\Then http://127.0.0.1:5173/a and http://localhost:4002/y.
        \\- [ ] It works
    ;
    const p = try parseTestPlan(a, md);
    const o = try localOrigins(a, p);
    try std.testing.expectEqual(@as(usize, 3), o.len);
    try std.testing.expectEqualStrings("localhost:4002", o[0].host);
    try std.testing.expectEqualStrings("events.localhost:4002", o[1].host);
    try std.testing.expectEqualStrings("127.0.0.1:5173", o[2].host);
    try std.testing.expectEqual(@as(u16, 4002), o[1].addr.getPort());
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
    /// null: not tested (you sent the results before getting to it).
    pass: ?bool = null,
    note: []const u8 = "",
};

/// One step's results: its checks and your comment on it.
pub const StepResult = struct {
    title: []const u8 = "",
    comment: []const u8 = "",
    checks: []const Check = &.{},
};

/// What you found, step by step, as a comment for the ticket, and whether all
/// passed (a check not tested hasn't). Steps with nothing to say (no checks,
/// no comment) are left out; a step none of whose checks were tested is one
/// line, and the first line names those steps so Claude knows they still
/// need testing.
pub fn recordResults(a: std.mem.Allocator, steps: []const StepResult, note: []const u8) !struct { passed: bool, commented: bool, untested: bool, text: []const u8 } {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    var failed = false;
    var untested = false;
    var commented = std.mem.trim(u8, note, " \n").len > 0;
    // Steps with a check not tested, as "2, 3".
    var skipped: std.Io.Writer.Allocating = .init(a);
    for (steps, 1..) |st, i| {
        var some = false;
        for (st.checks) |c| if (c.pass) |p| {
            if (!p) failed = true;
        } else {
            some = true;
        };
        if (some) {
            if (untested) try skipped.writer.writeAll(", ");
            try skipped.writer.print("{d}", .{i});
            untested = true;
        }
        if (std.mem.trim(u8, st.comment, " \n").len > 0) commented = true;
    }
    const which = skipped.written();
    const plural = std.mem.indexOfScalar(u8, which, ',') != null;
    if (untested) {
        try w.print("Tested in part: {s} The human sent these before testing everything: step{s} {s} still need{s} testing (the checks marked [?] or \"not tested\" below).\n", .{
            if (failed) "some checks failed. Please fix them, then finish the same way as before." else if (commented) "what was tested passed, with comments. Please look at them, then finish the same way as before." else "what was tested passed. Finish the same way as before.",
            if (plural) "s" else "",
            which,
            if (plural) "" else "s",
        });
    } else try w.writeAll(if (failed)
        "Tested: some checks failed. Please fix them, then finish the same way as before.\n"
    else if (commented)
        "Tested: everything passed, with comments. Please look at them, then finish the same way as before.\n"
    else
        "Tested: everything passed.\n");
    for (steps, 1..) |st, i| {
        if (st.checks.len == 0 and st.comment.len == 0) continue;
        const none = st.checks.len > 0 and for (st.checks) |c| {
            if (c.pass != null) break false;
        } else true;
        if (st.title.len > 0) try w.print("\nStep {d}: {s}{s}\n", .{ i, st.title, if (none) " (not tested)" else "" }) else try w.writeAll("\n");
        if (!none or st.title.len == 0) for (st.checks) |c| try w.print("- [{s}] {s}{s}{s}\n", .{
            if (c.pass) |p| (if (p) "x" else " ") else "?",
            c.text,
            if (c.note.len > 0) " — " else "",
            c.note,
        });
        if (st.comment.len > 0) try w.print("Comment: {s}\n", .{st.comment});
    }
    if (note.len > 0) try w.print("\n{s}\n", .{note});
    return .{ .passed = !failed and !untested, .commented = commented, .untested = untested, .text = aw.written() };
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
    // Sent after the first step: what wasn't reached is "not tested", and
    // nothing is "passed".
    const part = try recordResults(arena_state.allocator(), &.{
        .{ .title = "Start it", .checks = &.{ .{ .text = "Comes up", .pass = false, .note = "crashed" }, .{ .text = "Logs" } } },
        .{ .title = "The hero", .checks = &.{ .{ .text = "AVIF" }, .{ .text = "WebP" } } },
        .{ .title = "The footer", .checks = &.{.{ .text = "Links" }} },
    }, "");
    try std.testing.expect(!part.passed and part.untested and !part.commented);
    try std.testing.expectEqualStrings(
        \\Tested in part: some checks failed. Please fix them, then finish the same way as before. The human sent these before testing everything: steps 1, 2, 3 still need testing (the checks marked [?] or "not tested" below).
        \\
        \\Step 1: Start it
        \\- [ ] Comes up — crashed
        \\- [?] Logs
        \\
        \\Step 2: The hero (not tested)
        \\
        \\Step 3: The footer (not tested)
        \\
    , part.text);
    // Everything tested passed, but not everything was tested: not a pass.
    const half = try recordResults(arena_state.allocator(), &.{
        .{ .title = "a", .checks = &.{.{ .text = "y", .pass = true }} },
        .{ .title = "b", .checks = &.{.{ .text = "z" }} },
    }, "");
    try std.testing.expect(!half.passed and half.untested);
    try std.testing.expect(std.mem.startsWith(u8, half.text, "Tested in part: what was tested passed. Finish the same way as before. The human sent these before testing everything: step 2 still needs testing (the checks marked [?] or \"not tested\" below).\n"));
}

test "done: each ticket keeps the test plan its own done gave" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
            const p = ticketTestPlan(al, try board.getTicket(d, al, key)) orelse return "";
            for (p.steps) |st| if (st.checks.len > 0) return st.checks[0];
            return "";
        }
    }.of;

    try done(ctx, db, a, one, "did one", "## Checks\n- [ ] one works\n", null);
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try std.testing.expectEqualStrings("", try checks(a, db, two));

    // Two finishing with its own plan leaves One's alone; without one, it has none.
    try done(ctx, db, a, two, "did two", null, null);
    try std.testing.expectEqualStrings("", try checks(a, db, two));
    try done(ctx, db, a, two, "did two", "## Checks\n- [ ] two works\n", null);
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try std.testing.expectEqualStrings("two works", try checks(a, db, two));

    // A later round: no plan keeps it, "" drops it, an empty one or a demo
    // with checks is refused.
    try done(ctx, db, a, one, "again", null, null);
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try std.testing.expectError(error.BadTestPlan, done(ctx, db, a, one, "again", "# Verified\n\n# Demo\n", null));
    try std.testing.expectError(error.DemoChecks, done(ctx, db, a, one, "again", "# Demo\n## Look\n- [ ] x\n", null));
    // Text outside a "## " step would be dropped: refused instead.
    try std.testing.expectError(error.TextOutsideSteps, done(ctx, db, a, one, "again", "# Verified\n- tests pass\n# Test plan\n- [ ] The new tab looks right\n", null));
    try std.testing.expectError(error.TextOutsideSteps, done(ctx, db, a, one, "again", "# Demo\nLook at the new tab.\n", null));
    try std.testing.expectEqualStrings("one works", try checks(a, db, one));
    try done(ctx, db, a, one, "again", "", null);
    try std.testing.expectEqualStrings("", try checks(a, db, one));

    // A plan without checks gets "Works as expected"; Verified alone is
    // accepted and gets just that.
    try done(ctx, db, a, one, "again", "## Setup\n1. x\n", null);
    try std.testing.expectEqualStrings(try_it_check, try checks(a, db, one));
    try done(ctx, db, a, one, "again", "# Verified\n- ran it\n", null);
    const t1 = try board.getTicket(db, a, one);
    try std.testing.expectEqualStrings("- ran it", t1.verified);
    try std.testing.expectEqualStrings("", t1.test_plan);
    try std.testing.expectEqualStrings(try_it_check, try checks(a, db, one));
    // All three parts are kept, and a new handoff replaces all three.
    try done(ctx, db, a, one, "again", "# Verified\n- ran it\n# Test plan\n## A\n- [ ] a\n# Demo\n## Look\nopen: http://x/\n", null);
    try std.testing.expectEqualStrings("a", try checks(a, db, one));
    try std.testing.expectEqualStrings("Look", ticketDemo(a, try board.getTicket(db, a, one)).?.steps[0].title);
    try done(ctx, db, a, one, "again", "## B\n- [ ] b\n", null);
    const t2 = try board.getTicket(db, a, one);
    try std.testing.expectEqualStrings("", t2.verified);
    try std.testing.expectEqualStrings("", t2.demo);
}

test "done: a planning session's plan is kept and shown; elsewhere it is refused" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/nonexistent" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Plan me", .plan = true });
    try std.testing.expectError(error.BadPlan, done(ctx, db, a, k, "Plan ready", null, " \n"));
    try done(ctx, db, a, k, "Plan ready", null, "## Steps\n1. retry\n");
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqualStrings("## Steps\n1. retry\n", t.plan_md);
    try std.testing.expectEqual(board.Stage.planning, t.stage);
    const cs = try board.comments(db, a, t.id);
    try std.testing.expect(cs.len >= 1);
    try std.testing.expectEqualStrings("## Steps\n1. retry\n", cs[0].body);
    _ = try board.approve(ctx, db, a, k);
    try std.testing.expectError(error.BadPlan, done(ctx, db, a, k, "built", null, "## Steps\n"));
}

test "done: each ticket keeps the review guide its own session wrote" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(ctx.io, &dir_buf)];
    try tmp.dir.createDirPath(ctx.io, ".claude");
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    // Queue tickets sharing the project's checkout.
    try board.addProject(db, .{ .name = "qa", .dir = dir });
    const one = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "One" });
    const two = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Two" });
    const guide = struct {
        fn of(d: board.Db, al: std.mem.Allocator, key: []const u8) ![]const u8 {
            return (try board.getTicket(d, al, key)).review_guide;
        }
    }.of;

    // One's guide moves into One, out of the checkout.
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/review-guide.md", .data = "# One\n" });
    try done(ctx, db, a, one, "did one", null, null);
    try std.testing.expectEqualStrings("# One\n", try guide(db, a, one));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(ctx.io, ".claude/review-guide.md", .{}));

    // Two wrote none: it has none, and One keeps its own.
    try done(ctx, db, a, two, "did two", null, null);
    try std.testing.expectEqualStrings("", try guide(db, a, two));
    try std.testing.expectEqualStrings("# One\n", try guide(db, a, one));

    // A later round without a new guide keeps the old one; a new one replaces it.
    try done(ctx, db, a, one, "again", null, null);
    try std.testing.expectEqualStrings("# One\n", try guide(db, a, one));
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/review-guide.md", .data = "# One, again\n" });
    try done(ctx, db, a, one, "again", null, null);
    try std.testing.expectEqualStrings("# One, again\n", try guide(db, a, one));

    // A guide left from before Two's session started (one that never said
    // done) isn't Two's: dropped.
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/review-guide.md", .data = "# Stale\n" });
    const t2 = try board.getTicket(db, a, two);
    try db.exec("INSERT INTO events (ticket, kind, detail, at) VALUES (?1, 'started', '', ?2)", .{ t2.id, ctx.nowSeconds() + 60 });
    try done(ctx, db, a, two, "did two", null, null);
    try std.testing.expectEqualStrings("", try guide(db, a, two));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(ctx.io, ".claude/review-guide.md", .{}));

    // Before done, the board counts a guide only when Two's session wrote it.
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/review-guide.md", .data = "# Stale\n" });
    try std.testing.expect(!hasGuide(ctx, db, a, try board.getTicket(db, a, two)));
    try db.exec("UPDATE events SET at = ?2 WHERE ticket = ?1", .{ t2.id, ctx.nowSeconds() - 60 });
    try std.testing.expect(hasGuide(ctx, db, a, try board.getTicket(db, a, two)));
}
