//! Starting tickets. A worktree ticket gets its own worktree and session; a
//! queue ticket is typed into its target session (its own, its parent's, or
//! a new one in the project's directory) when that session is idle and has
//! no other ticket in progress. The dispatcher (`cl t dispatch`, and a thread
//! in `cl web`) starts queued tickets as slots and sessions free up.
//!
//! Sessions cl starts for tickets carry CL_TICKET and hooks (--settings) that
//! report back through `cl ticket hook`.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const launch = @import("launch.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");
const signals = @import("signals.zig");
const history = @import("history.zig");

pub const Error = error{
    AlreadyStarted,
    /// The queue target is working, or already has a ticket in progress.
    TargetBusy,
    WorktreeFailed,
    SessionFailed,
};

/// What the ticket's session is told first. The key is spelled out, so the
/// instructions work in sessions cl didn't start (no CL_TICKET).
pub fn prompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("Ticket {s}: {s}\n", .{ t.key, t.title });
    if (t.parent.len > 0) try w.print("(a sub-ticket of {s}; `cl ticket show {s}` has the bigger picture)\n", .{ t.parent, t.parent });
    if (t.body.len > 0) try w.print("\n{s}\n", .{t.body});
    if (notes.len > 0) {
        try w.writeAll("\nNotes on the ticket:\n");
        for (notes) |n| try w.print("- {s}\n", .{n.body});
    }
    const planning = t.plan and t.stage == .planning;
    if (planning) {
        try w.writeAll("\nPlan first, without changing any code. Ask me with AskUserQuestion until the plan is clear");
        if (t.skill.len > 0) try w.print(" (use the {s} skill for the interview)", .{t.skill});
        try w.print(
            \\. Then post the plan with `cl ticket comment {s} --as claude "<the plan>"`
            \\and run `cl ticket done {s} --summary "Plan ready"`. Wait for me to approve it before writing code.
            \\
        , .{ t.key, t.key });
    }
    try w.print(
        \\
        \\How tickets work here (cl board):
        \\- Ask me with AskUserQuestion when you need a decision; the board shows it.
        \\- To split off a separate piece of work: `cl ticket new --parent {s} "<title>" -m "<details>"`.
        \\- When the work is finished and you need nothing more from me:
        \\  1. Write a review guide to .claude/review-guide.md (`gutter -guide-format` shows the format).
        \\  2. If there is something for me to try, write .claude/test-plan.md: "## Setup" (numbered steps
        \\     only I can do), "## Launch" (one shell command, run from this directory, that starts
        \\     everything, and the URL or port to open) and "## Checks" ("- [ ] what to try and what I
        \\     should see").
        \\  3. {s}Run `cl ticket done {s} --summary "<what changed, in a sentence or two>"`.
        \\  Don't run it while you still need anything from me. When I send feedback, finish the same way.
        \\
    , .{ t.key, if (t.mode == .worktree) "Commit your work on this branch (the review shows commits and new files that way). " else "", t.key });
    return aw.written();
}

/// What a resumed conversation is told: it already has the ticket.
fn resumePrompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("Ticket {s} is back on: {s}\n", .{ t.key, t.title });
    if (notes.len > 0) {
        try w.writeAll("\nNotes on the ticket:\n");
        for (notes) |n| try w.print("- {s}\n", .{n.body});
    }
    try w.print("\nPick it up where you left off, and finish the same way as before (`cl ticket done {s}`).\n", .{t.key});
    return aw.written();
}

/// Write the hooks settings file (in the board's directory) and return its path.
fn hooksFile(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(ctx.io, &exe_buf)];
    const dir = try board.dirPath(ctx, a, cfg);
    const path = try std.fmt.allocPrint(a, "{s}/claude-hooks.json", .{dir});
    const stop = try std.fmt.allocPrint(a, "'{s}' ticket hook stop", .{exe});
    const notify = try std.fmt.allocPrint(a, "'{s}' ticket hook notify", .{exe});
    const json = try std.fmt.allocPrint(a,
        \\{{"hooks":{{"Stop":[{{"hooks":[{{"type":"command","command":{f}}}]}}],"Notification":[{{"hooks":[{{"type":"command","command":{f}}}]}}]}}}}
        \\
    , .{ std.json.fmt(stop, .{}), std.json.fmt(notify, .{}) });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = json });
    return path;
}

