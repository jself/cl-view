//! Automated review of a ticket in Review (`cl ticket autoreview`, the
//! board's "Run automated review"): a second Claude, not the one that wrote
//! the code, reads the ticket's changes and reports what it finds. Nothing
//! goes to the ticket's session by itself: the human reads the findings on
//! the board first, then sends them to Claude or opens them in gutter as a
//! draft review to edit (`gutterDraft`).
//!
//! The reviewer is an ordinary interactive `claude` in its own hidden tmux
//! session, clrv_<key>, started in the ticket's directory under the ticket's
//! profile (CLAUDE_CONFIG_DIR is always set, never inherited: cl web's own
//! environment may name another profile). It runs with --permission-mode
//! dontAsk and an allow list of tools that only read files, plus Write to one
//! file outside the checkout (`findingsPath`): no Bash at all, so it can't
//! change the work (not even through a command's --output) and never waits on
//! a permission prompt nobody sees. cl writes what it reviews for it, the
//! diff and the changes' descriptions, to <board dir>/autoreview/<KEY>.diff
//! (`changesText`), and its instructions to <KEY>.md, which its first message
//! tells it to read (a prompt that long can't go on Claude's command line:
//! one argument is at most 128 KiB). It has no CL_TICKET and
//! none of the ticket's hooks: it can't flag, finish or move the ticket. It
//! writes its findings as JSON to that file and stops; its own Stop hook
//! (`cl ticket autoreview <key> --stop-hook`, `stopHook`) keeps them on the
//! ticket (`Ticket.autoreview`) and closes the session, or sends it back
//! once to fix JSON that's wrong.
//!
//! While it runs the ticket is out of Needs You (`board.isWorking`); when it
//! finishes (or fails) it is back with its stage's flag, Ready for review.
//!
//! What it is told: the ticket, its plan, what the human said in comments,
//! Claude's summary and how to see the changes, with cl's own review
//! instructions, or the project's skill (`cl project set --review-skill`).
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");
const review = @import("review.zig");
const worktree = @import("worktree.zig");
const claude = @import("claude.zig");

/// A review still running after this long is stopped and recorded as failed.
pub const timeout_s: i64 = 20 * 60;

pub const Finding = struct {
    /// The file, relative to the ticket's directory; "" for a finding about
    /// the change as a whole.
    path: []const u8 = "",
    /// The line in the file's current version, 0 for none.
    line: i64 = 0,
    /// The last line when it spans several, else 0.
    end_line: i64 = 0,
    /// high, medium or low.
    severity: []const u8 = "medium",
    /// correctness, spec, standards, tests or other.
    category: []const u8 = "",
    title: []const u8 = "",
    /// What is wrong, why it matters, the fix it suggests (markdown).
    body: []const u8 = "",
};

/// What `Ticket.autoreview` holds.
pub const Review = struct {
    /// running, done or failed.
    status: []const u8 = "",
    started: i64 = 0,
    finished: i64 = 0,
    /// The ticket's round it reviewed: an older one is from before Claude's
    /// last changes.
    round: i64 = 0,
    /// The revision (gutter's -r) it was told to review.
    rev: []const u8 = "",
    /// The cl profile it ran under, so you know whose usage it was.
    profile: []const u8 = "",
    /// The project's review skill it used, "" for cl's own instructions.
    skill: []const u8 = "",
    summary: []const u8 = "",
    findings: []const Finding = &.{},
    /// Why it failed.
    @"error": []const u8 = "",
    /// When the findings were sent to the ticket's session, 0 if not.
    sent: i64 = 0,
    /// What you made of `message` on the board (its Edit), sent in its
    /// place; "" for the findings as they came. A new review drops it.
    edited: []const u8 = "",
};

pub const Error = error{
    /// Only a ticket in Review or Testing is reviewed.
    NotInReview,
    /// It has no changes to review (no base revision or jj change).
    NoChanges,
    /// A review of it is running already.
    AlreadyRunning,
    /// tmux couldn't start the reviewer (`tmux.lastError()`).
    StartFailed,
    /// The findings aren't the JSON asked for (`lastError()` says why).
    BadFindings,
    /// There is no finished review with findings to send or open.
    NoFindings,
    /// gutter is open already: a draft only loads when it starts.
    GutterOpen,
    /// The findings are from an earlier round, before Claude's last
    /// changes: their lines may point elsewhere now, or be fixed already.
    OldFindings,
    /// The review isn't running any more (stopped, failed or finished)
    /// when its findings came in: they're dropped.
    NotRunning,
};

/// Whether `r` reviewed the ticket's current round (not code Claude has
/// changed since).
pub fn current(r: Review, t: board.Ticket) bool {
    return r.round >= t.round;
}

pub fn sessionName(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "clrv_{s}", .{try std.ascii.allocLowerString(a, key)});
}

/// The ticket's last review, or null when it has none (or it can't be read).
pub fn load(a: std.mem.Allocator, t: board.Ticket) ?Review {
    if (t.autoreview.len == 0) return null;
    return std.json.parseFromSliceLeaky(Review, a, t.autoreview, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn save(db: board.Db, a: std.mem.Allocator, id: i64, r: Review) !void {
    try board.setAutoreview(db, id, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})}));
}

/// tmux targets for the reviewer's session `name`, matched exactly: a bare
/// name also matches by prefix, so clrv_cl-1 would find clrv_cl-11.
fn exact(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "={s}", .{name});
}
fn exactPane(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "={s}:", .{name});
}

fn exists(ctx: Ctx, a: std.mem.Allocator, name: []const u8) bool {
    return tmux.hasSession(ctx, exact(a, name) catch return false);
}

pub const State = enum { alive, gone, unknown };

/// Whether the reviewer still runs in `name` (its pane stays after it
/// exits): `unknown` when tmux can't be asked (blocked in a sandbox, or its
/// server doesn't answer), which isn't the same as the reviewer being gone.
fn state(ctx: Ctx, a: std.mem.Allocator, name: []const u8) State {
    if (ctx.tmux_blocked) return .unknown;
    const names = tmux.run(ctx, &.{ "list-sessions", "-F", "#{session_name}" }) catch {
        // No server at all: nothing runs on it, the reviewer included.
        return if (noServer(tmux.lastError())) .gone else .unknown;
    };
    defer ctx.gpa.free(names);
    var it = std.mem.tokenizeScalar(u8, names, '\n');
    while (it.next()) |n| {
        if (!std.mem.eql(u8, n, name)) continue;
        const dead = tmux.run(ctx, &.{ "display", "-p", "-t", exactPane(a, name) catch return .unknown, "#{pane_dead}" }) catch return .unknown;
        defer ctx.gpa.free(dead);
        return if (std.mem.eql(u8, dead, "1")) .gone else .alive;
    }
    return .gone;
}

/// tmux's error when no server runs on its socket.
fn noServer(err: []const u8) bool {
    return std.mem.indexOf(u8, err, "no server running") != null or
        (std.mem.indexOf(u8, err, "error connecting to") != null and std.mem.indexOf(u8, err, "No such file or directory") != null);
}

