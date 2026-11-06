//! What a ticket's session is waiting on, from local files and tmux only:
//! Claude's session registry says it is waiting (and on what), its transcript
//! holds the pending tool call (an AskUserQuestion's questions and options,
//! or the command a permission prompt is about), and the pane shows the menu
//! with its numbered options. These become the ticket's `question` and
//! `input` flags, with details the board shows and answers from.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const config = @import("config.zig");
const board = @import("board.zig");

/// A tool call in the transcript with no result yet.
pub const Pending = struct {
    id: []const u8 = "",
    name: []const u8,
    input: std.json.Value,
};

/// The newest tool call that has no result, ignoring subagents' calls.
pub fn pendingTool(a: std.mem.Allocator, jsonl: []const u8) ?Pending {
    var open: std.StringArrayHashMapUnmanaged(Pending) = .empty;
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const obj = switch (v) {
            .object => |o| o,
            else => continue,
        };
        if (obj.get("isSidechain")) |s| if (s == .bool and s.bool) continue;
        const msg = switch (obj.get("message") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const content = switch (msg.get("content") orelse continue) {
            .array => |arr| arr.items,
            else => continue,
        };
        for (content) |block| {
            const b = switch (block) {
                .object => |o| o,
                else => continue,
            };
            const kind = str(b.get("type")) orelse continue;
            if (std.mem.eql(u8, kind, "tool_use")) {
                const id = str(b.get("id")) orelse continue;
                open.put(a, id, .{ .id = id, .name = str(b.get("name")) orelse "", .input = b.get("input") orelse .null }) catch {};
            } else if (std.mem.eql(u8, kind, "tool_result")) {
                _ = open.orderedRemove(str(b.get("tool_use_id")) orelse continue);
            }
        }
    }
    const vals = open.values();
    return if (vals.len > 0) vals[vals.len - 1] else null;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

test pendingTool {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        \\{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"s1","name":"Read","input":{}}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"AskUserQuestion","input":{"questions":[{"question":"Which color?"}]}}]}}
    ;
    const p = pendingTool(a, data).?;
    try std.testing.expectEqualStrings("AskUserQuestion", p.name);
    try std.testing.expectEqualStrings("t2", p.id);
    try std.testing.expect(pendingTool(a, data[0 .. std.mem.indexOf(u8, data, "\n{\"type\":\"assistant\",\"isSidechain\"").?]) == null);
}

pub const Option = struct {
    n: u8,
    label: []const u8,
};

/// The numbered menu nearest the bottom of the pane ("❯ 1. Yes", "  2. No").
/// Description lines under an option are left out.
pub fn menuOptions(a: std.mem.Allocator, pane: []const u8) ![]Option {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, pane, '\n');
    while (it.next()) |l| try lines.append(a, l);
    var out: std.ArrayList(Option) = .empty;
    var i = lines.items.len;
    var gap: usize = 0;
    // Walk up from the bottom: collect options until the run of numbers
    // reaches 1. Options sit a line or two apart (descriptions, a rule);
    // a bigger gap means the menu ended and this is other text.
    while (i > 0) {
        i -= 1;
        const opt = parseOption(lines.items[i]) orelse {
            if (out.items.len > 0) {
                gap += 1;
                if (gap > 4) break;
            }
            continue;
        };
        gap = 0;
        if (out.items.len > 0 and opt.n != out.items[out.items.len - 1].n - 1) {
            if (opt.n > out.items[out.items.len - 1].n) break;
            continue;
        }
        try out.append(a, .{ .n = opt.n, .label = try a.dupe(u8, opt.label) });
        if (opt.n == 1) break;
    }
    std.mem.reverse(Option, out.items);
    if (out.items.len == 0 or out.items[0].n != 1) return &.{};
    return out.toOwnedSlice(a);
}