/// Claude's arguments for a ticket's conversation: a new one with session id
/// `sid`, or with `resuming` the existing conversation `sid`.
fn claudeArgs(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, t: board.Ticket, sid: []const u8, resuming: bool) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ if (resuming) "--resume" else "--session-id", sid, "--settings", try hooksFile(ctx, a, cfg) });
    if (t.plan and t.stage == .planning) try args.appendSlice(a, &.{ "--permission-mode", "plan" });
    return args.items;
}

/// The environment that tells the hooks which ticket a session works on.
fn ticketEnv(a: std.mem.Allocator, t: board.Ticket) ![]const []const u8 {
    const env = try a.alloc([]const u8, 1);
    env[0] = try std.fmt.allocPrint(a, "CL_TICKET={s}", .{t.key});
    return env;
}

/// Restart Claude in the idle session `s` with a conversation about `t`: a
/// new one, or with `resume_id` the ticket's earlier one. The session keeps its
/// place in the cl list; its last conversation can be resumed from Claude's
/// history (and a ticket's, from the board).
fn freshConversation(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, s: tmux.Session, text: []const u8, session_id: *[36]u8, resume_id: ?[]const u8) !void {
    const sid = resume_id orelse claude.uuid4(ctx, session_id);
    if (resume_id) |r| @memcpy(session_id, r[0..36]);
    var cmd: std.ArrayList([]const u8) = .empty;
    try cmd.append(a, "claude");
    try cmd.appendSlice(a, try claudeArgs(ctx, cfg, a, t, sid, resume_id != null));
    try cmd.append(a, text);
    tmux.respawn(ctx, s.tmux_name, s.dir, try ticketEnv(a, t), cmd.items) catch return error.SessionFailed;
    history.record(ctx, .{ .tmux = s.tmux_name, .name = s.name, .dir = s.dir, .profile = s.profile, .session_id = sid, .created = s.created }) catch {};
    // Finished tickets that ran here keep their conversation id, not the
    // session, so the board doesn't show this ticket's status on them.
    try db.exec("UPDATE tickets SET tmux = '' WHERE tmux = ?1 AND id != ?2 AND stage = 'done'", .{ s.tmux_name, t.id });
}

/// A new Claude session for the ticket in `dir`, told about it first; with
/// `resume_id`, it picks the ticket's earlier conversation back up.
fn newSession(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, t: board.Ticket, dir: []const u8, name: []const u8, text: []const u8, session_id: *[36]u8, in_worktree: bool, resume_id: ?[]const u8) ![]const u8 {
    if (resume_id) |r| @memcpy(session_id, r[0..36]);
    const extra = try claudeArgs(ctx, cfg, a, t, resume_id orelse claude.uuid4(ctx, session_id), resume_id != null);
    return launch.create(ctx, cfg, .{
        .dir = dir,
        .name = name,
        .profile = if (t.profile.len > 0) t.profile else null,
        .message = text,
        .detach = true,
        .extra = extra,
        .env = try ticketEnv(a, t),
        .accept_trust = in_worktree and cfg.board.trust_worktrees,
    }) catch error.SessionFailed;
}

/// The ticket's own conversation to pick back up, when Claude still has its
/// transcript for `dir`. Tickets typed into another conversation have none.
fn resumeId(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, t: board.Ticket, dir: []const u8, profile: []const u8) ?[]const u8 {
    if (t.session_id.len != 36) return null;
    const prof = cfg.find(profile) orelse cfg.defaultProfile();
    const config_dir = prof.config_dir orelse (claude.defaultConfigDir(ctx, a) catch return null);
    return if (claude.canResume(ctx, a, config_dir, dir, t.session_id)) t.session_id else null;
}