test noServer {
    try std.testing.expect(noServer("no server running on /tmp/tmux-1000/default"));
    try std.testing.expect(noServer("error connecting to /tmp/x/tmux.sock (No such file or directory)"));
    try std.testing.expect(!noServer("error connecting to /tmp/x/tmux.sock (Permission denied)"));
    try std.testing.expect(!noServer("tmux failed"));
}

fn alive(ctx: Ctx, a: std.mem.Allocator, name: []const u8) bool {
    return state(ctx, a, name) == .alive;
}

/// The profile the ticket's session runs under: its own, else its project's,
/// else the default (as the dispatcher picks it).
pub fn profileFor(cfg: config.Config, t: board.Ticket, p: board.Project) config.Profile {
    if (t.profile.len > 0) if (cfg.find(t.profile)) |x| return x;
    if (p.profile.len > 0) if (cfg.find(p.profile)) |x| return x;
    return cfg.defaultProfile();
}

test profileFor {
    var profiles = [_]config.Profile{ .{ .name = "work", .config_dir = "/h/.claude-work" }, .{ .name = "personal", .config_dir = "/h/.claude" } };
    const cfg: config.Config = .{ .profiles = &profiles, .default = "work", .operator = "work" };
    const t: board.Ticket = .{ .id = 1, .key = "DI-1", .project = "dizplay", .title = "", .body = "", .stage = .review, .mode = .queue, .plan = false, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "", .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0 };
    const p: board.Project = .{ .name = "dizplay", .dir = "/x", .prefix = "DI", .slots = 1, .mode = .queue, .profile = "personal" };
    // The project's profile, not the default (cl web's CLAUDE_CONFIG_DIR).
    try std.testing.expectEqualStrings("/h/.claude", profileFor(cfg, t, p).config_dir.?);
    var own = t;
    own.profile = "work";
    try std.testing.expectEqualStrings("work", profileFor(cfg, own, p).name);
    var none = p;
    none.profile = "";
    try std.testing.expectEqualStrings("work", profileFor(cfg, t, none).name);
}

// ---- starting and stopping ----

/// Tools the reviewer may use without asking; with dontAsk, every other one
/// is refused. Reading files, and writing its findings file (an absolute
/// path in a permission rule starts with //). No Bash: even git's read
/// commands write files (`git diff --output=`), so cl runs them itself
/// (`changesText`).
fn allowedTools(a: std.mem.Allocator, findings: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Read,Grep,Glob,Agent,Task,TodoWrite,Write(/{s}),Edit(/{s})", .{ findings, findings });
}

/// What the reviewer reviews, as cl sees it now: the changes' descriptions,
/// then the diff (git: and the files git doesn't track yet, which its diff
/// leaves out). error.NoChanges when the diff is empty.
pub fn changesText(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, rev: []const u8, vcs: worktree.Vcs) ![]const u8 {
    const Cmd = struct { title: []const u8, argv: []const []const u8 };
    const cmds: []const Cmd = switch (vcs) {
        .jj => &.{
            .{ .title = "jj log", .argv = &.{ "jj", "--no-pager", "--color=never", "log", "--no-graph", "-r", rev } },
            .{ .title = "jj diff --git", .argv = &.{ "jj", "--no-pager", "--color=never", "diff", "--git", "-r", rev } },
        },
        .git => &.{
            .{ .title = "git log", .argv = &.{ "git", "--no-pager", "log", "--no-color", try std.fmt.allocPrint(a, "{s}..HEAD", .{rev}) } },
            .{ .title = "git diff (the working tree against where the ticket started)", .argv = &.{ "git", "--no-pager", "diff", "--no-color", rev } },
            .{ .title = "git status --short (?? marks new files git doesn't track yet, so the diff leaves them out: read them in full)", .argv = &.{ "git", "status", "--short" } },
        },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    var changed = false;
    for (cmds, 0..) |c, i| {
        const r = try std.process.run(a, ctx.io, .{ .argv = c.argv, .cwd = .{ .path = dir }, .stdout_limit = .limited(64 << 20) });
        const ok = r.term == .exited and r.term.exited == 0;
        try aw.writer.print("===== {s}\n\n{s}\n", .{ c.title, if (ok) r.stdout else r.stderr });
        // The diff, or (git) a file it doesn't track yet: new work too.
        if (ok and i == 1 and std.mem.trim(u8, r.stdout, " \n").len > 0) changed = true;
        if (ok and i == 2 and (std.mem.startsWith(u8, r.stdout, "?? ") or std.mem.indexOf(u8, r.stdout, "\n?? ") != null)) changed = true;
    }
    if (!changed) return error.NoChanges;
    return aw.written();
}

test changesText {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = a, .perm = a, .env = &env, .home = "/tmp" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const git = struct {
        fn run(c: Ctx, al: std.mem.Allocator, d: []const u8, args: []const []const u8) !void {
            const argv = try std.mem.concat(al, []const u8, &.{ &.{ "git", "-c", "user.name=t", "-c", "user.email=t@t" }, args });
            const r = try std.process.run(al, c.io, .{ .argv = argv, .cwd = .{ .path = d } });
            if (r.term != .exited or r.term.exited != 0) return error.SkipZigTest;
        }
    };
    git.run(ctx, a, dir, &.{ "init", "-q", "-b", "master" }) catch return error.SkipZigTest;
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "one\n" });
    try git.run(ctx, a, dir, &.{ "add", "." });
    try git.run(ctx, a, dir, &.{ "commit", "-qm", "init" });
    const base = std.mem.trim(u8, (try std.process.run(a, ctx.io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = .{ .path = dir } })).stdout, "\n");
    try std.testing.expectError(error.NoChanges, changesText(ctx, a, dir, base, .git));
    // Only a new file git doesn't track yet: still changes to review.
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "only.txt", .data = "x\n" });
    try std.testing.expect(std.mem.indexOf(u8, try changesText(ctx, a, dir, base, .git), "?? only.txt") != null);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "two\n" });
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "new.txt", .data = "x\n" });
    const text = try changesText(ctx, a, dir, base, .git);
    try std.testing.expect(std.mem.indexOf(u8, text, "+two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "?? new.txt") != null);
}

/// Where the reviewer writes its findings: <board dir>/autoreview/<KEY>.json.
pub fn findingsPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/autoreview/{s}.json", .{ try board.dirPath(ctx, a, cfg), key });
}

/// The reviewer's settings: its Stop hook, which takes the findings.
fn hookSettings(a: std.mem.Allocator, exe: []const u8, key: []const u8) ![]const u8 {
    const cmd = try std.fmt.allocPrint(a, "'{s}' ticket autoreview {s} --stop-hook", .{ exe, key });
    return std.fmt.allocPrint(a, "{{\"hooks\":{{\"Stop\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":{f}}}]}}]}}}}", .{std.json.fmt(cmd, .{})});
}