fn parseOption(line: []const u8) ?Option {
    // Trim whole symbols, not bytes: "│" and "❯" share their first byte.
    var s = line;
    while (true) {
        const before = s.len;
        s = std.mem.trimStart(u8, s, " ");
        for ([_][]const u8{ "│", "❯", "\u{a0}" }) |p| {
            if (std.mem.startsWith(u8, s, p)) s = s[p.len..];
        }
        if (s.len == before) break;
    }
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    if (n == 0 or n > 2 or n + 1 >= s.len or s[n] != '.' or s[n + 1] != ' ') return null;
    const num = std.fmt.parseInt(u8, s[0..n], 10) catch return null;
    var label = s[n + 2 ..];
    // A question with previews draws the preview box to the right.
    for ([_][]const u8{ "┌", "│", "├", "└" }) |box| {
        if (std.mem.indexOf(u8, label, box)) |at| label = label[0..at];
    }
    return .{ .n = num, .label = std.mem.trim(u8, label, " ") };
}

test menuOptions {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const pane =
        \\ 1. Old list item from earlier
        \\ Do you want to proceed?
        \\ ❯\u{a0}1. Yes
        \\   2. Yes, and always allow access to
        \\      /tmp/x from this project
        \\   3. No
        \\ Esc to cancel · Tab to amend
    ;
    const opts = try menuOptions(arena_state.allocator(), pane);
    try std.testing.expectEqual(@as(usize, 3), opts.len);
    try std.testing.expectEqualStrings("Yes, and always allow access to", opts[1].label);
    try std.testing.expectEqualStrings("No", opts[2].label);

    const question =
        \\Ticket text with a list:
        \\1. Write a review guide
        \\
        \\Which size?
        \\
        \\❯ 1. Small
        \\     Small size
        \\  2. Large
        \\     Large size
        \\  3. Type something.
        \\────────────
        \\  4. Chat about this
        \\
        \\Enter to select
    ;
    const preview = try menuOptions(arena_state.allocator(),
        \\❯ 1. Small                        ┌──────────┐
        \\  2. Large                        │ [ small ]│
        \\                                  └──────────┘
    );
    try std.testing.expectEqualStrings("Small", preview[0].label);
    try std.testing.expectEqualStrings("Large", preview[1].label);

    const q = try menuOptions(arena_state.allocator(), question);
    try std.testing.expectEqual(@as(usize, 4), q.len);
    try std.testing.expectEqualStrings("Small", q[0].label);
}

/// A one-line summary of a tool call: the command, the file, or the JSON.
fn summarize(a: std.mem.Allocator, p: Pending) ![]const u8 {
    if (p.input == .object) {
        for ([_][]const u8{ "command", "file_path", "url", "pattern", "description" }) |k| {
            if (str(p.input.object.get(k))) |v| return v;
        }
    }
    const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(p.input, .{})});
    return json[0..@min(json.len, 300)];
}

/// The newest part of the transcript (big tool results make it long).
fn transcriptTail(ctx: Ctx, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(ctx.io, path, .{});
    defer file.close(ctx.io);
    const len = try file.length(ctx.io);
    const start = len -| 1024 * 1024;
    const buf = try a.alloc(u8, @intCast(len - start));
    const n = try file.readPositionalAll(ctx.io, buf, start);
    var data = buf[0..n];
    if (start > 0) data = data[(std.mem.indexOfScalar(u8, data, '\n') orelse return "") + 1 ..];
    return data;
}

/// The tool call a session is waiting on, from its transcript; null when
/// none is pending or there is no transcript to read.
pub fn pendingFor(ctx: Ctx, a: std.mem.Allocator, info: claude.Info) ?Pending {
    if (info.session_id.len == 0 or info.cwd.len == 0 or info.config_dir.len == 0) return null;
    const path = claude.transcriptPath(a, info.config_dir, info.cwd, info.session_id) catch return null;
    const data = transcriptTail(ctx, a, path) catch return null;
    return pendingTool(a, data);
}