/// Live sessions and their statuses, read once per dispatcher pass.
const View = struct {
    sessions: []tmux.Session,
    statuses: claude.StatusMap,

    fn read(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) !View {
        return .{ .sessions = try tmux.list(ctx, a), .statuses = try claude.readStatuses(ctx, a, cfg) };
    }

    fn find(self: View, tmux_name: []const u8) ?tmux.Session {
        for (self.sessions) |s| if (std.mem.eql(u8, s.tmux_name, tmux_name)) return s;
        return null;
    }

    fn alive(self: View, tmux_name: []const u8) bool {
        return self.find(tmux_name) != null;
    }

    fn idle(self: View, ctx: Ctx, tmux_name: []const u8) bool {
        const s = self.find(tmux_name) orelse return false;
        return switch (claude.statusFor(ctx, self.statuses, s)) {
            .idle, .shell => true,
            else => false,
        };
    }
};

/// Stages where a ticket still holds its session (or worktree slot): it is
/// not finished until it reaches done.
const in_progress = "('planning', 'running', 'review', 'testing')";

/// Where a queue ticket runs: its target, else its parent's session, else
/// the project's own session (see `homeSession`).
fn queueTarget(db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View, p: board.Project) ![]const u8 {
    if (t.target.len > 0) return t.target;
    if (t.parent.len > 0) {
        const parent = board.getTicket(db, a, t.parent) catch return "";
        if (parent.tmux.len > 0 and parent.tmux[0] != '(') return parent.tmux;
        return "";
    }
    return if (homeSession(view, p)) |s| s.tmux_name else "";
}

/// The project's session in the cl list: a live session in its directory,
/// preferably the one named after it, else the oldest.
fn homeSession(view: View, p: board.Project) ?tmux.Session {
    var best: ?tmux.Session = null;
    for (view.sessions) |s| {
        if (!std.mem.eql(u8, s.dir, p.dir)) continue;
        if (std.mem.eql(u8, s.name, p.name) or std.mem.eql(u8, s.name, std.fs.path.basename(p.dir))) return s;
        if (best == null or s.created < best.?.created) best = s;
    }
    return best;
}

/// Another top-level queue ticket of the project is in progress with a
/// session: one Claude works on a queue project at a time.
fn projectBusy(db: board.Db, a: std.mem.Allocator, view: View, t: board.Ticket) !bool {
    var st = try db.query("SELECT tmux FROM tickets WHERE project = ?1 AND id != ?2 AND mode = 'queue' AND parent IS NULL AND tmux != '' AND stage IN " ++ in_progress, .{ t.project, t.id });
    defer st.finalize();
    while (try st.step()) {
        const name = st.text(0);
        if (name[0] == '(' or view.alive(try a.dupe(u8, name))) return true;
    }
    return false;
}

/// Another ticket is in progress in `tmux_name`.
fn targetHasTicket(db: board.Db, tmux_name: []const u8, id: i64) !bool {
    return (try db.int("SELECT 1 FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage IN " ++ in_progress, .{ tmux_name, id })) != null;
}

/// Start `t` now, or again if its session is gone. `force` types a queue
/// ticket into its target even when the target is busy (Claude queues
/// typed messages).
pub fn start(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, force: bool) !void {
    startIn(ctx, cfg, db, a, t, force, null) catch |err| {
        // Busy: it waits in Queued, and the dispatcher starts (or resumes) it
        // there once the session is free.
        if (err == error.TargetBusy and t.stage != .queued and t.stage != .planning) {
            try board.moveTicket(ctx, db, t, .queued);
            try board.clearFlagId(ctx, db, t.id, "ended");
        }
        return err;
    };
}