test hookSettings {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try hookSettings(a, "/x/cl", "QA-1"), .{});
    const h = v.object.get("hooks").?.object.get("Stop").?.array.items[0].object.get("hooks").?.array.items[0].object;
    try std.testing.expectEqualStrings("'/x/cl' ticket autoreview QA-1 --stop-hook", h.get("command").?.string);
}

/// Start a review of `t` in clrv_<key>. It runs on its own; the result
/// comes back through `submit`. Refused while one is running.
pub fn start(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !Review {
    if (t.stage != .review and t.stage != .testing) return error.NotInReview;
    const dir = try review.ticketDir(db, a, t);
    const rev = try worktree.reviewRev(ctx, a, dir, t.base, t.change);
    if (rev.len == 0) return error.NoChanges;
    const name = try sessionName(a, t.key);
    if (alive(ctx, a, name)) return error.AlreadyRunning;
    // One that already exited: start a fresh one.
    if (exists(ctx, a, name)) tmux.runQuiet(ctx, &.{ "kill-session", "-t", try exact(a, name) }) catch {};

    const p = try board.getProject(db, a, t.project);
    const prof = profileFor(cfg, t, p);
    const config_dir = prof.config_dir orelse try claude.defaultConfigDir(ctx, a);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try a.dupe(u8, try ctx.exePath(&exe_buf));
    const vcs: worktree.Vcs = worktree.detect(ctx, a, dir) catch .git;
    const findings = try findingsPath(ctx, a, cfg, t.key);
    // One per ticket, overwritten each run: what the reviewer reviews and is
    // told (both kept, so you can see them).
    const pdir = std.fs.path.dirname(findings).?;
    try std.Io.Dir.cwd().createDirPath(ctx.io, pdir);
    std.Io.Dir.cwd().deleteFile(ctx.io, findings) catch {};
    const changes = try std.fmt.allocPrint(a, "{s}/{s}.diff", .{ pdir, t.key });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = changes, .data = try changesText(ctx, a, dir, rev, vcs) });
    const text = try prompt(a, .{
        .ticket = t,
        .comments = try board.comments(db, a, t.id),
        .dir = dir,
        .changes = changes,
        .findings = findings,
        .skill = p.review_skill,
    });
    const pfile = try std.fmt.allocPrint(a, "{s}/{s}.md", .{ pdir, t.key });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = pfile, .data = text });

    var sid_buf: [36]u8 = undefined;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "new-session", "-d", "-s", name, "-c", dir });
    try argv.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "CLAUDE_CONFIG_DIR={s}", .{config_dir}) });
    // Not the ticket's session: cl's hooks (if the profile has any) leave it alone.
    try argv.appendSlice(a, &.{ "-e", "CL_TICKET=", "-e", try std.fmt.allocPrint(a, "CL_AUTOREVIEW={s}", .{t.key}) });
    if (ctx.tmux_socket) |s| try argv.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "{s}={s}", .{ tmux.socket_env, s }) });
    try argv.appendSlice(a, &.{ "--", "claude" });
    // Each tool list takes every argument up to the next option, so the
    // first message comes after --session-id's one value.
    try argv.appendSlice(a, &.{ "--allowedTools", try allowedTools(a, findings), "--disallowedTools", "NotebookEdit", "--permission-mode", "dontAsk" });
    try argv.appendSlice(a, &.{ "--settings", try hookSettings(a, exe, t.key) });
    if (cfg.review_model.len > 0) try argv.appendSlice(a, &.{ "--model", cfg.review_model });
    try argv.appendSlice(a, &.{ "--session-id", claude.uuid4(ctx, &sid_buf) });
    try argv.append(a, try std.fmt.allocPrint(a, "You are an automated code reviewer for ticket {s}. Read your instructions in {s} (all of it) and follow them.", .{ t.key, pfile }));
    tmux.runQuiet(ctx, argv.items) catch return error.StartFailed;
    tmux.runQuiet(ctx, &.{ "set-option", "-t", try exact(a, name), "remain-on-exit", "on" }) catch {};
    // A folder Claude hasn't seen under this profile asks whether to trust
    // it first, and nobody would answer. Its ticket's own session usually did
    // already; else the board's projects are trusted (board.trust_projects),
    // so a helper says yes, detached so this doesn't wait for Claude to start.
    if (cfg.board.trust_projects) spawnTrust(ctx, a, exe, t.key) catch {};

    const r: Review = .{ .status = "running", .started = ctx.nowSeconds(), .round = t.round, .rev = rev, .profile = prof.name, .skill = p.review_skill };
    try save(db, a, t.id, r);
    try board.logEvent(ctx, db, t.id, "autoreview started", prof.name);
    return r;
}

fn spawnTrust(ctx: Ctx, a: std.mem.Allocator, exe: []const u8, key: []const u8) !void {
    const r = try std.process.run(a, ctx.io, .{ .argv = &.{
        "sh", "-c", "exec setsid -f \"$@\" </dev/null >/dev/null 2>&1", "sh", exe, "ticket", "autoreview", key, "--accept-trust",
    } });
    if (r.term != .exited or r.term.exited != 0) return error.SpawnFailed;
}

/// The helper `start` runs: say yes to the folder-trust dialog if it shows
/// before Claude's prompt (it gives up after a minute).
pub fn acceptTrust(ctx: Ctx, a: std.mem.Allocator, key: []const u8) void {
    claude.waitForPrompt(ctx, exactPane(a, sessionName(a, key) catch return) catch return, true) catch {};
}

/// Kill the reviewer's session, if any.
pub fn killSession(ctx: Ctx, a: std.mem.Allocator, key: []const u8) !void {
    const name = try sessionName(a, key);
    if (exists(ctx, a, name)) try tmux.runQuiet(ctx, &.{ "kill-session", "-t", try exact(a, name) });
}

/// Stop a running review (`--stop`, the board's Stop): it is recorded as
/// failed, stopped.
pub fn stop(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    try killSession(ctx, a, t.key);
    var r = load(a, t) orelse return;
    if (!std.mem.eql(u8, r.status, "running")) return;
    _ = try fail(ctx, db, a, t, &r, "stopped");
}

/// Record it failed, if it is still running: `r` may have been read before
/// its findings came in, and those win. Unless you stopped it yourself, the
/// ticket is back in Needs You (`board.raiseAfterReview`), as when it
/// finishes. False when it had finished meanwhile (nothing changed).
fn fail(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket, r: *Review, why: []const u8) !bool {
    r.status = "failed";
    r.@"error" = why;
    r.finished = ctx.nowSeconds();
    if (!try board.setAutoreviewIfRunning(db, t.id, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r.*, .{})}))) return false;
    try board.logEvent(ctx, db, t.id, "autoreview failed", why);
    if (!std.mem.eql(u8, why, "stopped")) try board.raiseAfterReview(ctx, db, t.id, t.stage);
    return true;
}

