//! Interactive chooser: session list on the left, live pane preview on the right.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const launch = @import("launch.zig");
const sgr = @import("sgr.zig");
const operator = @import("operator.zig");
const history = @import("history.zig");
const actions = @import("actions.zig");
const board = @import("board.zig");
const park = @import("park.zig");
const board_view = @import("board_view.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

const Mode = union(enum) {
    list,
    /// R: closed sessions, most recently closed first; Enter resumes one.
    history,
    /// P: parked tickets (cl ticket park); Enter resumes one.
    parked,
    /// b: the ticket board (board_view.zig).
    board,
    confirm_kill,
    input: Input,
};

const Input = enum { filter, history_filter, rename, send, new_dir, new_name, new_profile, new_message, board };

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
    /// tmux name -> Claude session id already in the history file.
    known: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Loaded when the resume list opens; lives in hist_state.
    hist_state: std.heap.ArenaAllocator,
    closed: []history.Closed = &.{},
    /// Index into histVisible(), not into `closed`.
    hist_cursor: usize = 0,
    hist_filter: []const u8 = "",
    /// The board, opened on the first refresh (null when it can't be).
    db: ?board.Db = null,
    db_tried: bool = false,
    /// Parked tickets, re-read each refresh (in the arena).
    parked: []board.Ticket = &.{},
    park_cursor: usize = 0,
    /// The operator, when it is running (hidden from `sessions`).
    op: ?tmux.Session = null,
    statuses: claude.StatusMap = .empty,
    preview: []PreviewLine = &.{},
    preview_of: []const u8 = "",
    cursor: usize = 0,
    mode: Mode = .list,
    input: vaxis.widgets.TextInput,
    filter: []const u8 = "",
    /// H: list hidden sessions too.
    show_hidden: bool = false,
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
    /// The ticket board, and what its open prompt asks (in form_state).
    bv: board_view.View = .{},
    board_label: []const u8 = "",
    /// ?: every key of the current view, on a screen of its own.
    show_keys: bool = false,

    fn arena(self: *App) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn form(self: *App) std.mem.Allocator {
        return self.form_state.allocator();
    }

    fn inBoard(self: *App) bool {
        return switch (self.mode) {
            .board => true,
            .input => |kind| kind == .board,
            else => false,
        };
    }

    /// What the board needs from the last refresh; null without a board.
    fn boardEnv(self: *App) ?board_view.Env {
        const db = self.db orelse return null;
        return .{ .ctx = self.ctx, .cfg = self.cfg, .db = db, .a = self.arena(), .sessions = self.sessions, .statuses = self.statuses };
    }

    /// Indices of sessions passing the filter, grouped by status (needs input first).
    fn visible(self: *App, buf: []usize) []usize {
        var n: usize = 0;
        for (self.sessions, 0..) |s, i| {
            if (s.hidden and !self.show_hidden) continue;
            if (matches(self.filter, &.{ s.name, s.dir, s.profile })) {
                buf[n] = i;
                n += 1;
            }
        }
        const vis = buf[0..n];
        std.sort.insertion(usize, vis, self, lessByGroup);
        return vis;
    }

    /// Indices into `closed` passing the resume list's filter, in order.
    fn histVisible(self: *App, buf: []usize) []usize {
        var n: usize = 0;
        for (self.closed, 0..) |c, i| {
            if (n == buf.len) break;
            if (matches(self.hist_filter, &.{ c.entry.name, c.entry.dir, c.entry.profile })) {
                buf[n] = i;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Header note about hidden sessions: how many are tucked away, or that they are shown.
    fn hiddenNote(self: *App) ![]const u8 {
        var n: usize = 0;
        for (self.sessions) |s| if (s.hidden) {
            n += 1;
        };
        if (n == 0) return "";
        if (self.show_hidden) return std.fmt.allocPrint(self.arena(), " · showing {d} hidden", .{n});
        return std.fmt.allocPrint(self.arena(), " · {d} hidden (H)", .{n});
    }

    /// Header note about parked tickets: they have no session, so P lists them.
    fn parkedNote(self: *App) ![]const u8 {
        if (self.parked.len == 0) return "";
        return std.fmt.allocPrint(self.arena(), " · {d} parked (P)", .{self.parked.len});
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
        self.op = try tmux.operator(self.ctx, self.arena());
        self.statuses = try claude.readStatuses(self.ctx, self.arena(), self.cfg);
        history.sync(self.ctx, self.ctx.gpa, &self.known, self.sessions, self.statuses) catch {};
        if (!self.db_tried) {
            self.db_tried = true;
            self.db = board.open(self.ctx, self.cfg) catch null;
        }
        self.parked = if (self.db) |db| board.listTickets(db, self.arena(), .{ .parked = true }) catch &.{} else &.{};
        if (self.park_cursor >= self.parked.len) self.park_cursor = self.parked.len -| 1;
        if (keep) |k| self.selectByName(k);
        if (self.inBoard()) {
            if (self.boardEnv()) |env| self.bv.load(env) catch |err| self.bv.setMsg(true, "couldn't read the board: {s}", .{@errorName(err)});
        } else try self.loadPreview();
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

    /// Re-read the terminal size and repaint everything (Ctrl-L, and after attaching).
    fn redraw(self: *App) !void {
        if (self.tty.getWinsize()) |ws| {
            try self.vx.resize(self.ctx.gpa, self.tty.writer(), ws);
        } else |_| {}
        self.vx.queueRefresh();
        try self.refresh();
    }

    fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.allocPrint(self.arena(), fmt, args) catch "";
        self.dirty = true;
    }

    fn handleKey(self: *App, key: vaxis.Key) !void {
        self.dirty = true;
        if (key.matches('l', .{ .ctrl = true })) return self.redraw();
        if (self.show_keys) {
            // Any key closes it.
            self.show_keys = false;
            return;
        }
        if (key.matches('?', .{}) and self.keys() != null) {
            self.show_keys = true;
            return;
        }
        switch (self.mode) {
            .list => try self.handleListKey(key),
            .history => try self.handleHistoryKey(key),
            .parked => try self.handleParkedKey(key),
            .board => try self.handleBoardKey(key),
            .confirm_kill => {
                if (key.matches('y', .{}) or key.matches(vaxis.Key.enter, .{})) {
                    if (self.selected()) |s| {
                        tmux.kill(self.ctx, s.tmux_name) catch {};
                        actions.sessionKilled(self.ctx, self.cfg, s.tmux_name);
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
                    if (kind == .board) self.mode = .board;
                    if (kind == .filter) self.filter = "";
                    if (kind == .history_filter) {
                        self.hist_filter = "";
                        self.hist_cursor = 0;
                        self.mode = .history;
                    }
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
                    if (kind == .history_filter) {
                        self.hist_filter = try std.mem.concat(self.hist_state.allocator(), u8, &.{ self.input.buf.firstHalf(), self.input.buf.secondHalf() });
                        self.hist_cursor = 0;
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
        } else if (key.matches('H', .{}) or key.matches('h', .{ .shift = true })) {
            self.show_hidden = !self.show_hidden;
            try self.loadPreview();
        } else if (key.matches('h', .{})) {
            if (self.selected()) |s| {
                tmux.setHidden(self.ctx, s.tmux_name, !s.hidden) catch {};
                if (s.hidden) self.setMessage("{s} is visible again", .{s.name}) else self.setMessage("hid {s} (H shows hidden sessions)", .{s.name});
                try self.refresh();
            }
        } else if (key.matches('/', .{})) {
            self.mode = .{ .input = .filter };
        } else if (key.matches('n', .{})) {
            _ = self.form_state.reset(.retain_capacity);
            self.filter = "";
            const cwd = std.process.currentPathAlloc(self.ctx.io, self.arena()) catch "";
            try self.input.insertSliceAtCursor(try self.ctx.shortenHomeIn(self.arena(), cwd));
            self.mode = .{ .input = .new_dir };
        } else if (key.matches('R', .{}) or key.matches('r', .{ .shift = true })) {
            _ = self.hist_state.reset(.retain_capacity);
            self.closed = history.closed(self.ctx, self.hist_state.allocator(), self.cfg, self.sessions, self.statuses) catch &.{};
            self.hist_cursor = 0;
            self.hist_filter = "";
            self.scroll = 0;
            self.mode = .history;
        } else if (key.matches('b', .{})) {
            try self.openBoard();
        } else if (key.matches('P', .{}) or key.matches('p', .{ .shift = true })) {
            self.park_cursor = 0;
            self.scroll = 0;
            self.mode = .parked;
        } else if (key.matches('r', .{ .ctrl = true })) {
            try self.refresh();
        } else if (key.matches(vaxis.Key.tab, .{})) {
            self.expanded = !self.expanded;
        } else if (key.matches('o', .{})) {
            try self.openOperator();
        }
    }

    fn openOperator(self: *App) !void {
        const tmux_name = operator.ensure(self.ctx, self.cfg) catch |err| {
            const msg = "operator failed: {s} (profile {s})";
            const args = .{ @errorName(err), self.cfg.operator };
            if (self.inBoard()) self.bv.setMsg(true, msg, args) else self.setMessage(msg, args);
            return;
        };
        // Attaching clears its alert (opening it is how you acknowledge it).
        try self.attach(try self.form().dupe(u8, tmux_name));
    }

    fn handleHistoryKey(self: *App, key: vaxis.Key) !void {
        var buf: [4096]usize = undefined;
        const vis = self.histVisible(&buf);
        const count = vis.len;
        if (key.matches('g', .{})) {
            if (self.pending_g) self.hist_cursor = 0;
            self.pending_g = !self.pending_g;
            return;
        }
        self.pending_g = false;
        if (key.matches(vaxis.Key.escape, .{}) and self.hist_filter.len > 0) {
            self.hist_filter = "";
            self.hist_cursor = 0;
        } else if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches('R', .{}) or key.matches('r', .{ .shift = true })) {
            self.mode = .list;
            self.scroll = 0;
        } else if (key.matches('/', .{})) {
            try self.input.insertSliceAtCursor(self.hist_filter);
            self.mode = .{ .input = .history_filter };
        } else if (key.matches('c', .{ .ctrl = true })) {
            self.quit = true;
        } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.hist_cursor + 1 < count) self.hist_cursor += 1;
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.hist_cursor > 0) self.hist_cursor -= 1;
        } else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true })) {
            if (count > 0) self.hist_cursor = count - 1;
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('l', .{})) {
            if (count == 0) return;
            const e = self.closed[vis[self.hist_cursor]].entry;
            var fresh = false;
            const tmux_name = launch.create(self.ctx, self.cfg, .{
                .started_fresh = &fresh,
                .dir = e.dir,
                .name = e.name,
                .profile = e.profile,
                .resume_flag = e.session_id.len > 0,
                .resume_id = if (e.session_id.len > 0) e.session_id else null,
                .continue_flag = e.session_id.len == 0,
            }) catch |err| {
                self.setMessage("resume failed: {s}", .{@errorName(err)});
                return;
            };
            self.mode = .list;
            self.scroll = 0;
            try self.refresh();
            try self.attach(tmux_name);
            if (fresh) self.setMessage("{s}: Claude had deleted the transcript, so that was a new session", .{e.name});
        }
    }

    fn handleParkedKey(self: *App, key: vaxis.Key) !void {
        const count = self.parked.len;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches('P', .{}) or key.matches('p', .{ .shift = true })) {
            self.mode = .list;
            self.scroll = 0;
        } else if (key.matches('c', .{ .ctrl = true })) {
            self.quit = true;
        } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.park_cursor + 1 < count) self.park_cursor += 1;
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.park_cursor > 0) self.park_cursor -= 1;
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('u', .{}) or key.matches('x', .{})) {
            if (count == 0) return;
            const db = self.db orelse return;
            const t = self.parked[self.park_cursor];
            const resume_it = !key.matches('x', .{});
            const r = park.unpark(self.ctx, self.cfg, db, self.arena(), t.key, resume_it) catch |err| {
                self.setMessage("unpark failed: {s}", .{@errorName(err)});
                return;
            };
            const key_s = try self.form().dupe(u8, t.key);
            try self.refresh();
            if (r.resumed) |how| switch (how) {
                .waiting => self.setMessage("{s} unparked; it waits in Queued for its session", .{key_s}),
                else => self.setMessage("{s} unparked and resumed", .{key_s}),
            } else self.setMessage("{s} unparked; its session stays stopped", .{key_s});
            if (self.parked.len == 0) self.mode = .list;
        }
    }

    fn openBoard(self: *App) !void {
        if (self.db == null) {
            self.setMessage("the ticket board can't be opened (board.dir)", .{});
            return;
        }
        self.mode = .board;
        try self.refresh();
    }

    fn handleBoardKey(self: *App, key: vaxis.Key) !void {
        const env = self.boardEnv() orelse {
            self.mode = .list;
            return;
        };
        try self.boardOutcome(try self.bv.handleKey(env, key));
    }

    fn boardOutcome(self: *App, out: board_view.Outcome) !void {
        switch (out) {
            .none => {},
            .reload => try self.refresh(),
            .leave => {
                self.mode = .list;
                try self.refresh();
            },
            .quit => self.quit = true,
            .operator => try self.openOperator(),
            // Its name outlives the refresh attaching makes.
            .attach => |s| try self.attach(try self.form().dupe(u8, s)),
            .prompt => |p| {
                self.board_label = try self.form().dupe(u8, p.label);
                try self.input.insertSliceAtCursor(p.prefill);
                self.mode = .{ .input = .board };
            },
        }
    }

    fn buildParkedLines(self: *App, width: u16) ![]Line {
        var lines: std.ArrayList(Line) = .empty;
        const now = self.ctx.nowSeconds();
        for (self.parked, 0..) |t, i| {
            const p = t.park.?;
            const age = try ageText(self.arena(), now - p.at);
            // "  KEY  title  reason  age"
            const fixed = 2 + cols(t.key) + 2 + cols(t.title) + 2 + 2 + age.len;
            try lines.append(self.arena(), .{ .vi = i, .segs = try self.arena().dupe(vaxis.Segment, &.{
                .{ .text = "  " },
                .{ .text = t.key, .style = .{ .bold = true } },
                .{ .text = "  " },
                .{ .text = t.title },
                .{ .text = "  " },
                .{ .text = try truncate(self.arena(), p.reason, width -| fixed), .style = .{ .italic = true, .dim = true } },
                .{ .text = try std.fmt.allocPrint(self.arena(), "  {s}", .{age}), .style = .{ .dim = true } },
            }) });
        }
        return lines.toOwnedSlice(self.arena());
    }

    /// What the selected parked ticket waits on, in the preview area.
    fn parkedDetail(self: *App, t: board.Ticket) ![]const u8 {
        const p = t.park.?;
        const now = self.ctx.nowSeconds();
        var aw: std.Io.Writer.Allocating = .init(self.arena());
        try aw.writer.print("Parked {s} ago: {s}\n\n", .{ try ageText(self.arena(), now - p.at), p.reason });
        if (p.until.len == 0) {
            try aw.writer.writeAll("Nothing checks it: Enter resumes it.");
        } else {
            try aw.writer.print("Wakes when this passes, checked every {s}:\n  {s}\n\n", .{ try park.formatDuration(self.arena(), p.every), p.until });
            if (p.checked > 0) try aw.writer.print("Last check {s}: {s}\n", .{ try agoText(self.arena(), now - p.checked), p.result }) else try aw.writer.writeAll("Not checked yet\n");
            try aw.writer.print("Next check {s}; gives up {s}", .{ try inText(self.arena(), p.next - now), try inText(self.arena(), p.deadline - now) });
        }
        return aw.written();
    }

    fn buildHistoryLines(self: *App, vis: []const usize, width: u16) ![]Line {
        var lines: std.ArrayList(Line) = .empty;
        const now = self.ctx.nowSeconds();
        for (vis, 0..) |ci, i| {
            const c = self.closed[ci];
            const age = try ageText(self.arena(), now - c.closed);
            const short = try self.ctx.shortenHomeIn(self.arena(), c.entry.dir);
            // "  name  profile  ~/dir  reply  age"
            const fixed = 2 + cols(c.entry.name) + 2 + cols(c.entry.profile) + 2 + cols(short) + 2 + 2 + age.len;
            try lines.append(self.arena(), .{ .vi = i, .segs = try self.arena().dupe(vaxis.Segment, &.{
                .{ .text = "  " },
                .{ .text = c.entry.name, .style = .{ .bold = true } },
                .{ .text = "  " },
                .{ .text = c.entry.profile, .style = .{ .dim = true } },
                .{ .text = "  " },
                .{ .text = short, .style = .{ .dim = true } },
                .{ .text = "  " },
                .{ .text = try truncate(self.arena(), c.reply, width -| fixed) },
                .{ .text = try std.fmt.allocPrint(self.arena(), "  {s}", .{age}), .style = .{ .dim = true } },
            }) });
        }
        return lines.toOwnedSlice(self.arena());
    }

    fn submitInput(self: *App, kind: Input, text: []const u8) !void {
        self.mode = .list;
        switch (kind) {
            .filter => {
                self.filter = text;
                self.cursor = 0;
            },
            .board => {
                self.mode = .board;
                const env = self.boardEnv() orelse return;
                // Answering waits until Claude has taken it (seconds): say so meanwhile.
                if (self.bv.prompt == .answer) {
                    self.bv.setMsg(false, "sending the answer…", .{});
                    try self.draw();
                }
                try self.boardOutcome(try self.bv.submit(env, text));
            },
            .history_filter => {
                self.hist_filter = try self.hist_state.allocator().dupe(u8, text);
                self.hist_cursor = 0;
                self.mode = .history;
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
        // The loop was stopped while attached, so a resize then went unseen.
        try self.redraw();
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
            const fixed = 2 + 1 + 1 + cols(s.name) + 2 + cols(s.profile) + (if (s.hidden) @as(usize, 10) else 2) + 2 + age.len;
            // Its alert (cl alert), when it raised one, says more than the summary.
            const alert = s.alert.len > 0;
            const summary = if (alert)
                try std.fmt.allocPrint(self.arena(), " ⚑ {s} ", .{try truncate(self.arena(), s.alert, width -| fixed -| 4)})
            else if (info) |i| try truncate(self.arena(), i.summary, width -| fixed) else "";
            try lines.append(self.arena(), .{ .vi = vi, .segs = try self.arena().dupe(vaxis.Segment, &.{
                .{ .text = "  " },
                .{ .text = "●", .style = .{ .fg = color } },
                .{ .text = " " },
                .{ .text = s.name, .style = .{ .bold = true } },
                .{ .text = "  " },
                .{ .text = s.profile, .style = .{ .dim = true } },
                .{ .text = if (s.hidden) "  hidden  " else "  ", .style = .{ .dim = true, .italic = true } },
                .{ .text = summary, .style = if (alert) .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 }, .bold = true } else .{} },
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

    /// The operator at the right end of the header line: its alert, or its
    /// status when there is room after the header's text.
    fn drawOperator(self: *App, win: vaxis.Window, header_end: u16) !void {
        const op = self.op orelse return;
        const st = self.status(op);
        // An alert always shows (over the header if it must, cut to fit); the
        // plain status only when there is room after it.
        const room = win.width -| header_end -| 1;
        const t = if (op.alert.len > 0)
            try std.fmt.allocPrint(self.arena(), " ⚑ {s} (o) ", .{try truncate(self.arena(), op.alert, @max(@min(win.width / 2, room -| 7), 8))})
        else
            try std.fmt.allocPrint(self.arena(), "operator {s} ", .{st.label()});
        const style: vaxis.Style = if (op.alert.len > 0) .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 }, .bold = true } else .{ .fg = statusColor(st) };
        if (op.alert.len > 0 or cols(t) <= room)
            _ = win.printSegment(.{ .text = t, .style = style }, .{ .col_offset = win.width -| @as(u16, @intCast(cols(t))), .wrap = .none });
    }

    /// The keys of the current view; null while it asks for something.
    fn keys(self: *App) ?[]const []const u8 {
        return switch (self.mode) {
            .list => &list_keys,
            .history => &.{ "enter resume", "/ filter", "j/k move", "gg/G top/bottom", "esc back" },
            .parked => &.{ "enter unpark and resume", "x unpark, leave it stopped", "j/k move", "esc back" },
            .board => if (self.bv.choice == null) self.bv.help() else null,
            else => null,
        };
    }

    const list_keys = [_][]const u8{
        "enter attach",   "b board",          "n new session", "o operator", "tab details", "R resume closed", "P parked",
        "h hide",         "H show hidden",    "d kill",        "r rename",   "s send",      "/ filter",        "j/k move",
        "gg/G top/bottom", "ctrl-r refresh", "ctrl-l redraw", "q quit",     "ctrl-q (in a session) detach",
    };

    /// The bottom line's help: the keys that fit, then "? all keys" when
    /// some don't.
    fn helpLine(self: *App, width: u16) ![]const u8 {
        return fitHelp(self.arena(), self.keys() orelse &.{}, width);
    }

    /// `?`: every key, in columns.
    fn drawKeys(self: *App, win: vaxis.Window) !void {
        const items = self.keys() orelse &.{};
        _ = win.print(&.{
            .{ .text = " KEYS  ", .style = .{ .bold = true } },
            .{ .text = "any key closes this", .style = .{ .dim = true } },
        }, .{ .wrap = .none });
        var widest: usize = 0;
        for (items) |it| widest = @max(widest, cols(it));
        const col_w: usize = widest + 4;
        const ncols: usize = @max(1, (win.width -| 2) / col_w);
        const nrows = (items.len + ncols - 1) / ncols;
        for (items, 0..) |it, i| {
            const r = i % nrows;
            const c = i / nrows;
            // "key description": the key bold.
            const sp = std.mem.indexOfScalar(u8, it, ' ') orelse it.len;
            _ = win.print(&.{
                .{ .text = it[0..sp], .style = .{ .bold = true } },
                .{ .text = it[sp..] },
            }, .{ .row_offset = @intCast(2 + r), .col_offset = @intCast(2 + c * col_w), .wrap = .none });
        }
    }

    fn drawBoard(self: *App, win: vaxis.Window) !void {
        const header_end = try self.bv.draw(self.arena(), win.child(.{ .height = win.height -| 1 }), self.ctx.nowSeconds());
        try self.drawOperator(win, header_end);
        const bottom = win.child(.{ .y_off = win.height -| 1, .height = 1 });
        if (self.mode == .input) {
            const res = bottom.printSegment(.{ .text = self.board_label, .style = .{ .bold = true } }, .{ .wrap = .none });
            self.input.draw(bottom.child(.{ .x_off = res.col, .width = bottom.width -| res.col }));
        } else if (try self.bv.choiceText(self.arena())) |t| {
            _ = bottom.printSegment(.{ .text = try truncate(self.arena(), t, bottom.width), .style = .{ .fg = .{ .index = 3 }, .bold = true } }, .{ .wrap = .none });
        } else if (self.bv.message().len > 0) {
            const err = self.bv.msg_err;
            _ = bottom.printSegment(.{ .text = try std.fmt.allocPrint(self.arena(), " {s}", .{self.bv.message()}), .style = if (err) .{ .fg = .{ .index = 1 }, .bold = true } else .{ .fg = .{ .index = 2 } } }, .{ .wrap = .none });
        } else {
            _ = bottom.printSegment(.{ .text = try self.helpLine(bottom.width), .style = .{ .dim = true } }, .{ .wrap = .none });
        }
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
        self.dirty = false;
    }

    fn draw(self: *App) !void {
        const win = self.vx.window();
        win.clear();
        win.hideCursor();
        const bold: vaxis.Style = .{ .bold = true };
        if (self.show_keys) {
            try self.drawKeys(win);
            try self.vx.render(self.tty.writer());
            try self.tty.writer().flush();
            self.dirty = false;
            return;
        }
        if (self.inBoard()) return self.drawBoard(win);

        var buf: [1024]usize = undefined;
        const vis = self.visible(&buf);

        const in_history = switch (self.mode) {
            .history => true,
            .input => |kind| kind == .history_filter,
            else => false,
        };
        var hbuf: [4096]usize = undefined;
        const hvis = if (in_history) self.histVisible(&hbuf) else &.{};
        const in_parked = self.mode == .parked;
        // Where the header text ends, so the operator label can avoid it.
        var header_end: u16 = 0;
        if (in_parked) {
            header_end = win.print(&.{
                .{ .text = " PARKED  ", .style = bold },
                .{ .text = try std.fmt.allocPrint(self.arena(), "{d} ticket{s} waiting on something outside cl", .{ self.parked.len, if (self.parked.len == 1) "" else "s" }), .style = .{ .dim = true } },
            }, .{ .wrap = .none }).col;
        } else if (in_history) {
            header_end = win.print(&.{
                .{ .text = " RESUME  ", .style = bold },
                .{ .text = if (self.hist_filter.len > 0)
                    try std.fmt.allocPrint(self.arena(), "{d} of {d} closed sessions match \"{s}\"", .{ hvis.len, self.closed.len, self.hist_filter })
                else
                    try std.fmt.allocPrint(self.arena(), "{d} closed sessions, most recently closed first", .{self.closed.len}), .style = .{ .dim = true } },
            }, .{ .wrap = .none }).col;
        }
        // Header: counts per group, like `claude agents`.
        var counts = std.enums.EnumArray(claude.Status, usize).initFill(0);
        for (vis) |si| counts.getPtr(self.status(self.sessions[si])).* += 1;
        if (!in_history and !in_parked) header_end = win.print(&.{
            .{ .text = " SESSIONS  ", .style = bold },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} need input", .{counts.get(.blocked)}), .style = .{ .fg = statusColor(.blocked) } },
            .{ .text = " · ", .style = .{ .dim = true } },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} working", .{counts.get(.busy)}), .style = .{ .fg = statusColor(.busy) } },
            .{ .text = " · ", .style = .{ .dim = true } },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} idle", .{counts.get(.idle) + counts.get(.shell)}), .style = .{ .fg = statusColor(.idle) } },
            .{ .text = " · ", .style = .{ .dim = true } },
            .{ .text = try std.fmt.allocPrint(self.arena(), "{d} other", .{vis.len - counts.get(.blocked) - counts.get(.busy) - counts.get(.idle) - counts.get(.shell)}), .style = .{ .dim = true } },
            .{ .text = try self.hiddenNote(), .style = .{ .dim = true, .italic = true } },
            .{ .text = try self.parkedNote(), .style = .{ .dim = true, .italic = true } },
        }, .{ .wrap = .none }).col;
        try self.drawOperator(win, header_end);

        // Split the rest between the list (top) and the preview (bottom).
        const lines = if (in_parked) try self.buildParkedLines(win.width) else if (in_history) try self.buildHistoryLines(hvis, win.width) else try self.buildLines(vis, win.width);
        const cursor = if (in_parked) self.park_cursor else if (in_history) self.hist_cursor else self.cursor;
        const avail: u16 = win.height -| 4; // header, gap under list, separator, bottom line
        const preview_min: u16 = @min(10, avail / 2);
        // The list takes at most a third of the window, then scrolls.
        const list_max: u16 = @max(1, win.height / 3);
        // At least one row, for the "no sessions" message.
        const list_h: u16 = @intCast(@min(@max(lines.len, 1), list_max, @max(1, avail -| preview_min)));
        const preview_h: u16 = avail -| list_h;

        // Scroll so the selected row is on screen.
        var cursor_line: usize = 0;
        for (lines, 0..) |l, i| if (l.vi == cursor) {
            cursor_line = i;
        };
        if (cursor_line < self.scroll) self.scroll = cursor_line;
        if (cursor_line >= self.scroll + list_h) self.scroll = cursor_line + 1 - list_h;
        if (self.scroll + list_h > lines.len) self.scroll = lines.len -| list_h;

        const list = win.child(.{ .y_off = 1, .height = list_h });
        for (lines[self.scroll..@min(lines.len, self.scroll + list_h)], 0..) |l, y| {
            const sel = l.vi != null and l.vi.? == cursor;
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
        if (in_parked and self.parked.len == 0) {
            _ = list.printSegment(.{ .text = "  no parked tickets.", .style = .{ .dim = true } }, .{ .wrap = .none });
        } else if (in_history and hvis.len == 0) {
            const t = if (self.closed.len == 0) "  no closed sessions yet." else "  no closed sessions match the filter.";
            _ = list.printSegment(.{ .text = t, .style = .{ .dim = true } }, .{ .wrap = .none });
        } else if (!in_history and vis.len == 0) {
            _ = list.printSegment(.{ .text = "  no sessions. press n to launch one.", .style = .{ .dim = true } }, .{ .wrap = .none });
        }

        // separator + preview of the selected pane
        const sep_y: u16 = 1 + list_h + 1;
        var x: u16 = 0;
        while (x < win.width) : (x += 1) win.writeCell(x, sep_y, .{ .char = .{ .grapheme = "─" }, .style = .{ .dim = true } });
        if (in_parked) {
            if (self.parked.len > 0) {
                const t = self.parked[self.park_cursor];
                const title = try std.fmt.allocPrint(self.arena(), " {s}  {s} ", .{ t.key, t.project });
                _ = win.printSegment(.{ .text = title, .style = .{ .dim = true } }, .{ .row_offset = sep_y, .col_offset = 1, .wrap = .none });
                const right = win.child(.{ .x_off = 2, .y_off = sep_y + 1, .width = win.width -| 4, .height = preview_h });
                _ = right.printSegment(.{ .text = try self.parkedDetail(t) }, .{ .wrap = .word });
            }
        } else if (in_history) {
            if (hvis.len > 0) {
                const c = self.closed[hvis[self.hist_cursor]];
                const how = if (!c.resumable)
                    "transcript deleted by Claude: starts a new session here"
                else if (c.entry.session_id.len > 0)
                    c.entry.session_id
                else
                    "no session id: resumes with --continue";
                const title = try std.fmt.allocPrint(self.arena(), " {s}  {s} ", .{ c.entry.name, how });
                _ = win.printSegment(.{ .text = title, .style = .{ .dim = true } }, .{ .row_offset = sep_y, .col_offset = 1, .wrap = .none });
                const right = win.child(.{ .x_off = 2, .y_off = sep_y + 1, .width = win.width -| 4, .height = preview_h });
                _ = right.printSegment(.{ .text = if (c.reply.len > 0) c.reply else "(no reply recorded)" }, .{ .wrap = .word });
            }
        } else if (self.selected()) |s| {
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
                const help = if (self.message.len > 0) self.message else try self.helpLine(bottom.width);
                _ = bottom.printSegment(.{ .text = help, .style = .{ .dim = true } }, .{ .wrap = .none });
            },
            .history => {
                const help = if (self.message.len > 0) self.message else try self.helpLine(bottom.width);
                _ = bottom.printSegment(.{ .text = help, .style = .{ .dim = true } }, .{ .wrap = .none });
            },
            .board => {},
            .parked => {
                const help = if (self.message.len > 0) self.message else try self.helpLine(bottom.width);
                _ = bottom.printSegment(.{ .text = help, .style = .{ .dim = true } }, .{ .wrap = .none });
            },
            .confirm_kill => {
                const s = self.selected().?;
                const t = try std.fmt.allocPrint(self.arena(), " kill {s}? [y/N] ", .{s.name});
                _ = bottom.printSegment(.{ .text = t, .style = .{ .fg = .{ .index = 1 }, .bold = true } }, .{ .wrap = .none });
            },
            .input => |kind| {
                const label: []const u8 = switch (kind) {
                    .filter, .history_filter => " filter: ",
                    .rename => " rename: ",
                    .send => " send: ",
                    .new_dir => " new session - directory: ",
                    .new_name => " new session - name: ",
                    .new_profile => " new session - profile: ",
                    .new_message => " new session - initial message (optional): ",
                    .board => self.board_label,
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

/// Whether `filter` (case-insensitive) occurs in any of `fields`; an empty filter matches.
fn matches(filter: []const u8, fields: []const []const u8) bool {
    if (filter.len == 0) return true;
    for (fields) |f| if (std.ascii.indexOfIgnoreCase(f, filter) != null) return true;
    return false;
}

/// Approximate display width: one column per codepoint.
pub fn cols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Cut `text` to at most `max` columns, ending in "…" when shortened.
pub fn truncate(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
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

/// A bottom line of `items` ("key what") that fits in `width` columns:
/// all of them, or as many as fit (in order) and then "? all keys".
pub fn fitHelp(a: std.mem.Allocator, items: []const []const u8, width: usize) ![]const u8 {
    const more = "  ? all keys";
    var total: usize = 0;
    for (items) |it| total += 2 + cols(it);
    var out: std.ArrayList(u8) = .empty;
    const room = if (total < width) width else width -| cols(more);
    var used: usize = 0;
    for (items) |it| {
        if (used + 2 + cols(it) > room) break;
        try out.appendSlice(a, if (used == 0) " " else "  ");
        try out.appendSlice(a, it);
        used += 2 + cols(it);
    }
    if (total >= width) try out.appendSlice(a, if (out.items.len == 0) " ? all keys" else more);
    return out.items;
}

test fitHelp {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const items: []const []const u8 = &.{ "enter attach", "b board", "q quit" };
    try std.testing.expectEqualStrings(" enter attach  b board  q quit", try fitHelp(a.allocator(), items, 80));
    try std.testing.expectEqualStrings(" enter attach  ? all keys", try fitHelp(a.allocator(), items, 26));
    const cut = try fitHelp(a.allocator(), items, 30);
    try std.testing.expect(cols(cut) <= 30);
    try std.testing.expect(std.mem.endsWith(u8, cut, "? all keys"));
    try std.testing.expectEqualStrings(" ? all keys", try fitHelp(a.allocator(), items, 12));
}

/// Unix seconds of the last thing that happened to the session.
fn ageSince(s: tmux.Session, info: ?claude.Info) i64 {
    if (info) |i| {
        const ms = if (i.status_since_ms > 0) i.status_since_ms else i.updated_ms;
        if (ms > 0) return @divTrunc(ms, 1000);
    }
    return if (s.activity > 0) s.activity else s.created;
}

/// "just now" or "5m ago".
fn agoText(arena: std.mem.Allocator, secs: i64) ![]const u8 {
    if (secs < 60) return "just now";
    return std.fmt.allocPrint(arena, "{s} ago", .{try ageText(arena, secs)});
}

/// "now" (due, or under a minute off) or "in 5m".
fn inText(arena: std.mem.Allocator, secs: i64) ![]const u8 {
    if (secs < 60) return "now";
    return std.fmt.allocPrint(arena, "in {s}", .{try ageText(arena, secs)});
}

pub fn ageText(arena: std.mem.Allocator, secs: i64) ![]const u8 {
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
    return runIn(ctx, cfg, select, false);
}

/// Run the chooser on the ticket board (`cl board`).
pub fn runBoard(ctx: Ctx, cfg: config.Config) !void {
    return runIn(ctx, cfg, null, true);
}

fn runIn(ctx: Ctx, cfg: config.Config, select: ?[]const u8, on_board: bool) !void {
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
        .hist_state = std.heap.ArenaAllocator.init(ctx.gpa),
        .input = vaxis.widgets.TextInput.init(ctx.gpa),
    };
    defer app.arena_state.deinit();
    defer app.form_state.deinit();
    defer app.hist_state.deinit();
    defer if (app.db) |db| db.close();
    defer history.freeKnown(ctx.gpa, &app.known);
    history.seed(ctx, ctx.gpa, &app.known) catch {};
    defer app.input.deinit();

    try app.refresh();
    if (select) |name| app.selectByName(name);
    try app.loadPreview();
    if (on_board) try app.openBoard();

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
