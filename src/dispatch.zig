//! Starting tickets. A worktree ticket gets its own worktree and session; a
//! queue ticket is typed into its target session (its own, its parent's, or
//! a new one in the project's directory) when that session is idle and has
//! no other ticket in progress. The dispatcher (`cl t dispatch`, and a thread
//! in `cl web`) starts queued tickets as slots and sessions free up, except
//! in a paused project (`cl project pause`), where it starts nothing new.
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
const autoreview = @import("autoreview.zig");
const park = @import("park.zig");
const reminders = @import("reminders.zig");
const drift = @import("drift.zig");
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

/// Why the last start on this thread failed with SessionFailed (tmux's own
/// words, or what cl was waiting for), for the start-failed flag and the CLI.
threadlocal var why_buf: [512]u8 = undefined;
threadlocal var why_len: usize = 0;

/// Record why the session didn't start (from `err`, what tmux or launch
/// failed with) and return SessionFailed.
fn sessionFailed(err: anyerror, dir: []const u8) error{SessionFailed} {
    const text = switch (err) {
        error.TmuxFailed => std.fmt.bufPrint(&why_buf, "tmux: {s}", .{tmux.lastError()}),
        error.NoSuchDir => std.fmt.bufPrint(&why_buf, "no such directory: {s}", .{dir}),
        error.PromptTimeout => std.fmt.bufPrint(&why_buf, "Claude's prompt didn't show within 60 seconds", .{}),
        else => std.fmt.bufPrint(&why_buf, "{s}", .{@errorName(err)}),
    } catch &why_buf;
    why_len = text.len;
    return error.SessionFailed;
}

/// Why a start failed with `err`, in a few words: what tmux said, for a
/// session that didn't start; jj's or git's error, for a worktree.
pub fn failureReason(err: anyerror) []const u8 {
    if (err == error.SessionFailed and why_len > 0) return why_buf[0..why_len];
    if (err == error.WorktreeFailed and worktree.lastError().len > 0) return worktree.lastError();
    if (err == error.NoRepo) return "its project isn't a code repo, so it can't have a worktree; move it to the queue (cl ticket relocate <key> queue)";
    return @errorName(err);
}

/// What the ticket's session is told first. The key is spelled out, so the
/// instructions work in sessions cl didn't start (no CL_TICKET). `gutter_rev`:
/// gutter is installed, so Claude writes a review guide for it and checks it
/// against this revision (gutter's -r, "" for its default). A ticket of a
/// project that isn't a code repo gets neither, nor anything about merging
/// or a target branch (`Project.repo`), whatever the caller passes.
pub fn prompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment, gutter_rev_in: ?[]const u8) ![]const u8 {
    return promptFor(a, t, null, notes, gutter_rev_in);
}

/// `prompt` for a ticket whose parent is `todo` (null when its parent isn't
/// a todo): the todo's title, body and link come first, as what the task is
/// for, and in a project that isn't a code repo, where its result goes.
pub fn promptFor(a: std.mem.Allocator, t: board.Ticket, todo: ?board.Ticket, notes: []const board.Comment, gutter_rev_in: ?[]const u8) ![]const u8 {
    const gutter_rev = if (t.repo) gutter_rev_in else null;
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("Ticket {s}: {s}\n", .{ t.key, t.title });
    if (t.parent.len > 0) try w.print("(a sub-ticket of {s}; `cl ticket show {s}` has the bigger picture)\n", .{ t.parent, t.parent });
    if (todo) |td| {
        try w.print("It is for {s}, a todo of mine (something I do myself; you help with this part): {s}\n", .{ td.key, td.title });
        if (td.body.len > 0) try w.print("{s}\n", .{std.mem.trimEnd(u8, td.body, "\n")});
        if (td.link.len > 0) try w.print("Source: {s} (read it with your connectors: Slack, Gmail, Calendar, Drive, GitHub)\n", .{td.link});
    }
    if (t.link.len > 0 and (todo == null or !std.mem.eql(u8, t.link, todo.?.link))) try w.print("Source: {s} (read it with your connectors)\n", .{t.link});
    if (!t.repo and todo != null) try w.writeAll("There is no code here to commit: the result is your summary or a comment on the ticket, or a draft left where I will see it.\n");
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
        \\- Keep the board's Overview current, a short line each, when you start and as each step
        \\  finishes: `cl ticket overview {s} --last "In progress: <what you're on>" --next "<what comes after>"`.
        \\  It's what I read to know where things stand, so say it plainly ("In progress: the review changes").
        \\- When the work is finished and you need nothing more from me:
        \\{s}  {d}. {s}Run `cl ticket done {s} --last "<one line>" --summary "<what changed, in a sentence or two>"`.
        \\     --last is the board's one-line Overview: what you did this round and where that leaves me,
        \\     like "Wrote the first version of the Overview tab; ready to test", "Fixed what failed in
        \\     testing; ready to test again" or "Made the review changes; ready for review again".
        \\  {d}. If there is something to try, add `--test-plan -` with the handoff on stdin (a heredoc,
        \\     not a file), in up to three sections (`cl ticket testplan --format` shows the format):
        \\     - `# Verified`: check everything you can yourself before you finish, and list what you
        \\       checked and what you saw: builds and tests, commands and their output, scripts, API
        \\       calls, pages in a headless browser. Don't hand me a step you could run and read yourself.
        \\     - `# Test plan`: only what needs me: what you can't do (a real browser or phone, voice,
        \\       my accounts, how it looks or feels) and anything where you want my judgment. Steps the
        \\       board walks me through, with `run:`/`open:` buttons and checks ("- [ ] what I should
        \\       see"). Keep the step that starts what I'd try it on; with nothing specific to check,
        \\       give just that step, and the board adds "Works as expected".
        \\     - `# Demo` (optional): when the change is something I'd want to see (a new feature, new
        \\       UI, a new command), a short guided tour with `run:`/`open:` buttons and what to look
        \\       at. No checks.
        \\     I test first and review after; without a handoff the ticket skips testing.
        \\{s}  Don't run it while you still need anything from me. When I send feedback, finish the same way.
        \\
    , .{
        t.key,
        t.key,
        if (gutter_rev) |rev| try guideStep(a, rev) else "",
        @as(u8, if (gutter_rev != null) 2 else 1),
        if (t.change.len == 0 and t.mode == .worktree) "Commit your work on this branch (the review shows commits and new files that way). " else "",
        t.key,
        @as(u8, if (gutter_rev != null) 3 else 2),
        // Not a code repo: nothing gets merged or made a PR (`Project.repo`).
        if (t.repo)
            \\  If its work shouldn't be merged (or made a PR) as it is, say so first with
            \\  `cl ticket custom-close "<what to do with it instead>"`; the board then offers only that.
            \\  If something will be left to do once its PR merges (a deploy, a backfill), suggest it with
            \\  `cl ticket custom-close --then "<steps>"`: finished with a PR, a follow-up ticket does it.
            \\
        else
            "",
    });
    if (t.change.len > 0) try w.print(
        \\- This is a jj repo, and your work goes into the ticket's jj change {s}{s}{s} by itself:
        \\  don't commit (git or jj), start other changes or switch branches. When it's done, cl merges it.
        \\
    , .{ t.change[0..@min(t.change.len, 12)], if (t.branch.len > 0) ", bookmark " else "", t.branch });
    if (t.repo and t.onto.len > 0) try w.print(
        \\- This ticket targets the branch {s}, not trunk: {s}. Don't merge it into trunk
        \\  (master/main) or base it there; when {s} goes into trunk is my decision, not this ticket's.
        \\
    , .{ t.onto, if (t.change.len > 0)
        try std.fmt.allocPrint(a, "its change is on top of {s}, and cl merges it into {s}", .{ t.onto, t.onto })
    else if (t.mode == .worktree)
        try std.fmt.allocPrint(a, "its branch starts from {s} and merges into it", .{t.onto})
    else
        try std.fmt.allocPrint(a, "do the work on top of {s} (check it out if the checkout isn't on it) and it merges into {s}", .{ t.onto, t.onto }), t.onto });
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
    /// The project's directory, which isn't a code repo (`Project.repo`).
    folder,
};

/// The command that sets a ticket's Overview (`cl ticket overview`), as sessions are told it.
fn overviewCmd(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "`cl ticket overview {s} --last \"In progress: <what you're on>\" --next \"<what comes after>\"`", .{key});
}

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
    try w.writeAll(if (t.umbrella)
        "\nThis is a planning session for an umbrella: the plan's output is its sub-tickets, and once I approve it they run, not it (no session builds this ticket itself). Don't write or change code or any other file, and don't commit.\n"
    else
        "\nThis is a planning session: plan the ticket, don't build it. Don't write or change code or any other file, and don't commit; once I approve the plan, a new session builds it.\n");
    switch (where) {
        .trunk => |rev| try w.print("You're in a read-only copy of the project at {s}, for reading the code; it goes away when planning ends.\n", .{rev}),
        .checkout => try w.writeAll("You're in the project's checkout, which may hold another ticket's unfinished work: read it as the code to plan against, but its files may not be what is merged.\n"),
        .folder => try w.writeAll("You're in the project's folder (it isn't a code repo); read what's there as you need.\n"),
    }
    try w.print("\nKeep the board's Overview current as the plan takes shape, a short sentence each: {s}.\n", .{try overviewCmd(a, t.key)});
    try w.writeAll("\nAsk me with AskUserQuestion until the plan is clear");
    if (t.skill.len > 0) try w.print(" (use the {s} skill for the interview)", .{t.skill});
    if (t.umbrella) {
        try w.print(
            \\. Then, before handing the plan in, file the sub-tickets, in the order they should run:
            \\`cl ticket new --parent {s} "<title>" -m "<details>"`. Each one's session sees only its own
            \\body, not this conversation: write it for a reader who starts cold, with what to do, why,
            \\where to look and what done looks like. Each waits for the one before it to be done; add
            \\`--parallel` to one that needn't, and `--after <key,...>` when it waits on others. They stay
            \\in Backlog until I approve; if I send feedback, change them with `cl ticket edit`, `cl ticket
            \\rank` and `cl ticket rm` and hand the plan in again.
            \\
            \\Then hand in the plan with
            \\`cl ticket done {s} --last "<one line, like 'Plan ready for approval'>" --summary "<the plan in a sentence>" --plan` and the plan as markdown on
            \\stdin (a heredoc, not a file): the sub-tickets by key, in order, what each is for, and what
            \\we decided and why. The board shows it to me for approval; approving queues the sub-tickets
            \\and this ticket follows them (running when one starts, done when all are). That is the end of
            \\your part. Don't call ExitPlanMode.
            \\
        , .{ t.key, t.key });
        return aw.written();
    }
    try w.print(
        \\. The session that builds it won't see
        \\this conversation, only the plan: write it for a reader who starts cold, with every decision
        \\we made and why, the files and functions to change, what to test, and what is still open.
        \\
        \\When the plan is ready, hand it in with
        \\`cl ticket done {s} --last "<one line, like 'Plan ready for approval' or 'Revised the plan
        \\after your feedback; ready to approve again'>" --summary "<the plan in a sentence>" --plan` and the plan as markdown on
        \\stdin (a heredoc, not a file). The board shows it to me for approval; that is the end of your
        \\part. Don't call ExitPlanMode. If I send feedback on the plan, revise it and hand it in the
        \\same way. To split off a separate piece of work: `cl ticket new --parent {s} "<title>" -m "<details>"`
        \\(it waits until the plan is approved).
        \\
        \\If the plan turns out to be only a set of separate tickets, with no work of its own here (a
        \\roadmap, a brainstorm whose ideas become tickets), ask me; if I agree, file them that way
        \\(in the order they should run; `--parallel` for one that needn't wait for the one before it,
        \\`--after <key,...>` to wait on others), make this ticket their umbrella with
        \\`cl ticket edit {s} --umbrella`, and hand in the plan listing them. Approving it then queues
        \\them instead of starting a session for this ticket.
        \\
    , .{ t.key, t.key, t.key });
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
    try w.print("\nPick it up where you left off, and finish the same way as before (`cl ticket done {s}`{s}).\n", .{ t.key, if (t.todo) "" else ", with --last \"<one line: what you did and where that leaves me>\"" });
    // A conversation from before the Overview doesn't know the command.
    if (!t.todo) try w.print("Keep the board's Overview current as you go, a short sentence each: {s}.\n", .{try overviewCmd(a, t.key)});
    return aw.written();
}