/// The ticket's review as it stands: one recorded as running whose session
/// has ended without reporting, or that has run past `timeout_s`, is
/// recorded as failed (and stopped) first. The board's detail and the web
/// server's sweep call this.
pub fn check(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !?Review {
    var r = load(a, t) orelse return null;
    if (!std.mem.eql(u8, r.status, "running")) return r;
    const name = try sessionName(a, t.key);
    const now = state(ctx, a, name);
    // Can't tell: leave it be (a read-only look mustn't fail a live review).
    if (now == .unknown) return r;
    const failed = if (now == .gone)
        try fail(ctx, db, a, t, &r, "the reviewer's session ended before it reported its findings")
    else if (ctx.nowSeconds() - r.started > timeout_s) blk: {
        killSession(ctx, a, t.key) catch {};
        break :blk try fail(ctx, db, a, t, &r, try std.fmt.allocPrint(a, "timed out after {d} minutes", .{@divTrunc(timeout_s, 60)}));
    } else return r;
    // Its findings came in since `t` was read: they stand.
    if (!failed) return load(a, try board.getTicket(db, a, t.key));
    return r;
}

pub const Checked = struct { key: []const u8, review: Review };

/// `check` every review recorded as running, so one whose reviewer died or
/// ran too long doesn't keep its ticket out of Needs You (`board.isWorking`)
/// until someone opens it. The main `cl web` does it every minute; `cl
/// ticket needs` and `watch` do it too, for when it isn't running. The ones
/// it found failed.
pub fn checkAll(ctx: Ctx, db: board.Db, a: std.mem.Allocator) ![]const Checked {
    var out: std.ArrayList(Checked) = .empty;
    for (try board.listTickets(db, a, .{})) |t| {
        if (!board.reviewing(t)) continue;
        const r = (check(ctx, db, a, t) catch continue) orelse continue;
        if (std.mem.eql(u8, r.status, "failed")) try out.append(a, .{ .key = t.key, .review = r });
    }
    return out.items;
}

test "check: a reviewer that died is recorded as failed, but findings that came in since win; stop records stopped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Skip without tmux on PATH (the macOS CI runner has none): tmux that
    // can't run at all makes state() say .unknown, not .gone, so nothing
    // here would be recorded as failed.
    _ = std.process.run(a, std.testing.io, .{ .argv = &.{ "tmux", "-V" } }) catch return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(a);
    // A tmux socket where no server runs (never made: asking tmux doesn't
    // start one): no reviewer is alive here.
    var raw: [8]u8 = undefined;
    std.testing.io.random(&raw);
    const sock = try std.fmt.allocPrint(a, "/tmp/cl-test-noserver-{x}.sock", .{raw});
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = &env, .home = "/tmp", .tmux_socket = sock };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;

    // Its session is gone: failed, and the ticket is back with its flag.
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1 });
    const r = (try check(ctx, db, a, try board.getTicket(db, a, k))).?;
    try std.testing.expectEqualStrings("failed", r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.@"error", "ended before") != null);
    try std.testing.expectEqualStrings(board.flag_review, (try board.getTicket(db, a, k)).flags[0].kind);

    // Read while running; the findings land before check acts on it.
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1 });
    const stale = try board.getTicket(db, a, k);
    try save(db, a, id, .{ .status = "done", .started = 1, .round = 1, .summary = "Fine." });
    const got = (try check(ctx, db, a, stale)).?;
    try std.testing.expectEqualStrings("done", got.status);
    try std.testing.expectEqualStrings("Fine.", load(a, try board.getTicket(db, a, k)).?.summary);

    // Stopped by you: recorded, and no flag raised for it.
    try board.clearFlagId(ctx, db, id, board.flag_review);
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1 });
    try stop(ctx, db, a, k);
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqualStrings("stopped", load(a, t).?.@"error");
    try std.testing.expectEqual(@as(usize, 0), t.flags.len);

    // checkAll (cl ticket needs, watch): it is back in Needs You.
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1 });
    try std.testing.expectEqual(@as(usize, 0), (try board.listTickets(db, a, .{ .needs = true })).len);
    try std.testing.expectEqual(@as(usize, 1), (try checkAll(ctx, db, a)).len);
    try std.testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);

    // Findings that come in after it was stopped are dropped.
    try save(db, a, id, .{ .status = "failed", .@"error" = "stopped", .started = 1, .round = 1 });
    try std.testing.expectError(error.NotRunning, submit(ctx, db, a, k, "{\"summary\": \"late\", \"findings\": []}"));
    try std.testing.expectEqualStrings("stopped", load(a, try board.getTicket(db, a, k)).?.@"error");

    // tmux can't be asked (blocked): a running review is left as it is.
    var blocked = ctx;
    blocked.tmux_socket = null;
    blocked.tmux_blocked = true;
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1 });
    try std.testing.expectEqualStrings("running", (try check(blocked, db, a, try board.getTicket(db, a, k))).?.status);
}

// ---- the prompt ----

pub const PromptInput = struct {
    ticket: board.Ticket,
    comments: []const board.Comment = &.{},
    dir: []const u8,
    /// The file holding the changes (`changesText`).
    changes: []const u8,
    /// The file it writes its findings to (`findingsPath`).
    findings: []const u8,
    /// The project's review skill, "" for cl's own instructions.
    skill: []const u8 = "",
};

