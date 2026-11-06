//! The operator: a hidden Claude session that manages the other sessions
//! through the cl CLI. It is created the first time you press `o` in the
//! chooser (or run `cl operator`, or Chat on the web board) and stays running
//! after that. Restarted, it continues its last conversation.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const launch = @import("launch.zig");
const claude = @import("claude.zig");

/// Appended to Claude's system prompt, so it always matches this binary.
/// A CLAUDE.md in the operator's directory can add personal instructions.
const instructions =
    \\You are the operator for `cl`, a tool that runs Claude Code sessions in tmux.
    \\The human talks to you to start, check on, and steer their other sessions.
    \\You are hidden from the session list; the other sessions do not know you exist.
    \\
    \\Commands (run them with Bash):
    \\  cl list --json                     every session: name, tmux, dir, profile, status, created, hidden
    \\  cl output <name> [lines]           status, Claude's latest reply, and the last lines of its pane (default 40)
    \\  cl -d -n <name> [-p <profile>] [-m <prompt>] <dir>
    \\                                     start a session in the background; -m sends a first prompt
    \\  cl send <name> <text>              type a line into a session and press Enter
    \\  cl kill <name>                     end a session (ask the human first)
    \\  cl hide <name> / cl unhide <name>  hide a session from the human's list (it keeps running), or show it again
    \\  cl watch                           print one line per status change, forever
    \\  cl alert <text>                    raise a flag in the human's session list (cl alert --clear removes it)
    \\  cl closed                          closed sessions, newest first: name, profile, dir, closed at, session id, reply
    \\  cl -d -r <session id> -n <name> -p <profile> <dir>
    \\                                     bring a closed session back (use the values from cl closed);
    \\                                     if Claude deleted its transcript, this starts a new session there
    \\
    \\The ticket board: load the cl-tickets skill before creating, reading or changing tickets.
    \\Tickets in the inbox (`cl ticket needs --json`) are for the human; tell them, and act
    \\only on what they asked you to handle.
    \\
    \\Statuses: busy (working), idle (waiting for its next prompt), shell (idle, with a
    \\background task such as a dev server still running), blocked (needs input, usually a
    \\permission prompt or a question), waiting (blocked on something external), starting,
    \\unknown, gone (process exited).
    \\
    \\Hidden sessions: the human hid them to stop hearing about them for now (say, work
    \\sessions on a weekend). Leave them out of summaries unless asked, and never raise an
    \\alert about one. `cl watch` stays silent about them.
    \\
    \\Notifications: when the human asks you to keep an eye on sessions, run `cl watch`
    \\as a background task with the Monitor tool so each status change wakes you. Without
    \\Monitor, run it in the background and read its output when the human checks in.
    \\
    \\A turn is finished only when the session is idle. `shell` means Claude ended its turn
    \\while a background task it started is still running; when a task like a build or test
    \\run finishes, Claude wakes up and the session goes busy again, so keep waiting. Check
    \\`cl output` to tell those apart from a long-running dev server, which keeps a session
    \\in shell for good and counts as done.
    \\
    \\The human is usually in the session list or another session, not talking to you. Use
    \\`cl alert "<short text>"` when something needs them: a session is blocked, a task they
    \\asked you to watch finished or failed. One line, under 60 characters, naming the session.
    \\The flag stays until they open you, so replace it rather than stacking alerts.
    \\
    \\Notes: you forget everything when your conversation ends, so keep notes in `notes/` in
    \\your working directory. `notes/index.md` lists the other files with a line each; add
    \\one file per project or long-running topic. Read the index at the start of every
    \\conversation, and the files it points to when they are relevant. Write down what the
    \\human asks you to track or remember, what each session was asked to do and where it
    \\got to, decisions, and follow-ups. Update notes as things change and delete ones that
    \\no longer apply. When the human says "note that ...", it goes here.
    \\
    \\When a session turns blocked, look at it with `cl output` and tell the human what it
    \\is asking. Answer it yourself with `cl send` only when the human told you to handle
    \\that kind of question. Permission prompts are menus: `cl send` types text, so tell the
    \\human instead of trying to pick an option. Never kill a session without asking.
    \\Keep replies short: the human usually wants who needs them and why.
