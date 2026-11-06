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
const review = @import("review.zig");
const park = @import("park.zig");
const actions = @import("actions.zig");
const images = @import("images.zig");

pub const Error = error{
    AlreadyStarted,
    /// The queue target is working, or already has a ticket in progress.
    TargetBusy,
    WorktreeFailed,
    SessionFailed,
    /// It has work under way that can't move with it: no jj change of its
    /// own (git, or a sub-ticket in its parent's change).
    NoChange,
    /// Claude is working in its session, or waiting on you: it can't move now.
    Busy,
};

/// What the ticket's session is told first. The key is spelled out, so the
/// instructions work in sessions cl didn't start (no CL_TICKET). `gutter_rev`:
/// gutter is installed, so Claude writes a review guide for it and checks it
/// against this revision (gutter's -r, "" for its default).
pub fn prompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment, gutter_rev: ?[]const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("Ticket {s}: {s}\n", .{ t.key, t.title });
    if (t.parent.len > 0) try w.print("(a sub-ticket of {s}; `cl ticket show {s}` has the bigger picture)\n", .{ t.parent, t.parent });
    if (t.body.len > 0) try w.print("\n{s}\n", .{t.body});
    try images.writeNote(w, a, t.body);
    if (notes.len > 0) {
        try w.writeAll("\nNotes on the ticket:\n");
        for (notes) |n| try w.print("- {s}\n", .{n.body});
    }
    if (t.plan_md.len > 0) try w.print(
        \\
        \\The approved plan, from a planning session before this one (you don't have that
        \\conversation; this is what it left). The code may have changed since it was written:
        \\check the plan against the code as it is now and adapt it where they disagree, and
        \\ask me if that changes what we agreed.
        \\
        \\{s}
        \\
    , .{std.mem.trimEnd(u8, t.plan_md, "\n")});
    try w.print(
        \\
        \\How tickets work here (cl board):
        \\- Ask me with AskUserQuestion when you need a decision; the board shows it.
        \\- To split off a separate piece of work: `cl ticket new --parent {s} "<title>" -m "<details>"`.
        \\- When the work is finished and you need nothing more from me:
        \\{s}  {d}. {s}Run `cl ticket done {s} --summary "<what changed, in a sentence or two>"`.
        \\  {d}. If there is something for me to try, add `--test-plan -` and give the plan on stdin
        \\     (a heredoc, not a file): steps the board walks me through one at a time, with buttons
        \\     to run a command (`run:`, from this directory) and open a page (`open:`), and checks
        \\     ("- [ ] what I should see"). `cl ticket testplan --format` shows the format.
        \\  If its work shouldn't be merged (or made a PR) as it is, say so first with
        \\  `cl ticket custom-close "<what to do with it instead>"`; the board then offers only that.
        \\  Don't run it while you still need anything from me. When I send feedback, finish the same way.
        \\
    , .{
        t.key,
        if (gutter_rev) |rev| try guideStep(a, rev) else "",
        @as(u8, if (gutter_rev != null) 2 else 1),
        if (t.change.len == 0 and t.mode == .worktree) "Commit your work on this branch (the review shows commits and new files that way). " else "",
        t.key,
        @as(u8, if (gutter_rev != null) 3 else 2),
    });
    if (t.change.len > 0) try w.print(
        \\- This is a jj repo, and your work goes into the ticket's jj change {s}{s}{s} by itself:
        \\  don't commit (git or jj), start other changes or switch branches. When it's done, cl merges it.
        \\
    , .{ t.change[0..@min(t.change.len, 12)], if (t.branch.len > 0) ", bookmark " else "", t.branch });
    return aw.written();
}

/// The review guide step. Checking the guide means starting gutter, which
/// opens a browser tab on the human's screen unless told not to (and the
/// check's timeout leaves it blank): the command given never opens one.
fn guideStep(a: std.mem.Allocator, rev: []const u8) ![]const u8 {
    const r = if (rev.len > 0) try std.fmt.allocPrint(a, " -r '{s}'", .{rev}) else "";
    return std.fmt.allocPrint(a,
        \\  1. Write a review guide to .claude/review-guide.md (`gutter -guide-format` shows the format).
        \\     To check it, run `timeout 5 gutter -open=false -port 0{s}` and read the line it prints
        \\     starting "guide: N stop(s), D dead reference(s), U unassigned line(s)". Whenever you
        \\     run gutter yourself, pass -open=false and never -window: otherwise it opens a browser
        \\     tab or window on my screen.
        \\
    , .{r});
}

/// Where a planning session reads the code.
pub const PlanDir = union(enum) {
    /// Its own read-only workspace on this revision (a trunk bookmark, or
    /// "HEAD" for git).
    trunk: []const u8,
    /// The project's checkout (no workspace could be made).
    checkout,
};

/// What a planning session is told first: plan only, then hand the plan in
/// for the session that builds it.
pub fn planPrompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment, where: PlanDir) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("Ticket {s}: {s}\n", .{ t.key, t.title });
    if (t.parent.len > 0) try w.print("(a sub-ticket of {s}; `cl ticket show {s}` has the bigger picture)\n", .{ t.parent, t.parent });
    if (t.body.len > 0) try w.print("\n{s}\n", .{t.body});
    try images.writeNote(w, a, t.body);
    if (notes.len > 0) {
        try w.writeAll("\nNotes on the ticket:\n");
        for (notes) |n| try w.print("- {s}\n", .{n.body});
    }
    try w.writeAll("\nThis is a planning session: plan the ticket, don't build it. Don't write or change code or any other file, and don't commit; once I approve the plan, a new session builds it.\n");
    switch (where) {
        .trunk => |rev| try w.print("You're in a read-only copy of the project at {s}, for reading the code; it goes away when planning ends.\n", .{rev}),
        .checkout => try w.writeAll("You're in the project's checkout, which may hold another ticket's unfinished work: read it as the code to plan against, but its files may not be what is merged.\n"),
    }
    try w.writeAll("\nAsk me with AskUserQuestion until the plan is clear");
    if (t.skill.len > 0) try w.print(" (use the {s} skill for the interview)", .{t.skill});
    try w.print(
        \\. The session that builds it won't see
        \\this conversation, only the plan: write it for a reader who starts cold, with every decision
        \\we made and why, the files and functions to change, what to test, and what is still open.
        \\
        \\When the plan is ready, hand it in with
        \\`cl ticket done {s} --summary "<the plan in a sentence>" --plan` and the plan as markdown on
        \\stdin (a heredoc, not a file). The board shows it to me for approval; that is the end of your
        \\part. Don't call ExitPlanMode. If I send feedback on the plan, revise it and hand it in the
        \\same way. To split off a separate piece of work: `cl ticket new --parent {s} "<title>" -m "<details>"`
        \\(it waits until the plan is approved).
        \\
    , .{ t.key, t.key });
    return aw.written();
}

