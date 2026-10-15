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

    fn visible(self: *App, buf: []usize) []usize {
        var n: usize = 0;
        for (self.sessions, 0..) |s, i| {
            if (self.filter.len == 0 or std.mem.indexOf(u8, s.name, self.filter) != null or
                std.mem.indexOf(u8, s.dir, self.filter) != null) {
                buf[n] = i;
                n += 1;
            }
        }
        return buf[0..n];
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
        const height = self.vx.window().height;
        const rows: usize = if (height > 4) height - 4 else 1;
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

    fn draw(self: *App) !void {
        const win = self.vx.window();
        win.clear();
        win.hideCursor();
        const left_w: u16 = @max(24, win.width * 35 / 100);
        const left = win.child(.{ .width = left_w, .height = win.height });
        const right = win.child(.{ .x_off = left_w + 1, .width = win.width -| (left_w + 1), .height = win.height });
        // separator
        var y: u16 = 0;
        while (y < win.height) : (y += 1) win.writeCell(left_w, y, .{ .char = .{ .grapheme = "│" }, .style = .{ .dim = true } });

        const bold: vaxis.Style = .{ .bold = true };
        _ = left.printSegment(.{ .text = " SESSIONS", .style = bold }, .{ .wrap = .none });
        var buf: [1024]usize = undefined;
        const vis = self.visible(&buf);
        var row: u16 = 2;
        for (vis, 0..) |si, vi| {
            if (row >= win.height - 2) break;
            const s = self.sessions[si];
            const st = claude.statusFor(self.ctx, self.statuses, s);
            const dot_style: vaxis.Style = .{ .fg = statusColor(st) };
            const sel = vi == self.cursor;
            const row_style: vaxis.Style = if (sel) .{ .reverse = true } else .{};
            const line = left.child(.{ .y_off = row, .height = 1 });
            if (sel) line.fill(.{ .style = row_style });
            _ = line.print(&.{
                .{ .text = " ", .style = row_style },
                .{ .text = "●", .style = .{ .fg = dot_style.fg, .reverse = sel } },
                .{ .text = " ", .style = row_style },
                .{ .text = s.name, .style = .{ .bold = true, .reverse = sel } },
                .{ .text = "  ", .style = row_style },
                .{ .text = s.profile, .style = .{ .dim = true, .reverse = sel } },
            }, .{ .wrap = .none });
            row += 1;
            if (row >= win.height - 2) break;
            const short = try self.ctx.shortenHomeIn(self.arena(), s.dir);
            const sub = left.child(.{ .y_off = row, .height = 1 });
            _ = sub.print(&.{
                .{ .text = "    ", .style = .{} },
                .{ .text = st.label(), .style = .{ .fg = dot_style.fg } },
                .{ .text = "  ", .style = .{} },
                .{ .text = short, .style = .{ .dim = true } },
            }, .{ .wrap = .none });
            row += 1;
            if (self.statuses.get(s.tmux_name)) |info| {
                if (info.name.len > 0 and !std.mem.eql(u8, info.name, s.name) and row < win.height - 2) {
                    const sub2 = left.child(.{ .y_off = row, .height = 1 });
                    _ = sub2.print(&.{
                        .{ .text = "    ", .style = .{} },
                        .{ .text = info.name, .style = .{ .italic = true, .dim = true } },
                    }, .{ .wrap = .none });
                    row += 1;
                }
            }
        }
        if (vis.len == 0) {
            _ = left.printSegment(.{ .text = "  no sessions. press n to launch one.", .style = .{ .dim = true } }, .{ .row_offset = 2, .wrap = .none });
        }

        // preview
        if (self.selected()) |s| {
            var hdr: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&hdr, " {s}  ({s})", .{ s.name, s.tmux_name }) catch " ";
            _ = right.printSegment(.{ .text = title, .style = bold }, .{ .wrap = .none });
            var py: u16 = 2;
            for (self.preview) |segs| {
                if (py >= right.height - 2) break;
                const pl = right.child(.{ .y_off = py, .height = 1 });
                _ = pl.print(segs, .{ .wrap = .none });
                py += 1;
            }
        }

        // bottom line: help, message, or input prompt
        const bottom = win.child(.{ .y_off = win.height -| 1, .height = 1 });
        switch (self.mode) {
            .list => {
                const help = if (self.message.len > 0) self.message else " enter attach  n new  d kill  r rename  s send  / filter  q quit  (ctrl-q detaches)";
                _ = bottom.printSegment(.{ .text = help, .style = .{ .dim = true } }, .{ .wrap = .none });
            },
            .confirm_kill => {
                const s = self.selected().?;
                var kb: [256]u8 = undefined;
                const t = std.fmt.bufPrint(&kb, " kill {s}? [y/N] ", .{s.name}) catch "";
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

fn statusColor(st: claude.Status) vaxis.Color {
    return switch (st) {
        .busy => .{ .index = 3 },
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
