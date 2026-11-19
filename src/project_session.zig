//! Project sessions: a Claude session in a project's own folder, started from
//! the board (Ask, `a`) or `cl project session`, to ask a quick question or
//! run something there. Not a ticket: it lives in tmux only, tagged with its
//! project (@cl_project), and the board shows it as a chip above Needs You.
//! The dispatcher never types a queue ticket into one (`dispatch.homeSession`).
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const launch = @import("launch.zig");
const dispatch = @import("dispatch.zig");
const claude = @import("claude.zig");
const tmux = @import("tmux.zig");

/// Start a project session in project `project_name`'s checkout, detached.
/// `text` ("" for none) is its first message; `model` ("" for
/// board.session_model, else the profile's) its --model. Returns the tmux
/// name. A session that didn't start is error.SessionFailed, with the reason
/// in `dispatch.failureReason`.
pub fn start(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, project_name: []const u8, text: []const u8, model_in: []const u8) ![]const u8 {
    const p = try board.getProject(db, a, project_name);
    const model = if (model_in.len > 0) model_in else cfg.board.session_model;
    if (!validModel(model)) return error.BadInput;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const name = launch.create(ctx, cfg, .{
        .dir = p.dir,
        .name = p.name,
        .project = p.name,
        .model = model,
        .profile = if (p.profile.len > 0) p.profile else null,
        .detach = true,
        .extra = try extraArgs(a, p, model),
    }) catch |e| return dispatch.sessionFailed(e, p.dir);
    // The first message here rather than in launch.create, which loses the
    // session's name when it fails: a session whose question didn't go in
    // is ended, not left on the board as a chip without it.
    if (trimmed.len > 0) {
        claude.sendInitialMessage(ctx, name, trimmed, cfg.board.trust_projects) catch |e| {
            tmux.kill(ctx, name) catch {};
            return dispatch.sessionFailed(e, p.dir);
        };
    } else if (cfg.board.trust_projects) {
        // No question: still say yes to the folder-trust dialog, as
        // board.trust_projects promises. A slow prompt isn't a failure; the
        // session waits for you either way.
        claude.waitForPrompt(ctx, name, true) catch {};
    }
    return name;
}

/// Claude's arguments for a project session of `p`: its instructions and,
/// unless `model` is "", --model. `start` and resuming one from the
/// chooser's R list (`resumeArgs`) both use these: --append-system-prompt and
/// --model last only as long as the process, not in the transcript.
pub fn extraArgs(a: std.mem.Allocator, p: board.Project, model: []const u8) ![]const []const u8 {
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(a, &.{ "--append-system-prompt", try instructions(a, p) });
    if (validModel(model) and model.len > 0) try extra.appendSlice(a, &.{ "--model", model });
    return extra.items;
}

/// `extraArgs` for resuming project session of `project` in `dir` (from
/// history). Without the board, or with the project gone or renamed, the
/// instructions still go: for a code repo (the stricter ones), in `dir`.
pub fn resumeArgs(db: ?board.Db, a: std.mem.Allocator, project: []const u8, dir: []const u8, model: []const u8) ![]const []const u8 {
    const p = if (db) |d| board.getProject(d, a, project) catch null else null;
    return extraArgs(a, p orelse std.mem.zeroInit(board.Project, .{ .name = project, .dir = dir, .prefix = "", .repo = true }), model);
}

/// A model name Claude's --model can take: "" (the default) or a word, never
/// something that would read as another flag.
fn validModel(m: []const u8) bool {
    if (m.len == 0) return true;
    if (m.len > 64 or m[0] == '-') return false;
    for (m) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '[' or c == ']')) return false;
    return true;
}

/// What a project session is told (its --append-system-prompt): what it is,
/// that the checkout is shared with tickets' work, and how a change becomes
/// a ticket.
pub fn instructions(a: std.mem.Allocator, p: board.Project) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("This is a quick session in project {s} ({s}), opened from the cl board to ask about it or run things in it. It isn't a ticket: nothing tracks it, and it ends when I close it.\n", .{ p.name, p.dir });
    if (p.repo) {
        try w.writeAll("This folder is the project's own checkout, where tickets' work may be under way: don't edit tracked files here, and don't run jj or git commands that change anything (commit, describe, new, edit, rebase, checkout, stash, restore, reset). Reading them (status, log, diff, show) is fine.\n");
    } else {
        try w.writeAll("This folder is the project's own, where tickets' work may be under way: don't edit its files.\n");
    }
    try w.print(
        \\Running the project's commands is fine: its tools, tests, and builds that only write to ignored output.
        \\For a change to code or files, offer to make it a ticket, and make one when I say so: `cl ticket new {s} "<title>" -m "<details>"`. It is queued, and cl works on it.
        \\If I haven't asked anything yet, wait for me.
        \\
    , .{p.name});
    return aw.written();
}

test instructions {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = std.mem.zeroInit(board.Project, .{ .name = "srd", .dir = "/x/srd", .prefix = "SD", .repo = true });
    const with = try instructions(a, p);
    try std.testing.expect(std.mem.indexOf(u8, with, "project srd (/x/srd)") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "`cl ticket new srd \"<title>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "jj or git") != null);
    p.repo = false;
    const without = try instructions(a, p);
    try std.testing.expect(std.mem.indexOf(u8, without, "jj") == null);
    try std.testing.expect(std.mem.indexOf(u8, without, "git") == null);
    try std.testing.expect(std.mem.indexOf(u8, without, "cl ticket new srd") != null);
}

test resumeArgs {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No board: the instructions still go, with the model.
    const args = try resumeArgs(null, a, "srd", "/x/srd", "haiku");
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("--append-system-prompt", args[0]);
    try std.testing.expect(std.mem.indexOf(u8, args[1], "project srd (/x/srd)") != null);
    try std.testing.expect(std.mem.indexOf(u8, args[1], "jj or git") != null);
    try std.testing.expectEqualStrings("haiku", args[3]);
    // No model: the profile's.
    try std.testing.expectEqual(@as(usize, 2), (try resumeArgs(null, a, "srd", "/x/srd", "")).len);
}

test validModel {
    try std.testing.expect(validModel(""));
    try std.testing.expect(validModel("sonnet"));
    try std.testing.expect(validModel("claude-opus-5-5"));
    try std.testing.expect(validModel("opus[1m]"));
    try std.testing.expect(!validModel("--dangerously-skip-permissions"));
    try std.testing.expect(!validModel("sonnet --x"));
}