/// Told before anything else when the checkout was just switched to the
/// ticket's change: its files are not what was running.
const switched_note =
    \\The project's checkout was just switched to this ticket's change, so its files differ from what was there before. Before anything else, if something runs from this checkout (an installed build, a server; the project's CLAUDE.md may say what and how), rebuild and restart it so it serves this ticket's code.
    \\
    \\
;

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
    // Its pasted images, readable without a permission prompt (they're
    // outside the project). Like the tool list, it takes every argument up to
    // the next option.
    if (images.ticketDir(ctx, a, cfg, t.key)) |d| try args.appendSlice(a, &.{ "--add-dir", d });
    try args.appendSlice(a, &.{ if (resuming) "--resume" else "--session-id", sid, "--settings", try hooksFile(ctx, a, cfg) });
    // Planning writes nothing, and ExitPlanMode would let it start building.
    // The tool list goes before another option: it takes every argument up to one.
    if (t.stage == .planning) try args.appendSlice(a, &.{ "--disallowedTools", "Edit,Write,NotebookEdit,ExitPlanMode", "--permission-mode", "plan" });
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

/// A new Claude session for the ticket in `dir` (the project's folder or a
/// worktree of it), told about it first; with `resume_id`, it picks the
/// ticket's earlier conversation back up. A project on the board is one the
/// human trusts, so Claude's folder-trust dialog there gets a yes.
fn newSession(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, t: board.Ticket, dir: []const u8, name: []const u8, text: []const u8, session_id: *[36]u8, resume_id: ?[]const u8) ![]const u8 {
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
        .accept_trust = cfg.board.trust_projects,
    }) catch error.SessionFailed;
}

/// The ticket's own conversation to pick back up, when Claude still has its
/// transcript for `dir`. Tickets typed into another conversation have none.
fn resumeId(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, t: board.Ticket, dir: []const u8, profile: []const u8) ?[]const u8 {
    if (t.session_id.len != 36) return null;
    const config_dir = configDir(ctx, cfg, a, profile) orelse return null;
    return if (claude.canResume(ctx, a, config_dir, dir, t.session_id)) t.session_id else null;
}

/// Where Claude keeps its transcripts for `profile`.
fn configDir(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, profile: []const u8) ?[]const u8 {
    const prof = cfg.find(profile) orelse cfg.defaultProfile();
    return prof.config_dir orelse (claude.defaultConfigDir(ctx, a) catch null);
}

/// Take the ticket's conversation (and cl's files for it) from checkout
/// `from` to `to`: Claude keeps transcripts by directory, so this is what
/// lets it resume there. The conversation to resume, or null when `from`
/// has none.
fn carryConversation(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, t: board.Ticket, from: []const u8, to: []const u8) ?[]const u8 {
    if (t.session_id.len != 36) return null;
    const config_dir = configDir(ctx, cfg, a, t.profile) orelse return null;
    if (!(claude.copyTranscript(ctx, a, config_dir, from, to, t.session_id) catch false)) return null;
    worktree.carryClFiles(ctx, a, from, to);
    return resumeId(ctx, cfg, a, t, to, t.profile);
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
/// not finished until it reaches done. Planning holds neither: it runs in a
/// session and workspace of its own (see `startPlanning`).
const in_progress = board.in_progress;

/// Where a queue ticket runs: its target, else its parent's session, else
/// the project's own session (see `homeSession`).
fn queueTarget(db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View, p: board.Project) ![]const u8 {
    if (t.target.len > 0) return t.target;
    if (try parentSession(db, a, t, view)) |s| return s;
    return if (homeSession(view, p)) |s| s.tmux_name else "";
}

/// The live session of `t`'s parent while the parent is in progress: a
/// sub-ticket goes on in that conversation. With the parent finished or its
/// session gone, the sub-ticket waits its turn like a top-level ticket. A
/// parent still planning has only its planning session: see `parentPlanning`.
fn parentSession(db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View) !?[]const u8 {
    if (t.parent.len == 0) return null;
    const parent = board.getTicket(db, a, t.parent) catch |err| return if (err == error.NotFound) null else err;
    if (parent.tmux.len == 0 or parent.tmux[0] == '(' or !view.alive(parent.tmux)) return null;
    return switch (parent.stage) {
        .running, .review, .testing => parent.tmux,
        else => null,
    };
}

/// `t`'s parent is still being planned: the sub-ticket waits for the plan.
fn parentPlanning(db: board.Db, a: std.mem.Allocator, t: board.Ticket) !bool {
    if (t.parent.len == 0) return false;
    const parent = board.getTicket(db, a, t.parent) catch |err| return if (err == error.NotFound) false else err;
    return parent.stage == .planning;
}

/// The planning session's tmux name starts with this (launch names
/// sessions cl_<name>_<n>, and a planning session is named <key>-plan).
fn planSessionPrefix(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "cl_{s}-plan_", .{try std.ascii.allocLowerString(a, key)});
}

fn isPlanSession(a: std.mem.Allocator, t: board.Ticket) !bool {
    return std.mem.startsWith(u8, t.tmux, try planSessionPrefix(a, t.key));
}

/// Planning sessions of `project` that are running (or starting).
fn runningPlanners(db: board.Db, a: std.mem.Allocator, view: View, project: []const u8) !i64 {
    var st = try db.query("SELECT tmux FROM tickets WHERE project = ?1 AND stage = 'planning' AND tmux != ''", .{project});
    defer st.finalize();
    var n: i64 = 0;
    while (try st.step()) {
        const name = st.text(0);
        if (std.mem.eql(u8, name, "(starting)") or view.alive(try a.dupe(u8, name))) n += 1;
    }
    return n;
}