/// Write the hooks settings file (in the board's directory) and return its path.
fn hooksFile(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try ctx.exePath(&exe_buf);
    const dir = try board.dirPath(ctx, a, cfg);
    const path = try std.fmt.allocPrint(a, "{s}/claude-hooks.json", .{dir});
    const stop = try std.fmt.allocPrint(a, "'{s}' ticket hook stop", .{exe});
    const notify = try std.fmt.allocPrint(a, "'{s}' ticket hook notify", .{exe});
    // Some Claude Code versions write an AskUserQuestion call to the
    // transcript only once it is answered; this keeps it while it is asked.
    const ask = try std.fmt.allocPrint(a, "'{s}' ticket hook ask", .{exe});
    const json = try std.fmt.allocPrint(a,
        \\{{"hooks":{{"Stop":[{{"hooks":[{{"type":"command","command":{f}}}]}}],"Notification":[{{"hooks":[{{"type":"command","command":{f}}}]}}],"PreToolUse":[{{"matcher":"AskUserQuestion","hooks":[{{"type":"command","command":{f}}}]}}]}}}}
        \\
    , .{ std.json.fmt(stop, .{}), std.json.fmt(notify, .{}), std.json.fmt(ask, .{}) });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = json });
    return path;
}

test "the hooks file runs cl on a turn's end, notifications and AskUserQuestion" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "", .board = .{ .dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a) } };
    const path = try hooksFile(ctx, a, cfg);
    const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 16));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const pre = v.object.get("hooks").?.object.get("PreToolUse").?.array.items[0].object;
    try std.testing.expectEqualStrings("AskUserQuestion", pre.get("matcher").?.string);
    try std.testing.expect(std.mem.endsWith(u8, pre.get("hooks").?.array.items[0].object.get("command").?.string, "' ticket hook ask"));
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
    tmux.respawn(ctx, s.tmux_name, s.dir, try ticketEnv(a, t), cmd.items, text) catch |e| return sessionFailed(e, s.dir);
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
    }) catch |e| sessionFailed(e, dir);
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
pub const View = struct {
    sessions: []tmux.Session,
    statuses: claude.StatusMap,

    pub fn read(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) !View {
        return .{ .sessions = try tmux.list(ctx, a), .statuses = try claude.readStatuses(ctx, a, cfg) };
    }

    fn find(self: View, tmux_name: []const u8) ?tmux.Session {
        for (self.sessions) |s| if (std.mem.eql(u8, s.tmux_name, tmux_name)) return s;
        return null;
    }

    fn alive(self: View, tmux_name: []const u8) bool {
        return self.find(tmux_name) != null;
    }

    pub fn idle(self: View, ctx: Ctx, tmux_name: []const u8) bool {
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
    return if (homeSession(view, p, try todoSessions(db, a))) |s| s.tmux_name else "";
}

/// The sessions todos talk in (see `startTodo`): they run in the project's
/// directory but are never its session, so no ticket is typed into one.
fn todoSessions(db: board.Db, a: std.mem.Allocator) ![]const []const u8 {
    var st = try db.query("SELECT tmux FROM tickets WHERE todo != 0 AND tmux != '' AND stage != 'done'", .{});
    defer st.finalize();
    var out: std.ArrayList([]const u8) = .empty;
    while (try st.step()) try out.append(a, try st.dupe(a, 0));
    return out.items;
}

/// The live session of `t`'s parent while the parent is in progress: a
/// sub-ticket goes on in that conversation. With the parent finished or its
/// session gone, the sub-ticket waits its turn like a top-level ticket. A
/// parent still planning has only its planning session: see `parentPlanning`.
fn parentSession(db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View) !?[]const u8 {
    if (t.parent.len == 0) return null;
    const parent = board.getTicket(db, a, t.parent) catch |err| return if (err == error.NotFound) null else err;
    // A todo's tasks go on their own, never in a session it has.
    if (parent.todo) return null;
    if (parent.tmux.len == 0 or parent.tmux[0] == '(' or !view.alive(parent.tmux)) return null;
    return switch (parent.stage) {
        .running, .review, .testing => parent.tmux,
        else => null,
    };
}

/// `t`'s parent when that is a todo (what `promptFor` tells it about).
fn todoParent(db: board.Db, a: std.mem.Allocator, t: board.Ticket) !?board.Ticket {
    if (t.parent.len == 0) return null;
    const parent = board.getTicket(db, a, t.parent) catch |err| return if (err == error.NotFound) null else err;
    return if (parent.todo) parent else null;
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
    var dir = p.dir;
    var where: PlanDir = .folder;
    // Not a code repo: it plans in the project's directory.
    if (p.repo) {
        _ = worktree.ensureJj(ctx, a, p.dir);
        // On its target: the code it will be built on.
        const trunk = worktree.target(ctx, a, p.dir, t.onto) orelse if (t.onto.len > 0) t.onto else null;
        const path = try worktree.planPath(ctx, a, cfg, p.name, t.key);
        dir = path;
        where = .{ .trunk = trunk orelse "HEAD" };
        worktree.createPlan(ctx, a, p.dir, path, trunk) catch |err| {
            if (err == error.OutOfMemory) return err;
            try board.logEvent(ctx, db, t.id, "no planning workspace", worktree.lastError());
            dir = p.dir;
            where = .checkout;
        };
    }
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
/// preferably the one named after it, else the oldest. Not one of `skip`
/// (a todo's: `todoSessions`).
fn homeSession(view: View, p: board.Project, skip: []const []const u8) ?tmux.Session {
    var best: ?tmux.Session = null;
    sessions: for (view.sessions) |s| {
        if (!std.mem.eql(u8, s.dir, p.dir)) continue;
        for (skip) |k| if (std.mem.eql(u8, k, s.tmux_name)) continue :sessions;
        if (std.mem.eql(u8, s.name, p.name) or std.mem.eql(u8, s.name, std.fs.path.basename(p.dir))) return s;
        if (best == null or s.created < best.?.created) best = s;
    }
    return best;
}

/// Another queue ticket of the project is in progress with a session: one
/// Claude works on a queue project at a time. A todo's talk session isn't
/// the project's work (`startTodo`).
fn projectBusy(db: board.Db, a: std.mem.Allocator, view: View, t: board.Ticket) !bool {
    var st = try db.query("SELECT tmux FROM tickets WHERE project = ?1 AND id != ?2 AND mode = 'queue' AND todo = 0 AND tmux != '' AND stage IN " ++ in_progress, .{ t.project, t.id });
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
    // Nothing to make a worktree of (`Project.repo`).
    if (to == .worktree and !t.repo) return error.NoRepo;
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
    const trunk = worktree.target(ctx, a, p.dir, t.onto);
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
    autoreview.stop(ctx, db, a, t.key) catch {};
    review.stopLaunch(ctx, a, t.key, .test_plan, null) catch {};
    const short = t.change[0..@min(t.change.len, 12)];
    var note: []const u8 = undefined;
    switch (to) {
        .worktree => {
            // Its own conversation open in the queue session: that session
            // gets a new one, and this one goes on in the worktree.
            if (live) if (view.statuses.get(t.tmux)) |info| if (std.mem.eql(u8, info.session_id, t.session_id)) {
                const s = view.find(t.tmux).?;
                tmux.respawn(ctx, s.tmux_name, s.dir, &.{}, &.{"claude"}, null) catch |e| return sessionFailed(e, s.dir);
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
    if (t.umbrella) return error.Umbrella;
    // Yours: the dispatcher never starts it (`board.hold`); started by
    // hand, it gets a session to talk about it in.
    if (t.todo) return startTodo(ctx, cfg, db, a, t);
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
    if (!p.repo and t.mode == .worktree) return error.NoRepo;
    if (!try board.claimStart(db, t.id)) return error.AlreadyStarted;
    errdefer board.releaseStart(db, t.id) catch {};
    // A project that isn't a code repo (`Project.repo`) gets none of what
    // follows: no jj, base, change or worktree.
    // Projects added before jj was set up on add get it on their first start.
    if (p.repo and worktree.ensureJj(ctx, a, p.dir)) try board.logEvent(ctx, db, t.id, "jj init", p.dir);
    // What gutter will diff against: the repo as it is now.
    const base = if (p.repo) worktree.baseRev(ctx, a, p.dir, t.onto) else "";
    try board.setBase(db, t.id, base);
    // jj: the ticket's own change, on top of trunk (or its target branch). A
    // queue ticket takes the project's checkout over only when it gets the
    // session to itself.
    const trunk = if (p.repo) worktree.target(ctx, a, p.dir, t.onto) else null;
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
                // git: the branch starts from its target, else the checkout's HEAD.
                worktree.create(ctx, a, cfg, p.dir, p.name, t.key, t.title, trunk orelse t.onto, desc)) catch |err| {
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
    const body = if (resume_id != null) try resumePrompt(a, tc, notes) else try promptFor(a, tc, try todoParent(db, a, t), notes, if (p.repo and review.findGutter(ctx, a, cfg) != null)
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
            tmux.sendLine(ctx, target, text) catch |e| return sessionFailed(e, p.dir);
            try board.setSession(ctx, db, t.id, target, resume_id.?, "", "");
        } else if (live and resume_id == null and (in_parent or !free)) {
            // A sub-ticket goes on in its parent's conversation, and a forced
            // start into a busy session is typed (Claude queues it).
            tmux.sendLine(ctx, target, text) catch |e| return sessionFailed(e, p.dir);
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

/// Talk to Claude about a todo: a session of its own in the project's
/// directory, told it is the human's todo (`todoPrompt`), or picking its
/// earlier conversation back up. Never the project's queue session or a
/// parent's, and nothing else of a start: no jj, change, base or worktree,
/// so the project's checkout is left alone, and the todo stays in its stage.
fn startTodo(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !void {
    // Done, nothing would follow its session or keep the queue out of it.
    if (t.stage == .done) return error.TodoDone;
    const p = try board.getProject(db, a, t.project);
    if (!try board.claimStart(db, t.id)) return error.AlreadyStarted;
    errdefer board.releaseStart(db, t.id) catch {};
    const resume_id = resumeId(ctx, cfg, a, t, p.dir, t.profile);
    const notes = try board.unsentNotes(db, a, t.id);
    const text = if (resume_id != null) try todoResumePrompt(a, t, notes) else try todoPrompt(a, t, notes);
    var sid: [36]u8 = undefined;
    const name = try newSession(ctx, cfg, a, t, p.dir, try std.ascii.allocLowerString(a, t.key), text, &sid, resume_id);
    // Not `board.setSession`: talking about it doesn't end its wait (a park).
    try db.exec("UPDATE tickets SET tmux = ?2, session_id = ?3, killed = 0 WHERE id = ?1", .{ t.id, name, @as([]const u8, &sid) });
    try board.markNotesSent(db, t.id);
    try board.clearFlagId(ctx, db, t.id, "start-failed");
    try board.clearFlagId(ctx, db, t.id, "ended");
    try board.logEvent(ctx, db, t.id, "talk started", name);
}

/// The first message of a todo's talk session (`startTodo`): it is the
/// human's own todo, not a task to finish, with what to do and not do.
pub fn todoPrompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("Todo {s}: {s}\n", .{ t.key, t.title });
    try w.writeAll("This is a todo of mine: something I do myself, not a task for you to finish. I opened this session to talk about it with you.\n");
    if (t.body.len > 0) try w.print("\n{s}\n", .{std.mem.trimEnd(u8, t.body, "\n")});
    try images.writeNote(w, a, t.body);
    if (t.link.len > 0) try w.print("\nWhere it came from: {s}\nRead it with your connectors (Slack, Gmail, Calendar, Drive, GitHub) when it helps.\n", .{t.link});
    if (notes.len > 0) {
        try w.writeAll("\nNotes on it:\n");
        for (notes) |n| try w.print("- {s}\n", .{n.body});
    }
    try w.print(
        \\
        \\Help with whatever I ask about it: look things up, draft a reply, think it through with me.
        \\- This folder is the project's own checkout, where other tickets' work may be under way: don't edit files or run jj or git here. A change to code or files is a Claude task under this todo (below).
        \\- For a piece of work that should be a ticket of its own (when I ask for one), create it under this todo: `cl ticket new --parent {s} "<title>" -m "<details>"`. It doesn't start by itself; I start it from the board.
        \\- Don't run `cl ticket done` on it: it is mine, not a ticket you finish.
        \\- When I say it is finished, run `cl ticket move {s} done`. When I say it waits on someone or something, run `cl ticket park {s} --reason "<what it waits on>"`.
        \\
        \\Start by reading what it links to, if anything, and tell me in a few lines what it's about; then wait for me.
        \\
    , .{ t.key, t.key, t.key });
    return aw.written();
}

/// A todo's talk session resumed: its conversation already has the todo.
fn todoResumePrompt(a: std.mem.Allocator, t: board.Ticket, notes: []const board.Comment) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("I'm back to talk about todo {s}: {s}\n", .{ t.key, t.title });
    if (notes.len > 0) {
        try w.writeAll("\nNotes on it since:\n");
        for (notes) |n| try w.print("- {s}\n", .{n.body});
    }
    try w.writeAll("\nPick up where we left off, and wait for me.\n");
    return aw.written();
}

pub const AttachError = error{
    /// No cl session by that name.
    NoSuchSession,
    /// Its pane is dead: there's no Claude there to attach.
    PaneDead,
    /// The session runs outside the ticket's project.
    OtherProject,
    Finished,
    Planning,
    Umbrella,
    /// A todo is the human's: no session works on it.
    Todo,
    /// The dispatcher (or a start) is starting it right now.
    Starting,
    /// It has a live session of its own already, another one.
    AlreadyStarted,
    /// Another unfinished ticket's session (`attachOwner` says which).
    SessionTaken,
};

pub const Attached = struct {
    /// The session's tmux name.
    session: []const u8,
    /// Claude was restarted there, resuming its conversation (or a new one),
    /// with the ticket's hooks and CL_TICKET, and told about the ticket.
    restarted: bool,
    /// It resumed the conversation it had there (else, having none yet, a new one).
    resumed: bool = false,
    /// It was the ticket's session already, with its hooks, and Claude had
    /// been told the ticket in this conversation: nothing to restart.
    told: bool = false,
    /// What Claude was doing there when it wasn't restarted.
    status: claude.Status,
    /// It was the ticket's session already.
    again: bool,
    /// The jj change it took as the ticket's ("" none).
    adopted: []const u8 = "",
};

/// The session `name` (cl name or tmux name) in `view`.
fn findSession(view: View, name: []const u8) ?tmux.Session {
    for (view.sessions) |s| if (std.mem.eql(u8, s.name, name) or std.mem.eql(u8, s.tmux_name, name)) return s;
    return null;
}

/// The unfinished ticket other than `id` that session `tmux_name` belongs
/// to, if any: a session is one ticket's at a time.
pub fn attachOwner(db: board.Db, a: std.mem.Allocator, tmux_name: []const u8, id: i64) !?[]const u8 {
    var st = try db.query("SELECT key FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage != 'done' ORDER BY id LIMIT 1", .{ tmux_name, id });
    defer st.finalize();
    return if (try st.step()) try a.dupe(u8, st.text(0)) else null;
}

/// `dir` is `under` or inside it.
fn within(dir: []const u8, under: []const u8) bool {
    if (under.len == 0 or !std.mem.startsWith(u8, dir, under)) return false;
    return dir.len == under.len or dir[under.len] == '/' or under[under.len - 1] == '/';
}

/// A session in `dir` works on project `p`: in its checkout (or below), the
/// ticket's worktree, or one of the project's worktrees (`wt_root`, the
/// board's worktrees folder).
fn inProject(dir: []const u8, p: board.Project, t: board.Ticket, wt_root: []const u8) bool {
    if (within(dir, p.dir) or within(dir, t.worktree)) return true;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pw = std.fmt.bufPrint(&buf, "{s}/{s}", .{ std.mem.trimEnd(u8, wt_root, "/"), p.name }) catch return false;
    return within(dir, pw);
}

/// Whether `t` may take session `s` (in `view`): the refusals of `attach`.
/// `in_project`: the session runs in the ticket's project (`inProject`).
fn attachCheck(db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View, s: tmux.Session, in_project: bool) !void {
    if (t.stage == .done) return error.Finished;
    if (t.stage == .planning) return error.Planning;
    if (t.umbrella) return error.Umbrella;
    if (t.todo) return error.Todo;
    if (s.pane_dead) return error.PaneDead;
    if (!in_project) return error.OtherProject;
    if (t.tmux.len > 0 and t.tmux[0] == '(') return error.Starting;
    if (t.tmux.len > 0 and !std.mem.eql(u8, t.tmux, s.tmux_name) and view.alive(t.tmux)) return error.AlreadyStarted;
    if (try attachOwner(db, a, s.tmux_name, t.id) != null) return error.SessionTaken;
}

/// Take session `tmux_name` for ticket `id`, checking in the same write that
/// no other unfinished ticket has it (two attaches at once can't both win),
/// and that no start has claimed the ticket meanwhile.
fn claimSession(db: board.Db, a: std.mem.Allocator, id: i64, tmux_name: []const u8, old: []const u8) !void {
    try db.exec(
        \\UPDATE tickets SET tmux = ?2 WHERE id = ?1 AND (tmux = ?2 OR tmux = ?3)
        \\  AND NOT EXISTS (SELECT 1 FROM tickets o WHERE o.tmux = ?2 AND o.id != ?1 AND o.stage != 'done')
    , .{ id, tmux_name, old });
    if (db.changes() == 1) return;
    return if (try attachOwner(db, a, tmux_name, id) != null) error.SessionTaken else error.Starting;
}

/// What attach does with Claude in the session.
const AttachPlan = struct {
    /// Restart Claude there with the ticket's hooks (and tell it the ticket).
    restart: bool,
    /// The conversation to resume (null: a new one).
    resume_id: ?[]const u8,
    /// The conversation the ticket records ("" unknown).
    conversation: []const u8,
};

/// Decide what attach does. A restart only when Claude is idle there (a
/// background task counts as busy: the restart would end it), cl knows its
/// conversation, and Claude runs in the session's directory (where the
/// restart runs it and finds transcripts); and not when `told` (it has the
/// hooks and the ticket already). `resumable`: Claude has that
/// conversation's transcript; one with none said nothing yet, so a new
/// conversation loses nothing.
fn attachPlan(status: claude.Status, info: ?claude.Info, dir: []const u8, resumable: bool, told: bool) AttachPlan {
    const i = info orelse return .{ .restart = false, .resume_id = null, .conversation = "" };
    const known = i.session_id.len == 36 and (i.cwd.len == 0 or std.mem.eql(u8, i.cwd, dir));
    return .{
        .restart = status == .idle and known and !told,
        .resume_id = if (known and resumable) i.session_id else null,
        .conversation = i.session_id,
    };
}

/// `t` was already told in session `tmux_name`'s conversation `conversation`,
/// with its hooks: cl started it there, or attach restarted it there, last.
fn toldHere(db: board.Db, a: std.mem.Allocator, t: board.Ticket, tmux_name: []const u8, conversation: []const u8) !bool {
    if (!std.mem.eql(u8, t.tmux, tmux_name) or conversation.len == 0 or !std.mem.eql(u8, t.session_id, conversation)) return false;
    var st = try db.query("SELECT kind, detail FROM events WHERE ticket = ?1 AND kind IN ('started', 'attached') ORDER BY id DESC LIMIT 1", .{t.id});
    defer st.finalize();
    if (!try st.step()) return false;
    const kind = st.text(0);
    const detail = st.text(1);
    if (std.mem.eql(u8, kind, "started")) return std.mem.eql(u8, detail, tmux_name);
    return std.mem.eql(u8, detail, try std.fmt.allocPrint(a, "{s}{s}", .{ tmux_name, restarted_suffix }));
}

const restarted_suffix = " (restarted with its hooks)";

/// Give an attached ticket with no change of its own the one its session
/// works in (jj): the working copy's change, when it is undescribed, not in
/// trunk and no other ticket's (`unclaimedWork`), described and bookmarked
/// as a started ticket's is. Its base (what gutter diffs against) becomes
/// the commit below it. Without one, finishing it can only close it.
/// Returns the change taken, or "".
fn attachChange(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, repo: []const u8) ![]const u8 {
    // Not a code repo: nothing to take (`Project.repo`).
    if (!t.repo) return "";
    var taken: []const u8 = "";
    if (t.change.len == 0) if (worktree.target(ctx, a, repo, t.onto)) |trunk| {
        if (worktree.unclaimedWork(ctx, a, repo, trunk)) |c| {
            if ((try db.int("SELECT 1 FROM tickets WHERE change_id = ?1 AND id != ?2", .{ c, t.id })) == null) {
                const desc = try std.fmt.allocPrint(a, "{s}: {s}", .{ t.key, t.title });
                if (worktree.adoptChange(ctx, a, repo, desc, try worktree.slug(a, t.key, t.title))) |ch| {
                    try board.setChange(db, t.id, ch.id, ch.bookmark);
                    try board.logEvent(ctx, db, t.id, "adopted change", ch.id);
                    taken = ch.id;
                } else |_| try board.logEvent(ctx, db, t.id, "no change", worktree.lastError());
            }
        }
    };
    if (t.base.len == 0) {
        const base = worktree.baseRev(ctx, a, repo, t.onto);
        if (base.len > 0) try board.setBase(db, t.id, base);
    }
    return taken;
}

/// Make a running cl session `name` the ticket's session, as if cl had
/// started it there: the board follows its status, flags and Needs You by
/// it, and `cl ticket kill`, merging and the rest act on it. A ticket with no
/// jj change of its own takes the one the session works in (`attachChange`).
/// An idle Claude is restarted resuming its own conversation (a new one if
/// it had none yet: nothing said, no transcript), with the ticket's hooks
/// and CL_TICKET, and told about the ticket (its description and how to
/// finish), unless it was told already (`toldHere`). A busy one (or one idle
/// with a background task, which a restart would end) is left as it is: the
/// session is recorded, and attaching it again once it is idle adds the
/// rest. A ticket in Backlog or Queued moves to Running; one in Review or
/// Testing stays there. Refused for a session outside the ticket's project
/// or another unfinished ticket's, and for a ticket with a live session of
/// its own (another one), done, being planned, or an umbrella.
pub fn attach(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, name: []const u8) !Attached {
    const view = try View.read(ctx, a, cfg);
    const s = findSession(view, name) orelse return error.NoSuchSession;
    return attachTo(ctx, cfg, db, a, t, view, s);
}

fn attachTo(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket, view: View, s: tmux.Session) !Attached {
    const p = try board.getProject(db, a, t.project);
    try attachCheck(db, a, t, view, s, inProject(s.dir, p, t, try worktree.root(ctx, a, cfg)));
    const again = std.mem.eql(u8, t.tmux, s.tmux_name);
    // Its old session is gone (attachCheck): it lets go of it.
    try claimSession(db, a, t.id, s.tmux_name, t.tmux);
    errdefer if (!again) db.exec("UPDATE tickets SET tmux = ?3 WHERE id = ?1 AND tmux = ?2", .{ t.id, s.tmux_name, t.tmux }) catch {};
    const status = claude.statusFor(ctx, view.statuses, s);
    const info = view.statuses.get(s.tmux_name);
    const conversation = if (info) |i| i.session_id else "";
    const resumable = if (info) |i| conversation.len == 36 and i.config_dir.len > 0 and claude.canResume(ctx, a, i.config_dir, s.dir, conversation) else false;
    const told = try toldHere(db, a, t, s.tmux_name, conversation);
    const plan = attachPlan(status, info, s.dir, resumable, told);
    // jj runs at the repo's root: the project's checkout for a session in
    // it (or below), else its own worktree.
    const adopted = try attachChange(ctx, db, a, t, if (within(s.dir, p.dir)) p.dir else s.dir);
    const tc = try board.getTicket(db, a, t.key);
    var sid: [36]u8 = undefined;
    if (plan.restart) {
        const notes = try board.unsentNotes(db, a, t.id);
        const gutter_rev: ?[]const u8 = if (review.findGutter(ctx, a, cfg) != null)
            try worktree.reviewRev(ctx, a, if (tc.worktree.len > 0) tc.worktree else p.dir, tc.base, tc.change)
        else
            null;
        const text = try std.mem.concat(a, u8, &.{ try attachNote(a, t.key), try promptFor(a, tc, try todoParent(db, a, t), notes, gutter_rev) });
        try freshConversation(ctx, cfg, db, a, t, s, text, &sid, plan.resume_id);
        try board.setSession(ctx, db, t.id, s.tmux_name, &sid, tc.worktree, tc.branch);
        try board.markNotesSent(db, t.id);
    } else {
        try board.setSession(ctx, db, t.id, s.tmux_name, plan.conversation, tc.worktree, tc.branch);
    }
    try board.clearFlagId(ctx, db, t.id, "start-failed");
    try board.clearFlagId(ctx, db, t.id, "ended");
    if (t.stage == .backlog or t.stage == .queued) try board.moveTicket(ctx, db, t, .running);
    try board.logEvent(ctx, db, t.id, "attached", try std.fmt.allocPrint(a, "{s}{s}", .{ s.tmux_name, if (plan.restart) restarted_suffix else "" }));
    return .{
        .session = s.tmux_name,
        .restarted = plan.restart,
        .resumed = plan.restart and plan.resume_id != null,
        .told = told,
        .status = status,
        .again = again,
        .adopted = adopted,
    };
}

/// What an attached session is told before the ticket itself.
fn attachNote(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\cl attached this session to ticket {s}: from now on the board follows this session for it
        \\(its status, questions and Needs You), and this conversation goes on as {s}'s. If you
        \\were already working on it, carry on from where you are.
        \\
        \\
    , .{ key, key });
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

/// A ticket finishing (Claude merging it, opening its PR, ...) whose session
/// went away before it reached Done: it didn't land. It stops finishing (so
/// Merge can be tried again) and is flagged merge-failed.
fn finishingGone(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !void {
    try board.setFinishing(ctx, db, t.id, "");
    try board.setFlagId(ctx, db, t.id, stoppedFlag(t.finishing), "auto", try std.fmt.allocPrint(a, "its session ({s}) ended while Claude was {s}, before it reached Done\nNothing more was merged or opened. Try again (Merge, PR or Tell Claude), or close it.", .{ t.tmux, actions.finishingWhat(t.finishing) }));
}

/// The dispatcher keeps the flags of `t`'s session in step: a ticket in
/// progress in Running or Planning, and a todo's talk session in whatever
/// stage it is (Backlog or Running: `startTodo`).
fn followed(t: board.Ticket) bool {
    return t.stage == .running or t.stage == .planning or (t.todo and t.stage == .backlog);
}

/// `t`'s session went away. A ticket in progress is flagged `ended`; a
/// todo's talk session ending is nothing to flag (the todo is the human's,
/// and Talk to Claude starts another), so it just lets go of it, with what
/// it was waiting on.
fn sessionGone(ctx: Ctx, db: board.Db, t: board.Ticket) !void {
    if (!t.todo) return board.setFlagId(ctx, db, t.id, "ended", "auto", "its session is gone; start it again or resume it");
    try db.exec("UPDATE tickets SET tmux = '' WHERE id = ?1 AND tmux = ?2", .{ t.id, t.tmux });
    for ([_][]const u8{ board.flag_question, board.flag_input, "ended" }) |k| try board.clearFlagId(ctx, db, t.id, k);
    try board.setIdle(ctx, db, t.id, false);
    if (t.asking.len > 0) try board.setAsking(db, t.id, "");
    try board.logEvent(ctx, db, t.id, "talk ended", t.tmux);
}

/// One dispatcher pass: start what can start, and flag tickets whose session
/// went away. Returns how many tickets it started.
pub fn tick(ctx: Ctx, cfg: config.Config, db: board.Db) !usize {
    // Parked tickets' checks (they run detached; a passing one resumes its ticket).
    park.checkDue(ctx, db) catch {};
    // Todos' reminders and due dates (Needs You's Today group).
    reminders.checkDue(ctx, cfg, db) catch {};
    // Nothing queued or in progress, and no session to let go of: nothing to look at.
    if ((try db.int("SELECT 1 FROM tickets WHERE stage IN ('queued', 'planning', 'running') OR (stage = 'backlog' AND tmux != '') OR finishing != '' OR tmux LIKE '%-plan\\_%' ESCAPE '\\' LIMIT 1", .{})) == null) return 0;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const view = try View.read(ctx, a, cfg);

    // In progress: flag a session that is gone, and keep the flags of a
    // live one in step with what it is waiting on. A queue session shared by
    // several tickets speaks for the newest one in progress there.
    var current: std.StringHashMapUnmanaged(board.Ticket) = .empty;
    for (try board.listTickets(db, a, .{ .done = false })) |t| {
        if (t.finishing.len > 0 and t.tmux.len > 0 and t.tmux[0] != '(' and !view.alive(t.tmux)) {
            finishingGone(ctx, db, a, t) catch {};
            continue;
        }
        if (!followed(t)) continue;
        if (t.tmux.len == 0 or t.tmux[0] == '(') continue;
        if (!view.alive(t.tmux)) {
            sessionGone(ctx, db, t) catch {};
            continue;
        }
        const prev = current.get(t.tmux);
        if (prev == null or prev.?.id < t.id) try current.put(a, t.tmux, t);
    }
    var cur_it = current.valueIterator();
    while (cur_it.next()) |t| {
        const s = view.find(t.tmux) orelse continue;
        const status = claude.statusFor(ctx, view.statuses, s);
        signals.sync(ctx, db, a, t.*, view.statuses.get(t.tmux), status) catch {};
        signals.syncIdle(ctx, db, t.*, status, s.hidden) catch {};
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
    for (try planningToStart(db, a)) |t| {
        const p = board.getProject(db, a, t.project) catch continue;
        if (try runningPlanners(db, a, view, p.name) >= p.planners) continue;
        startPlanning(ctx, cfg, db, a, t) catch |err| switch (err) {
            error.AlreadyStarted => continue,
            else => {
                board.setFlagId(ctx, db, t.id, "start-failed", "auto", failureReason(err)) catch {};
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
                board.setFlagId(ctx, db, t.id, "start-failed", "auto", failureReason(err)) catch {};
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
/// (moving it to Queued doesn't start it). A paused project's queued
/// tickets wait, in their place, for it to resume. One that waits on
/// another ticket (board.hold: a link, its parent, or the sub-ticket before
/// it) waits until that one is Done, and an umbrella runs as its
/// sub-tickets, so it doesn't start itself.
pub fn waitingToStart(db: board.Db, a: std.mem.Allocator) ![]board.Ticket {
    const paused = try pausedProjects(db, a);
    var waiting: std.ArrayList(board.Ticket) = .empty;
    for (try board.listTickets(db, a, .{ .stage = .queued })) |t| {
        // An umbrella has no work of its own (its sub-tickets run, not it), and
        // a ticket waiting on others waits: see board.hold.
        if (t.tmux.len == 0 and !t.killed and t.park == null and !paused.contains(t.project) and board.hold(t) == null) try waiting.append(a, t);
    }
    std.mem.sort(board.Ticket, waiting.items, {}, byRank);
    return waiting.items;
}

/// Planning tickets the dispatcher may start, in board order (up to each
/// project's planners): not started, killed or parked, and not in a paused
/// project.
fn planningToStart(db: board.Db, a: std.mem.Allocator) ![]board.Ticket {
    const paused = try pausedProjects(db, a);
    var out: std.ArrayList(board.Ticket) = .empty;
    for (try board.listTickets(db, a, .{ .stage = .planning })) |t| {
        if (t.tmux.len == 0 and !t.killed and t.park == null and !paused.contains(t.project)) try out.append(a, t);
    }
    std.mem.sort(board.Ticket, out.items, {}, byRank);
    return out.items;
}

fn pausedProjects(db: board.Db, a: std.mem.Allocator) !std.StringHashMapUnmanaged(void) {
    var paused: std.StringHashMapUnmanaged(void) = .empty;
    for (try board.listProjects(db, a)) |p| if (p.paused) try paused.put(a, p.name, {});
    return paused;
}

/// Board order: rank, then oldest first.
fn byRank(_: void, x: board.Ticket, y: board.Ticket) bool {
    return x.rank < y.rank or (x.rank == y.rank and x.id < y.id);
}

pub const Interrupted = struct {
    /// Running tickets stopped and put back in Queued: they resume their
    /// conversation when the project resumes.
    queued: []const []const u8,
    /// Planning sessions ended: planning picks up again when it resumes.
    planning: []const []const u8,
    /// Running tickets left running: another ticket in progress shares
    /// their session (a parent's), or theirs is still starting.
    left: []const []const u8,
};

/// "Pause now" (`cl project pause --now`): besides holding new starts,
/// stop what `project` is working on as moving it back to Queued does
/// (CL-70): each Running ticket's session is killed, its conversation and
/// change kept, and it waits in Queued, keeping its rank, to resume. Planning
/// sessions end too; their tickets stay in Planning and are started again
/// (resuming the conversation) on resume. Testing and Review tickets wait
/// on you, not Claude, and are left alone, as is a Running ticket held for
/// its automated review (Claude has finished; `autoreview.holds`).
pub fn interrupt(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, project: []const u8) !Interrupted {
    var queued: std.ArrayList([]const u8) = .empty;
    var planning: std.ArrayList([]const u8) = .empty;
    var left: std.ArrayList([]const u8) = .empty;
    for (try board.listTickets(db, a, .{ .project = project })) |t| {
        if (t.tmux.len == 0) continue;
        switch (t.stage) {
            .running => {
                // Claude has finished; only its automated review runs, and
                // the ticket moves on when that's done (autoreview.startOnDone).
                if (autoreview.holds(a, t)) continue;
                actions.move(ctx, cfg, db, a, t.key, .queued, false, .close) catch |err| switch (err) {
                    error.SharedSession, error.Starting => {
                        try left.append(a, t.key);
                        continue;
                    },
                    else => return err,
                };
                try queued.append(a, t.key);
            },
            .planning => {
                if (t.tmux[0] == '(') {
                    try left.append(a, t.key);
                    continue;
                }
                _ = actions.kill(ctx, cfg, db, a, t.key) catch |err| switch (err) {
                    error.NoSession => continue,
                    else => return err,
                };
                // Not killed for good: the dispatcher plans it again on resume.
                try db.exec("UPDATE tickets SET killed = 0 WHERE id = ?1", .{t.id});
                try planning.append(a, t.key);
            },
            else => {},
        }
    }
    return .{ .queued = queued.items, .planning = planning.items, .left = left.items };
}

/// Run the dispatcher until killed, every few seconds.
pub fn loop(ctx: Ctx, cfg: config.Config, log: *const fn ([]const u8) void) void {
    // Open tickets' changes test-rebased onto their target as it moves (a
    // minute apart), on a thread of its own: jj can be slow.
    if (std.Thread.spawn(.{}, drift.loop, .{ ctx, cfg })) |th| th.detach() else |_| log("dispatch: the conflict check didn't start");
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
    /// Stop: what Claude said last (newer Claude Code versions send it).
    last_assistant_message: ?[]const u8 = null,
    message: ?[]const u8 = null,
    notification_type: ?[]const u8 = null,
    /// PreToolUse: the tool call about to run.
    tool_name: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
    tool_input: ?std.json.Value = null,
};

/// `cl ticket hook <stop|notify|ask>`, run by Claude Code in a ticket's session
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
        if (t.asking.len > 0) board.setAsking(db, t.id, "") catch {};
        board.logEvent(ctx, db, t.id, "turn ended", "") catch {};
        // Finishing still: Claude stopped before it ran `done --close`.
        if (t.finishing.len > 0 and t.stage != .done) stoppedFinishing(ctx, db, a, t, in.last_assistant_message orelse "") catch {};
    } else if (std.mem.eql(u8, event, "ask")) {
        // PreToolUse on AskUserQuestion: keep the call for signals.waitingOn.
        // The question flag comes with the Notification that follows, once
        // the menu is on screen.
        const kept = (keptAsk(a, in) catch return) orelse return;
        board.setAsking(db, t.id, kept) catch {};
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

/// What the PreToolUse hook keeps of an AskUserQuestion call
/// (board.Ticket.asking), null when it carries no input.
fn keptAsk(a: std.mem.Allocator, in: HookInput) !?[]const u8 {
    const call = in.tool_input orelse return null;
    if (call != .object) return null;
    return try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .id = in.tool_use_id orelse "", .input = call }, .{})});
}

test "the AskUserQuestion hook keeps the questions the board answers from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // What Claude Code sends PreToolUse (trimmed).
    const in = try std.json.parseFromSliceLeaky(HookInput, a,
        \\{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"toolu_1",
        \\ "tool_input":{"questions":[{"question":"Fruits?","header":"Fruit","multiSelect":true,"options":[{"label":"Apple"},{"label":"Banana"}]}]}}
    , .{ .ignore_unknown_fields = true });
    const kept = (try keptAsk(a, in)).?;
    const p = signals.keptAsk(a, kept).?;
    try std.testing.expectEqualStrings("toolu_1", p.id);
    const qs = try std.json.parseFromValueLeaky([]const actions.Question, a, p.input.object.get("questions").?, .{ .ignore_unknown_fields = true });
    try std.testing.expect(qs[0].multiSelect);
    // Answered as multi-select, with your own words: both need the questions.
    const keys = try actions.questionKeys(a, qs, &.{"1,kiwi"});
    try std.testing.expectEqualDeep(actions.Press{ .text = "kiwi" }, keys[5]);
    try std.testing.expectEqual(@as(?[]const u8, null), try keptAsk(a, .{}));
}

/// Claude ended its turn while finishing a ticket, without taking it to Done:
/// the merge (or PR, or what you told it) hasn't landed, so it needs you.
/// It stays finishing: an answer lets Claude carry on.
fn stoppedFinishing(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, said: []const u8) !void {
    const tail = lastLines(said, 12);
    try board.setFlagId(ctx, db, t.id, stoppedFlag(t.finishing), "auto", try std.fmt.allocPrint(a, "Claude stopped while {s}, without taking it to Done; its session says why{s}{s}", .{ actions.finishingWhat(t.finishing), if (tail.len > 0) "\n" else "", tail }));
}

/// The flag for finishing `how` cut short: merged already ("after-merge":
/// cl merged it, Claude was doing the steps after) it is the after-merge
/// that failed; otherwise the merge (or PR) didn't land.
fn stoppedFlag(how: []const u8) []const u8 {
    return if (std.mem.eql(u8, how, "after-merge")) board.flag_after_merge else board.flag_merge_failed;
}

/// The last `n` lines of `text`, trimmed.
fn lastLines(text: []const u8, n: usize) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var i = t.len;
    var seen: usize = 0;
    while (i > 0) : (i -= 1) {
        if (t[i - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
    }
    return t[i..];
}

test lastLines {
    try std.testing.expectEqualStrings("c\nd", lastLines("a\nb\nc\nd\n", 2));
    try std.testing.expectEqualStrings("only", lastLines("  only ", 3));
    try std.testing.expectEqualStrings("", lastLines("", 3));
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
    try std.testing.expect(std.mem.indexOf(u8, text, "`cl ticket overview QA-3 --last \"In progress:") != null);
    // done hands in the Overview's Last: what it did and where that leaves me, in a line.
    try std.testing.expect(std.mem.indexOf(u8, text, "Run `cl ticket done QA-3 --last \"<one line>\" --summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Made the review changes; ready for review again\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "without a handoff the ticket skips testing") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, try prompt(a, t, &.{}, null), want) != null);
    try std.testing.expect(std.mem.indexOf(u8, try planPrompt(a, t, &.{}, .checkout), want) != null);
    t.body = "no pictures";
    try std.testing.expect(std.mem.indexOf(u8, try prompt(a, t, &.{}, null), "Read tool") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "`cl ticket overview QA-3 --last \"In progress:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "grilling skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "don't build it") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "read-only copy of the project at master") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`cl ticket done QA-3 --last \"<one line, like 'Plan ready for approval' or") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--summary \"<the plan in a sentence>\" --plan`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Don't call ExitPlanMode") != null);
    // Nothing about building: no review guide, test plan, or jj change.
    try std.testing.expect(std.mem.indexOf(u8, text, "review guide") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--test-plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jj change") == null);
    const here = try planPrompt(a, t, &.{}, .checkout);
    try std.testing.expect(std.mem.indexOf(u8, here, "another ticket's unfinished work") != null);
    // A plan that turns out to be tickets may make it an umbrella.
    try std.testing.expect(std.mem.indexOf(u8, text, "`cl ticket edit QA-3 --umbrella`") != null);

    // Plan, then tickets: an umbrella's planning session files its sub-tickets.
    var u = t;
    u.umbrella = true;
    const ut = try planPrompt(a, u, &.{}, .{ .trunk = "master" });
    try std.testing.expect(std.mem.indexOf(u8, ut, "planning session for an umbrella") != null);
    try std.testing.expect(std.mem.indexOf(u8, ut, "`cl ticket new --parent QA-3 \"<title>\" -m \"<details>\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, ut, "`cl ticket done QA-3 --last \"<one line, like 'Plan ready for approval'>\" --summary \"<the plan in a sentence>\" --plan`") != null);
    try std.testing.expect(std.mem.indexOf(u8, ut, "approving queues the sub-tickets") != null);
    try std.testing.expect(std.mem.indexOf(u8, ut, "a new session builds it") == null);
}

test "planning takes no queue turn or worktree slot, and holds back its sub-tickets" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    try std.testing.expectEqualStrings("cl_qa-1_2", (homeSession(.{ .sessions = sessions[0..2], .statuses = .empty }, p, &.{})).?.tmux_name);

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
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    // A conversation from before the Overview is told the command too.
    try std.testing.expect(std.mem.indexOf(u8, text, "`cl ticket overview QA-3 --last") != null);
    // The resumed conversation already has the body and the instructions.
    try std.testing.expect(std.mem.indexOf(u8, text, "wrap fetch") == null);
}

test "a ticket moved back to the queue lets go of its dead session" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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

test "an umbrella is never started; its sub-tickets are" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const ku = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Umbrella", .stage = .queued, .umbrella = true });
    const ks = try board.createTicket(ctx, db, a, .{ .parent = ku, .title = "Piece", .stage = .queued });
    const w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(ks, w[0].key);
    try std.testing.expectError(error.Umbrella, startIn(ctx, undefined, db, a, try board.getTicket(db, a, ku), false, View{ .sessions = &.{}, .statuses = .empty }, false));
}

test "plan, then tickets: the umbrella plans, its sub-tickets wait for approval, then they start and it doesn't" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const ku = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Ideate", .plan = true, .umbrella = true });
    // It gets a planning session like any planning ticket.
    const p = try planningToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), p.len);
    try std.testing.expectEqualStrings(ku, p[0].key);
    // What its session files waits for the plan, even queued.
    const k1 = try board.createTicket(ctx, db, a, .{ .parent = ku, .title = "One" });
    const k2 = try board.createTicket(ctx, db, a, .{ .parent = ku, .title = "Two", .stage = .queued });
    try std.testing.expectError(error.TargetBusy, startIn(ctx, undefined, db, a, try board.getTicket(db, a, k2), false, View{ .sessions = &.{}, .statuses = .empty }, false));
    try board.done(ctx, db, a, ku, "Two tickets");
    _ = try board.approve(ctx, db, a, ku);
    try std.testing.expectEqual(@as(usize, 0), (try planningToStart(db, a)).len);
    try std.testing.expectEqual(@as(usize, 0), (try board.getTicket(db, a, ku)).flags.len);
    // Approved: the first sub-ticket is what starts; the umbrella never does.
    const w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(k1, w[0].key);
    try std.testing.expectError(error.Umbrella, startIn(ctx, undefined, db, a, try board.getTicket(db, a, ku), false, View{ .sessions = &.{}, .statuses = .empty }, false));
}

test "a running ticket moved back to Queued is stopped, then started again where it left off" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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

test "a paused project starts nothing; resumed, the top of its queue goes first" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try board.addProject(db, .{ .name = "web", .dir = "/x/web" });
    const k1 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "First in", .stage = .queued });
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Moved to the top", .stage = .queued });
    const kw = try board.createTicket(ctx, db, a, .{ .project = "web", .title = "Other project", .stage = .queued });
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Being planned", .stage = .planning, .plan = true });
    const kr = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Running", .stage = .running });
    try db.exec("UPDATE tickets SET tmux = 'cl_qa_1' WHERE key = ?1", .{kr});
    try board.rankTicket(db, a, k2, null, k1);

    try board.setProjectPaused(db, "qa", true);
    try std.testing.expect((try board.getProject(db, a, "qa")).paused);
    // Nothing of qa's starts, queued or planning; web goes on.
    const w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(kw, w[0].key);
    try std.testing.expectEqual(@as(usize, 0), (try planningToStart(db, a)).len);
    // Its queued tickets stay in Queued, in their order, and the running one
    // keeps its session and stage.
    const q = try board.listTickets(db, a, .{ .project = "qa", .stage = .queued });
    try std.testing.expectEqual(@as(usize, 2), q.len);
    const r = try board.getTicket(db, a, kr);
    try std.testing.expectEqual(board.Stage.running, r.stage);
    try std.testing.expectEqualStrings("cl_qa_1", r.tmux);

    // Every project at once.
    try board.setAllPaused(db, true);
    try std.testing.expectEqual(@as(usize, 0), (try waitingToStart(db, a)).len);
    try board.setAllPaused(db, false);
    try std.testing.expect(!(try board.getProject(db, a, "web")).paused);

    // Resumed: the top-ranked queued ticket is the first to start, and planning goes on.
    const resumed = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 3), resumed.len);
    try std.testing.expectEqualStrings(k2, resumed[0].key);
    try std.testing.expectEqualStrings(k1, resumed[1].key);
    try std.testing.expectEqualStrings(kp, (try planningToStart(db, a))[0].key);
    try std.testing.expectError(error.NotFound, board.setProjectPaused(db, "nope", true));
}

test "a pause survives a restart, and an older board gets the column" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/board.db", .{dir}, 0);
    {
        const db = try board.Db.open(path);
        defer db.close();
        try board.migrate(db);
        // A board from before pausing.
        try db.execMulti("ALTER TABLE projects DROP COLUMN paused");
        try board.migrate(db);
        try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
        try board.setProjectPaused(db, "qa", true);
    }
    const db = try board.Db.open(path);
    defer db.close();
    try board.migrate(db);
    try std.testing.expect((try board.getProject(db, a, "qa")).paused);
}

test "a finishing ticket whose session ends or stops short is flagged; trying again clears it" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp", .tmux_blocked = true };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;
    try board.setSession(ctx, db, id, "cl_qa-1_x", "", "", "");

    // Claude opening the PR stops and says why: flagged with what it said.
    try board.setFinishing(ctx, db, id, "pr");
    try stoppedFinishing(ctx, db, a, try board.getTicket(db, a, k), "Working...\ngh: authentication required");
    var t = try board.getTicket(db, a, k);
    try std.testing.expectEqualStrings(board.flag_merge_failed, t.flags[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, t.flags[0].detail, "opening a PR") != null);
    try std.testing.expect(std.mem.endsWith(u8, t.flags[0].detail, "gh: authentication required"));
    try std.testing.expectEqualStrings("pr", t.finishing);

    // Merge tried again: the old failure goes. Its session then ends.
    try board.setFinishing(ctx, db, id, "merge");
    try std.testing.expectEqual(@as(usize, 0), (try board.getTicket(db, a, k)).flags.len);
    try finishingGone(ctx, db, a, try board.getTicket(db, a, k));
    t = try board.getTicket(db, a, k);
    try std.testing.expectEqualStrings("", t.finishing);
    try std.testing.expectEqualStrings(board.flag_merge_failed, t.flags[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, t.flags[0].detail, "cl_qa-1_x") != null);
    try std.testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);

    // Cut short after the merge (Claude doing the steps after it): the after-merge failed.
    try board.setFinishing(ctx, db, id, "after-merge");
    try finishingGone(ctx, db, a, try board.getTicket(db, a, k));
    var after = false;
    for ((try board.getTicket(db, a, k)).flags) |f| after = after or std.mem.eql(u8, f.kind, board.flag_after_merge);
    try std.testing.expect(after);
}