/// What a session waits on before it is answered, to tell afterwards
/// whether the answer got through.
pub const Waiting = struct {
    /// The pending tool call's id, "" when the transcript can't be read.
    tool_id: []const u8 = "",

    pub fn of(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, tmux_name: []const u8) Waiting {
        const statuses = claude.readStatuses(ctx, a, cfg) catch return .{};
        const info = statuses.get(tmux_name) orelse return .{};
        const p = pendingFor(ctx, a, info) orelse return .{};
        return .{ .tool_id = p.id };
    }

    /// Whether the session took the answer typed into it: it stopped
    /// waiting, or the tool call it waited on has its result (it may be
    /// waiting again, on the next one). An approved command can run for a
    /// while before it has a result, so stopping waiting counts on its own.
    /// Checks until it has or `timeout_ms` runs out.
    pub fn answered(self: Waiting, ctx: Ctx, cfg: config.Config, tmux_name: []const u8, timeout_ms: i64) bool {
        var waited: i64 = 0;
        while (true) : (waited += 250) {
            if (self.answeredNow(ctx, cfg, tmux_name)) return true;
            if (waited >= timeout_ms) return false;
            ctx.sleepMs(250);
        }
    }

    fn answeredNow(self: Waiting, ctx: Ctx, cfg: config.Config, tmux_name: []const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const statuses = claude.readStatuses(ctx, a, cfg) catch return false;
        const info = statuses.get(tmux_name) orelse return false;
        if (info.status != .waiting and info.status != .blocked) return true;
        if (self.tool_id.len == 0) return false;
        const p = pendingFor(ctx, a, info) orelse return true;
        return !std.mem.eql(u8, p.id, self.tool_id);
    }
};

/// Flag details the board shows: what is asked and the menu's options.
pub const Ask = struct {
    /// "question" or "permission".
    kind: []const u8,
    /// The tool waiting (AskUserQuestion, Bash, Edit, ...).
    tool: []const u8 = "",
    /// For permission prompts: the command, file or URL.
    summary: []const u8 = "",
    /// For questions: AskUserQuestion's own input (questions, options).
    questions: std.json.Value = .null,
    /// The menu on screen right now.
    options: []const Option = &.{},
};

/// Whether a waiting session is on an AskUserQuestion menu rather than a
/// permission prompt: the pending tool call says so, or, when the transcript
/// doesn't have it (Claude writes the call only once it is answered), the
/// registry's "input needed" (a permission prompt is "permission prompt").
pub fn isQuestion(pend: ?Pending, info: ?claude.Info) bool {
    if (pend) |p| return std.mem.eql(u8, p.name, "AskUserQuestion");
    const i = info orelse return false;
    return std.mem.indexOf(u8, i.waiting_for, "input") != null;
}

/// Whether the AskUserQuestion menu at the bottom of the pane is the kind
/// with a preview beside its options. There a number key only moves to its
/// option and Enter picks it; elsewhere the number picks it at once.
pub fn previewMenu(pane: []const u8) bool {
    const footer = std.mem.lastIndexOf(u8, pane, "Enter to select") orelse return false;
    // The footer ends the menu (a narrow pane wraps it onto more lines);
    // after it, it may only go on, not start another menu or prompt.
    const rest = pane[footer..];
    if (std.mem.indexOf(u8, rest, "❯") != null or std.mem.count(u8, std.mem.trimEnd(u8, rest, " \n"), "\n") > 2) return false;
    // Compare without spaces, which wrapping may have turned into line breaks.
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    for (rest) |ch| if (!std.ascii.isWhitespace(ch) and n < buf.len) {
        buf[n] = ch;
        n += 1;
    };
    return std.mem.indexOf(u8, buf[0..n], "ntoaddnotes") != null;
}