/// Start `t`'s planning session: a new session of its own in a read-only
/// workspace on trunk (the project's checkout when none can be made),
/// resuming its planning conversation if it had one. It takes no queue turn
/// or worktree slot, and leaves the ticket's change alone.
fn startPlanning(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !void {
    const p = try board.getProject(db, a, t.project);
    if (!try board.claimStart(db, t.id)) return error.AlreadyStarted;
    errdefer board.releaseStart(db, t.id) catch {};
    _ = worktree.ensureJj(ctx, a, p.dir);
    const trunk = worktree.trunkBookmark(ctx, a, p.dir);
    const path = try worktree.planPath(ctx, a, cfg, p.name, t.key);
    var dir = path;
    var where: PlanDir = .{ .trunk = trunk orelse "HEAD" };
    worktree.createPlan(ctx, a, p.dir, path, trunk) catch |err| {
        if (err == error.OutOfMemory) return err;
        try board.logEvent(ctx, db, t.id, "no planning workspace", worktree.lastError());
        dir = p.dir;
        where = .checkout;
    };
    const resume_id = resumeId(ctx, cfg, a, t, dir, t.profile);
    const notes = try board.unsentNotes(db, a, t.id);
    const text = if (resume_id != null) try resumePrompt(a, t, notes) else try planPrompt(a, t, notes, where);
    var sid: [36]u8 = undefined;
    const name = try std.fmt.allocPrint(a, "{s}-plan", .{try std.ascii.allocLowerString(a, t.key)});
    const tmux_name = try newSession(ctx, cfg, a, t, dir, name, text, &sid, resume_id);
    // Its worktree and bookmark (from an earlier round) stay as they are.
    try board.setSession(ctx, db, t.id, tmux_name, &sid, t.worktree, t.branch);
    try board.markNotesSent(db, t.id);
    try board.clearFlagId(ctx, db, t.id, "start-failed");
    try board.clearFlagId(ctx, db, t.id, "ended");
    try board.logEvent(ctx, db, t.id, "planning started", tmux_name);
}

/// Planning is over for `t` (approved, or moved on): close its planning
/// session and workspace, and forget that conversation so the session that
/// builds it starts a new one, with the plan.
fn endPlanning(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View) !void {
    if (view.alive(t.tmux)) tmux.kill(ctx, t.tmux) catch {};
    const p = try board.getProject(db, a, t.project);
    worktree.removePlan(ctx, a, p.dir, try worktree.planPath(ctx, a, cfg, p.name, t.key));
    try db.exec("UPDATE tickets SET tmux = '', session_id = '' WHERE id = ?1 AND tmux = ?2", .{ t.id, t.tmux });
    try board.clearFlagId(ctx, db, t.id, "ended");
    try board.logEvent(ctx, db, t.id, "planning ended", t.tmux);
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

/// Another queue ticket of the project is in progress with a session: one
/// Claude works on a queue project at a time.
fn projectBusy(db: board.Db, a: std.mem.Allocator, view: View, t: board.Ticket) !bool {
    var st = try db.query("SELECT tmux FROM tickets WHERE project = ?1 AND id != ?2 AND mode = 'queue' AND tmux != '' AND stage IN " ++ in_progress, .{ t.project, t.id });
    defer st.finalize();
    while (try st.step()) {
        const name = st.text(0);
        if (name[0] == '(' or view.alive(try a.dupe(u8, name))) return true;
    }
    return false;
}

const targetHasTicket = board.sessionHasTicket;

/// Start `t` now, or again if its session is gone. `force` types a queue
/// ticket into its target even when the target is busy (Claude queues
/// typed messages).
pub fn start(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, force: bool) !void {
    return startKeeping(ctx, cfg, db, a, t, force, false);
}

/// `start`; with `keep_stage` a ticket in Review or Testing stays there (it
/// moved, it wasn't sent back).
fn startKeeping(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, force: bool, keep_stage: bool) !void {
    startIn(ctx, cfg, db, a, t, force, null, keep_stage) catch |err| {
        // Busy: it waits in Queued, and the dispatcher starts (or resumes) it
        // there once the session is free.
        if (err == error.TargetBusy and t.stage != .queued and t.stage != .planning) {
            try board.moveTicket(ctx, db, t, .queued);
            try board.clearFlagId(ctx, db, t.id, "ended");
        }
        return err;
    };
}

pub const Relocated = enum {
    /// Only its mode changed: it hadn't started, so it starts the new way.
    mode,
    /// It went on in its new place.
    moved,
    /// It wasn't under way but was queued (or beyond, its session gone):
    /// it started in its own worktree there and then.
    started,
    /// It waits in Queued: for the project's session (back in the queue),
    /// or for a worktree slot.
    waiting,
};

/// Move a ticket between the queue and a worktree of its own (`to`). One
/// that hasn't started, or has nothing to carry, only changes mode. One
/// under way takes its jj change and its conversation along. To a worktree:
/// a jj workspace on its change, the conversation copied there and resumed,
/// and the queue session gets a new conversation (free for the next ticket).
/// Back to the queue: the workspace is forgotten (its work stays in the
/// change), and the conversation resumes in the project's checkout on the
/// change, in the project's session once that is free. Either way it may
/// wait in Queued: for the project's session, or for one of the project's
/// worktree slots. Its change and bookmark stay the same. Claude is told it
/// moved. Refused while its session is working or waiting on something.
/// One switched to a worktree while not under way starts there now when it
/// is queued or beyond (`startSwitched`), not on the dispatcher's next pass.
pub fn relocate(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, to: board.Mode) !Relocated {
    if (t.mode == to) return .mode;
    const r = try relocateMode(ctx, cfg, db, a, t, to);
    if (r != .mode or to != .worktree) return r;
    return startSwitched(ctx, cfg, db, a, t.key);
}

/// A ticket just switched to a worktree that isn't under way: queued, or
/// running, in review or testing with its session gone. It has nothing left
/// to wait for (no shared session), so it starts in its own worktree now,
/// within the project's slots; with all of them taken it waits in Queued
/// for one. Backlog and planning stay put, as do killed and parked tickets.
fn startSwitched(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8) !Relocated {
    const t = try board.getTicket(db, a, key);
    const view = try View.read(ctx, a, cfg);
    const p = try board.getProject(db, a, t.project);
    const started = t.tmux.len > 0 and (t.tmux[0] == '(' or view.alive(t.tmux));
    switch (switchedStart(t, started, try runningWorktrees(db, a, view, p.name), p.slots)) {
        .stay => return .mode,
        .wait => {
            if (t.stage != .queued) {
                try board.moveTicket(ctx, db, t, .queued);
                try board.clearFlagId(ctx, db, t.id, "ended");
            }
            return .waiting;
        },
        .start => {},
    }
    startIn(ctx, cfg, db, a, t, false, view, true) catch |err| switch (err) {
        // The dispatcher got there first.
        error.AlreadyStarted => return .started,
        else => return err,
    };
    return .started;
}

/// What a ticket just switched to a worktree does: `started` when it has a
/// live session (or one starting) already, `running` the project's worktree
/// tickets in progress, out of its `slots`.
fn switchedStart(t: board.Ticket, started: bool, running: i64, slots: i64) enum { stay, start, wait } {
    switch (t.stage) {
        .queued, .running, .review, .testing => {},
        .backlog, .planning, .done => return .stay,
    }
    if (started or t.killed or t.park != null) return .stay;
    return if (running >= slots) .wait else .start;
}

fn relocateMode(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, to: board.Mode) !Relocated {
    if (t.tmux.len > 0 and t.tmux[0] == '(') return error.Busy;
    const view = try View.read(ctx, a, cfg);
    const p = try board.getProject(db, a, t.project);
    const live = t.tmux.len > 0 and view.alive(t.tmux);
    const trunk = worktree.trunkBookmark(ctx, a, p.dir);
    const own = trunk != null and t.change.len > 0 and worktree.changeState(ctx, a, p.dir, t.change, trunk.?) == .open;
    if (!own) {
        // Work under way with nothing to carry it in: it would be left behind.
        if (live or t.worktree.len > 0) return error.NoChange;
        try board.updateTicket(ctx, db, a, t.key, .{ .mode = to });
        return .mode;
    }
    if (live) {
        // Claude mid-turn, or a question or prompt that would be lost.
        if (!view.idle(ctx, t.tmux)) return error.Busy;
        // A sub-ticket going on in this conversation would lose it.
        if (try targetHasTicket(db, t.tmux, t.id)) return error.Busy;
    }
    review.stopGutter(ctx, a, t.key) catch {};
    review.stopLaunch(ctx, a, t.key, null) catch {};
    const short = t.change[0..@min(t.change.len, 12)];
    var note: []const u8 = undefined;
    switch (to) {
        .worktree => {
            // Its own conversation open in the queue session: that session
            // gets a new one, and this one goes on in the worktree.
            if (live) if (view.statuses.get(t.tmux)) |info| if (std.mem.eql(u8, info.session_id, t.session_id)) {
                const s = view.find(t.tmux).?;
                tmux.respawn(ctx, s.tmux_name, s.dir, &.{}, &.{"claude"}) catch return error.SessionFailed;
            };
            note = try std.fmt.allocPrint(a, "This ticket moved from the project's main folder ({s}) to a worktree of its own, your current directory now: work, build and run things there from now on. Its jj change {s} came along and is checked out there; the main folder has moved on to other work.", .{ p.dir, short });
        },
        .queue => {
            if (live) tmux.kill(ctx, t.tmux) catch {};
            if (t.worktree.len > 0) {
                _ = carryConversation(ctx, cfg, a, t, t.worktree, p.dir);
                worktree.forget(ctx, a, p.dir, t.worktree) catch {
                    try board.logEvent(ctx, db, t.id, "move failed", worktree.lastError());
                    return error.WorktreeFailed;
                };
                try board.logEvent(ctx, db, t.id, "worktree removed", t.worktree);
            }
            note = try std.fmt.allocPrint(a, "This ticket moved from its worktree{s}{s} back to the project's main folder ({s}), your current directory now: work, build and run things there from now on. Its jj change {s} is checked out there.", .{ if (t.worktree.len > 0) " at " else "", t.worktree, p.dir, short });
        },
    }
    try board.updateTicket(ctx, db, a, t.key, .{ .mode = to });
    try board.setSession(ctx, db, t.id, "", t.session_id, "", t.branch);
    try board.logEvent(ctx, db, t.id, "moved", @tagName(to));
    _ = try board.addComment(ctx, db, a, t.key, "cl", note, false);
    // Not under way (Backlog, Queued, or its session had ended): it goes on
    // in its new place when it starts.
    if (!live) return .mode;
    const now_t = try board.getTicket(db, a, t.key);
    // Every worktree slot taken: it waits in Queued, and the dispatcher
    // starts it in its worktree (the conversation comes along) when one frees.
    if (to == .worktree and try runningWorktrees(db, a, view, p.name) >= p.slots) {
        try board.moveTicket(ctx, db, now_t, .queued);
        try board.clearFlagId(ctx, db, t.id, "ended");
        return .waiting;
    }
    startKeeping(ctx, cfg, db, a, now_t, false, true) catch |err| switch (err) {
        error.TargetBusy => return .waiting,
        error.AlreadyStarted => return .moved,
        else => return err,
    };
    return .moved;
}

fn startIn(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, force: bool, view_in: ?View, keep_stage: bool) !void {
    const view = view_in orelse try View.read(ctx, a, cfg);
    if (t.tmux.len > 0) {
        if (t.tmux[0] == '(' or view.alive(t.tmux)) return error.AlreadyStarted;
        // Its session is gone: start it again (a worktree still there is reused).
        try db.exec("UPDATE tickets SET tmux = '' WHERE id = ?1 AND tmux = ?2", .{ t.id, t.tmux });
    }
    if (t.stage == .planning) return startPlanning(ctx, cfg, db, a, t);
    if (try parentPlanning(db, a, t)) return error.TargetBusy;
    const p = try board.getProject(db, a, t.project);
    const target = if (t.mode == .queue) try queueTarget(db, a, t, view, p) else "";
    const live = target.len > 0 and view.alive(target);
    // A sub-ticket going on in its parent's live conversation.
    const in_parent = t.mode == .queue and t.target.len == 0 and (try parentSession(db, a, t, view)) != null;
    // An untargeted ticket waits for the project's other ticket wherever it runs.
    const busy = t.mode == .queue and t.target.len == 0 and !in_parent and try projectBusy(db, a, view, t);
    // Free: idle, with no other ticket in progress there or in the project.
    const free = live and !busy and view.idle(ctx, target) and !try targetHasTicket(db, target, t.id);
    // A ticket that had a conversation of its own picks it back up.
    const target_s = if (live) view.find(target) else null;
    var resume_id = switch (t.mode) {
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
    // Projects added before jj was set up on add get it on their first start.
    if (worktree.ensureJj(ctx, a, p.dir)) try board.logEvent(ctx, db, t.id, "jj init", p.dir);
    // What gutter will diff against: the repo as it is now.
    const base = worktree.baseRev(ctx, a, p.dir);
    try board.setBase(db, t.id, base);
    // jj: the ticket's own change, on top of trunk. A queue ticket takes the
    // project's checkout over only when it gets the session to itself.
    const trunk = worktree.trunkBookmark(ctx, a, p.dir);
    if (trunk != null) worktree.excludeClFiles(ctx, a, p.dir);
    const desc = try std.fmt.allocPrint(a, "{s}: {s}", .{ t.key, t.title });
    var tc = t;
    var wt: worktree.Worktree = .{ .path = "", .branch = "" };
    var switched = false;
    switch (t.mode) {
        .worktree => {
            // A change of its own already (it ran in the queue): the
            // worktree works on that one.
            const own = trunk != null and t.change.len > 0 and worktree.changeState(ctx, a, p.dir, t.change, trunk.?) == .open;
            wt = (if (own)
                worktree.createOn(ctx, a, cfg, p.dir, p.name, t.key, t.title, t.change, t.branch, trunk.?)
            else
                worktree.create(ctx, a, cfg, p.dir, p.name, t.key, t.title, trunk orelse "", desc)) catch |err| {
                try board.logEvent(ctx, db, t.id, "start failed", worktree.lastError());
                return if (err == error.OutOfMemory) err else error.WorktreeFailed;
            };
            // Its conversation ran in the project's checkout: it comes along.
            if (resume_id == null) resume_id = carryConversation(ctx, cfg, a, t, p.dir, wt.path);
            // A worktree made earlier keeps the change it has.
            if (wt.change.len > 0) {
                try board.setChange(db, t.id, wt.change, wt.branch);
                tc.change = wt.change;
                tc.branch = wt.branch;
            } else if (t.change.len > 0) wt.branch = t.branch;
        },
        // Never while another ticket of the project is in progress (a
        // forced start): its files would go from under it.
        .queue => if (trunk != null and !in_parent and (free or !live) and !try projectBusy(db, a, view, t)) {
            if (try ticketChange(ctx, db, a, p.dir, t, trunk.?, desc)) |c| {
                tc.change = c.change.id;
                tc.branch = c.change.bookmark;
                switched = c.switched;
            }
        },
    }
    const notes = try board.unsentNotes(db, a, t.id);
    const body = if (resume_id != null) try resumePrompt(a, tc, notes) else try prompt(a, tc, notes, if (review.findGutter(ctx, a, cfg) != null)
        try worktree.reviewRev(ctx, a, if (wt.path.len > 0) wt.path else p.dir, base, tc.change)
    else
        null);
    const text = if (switched) try std.mem.concat(a, u8, &.{ switched_note, body }) else body;
    var sid: [36]u8 = undefined;
    switch (t.mode) {
        .worktree => {
            const name = try newSession(ctx, cfg, a, t, wt.path, try std.ascii.allocLowerString(a, t.key), text, &sid, resume_id);
            try board.setSession(ctx, db, t.id, name, &sid, wt.path, wt.branch);
        },
        .queue => if (open_here) {
            // Its own conversation is still open there: carry on in it.
            try tmux.sendLine(ctx, target, text);
            try board.setSession(ctx, db, t.id, target, resume_id.?, "", "");
        } else if (live and resume_id == null and (in_parent or !free)) {
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
            const name = try newSession(ctx, cfg, a, t, p.dir, std.fs.path.basename(p.dir), text, &sid, resume_id);
            try board.setSession(ctx, db, t.id, name, &sid, "", "");
        },
    }
    // setSession cleared it for a queue ticket.
    if (tc.change.len > 0) try board.setChange(db, t.id, tc.change, tc.branch);
    try board.markNotesSent(db, t.id);
    try board.clearFlagId(ctx, db, t.id, "start-failed");
    try board.clearFlagId(ctx, db, t.id, "ended");
    if (!(keep_stage and (t.stage == .review or t.stage == .testing))) try board.moveTicket(ctx, db, t, .running);
    const now_t = try board.getTicket(db, a, t.key);
    try board.logEvent(ctx, db, t.id, "started", now_t.tmux);
}

/// Put the project's checkout `dir` on the ticket's change: its own when it
/// has one still open, else a new one on top of `trunk`. A ticket that ran
/// before tickets had changes takes the checkout's undescribed work as its
/// change. Undescribed work the checkout leaves behind is logged and noted on
/// the ticket. `switched` is true when the checkout's files changed. null
/// (logged) when jj refused.
fn ticketChange(ctx: Ctx, db: board.Db, a: std.mem.Allocator, dir: []const u8, t: board.Ticket, trunk: []const u8, desc: []const u8) !?struct { change: worktree.Change, switched: bool } {
    const before = worktree.workingCommit(ctx, a, dir) catch "";
    const stray = worktree.strayWork(ctx, a, dir, trunk);
    const open = t.change.len > 0 and worktree.changeState(ctx, a, dir, t.change, trunk) == .open;
    const bookmark = try worktree.slug(a, t.key, t.title);
    // Ran before tickets had changes (a base and no change): it worked on
    // whatever the checkout had, so that is its work.
    if (stray != null and t.change.len == 0 and t.base.len > 0) {
        const c = worktree.adoptChange(ctx, a, dir, desc, bookmark) catch {
            try board.logEvent(ctx, db, t.id, "no change", worktree.lastError());
            return null;
        };
        try board.setChange(db, t.id, c.id, c.bookmark);
        try board.logEvent(ctx, db, t.id, "adopted change", c.id);
        return .{ .change = c, .switched = false };
    }
    const c: worktree.Change = blk: {
        if (open) {
            _ = worktree.editChange(ctx, a, dir, t.change) catch {
                try board.logEvent(ctx, db, t.id, "no change", worktree.lastError());
                return null;
            };
            break :blk .{ .id = t.change, .bookmark = t.branch };
        }
        // None yet, or merged already (reopened after Done), or abandoned: a new one.
        const c = worktree.newChange(ctx, a, dir, trunk, desc, bookmark) catch {
            try board.logEvent(ctx, db, t.id, "no change", worktree.lastError());
            return null;
        };
        // Kept at once: a start that fails later on finds it next time.
        try board.setChange(db, t.id, c.id, c.bookmark);
        try board.logEvent(ctx, db, t.id, "change", c.id);
        break :blk c;
    };
    // jj keeps work the checkout left, but nothing points at it: say where.
    if (stray) |id| if (!std.mem.eql(u8, id, c.id)) {
        const short = id[0..@min(id.len, 12)];
        try board.logEvent(ctx, db, t.id, "left undescribed work", id);
        _ = try board.addComment(ctx, db, a, t.key, "claude", try std.fmt.allocPrint(a, "The project's checkout held uncommitted work in an undescribed change, {s}, that belongs to no ticket. It was left there for this ticket's change: `jj log -r {s}` shows it, `jj edit {s}` goes back to it.", .{ short, short, short }), false);
    };
    const switched = before.len > 0 and worktree.filesDiffer(ctx, a, dir, before);
    // Where the checkout was, in case it held work of someone's own (jj keeps it there).
    if (switched) try board.logEvent(ctx, db, t.id, "checkout switched from", before[0..@min(before.len, 12)]);
    return .{ .change = c, .switched = switched };
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
    // Parked tickets' checks (they run detached; a passing one resumes its ticket).
    park.checkDue(ctx, db) catch {};
    // Nothing queued or in progress, and no session to let go of: nothing to look at.
    if ((try db.int("SELECT 1 FROM tickets WHERE stage IN ('queued', 'planning', 'running') OR (stage = 'backlog' AND tmux != '') OR tmux LIKE '%-plan\\_%' ESCAPE '\\' LIMIT 1", .{})) == null) return 0;
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

    // Out of Planning (approved, or moved): its planning session goes, before
    // the ticket can start building.
    {
        var st = try db.query("SELECT key FROM tickets WHERE stage != 'planning' AND tmux LIKE '%-plan\\_%' ESCAPE '\\'", .{});
        defer st.finalize();
        var keys: std.ArrayList([]const u8) = .empty;
        while (try st.step()) try keys.append(a, try st.dupe(a, 0));
        for (keys.items) |k| {
            const t = board.getTicket(db, a, k) catch continue;
            if (try isPlanSession(a, t)) endPlanning(ctx, cfg, db, a, t, view) catch {};
        }
    }

    try releaseGone(ctx, db, a, view);

    // Planning tickets that never started, in board order, up to each
    // project's planners. They don't wait for the queue or worktree slots.
    const planning = try board.listTickets(db, a, .{ .stage = .planning });
    std.mem.sort(board.Ticket, planning, {}, byRank);
    for (planning) |t| {
        if (t.tmux.len > 0 or t.killed or t.park != null) continue;
        const p = board.getProject(db, a, t.project) catch continue;
        if (try runningPlanners(db, a, view, p.name) >= p.planners) continue;
        startPlanning(ctx, cfg, db, a, t) catch |err| switch (err) {
            error.AlreadyStarted => continue,
            else => {
                board.setFlagId(ctx, db, t.id, "start-failed", "auto", @errorName(err)) catch {};
                continue;
            },
        };
        return 1 + try tick(ctx, cfg, db);
    }

    var started: usize = 0;
    for (try waitingToStart(db, a)) |t0| {
        // Earlier starts this pass may have set its target.
        const t = board.getTicket(db, a, t0.key) catch continue;
        if (t.tmux.len > 0) continue;
        if (t.mode == .worktree) {
            const p = board.getProject(db, a, t.project) catch continue;
            if (try runningWorktrees(db, a, view, p.name) >= p.slots) continue;
        }
        startIn(ctx, cfg, db, a, t, false, view, false) catch |err| switch (err) {
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

/// What the dispatcher may start, in board order: queued tickets (planning
/// ones start on their own, up to the project's planners). A killed one waits for you to
/// restart it, and a parked one for its park to end, in whatever stage
/// (moving it to Queued doesn't start it).
fn waitingToStart(db: board.Db, a: std.mem.Allocator) ![]board.Ticket {
    var waiting: std.ArrayList(board.Ticket) = .empty;
    for (try board.listTickets(db, a, .{ .stage = .queued })) |t| if (t.tmux.len == 0 and !t.killed and t.park == null) try waiting.append(a, t);
    std.mem.sort(board.Ticket, waiting.items, {}, byRank);
    return waiting.items;
}

/// Board order: rank, then oldest first.
fn byRank(_: void, x: board.Ticket, y: board.Ticket) bool {
    return x.rank < y.rank or (x.rank == y.rank and x.id < y.id);
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
        // A finished turn: nothing is waiting on a prompt or question any more.
        board.clearFlagId(ctx, db, t.id, board.flag_input) catch {};
        board.clearFlagId(ctx, db, t.id, board.flag_question) catch {};
        board.logEvent(ctx, db, t.id, "turn ended", "") catch {};
    } else if (std.mem.eql(u8, event, "notify")) {
        const msg = in.message orelse "";
        const kind = in.notification_type orelse "";
        if (std.mem.eql(u8, kind, "permission_prompt") or std.mem.indexOf(u8, msg, "permission") != null) {
            // An AskUserQuestion menu sends this too. Claude's registry
            // (already "waiting" by now) tells the two apart, as the
            // dispatcher does; this way it is right even where the
            // dispatcher doesn't look (a ticket not in progress).
            const statuses = claude.readStatuses(ctx, a, cfg) catch claude.StatusMap.empty;
            if (t.tmux.len > 0 and t.tmux[0] != '(') if (statuses.get(t.tmux)) |info| {
                signals.sync(ctx, db, a, t, info, .blocked) catch {};
                return;
            };
            board.setFlagId(ctx, db, t.id, board.flag_input, "auto", msg) catch {};
        }
    }
}

test prompt {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "wrap fetch", .stage = .queued,
        .mode = .queue, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "QA-1", .children = 0,
    };
    const text = try prompt(arena_state.allocator(), t, &.{.{ .author = "you", .body = "keep it small", .sent = false, .at = 0 }}, "abc::");
    try std.testing.expect(std.mem.indexOf(u8, text, "Ticket QA-3: Retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sub-ticket of QA-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- keep it small") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "approved plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cl ticket done QA-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  1. Write a review guide") != null);
    // Checking the guide never opens a browser tab or window.
    try std.testing.expect(std.mem.indexOf(u8, text, "`timeout 5 gutter -open=false -port 0 -r 'abc::'`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pass -open=false and never -window") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  2. Run `cl ticket done QA-3") != null);
    // No revision to give: gutter's default.
    const no_rev = try prompt(arena_state.allocator(), t, &.{}, "");
    try std.testing.expect(std.mem.indexOf(u8, no_rev, "`timeout 5 gutter -open=false -port 0`") != null);
    // Without gutter: no review guide, and the steps are numbered from 1.
    const plain = try prompt(arena_state.allocator(), t, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "gutter") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "me:\n  1. Run `cl ticket done QA-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "  2. If there is something") != null);
}

test "the session is told to open the description's images" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "It breaks here:\n![image](/b/images/QA-3/0a1b.png)", .stage = .queued,
        .mode = .queue, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0,
    };
    const want = "![image](/b/images/QA-3/0a1b.png)\n\nThe description has an image (pasted on the board). Open it with your Read tool to see it:\n- /b/images/QA-3/0a1b.png\n";
    try std.testing.expect(std.mem.indexOf(u8, try prompt(a, t, &.{}, false), want) != null);
    try std.testing.expect(std.mem.indexOf(u8, try planPrompt(a, t, &.{}, .checkout), want) != null);
    t.body = "no pictures";
    try std.testing.expect(std.mem.indexOf(u8, try prompt(a, t, &.{}, false), "Read tool") == null);
}