test "a start that fails says why" {
    try std.testing.expectEqual(error.SessionFailed, sessionFailed(error.NoSuchDir, "/gone/qa"));
    try std.testing.expectEqualStrings("no such directory: /gone/qa", failureReason(error.SessionFailed));
    try std.testing.expectEqual(error.SessionFailed, sessionFailed(error.PromptTimeout, "/x"));
    try std.testing.expectEqualStrings("Claude's prompt didn't show within 60 seconds", failureReason(error.SessionFailed));
    try std.testing.expectEqualStrings("TargetBusy", failureReason(error.TargetBusy));
}

test "the dispatcher holds a blocked ticket and starts it once its blocker is done" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa", .mode = .worktree });
    try board.addProject(db, .{ .name = "web", .dir = "/x/web" });
    // A blocker in another project, still in Backlog.
    const kb = try board.createTicket(ctx, db, a, .{ .project = "web", .title = "API first" });
    const kw = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Uses the API", .stage = .queued });
    try std.testing.expect(try board.addBlocker(ctx, db, a, kw, kb));
    try std.testing.expect(!try board.addBlocker(ctx, db, a, kw, kb));

    const held = try board.getTicket(db, a, kw);
    try std.testing.expectEqual(board.Hold.blocked, board.hold(held).?);
    try std.testing.expectEqualStrings(kb, (try board.waitingOn(a, held))[0].key);
    try std.testing.expectEqual(@as(usize, 0), (try waitingToStart(db, a)).len);

    // Under way isn't enough: it waits for Done.
    try board.move(ctx, db, a, kb, .queued);
    var w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(kb, w[0].key);
    try board.move(ctx, db, a, kb, .review);
    try std.testing.expectEqual(@as(usize, 0), (try waitingToStart(db, a)).len);

    try board.move(ctx, db, a, kb, .done);
    w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(kw, w[0].key);
    try std.testing.expect(board.hold(w[0]) == null);
}