/// What the reviewer is told.
pub fn prompt(a: std.mem.Allocator, in: PromptInput) ![]const u8 {
    const t = in.ticket;
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print(
        \\You are reviewing another Claude session's work on ticket {s}, "{s}", before the human looks at it. You didn't write this code: read it with fresh eyes, and assume nothing works until you've seen that it does. Don't change any files; you can only read them.
        \\
        \\## What was asked
        \\
        \\{s}
        \\
    , .{ t.key, t.title, if (std.mem.trim(u8, t.body, " \n").len > 0) std.mem.trim(u8, t.body, " \n") else "(no description beyond the title)" });
    if (std.mem.trim(u8, t.plan_md, " \n").len > 0) try w.print("\n## The plan it was built from\n\n{s}\n", .{std.mem.trim(u8, t.plan_md, " \n")});
    var said = false;
    for (in.comments) |c| {
        if (!std.mem.eql(u8, c.author, "you")) continue;
        // An earlier review's findings, sent on: not what you asked for.
        if (std.mem.startsWith(u8, c.body, message_lead)) continue;
        if (!said) try w.writeAll("\n## What the human said along the way (it counts as part of what was asked)\n\n");
        said = true;
        try w.print("- {s}\n", .{std.mem.trim(u8, c.body, " \n")});
    }
    if (std.mem.trim(u8, t.summary, " \n").len > 0) try w.print("\n## What the author says it did\n\n{s}\n", .{std.mem.trim(u8, t.summary, " \n")});
    try w.print("\n## The changes\n\nThey are in {s}: their descriptions, then the diff, as of when this review started. Read all of it (in parts if it is long). The code is in {s}; read the changed files in full wherever you need the context around a change. You have no shell here, only the Read, Grep and Glob tools (and Write, for your findings).\n\n", .{ in.changes, in.dir });
    if (in.skill.len > 0) {
        try w.print("## How to review\n\nUse the `{s}` skill to review these changes against what was asked. When it is done, report what it found as below: one finding per problem it raised. Don't wait for anyone to answer questions; nobody is watching this session.\n", .{in.skill});
    } else try w.writeAll(
        \\## What to look for
        \\
        \\1. Bugs: wrong logic, edge cases, error handling, races, leaks, security problems. These matter most.
        \\2. Gaps against what was asked: something asked for that is missing or half done, or something done that wasn't asked for.
        \\3. Breaches of the repository's documented standards: its CLAUDE.md, AGENTS.md or CONTRIBUTING.md, where it has them.
        \\4. New behavior without tests, where the repository has tests.
        \\
        \\Check each finding by reading the code before you report it, and leave out anything you can't back up. No style nits a formatter or linter would catch. At most 15 findings, the most severe first. No findings at all is a fine answer when the work is sound.
        \\
    );
    try w.print(
        \\
        \\## Reporting
        \\
        \\When you're done, write your findings with the Write tool to {s} (the only file you can write), as one JSON object:
        \\
        \\{{"summary": "...", "findings": [{{"path": "src/x.zig", "line": 120, "end_line": 124, "severity": "high", "category": "correctness", "title": "...", "body": "..."}}]}}
        \\
        \\- summary: a short paragraph, your overall verdict.
        \\- severity: high (a real bug, or something asked for that isn't done), medium (likely a problem, or a gap worth fixing) or low (minor).
        \\- category: correctness, spec, standards, tests or other.
        \\- title: one line. body: what is wrong, why it matters, and the fix you suggest (markdown is fine).
        \\- path and line: the file (relative to {s}) and the line in its current version; end_line when it spans several lines. Leave all three out for a finding about the change as a whole.
        \\
        \\Then stop: cl reads the file when you finish. If it can't, you're told why; fix the file and stop again. Once it has your findings, cl closes this session.
        \\
    , .{ in.findings, in.dir });
    return aw.written();
}

test prompt {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: board.Ticket = .{ .id = 1, .key = "QA-7", .project = "qa", .title = "Retry uploads", .body = "Retry failed uploads 3 times.", .stage = .review, .mode = .worktree, .plan = false, .skill = "", .target = "", .worktree = "/w", .branch = "", .profile = "", .tmux = "", .session_id = "", .summary = "Added a retry loop.", .round = 2, .created = 0, .updated = 0, .parent = "", .children = 0 };
    t.plan_md = "# Plan\nWrap upload() in a loop.";
    const cs = [_]board.Comment{
        .{ .author = "you", .body = "Also log each retry.", .sent = true, .at = 0 },
        .{ .author = "claude", .body = "Done.", .sent = false, .at = 0 },
        .{ .author = "you", .body = try message(a, .{ .status = "done", .summary = "Earlier verdict.", .findings = &.{} }), .sent = true, .at = 0 },
    };
    const text = try prompt(a, .{ .ticket = t, .comments = &cs, .dir = "/w", .changes = "/s/autoreview/QA-7.diff", .findings = "/s/autoreview/QA-7.json" });
    for ([_][]const u8{ "QA-7", "Retry failed uploads 3 times.", "Wrap upload() in a loop.", "Also log each retry.", "Added a retry loop.", "They are in /s/autoreview/QA-7.diff", "What to look for", "with the Write tool to /s/autoreview/QA-7.json" }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing: {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
    // Claude's own comments aren't what was asked, nor an earlier review's findings you sent on.
    try std.testing.expect(std.mem.indexOf(u8, text, "Done.") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Earlier verdict.") == null);
    const git = try prompt(a, .{ .ticket = t, .dir = "/w", .changes = "/s/d", .findings = "/s/f.json", .skill = "code-review" });
    try std.testing.expect(std.mem.indexOf(u8, git, "Use the `code-review` skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, git, "What to look for") == null);
}

// ---- the result ----

const max_findings = 50;

var last_error_buf: [512]u8 = undefined;
var last_error_len: usize = 0;

/// Why the last findings were refused.
pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

fn bad(comptime fmt: []const u8, args: anytype) error{BadFindings} {
    const s = std.fmt.bufPrint(&last_error_buf, fmt, args) catch last_error_buf[0..];
    last_error_len = s.len;
    return error.BadFindings;
}

/// The reviewer's JSON as it may come: a missing or null field is fine.
const RawFinding = struct {
    path: ?[]const u8 = null,
    line: ?i64 = null,
    end_line: ?i64 = null,
    severity: ?[]const u8 = null,
    category: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
};
const Raw = struct {
    summary: ?[]const u8 = null,
    findings: ?[]const RawFinding = null,
};

/// Read the reviewer's findings: `{"summary", "findings": [...]}`, also
/// inside a ```json fence. Severities other than high, medium and low read
/// as medium; paths are made relative to `dir`; the most severe come first.
pub fn parseFindings(a: std.mem.Allocator, input: []const u8, dir: []const u8) error{ BadFindings, OutOfMemory }!struct { summary: []const u8, findings: []const Finding } {
    var text = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, text, "```")) {
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return bad("empty ``` block", .{});
        const end = std.mem.lastIndexOf(u8, text, "```") orelse text.len;
        text = std.mem.trim(u8, text[nl + 1 .. if (end > nl) end else text.len], " \t\r\n");
    }
    if (text.len == 0) return bad("no JSON on stdin", .{});
    const raw = std.json.parseFromSliceLeaky(Raw, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e|
        return bad("not the JSON asked for ({s}): it is one object, {{\"summary\": \"...\", \"findings\": [...]}}", .{@errorName(e)});
    const items = raw.findings orelse return bad("\"findings\" is missing (use [] for none)", .{});
    if (items.len > max_findings) return bad("{d} findings is too many: keep the {d} that matter most", .{ items.len, max_findings });
    var out: std.ArrayList(Finding) = .empty;
    for (items, 1..) |f, i| {
        const title = std.mem.trim(u8, f.title orelse "", " \n");
        const body = std.mem.trim(u8, f.body orelse "", " \n");
        if (title.len == 0 and body.len == 0) return bad("finding {d} has no title or body", .{i});
        var path = std.mem.trim(u8, f.path orelse "", " ");
        if (dir.len > 0 and std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/') path = path[dir.len + 1 ..];
        while (std.mem.startsWith(u8, path, "./")) path = path[2..];
        const line = @max(f.line orelse 0, 0);
        const end_line = @max(f.end_line orelse 0, 0);
        try out.append(a, .{
            .path = path,
            .line = if (path.len > 0) line else 0,
            .end_line = if (path.len > 0 and line > 0 and end_line > line) end_line else 0,
            .severity = severity(f.severity orelse ""),
            .category = try std.ascii.allocLowerString(a, std.mem.trim(u8, f.category orelse "", " ")),
            .title = if (title.len > 0) title else firstLine(body),
            .body = body,
        });
    }
    std.mem.sort(Finding, out.items, {}, struct {
        fn lt(_: void, x: Finding, y: Finding) bool {
            return rank(x.severity) < rank(y.severity);
        }
    }.lt);
    return .{ .summary = std.mem.trim(u8, raw.summary orelse "", " \n"), .findings = out.items };
}

fn severity(s: []const u8) []const u8 {
    for ([_][]const u8{ "high", "medium", "low" }) |x| if (std.ascii.eqlIgnoreCase(s, x)) return x;
    for ([_][]const u8{ "critical", "blocking", "major", "error" }) |x| if (std.ascii.eqlIgnoreCase(s, x)) return "high";
    for ([_][]const u8{ "minor", "nit", "nitpick", "suggestion", "info" }) |x| if (std.ascii.eqlIgnoreCase(s, x)) return "low";
    return "medium";
}

fn rank(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "high")) return 0;
    if (std.mem.eql(u8, s, "medium")) return 1;
    return 2;
}

fn firstLine(s: []const u8) []const u8 {
    const l = std.mem.sliceTo(s, '\n');
    return l[0..@min(l.len, 100)];
}

test parseFindings {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseFindings(a,
        \\```json
        \\{"summary": "Mostly fine.", "findings": [
        \\  {"path": "/w/src/a.zig", "line": 3, "severity": "low", "title": "Nit", "body": "x"},
        \\  {"path": "./src/b.zig", "line": 10, "end_line": 12, "severity": "HIGH", "title": "Crash", "body": "y", "category": "Correctness"},
        \\  {"path": null, "line": null, "severity": "weird", "title": "", "body": "No tests at all.\nMore."}
        \\]}
        \\```
    , "/w");
    try std.testing.expectEqualStrings("Mostly fine.", r.summary);
    try std.testing.expectEqual(@as(usize, 3), r.findings.len);
    try std.testing.expectEqualStrings("Crash", r.findings[0].title);
    try std.testing.expectEqualStrings("src/b.zig", r.findings[0].path);
    try std.testing.expectEqual(@as(i64, 12), r.findings[0].end_line);
    try std.testing.expectEqualStrings("correctness", r.findings[0].category);
    try std.testing.expectEqualStrings("medium", r.findings[1].severity);
    try std.testing.expectEqualStrings("No tests at all.", r.findings[1].title);
    try std.testing.expectEqualStrings("", r.findings[1].path);
    try std.testing.expectEqualStrings("src/a.zig", r.findings[2].path);
    // None is a fine answer.
    try std.testing.expectEqual(@as(usize, 0), (try parseFindings(a, "{\"summary\": \"Good.\", \"findings\": []}", "/w")).findings.len);
    try std.testing.expectError(error.BadFindings, parseFindings(a, "Looks good to me!", "/w"));
    try std.testing.expectError(error.BadFindings, parseFindings(a, "{\"summary\": \"x\"}", "/w"));
    try std.testing.expect(std.mem.indexOf(u8, lastError(), "findings") != null);
    try std.testing.expectError(error.BadFindings, parseFindings(a, "{\"findings\": [{\"path\": \"a\"}]}", "/w"));
}

/// The reviewer's report (`--findings -`): kept on the ticket as done.
pub fn submit(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, input: []const u8) !Review {
    const t = try board.getTicket(db, a, key);
    const dir = review.ticketDir(db, a, t) catch "";
    const got = try parseFindings(a, input, dir);
    var r = load(a, t) orelse Review{ .started = ctx.nowSeconds(), .round = t.round };
    r.status = "done";
    r.finished = ctx.nowSeconds();
    r.summary = got.summary;
    r.findings = got.findings;
    r.@"error" = "";
    r.sent = 0;
    // Only while it runs: stopped or timed out meanwhile, that stands.
    if (!try board.setAutoreviewIfRunning(db, t.id, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})}))) return error.NotRunning;
    try board.logEvent(ctx, db, t.id, "autoreview done", try std.fmt.allocPrint(a, "{d} finding{s}", .{ got.findings.len, if (got.findings.len == 1) "" else "s" }));
    // Out of Needs You while it ran (board.isWorking): back now.
    try board.raiseAfterReview(ctx, db, t.id, t.stage);
    return r;
}