test "the session that builds a planned ticket is told the plan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "wrap fetch", .stage = .queued,
        .mode = .queue, .plan = true, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0,
        .plan_md = "## Approach\nRetry fetch three times in api.ts.\n\n",
    };
    const text = try prompt(arena_state.allocator(), t, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, text, "approved plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "check the plan against the code as it is now") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "## Approach\nRetry fetch three times in api.ts.\n\nHow tickets work") != null);
}

test planPrompt {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "wrap fetch", .stage = .planning,
        .mode = .queue, .plan = true, .skill = "grilling", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "QA-1", .children = 0,
    };
    const text = try planPrompt(a, t, &.{.{ .author = "you", .body = "keep it small", .sent = false, .at = 0 }}, .{ .trunk = "master" });
    try std.testing.expect(std.mem.indexOf(u8, text, "Ticket QA-3: Retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sub-ticket of QA-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- keep it small") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "grilling skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "don't build it") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "read-only copy of the project at master") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`cl ticket done QA-3 --summary \"<the plan in a sentence>\" --plan`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Don't call ExitPlanMode") != null);
    // Nothing about building: no review guide, test plan, or jj change.
    try std.testing.expect(std.mem.indexOf(u8, text, "review guide") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--test-plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jj change") == null);
    const here = try planPrompt(a, t, &.{}, .checkout);
    try std.testing.expect(std.mem.indexOf(u8, here, "another ticket's unfinished work") != null);
}

test "planning takes no queue turn or worktree slot, and holds back its sub-tickets" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Planned", .plan = true });
    const kw = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Planned in a worktree", .plan = true, .mode = .worktree });
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Next", .stage = .queued });
    const ks = try board.createTicket(ctx, db, a, .{ .title = "Piece", .stage = .queued, .parent = kp });
    const mk = struct {
        fn s(tmux_name: []const u8, name: []const u8, created: i64) tmux.Session {
            return .{ .tmux_name = tmux_name, .name = name, .dir = "/x/qa-tool", .profile = "", .created = created, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" };
        }
    }.s;
    var sessions = [_]tmux.Session{ mk("cl_qa-tool_1", "qa-tool", 1), mk("cl_qa-1-plan_2", "qa-1-plan", 2), mk("cl_qa-2-plan_3", "qa-2-plan", 3) };
    const view: View = .{ .sessions = &sessions, .statuses = .empty };
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-1-plan_2' WHERE key = ?1", .{kp});
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-2-plan_3' WHERE key = ?1", .{kw});
    const tp = try board.getTicket(db, a, kp);
    try std.testing.expectEqual(board.Stage.planning, tp.stage);
    try std.testing.expect(try isPlanSession(a, tp));
    try std.testing.expect(!try isPlanSession(a, try board.getTicket(db, a, kq)));

    // The queue goes on, and the worktree slots are all free.
    const tq = try board.getTicket(db, a, kq);
    try std.testing.expect(!try projectBusy(db, a, view, tq));
    try std.testing.expect(!try targetHasTicket(db, "cl_qa-1-plan_2", tq.id));
    try std.testing.expectEqual(@as(i64, 0), try runningWorktrees(db, a, view, "qa"));
    try std.testing.expectEqual(@as(i64, 2), try runningPlanners(db, a, view, "qa"));

    // A sub-ticket doesn't go into the planning conversation: it waits for the plan.
    const ts = try board.getTicket(db, a, ks);
    try std.testing.expect(try parentSession(db, a, ts, view) == null);
    try std.testing.expect(try parentPlanning(db, a, ts));
    try db.exec("UPDATE tickets SET stage = 'queued' WHERE key = ?1", .{kp});
    try std.testing.expect(!try parentPlanning(db, a, ts));
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

test "sub-tickets of a finished parent wait their turn" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const p = try board.getProject(db, a, "qa");
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Parent", .stage = .running });
    const k1 = try board.createTicket(ctx, db, a, .{ .title = "Sub one", .stage = .queued, .parent = kp });
    const k2 = try board.createTicket(ctx, db, a, .{ .title = "Sub two", .stage = .queued, .parent = kp });
    const k3 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Top", .stage = .queued });
    const mk = struct {
        fn s(tmux_name: []const u8, name: []const u8, created: i64) tmux.Session {
            return .{ .tmux_name = tmux_name, .name = name, .dir = "/x/qa-tool", .profile = "", .created = created, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" };
        }
    }.s;
    var sessions = [_]tmux.Session{ mk("cl_qa-tool_1", "qa-tool", 1), mk("cl_qa-2_2", "qa-2", 2) };
    const view: View = .{ .sessions = &sessions, .statuses = .empty };

    // The parent is running in its live session: a sub-ticket goes on there,
    // and its being busy is no reason for the sub-ticket to wait.
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-2_2' WHERE key = ?1", .{kp});
    const t1 = try board.getTicket(db, a, k1);
    try std.testing.expectEqualStrings("cl_qa-2_2", (try parentSession(db, a, t1, view)).?);
    try std.testing.expectEqualStrings("cl_qa-2_2", try queueTarget(db, a, t1, view, p));
    try std.testing.expect(try projectBusy(db, a, view, t1));

    // Its session gone, the parent has no conversation to go on in.
    try db.exec("UPDATE tickets SET tmux = 'cl_gone_9' WHERE key = ?1", .{kp});
    try std.testing.expect(try parentSession(db, a, t1, view) == null);

    // The parent is done: the sub-tickets go to the project's session, one
    // at a time, and hold back top-level tickets too.
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-2_2', stage = 'done' WHERE key = ?1", .{kp});
    try std.testing.expect(try parentSession(db, a, t1, view) == null);
    try std.testing.expectEqualStrings("cl_qa-tool_1", try queueTarget(db, a, t1, view, p));
    try std.testing.expect(!try projectBusy(db, a, view, t1));
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-tool_1', stage = 'running' WHERE key = ?1", .{k1});
    try std.testing.expect(try projectBusy(db, a, view, try board.getTicket(db, a, k2)));
    try std.testing.expect(try projectBusy(db, a, view, try board.getTicket(db, a, k3)));
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

test "a parked ticket isn't started, even moved to Queued" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Parked", .stage = .running });
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Queued", .stage = .queued });
    _ = try park.park(ctx, db, a, kp, .{ .reason = "PR #30", .until = "false" });
    // Moved to Queued it's no longer killed, but still parked: not started.
    try board.move(ctx, db, a, kp, .queued);
    try std.testing.expect(!(try board.getTicket(db, a, kp)).killed);
    const w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(kq, w[0].key);
    // Unparked (without resuming), it waits its turn like the others.
    _ = try board.takePark(ctx, db, a, (try board.getTicket(db, a, kp)).id, null);
    try std.testing.expectEqual(@as(usize, 2), (try waitingToStart(db, a)).len);
}

test "a running ticket moved back to Queued is stopped, then started again where it left off" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const sid = "0b9e2c1a-6a51-4c1e-9d0e-2f6a8d3c4b5e";
    const kr = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Jumped ahead", .stage = .running });
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Next", .stage = .queued });
    const ko = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Other", .stage = .done });
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-tool_1', session_id = ?2 WHERE key = ?1", .{ kr, sid });
    try board.setChange(db, (try board.getTicket(db, a, kr)).id, "morxntynnxtk", "qa-1-jumped-ahead");
    try board.setFlagId(ctx, db, (try board.getTicket(db, a, kr)).id, board.flag_question, "auto", "which one?");
    // Its session holds a done ticket too: that one isn't cut off by a kill.
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-tool_1' WHERE key = ?1", .{ko});

    // While it runs there, that session is the one to end; with none live,
    // there is nothing to end and it just moves.
    const t = try board.getTicket(db, a, kr);
    try std.testing.expectEqualStrings("cl_qa-tool_1", (try actions.sessionToStop(db, t, true)).?);
    try std.testing.expect(try actions.sessionToStop(db, t, false) == null);
    // Another ticket in progress in the same (shared) session: refused.
    try db.exec("UPDATE tickets SET stage = 'running' WHERE key = ?1", .{ko});
    try std.testing.expectError(error.SharedSession, actions.sessionToStop(db, t, true));
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{ko});
    // Not in progress, a session it still names isn't its own any more.
    try std.testing.expect(try actions.sessionToStop(db, try board.getTicket(db, a, kq), true) == null);
    var starting = t;
    starting.tmux = "(starting)";
    try std.testing.expectError(error.Starting, actions.sessionToStop(db, starting, true));

    // Stopped and queued: no session, not killed, its question gone with
    // the session, and its conversation and change kept for the restart.
    try actions.letGo(ctx, db, a, t, "cl_qa-tool_1", .queued);
    const q = try board.getTicket(db, a, kr);
    try std.testing.expectEqual(board.Stage.queued, q.stage);
    try std.testing.expectEqualStrings("", q.tmux);
    try std.testing.expect(!q.killed);
    try std.testing.expectEqual(@as(usize, 0), q.flags.len);
    try std.testing.expectEqualStrings(sid, q.session_id);
    try std.testing.expectEqualStrings("morxntynnxtk", q.change);
    // Nothing holds the project's slot now: the dispatcher starts it again,
    // first in board order, and with its conversation id it resumes.
    const none: View = .{ .sessions = &.{}, .statuses = .empty };
    try std.testing.expect(!try projectBusy(db, a, none, q));
    const w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqualStrings(kr, w[0].key);
    try std.testing.expectEqualStrings(kq, w[1].key);

    // Shelved in Backlog it stops the same way, and waits for you: queued
    // again, the dispatcher takes it.
    try db.exec("UPDATE tickets SET stage = 'running', tmux = 'cl_qa-tool_1' WHERE key = ?1", .{kr});
    try actions.letGo(ctx, db, a, try board.getTicket(db, a, kr), "cl_qa-tool_1", .backlog);
    const b = try board.getTicket(db, a, kr);
    try std.testing.expectEqual(board.Stage.backlog, b.stage);
    try std.testing.expectEqualStrings("", b.tmux);
    try board.move(ctx, db, a, kr, .queued);
    try std.testing.expectEqual(@as(usize, 2), (try waitingToStart(db, a)).len);
}

test "a ticket switched to a worktree starts now when queued or beyond" {
    var t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "", .stage = .queued,
        .mode = .worktree, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0,
    };
    try std.testing.expectEqual(.start, switchedStart(t, false, 0, 3));
    // All the project's slots taken: it waits in Queued for one.
    try std.testing.expectEqual(.wait, switchedStart(t, false, 3, 3));
    // Already starting or under way: nothing to start.
    try std.testing.expectEqual(.stay, switchedStart(t, true, 0, 3));
    // Its session gone in Running, Review or Testing: it starts again there.
    for ([_]board.Stage{ .running, .review, .testing }) |st| {
        t.stage = st;
        try std.testing.expectEqual(.start, switchedStart(t, false, 1, 3));
    }
    // Backlog and Planning only change mode.
    for ([_]board.Stage{ .backlog, .planning, .done }) |st| {
        t.stage = st;
        try std.testing.expectEqual(.stay, switchedStart(t, false, 0, 3));
    }
    // A killed or parked one waits for you.
    t.stage = .queued;
    t.killed = true;
    try std.testing.expectEqual(.stay, switchedStart(t, false, 0, 3));
}