test "ordered sub-tickets in a worktree project start one at a time" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa", .mode = .worktree, .slots = 3 });
    const kp = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Roadmap", .umbrella = true });
    const k1 = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "One" });
    const k2 = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "Two" });
    const k3 = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "Three" });
    const kx = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "Alongside" });
    try board.setParallel(ctx, db, a, kx, true);

    // Queueing the umbrella queues its sub-tickets; it has no work of its own.
    try board.move(ctx, db, a, kp, .queued);
    for ([_][]const u8{ k1, k2, k3, kx }) |k| try std.testing.expectEqual(board.Stage.queued, (try board.getTicket(db, a, k)).stage);
    try std.testing.expectEqual(board.Hold.subtickets, board.hold(try board.getTicket(db, a, kp)).?);

    const keys = struct {
        fn of(al: std.mem.Allocator, ts: []const board.Ticket) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (ts) |t| {
                if (out.items.len > 0) try out.append(al, ' ');
                try out.appendSlice(al, t.key);
            }
            return out.items;
        }
    }.of;
    // Slots for three, but only the first starts, with the parallel one.
    try std.testing.expectEqualStrings("QA-2 QA-5", try keys(a, try waitingToStart(db, a)));
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-2_1', stage = 'running' WHERE key = ?1", .{k1});
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-5_2', stage = 'running' WHERE key = ?1", .{kx});
    try std.testing.expectEqualStrings("", try keys(a, try waitingToStart(db, a)));
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{k1});
    try std.testing.expectEqualStrings("QA-3", try keys(a, try waitingToStart(db, a)));

    // Reordered, the chain follows: Three goes before Two.
    try board.rankTicket(db, a, k3, null, k2);
    try std.testing.expectEqualStrings("QA-4", try keys(a, try waitingToStart(db, a)));
    const t2 = try board.getTicket(db, a, k2);
    try std.testing.expectEqualStrings(k3, t2.blocked_by[0].key);
    try std.testing.expect(t2.blocked_by[0].order);
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{k3});
    try std.testing.expectEqualStrings("QA-3", try keys(a, try waitingToStart(db, a)));

    // A sub-ticket created later goes last, after the parallel one too.
    const k4 = try board.createTicket(ctx, db, a, .{ .parent = kp, .title = "Four", .stage = .queued });
    const t4 = try board.getTicket(db, a, k4);
    try std.testing.expectEqual(@as(usize, 2), t4.blocked_by.len);
    try std.testing.expectEqualStrings(k2, t4.blocked_by[0].key);
    try std.testing.expectEqualStrings(kx, t4.blocked_by[1].key);
}