fn startIn(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, force: bool, view_in: ?View) !void {
    const view = view_in orelse try View.read(ctx, a, cfg);
    if (t.tmux.len > 0) {
        if (t.tmux[0] == '(' or view.alive(t.tmux)) return error.AlreadyStarted;
        // Its session is gone: start it again (a worktree still there is reused).
        try db.exec("UPDATE tickets SET tmux = '' WHERE id = ?1 AND tmux = ?2", .{ t.id, t.tmux });
    }
    const p = try board.getProject(db, a, t.project);
    const target = if (t.mode == .queue) try queueTarget(db, a, t, view, p) else "";
    const live = target.len > 0 and view.alive(target);
    // An untargeted ticket waits for the project's other ticket wherever it runs.
    const busy = t.mode == .queue and t.target.len == 0 and t.parent.len == 0 and try projectBusy(db, a, view, t);
    // Free: idle, with no other ticket in progress there or in the project.
    const free = live and !busy and view.idle(ctx, target) and !try targetHasTicket(db, target, t.id);
    // A ticket that had a conversation of its own picks it back up.
    const target_s = if (live) view.find(target) else null;
    const resume_id = switch (t.mode) {
        .worktree => if (t.worktree.len > 0) resumeId(ctx, cfg, a, t, t.worktree, t.profile) else null,
        .queue => resumeId(ctx, cfg, a, t, p.dir, if (target_s) |s| s.profile else t.profile),
    };
    // Its conversation is still the one open in the target.
    const open_here = resume_id != null and live and if (view.statuses.get(target)) |i| std.mem.eql(u8, i.session_id, resume_id.?) else false;
    // Resuming swaps the session's conversation: never while it is busy, even
    // when forced, or another ticket's conversation would be cut off.
    const can_force = force and (resume_id == null or open_here);
    if (t.mode == .queue and !can_force and !free and (live or busy)) return error.TargetBusy;
    if (!try board.claimStart(db, t.id)) return error.AlreadyStarted;
    errdefer board.releaseStart(db, t.id) catch {};
    const notes = try board.unsentNotes(db, a, t.id);
    const text = if (resume_id != null) try resumePrompt(a, t, notes) else try prompt(a, t, notes);
    var sid: [36]u8 = undefined;
    // What gutter will diff against: the repo as it is now.
    try board.setBase(db, t.id, worktree.baseRev(ctx, a, p.dir));
    switch (t.mode) {
        .worktree => {
            const wt = worktree.create(ctx, a, cfg, p.dir, p.name, t.key, t.title) catch |err| {
                try board.logEvent(ctx, db, t.id, "start failed", worktree.lastError());
                return if (err == error.OutOfMemory) err else error.WorktreeFailed;
            };
            const name = try newSession(ctx, cfg, a, t, wt.path, try std.ascii.allocLowerString(a, t.key), text, &sid, true, resume_id);
            try board.setSession(ctx, db, t.id, name, &sid, wt.path, wt.branch);
        },
        .queue => if (open_here) {
            // Its own conversation is still open there: carry on in it.
            try tmux.sendLine(ctx, target, text);
            try board.setSession(ctx, db, t.id, target, resume_id.?, "", "");
        } else if (live and resume_id == null and (t.parent.len > 0 or !free)) {
            // A sub-ticket goes on in its parent's conversation, and a forced
            // start into a busy session is typed (Claude queues it).
            try tmux.sendLine(ctx, target, text);
            try board.setSession(ctx, db, t.id, target, "", "", "");
        } else if (live) {
            // The session is free: this ticket's conversation there, new or
            // resumed. The one it replaces stays resumable.
            try freshConversation(ctx, cfg, db, a, t, target_s.?, text, &sid, resume_id);
            try board.setSession(ctx, db, t.id, target, &sid, "", "");
        } else {
            // No session yet: start the project's, named after it.
            const name = try newSession(ctx, cfg, a, t, p.dir, std.fs.path.basename(p.dir), text, &sid, false, resume_id);
            try board.setSession(ctx, db, t.id, name, &sid, "", "");
        },
    }
    try board.markNotesSent(db, t.id);
    try board.clearFlagId(ctx, db, t.id, "start-failed");
    try board.clearFlagId(ctx, db, t.id, "ended");
    if (t.stage != .planning) try board.moveTicket(ctx, db, t, .running);
    const now_t = try board.getTicket(db, a, t.key);
    try board.logEvent(ctx, db, t.id, "started", now_t.tmux);
}

