//! Every session cl has launched, so closed ones can be resumed. Append-only
//! JSONL at ~/.local/state/cl/history.jsonl; a later line for the same tmux
//! name replaces the earlier one (e.g. when /clear starts a new Claude session).
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");

pub const Entry = struct {
    tmux: []const u8,
    name: []const u8,
    dir: []const u8,
    profile: []const u8,
    /// Claude's session id, "" when unknown (resume then falls back to --continue).
    session_id: []const u8 = "",
    created: i64 = 0,
};

/// A closed session that can be resumed.
pub const Closed = struct {
    entry: Entry,
    /// Unix seconds the transcript was last written, else when it was created.
    closed: i64,
    /// Claude's latest reply, whitespace squashed.
    reply: []const u8,
    /// False once Claude has deleted the transcript; resuming starts afresh.
    resumable: bool = true,
};

fn path(ctx: Ctx, alloc: std.mem.Allocator) ![]const u8 {
    if (ctx.env.get("XDG_STATE_HOME")) |d| if (d.len > 0) return std.fmt.allocPrint(alloc, "{s}/cl/history.jsonl", .{d});
    return std.fmt.allocPrint(alloc, "{s}/.local/state/cl/history.jsonl", .{ctx.home});
}

/// Append one entry.
pub fn record(ctx: Ctx, e: Entry) !void {
    const p = try path(ctx, ctx.gpa);
    defer ctx.gpa.free(p);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(p).?);
    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    try aw.writer.print("{f}\n", .{std.json.fmt(e, .{})});
    const file = try std.Io.Dir.cwd().createFile(ctx.io, p, .{ .truncate = false });
    defer file.close(ctx.io);
    try file.writePositionalAll(ctx.io, aw.writer.buffered(), try file.length(ctx.io));
}

/// Latest entry per tmux name, in file order. Strings live in `arena`.
pub fn load(ctx: Ctx, arena: std.mem.Allocator) ![]Entry {
    const p = try path(ctx, arena);
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, p, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const e = std.json.parseFromSliceLeaky(Entry, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const gop = try index.getOrPut(arena, e.tmux);
        if (gop.found_existing) {
            entries.items[gop.value_ptr.*] = e;
        } else {
            gop.value_ptr.* = entries.items.len;
            try entries.append(arena, e);
        }
    }
    return entries.items;
}

/// Record live sessions whose Claude session id is new to the history: ones
/// started before history existed, and ones that switched ids (/clear).
/// `known` maps tmux name -> session id and is updated in place.
pub fn sync(ctx: Ctx, gpa: std.mem.Allocator, known: *std.StringHashMapUnmanaged([]const u8), sessions: []const tmux.Session, statuses: claude.StatusMap) !void {
    for (sessions) |s| {
        const info = statuses.get(s.tmux_name) orelse continue;
        if (info.session_id.len == 0) continue;
        if (known.get(s.tmux_name)) |sid| if (std.mem.eql(u8, sid, info.session_id)) continue;
        try record(ctx, .{ .tmux = s.tmux_name, .name = s.name, .dir = s.dir, .profile = s.profile, .session_id = info.session_id, .created = s.created });
        try remember(gpa, known, s.tmux_name, info.session_id);
    }
}

/// Fill `known` (tmux name -> session id) from the history file.
pub fn seed(ctx: Ctx, gpa: std.mem.Allocator, known: *std.StringHashMapUnmanaged([]const u8)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for (try load(ctx, arena_state.allocator())) |e| try remember(gpa, known, e.tmux, e.session_id);
}

fn remember(gpa: std.mem.Allocator, known: *std.StringHashMapUnmanaged([]const u8), tmux_name: []const u8, sid: []const u8) !void {
    if (known.fetchRemove(tmux_name)) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
    try known.put(gpa, try gpa.dupe(u8, tmux_name), try gpa.dupe(u8, sid));
}

pub fn freeKnown(gpa: std.mem.Allocator, known: *std.StringHashMapUnmanaged([]const u8)) void {
    var it = known.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        gpa.free(kv.value_ptr.*);
    }
    known.deinit(gpa);
}

/// Closed sessions, most recently closed first: not running, one per Claude
/// session id. Reads each transcript's tail, so call it on demand.
pub fn closed(ctx: Ctx, arena: std.mem.Allocator, cfg: config.Config, live: []const tmux.Session, statuses: claude.StatusMap) ![]Closed {
    const entries = try load(ctx, arena);
    var running: std.StringHashMapUnmanaged(void) = .empty;
    for (live) |s| {
        try running.put(arena, s.tmux_name, {});
        if (statuses.get(s.tmux_name)) |i| if (i.session_id.len > 0) try running.put(arena, i.session_id, {});
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    // name/dir/profile of entries newer than the current one.
    var newer: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(Closed) = .empty;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = entries[i];
        const like = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}", .{ e.name, e.dir, e.profile });
        const has_newer = (try newer.getOrPut(arena, like)).found_existing;
        if (running.contains(e.tmux)) continue;
        if (e.session_id.len > 0) {
            if (running.contains(e.session_id)) continue;
            if ((try seen.getOrPut(arena, e.session_id)).found_existing) continue;
        }
        const config_dir = if (cfg.find(e.profile)) |p| p.config_dir else null;
        const cd = config_dir orelse try claude.defaultConfigDir(ctx, arena);
        const resumable = claude.canResume(ctx, arena, cd, e.dir, e.session_id);
        // Nothing left to resume, and a newer session already took its place.
        if (!resumable and has_newer) continue;
        var when = e.created;
        var reply: []const u8 = "";
        if (e.session_id.len > 0) {
            const tpath = try claude.transcriptPath(arena, cd, e.dir, e.session_id);
            if (std.Io.Dir.cwd().statFile(ctx.io, tpath, .{})) |st| {
                when = st.mtime.toSeconds();
            } else |_| {}
            reply = claude.lastReply(ctx, arena, cd, e.dir, e.session_id) catch "";
        }
        try out.append(arena, .{ .entry = e, .closed = when, .reply = reply, .resumable = resumable });
    }
    std.mem.sort(Closed, out.items, {}, struct {
        fn gt(_: void, a: Closed, b: Closed) bool {
            return a.closed > b.closed;
        }
    }.gt);
    return out.items;
}