test "a ticket with a target branch starts on it, queued or in a worktree, and its session is told" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp", .tmux_blocked = true };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sh = struct {
        fn run(c: Ctx, al: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
            const r = try std.process.run(al, c.io, .{ .argv = argv });
            if (r.term != .exited or r.term.exited != 0) return error.CommandFailed;
            return std.mem.trim(u8, r.stdout, " \n");
        }
    }.run;
    _ = sh(ctx, a, &.{ "jj", "--version" }) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    _ = sh(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    const git = [_][]const u8{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t" };
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "commit", "-q", "--allow-empty", "-m", "init" }));
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "checkout", "-q", "-b", "feature/venues" }));
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "commit", "-q", "--allow-empty", "-m", "venues" }));
    _ = try sh(ctx, a, &(git ++ [_][]const u8{ "checkout", "-q", "master" }));
    try std.testing.expect(worktree.ensureJj(ctx, a, repo));
    const feature_at = try sh(ctx, a, &.{ "git", "-C", repo, "rev-parse", "feature/venues" });
    const parentOf = struct {
        fn of(c: Ctx, al: std.mem.Allocator, dir: []const u8, change: []const u8) ![]const u8 {
            return sh(c, al, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", try std.fmt.allocPrint(al, "{s}-", .{change}), "-T", "commit_id" });
        }
    }.of;

    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = repo });
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    cfg.board.worktrees = try std.fmt.allocPrint(a, "{s}/wt", .{base});

    // Queued: the project's checkout goes onto a new change on the feature branch.
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Queued", .onto = "feature/venues" });
    const tq = try board.getTicket(db, a, kq);
    const c = (try ticketChange(ctx, db, a, repo, tq, worktree.target(ctx, a, repo, tq.onto).?, "QA-1: Queued")).?;
    try std.testing.expectEqualStrings(feature_at, try parentOf(ctx, a, repo, c.change.id));

    // A worktree: its workspace's change is on the feature branch too.
    const kw = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Own", .mode = .worktree, .onto = "feature/venues" });
    const tw = try board.getTicket(db, a, kw);
    const wt = try worktree.create(ctx, a, cfg, repo, "qa", kw, tw.title, worktree.target(ctx, a, repo, tw.onto) orelse tw.onto, "QA-2: Own");
    try std.testing.expectEqualStrings(feature_at, try parentOf(ctx, a, repo, wt.change));

    // Its session hears where the work goes, and not to take it to trunk.
    var t = tq;
    t.change = c.change.id;
    const text = try prompt(a, t, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, text, "targets the branch feature/venues, not trunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cl merges it into feature/venues") != null);
    // A ticket on trunk hears nothing of the kind.
    t.onto = "";
    try std.testing.expect(std.mem.indexOf(u8, try prompt(a, t, &.{}, null), "targets the branch") == null);
}