/// Worktree tickets of `project` with a live session in progress.
fn runningWorktrees(db: board.Db, a: std.mem.Allocator, view: View, project: []const u8) !i64 {
    var st = try db.query("SELECT tmux FROM tickets WHERE project = ?1 AND mode = 'worktree' AND tmux != '' AND stage IN " ++ in_progress, .{project});
    defer st.finalize();
    var n: i64 = 0;
    while (try st.step()) {
        const name = st.text(0);
        if (std.mem.eql(u8, name, "(starting)") or view.alive(try a.dupe(u8, name))) n += 1;
    }
    return n;
}

/// A ticket moved back to Backlog or Queued lets go of a session that is
/// gone, so it reads as not started and the dispatcher can pick it up. A
/// queued one lets go of a live session too: it starts (or resumes) there
/// again once the session is free.
fn releaseGone(ctx: Ctx, db: board.Db, a: std.mem.Allocator, view: View) !void {
    for ([_]board.Stage{ .backlog, .queued }) |stage| {
        for (try board.listTickets(db, a, .{ .stage = stage })) |t| {
            if (t.tmux.len == 0 or t.tmux[0] == '(') continue;
            if (stage == .backlog and view.alive(t.tmux)) continue;
            try db.exec("UPDATE tickets SET tmux = '' WHERE id = ?1 AND tmux = ?2", .{ t.id, t.tmux });
            try board.clearFlagId(ctx, db, t.id, "ended");
        }
    }
}

/// One dispatcher pass: start what can start, and flag tickets whose session
/// went away. Returns how many tickets it started.
pub fn tick(ctx: Ctx, cfg: config.Config, db: board.Db) !usize {
    // Nothing queued or in progress, and no session to let go of: nothing to look at.
    if ((try db.int("SELECT 1 FROM tickets WHERE stage IN ('queued', 'planning', 'running') OR (stage = 'backlog' AND tmux != '') LIMIT 1", .{})) == null) return 0;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const view = try View.read(ctx, a, cfg);

    // In progress: flag a session that is gone, and keep the flags of a
    // live one in step with what it is waiting on. A queue session shared by
    // several tickets speaks for the newest one in progress there.
    var current: std.StringHashMapUnmanaged(board.Ticket) = .empty;
    for (try board.listTickets(db, a, .{ .done = false })) |t| {
        if (t.stage != .running and t.stage != .planning) continue;
        if (t.tmux.len == 0 or t.tmux[0] == '(') continue;
        if (!view.alive(t.tmux)) {
            board.setFlagId(ctx, db, t.id, "ended", "auto", "its session is gone; start it again or resume it") catch {};
            continue;
        }
        const prev = current.get(t.tmux);
        if (prev == null or prev.?.id < t.id) try current.put(a, t.tmux, t);
    }
    var cur_it = current.valueIterator();
    while (cur_it.next()) |t| {
        const s = view.find(t.tmux) orelse continue;
        signals.sync(ctx, db, a, t.*, view.statuses.get(t.tmux), claude.statusFor(ctx, view.statuses, s)) catch {};
    }

    try releaseGone(ctx, db, a, view);

    // Queued tickets, and planning tickets that never started, oldest first.
    var waiting: std.ArrayList(board.Ticket) = .empty;
    for (try board.listTickets(db, a, .{ .stage = .queued })) |t| if (t.tmux.len == 0) try waiting.append(a, t);
    for (try board.listTickets(db, a, .{ .stage = .planning })) |t| if (t.tmux.len == 0) try waiting.append(a, t);
    std.mem.sort(board.Ticket, waiting.items, {}, struct {
        fn lt(_: void, x: board.Ticket, y: board.Ticket) bool {
            return x.id < y.id;
        }
    }.lt);

    var started: usize = 0;
    for (waiting.items) |t0| {
        // Earlier starts this pass may have set its target.
        const t = board.getTicket(db, a, t0.key) catch continue;
        if (t.tmux.len > 0) continue;
        if (t.mode == .worktree) {
            const p = board.getProject(db, a, t.project) catch continue;
            if (try runningWorktrees(db, a, view, p.name) >= p.slots) continue;
        }
        startIn(ctx, cfg, db, a, t, false, view) catch |err| switch (err) {
            error.TargetBusy, error.AlreadyStarted => continue,
            else => {
                board.setFlagId(ctx, db, t.id, "start-failed", "auto", @errorName(err)) catch {};
                continue;
            },
        };
        started += 1;
        // Sessions changed; re-read before deciding on the next one.
        return started + try tick(ctx, cfg, db);
    }
    return started;
}

