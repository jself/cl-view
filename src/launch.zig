//! Create a new Claude session (shared by the CLI and the TUI's "n" form).
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const history = @import("history.zig");

pub const Options = struct {
    dir: ?[]const u8 = null,
    name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    resume_id: ?[]const u8 = null,
    resume_flag: bool = false,
    continue_flag: bool = false,
    detach: bool = false,
    /// See tmux.NewOptions.role.
    role: []const u8 = "",
    /// Set to true when --resume/--continue had no transcript to resume, so a
    /// fresh session was started instead.
    started_fresh: ?*bool = null,
    extra: []const []const u8 = &.{},
};

pub const Error = error{ NoSuchDir, NoSuchProfile, PromptTimeout };

/// Create the tmux session, optionally send the initial message, return the tmux name.
pub fn create(ctx: Ctx, cfg: config.Config, o: Options) ![]const u8 {
    const profile = if (o.profile) |p| (cfg.find(p) orelse return error.NoSuchProfile) else cfg.defaultProfile();
    // currentPathAlloc returns a sentinel slice; freeing its plain-slice coercion trips the safe allocator.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const raw_dir = if (o.dir) |d| try ctx.expandHome(d) else try ctx.gpa.dupe(u8, cwd_buf[0..try std.process.currentPath(ctx.io, &cwd_buf)]);
    defer ctx.gpa.free(raw_dir);
    const dir = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, raw_dir, ctx.perm) catch return error.NoSuchDir;
    const name = if (o.name) |n| (if (n.len > 0) n else std.fs.path.basename(dir)) else std.fs.path.basename(dir);

    var cmd: std.ArrayList([]const u8) = .empty;
    defer cmd.deinit(ctx.gpa);
    try cmd.append(ctx.gpa, "claude");
    var idbuf: [36]u8 = undefined;
    // Claude's session id when we know it up front; the chooser fills in the rest.
    var session_id: []const u8 = "";
    // Claude only exits with "No conversation found" when the transcript was
    // cleaned up; start a new session with the same options instead.
    var resume_flag = o.resume_flag;
    var continue_flag = o.continue_flag;
    if ((resume_flag and o.resume_id != null) or continue_flag) {
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const config_dir = profile.config_dir orelse try claude.defaultConfigDir(ctx, arena);
        if (!claude.canResume(ctx, arena, config_dir, dir, if (resume_flag) o.resume_id.? else "")) {
            resume_flag = false;
            continue_flag = false;
            if (o.started_fresh) |f| f.* = true;
        }
    }
    if (resume_flag) {
        try cmd.append(ctx.gpa, "--resume");
        if (o.resume_id) |id| {
            try cmd.append(ctx.gpa, id);
            session_id = id;
        }
    } else if (continue_flag) {
        try cmd.append(ctx.gpa, "--continue");
    } else if (!claude.argsPickSession(o.extra)) {
        session_id = claude.uuid4(ctx, &idbuf);
        try cmd.appendSlice(ctx.gpa, &.{ "--session-id", session_id });
    }
    try cmd.appendSlice(ctx.gpa, o.extra);

    const tmux_name = try tmux.newSession(ctx, .{
        .name = name,
        .dir = dir,
        .profile = profile.name,
        .config_dir = profile.config_dir,
        .role = o.role,
        .command = cmd.items,
    });

    if (o.role.len == 0) {
        history.record(ctx, .{ .tmux = tmux_name, .name = name, .dir = dir, .profile = profile.name, .session_id = session_id, .created = ctx.nowSeconds() }) catch {};
    }

    if (o.message) |m| {
        if (m.len > 0) try claude.sendInitialMessage(ctx, tmux_name, m);
    }
    return tmux_name;
}
