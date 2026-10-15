//! Interactive chooser: session list on the left, live pane preview on the right.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const launch = @import("launch.zig");
const sgr = @import("sgr.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

const Mode = union(enum) {
    list,
    confirm_kill,
    input: Input,
};

const Input = enum { filter, rename, send, new_dir, new_name, new_profile, new_message };

const PreviewLine = []sgr.Segment;

const App = struct {
    ctx: Ctx,
    cfg: config.Config,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    loop: *vaxis.Loop(Event),

    arena_state: std.heap.ArenaAllocator,
    /// Lives across refreshes: form fields and the filter string.
    form_state: std.heap.ArenaAllocator,
    sessions: []tmux.Session = &.{},
    statuses: claude.StatusMap = .empty,
    preview: []PreviewLine = &.{},
    preview_of: []const u8 = "",
    cursor: usize = 0,
    mode: Mode = .list,
    input: vaxis.widgets.TextInput,
    filter: []const u8 = "",
    message: []const u8 = "",
    last_refresh_ms: i64 = 0,
    dirty: bool = true,
    quit: bool = false,
    pending_g: bool = false,
    /// Tab toggles per-session details (directory, tmux name, Claude's name).
    expanded: bool = false,
    /// First list line drawn (keeps the cursor on screen).
    scroll: usize = 0,
    // state for the "new session" form
    new_dir: []const u8 = "",
    new_name: []const u8 = "",
    new_profile: []const u8 = "",

    fn arena(self: *App) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn form(self: *App) std.mem.Allocator {
        return self.form_state.allocator();
    }

    /// Indices of sessions passing the filter, grouped by status (needs input first).
    fn visible(self: *App, buf: []usize) []usize {
        var n: usize = 0;
        for (self.sessions, 0..) |s, i| {
            if (self.filter.len == 0 or std.mem.indexOf(u8, s.name, self.filter) != null or
                std.mem.indexOf(u8, s.dir, self.filter) != null) {
                buf[n] = i;
                n += 1;
            }
        }
        const vis = buf[0..n];
        std.sort.insertion(usize, vis, self, lessByGroup);
        return vis;
    }

    fn lessByGroup(self: *App, a: usize, b: usize) bool {
        return self.status(self.sessions[a]).rank() < self.status(self.sessions[b]).rank();
    }

    fn status(self: *App, s: tmux.Session) claude.Status {
        return claude.statusFor(self.ctx, self.statuses, s);
    }

    fn selected(self: *App) ?tmux.Session {
        var buf: [1024]usize = undefined;
        const vis = self.visible(&buf);
        if (vis.len == 0) return null;
        if (self.cursor >= vis.len) self.cursor = vis.len - 1;
        return self.sessions[vis[self.cursor]];
    }

    fn refresh(self: *App) !void {
        const keep = if (self.selected()) |s| try self.ctx.gpa.dupe(u8, s.tmux_name) else null;
        defer if (keep) |k| self.ctx.gpa.free(k);
        _ = self.arena_state.reset(.retain_capacity);
        self.preview = &.{};
        self.sessions = try tmux.list(self.ctx, self.arena());
        self.statuses = try claude.readStatuses(self.ctx, self.arena(), self.cfg);
        if (keep) |k| self.selectByName(k);
        try self.loadPreview();
        self.last_refresh_ms = std.Io.Timestamp.now(self.ctx.io, .real).toMilliseconds();
        self.dirty = true;
    }

    fn selectByName(self: *App, tmux_name: []const u8) void {
        var buf: [1024]usize = undefined;
        const vis = self.visible(&buf);
        for (vis, 0..) |si, vi| {
            if (std.mem.eql(u8, self.sessions[si].tmux_name, tmux_name)) {
                self.cursor = vi;
                return;
            }
        }
    }

    fn loadPreview(self: *App) !void {
        const s = self.selected() orelse {
            self.preview = &.{};
            return;
        };
        const rows: usize = @max(1, self.vx.window().height);
        const raw = tmux.capture(self.ctx, s.tmux_name, rows) catch {
            self.preview = &.{};
            return;
        };
        defer self.ctx.gpa.free(raw);
        var lines: std.ArrayList(PreviewLine) = .empty;
        var it = std.mem.splitScalar(u8, raw, '\n');
        var style: vaxis.Style = .{};
        while (it.next()) |line| {
            const segs = try sgr.parseLine(self.arena(), try self.arena().dupe(u8, line), style);
            if (segs.len > 0) style = segs[segs.len - 1].style;
            try lines.append(self.arena(), segs);
        }
        // keep the last `rows` lines
        const all = lines.items;
        self.preview = if (all.len > rows) try self.arena().dupe(PreviewLine, all[all.len - rows ..]) else try self.arena().dupe(PreviewLine, all);
        self.preview_of = s.tmux_name;
    }

    fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.allocPrint(self.arena(), fmt, args) catch "";
        self.dirty = true;
    }

    fn handleKey(self: *App, key: vaxis.Key) !void {
        self.dirty = true;
        switch (self.mode) {
            .list => try self.handleListKey(key),
            .confirm_kill => {
                if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
                    if (self.selected()) |s| {
                        tmux.kill(self.ctx, s.tmux_name) catch {};
                        self.setMessage("killed {s}", .{s.name});
                    }
                    try self.refresh();
                }
                self.mode = .list;
            },
            .input => |kind| {
                if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
                    self.input.clearAndFree();
                    self.mode = .list;
                    if (kind == .filter) self.filter = "";
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    const owned = try self.input.toOwnedSlice();
                    defer self.ctx.gpa.free(owned);
                    const text = try self.form().dupe(u8, owned);
                    self.input.clearAndFree();
                    try self.submitInput(kind, text);
                } else {
                    try self.input.update(.{ .key_press = key });
                    if (kind == .filter) {
                        self.filter = try std.mem.concat(self.form(), u8, &.{ self.input.buf.firstHalf(), self.input.buf.secondHalf() });
                    }
                }
            },
        }
    }

    fn handleListKey(self: *App, key: vaxis.Key) !void {
        var buf: [1024]usize = undefined;
        const count = self.visible(&buf).len;
        if (key.matches('g', .{})) {
            if (self.pending_g) {
                self.cursor = 0;
                self.pending_g = false;
            } else self.pending_g = true;
            try self.loadPreview();
            return;
        }
        self.pending_g = false;
        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            self.quit = true;
        } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (count > 0 and self.cursor + 1 < count) self.cursor += 1;
            try self.loadPreview();
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.cursor > 0) self.cursor -= 1;
            try self.loadPreview();
        } else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
            if (count > 0) self.cursor = count - 1;
            try self.loadPreview();
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('l', .{})) {
            if (self.selected()) |s| try self.attach(s.tmux_name);
        } else if (key.matches('d', .{}) or key.matches('x', .{})) {
            if (self.selected() != null) self.mode = .confirm_kill;
        } else if (key.matches('r', .{})) {
            if (self.selected()) |s| {
                try self.input.insertSliceAtCursor(s.name);
                self.mode = .{ .input = .rename };
            }
        } else if (key.matches('s', .{})) {
            if (self.selected() != null) self.mode = .{ .input = .send };
        } else if (key.matches('/', .{})) {
            self.mode = .{ .input = .filter };
        } else if (key.matches('n', .{})) {
            _ = self.form_state.reset(.retain_capacity);
            self.filter = "";
            const cwd = std.process.currentPathAlloc(self.ctx.io, self.arena()) catch "";
            try self.input.insertSliceAtCursor(try self.ctx.shortenHomeIn(self.arena(), cwd));
            self.mode = .{ .input = .new_dir };
        } else if (key.matches('R', .{}) or key.matches('r', .{ .ctrl = true })) {
            try self.refresh();
        } else if (key.matches(vaxis.Key.tab, .{})) {
            self.expanded = !self.expanded;
        }
    }

    fn submitInput(self: *App, kind: Input, text: []const u8) !void {
        self.mode = .list;
        switch (kind) {
            .filter => {
                self.filter = text;
                self.cursor = 0;
            },
            .rename => if (self.selected()) |s| {
                if (text.len > 0) tmux.rename(self.ctx, s.tmux_name, text) catch {};
                try self.refresh();
            },
            .send => if (self.selected()) |s| {
                if (text.len > 0) tmux.sendLine(self.ctx, s.tmux_name, text) catch {};
                self.setMessage("sent to {s}", .{s.name});
            },
            .new_dir => {
                self.new_dir = text;
                const expanded = try self.ctx.expandHome(text);
                defer self.ctx.gpa.free(expanded);
                try self.input.insertSliceAtCursor(std.fs.path.basename(expanded));
                self.mode = .{ .input = .new_name };
            },
            .new_name => {
                self.new_name = text;
                try self.input.insertSliceAtCursor(self.cfg.default);
                self.mode = .{ .input = .new_profile };
            },
            .new_profile => {
                self.new_profile = text;
                self.mode = .{ .input = .new_message };
            },
            .new_message => {
                const tmux_name = launch.create(self.ctx, self.cfg, .{
                    .dir = self.new_dir,
                    .name = self.new_name,
                    .profile = if (self.new_profile.len > 0) self.new_profile else null,
                    .message = text,
                }) catch |err| {
                    self.setMessage("launch failed: {s}", .{@errorName(err)});
                    return;
                };
                try self.refresh();
                try self.attach(tmux_name);
            },
        }
    }

    fn attach(self: *App, tmux_name: []const u8) !void {
        const writer = self.tty.writer();
        self.loop.stop();
        try self.vx.exitAltScreen(writer);
        try writer.flush();
        tmux.attach(self.ctx, tmux_name) catch |err| self.setMessage("attach failed: {s}", .{@errorName(err)});
        try self.loop.start();
        try self.vx.enterAltScreen(writer);
        self.vx.queueRefresh();
        try self.refresh();
        self.selectByName(tmux_name);
        try self.loadPreview();
    }

    /// One row of the list: a group heading, a session, or a detail line under a session.
    const Line = struct {
        segs: []const vaxis.Segment,
        /// Index into the visible list when this row is selectable.
        vi: ?usize = null,
    };

    fn buildLines(self: *App, vis: []const usize, width: u16) ![]Line {
        var lines: std.ArrayList(Line) = .empty;
        var group: ?claude.Status = null;
        for (vis, 0..) |si, vi| {
            const s = self.sessions[si];
            const st = self.status(s);
            const color = statusColor(st);
            if (group == null or group.? != st) {
                group = st;
                if (lines.items.len > 0) try lines.append(self.arena(), .{ .segs = &.{} });
                try lines.append(self.arena(), .{ .segs = try self.arena().dupe(vaxis.Segment, &.{
                    .{ .text = try std.fmt.allocPrint(self.arena(), " {s}", .{st.groupLabel()}), .style = .{ .fg = color, .bold = true } },
                }) });
            }
            const info = self.statuses.get(s.tmux_name);
            const age = try ageText(self.arena(), self.ctx.nowSeconds() - ageSince(s, info));
            // "  ● name  profile  summary  age": fit the summary into what is left.
            const fixed = 2 + 1 + 1 + cols(s.name) + 2 + cols(s.profile) + 2 + 2 + age.len;
            const summary = if (info) |i| try truncate(self.arena(), i.summary, width -| fixed) else "";
            try lines.append(self.arena(), .{ .vi = vi, .segs = try self.arena().dupe(vaxis.Segment, &.{
                .{ .text = "  " },
                .{ .text = "●", .style = .{ .fg = color } },
                .{ .text = " " },
                .{ .text = s.name, .style = .{ .bold = true } },
                .{ .text = "  " },
                .{ .text = s.profile, .style = .{ .dim = true } },
                .{ .text = "  " },
                .{ .text = summary },
                .{ .text = try std.fmt.allocPrint(self.arena(), "  {s}", .{age}), .style = .{ .dim = true } },
            }) });
            if (!self.expanded) continue;
            const short = try self.ctx.shortenHomeIn(self.arena(), s.dir);
            try lines.append(self.arena(), .{ .segs = try self.arena().dupe(vaxis.Segment, &.{
                .{ .text = "      " }, .{ .text = short, .style = .{ .dim = true } },
                .{ .text = "  " },   .{ .text = s.tmux_name, .style = .{ .dim = true } },
            }) });
            if (info) |i| if (i.name.len > 0 and !std.mem.eql(u8, i.name, s.name)) {
                try lines.append(self.arena(), .{ .segs = try self.arena().dupe(vaxis.Segment, &.{
                    .{ .text = "      " }, .{ .text = i.name, .style = .{ .italic = true, .dim = true } },
                }) });
            };
        }
        return lines.toOwnedSlice(self.arena());
    }

    fn draw(self: *App) !void {
        const win = self.vx.window();
        win.clear();
        win.hideCursor();
        const bold: vaxis.Style = .{ .bold = true };

        var buf: [1024]usize = undefined;
        const vis = self.visible(&buf);

        // Header: counts per group, like `claude agents`.
        var counts = std.enums.EnumArray(claude.Status, usize).initFill(0);
        for (vis) |si| counts.getPtr(self.status(self.sessions[si])).* += 1;
        _ = win.print(&.{
            .{ .text = " SESSIONS  ", .style = bold },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} need input", .{counts.get(.blocked)}), .style = .{ .fg = statusColor(.blocked) } },
            .{ .text = " · ", .style = .{ .dim = true } },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} working", .{counts.get(.busy)}), .style = .{ .fg = statusColor(.busy) } },
            .{ .text = " · ", .style = .{ .dim = true } },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} idle", .{counts.get(.idle) + counts.get(.shell)}), .style = .{ .fg = statusColor(.idle) } },
            .{ .text = " · ", .style = .{ .dim = true } },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} other", .{vis.len - counts.get(.blocked) - counts.get(.busy) - counts.get(.idle) - counts.get(.shell)}), .style = .{ .dim = true } },
        }, .{ .wrap = .none });

        // Split the rest between the list (top) and the preview (bottom).
        const lines = try self.buildLines(vis, win.width);
        const avail: u16 = win.height -| 4; // header, gap under list, separator, bottom line
        const preview_min: u16 = @min(10, avail / 2);
        // The list takes at most a third of the window, then scrolls.
        const list_max: u16 = @max(1, win.height / 3);
        const list_h: u16 = @intCast(@min(lines.len, list_max, @max(1, avail -| preview_min)));
        const preview_h: u16 = avail -| list_h;

        // Scroll so the selected row is on screen.
        var cursor_line: usize = 0;
        for (lines, 0..) |l, i| if (l.vi == self.cursor) {
            cursor_line = i;
        };
        if (cursor_line < self.scroll) self.scroll = cursor_line;
        if (cursor_line >= self.scroll + list_h) self.scroll = cursor_line + 1 - list_h;
        if (self.scroll + list_h > lines.len) self.scroll = lines.len -| list_h;

        const list = win.child(.{ .y_off = 1, .height = list_h });
        for (lines[self.scroll..@min(lines.len, self.scroll + list_h)], 0..) |l, y| {
            const sel = l.vi != null and l.vi.? == self.cursor;
            const row = list.child(.{ .y_off = @intCast(y), .height = 1 });
            if (sel) {
                row.fill(.{ .style = .{ .reverse = true } });
                const segs = try self.arena().dupe(vaxis.Segment, l.segs);
                for (segs) |*sg| sg.style.reverse = true;
                _ = row.print(segs, .{ .wrap = .none });
            } else {
                _ = row.print(l.segs, .{ .wrap = .none });
            }
        }
        if (vis.len == 0) {
            _ = list.printSegment(.{ .text = "  no sessions. press n to launch one.", .style = .{ .dim = true } }, .{ .wrap = .none });
        }

        // separator + preview of the selected pane
        const sep_y: u16 = 1 + list_h + 1;
        var x: u16 = 0;
        while (x < win.width) : (x += 1) win.writeCell(x, sep_y, .{ .char = .{ .grapheme = "─" }, .style = .{ .dim = true } });
        if (self.selected()) |s| {
            const title = try std.fmt.allocPrint(self.arena(), " {s}  {s} ", .{ s.name, s.tmux_name });
            _ = win.printSegment(.{ .text = title, .style = .{ .dim = true } }, .{ .row_offset = sep_y, .col_offset = 1, .wrap = .none });
            const right = win.child(.{ .y_off = sep_y + 1, .height = preview_h });
            const shown = if (self.preview.len > preview_h) self.preview[self.preview.len - preview_h ..] else self.preview;
            for (shown, 0..) |segs, py| {
                const pl = right.child(.{ .y_off = @intCast(py), .height = 1 });
                _ = pl.print(segs, .{ .wrap = .none });
            }
        }

        // bottom line: help, message, or input prompt
        const bottom = win.child(.{ .y_off = win.height -| 1, .height = 1 });
        switch (self.mode) {
            .list => {
                const help = if (self.message.len > 0) self.message else " enter attach  tab details  n new  d kill  r rename  s send  / filter  q quit  (ctrl-q detaches)";
                _ = bottom.printSegment(.{ .text = help, .style = .{ .dim = true } }, .{ .wrap = .none });
            },
            .confirm_kill => {
                const s = self.selected().?;
                const t = try std.fmt.allocPrint(self.arena(), " kill {s}? [y/N] ", .{s.name});
                _ = bottom.printSegment(.{ .text = t, .style = .{ .fg = .{ .index = 1 }, .bold = true } }, .{ .wrap = .none });
            },
            .input => |kind| {
                const label: []const u8 = switch (kind) {
                    .filter => " filter: ",
                    .rename => " rename: ",
                    .send => " send: ",
                    .new_dir => " new session - directory: ",
                    .new_name => " new session - name: ",
                    .new_profile => " new session - profile: ",
                    .new_message => " new session - initial message (optional): ",
                };
                const res = bottom.printSegment(.{ .text = label, .style = bold }, .{ .wrap = .none });
                const field = bottom.child(.{ .x_off = res.col, .width = bottom.width -| res.col });
                self.input.draw(field);
            },
        }
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
        self.dirty = false;
    }
};