/// Run the dispatcher until killed, every few seconds.
pub fn loop(ctx: Ctx, cfg: config.Config, log: *const fn ([]const u8) void) void {
    while (true) : (ctx.sleepMs(3000)) {
        const db = board.open(ctx, cfg) catch {
            log("dispatch: cannot open the board");
            continue;
        };
        defer db.close();
        const n = tick(ctx, cfg, db) catch |err| {
            var buf: [128]u8 = undefined;
            log(std.fmt.bufPrint(&buf, "dispatch: {s}", .{@errorName(err)}) catch "dispatch failed");
            continue;
        };
        if (n > 0) {
            var buf: [64]u8 = undefined;
            log(std.fmt.bufPrint(&buf, "dispatch: started {d} ticket(s)", .{n}) catch "dispatch: started");
        }
    }
}

const HookInput = struct {
    hook_event_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    notification_type: ?[]const u8 = null,
};

/// `cl ticket hook <stop|notify>`, run by Claude Code in a ticket's session
/// with the event as JSON on stdin. Never fails: a hook's error would show
/// up in Claude's session.
pub fn hook(ctx: Ctx, cfg: config.Config, event: []const u8, input: []const u8) void {
    const key = ctx.env.get("CL_TICKET") orelse return;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = board.open(ctx, cfg) catch return;
    defer db.close();
    const t = board.getTicket(db, a, key) catch return;
    const in = std.json.parseFromSliceLeaky(HookInput, a, input, .{ .ignore_unknown_fields = true }) catch HookInput{};
    if (std.mem.eql(u8, event, "stop")) {
        // A finished turn: nothing is waiting on a permission prompt any more.
        board.clearFlagId(ctx, db, t.id, board.flag_input) catch {};
        board.logEvent(ctx, db, t.id, "turn ended", "") catch {};
    } else if (std.mem.eql(u8, event, "notify")) {
        const msg = in.message orelse "";
        const kind = in.notification_type orelse "";
        if (std.mem.eql(u8, kind, "permission_prompt") or std.mem.indexOf(u8, msg, "permission") != null) {
            board.setFlagId(ctx, db, t.id, board.flag_input, "auto", msg) catch {};
        }
    }
}

test prompt {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "wrap fetch", .stage = .planning,
        .mode = .queue, .plan = true, .skill = "grilling", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "QA-1", .children = 0,
    };
    const text = try prompt(arena_state.allocator(), t, &.{.{ .author = "you", .body = "keep it small", .sent = false, .at = 0 }});
    try std.testing.expect(std.mem.indexOf(u8, text, "Ticket QA-3: Retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sub-ticket of QA-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- keep it small") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "grilling skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cl ticket done QA-3") != null);
}