;

/// The operator's ticket skill, written to <dir>/.claude/skills/cl-tickets
/// every time the operator is opened so it always matches this binary.
const tickets_skill =
    \\---
    \\name: cl-tickets
    \\description: Create, find, read and change tickets on the cl board. Use whenever the human asks for a ticket, a task to be queued or done by a session, what is waiting on them, or about a ticket by key (like QA-3).
    \\---
    \\
    \\# Tickets on the cl board
    \\
    \\The board holds tickets for Claude sessions to work on. Each ticket belongs to a
    \\project, whose prefix makes its key (project qa-tool, prefix QA: QA-1, QA-2...).
    \\Run `cl ticket` (or `cl t`) with no arguments for the full command list.
    \\
    \\## Creating a ticket
    \\
    \\1. Find the project: `cl project list --json`. Match what the human said to a project
    \\   name or directory. If none fits, ask which one, or offer
    \\   `cl project add <name> <dir> [--prefix <KEY>]`; never guess a directory.
    \\2. Write the ticket. The title is a short imperative ("Fix flaky login spec"). The body
    \\   (`-m`) is the whole first message the session gets, read by a Claude that knows
    \\   nothing of this conversation: what to do, why, where to look, what done looks like,
    \\   and anything the human said that matters. Keep their words for requirements.
    \\3. Create it: `cl ticket new <project> "<title>" -m "<body>"`. It prints the key.
    \\   Options, only when they apply:
    \\     --worktree           its own git worktree and session (parallel work on a branch)
    \\     --queue              typed into a session in the project's directory (the default
    \\                          unless the project sets a mode)
    \\     --target <session>   a queue ticket for one particular session (tmux name)
    \\     --plan               start in planning: Claude interviews the human and posts a
    \\                          plan to approve first (--skill <name> picks the interview skill)
    \\     --parent <key>       a sub-ticket; the project may be left out
    \\     --stage queued       start as soon as a slot or session frees up; without it
    \\                          the ticket waits in backlog until someone queues it
    \\     --profile <name>     the Claude profile for its session
    \\   Ask before queueing (`--stage queued`) unless the human asked for the work to start.
    \\4. Tell the human the key and, in a line, what it will do.
    \\
    \\Several pieces of work: one ticket each, or a parent ticket with sub-tickets when they
    \\belong together. Make sure the human wants all of them before creating more than two.
    \\
    \\## Reading the board
    \\
    \\  cl ticket needs --json             the inbox: tickets waiting on the human, oldest first
    \\  cl ticket list [--stage <s>] [--project <p>] [--search <q>] [--open] [--json]
    \\  cl ticket show <key> [--json]      details, flags, sub-tickets, comments and activity
    \\
    \\Stages: backlog, planning, queued, running, review, testing, done. Flags say what a
    \\ticket needs from the human: question (Claude asked something), input (a permission
    \\prompt), review (finished, to review), testing (to try), ended (its session went away).
    \\
    \\## Changing tickets
    \\
    \\  cl ticket edit <key> [--title <t>] [-m <body>] [--plan | --no-plan] ...
    \\  cl ticket move <key> <stage>       e.g. queued to have the dispatcher start it
    \\  cl ticket rank <key> --top         reorder when asked: --top / --bottom of its
    \\                                     stage (all projects), or --before / --after <key>;
    \\                                     the dispatcher starts queued tickets in this order
    \\  cl ticket start <key>              start it now
    \\  cl ticket comment <key> "<text>"   a note; with --send it is also typed into the
    \\                                     ticket's session, and a ticket in review or testing
    \\                                     goes back to running
    \\  cl ticket approve <key>            plan -> running, review -> testing, testing -> done
    \\  Going to done (move or approve) closes the session. A worktree ticket takes
    \\  --merge (Claude merges its branch first) or --pr (opens a PR first); ask the
    \\  human which unless they said. --close, the default, just closes. --tell "<text>"
    \\  has Claude do whatever the text says first. A ticket whose Claude said not to
    \\  merge it as is shows "custom close: ..." in `show`: --merge and --pr are refused
    \\  for it, so do what that says (--tell) or ask the human. The ticket's Claude (or
    \\  you, when the human says so) sets it with `cl ticket custom-close <key> "<what to
    \\  do instead>"`; --clear undoes it.
    \\  cl ticket answer <key> <answer>... answer its question (an option number or words)
    \\
    \\Approving, answering, sending comments into a session, moving to done and `rm` act for
    \\the human: do them only when the human asked you to. Never `rm` a ticket without asking.
    \\