test "a ticket of a project that isn't a code repo gets no jj, base or change, and its session no review guide or merge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // perm: what a session start keeps (its name) goes with the arena.
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = Ctx.testEnv(), .home = "/tmp", .tmux_blocked = true };
    const sh = struct {
        fn run(c: Ctx, al: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
            const r = try std.process.run(al, c.io, .{ .argv = argv });
            if (r.term != .exited or r.term.exited != 0) return error.CommandFailed;
            return std.mem.trim(u8, r.stdout, " \n");
        }
    }.run;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    // Inside a git repo, as a notes folder in a dotfiles repo might be: cl
    // must leave that repo alone, not take it for the project's.
    _ = sh(ctx, a, &.{ "git", "init", "-q", "-b", "master", base }) catch return error.SkipZigTest;
    _ = try sh(ctx, a, &.{ "git", "-C", base, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init" });
    const dir = try std.fmt.allocPrint(a, "{s}/todo", .{base});
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);

    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "me", .dir = dir, .repo = false });
    var profiles = [_]config.Profile{.{ .name = "work", .config_dir = "/h/.claude-work" }};
    const cfg: config.Config = .{ .profiles = &profiles, .default = "work", .operator = "work" };
    const k = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Book the venue", .stage = .queued });

    // No worktree to move to.
    try std.testing.expectError(error.NoRepo, relocate(ctx, cfg, db, a, try board.getTicket(db, a, k), .worktree));

    // Started (its session can't, tmux being blocked here): no jj set up,
    // no base for a review, no change.
    const none: View = .{ .sessions = &.{}, .statuses = .empty };
    try std.testing.expectError(error.SessionFailed, startIn(ctx, cfg, db, a, try board.getTicket(db, a, k), false, none, false));
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqualStrings("", t.base);
    try std.testing.expectEqualStrings("", t.change);
    try std.testing.expect(!try board.hasEvent(db, t.id, "jj init"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, try std.fmt.allocPrint(a, "{s}/.jj", .{base}), .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, try std.fmt.allocPrint(a, "{s}/.jj", .{dir}), .{}));

    // What its session is told: how to finish, with nothing about merging or PRs.
    const text = try prompt(a, t, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Run `cl ticket done QA-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1. Run `cl ticket done ME-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "custom-close") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "review guide") == null);
    // Whatever a caller passes (attaching a session does its own): no review
    // guide, and no target branch, even one set on it from before.
    var onto = t;
    onto.onto = "feature";
    const passed = try prompt(a, onto, &.{}, "");
    try std.testing.expect(std.mem.indexOf(u8, passed, "review guide") == null);
    try std.testing.expect(std.mem.indexOf(u8, passed, "targets the branch") == null);
    var code = onto;
    code.repo = true;
    const code_text = try prompt(a, code, &.{}, "");
    for ([_][]const u8{ "custom-close", "review guide", "targets the branch feature" }) |want| try std.testing.expect(std.mem.indexOf(u8, code_text, want) != null);

    // Planning: in the project's folder, no workspace or jj, and told it's a folder.
    var planCfg = cfg;
    planCfg.board.worktrees = try std.fmt.allocPrint(a, "{s}/wt", .{base});
    const kp = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Plan the trip", .plan = true });
    try std.testing.expectError(error.SessionFailed, startPlanning(ctx, planCfg, db, a, try board.getTicket(db, a, kp)));
    try std.testing.expect(!try board.hasEvent(db, (try board.getTicket(db, a, kp)).id, "no planning workspace"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, planCfg.board.worktrees, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, try std.fmt.allocPrint(a, "{s}/.jj", .{base}), .{}));
    const plan_text = try planPrompt(a, t, &.{}, .folder);
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "isn't a code repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_text, "unfinished work") == null);
}