/// What the Stop hook does with the reviewer's turn.
pub const HookResult = union(enum) {
    /// The findings are kept; close the session.
    done: Review,
    /// Send it back with this, to fix the file (or write it).
    retry: []const u8,
    /// Gave up (recorded as failed); close the session.
    failed,
    /// Not a review cl is waiting for (stopped, or already done).
    ignore,
};

/// The reviewer stopped (its Stop hook, `--stop-hook`): take the findings
/// file. Missing or wrong, it is sent back once (`again`, the hook's
/// stop_hook_active, says it already was); then the review fails.
pub fn stopHook(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, again: bool) !HookResult {
    const t = try board.getTicket(db, a, key);
    var r = load(a, t) orelse return .ignore;
    if (!std.mem.eql(u8, r.status, "running")) return .ignore;
    const path = try findingsPath(ctx, a, cfg, t.key);
    const why: []const u8 = if (std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20))) |text|
        if (submit(ctx, db, a, t.key, text)) |done| return .{ .done = done } else |e| switch (e) {
            // Stopped or timed out since it was read above.
            error.NotRunning => return .ignore,
            error.BadFindings => try std.fmt.allocPrint(a, "cl couldn't take the findings in {s}: {s}. Fix the file with the Write tool, then stop again.", .{ path, lastError() }),
            else => return e,
        }
    else |_| try std.fmt.allocPrint(a, "You haven't written your findings yet. Write them as JSON to {s} with the Write tool (see \"Reporting\" above), then stop.", .{path});
    if (!again) return .{ .retry = why };
    if (!try fail(ctx, db, a, t, &r, try std.fmt.allocPrint(a, "the reviewer stopped without findings cl could read: {s}", .{std.mem.sliceTo(why, '.')}))) return .ignore;
    return .failed;
}