/// Approximate display width: one column per codepoint.
fn cols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Cut `text` to at most `max` columns, ending in "…" when shortened.
fn truncate(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (max == 0) return "";
    if (cols(text) <= max) return text;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (n + 1 >= max) break;
        n += 1;
        end += cp.len;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{std.mem.trimEnd(u8, text[0..end], " ")});
}

/// Unix seconds of the last thing that happened to the session.
fn ageSince(s: tmux.Session, info: ?claude.Info) i64 {
    if (info) |i| {
        const ms = if (i.status_since_ms > 0) i.status_since_ms else i.updated_ms;
        if (ms > 0) return @divTrunc(ms, 1000);
    }
    return if (s.activity > 0) s.activity else s.created;
}

fn ageText(arena: std.mem.Allocator, secs: i64) ![]const u8 {
    const t = @max(secs, 0);
    if (t < 60) return "now";
    if (t < 3600) return std.fmt.allocPrint(arena, "{d}m", .{@divTrunc(t, 60)});
    if (t < 86400) return std.fmt.allocPrint(arena, "{d}h", .{@divTrunc(t, 3600)});
    return std.fmt.allocPrint(arena, "{d}d", .{@divTrunc(t, 86400)});
}

test "truncate keeps codepoints whole" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("héllo", try truncate(a.allocator(), "héllo", 5));
    try std.testing.expectEqualStrings("hél…", try truncate(a.allocator(), "héllo world", 4));
    try std.testing.expectEqualStrings("", try truncate(a.allocator(), "x", 0));
}