test "attach refuses another ticket's session and a ticket with a live one" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const mk = struct {
        fn s(tmux_name: []const u8, name: []const u8) tmux.Session {
            return .{ .tmux_name = tmux_name, .name = name, .dir = "/x/qa-tool", .profile = "", .created = 1, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" };
        }
    }.s;
    var sessions = [_]tmux.Session{ mk("cl_qa-tool_1", "qa-tool"), mk("cl_other_2", "other") };
    const view: View = .{ .sessions = &sessions, .statuses = .empty };
    try std.testing.expectEqualStrings("cl_qa-tool_1", findSession(view, "qa-tool").?.tmux_name);
    try std.testing.expectEqualStrings("cl_other_2", findSession(view, "cl_other_2").?.tmux_name);
    try std.testing.expect(findSession(view, "nope") == null);

    const k1 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Owner", .stage = .running });
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Stray", .stage = .queued });
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-tool_1' WHERE key = ?1", .{k1});
    const t2 = try board.getTicket(db, a, k2);

    // QA-1 is in progress in qa-tool: it isn't QA-2's to take.
    try std.testing.expectError(error.SessionTaken, attachCheck(db, a, t2, view, sessions[0], true));
    try std.testing.expectEqualStrings(k1, (try attachOwner(db, a, "cl_qa-tool_1", t2.id)).?);
    // Its owner can attach it again (to add the hooks once it is idle).
    try attachCheck(db, a, try board.getTicket(db, a, k1), view, sessions[0], true);
    // Any unfinished ticket holds it, not only one in progress.
    try db.exec("UPDATE tickets SET stage = 'backlog' WHERE key = ?1", .{k1});
    try std.testing.expectError(error.SessionTaken, attachCheck(db, a, t2, view, sessions[0], true));
    // Done, it lets go.
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{k1});
    try attachCheck(db, a, t2, view, sessions[0], true);

    // A ticket whose own session is alive keeps it; a dead one is replaced.
    try db.exec("UPDATE tickets SET tmux = 'cl_other_2' WHERE key = ?1", .{k2});
    try std.testing.expectError(error.AlreadyStarted, attachCheck(db, a, try board.getTicket(db, a, k2), view, sessions[0], true));
    try db.exec("UPDATE tickets SET tmux = 'cl_gone_9' WHERE key = ?1", .{k2});
    try attachCheck(db, a, try board.getTicket(db, a, k2), view, sessions[0], true);
    try db.exec("UPDATE tickets SET tmux = '(starting)' WHERE key = ?1", .{k2});
    try std.testing.expectError(error.Starting, attachCheck(db, a, try board.getTicket(db, a, k2), view, sessions[0], true));

    // Done, planning and dead panes are refused.
    try db.exec("UPDATE tickets SET tmux = '', stage = 'done' WHERE key = ?1", .{k2});
    try std.testing.expectError(error.Finished, attachCheck(db, a, try board.getTicket(db, a, k2), view, sessions[0], true));
    try db.exec("UPDATE tickets SET stage = 'planning' WHERE key = ?1", .{k2});
    try std.testing.expectError(error.Planning, attachCheck(db, a, try board.getTicket(db, a, k2), view, sessions[0], true));
    try db.exec("UPDATE tickets SET stage = 'queued' WHERE key = ?1", .{k2});
    var dead = sessions[1];
    dead.pane_dead = true;
    try std.testing.expectError(error.PaneDead, attachCheck(db, a, try board.getTicket(db, a, k2), view, dead, true));
    try std.testing.expectError(error.OtherProject, attachCheck(db, a, try board.getTicket(db, a, k2), view, sessions[0], false));

    // Two attaches at once: the write itself refuses the second.
    try db.exec("UPDATE tickets SET tmux = '' WHERE key = ?1", .{k2});
    try db.exec("UPDATE tickets SET tmux = 'cl_other_2', stage = 'running' WHERE key = ?1", .{k1});
    try std.testing.expectError(error.SessionTaken, claimSession(db, a, t2.id, "cl_other_2", ""));
    // A start claimed the ticket meanwhile.
    try db.exec("UPDATE tickets SET tmux = '(starting)' WHERE key = ?1", .{k2});
    try std.testing.expectError(error.Starting, claimSession(db, a, t2.id, "cl_qa-tool_1", ""));
    try db.exec("UPDATE tickets SET tmux = 'cl_gone_9' WHERE key = ?1", .{k2});
    try claimSession(db, a, t2.id, "cl_qa-tool_1", "cl_gone_9");
    try std.testing.expectEqualStrings("cl_qa-tool_1", (try board.getTicket(db, a, k2)).tmux);
}

test "a session attaches only within the ticket's project" {
    const p: board.Project = .{ .name = "qa", .dir = "/x/qa-tool", .prefix = "QA", .slots = 3, .mode = .queue, .profile = "" };
    const t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Retry", .body = "", .stage = .queued,
        .mode = .worktree, .plan = false, .skill = "", .target = "", .worktree = "/y/qa-3", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0,
    };
    try std.testing.expect(inProject("/x/qa-tool", p, t, "/wt"));
    try std.testing.expect(inProject("/x/qa-tool/web", p, t, "/wt"));
    try std.testing.expect(!inProject("/x/qa-tool-old", p, t, "/wt"));
    try std.testing.expect(inProject("/y/qa-3", p, t, "/wt"));
    try std.testing.expect(inProject("/wt/qa/qa-1-other", p, t, "/wt/"));
    try std.testing.expect(!inProject("/wt/qb/qb-1", p, t, "/wt"));
    try std.testing.expect(!inProject("/x/cl-wrapper", p, t, "/wt"));
}

test attachPlan {
    const sid = "11111111-2222-3333-4444-555555555555";
    const info: claude.Info = .{ .status = .idle, .name = "", .status_since_ms = 0, .updated_ms = 0, .summary = "", .session_id = sid, .cwd = "/x/qa" };
    // Idle and known: restarted, resuming when Claude has the transcript.
    const p1 = attachPlan(.idle, info, "/x/qa", true, false);
    try std.testing.expect(p1.restart);
    try std.testing.expectEqualStrings(sid, p1.resume_id.?);
    // Nothing said yet: a new conversation.
    try std.testing.expect(attachPlan(.idle, info, "/x/qa", false, false).resume_id == null);
    // Busy, or a background task running: recorded, with its conversation.
    for ([_]claude.Status{ .busy, .shell, .waiting, .blocked, .unknown }) |st| {
        const p = attachPlan(st, info, "/x/qa", true, false);
        try std.testing.expect(!p.restart);
        try std.testing.expectEqualStrings(sid, p.conversation);
    }
    // Told already, Claude elsewhere, or no status at all: no restart.
    try std.testing.expect(!attachPlan(.idle, info, "/x/qa", true, true).restart);
    try std.testing.expect(!attachPlan(.idle, info, "/x/other", true, false).restart);
    const none = attachPlan(.idle, null, "/x/qa", true, false);
    try std.testing.expect(!none.restart);
    try std.testing.expectEqualStrings("", none.conversation);
}

test "attaching a busy session records it, and the ticket runs there" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "", .board = .{ .worktrees = "/wt" } };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const sid = "11111111-2222-3333-4444-555555555555";
    const mk = struct {
        fn s(tmux_name: []const u8, name: []const u8) tmux.Session {
            return .{ .tmux_name = tmux_name, .name = name, .dir = "/x/qa-tool", .profile = "", .created = 1, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" };
        }
    }.s;
    var sessions = [_]tmux.Session{ mk("cl_qa-tool_1", "qa-tool"), mk("cl_qa-2_2", "qa-2") };
    var statuses: claude.StatusMap = .empty;
    for (sessions) |s| try statuses.put(a, s.tmux_name, .{ .status = .busy, .name = "", .status_since_ms = 0, .updated_ms = 0, .summary = "", .session_id = sid, .cwd = "/x/qa-tool" });
    const view: View = .{ .sessions = &sessions, .statuses = statuses };

    // Queued, its last start failed and its old session is gone (QA-6).
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Stray", .stage = .queued });
    try db.exec("UPDATE tickets SET tmux = 'cl_gone_9' WHERE key = ?1", .{kq});
    const tq = try board.getTicket(db, a, kq);
    try board.setFlagId(ctx, db, tq.id, "start-failed", "auto", "");
    try board.setFlagId(ctx, db, tq.id, "ended", "auto", "");
    const r = try attachTo(ctx, cfg, db, a, tq, view, sessions[0]);
    try std.testing.expect(!r.restarted and !r.again);
    try std.testing.expectEqual(claude.Status.busy, r.status);
    const after = try board.getTicket(db, a, kq);
    try std.testing.expectEqualStrings("cl_qa-tool_1", after.tmux);
    try std.testing.expectEqualStrings(sid, after.session_id);
    try std.testing.expectEqual(board.Stage.running, after.stage);
    try std.testing.expectEqual(@as(usize, 0), after.flags.len);
    // Again: the same session, still busy.
    try std.testing.expect((try attachTo(ctx, cfg, db, a, after, view, sessions[0])).again);

    // In Review it stays there.
    const kr = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Reviewed", .stage = .review });
    _ = try attachTo(ctx, cfg, db, a, try board.getTicket(db, a, kr), view, sessions[1]);
    try std.testing.expectEqual(board.Stage.review, (try board.getTicket(db, a, kr)).stage);
    // The first one's session isn't another's to take.
    const kb = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Other", .stage = .backlog });
    try std.testing.expectError(error.SessionTaken, attachTo(ctx, cfg, db, a, try board.getTicket(db, a, kb), view, sessions[0]));
    try std.testing.expectEqualStrings("", (try board.getTicket(db, a, kb)).tmux);
    // Nor is a session in another project.
    var elsewhere = sessions[1];
    elsewhere.tmux_name = "cl_cl-wrapper_3";
    elsewhere.dir = "/x/cl-wrapper";
    try std.testing.expectError(error.OtherProject, attachTo(ctx, cfg, db, a, try board.getTicket(db, a, kb), view, elsewhere));
}