test stopHook {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = &env, .home = "/tmp", .tmux_blocked = true };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    cfg.board.dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = cfg.board.dir });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;
    // No review running: nothing to do.
    try std.testing.expect(try stopHook(ctx, cfg, db, a, k, false) == .ignore);
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1, .profile = "work" });
    // No file yet: sent back to write it.
    const r1 = try stopHook(ctx, cfg, db, a, k, false);
    try std.testing.expect(std.mem.indexOf(u8, r1.retry, "haven't written") != null);
    // Wrong JSON: sent back with why.
    const path = try findingsPath(ctx, a, cfg, k);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = "{\"summary\": \"x\"}" });
    try std.testing.expect(std.mem.indexOf(u8, (try stopHook(ctx, cfg, db, a, k, false)).retry, "findings") != null);
    // Still wrong the second time: failed.
    try std.testing.expect(try stopHook(ctx, cfg, db, a, k, true) == .failed);
    try std.testing.expectEqualStrings("failed", load(a, try board.getTicket(db, a, k)).?.status);
    // Right: kept, with the profile it ran under.
    try save(db, a, id, .{ .status = "running", .started = 1, .round = 1, .profile = "work" });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = "{\"summary\": \"Fine.\", \"findings\": []}" });
    const r = (try stopHook(ctx, cfg, db, a, k, false)).done;
    try std.testing.expectEqualStrings("done", r.status);
    try std.testing.expectEqualStrings("work", r.profile);
    try std.testing.expectEqualStrings("Fine.", load(a, try board.getTicket(db, a, k)).?.summary);
}

// ---- what the findings become ----

fn where(a: std.mem.Allocator, f: Finding) ![]const u8 {
    if (f.path.len == 0) return "";
    if (f.line == 0) return f.path;
    if (f.end_line > f.line) return std.fmt.allocPrint(a, "{s}:{d}-{d}", .{ f.path, f.line, f.end_line });
    return std.fmt.allocPrint(a, "{s}:{d}", .{ f.path, f.line });
}

/// How `message` starts. Sent, it is kept as your comment (so the ticket
/// goes back for a round, as any you send does); `prompt` leaves such
/// comments out, so a later review isn't told an earlier one's findings are
/// what you asked for.
pub const message_lead = "An automated review (a separate Claude that read your changes)";

/// `message`'s first line: what Claude is to do with the findings.
pub const message_intro = message_lead ++ " found the problems below. Check each one against the code: fix what's real, say which you disagree with and why, then finish the same way as before.";

/// What the ticket's session is sent ("Send findings to Claude"): your
/// edit of it when you made one (`edit`).
pub fn message(a: std.mem.Allocator, r: Review) ![]const u8 {
    if (r.edited.len > 0) return r.edited;
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("{s}\n", .{message_intro});
    if (r.summary.len > 0) try w.print("\nIts verdict: {s}\n", .{r.summary});
    for (r.findings, 1..) |f, i| {
        const at = try where(a, f);
        try w.print("\n{d}. [{s}] {s}{s}{s}{s}\n", .{ i, f.severity, f.title, if (at.len > 0) " (" else "", at, if (at.len > 0) ")" else "" });
        var lines = std.mem.splitScalar(u8, f.body, '\n');
        while (lines.next()) |l| try w.print("   {s}\n", .{l});
    }
    return aw.written();
}

test message {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fs = [_]Finding{
        .{ .path = "src/a.zig", .line = 3, .end_line = 5, .severity = "high", .title = "Crash", .body = "It crashes.\nFix: check null." },
        .{ .severity = "low", .title = "No tests", .body = "Add one." },
    };
    const text = try message(a, .{ .status = "done", .summary = "Two problems.", .findings = &fs });
    try std.testing.expect(std.mem.indexOf(u8, text, "finish the same way as before") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Its verdict: Two problems.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1. [high] Crash (src/a.zig:3-5)\n   It crashes.\n   Fix: check null.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2. [low] No tests\n   Add one.\n") != null);
    try std.testing.expectEqualStrings("Only fix the crash.", try message(a, .{ .status = "done", .findings = &fs, .edited = "Only fix the crash." }));
}

/// Whether `r` has something to send or open: findings, or your edit.
pub fn usable(r: Review) bool {
    return std.mem.eql(u8, r.status, "done") and (r.findings.len > 0 or r.edited.len > 0);
}

/// Keep your edit of the message the findings are sent as ("" goes back to
/// the findings as they came). Only a finished review of the current round.
/// `base` is the message the edit started from: error.EditConflict when it
/// is something else now (the review ran again, or it was edited
/// elsewhere), so your edit isn't put on findings you haven't seen.
pub fn edit(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, text: []const u8, base: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    var r = load(a, t) orelse return error.NoFindings;
    if (!std.mem.eql(u8, r.status, "done")) return error.NoFindings;
    if (!current(r, t)) return error.OldFindings;
    if (!std.mem.eql(u8, std.mem.trim(u8, base, " \t\r\n"), std.mem.trim(u8, try message(a, r), " \t\r\n"))) return error.EditConflict;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    r.edited = "";
    const original = std.mem.trim(u8, try message(a, r), " \t\r\n");
    // Emptied, or saved as the findings read: nothing of yours to keep.
    if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, original)) r.edited = trimmed;
    // Not if it changed meanwhile (a new review started, or it was sent).
    if (!try board.setAutoreviewIf(db, t.id, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})}), t.autoreview)) return error.EditConflict;
    try board.logEvent(ctx, db, t.id, if (r.edited.len > 0) "autoreview edited" else "autoreview edit dropped", "");
}

test edit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = a, .env = undefined, .home = "/tmp" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;
    try board.setAutoreview(db, id, "{\"status\":\"running\",\"round\":1}");
    try std.testing.expectError(error.NoFindings, edit(ctx, db, a, k, "x", ""));
    try board.setAutoreview(db, id, "{\"status\":\"done\",\"round\":1,\"findings\":[]}");
    const first = try message(a, load(a, try board.getTicket(db, a, k)).?);
    // Started from another review's message (it ran again meanwhile): refused.
    try std.testing.expectError(error.EditConflict, edit(ctx, db, a, k, "x", "An older review's findings"));
    try edit(ctx, db, a, k, "  Please also add a test.\n", first);
    const r = load(a, try board.getTicket(db, a, k)).?;
    try std.testing.expectEqualStrings("Please also add a test.", r.edited);
    try std.testing.expect(usable(r));
    try std.testing.expectEqualStrings("Please also add a test.", try message(a, r));
    // Emptied, or saved as the findings already read: back to them.
    try edit(ctx, db, a, k, "", "Please also add a test.");
    try std.testing.expectEqualStrings("", load(a, try board.getTicket(db, a, k)).?.edited);
    try std.testing.expect(!usable(load(a, try board.getTicket(db, a, k)).?));
    // From an earlier round: no.
    try db.exec("UPDATE tickets SET round = 2 WHERE id = ?1", .{id});
    try std.testing.expectError(error.OldFindings, edit(ctx, db, a, k, "y", first));
}

/// gutter's -severity names (shown only when gutter runs with -severity).
fn gutterSeverity(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "high")) return "BLOCKING";
    if (std.mem.eql(u8, s, "medium")) return "IMPORTANT";
    return "SUGGESTION";
}