;

pub const name = "operator";

/// Return the operator's tmux name, creating the session if it is not running.
pub fn ensure(ctx: Ctx, cfg: config.Config) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(ctx.perm, "{s}/.config/cl/operator", .{ctx.home});
    const skill_dir = try std.fmt.allocPrint(arena, "{s}/.claude/skills/cl-tickets", .{dir});
    try std.Io.Dir.cwd().createDirPath(ctx.io, skill_dir);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{skill_dir}),
        .data = tickets_skill,
    });
    if (try tmux.operator(ctx, arena)) |s| return ctx.perm.dupe(u8, s.tmux_name);

    // --continue keeps the chat going across restarts (a fresh one the first time).
    return launch.create(ctx, cfg, .{
        .dir = dir,
        .name = name,
        .profile = cfg.operator,
        .role = tmux.operator_role,
        .continue_flag = true,
        .extra = &.{ "--append-system-prompt", instructions },
    });
}

/// Type `text` into the operator and press Enter, starting it first if it
/// isn't running (the board's Quick Ticket button). Multi-line text arrives
/// as one message. Starting it happens here, so a failure to start is
/// reported; waiting for its prompt and typing happen on a thread of their
/// own, so the caller doesn't wait. Returns whether it had to be started.
pub fn sendInBackground(ctx: Ctx, cfg: config.Config, text: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const was_running = (try tmux.operator(ctx, arena_state.allocator())) != null;
    const tmux_name = try ensure(ctx, cfg);
    const owned = try ctx.gpa.dupe(u8, text);
    errdefer ctx.gpa.free(owned);
    const t = try std.Thread.spawn(.{}, deliver, .{ ctx, tmux_name, owned, !was_running });
    t.detach();
    return !was_running;
}

/// `sendInBackground`, but returning once it is typed: for a process that
/// exits right after (the CLI, the after-merge runner).
pub fn send(ctx: Ctx, cfg: config.Config, text: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const was_running = (try tmux.operator(ctx, arena_state.allocator())) != null;
    const tmux_name = try ensure(ctx, cfg);
    if (!was_running) {
        try claude.waitForPrompt(ctx, tmux_name, false);
        ctx.sleepMs(300);
    }
    try claude.submit(ctx, tmux_name, text, true);
}

fn deliver(ctx: Ctx, tmux_name: []const u8, text: []const u8, fresh: bool) void {
    defer ctx.gpa.free(text);
    if (fresh) {
        claude.waitForPrompt(ctx, tmux_name, false) catch |err| {
            std.log.err("quick ticket: the operator's prompt didn't show ({s}); not sent", .{@errorName(err)});
            return;
        };
        ctx.sleepMs(300);
    }
    claude.submit(ctx, tmux_name, text, true) catch |err|
        std.log.err("quick ticket: couldn't type into the operator ({s})", .{@errorName(err)});
}

/// What the Quick Ticket button sends: the prefix, then the human's words.
pub fn quickTicketText(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.BadInput;
    return std.fmt.allocPrint(a, "Add a Ticket: {s}", .{t});
}

test quickTicketText {
    const a = std.testing.allocator;
    const s = try quickTicketText(a, "  fix the login page\nit 500s\n");
    defer a.free(s);
    try std.testing.expectEqualStrings("Add a Ticket: fix the login page\nit 500s", s);
    try std.testing.expectError(error.BadInput, quickTicketText(a, " \n "));
}