fn statusColor(st: claude.Status) vaxis.Color {
    return switch (st) {
        .busy => .{ .index = 3 },
        .waiting => .{ .index = 5 },
        .shell => .{ .index = 6 },
        .idle => .{ .index = 2 },
        .blocked => .{ .index = 1 },
        .starting => .{ .index = 4 },
        .gone => .{ .index = 8 },
        .unknown => .default,
    };
}

/// Run the chooser. `select` preselects a tmux session name.
pub fn run(ctx: Ctx, cfg: config.Config, select: ?[]const u8) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(ctx.io, &tty_buf);
    defer tty.deinit();
    var vx = try vaxis.init(ctx.io, ctx.gpa, ctx.env, .{});
    defer vx.deinit(ctx.gpa, tty.writer());
    var loop: vaxis.Loop(Event) = .init(ctx.io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var app: App = .{
        .ctx = ctx,
        .cfg = cfg,
        .vx = &vx,
        .tty = &tty,
        .loop = &loop,
        .arena_state = std.heap.ArenaAllocator.init(ctx.gpa),
        .form_state = std.heap.ArenaAllocator.init(ctx.gpa),
        .input = vaxis.widgets.TextInput.init(ctx.gpa),
    };
    defer app.arena_state.deinit();
    defer app.form_state.deinit();
    defer app.input.deinit();

    try app.refresh();
    if (select) |name| app.selectByName(name);
    try app.loadPreview();

    while (!app.quit) {
        ctx.sleepMs(25);
        while (try loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| try app.handleKey(key),
                .winsize => |ws| {
                    try vx.resize(ctx.gpa, tty.writer(), ws);
                    try app.loadPreview();
                    app.dirty = true;
                },
                .mouse => {},
            }
        }
        const now = std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
        if (now - app.last_refresh_ms >= 1000) try app.refresh();
        if (app.dirty) try app.draw();
    }
    try vx.exitAltScreen(tty.writer());
    try tty.writer().flush();
}