test "an attached session already told the ticket isn't restarted" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const sid = "11111111-2222-3333-4444-555555555555";
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .running });
    try db.exec("UPDATE tickets SET tmux = 'cl_s_1', session_id = ?2 WHERE key = ?1", .{ k, sid });
    const t = try board.getTicket(db, a, k);
    // Started there by cl: told.
    try board.logEvent(ctx, db, t.id, "started", "cl_s_1");
    try std.testing.expect(try toldHere(db, a, t, "cl_s_1", sid));
    // Another conversation there now (/clear): not this one.
    try std.testing.expect(!try toldHere(db, a, t, "cl_s_1", "99999999-2222-3333-4444-555555555555"));
    // Attached while busy: not told.
    try board.logEvent(ctx, db, t.id, "attached", "cl_s_1");
    try std.testing.expect(!try toldHere(db, a, t, "cl_s_1", sid));
    // Attached and restarted: told.
    try board.logEvent(ctx, db, t.id, "attached", "cl_s_1" ++ restarted_suffix);
    try std.testing.expect(try toldHere(db, a, t, "cl_s_1", sid));
}

test attachNote {
    const text = try attachNote(std.testing.allocator, "QA-6");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "cl attached this session to ticket QA-6"));
}

test "a todo is never started, in any stage; its queued tasks are, while it sits in Backlog" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const kt = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Reply to Josh", .todo = true });
    const kc = try board.createTicket(ctx, db, a, .{ .parent = kt, .title = "Draft it", .stage = .queued });
    const w = try waitingToStart(db, a);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqualStrings(kc, w[0].key);
    // Even put in Queued behind cl's back, the dispatcher passes it by.
    try db.exec("UPDATE tickets SET stage = 'queued' WHERE key = ?1", .{kt});
    for (try waitingToStart(db, a)) |t| try std.testing.expect(!std.mem.eql(u8, t.key, kt));
}

test "starting a todo makes a talk session of its own, or nothing: no stage change, no claim left behind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = Ctx.testEnv(), .home = "/tmp", .tmux_blocked = true };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The hooks file goes in the board's directory: a temporary one, never the real board's.
    var profiles = [_]config.Profile{.{ .name = "default", .config_dir = null }};
    const cfg: config.Config = .{ .profiles = &profiles, .default = "default", .operator = "", .board = .{ .dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a) } };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    // A directory that isn't there: the session can't start.
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool-not-there" });
    const kt = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Reply to Josh", .todo = true });
    try std.testing.expectError(error.SessionFailed, startTodo(ctx, cfg, db, a, try board.getTicket(db, a, kt)));
    const t = try board.getTicket(db, a, kt);
    try std.testing.expectEqualStrings("", t.tmux);
    try std.testing.expectEqual(board.Stage.backlog, t.stage);
    // Starting in Running: it stays Running, never Queued (no TargetBusy wait).
    try db.exec("UPDATE tickets SET stage = 'running' WHERE key = ?1", .{kt});
    try std.testing.expectError(error.SessionFailed, startTodo(ctx, cfg, db, a, try board.getTicket(db, a, kt)));
    try std.testing.expectEqual(board.Stage.running, (try board.getTicket(db, a, kt)).stage);
    // Being started already: it says so.
    try db.exec("UPDATE tickets SET tmux = '(starting)' WHERE key = ?1", .{kt});
    try std.testing.expectError(error.AlreadyStarted, startTodo(ctx, cfg, db, a, try board.getTicket(db, a, kt)));
    // Done: refused, before anything is claimed (nothing would follow it).
    try db.exec("UPDATE tickets SET tmux = '', stage = 'done' WHERE key = ?1", .{kt});
    try std.testing.expectError(error.TodoDone, startTodo(ctx, cfg, db, a, try board.getTicket(db, a, kt)));
    try std.testing.expectEqualStrings("", (try board.getTicket(db, a, kt)).tmux);
}

test "a todo's talk session never holds the project's queue" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa-tool" });
    const p = try board.getProject(db, a, "qa");
    const kt = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Reply to Josh", .todo = true, .stage = .running });
    const kc = try board.createTicket(ctx, db, a, .{ .parent = kt, .title = "Draft it", .stage = .queued });
    const kq = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Fix the build", .stage = .queued });
    try db.exec("UPDATE tickets SET tmux = 'cl_qa-1_1' WHERE key = ?1", .{kt});
    const mk = struct {
        fn s(tmux_name: []const u8, name: []const u8, created: i64) tmux.Session {
            return .{ .tmux_name = tmux_name, .name = name, .dir = "/x/qa-tool", .profile = "", .created = created, .pane_title = "", .pane_dead = false, .activity = 0, .role = "", .alert = "" };
        }
    }.s;
    const tq = try board.getTicket(db, a, kq);
    const tc = try board.getTicket(db, a, kc);
    // Only the todo's session is open in the project's directory: it isn't
    // the project's, so the queued ticket starts one of its own.
    var only = [_]tmux.Session{mk("cl_qa-1_1", "qa-1", 1)};
    const v1: View = .{ .sessions = &only, .statuses = .empty };
    try std.testing.expectEqualStrings("", try queueTarget(db, a, tq, v1, p));
    try std.testing.expectEqualStrings("", try queueTarget(db, a, tc, v1, p));
    // The oldest other session there is, even though the todo's is older.
    var more = [_]tmux.Session{ mk("cl_qa-1_1", "qa-1", 1), mk("cl_x_2", "x", 2) };
    const v2: View = .{ .sessions = &more, .statuses = .empty };
    try std.testing.expectEqualStrings("cl_x_2", try queueTarget(db, a, tq, v2, p));
    // Its live session (Running or Backlog) is no ticket in progress there.
    try std.testing.expect(!try projectBusy(db, a, v2, tq));
    try std.testing.expect(!try targetHasTicket(db, "cl_qa-1_1", tq.id));
    try std.testing.expect(try parentSession(db, a, tc, v2) == null);
    // Done, its session isn't skipped any more (it was closed with it).
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{kt});
    try std.testing.expectEqualStrings("cl_qa-1_1", try queueTarget(db, a, tq, v2, p));
    // A ticket in progress there would hold it (regression).
    try db.exec("UPDATE tickets SET stage = 'running', todo = 0 WHERE key = ?1", .{kt});
    try std.testing.expect(try projectBusy(db, a, v2, tq));
}

test "a todo's talk session is followed in Backlog and Running; gone, it is let go without `ended`" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = Ctx.testEnv(), .home = "/tmp", .tmux_blocked = true };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    const kt = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Reply to Josh", .todo = true });
    const kr = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Look it up", .stage = .running });
    try db.exec("UPDATE tickets SET tmux = 'cl_me-1_1' WHERE key = ?1", .{kt});
    try db.exec("UPDATE tickets SET tmux = 'cl_me_2' WHERE key = ?1", .{kr});
    var t = try board.getTicket(db, a, kt);
    try std.testing.expect(followed(t));
    t.stage = .running;
    try std.testing.expect(followed(t));
    t.stage = .done;
    try std.testing.expect(!followed(t));
    t.stage = .backlog;
    t.todo = false;
    try std.testing.expect(!followed(t));

    // It asked something, then its session went away.
    try board.setFlag(ctx, db, a, kt, board.flag_question, "auto", "Which dates?");
    try sessionGone(ctx, db, try board.getTicket(db, a, kt));
    t = try board.getTicket(db, a, kt);
    try std.testing.expectEqualStrings("", t.tmux);
    try std.testing.expectEqual(@as(usize, 0), t.flags.len);
    try std.testing.expectEqual(board.Stage.backlog, t.stage);
    // A ticket's is flagged, as before.
    try sessionGone(ctx, db, try board.getTicket(db, a, kr));
    const r = try board.getTicket(db, a, kr);
    try std.testing.expectEqualStrings("cl_me_2", r.tmux);
    try std.testing.expectEqualStrings("ended", r.flags[0].kind);
}

test todoPrompt {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t: board.Ticket = .{ .id = 1, .key = "ME-1", .project = "me", .title = "Reply to Josh", .body = "About the offsite dates.\n", .stage = .backlog, .mode = .queue, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "", .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0, .todo = true, .link = "https://slack.example/p1" };
    const text = try todoPrompt(a, t, &.{.{ .author = "you", .body = "he prefers Tuesday", .sent = false, .at = 0 }});
    for ([_][]const u8{ "Todo ME-1: Reply to Josh", "a todo of mine", "not a task for you to finish", "About the offsite dates.", "https://slack.example/p1", "- he prefers Tuesday", "`cl ticket new --parent ME-1 ", "Don't run `cl ticket done`", "`cl ticket move ME-1 done`", "`cl ticket park ME-1 --reason " }) |want|
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
            return error.TestUnexpectedResult;
        };
    // Resumed: the conversation has it all already.
    const back = try todoResumePrompt(a, t, &.{});
    try std.testing.expect(std.mem.indexOf(u8, back, "todo ME-1: Reply to Josh") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "cl ticket done") == null);
}

test "a todo's task is told the todo's title, body and link; other tickets aren't" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const todo: board.Ticket = .{ .id = 1, .key = "ME-1", .project = "me", .title = "Reply to Josh", .body = "About the offsite dates.\n", .stage = .backlog, .mode = .queue, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "", .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 1, .todo = true, .link = "https://slack.example/p1" };
    var t = todo;
    t.id = 2;
    t.key = "ME-2";
    t.title = "Draft a reply";
    t.body = "Short and friendly.";
    t.parent = "ME-1";
    t.todo = false;
    t.link = "";
    t.children = 0;
    t.repo = false;
    const text = try promptFor(a, t, todo, &.{}, null);
    for ([_][]const u8{ "It is for ME-1, a todo of mine", "Reply to Josh", "About the offsite dates.", "Source: https://slack.example/p1", "There is no code here to commit" }) |want|
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
            return error.TestUnexpectedResult;
        };
    // Not a todo's: none of that.
    const plain = try promptFor(a, t, null, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "a todo of mine") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "There is no code here") == null);
}

test "pause now leaves a ticket held in Running for its automated review alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = &env, .home = "/tmp", .tmux_blocked = true };
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Held", .stage = .running });
    const id = (try board.getTicket(db, a, k)).id;
    try db.exec("UPDATE tickets SET tmux = 'cl_qa' WHERE id = ?1", .{id});
    try board.setAutoreview(db, id, "{\"status\":\"running\",\"started\":1,\"round\":1,\"auto\":\"send\",\"held\":true}");
    const r = try interrupt(ctx, cfg, db, a, "qa");
    try std.testing.expectEqual(@as(usize, 0), r.queued.len);
    try std.testing.expectEqual(@as(usize, 0), r.left.len);
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqual(board.Stage.running, t.stage);
    try std.testing.expect(autoreview.holds(a, t));
}