test "queue tickets run one at a time in the project's session" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const p = try board.getProject(db, a, "qa");
    const k1 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "First", .stage = .queued });
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Second", .stage = .queued });
    const t1 = try board.getTicket(db, a, k1);
    const t2 = try board.getTicket(db, a, k2);

    // No session in the project's directory yet: the first start makes one.
    const none: View = .{ .sessions = &.{}, .statuses = .empty };
    try std.testing.expectEqualStrings("", try queueTarget(db, a, t2, none, p));

    // The project's own session wins over an older one and other directories.
    const mk = struct {
        fn s(tmux_name: []const u8, name: []const u8, dir: []const u8, created: i64) tmux.Session {
            return .{ .tmux_name = tmux_name, .name = name, .dir = dir, .profile = "", .created = created, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" };
        }
    }.s;
    var sessions = [_]tmux.Session{ mk("cl_x_1", "x", "/x/other", 1), mk("cl_qa-1_2", "qa-1", "/x/qa-tool", 2), mk("cl_qa-tool_3", "qa-tool", "/x/qa-tool", 3) };
    const view: View = .{ .sessions = &sessions, .statuses = .empty };
    try std.testing.expectEqualStrings("cl_qa-tool_3", try queueTarget(db, a, t2, view, p));
    try std.testing.expectEqualStrings("cl_qa-1_2", (homeSession(.{ .sessions = sessions[0..2], .statuses = .empty }, p)).?.tmux_name);

    // The first one is being tested in some session: the second waits.
    try std.testing.expect(!try projectBusy(db, a, view, t2));
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-1_2', stage = 'testing' WHERE id = ?1", .{t1.id});
    try std.testing.expect(try projectBusy(db, a, view, t2));
    try std.testing.expect(try targetHasTicket(db, "cl_qa-1_2", t2.id));

    // Done frees the project for the next one.
    try db.exec("UPDATE tickets SET stage = 'done' WHERE id = ?1", .{t1.id});
    try std.testing.expect(!try projectBusy(db, a, view, t2));
    try std.testing.expect(!try targetHasTicket(db, "cl_qa-1_2", t2.id));
}

test resumePrompt {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "wrap fetch", .stage = .queued,
        .mode = .queue, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 2, .created = 0, .updated = 0, .parent = "", .children = 0,
    };
    const text = try resumePrompt(arena_state.allocator(), t, &.{.{ .author = "you", .body = "also retry on 503", .sent = false, .at = 0 }});
    try std.testing.expect(std.mem.indexOf(u8, text, "Ticket QA-3 is back on: Retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- also retry on 503") != null);
    // The resumed conversation already has the body and the instructions.
    try std.testing.expect(std.mem.indexOf(u8, text, "wrap fetch") == null);
}

test "a ticket moved back to the queue lets go of its dead session" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Requeued", .stage = .queued });
    const kb = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Shelved", .stage = .backlog });
    const kl = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Live", .stage = .backlog });
    const kw = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Requeued live", .stage = .queued });
    const kr = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Running", .stage = .running });
    for ([_][]const u8{ kq, kb, kr }) |k| try db.exec("UPDATE tickets SET tmux = 'cl_dead_1' WHERE key = ?1", .{k});
    for ([_][]const u8{ kl, kw }) |k| try db.exec("UPDATE tickets SET tmux = 'cl_live_2' WHERE key = ?1", .{k});
    try board.setFlagId(ctx, db, (try board.getTicket(db, a, kq)).id, "ended", "auto", "");

    var sessions = [_]tmux.Session{.{ .tmux_name = "cl_live_2", .name = "live", .dir = "/x/qa-tool", .profile = "", .created = 2, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" }};
    try releaseGone(ctx, db, a, .{ .sessions = &sessions, .statuses = .empty });

    const q = try board.getTicket(db, a, kq);
    try std.testing.expectEqualStrings("", q.tmux);
    try std.testing.expectEqual(@as(usize, 0), q.flags.len);
    try std.testing.expectEqualStrings("", (try board.getTicket(db, a, kb)).tmux);
    // Shelved in Backlog, a live session stays; queued, it waits to start there again.
    try std.testing.expectEqualStrings("cl_live_2", (try board.getTicket(db, a, kl)).tmux);
    try std.testing.expectEqualStrings("", (try board.getTicket(db, a, kw)).tmux);
    // A running ticket keeps its own (it gets the "ended" flag).
    try std.testing.expectEqualStrings("cl_dead_1", (try board.getTicket(db, a, kr)).tmux);
}
