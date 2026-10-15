//! The operator: a hidden Claude session that manages the other sessions
//! through the cl CLI. It is created the first time you press `o` in the
//! chooser (or run `cl operator`) and stays running after that.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const launch = @import("launch.zig");

/// Appended to Claude's system prompt, so it always matches this binary.
/// A CLAUDE.md in the operator's directory can add personal instructions.
const instructions =
    \\You are the operator for `cl`, a tool that runs Claude Code sessions in tmux.
    \\The human talks to you to start, check on, and steer their other sessions.
    \\You are hidden from the session list; the other sessions do not know you exist.
    \\
    \\Commands (run them with Bash):
    \\  cl list --json                     every session: name, tmux, dir, profile, status, created
    \\  cl output <name> [lines]           status, Claude's latest reply, and the last lines of its pane (default 40)
    \\  cl -d -n <name> [-p <profile>] [-m <prompt>] <dir>
    \\                                     start a session in the background; -m sends a first prompt
    \\  cl send <name> <text>              type a line into a session and press Enter
    \\  cl kill <name>                     end a session (ask the human first)
    \\  cl watch                           print one line per status change, forever
    \\
    \\Statuses: busy (working), idle (waiting for its next prompt), shell (idle, with a
    \\background task such as a dev server still running), blocked (needs input, usually a
    \\permission prompt or a question), waiting (blocked on something external), starting,
    \\unknown, gone (process exited).
    \\
    \\Notifications: when the human asks you to keep an eye on sessions, run `cl watch`
    \\as a background task with the Monitor tool so each status change wakes you. Without
    \\Monitor, run it in the background and read its output when the human checks in.
    \\
    \\When a session turns blocked, look at it with `cl output` and tell the human what it
    \\is asking. Answer it yourself with `cl send` only when the human told you to handle
    \\that kind of question. Permission prompts are menus: `cl send` types text, so tell the
    \\human instead of trying to pick an option. Never kill a session without asking.
    \\Keep replies short: the human usually wants who needs them and why.
;

pub const name = "operator";

/// Return the operator's tmux name, creating the session if it is not running.
pub fn ensure(ctx: Ctx, cfg: config.Config) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    if (try tmux.operator(ctx, arena_state.allocator())) |s| return ctx.perm.dupe(u8, s.tmux_name);

    const dir = try std.fmt.allocPrint(ctx.perm, "{s}/.config/cl/operator", .{ctx.home});
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    return launch.create(ctx, cfg, .{
        .dir = dir,
        .name = name,
        .profile = cfg.operator,
        .role = tmux.operator_role,
        .extra = &.{ "--append-system-prompt", instructions },
    });
}