/// gutter's draft file (`<output>.draft.json`, which it restores when its
/// `key` is the -r it was started with) holding the findings: those with a
/// file as inline comments, the rest with the summary in the overall note.
pub fn gutterDraft(a: std.mem.Allocator, rev: []const u8, r: Review) ![]const u8 {
    const Comment = struct { path: []const u8, side: []const u8 = "new", line: i64, end_line: i64 = 0, snippet: []const u8 = "", body: []const u8, severity: []const u8 };
    var comments: std.ArrayList(Comment) = .empty;
    var general: std.Io.Writer.Allocating = .init(a);
    // Your edit is one text: it goes in whole as the overall note, without
    // the intro telling Claude what to do (gutter wraps the note as your review).
    if (r.edited.len > 0) {
        const note = if (std.mem.startsWith(u8, r.edited, message_intro)) std.mem.trimStart(u8, r.edited[message_intro.len..], " \t\r\n") else r.edited;
        return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .key = rev, .general = note, .comments = comments.items }, .{ .whitespace = .indent_2 })});
    }
    try general.writer.print("Automated review: {s}", .{if (r.summary.len > 0) r.summary else "(no summary)"});
    for (r.findings) |f| {
        const body = try std.fmt.allocPrint(a, "**[{s}] {s}**\n\n{s}", .{ f.severity, f.title, f.body });
        if (f.path.len == 0) {
            try general.writer.print("\n\n{s}", .{body});
            continue;
        }
        try comments.append(a, .{ .path = f.path, .line = @max(f.line, 1), .end_line = f.end_line, .body = body, .severity = gutterSeverity(f.severity) });
    }
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .key = rev, .general = general.written(), .comments = comments.items }, .{ .whitespace = .indent_2 })});
}

test gutterDraft {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fs = [_]Finding{
        .{ .path = "src/a.zig", .line = 3, .end_line = 5, .severity = "high", .title = "Crash", .body = "It crashes." },
        .{ .severity = "low", .title = "No tests", .body = "Add one." },
    };
    const json = try gutterDraft(a, "abc::", .{ .status = "done", .summary = "Two problems.", .findings = &fs });
    const D = struct {
        key: []const u8,
        general: []const u8,
        comments: []const struct { path: []const u8, side: []const u8, line: i64, end_line: i64, body: []const u8 },
    };
    const d = try std.json.parseFromSliceLeaky(D, a, json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("abc::", d.key);
    try std.testing.expectEqual(@as(usize, 1), d.comments.len);
    try std.testing.expectEqualStrings("src/a.zig", d.comments[0].path);
    try std.testing.expectEqualStrings("new", d.comments[0].side);
    try std.testing.expectEqual(@as(i64, 5), d.comments[0].end_line);
    try std.testing.expectEqualStrings("**[high] Crash**\n\nIt crashes.", d.comments[0].body);
    try std.testing.expect(std.mem.startsWith(u8, d.general, "Automated review: Two problems."));
    try std.testing.expect(std.mem.indexOf(u8, d.general, "**[low] No tests**\n\nAdd one.") != null);
    // Your edit goes in whole as the overall note, with no inline comments,
    // and without the intro addressed to Claude.
    for ([_][]const u8{ "Only fix the crash.", message_intro ++ "\n\nOnly fix the crash." }) |edited| {
        const e = try std.json.parseFromSliceLeaky(D, a, try gutterDraft(a, "abc::", .{ .status = "done", .findings = &fs, .edited = edited }), .{ .ignore_unknown_fields = true });
        try std.testing.expectEqualStrings("Only fix the crash.", e.general);
        try std.testing.expectEqual(@as(usize, 0), e.comments.len);
    }
}

pub const DraftResult = enum {
    /// The draft is written: gutter opens with the findings.
    written,
    /// A draft of your own for these changes was there already: it is kept,
    /// and gutter opens with it instead.
    kept,
};

/// Open gutter on the ticket with the findings as its draft review
/// ("Open in gutter with findings"). Not when gutter is open already: it
/// reads a draft only as it starts.
pub fn openInGutter(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !struct { port: u16, draft: DraftResult } {
    const r = load(a, t) orelse return error.NoFindings;
    if (!usable(r)) return error.NoFindings;
    if (!current(r, t)) return error.OldFindings;
    if (try review.gutterPort(ctx, a, t.key) != null) return error.GutterOpen;
    const dir = try review.ticketDir(db, a, t);
    const rev = try worktree.reviewRev(ctx, a, dir, t.base, t.change);
    const copy = try std.fmt.allocPrint(a, "{s}/autoreview/{s}.draft.json", .{ try board.dirPath(ctx, a, cfg), t.key });
    const res = try writeDraft(ctx, a, dir, rev, r, copy);
    return .{ .port = try review.startGutter(ctx, cfg, db, a, t), .draft = res };
}

/// Write the draft unless one of yours for the same changes is there (gutter
/// keeps an unsent review in it). One that is still exactly what cl last
/// wrote (`copy` keeps that) isn't yours: you opened it and closed gutter
/// without changing it, so newer findings replace it.
fn writeDraft(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, rev: []const u8, r: Review, copy: []const u8) !DraftResult {
    const path = try review.draftPath(a, dir);
    if (std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(4 << 20))) |old| {
        const ours = std.Io.Dir.cwd().readFileAlloc(ctx.io, copy, a, .limited(4 << 20)) catch "";
        const D = struct { key: []const u8 = "", general: []const u8 = "", comments: []const std.json.Value = &.{} };
        if (!std.mem.eql(u8, old, ours)) if (std.json.parseFromSliceLeaky(D, a, old, .{ .ignore_unknown_fields = true })) |d| {
            if (std.mem.eql(u8, d.key, rev) and (d.comments.len > 0 or std.mem.trim(u8, d.general, " \n").len > 0)) return .kept;
        } else |_| {};
    } else |_| {}
    const data = try gutterDraft(a, rev, r);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(copy).?);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = copy, .data = data });
    return .written;
}

test writeDraft {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = a, .perm = a, .env = &env, .home = "/tmp" };
    const dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const copy = try std.fmt.allocPrint(a, "{s}/state/QA-1.draft.json", .{dir});
    const r: Review = .{ .status = "done", .summary = "S", .findings = &.{.{ .path = "a", .line = 1, .title = "T", .body = "B" }} };
    try std.testing.expectEqual(DraftResult.written, try writeDraft(ctx, a, dir, "abc::", r, copy));
    // Left as cl wrote it (gutter closed without a change): Run again's
    // findings replace it.
    const path = try review.draftPath(a, dir);
    const again: Review = .{ .status = "done", .summary = "Newer", .findings = r.findings };
    try std.testing.expectEqual(DraftResult.written, try writeDraft(ctx, a, dir, "abc::", again, copy));
    try std.testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20)), "Newer") != null);
    // Your own draft for the same changes is kept...
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = "{\"key\": \"abc::\", \"general\": \"mine\", \"comments\": []}" });
    try std.testing.expectEqual(DraftResult.kept, try writeDraft(ctx, a, dir, "abc::", r, copy));
    try std.testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20)), "mine") != null);
    // ...one for other changes isn't.
    try std.testing.expectEqual(DraftResult.written, try writeDraft(ctx, a, dir, "def::", r, copy));
}