test previewMenu {
    try std.testing.expect(previewMenu(
        \\Which line?
        \\❯ 1. Both lines                   ┌───────────────┐
        \\  2. from one                     │ const one = 1;│
        \\                                  └───────────────┘
        \\                                  Notes: press n to add notes
        \\──────────────
        \\  Chat about this
        \\Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
        \\
    ));
    try std.testing.expect(!previewMenu(
        \\Which size?
        \\❯ 1. Small
        \\  2. Large
        \\  3. Type something.
        \\──────────────
        \\  4. Chat about this
        \\Enter to select · ↑/↓ to navigate · Esc to cancel
    ));
    try std.testing.expect(!previewMenu("Enter to select · n to add notes\n❯ \n"));
    // A narrow pane wraps the footer.
    try std.testing.expect(previewMenu("❯ 1. Small   ┌──┐\nEnter to select · ↑/↓ to navigate · n to add\nnotes · Tab to switch questions ·\nEsc to cancel\n\n"));
}

/// How many questions the AskUserQuestion menu at the bottom of the pane
/// asks, from its tab bar ("←  ☐ Size  ☒ Color  ✔ Submit  →"; a lone
/// question has no bar). 0 when no menu is on screen.
pub fn menuQuestions(pane: []const u8) usize {
    const footer = std.mem.lastIndexOf(u8, pane, "Enter to select") orelse return 0;
    const top = pane[0..footer];
    const bar = std.mem.lastIndexOf(u8, top, "←") orelse return 1;
    const end = std.mem.indexOfPos(u8, top, bar, "→") orelse return 1;
    // A bar further up belongs to an earlier menu: this one starts below a rule.
    if (std.mem.indexOf(u8, top[bar..end], "Submit") == null) return 1;
    return std.mem.count(u8, top[bar..end], "☐") + std.mem.count(u8, top[bar..end], "☒");
}

test menuQuestions {
    try std.testing.expectEqual(@as(usize, 2), menuQuestions(
        \\←  ☒ Size  ☐ Color  ✔ Submit  →
        \\Which color?
        \\❯ 1. Red
        \\Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    ));
    try std.testing.expectEqual(@as(usize, 1), menuQuestions(
        \\ ☐ Line
        \\Which line?
        \\❯ 1. Both lines
        \\Enter to select · ↑/↓ to navigate · Esc to cancel
    ));
    try std.testing.expectEqual(@as(usize, 0), menuQuestions("❯ \n"));
}

/// Update the ticket's `question` and `input` flags from its session.
pub fn sync(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, info: ?claude.Info, status: claude.Status) !void {
    const waiting = status == .waiting or status == .blocked;
    if (!waiting) {
        try clearAuto(ctx, db, t.id, board.flag_question);
        try clearAuto(ctx, db, t.id, board.flag_input);
        return;
    }
    const pane_raw = tmux.capturePlainLines(ctx, t.tmux, 60) catch "";
    const pane = try a.dupe(u8, pane_raw);
    if (pane_raw.len > 0) ctx.gpa.free(pane_raw);
    var ask: Ask = .{ .kind = "permission", .options = try menuOptions(a, pane) };
    const pend: ?Pending = if (info) |inf| pendingFor(ctx, a, inf) else null;
    const asking = isQuestion(pend, info);
    if (pend) |p| {
        ask.tool = p.name;
        if (asking) {
            if (p.input == .object) ask.questions = p.input.object.get("questions") orelse .null;
        } else ask.summary = try summarize(a, p);
    }
    const detail = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(if (asking) Ask{ .kind = "question", .tool = ask.tool, .questions = ask.questions, .options = ask.options } else ask, .{})});
    if (asking) {
        try clearAuto(ctx, db, t.id, board.flag_input);
        try board.setFlagId(ctx, db, t.id, board.flag_question, "auto", detail);
    } else {
        try clearAuto(ctx, db, t.id, board.flag_question);
        try board.setFlagId(ctx, db, t.id, board.flag_input, "auto", detail);
    }
}

/// Clear a flag the board set itself, leaving one you set by hand.
fn clearAuto(ctx: Ctx, db: board.Db, id: i64, kind: []const u8) !void {
    if ((try db.int("SELECT 1 FROM flags WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL AND source = 'auto'", .{ id, kind })) == null) return;
    try board.clearFlagId(ctx, db, id, kind);
}
