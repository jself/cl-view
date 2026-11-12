//! The board in `cl web`: the /board page and its JSON API. Every action is
//! the same code `cl ticket` runs (board.zig, actions.zig, dispatch.zig,
//! review.zig), so the two always agree.
//!
//!   GET  /board                         the page
//!   GET  /api/board                     projects, tickets, sessions, profiles
//!   GET  /api/needs                     what is in Needs You, as ids (cl-window's attention check)
//!   GET  /api/ticket/<key>              one ticket in full (+ session tail, review, test plan)
//!   POST /api/ticket                    new ticket
//!   POST /api/image/<key|new>           upload an image (the raw bytes) for a ticket's description
//!   GET  /api/image/<key|new>/<file>    one such image
//!   POST /api/ticket/<key>/<action>     edit move rank comment flag unflag dismiss done approve
//!                                       start answer key kill hide unhide rm cleanup gutter
//!                                       gutter-stop launch launch-stop test-progress
//!                                       test-results relocate park unpark autoreview
//!                                       autoreview-stop autoreview-send autoreview-gutter snooze
//!                                       autoreview-edit plan
//!   POST /api/flags/dismiss             dismiss one kind of flag on several tickets
//!   POST /api/needs/act                 a notification's button: {item, action} (push.act)
//!   POST /api/alert/<tmux>/dismiss      clear a session's alert (cl alert)
//!   POST /api/project                   add a project
//!   POST /api/project/<name>/<action>   set rm hide unhide after-merge push
//!   GET  /api/push                      push notifications: the key, devices, settings
//!   POST /api/push/<action>             subscribe settings device remove test
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const board = @import("board.zig");
const actions = @import("actions.zig");
const dispatch = @import("dispatch.zig");
const review = @import("review.zig");
const autoreview = @import("autoreview.zig");
const worktree = @import("worktree.zig");
const web = @import("web.zig");
const operator = @import("operator.zig");
const after_merge = @import("after_merge.zig");
const ci = @import("ci.zig");
const park = @import("park.zig");
const drift = @import("drift.zig");
const images = @import("images.zig");
const alerts = @import("alerts.zig");
const voice = @import("voice.zig");
const ticket_watch = @import("ticket_watch.zig");
const push = @import("push.zig");
const when = @import("when.zig");

const board_html = @embedFile("web/board.html");

/// Which board page this server serves: an open board whose page came from
/// another build (cl was rebuilt and restarted under it) offers a reload.
fn buildId(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{x:0>16}", .{std.hash.Wyhash.hash(0, board_html)});
}

/// Revalidated every time rather than no-store: a page that fetched a
/// no-store response can't go in the browser's back/forward cache, and the
/// board should (see `web.respondPage`). The page asks with cache: "no-store"
/// anyway, so it never gets an old answer.
const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "private, no-cache" },
};

/// Handle /board and /api/*; false when the path is someone else's.
pub fn handle(ctx: Ctx, cfg: config.Config, req: *std.http.Server.Request, path: []const u8, authed: bool) !bool {
    const is_api = std.mem.startsWith(u8, path, "/api/");
    if (!is_api and !std.mem.eql(u8, path, "/board")) return false;
    if (!authed) {
        if (is_api) {
            try req.respond("{\"error\":\"log in first\"}", .{ .status = .unauthorized, .extra_headers = &json_headers });
        } else {
            // Back here after signing in: a notification's link keeps its ticket.
            const location = try web.loginLocation(ctx.gpa, req.head.target);
            defer ctx.gpa.free(location);
            try req.respond("", .{ .status = .see_other, .extra_headers = &.{.{ .name = "location", .value = location }} });
        }
        return true;
    }
    if (!is_api) {
        const page = try web.withFontSize(ctx.gpa, board_html, cfg.web.font_size);
        defer ctx.gpa.free(page);
        try web.respondPage(req, page);
        return true;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = board.open(ctx, cfg) catch {
        try fail(req, .internal_server_error, "cannot open the board database");
        return true;
    };
    defer db.close();

    const post = req.head.method == .POST;
    if (post and !web.sameOrigin(req)) {
        try fail(req, .forbidden, "cross-site request refused");
        return true;
    }
    var parts = std.mem.splitScalar(u8, path["/api/".len..], '/');
    const what = parts.next() orelse "";
    // The page escapes names (encodeURIComponent): a project may be called "scratch 2".
    const name = std.Uri.percentDecodeInPlace(try a.dupe(u8, parts.next() orelse ""));
    const action = parts.next() orelse "";

    // An image's bytes, not JSON.
    if (post and std.mem.eql(u8, what, "image")) {
        uploadImage(ctx, cfg, db, a, req, name) catch |err| switch (err) {
            error.TooBig => try fail(req, .payload_too_large, "an image can be up to 10 MB"),
            error.BadInput => try fail(req, .bad_request, "only png, jpeg, gif and webp images"),
            error.NotFound => try fail(req, .not_found, "no such ticket"),
            else => try fail(req, .internal_server_error, @errorName(err)),
        };
        return true;
    }

    // Voice: the request body is a WAV recording, not JSON.
    if (post and std.mem.eql(u8, what, "voice") and std.mem.eql(u8, name, "ask")) {
        voiceAsk(ctx, cfg, a, req) catch |err| try fail(req, voiceStatus(err), try voiceDetail(a, err, "voice.stt"));
        return true;
    }
    if (post and std.mem.eql(u8, what, "voice") and std.mem.eql(u8, name, "text")) {
        voiceText(ctx, cfg, a, req) catch |err| try fail(req, voiceStatus(err), try voiceDetail(a, err, "voice.stt"));
        return true;
    }

    // Push notifications: bodies of their own.
    if (std.mem.eql(u8, what, "push")) {
        pushApi(ctx, cfg, db, a, req, post, name) catch |err| switch (err) {
            error.NotFound => try fail(req, .not_found, "no such device"),
            error.BadInput => try fail(req, .bad_request, "that isn't a push subscription or setting cl can use"),
            // The board unsubscribes the browser when it hears this.
            error.Removed => try fail(req, .gone, "this device was removed from notifications; turn them on again here to bring it back"),
            error.Refused, error.Gone => try fail(req, .bad_gateway, push.lastError()),
            error.Sqlite => try fail(req, .internal_server_error, db.message()),
            else => try fail(req, .internal_server_error, @errorName(err)),
        };
        return true;
    }

    const body: Body = if (post) readBody(req, a) catch {
        try fail(req, .bad_request, "the request body isn't valid JSON");
        return true;
    } else .{};

    route(ctx, cfg, db, a, req, post, what, name, action, body) catch |err| {
        const status: std.http.Status, const msg: []const u8 = switch (err) {
            error.NotFound => .{ .not_found, "no such ticket or project" },
            error.Exists => .{ .conflict, "already exists, or still in use" },
            error.Cycle => .{ .conflict, "that would make tickets wait on each other in a circle (or on itself), so none would start" },
            error.BadInput => .{ .bad_request, "invalid input" },
            error.BadWhen => .{ .bad_request, "not a date I know: " ++ when.forms },
            error.NoSuchDir => .{ .bad_request, "no such directory" },
            error.NoSession => .{ .conflict, "the ticket has no live session" },
            error.CustomClose => .{ .conflict, "Claude asked to close it its own way; tell Claude, or just close it" },
            error.NoSuchBranch => .{ .bad_request, "the project's repo has no branch or bookmark by that name (create it first)" },
            error.WaitingFlag => .{ .bad_request, "that flag is waiting on you (a question, a prompt, a review, a test or a conflict); answer it or act on the ticket instead" },
            error.NothingAsked => .{ .conflict, "nothing is waiting for an answer" },
            error.Handled => .{ .conflict, "that's been dealt with already" },
            error.BadAction => .{ .bad_request, "that button doesn't fit where it stands now; open it on the board" },
            error.BadAnswer => .{ .bad_request, "one answer per question: an option number or your own words (several numbers for a multi-select one)" },
            error.GutterFailed => .{ .internal_server_error, "gutter didn't start" },
            error.GutterMissing => .{ .conflict, review.not_installed },
            error.GutterOpen => .{ .conflict, "gutter is open already: close it first, then open it with the findings" },
            error.NotInReview => .{ .conflict, "only a ticket in testing or review gets an automated review (the project's own runs as Claude finishes)" },
            error.NoChanges => .{ .conflict, "it has no changes to review" },
            error.AlreadyRunning => .{ .conflict, "its automated review is running already" },
            error.StartFailed => .{ .internal_server_error, std.fmt.allocPrint(a, "the reviewer didn't start: {s}", .{tmux.lastError()}) catch "the reviewer didn't start" },
            error.NoFindings => .{ .conflict, "there are no findings to use" },
            error.EditConflict => .{ .conflict, "it changed while you were editing (a revised plan, or a new review): copy your text, press Cancel to see the new version, and edit that" },
            error.PlanStarted => .{ .conflict, "the session that builds it has started, or will resume a conversation, and won't see an edit of the plan; send Claude what to change instead" },
            error.OldFindings => .{ .conflict, "these findings are from before Claude's last changes; run the review again" },
            error.NotDelivered => .{ .conflict, "Claude didn't take the answer; it's still waiting. Check the session" },
            error.AlreadyStarted => .{ .conflict, "it already has a session" },
            error.Umbrella => .{ .conflict, "it's an umbrella: its sub-tickets run, not it" },
            error.Todo => .{ .conflict, board.todo_refused },
            error.TodoDone => .{ .conflict, "it's a done todo: move it back to To do or Doing to talk about it" },
            error.NoSubtickets => .{ .conflict, actions.no_subtickets },
            error.TargetBusy => .{ .conflict, "its session is busy or has another ticket in progress; it waits in Queued and starts there when the session is free" },
            error.WorktreeFailed => .{ .internal_server_error, worktree.lastError() },
            error.Busy => .{ .conflict, "Claude is working in its session or waiting on you; it can move once it is idle" },
            error.NoChange => .{ .conflict, "its work has no jj change of its own to move with it" },
            error.NotParked => .{ .conflict, "it isn't parked" },
            error.NoDrift => .{ .conflict, "its change no longer conflicts with its target" },
            error.Working => .{ .conflict, "Claude is working in its session or waiting on you; Rebase now asks only once it is idle, so nothing is cut off or answered by accident" },
            error.SessionElsewhere => .{ .conflict, "its session is on another ticket now; Rebase now waits until it is back on this one" },
            error.BadPr => .{ .bad_request, "the PR is its URL (https://github.com/<owner>/<repo>/pull/<n>), #<n>, or <owner>/<repo>#<n>" },
            error.NoRemote => .{ .bad_request, "its checkout has no GitHub origin remote to find that PR number in; give the PR's URL" },
            error.Finished => .{ .conflict, "it's done; there's nothing to park" },
            error.BadDuration => .{ .bad_request, "every and max are durations like 90s, 30m, 1h, 1d, 1w (every at least 1m)" },
            error.SessionFailed => .{ .internal_server_error, std.fmt.allocPrint(a, "the session didn't start: {s}", .{dispatch.failureReason(err)}) catch "the session didn't start" },
            error.OperatorFailed => .{ .internal_server_error, "couldn't reach the operator; open Chat to check on it" },
            error.OpenSubtickets => .{ .conflict, "it has sub-tickets that aren't done yet; finish them or spin them off" },
            error.NoTestPlan => .{ .not_found, "no test plan" },
            error.NoDemo => .{ .not_found, "no demo" },
            error.NoLaunch => .{ .not_found, "that step has no run: command" },
            error.Conflicts => .{ .conflict, "merging it back conflicts (the files are on the ticket); it stays in Review" },
            error.MergeFailed => .{ .internal_server_error, worktree.lastError() },
            error.SharedSession => .{ .conflict, "another ticket is in progress in its session, so stopping it would cut that one off; move or finish that ticket first, or kill the session for both" },
            error.Starting => .{ .conflict, "it is starting right now; try again in a moment" },
            error.NoRepo => .{ .conflict, "its project isn't a code repo: no worktrees, target branches or automated reviews there; its tickets run in the queue" },
            error.RepoWork => .{ .conflict, "it has work in a code repo (a worktree, jj change or branch), which a project that isn't one can't take; finish it first" },
            error.Sqlite => .{ .internal_server_error, db.message() },
            error.VoiceOff, error.SpeechFailed => .{ voiceStatus(err), voiceDetail(a, err, "voice.tts") catch voiceMessage(err) },
            else => .{ .internal_server_error, @errorName(err) },
        };
        try fail(req, status, msg);
    };
    return true;
}

/// Every field any request takes; each action reads its own.
const Body = struct {
    project: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    target: ?[]const u8 = null,
    plan: ?bool = null,
    umbrella: ?bool = null,
    todo: ?bool = null,
    link: ?[]const u8 = null,
    /// A todo's due date and reminder (when.parse: the board's pickers send
    /// 2026-11-10 or 2026-11-10T15:00); "" clears. snooze: `when`.
    due: ?[]const u8 = null,
    remind: ?[]const u8 = null,
    when: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    text: ?[]const u8 = null,
    send: ?bool = null,
    kind: ?[]const u8 = null,
    /// needs/act: the notification's item (push.Item.id) and its button
    /// (push.Action.action).
    item: ?[]const u8 = null,
    action: ?[]const u8 = null,
    /// needs/act answering: which question it answers (push.Item.ask).
    ask: ?[]const u8 = null,
    /// flags/dismiss: the tickets whose `kind` flag goes.
    keys: ?[]const []const u8 = null,
    detail: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    now: ?bool = null,
    answers: ?[]const []const u8 = null,
    key: ?[]const u8 = null,
    branch: ?bool = null,
    /// test-results: each step's checks and comment (`checks` alone: a page
    /// from before steps).
    steps: ?[]const review.StepResult = null,
    checks: ?[]const review.Check = null,
    /// test-progress: the board's JSON for how far testing got.
    progress: ?[]const u8 = null,
    note: ?[]const u8 = null,
    /// launch, launch-stop: the test plan step (1-based).
    step: ?usize = null,
    /// A launch of the demo's step, not the test plan's.
    demo: ?bool = null,
    name: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    slots: ?i64 = null,
    after_merge: ?[]const u8 = null,
    after_merge_claude: ?[]const u8 = null,
    /// Project: the automated review's skill ("" for cl's own instructions).
    review_skill: ?[]const u8 = null,
    /// Project: whether Claude finishing a ticket in Running gets it an
    /// automated review by itself, before it moves on.
    auto_review: ?board.AutoReview = null,
    push_after_merge: ?[]const u8 = null,
    /// Project: a code repo (`board.Project.repo`); false for one that isn't.
    repo: ?bool = null,
    /// Ticket or project: the branch it targets ("" for trunk / the project's).
    onto: ?[]const u8 = null,
    /// finish "tell": what Claude should do first.
    tell: ?[]const u8 = null,
    planners: ?i64 = null,
    /// plan, autoreview-edit: the text the edit started from.
    base: ?[]const u8 = null,
    spin_off: ?bool = null,
    /// block, unblock: the ticket it waits on.
    blocker: ?[]const u8 = null,
    /// Going to Done: "merge", "pr" or "close" (the default).
    finish: ?[]const u8 = null,
    /// Moving or ranking: the keys of the tickets it lands between.
    after: ?[]const u8 = null,
    before: ?[]const u8 = null,
    /// unpark: end the park without resuming the session.
    no_resume: ?bool = null,
    /// park: what it waits on, the check command ("" for none), and its
    /// interval and give-up time as durations ("1h", "7d"; "" for defaults).
    reason: ?[]const u8 = null,
    until: ?[]const u8 = null,
    every: ?[]const u8 = null,
    max: ?[]const u8 = null,
    /// park: the PR to wait on instead of `until` (its URL or "#n").
    pr: ?[]const u8 = null,
    /// Going to Done with "pr": what a follow-up does once it merges ("" for
    /// nothing; left out, Claude's suggestion stands).
    then: ?[]const u8 = null,
};

/// The steps for after the PR merges, when it goes to Done with a PR.
/// Returns what it replaced (null when it set nothing), for `restoreThen`.
fn setThen(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, b: Body, finish: actions.Finish) !?[]const u8 {
    if (finish != .pr) return null;
    const then = b.then orelse return null;
    const t = try board.getTicket(db, a, key);
    try board.setPrThen(ctx, db, t.id, std.mem.trim(u8, then, " \t\r\n"));
    return t.pr_then;
}

/// Put back what `setThen` replaced: the move it was for was refused.
fn restoreThen(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, old: ?[]const u8) void {
    const o = old orelse return;
    const t = board.getTicket(db, a, key) catch return;
    board.setPrThen(ctx, db, t.id, o) catch {};
}

/// A duration from the board ("1h"), or `default` when it is left empty.
fn durationOr(s: ?[]const u8, default: i64) !i64 {
    const v = std.mem.trim(u8, s orelse "", " ");
    if (v.len == 0) return default;
    return park.parseDuration(v) orelse error.BadDuration;
}

fn finishOf(b: Body) !actions.Finish {
    const f = b.finish orelse "close";
    if (std.mem.eql(u8, f, "tell")) return actions.Finish.told(b.tell orelse "") orelse error.BadInput;
    return actions.Finish.parse(f) orelse error.BadInput;
}

fn readBody(req: *std.http.Server.Request, a: std.mem.Allocator) !Body {
    const len: usize = @intCast(@min(req.head.content_length orelse 0, 1024 * 1024));
    if (len == 0) return .{};
    const buf = try a.alloc(u8, len);
    const r = try req.readerExpectContinue(&.{});
    try r.readSliceAll(buf);
    return std.json.parseFromSliceLeaky(Body, a, buf, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn fail(req: *std.http.Server.Request, status: std.http.Status, msg: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(.{ .@"error" = msg }, .{})}) catch "{\"error\":\"error\"}";
    try req.respond(text, .{ .status = status, .extra_headers = &json_headers });
}

fn ok(req: *std.http.Server.Request, a: std.mem.Allocator, value: anytype) !void {
    try req.respond(try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(value, .{})}), .{ .extra_headers = &json_headers });
}

fn route(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, post: bool, what: []const u8, name: []const u8, action: []const u8, b: Body) !void {
    if (std.mem.eql(u8, what, "voice")) {
        if (!post and std.mem.eql(u8, name, "reply")) return voiceReply(ctx, cfg, a, req, action);
        // The terminal page's mic shows only with voice.stt.
        if (!post and std.mem.eql(u8, name, "on")) return ok(req, a, .{ .on = cfg.voice.stt.len > 0 });
        if (post and std.mem.eql(u8, name, "speak")) return voiceSpeak(ctx, cfg, a, req, b.text orelse "");
        return error.NotFound;
    }
    if (!post) {
        if (std.mem.eql(u8, what, "board")) return getBoard(ctx, cfg, db, a, req);
        if (std.mem.eql(u8, what, "needs")) return getNeeds(ctx, cfg, db, a, req);
        if (std.mem.eql(u8, what, "ticket") and name.len > 0) return getTicket(ctx, cfg, db, a, req, name);
        if (std.mem.eql(u8, what, "image")) return getImage(ctx, cfg, a, req, name, action);
        return error.NotFound;
    }
    if (std.mem.eql(u8, what, "ticket")) {
        if (name.len == 0) {
            const adopt_ctx: AdoptCtx = .{ .ctx = ctx, .cfg = cfg };
            if (nonEmpty(b.onto)) |o| {
                const pname = if (nonEmpty(b.project)) |pn| pn else (try board.getTicket(db, a, nonEmpty(b.parent) orelse return error.BadInput)).project;
                const tp = try board.getProject(db, a, pname);
                // Repo-less, createTicket refuses it: no repo to look it up in.
                if (!tp.repo) return error.NoRepo;
                try checkOnto(ctx, a, tp.dir, o);
            }
            const key = try board.createTicket(ctx, db, a, .{
                .project = b.project orelse "",
                .title = b.title,
                .body = b.body,
                .stage = if (b.stage) |s| board.Stage.parse(s) orelse return error.BadInput else null,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .plan = b.plan,
                .umbrella = b.umbrella,
                .todo = b.todo,
                .link = b.link,
                .due = try webWhen(ctx, cfg, db, b.due),
                .remind = if (try webWhen(ctx, cfg, db, b.remind)) |w| w.at else null,
                .skill = nonEmpty(b.skill),
                .target = b.target,
                .profile = b.profile,
                .parent = nonEmpty(b.parent),
                .onto = nonEmpty(b.onto),
                .body_for_key = .{ .ctx = &adopt_ctx, .call = adoptImages },
            });
            return ok(req, a, .{ .key = key });
        }
        try ticketAction(ctx, cfg, db, a, req, name, action, b);
        return;
    }
    // A button on a push notification (src/web/sw.js), sent by the
    // service worker with the board's own login cookie.
    if (std.mem.eql(u8, what, "needs") and std.mem.eql(u8, name, "act")) {
        return ok(req, a, try push.act(ctx, cfg, db, a, b.item orelse return error.BadInput, b.action orelse return error.BadInput, b.ask orelse ""));
    }
    // Dismiss all of one kind in Needs You: the keys the board showed, so a
    // flag raised since isn't cleared unseen.
    if (std.mem.eql(u8, what, "flags") and std.mem.eql(u8, name, "dismiss")) {
        const kind = b.kind orelse return error.BadInput;
        if (board.waitingFlag(kind)) return error.WaitingFlag;
        var n: usize = 0;
        for (b.keys orelse return error.BadInput) |k| {
            if (board.dismissFlag(ctx, db, a, k, kind) catch |e| switch (e) {
                error.NotFound => false, // deleted meanwhile
                else => return e,
            }) n += 1;
        }
        return ok(req, a, .{ .dismissed = n });
    }
    // A session's alert: Dismiss, or Open just before it opens the session
    // (attaching clears it too, but a terminal the page already had doesn't attach again).
    if (std.mem.eql(u8, what, "alert") and std.mem.eql(u8, action, "dismiss")) {
        return ok(req, a, .{ .dismissed = try alerts.dismiss(ctx, a, name) });
    }
    // The Quick Ticket button: hand the human's words to the operator.
    if (std.mem.eql(u8, what, "operator") and std.mem.eql(u8, name, "quick-ticket")) {
        const text = try operator.quickTicketText(a, b.text orelse "");
        const started = operator.sendInBackground(ctx, cfg, .chat, text) catch return error.OperatorFailed;
        return ok(req, a, .{ .ok = true, .started = started });
    }
    // Pause or resume every project: /api/projects/pause, /api/projects/resume.
    if (std.mem.eql(u8, what, "projects") and (std.mem.eql(u8, name, "pause") or std.mem.eql(u8, name, "resume"))) {
        const pause = std.mem.eql(u8, name, "pause");
        try board.setAllPaused(db, pause);
        var stopped: std.ArrayList([]const u8) = .empty;
        var left: std.ArrayList([]const u8) = .empty;
        if (pause and b.now == true) for (try board.listProjects(db, a)) |p| {
            const r = try dispatch.interrupt(ctx, cfg, db, a, p.name);
            try stopped.appendSlice(a, r.queued);
            try stopped.appendSlice(a, r.planning);
            try left.appendSlice(a, r.left);
        };
        return ok(req, a, .{ .ok = true, .stopped = stopped.items, .left = left.items });
    }
    if (std.mem.eql(u8, what, "project")) {
        if (name.len == 0) {
            const repo = b.repo orelse true;
            var in: board.ProjectInput = .{
                .name = b.name orelse "",
                .dir = "",
                .prefix = nonEmpty(b.prefix),
                .slots = b.slots,
                .planners = b.planners,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .profile = b.profile,
                .after_merge = b.after_merge,
                .after_merge_claude = b.after_merge_claude,
                .review_skill = b.review_skill,
                .auto_review = b.auto_review,
                .onto = b.onto,
                .push_after_merge = b.push_after_merge,
                .repo = repo,
            };
            // Everything checked before a directory is made for it.
            board.checkNewProject(db, in) catch |e| return projectFail(req, e);
            // Not a code repo: its directory is made if it is missing.
            if (!repo) if (nonEmpty(b.dir)) |d| {
                const expanded = try ctx.expandHome(d);
                defer ctx.gpa.free(expanded);
                std.Io.Dir.cwd().createDirPath(ctx.io, expanded) catch return error.NoSuchDir;
            };
            in.dir = try realDir(ctx, a, b.dir orelse return error.BadInput);
            const dir = in.dir;
            if (repo) if (nonEmpty(b.onto)) |o| try checkOnto(ctx, a, dir, o);
            board.addProject(db, in) catch |e| return projectFail(req, e);
            if (repo) _ = worktree.ensureJj(ctx, a, dir);
            return ok(req, a, .{ .ok = true });
        }
        if (std.mem.eql(u8, action, "set")) {
            if (nonEmpty(b.onto)) |o| {
                const cur = try board.getProject(db, a, name);
                // Repo-less, updateProject refuses it: no repo to look it up in.
                if (!std.mem.eql(u8, o, cur.onto) and (b.repo orelse cur.repo)) try checkOnto(ctx, a, if (b.dir) |d| try realDir(ctx, a, d) else cur.dir, o);
            }
            board.updateProject(db, name, .{
                .name = b.name orelse "",
                .dir = if (b.dir) |d| try realDir(ctx, a, d) else "",
                .prefix = nonEmpty(b.prefix),
                .slots = b.slots,
                .planners = b.planners,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .profile = b.profile,
                .after_merge = b.after_merge,
                .after_merge_claude = b.after_merge_claude,
                .review_skill = b.review_skill,
                .auto_review = b.auto_review,
                .onto = b.onto,
                .push_after_merge = b.push_after_merge,
                .repo = b.repo,
            }) catch |e| return projectFail(req, e);
        } else if (std.mem.eql(u8, action, "after-merge")) {
            if (!after_merge.runs(try board.getProject(db, a, name))) return error.BadInput;
            try after_merge.startByHand(ctx, db, name, nonEmpty(b.key) orelse "-");
        } else if (std.mem.eql(u8, action, "push")) {
            ci.pushFromBoard(ctx, db, a, name) catch |e| return if (e == error.NoPush) error.BadInput else e;
        } else if (std.mem.eql(u8, action, "hide") or std.mem.eql(u8, action, "unhide")) {
            try board.setProjectHidden(db, name, std.mem.eql(u8, action, "hide"));
        } else if (std.mem.eql(u8, action, "pause") or std.mem.eql(u8, action, "resume")) {
            const pause = std.mem.eql(u8, action, "pause");
            try board.setProjectPaused(db, name, pause);
            // Pause now: what runs stops too, and resumes with the project.
            if (pause and b.now == true) {
                const r = try dispatch.interrupt(ctx, cfg, db, a, name);
                var stopped: std.ArrayList([]const u8) = .empty;
                try stopped.appendSlice(a, r.queued);
                try stopped.appendSlice(a, r.planning);
                return ok(req, a, .{ .ok = true, .stopped = stopped.items, .left = r.left });
            }
        } else if (std.mem.eql(u8, action, "rm")) {
            board.removeProject(db, name) catch |e| switch (e) {
                error.Exists => {
                    const n = try db.int("SELECT count(*) FROM tickets WHERE project = ?1", .{name}) orelse 0;
                    return fail(req, .conflict, try std.fmt.allocPrint(a, "{s} still has {d} ticket{s} (Done ones count too). cl only deletes an empty project: delete its tickets or move them to another project first", .{ name, n, if (n == 1) "" else "s" }));
                },
                else => return e,
            };
        } else return error.NotFound;
        return ok(req, a, .{ .ok = true });
    }
    return error.NotFound;
}

const AdoptCtx = struct { ctx: Ctx, cfg: config.Config };

/// A new ticket's body, with the images pasted in the New ticket dialog moved
/// to the ticket's own folder.
fn adoptImages(p: *const anyopaque, a: std.mem.Allocator, key: []const u8, body: []const u8) anyerror!?[]const u8 {
    const c: *const AdoptCtx = @ptrCast(@alignCast(p));
    return images.adopt(c.ctx, a, c.cfg, key, body);
}

/// Store an image pasted into a description: `owner` is the ticket's key,
/// or images.staging for a ticket not created yet. Answers its path (what
/// the description refers to it by) and its URL here.
fn uploadImage(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, owner: []const u8) !void {
    const key = if (std.mem.eql(u8, owner, images.staging)) owner else (try board.getTicket(db, a, owner)).key;
    const len = req.head.content_length orelse return error.BadInput;
    if (len > images.max_bytes) return error.TooBig;
    if (len == 0) return error.BadInput;
    const buf = try a.alloc(u8, @intCast(len));
    const r = try req.readerExpectContinue(&.{});
    try r.readSliceAll(buf);
    const path = try images.save(ctx, a, cfg, key, buf);
    const url = try std.fmt.allocPrint(a, "/api/image/{s}/{s}", .{ key, std.fs.path.basename(path) });
    return ok(req, a, .{ .path = path, .url = url });
}

/// Serve one image, to the logged-in board only (it is under /api/).
fn getImage(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, req: *std.http.Server.Request, owner: []const u8, file: []const u8) !void {
    if (!images.validOwner(owner) or !images.validName(file)) return error.NotFound;
    const ctype = images.contentType(std.fs.path.extension(file)[1..]) orelse return error.NotFound;
    const path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ try images.root(ctx, a, cfg), owner, file });
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(images.max_bytes + 1)) catch return error.NotFound;
    try req.respond(data, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = ctype },
        // Named by their content: a name never shows another image.
        .{ .name = "cache-control", .value = "private, max-age=86400" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

/// Adding or changing a project: say which input was wrong.
fn projectFail(req: *std.http.Server.Request, err: board.Error) !void {
    return switch (err) {
        error.Exists => fail(req, .conflict, "another project already has that name or key prefix"),
        error.BadInput => fail(req, .bad_request, "a project needs a name and a directory, and a key prefix is up to 8 capital letters and digits"),
        error.NoRepo => fail(req, .bad_request, "a project that isn't a code repo runs its tickets in the queue, with no automated review, target branch, push or after-merge command"),
        error.RepoWork => fail(req, .conflict, "tickets that aren't done have work in the repo (a worktree, jj change or branch): finish them first"),
        else => err,
    };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn realDir(ctx: Ctx, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const expanded = try ctx.expandHome(path);
    defer ctx.gpa.free(expanded);
    return std.Io.Dir.cwd().realPathFileAlloc(ctx.io, expanded, a) catch error.NoSuchDir;
}

/// A target branch (`--onto`) must be there in the project's repo at `dir`.
fn checkOnto(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, onto: []const u8) !void {
    if (!worktree.branchExists(ctx, a, dir, onto)) return error.NoSuchBranch;
}

/// A date from the board (when.parse); null when not sent.
fn webWhen(ctx: Ctx, cfg: config.Config, db: board.Db, text: ?[]const u8) !?when.When {
    const t = text orelse return null;
    return try when.parse(db, ctx.nowSeconds(), cfg.board.morning, t);
}

fn ticketAction(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, key: []const u8, action: []const u8, b: Body) !void {
    const eql = std.mem.eql;
    if (eql(u8, action, "edit")) {
        const mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null;
        if (nonEmpty(b.onto)) |o| {
            const cur = try board.getTicket(db, a, key);
            // Unchanged: no need to look again.
            if (!std.mem.eql(u8, o, cur.onto_own)) {
                const tp = try board.getProject(db, a, nonEmpty(b.project) orelse cur.project);
                // Repo-less, updateTicket refuses it: no repo to look it up in.
                if (!tp.repo) return error.NoRepo;
                try checkOnto(ctx, a, tp.dir, o);
            }
        }
        try board.updateTicket(ctx, db, a, key, .{
            .project = b.project orelse "",
            .title = b.title,
            .body = b.body,
            .plan = b.plan,
            .umbrella = b.umbrella,
            .todo = b.todo,
            .link = b.link,
            .due = try webWhen(ctx, cfg, db, b.due),
            .remind = if (try webWhen(ctx, cfg, db, b.remind)) |w| w.at else null,
            .skill = b.skill,
            .target = b.target,
            .profile = b.profile,
            .onto = b.onto,
        });
        // A new mode moves the ticket (with its work, once started).
        if (mode) |m| {
            const r = try dispatch.relocate(ctx, cfg, db, a, try board.getTicket(db, a, key), m);
            return ok(req, a, .{ .result = @tagName(r) });
        }
    } else if (eql(u8, action, "relocate")) {
        const m = board.Mode.parse(b.mode orelse "") orelse return error.BadInput;
        const r = try dispatch.relocate(ctx, cfg, db, a, try board.getTicket(db, a, key), m);
        return ok(req, a, .{ .result = @tagName(r) });
    } else if (eql(u8, action, "move")) {
        const stage = board.Stage.parse(b.stage orelse "") orelse return error.BadInput;
        // Ranked first, so the dispatcher never sees it queued in the wrong place.
        if (nonEmpty(b.after) != null or nonEmpty(b.before) != null) try board.rankTicket(db, a, key, nonEmpty(b.after), nonEmpty(b.before));
        const finish = try finishOf(b);
        const old = if (stage == .done) try setThen(ctx, db, a, key, b, finish) else null;
        errdefer restoreThen(ctx, db, a, key, old);
        try actions.move(ctx, cfg, db, a, key, stage, b.spin_off orelse false, finish);
    } else if (eql(u8, action, "block")) {
        _ = try board.addBlocker(ctx, db, a, key, b.blocker orelse return error.BadInput);
    } else if (eql(u8, action, "unblock")) {
        _ = try board.removeBlocker(ctx, db, a, key, b.blocker orelse return error.BadInput);
    } else if (eql(u8, action, "rank")) {
        try board.rankTicket(db, a, key, nonEmpty(b.after), nonEmpty(b.before));
    } else if (eql(u8, action, "comment")) {
        const r = try actions.comment(ctx, db, a, key, "you", b.text orelse return error.BadInput, b.send orelse false);
        return ok(req, a, r);
    } else if (eql(u8, action, "flag")) {
        try board.setFlag(ctx, db, a, key, b.kind orelse return error.BadInput, "manual", b.detail orelse "");
    } else if (eql(u8, action, "unflag")) {
        try board.clearFlag(ctx, db, a, key, b.kind orelse return error.BadInput);
    } else if (eql(u8, action, "dismiss")) {
        const kind = b.kind orelse return error.BadInput;
        if (board.waitingFlag(kind)) return error.WaitingFlag;
        return ok(req, a, .{ .dismissed = try board.dismissFlag(ctx, db, a, key, kind) });
    } else if (eql(u8, action, "done")) {
        try review.done(ctx, db, a, key, b.summary orelse "", null, null);
        // As with Claude's `cl ticket done`: the project may review it by
        // itself first, in Running; else it moves on now.
        _ = try autoreview.startOnDone(ctx, cfg, db, a, key);
    } else if (eql(u8, action, "approve")) {
        const finish = try finishOf(b);
        const old = if ((try board.getTicket(db, a, key)).stage == .review) try setThen(ctx, db, a, key, b, finish) else null;
        errdefer restoreThen(ctx, db, a, key, old);
        _ = try actions.approve(ctx, db, a, key, b.spin_off orelse false, finish);
    } else if (eql(u8, action, "start")) {
        const t = try board.getTicket(db, a, key);
        try dispatch.start(ctx, cfg, db, a, t, b.now orelse false);
    } else if (eql(u8, action, "answer")) {
        try actions.answer(ctx, cfg, db, a, key, b.answers orelse return error.BadInput);
    } else if (eql(u8, action, "kill")) {
        return ok(req, a, try actions.kill(ctx, cfg, db, a, key));
    } else if (eql(u8, action, "park")) {
        const every = try durationOr(b.every, park.default_every);
        if (every < 60) return error.BadDuration;
        const max: ?i64 = if (nonEmpty(b.max) != null) try durationOr(b.max, park.default_max) else null;
        const r = try park.park(ctx, db, a, key, .{ .reason = b.reason orelse "", .until = b.until orelse "", .pr = b.pr orelse "", .every = every, .max = max });
        try park.stopSession(ctx, cfg, db, a, key);
        return ok(req, a, .{ .session = r.session orelse "", .others = r.others });
    } else if (eql(u8, action, "rebase")) {
        try drift.rebase(ctx, cfg, db, a, key);
    } else if (eql(u8, action, "unpark")) {
        const r = try park.unpark(ctx, cfg, db, a, key, !(b.no_resume orelse false));
        return ok(req, a, .{ .resumed = if (r.resumed) |x| @tagName(x) else "" });
    } else if (eql(u8, action, "hide") or eql(u8, action, "unhide")) {
        _ = try board.hideNeeds(ctx, db, a, key, eql(u8, action, "hide"));
    } else if (eql(u8, action, "snooze")) {
        const w = (try webWhen(ctx, cfg, db, b.when)) orelse return error.BadWhen;
        if (w.at == 0) return error.BadWhen;
        const said = try when.label(db, a, ctx.nowSeconds(), .{ .at = w.at, .has_time = true });
        try board.snooze(ctx, db, a, key, w.at, try when.format(db, a, ctx.nowSeconds(), .{ .at = w.at, .has_time = true }));
        return ok(req, a, .{ .until = said });
    } else if (eql(u8, action, "key")) {
        try actions.press(ctx, db, a, key, std.meta.stringToEnum(actions.Key, b.key orelse "") orelse return error.BadInput);
    } else if (eql(u8, action, "rm")) {
        const t = try board.getTicket(db, a, key);
        const freed = actions.remove(ctx, db, a, t.key) catch |e| switch (e) {
            error.Exists => return fail(req, .conflict, try std.fmt.allocPrint(a, "{s} has sub-tickets; delete them first", .{t.key})),
            else => return e,
        };
        images.removeTicket(ctx, a, cfg, t.key);
        // The tickets that waited on it go on without it: the board says so.
        return ok(req, a, .{ .ok = true, .freed = freed });
    } else if (eql(u8, action, "cleanup")) {
        const t = try board.getTicket(db, a, key);
        if (t.worktree.len == 0) return error.BadInput;
        const p = try board.getProject(db, a, t.project);
        try worktree.remove(ctx, a, p.dir, .{ .path = t.worktree, .branch = t.branch }, b.branch orelse false);
        try board.setSession(ctx, db, t.id, t.tmux, t.session_id, "", if (b.branch orelse false) "" else t.branch);
        try board.logEvent(ctx, db, t.id, "worktree removed", t.worktree);
    } else if (eql(u8, action, "gutter")) {
        const t = try board.getTicket(db, a, key);
        const port = try review.startGutter(ctx, cfg, db, a, t);
        web.relayGutter(ctx, cfg, t.key, port);
        return ok(req, a, .{ .port = port });
    } else if (eql(u8, action, "gutter-stop")) {
        try review.stopGutter(ctx, a, key);
    } else if (eql(u8, action, "autoreview")) {
        const r = try autoreview.start(ctx, cfg, db, a, try board.getTicket(db, a, key));
        return ok(req, a, .{ .profile = r.profile });
    } else if (eql(u8, action, "autoreview-stop")) {
        try autoreview.stop(ctx, db, a, key);
    } else if (eql(u8, action, "autoreview-send")) {
        return ok(req, a, try actions.autoreviewSend(ctx, db, a, key));
    } else if (eql(u8, action, "autoreview-edit")) {
        try autoreview.edit(ctx, db, a, key, b.text orelse return error.BadInput, b.base orelse return error.BadInput);
    } else if (eql(u8, action, "plan")) {
        try board.editPlan(ctx, db, a, key, b.text orelse return error.BadInput, b.base orelse return error.BadInput);
    } else if (eql(u8, action, "autoreview-gutter")) {
        const t = try board.getTicket(db, a, key);
        const r = try autoreview.openInGutter(ctx, cfg, db, a, t);
        web.relayGutter(ctx, cfg, t.key, r.port);
        return ok(req, a, .{ .port = r.port, .draft = @tagName(r.draft) });
    } else if (eql(u8, action, "launch")) {
        _ = try review.launch(ctx, db, a, try board.getTicket(db, a, key), launchKind(b), b.step);
    } else if (eql(u8, action, "launch-stop")) {
        try review.stopLaunch(ctx, a, key, launchKind(b), b.step);
    } else if (eql(u8, action, "test-progress")) {
        const json = b.progress orelse return error.BadInput;
        if (json.len > 64 * 1024) return error.BadInput;
        // An object or "" (start over), nothing else.
        if (json.len > 0) switch (std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return error.BadInput) {
            .object => {},
            else => return error.BadInput,
        };
        try board.setTestProgress(db, (try board.getTicket(db, a, key)).id, json);
    } else if (eql(u8, action, "test-results")) {
        const steps = b.steps orelse &.{review.StepResult{ .checks = b.checks orelse return error.BadInput }};
        // All passing moves a ticket in Testing on to Review: finishing is
        // approving it there.
        return ok(req, a, try actions.testResults(ctx, db, a, key, steps, b.note orelse "", b.send));
    } else return error.NotFound;
    return ok(req, a, .{ .ok = true });
}

const SessionRow = struct {
    tmux: []const u8,
    name: []const u8,
    dir: []const u8,
    status: []const u8,
};

const TicketRow = struct {
    ticket: board.Ticket,
    /// The live session's status ("" without one).
    status: []const u8,
    /// Claude is working on it now: it stays out of Needs You until it stops.
    working: bool = false,
    /// Where its automated review stands (`autoreview.standing`).
    autoreview: autoreview.Standing = .none,
    /// It has a plan (`listTicket` leaves the plan's text out).
    has_plan: bool = false,
};

fn launchKind(b: Body) review.Kind {
    return if (b.demo orelse false) .demo else .test_plan;
}

/// A ticket as the board's columns show it: the long texts only its popup
/// shows (GET /api/ticket sends them in full) are left out. The board asks
/// for every ticket, Done ones too, every few seconds: with them, that was
/// a megabyte each time on a board with 160 tickets.
fn listTicket(a: std.mem.Allocator, t: board.Ticket, ar: ?autoreview.Review) !board.Ticket {
    var out = t;
    out.review_guide = "";
    out.test_plan = "";
    out.verified = "";
    out.demo = "";
    out.test_progress = "";
    out.plan_md = "";
    // A card shows the summary only as what its testing or review flag
    // asks (Claude's summary is first seen in Testing now).
    const asks_review = for (t.flags) |f| {
        if (std.mem.eql(u8, f.kind, "review") or std.mem.eql(u8, f.kind, "testing")) break true;
    } else false;
    if (!asks_review) out.summary = "";
    out.autoreview = if (ar) |r| try listReview(a, r) else "";
    return out;
}

/// What a card's review pill reads of `Ticket.autoreview`: where it stands,
/// how many findings and what became of them, not their text.
fn listReview(a: std.mem.Allocator, r: autoreview.Review) ![]const u8 {
    var out = r;
    out.summary = "";
    out.reply = "";
    out.previous = null;
    // The pill only asks whether there is an edit.
    if (r.edited.len > 0) out.edited = "1";
    const findings = try a.alloc(autoreview.Finding, r.findings.len);
    for (findings, r.findings) |*f, g| f.* = .{ .severity = g.severity };
    out.findings = findings;
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(out, .{})});
}

test "listTicket leaves out the popup's texts, not what a card shows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var review_flag = [_]board.Flag{.{ .kind = "review", .source = "auto", .detail = "", .at = 0 }};
    var t = std.mem.zeroInit(board.Ticket, .{ .key = "CL-1", .title = "t", .body = "searchable", .summary = "did it", .plan_md = "# plan", .review_guide = "guide", .test_plan = "plan", .verified = "ran it", .demo = "## Look", .test_progress = "{}" });
    const r: autoreview.Review = .{ .status = "done", .summary = "long", .edited = "my edit", .findings = &.{ .{ .title = "a", .body = "why" }, .{ .title = "b", .body = "why" } } };
    t.autoreview = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})});

    const l = try listTicket(a, t, autoreview.load(a, t));
    try std.testing.expectEqualStrings("searchable", l.body);
    try std.testing.expectEqualStrings("", l.summary);
    try std.testing.expectEqualStrings("", l.plan_md);
    try std.testing.expectEqualStrings("", l.review_guide);
    try std.testing.expectEqualStrings("", l.test_plan);
    try std.testing.expectEqualStrings("", l.verified);
    try std.testing.expectEqualStrings("", l.demo);
    try std.testing.expectEqualStrings("", l.test_progress);
    const back = autoreview.load(a, l).?;
    try std.testing.expectEqualStrings("done", back.status);
    try std.testing.expectEqual(@as(usize, 2), back.findings.len);
    try std.testing.expectEqualStrings("", back.findings[0].body);
    try std.testing.expectEqualStrings("", back.summary);
    try std.testing.expect(back.edited.len > 0);

    t.flags = &review_flag;
    try std.testing.expectEqualStrings("did it", (try listTicket(a, t, null)).summary);
    var testing_flag = [_]board.Flag{.{ .kind = "testing", .source = "auto", .detail = "", .at = 1 }};
    t.flags = &testing_flag;
    try std.testing.expectEqualStrings("did it", (try listTicket(a, t, null)).summary);
}

fn sessionStatuses(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator) !struct { rows: []SessionRow, map: std.StringHashMapUnmanaged([]const u8), busy: []const []const u8 } {
    const sessions = try tmux.list(ctx, a);
    const statuses = try claude.readStatuses(ctx, a, cfg);
    var rows: std.ArrayList(SessionRow) = .empty;
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var busy: std.ArrayList([]const u8) = .empty;
    for (sessions) |s| {
        const st = claude.statusFor(ctx, statuses, s);
        try rows.append(a, .{ .tmux = s.tmux_name, .name = s.name, .dir = s.dir, .status = st.label() });
        try map.put(a, s.tmux_name, st.label());
        if (st == .busy) try busy.append(a, s.tmux_name);
    }
    return .{ .rows = rows.items, .map = map, .busy = busy.items };
}

fn getBoard(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request) !void {
    const ss = try sessionStatuses(ctx, cfg, a);
    const tickets = try board.listTickets(db, a, .{});
    var rows: std.ArrayList(TicketRow) = .empty;
    for (tickets) |t| {
        const ar = autoreview.load(a, t);
        try rows.append(a, .{
            .ticket = try listTicket(a, t, ar),
            .status = ss.map.get(t.tmux) orelse "",
            .working = try board.isWorking(db, t, ss.busy),
            .autoreview = autoreview.standing(ar, t),
            .has_plan = std.mem.trim(u8, t.plan_md, " \t\r\n").len > 0,
        });
    }
    var profiles: std.ArrayList([]const u8) = .empty;
    for (cfg.profiles) |p| try profiles.append(a, p.name);
    const b: Board = .{
        .projects = try board.listProjects(db, a),
        .tickets = rows.items,
        .sessions = ss.rows,
        // Hidden projects' too: the page leaves them out as it does their tickets.
        .alerts = try alerts.list(ctx, db, a, true),
        .profiles = profiles.items,
        .build = try buildId(a),
        // Descriptions refer to pasted images by their path under here.
        .images_dir = try images.root(ctx, a, cfg),
        // The mic button shows only with voice.stt; voice.tts picks who speaks.
        // `split`: a resident TTS server (voice.tts is a URL) is quick per
        // request, so the board asks for each sentence and starts on the first.
        .voice = .{ .on = cfg.voice.stt.len > 0, .tts = cfg.voice.tts.len > 0, .split = voice.ttsIsUrl(cfg.voice.tts), .speed = cfg.voice.tts_speed, .pitch = cfg.voice.tts_pitch },
    };
    try okCached(req, try cached(a, b), ctx.nowSeconds());
}

/// What GET /api/board sends. No clock in it: the time goes in a header
/// (x-now), so the body only changes when the board does, and the page's
/// refreshes get 304 while nothing moved (`okCached`), which is most of them.
const Board = struct {
    projects: []const board.Project,
    tickets: []const TicketRow,
    sessions: []const SessionRow,
    /// Hidden projects' too: the page leaves them out as it does their tickets.
    alerts: []const alerts.Alert,
    profiles: []const []const u8,
    build: []const u8,
    /// Descriptions refer to pasted images by their path under here.
    images_dir: []const u8,
    /// The mic button shows only with voice.stt; voice.tts picks who speaks.
    /// `split`: a resident TTS server (voice.tts is a URL) is quick per
    /// request, so the board asks for each sentence and starts on the first.
    voice: struct { on: bool, tts: bool, split: bool, speed: f32, pitch: f32 },
};

/// A JSON response and its etag: a hash of the body, so it only changes
/// when the body does.
const Cached = struct { body: []const u8, etag: []const u8 };

fn cached(a: std.mem.Allocator, value: anytype) !Cached {
    const body = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(value, .{})});
    return .{ .body = body, .etag = try std.fmt.allocPrint(a, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, body)}) };
}

/// The page already has this response: it sent back its etag.
fn unchanged(if_none_match: ?[]const u8, etag: []const u8) bool {
    return std.mem.eql(u8, if_none_match orelse return false, etag);
}

/// Send `c`, or 304 with no body when the page has it already. `now`, when
/// given, goes in x-now: the page's "5m ago" without a clock in the body.
fn okCached(req: *std.http.Server.Request, c: Cached, now: ?i64) !void {
    var now_buf: [24]u8 = undefined;
    const now_s = if (now) |n| std.fmt.bufPrint(&now_buf, "{d}", .{n}) catch unreachable else "";
    const with_now = json_headers ++ [_]std.http.Header{ .{ .name = "etag", .value = c.etag }, .{ .name = "x-now", .value = now_s } };
    const headers: []const std.http.Header = if (now != null) &with_now else with_now[0 .. with_now.len - 1];
    if (unchanged(web.header(req, "if-none-match"), c.etag))
        return req.respond("", .{ .status = .not_modified, .extra_headers = headers });
    try req.respond(c.body, .{ .extra_headers = headers });
}

test "the board's etag: the same while nothing changed, new when something did" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows = [_]TicketRow{.{ .ticket = std.mem.zeroInit(board.Ticket, .{ .key = "CL-1", .title = "t", .stage = .running }), .status = "busy" }};
    const b: Board = .{ .projects = &.{}, .tickets = &rows, .sessions = &.{}, .alerts = &.{}, .profiles = &.{"work"}, .build = "abc", .images_dir = "/i", .voice = .{ .on = false, .tts = false, .split = false, .speed = 1, .pitch = 1 } };

    const first = try cached(a, b);
    const again = try cached(a, b);
    try std.testing.expectEqualStrings(first.etag, again.etag);
    // Nothing time-based: a clock in the body would make every refresh a 200.
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"now\"") == null);
    try std.testing.expect(unchanged(first.etag, again.etag));

    rows[0].ticket.stage = .review;
    const moved = try cached(a, b);
    try std.testing.expect(!std.mem.eql(u8, first.etag, moved.etag));
    // The page's old etag no longer matches: it gets the new board.
    try std.testing.expect(!unchanged(first.etag, moved.etag));
    try std.testing.expect(!unchanged(null, moved.etag));
}

/// What is in Needs You, one id per thing asking: `f<flag id>` for each
/// flag that puts a ticket there and `a<tmux>@<time>` for each alert.
/// cl-window reads it every few seconds and asks for attention when an id
/// shows up that it has never seen. Hidden projects are left out, as
/// the board leaves them out by default.
fn getNeeds(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request) !void {
    const ss = try sessionStatuses(ctx, cfg, a);
    try ok(req, a, .{ .needs = try needsIds(a, try ticket_watch.snapshot(db, a, .{ .busy = ss.busy }), try alerts.list(ctx, db, a, false)) });
}

fn needsIds(a: std.mem.Allocator, tickets: []const ticket_watch.Seen, al: []const alerts.Alert) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (tickets) |t| if (t.inNeeds()) for (t.flags) |f| if (t.asks(f)) try ids.append(a, try std.fmt.allocPrint(a, "f{d}", .{f.id}));
    for (al) |x| try ids.append(a, try std.fmt.allocPrint(a, "a{s}@{d}", .{ x.tmux, x.at }));
    return ids.items;
}

test "needsIds: the flags that put a ticket in Needs You, then alerts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flags = [_]ticket_watch.SeenFlag{ .{ .id = 7, .kind = "question", .detail = "" }, .{ .id = 8, .kind = "review", .detail = "", .hidden = true } };
    const done_flags = [_]ticket_watch.SeenFlag{ .{ .id = 9, .kind = "review", .detail = "" }, .{ .id = 10, .kind = "after-merge", .detail = "" } };
    const base: ticket_watch.Seen = .{ .id = 1, .key = "CL-1", .project = "p", .title = "t", .stage = .running, .hidden = false, .flags = &flags };
    var parked = base;
    parked.parked = true;
    var working = base;
    working.working = true;
    var hidden_project = base;
    hidden_project.project_hidden = true;
    var done = base;
    done.stage = .done;
    done.flags = &done_flags;
    // Parked, a todo's due date (or reminder) still asks; nothing else does.
    const todo_flags = [_]ticket_watch.SeenFlag{ .{ .id = 11, .kind = "idle", .detail = "" }, .{ .id = 12, .kind = "due", .detail = "due today" } };
    var parked_todo = base;
    parked_todo.parked = true;
    parked_todo.flags = &todo_flags;
    const al = [_]alerts.Alert{.{ .tmux = "cl_x", .from = "x", .operator = false, .text = "hi", .at = 42, .ticket = "", .project = "" }};
    const ids = try needsIds(a, &.{ base, parked, working, hidden_project, done, parked_todo }, &al);
    try std.testing.expectEqual(@as(usize, 4), ids.len);
    try std.testing.expectEqualStrings("f7", ids[0]);
    try std.testing.expectEqualStrings("f10", ids[1]);
    try std.testing.expectEqualStrings("f12", ids[2]);
    try std.testing.expectEqualStrings("acl_x@42", ids[3]);
}

// ---- push notifications (push.zig) ----

const PushBody = struct {
    /// subscribe: the browser's PushSubscription (its toJSON()).
    endpoint: ?[]const u8 = null,
    keys: ?struct { p256dh: []const u8 = "", auth: []const u8 = "" } = null,
    name: ?[]const u8 = null,
    /// subscribe: the device's time zone, in minutes east of UTC.
    tz_offset: ?i64 = null,
    /// subscribe: the human pressed Turn on (see push.Subscription).
    explicit: ?bool = null,
    /// subscribe: the browser renewed the subscription that had this endpoint.
    old_endpoint: ?[]const u8 = null,
    /// device, remove, test: which one.
    id: ?i64 = null,
    /// device: on or off.
    enabled: ?bool = null,
    /// settings: the kinds that notify, and quiet hours (minutes after
    /// midnight; null or equal for none).
    kinds: ?[]const []const u8 = null,
    quiet_from: ?i64 = null,
    quiet_to: ?i64 = null,
};

/// A subscription from the board or the service worker.
fn pushSubscription(b: PushBody) !push.Subscription {
    const keys = b.keys orelse return error.BadInput;
    return .{
        .endpoint = b.endpoint orelse return error.BadInput,
        .p256dh = keys.p256dh,
        .auth = keys.auth,
        .name = b.name orelse "",
        .tz_offset = b.tz_offset orelse 0,
        .explicit = b.explicit orelse false,
        .old_endpoint = b.old_endpoint orelse "",
    };
}

/// The settings the board sent: known kinds only; quiet hours both set (as
/// minutes after midnight) or none.
fn pushSettings(a: std.mem.Allocator, b: PushBody) !push.Settings {
    var kinds: std.ArrayList(push.Group) = .empty;
    for (b.kinds orelse &.{}) |k| try kinds.append(a, std.meta.stringToEnum(push.Group, k) orelse return error.BadInput);
    const minute = struct {
        fn f(v: ?i64) ?u16 {
            const m = v orelse return null;
            return if (m >= 0 and m < 24 * 60) @intCast(m) else null;
        }
    }.f;
    const from = minute(b.quiet_from);
    const to = minute(b.quiet_to);
    return .{ .kinds = kinds.items, .quiet_from = if (to != null) from else null, .quiet_to = if (from != null) to else null };
}

test "push API bodies: subscriptions and settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: std.mem.Allocator, text: []const u8) !PushBody {
            return std.json.parseFromSliceLeaky(PushBody, al, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        }
    }.f;
    try std.testing.expectError(error.BadInput, pushSubscription(try parse(a, "{\"endpoint\":\"https://x\"}")));
    try std.testing.expectError(error.BadInput, pushSubscription(try parse(a, "{\"keys\":{\"p256dh\":\"k\",\"auth\":\"a\"}}")));
    const sub = try pushSubscription(try parse(a, "{\"endpoint\":\"https://x\",\"keys\":{\"p256dh\":\"k\",\"auth\":\"a\"},\"explicit\":true,\"old_endpoint\":\"https://o\"}"));
    try std.testing.expect(sub.explicit);
    try std.testing.expectEqualStrings("https://o", sub.old_endpoint);
    try std.testing.expect(!(try pushSubscription(try parse(a, "{\"endpoint\":\"https://x\",\"keys\":{}}"))).explicit);

    try std.testing.expectError(error.BadInput, pushSettings(a, try parse(a, "{\"kinds\":[\"ask\",\"bogus\"]}")));
    const s = try pushSettings(a, try parse(a, "{\"kinds\":[\"ask\",\"alert\"],\"quiet_from\":1320,\"quiet_to\":420}"));
    try std.testing.expectEqualSlices(push.Group, &.{ .ask, .alert }, s.kinds);
    try std.testing.expectEqual(@as(?u16, 420), s.quiet_to);
    // Half set, or out of range: no quiet hours.
    const half = try pushSettings(a, try parse(a, "{\"kinds\":[],\"quiet_from\":1320,\"quiet_to\":null}"));
    try std.testing.expect(half.quiet_from == null and half.quiet_to == null);
    const bad = try pushSettings(a, try parse(a, "{\"quiet_from\":1320,\"quiet_to\":1440}"));
    try std.testing.expect(bad.quiet_from == null and bad.quiet_to == null);
}

fn pushApi(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, post: bool, action: []const u8) !void {
    if (!post) {
        if (action.len > 0) return error.NotFound;
        const s = try push.settings(db, a);
        var kinds: std.ArrayList([]const u8) = .empty;
        for (s.kinds) |g| try kinds.append(a, @tagName(g));
        const ds = try push.devices(db, a);
        const Shown = struct { id: i64, name: []const u8, enabled: bool, created: i64, seen: i64, sent: i64, @"error": []const u8, endpoint: []const u8 };
        var shown: std.ArrayList(Shown) = .empty;
        for (ds) |d| try shown.append(a, .{ .id = d.id, .name = d.name, .enabled = d.enabled, .created = d.created, .seen = d.seen, .sent = d.sent, .@"error" = d.@"error", .endpoint = d.endpoint });
        return ok(req, a, .{
            .key = try push.publicKey(ctx, db, a),
            .devices = shown.items,
            .kinds = kinds.items,
            .quiet_from = s.quiet_from,
            .quiet_to = s.quiet_to,
        });
    }
    const len: usize = @intCast(@min(req.head.content_length orelse 0, 64 * 1024));
    const buf = try a.alloc(u8, len);
    if (len > 0) try (try req.readerExpectContinue(&.{})).readSliceAll(buf);
    const b = std.json.parseFromSliceLeaky(PushBody, a, if (len > 0) buf else "{}", .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadInput;
    const eql = std.mem.eql;
    if (eql(u8, action, "subscribe")) return ok(req, a, .{ .id = try push.subscribe(db, a, ctx.nowSeconds(), try pushSubscription(b)) });
    if (eql(u8, action, "settings")) {
        try push.saveSettings(db, a, try pushSettings(a, b));
        return ok(req, a, .{ .ok = true });
    }
    const id = b.id orelse return error.BadInput;
    if (eql(u8, action, "device")) {
        try push.setEnabled(db, id, b.enabled orelse return error.BadInput);
    } else if (eql(u8, action, "remove")) {
        try push.remove(db, id, true, ctx.nowSeconds());
    } else if (eql(u8, action, "test")) {
        try push.sendTest(ctx, cfg, db, a, id);
    } else return error.NotFound;
    return ok(req, a, .{ .ok = true });
}

// ---- voice (voice.zig): the board records, cl transcribes and speaks ----

fn voiceStatus(err: anyerror) std.http.Status {
    return switch (err) {
        error.VoiceOff => .not_found,
        error.BadInput => .unprocessable_entity,
        error.TooBig => .payload_too_large,
        else => .internal_server_error,
    };
}

fn voiceMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.VoiceOff => "voice is off: set voice.stt in ~/.config/cl/config",
        error.BadInput => "didn't catch any words",
        error.TooBig => "that recording is too long",
        error.SpeechFailed => "the voice command failed",
        error.OperatorFailed => "couldn't reach the operator; open Chat to check on it",
        else => @errorName(err),
    };
}

/// The error for the board, with the command's own reason when it failed:
/// "voice.tts failed: sh: line 1: piper: command not found".
fn voiceDetail(a: std.mem.Allocator, err: anyerror, setting: []const u8) ![]const u8 {
    const why = voice.lastError();
    if (err != error.SpeechFailed or why.len == 0) return voiceMessage(err);
    return std.fmt.allocPrint(a, "{s} failed: {s}", .{ setting, why });
}

/// POST /api/voice/ask with a WAV: transcribe it and type it into the
/// voice operator (operator.zig), which runs on `voice.model`. `since` is the time to poll /api/voice/reply/<since> from.
fn voiceAsk(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, req: *std.http.Server.Request) !void {
    const wav = try readWav(a, req);
    if (cfg.voice.stt.len == 0) return error.VoiceOff;
    const words = try voice.transcribe(ctx, a, cfg, wav);
    const since = voice.nowMs(ctx);
    const started = operator.sendInBackground(ctx, cfg, .voice, try voice.message(a, words)) catch return error.OperatorFailed;
    return ok(req, a, .{ .text = words, .since = since, .started = started });
}

/// POST /api/voice/text with a WAV: just the words, for the terminal page to
/// type into its session (README, "Dictating into a session").
fn voiceText(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, req: *std.http.Server.Request) !void {
    const wav = try readWav(a, req);
    if (cfg.voice.stt.len == 0) return error.VoiceOff;
    const words = try voice.transcribe(ctx, a, cfg, wav);
    if (words.len == 0) return error.BadInput;
    return ok(req, a, .{ .text = words });
}

fn readWav(a: std.mem.Allocator, req: *std.http.Server.Request) ![]u8 {
    const len: usize = @intCast(req.head.content_length orelse 0);
    if (len > voice.max_wav) return error.TooBig;
    const wav = try a.alloc(u8, len);
    const r = try req.readerExpectContinue(&.{});
    try r.readSliceAll(wav);
    return wav;
}

/// GET /api/voice/reply/<since>: the voice operator's `cl say` if it is newer than
/// `since` (ms), its status, and the first sentence of its written reply
/// (for when it answered without `cl say`). A long poll: it answers as soon
/// as a fresh `cl say` lands (checked every 150 ms, so the board can start
/// speaking right away) or the operator's status changes, else after 10 s.
fn voiceReply(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, req: *std.http.Server.Request, since_s: []const u8) !void {
    const since = std.fmt.parseInt(i64, since_s, 10) catch return error.BadInput;
    const op = (try tmux.voiceOperator(ctx, a)) orelse return ok(req, a, .{ .status = "gone" });
    const first = try operatorStatus(ctx, cfg, a, op);
    var status = first.status;
    var tick: usize = 0;
    while (tick < 10_000 / 150) : (tick += 1) {
        if (try voice.lastSaid(ctx, a, op.tmux_name)) |said| if (said.at > since) {
            return ok(req, a, .{ .status = status, .said = said.text, .reply = "" });
        };
        if (tick > 0 and tick % 7 == 0) { // about once a second
            const now = operatorStatus(ctx, cfg, a, op) catch break;
            status = now.status;
            if (!std.mem.eql(u8, status, first.status)) return ok(req, a, .{ .status = status, .said = null, .reply = try voice.firstSentence(a, now.reply) });
        }
        ctx.sleepMs(150);
    }
    const last = try operatorStatus(ctx, cfg, a, op);
    return ok(req, a, .{ .status = last.status, .said = null, .reply = try voice.firstSentence(a, last.reply) });
}

fn operatorStatus(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, op: tmux.Session) !struct { status: []const u8, reply: []const u8 } {
    const statuses = try claude.readStatuses(ctx, a, cfg);
    return .{
        .status = claude.statusFor(ctx, statuses, op).label(),
        .reply = if (statuses.get(op.tmux_name)) |info| info.summary else "",
    };
}

/// POST /api/voice/speak {text}: voice.tts's WAV of `text`.
fn voiceSpeak(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, req: *std.http.Server.Request, text: []const u8) !void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or t.len > voice.max_say) return error.BadInput;
    const wav = try voice.speak(ctx, a, cfg, t);
    try req.respond(wav, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "audio/wav" },
        .{ .name = "cache-control", .value = "private, no-cache" },
    } });
}

fn getTicket(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, key: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    const ss = try sessionStatuses(ctx, cfg, a);
    const live = t.tmux.len > 0 and ss.map.contains(t.tmux);
    // The tail keeps its colors and links (SGR and OSC 8 escapes): the board
    // draws it with xterm.js at the pane's width.
    var tail: []const u8 = "";
    var tail_cols: u16 = 0;
    if (live) {
        tail_cols = tmux.paneWidth(ctx, t.tmux) catch 0;
        const raw = tmux.capture(ctx, t.tmux, 50) catch "";
        tail = try a.dupe(u8, std.mem.trimEnd(u8, raw, "\n "));
        if (raw.len > 0) ctx.gpa.free(raw);
    }
    const dir = review.ticketDir(db, a, t) catch "";
    const plan = review.ticketTestPlan(a, t);
    const demo = review.ticketDemo(a, t);
    const ar = try autoreview.check(ctx, db, a, t);
    // gutter may have been opened elsewhere (cl t gutter): relay it too.
    const gutter_port = try review.gutterPort(ctx, a, t.key);
    if (gutter_port) |p| web.relayGutter(ctx, cfg, t.key, p);
    // Opened from another machine (`?relay=1`, the phone): the plan's local
    // apps get relays it can reach (web.relayPlan); the board rewrites links to them.
    var relay_buf: [8]u8 = undefined;
    const want_relays = std.mem.eql(u8, web.queryValue(req.head.target, "relay", &relay_buf) orelse "", "1");
    var relays: std.ArrayList(struct { host: []const u8, port: u16 }) = .empty;
    if (want_relays) for ([_]?review.TestPlan{ plan, demo }) |p| if (p) |pl| for (try review.localOrigins(a, pl)) |o| {
        for (relays.items) |r| {
            if (std.mem.eql(u8, r.host, o.host)) break;
        } else if (web.relayPlan(ctx, t.key, o.host, o.addr)) |port| try relays.append(a, .{ .host = o.host, .port = port });
    };
    var ip_buf: [64]u8 = undefined;
    const relay_ip = if (relays.items.len > 0) web.relayIp(ctx, &ip_buf) orelse "" else "";
    var subs: std.ArrayList(TicketRow) = .empty;
    for (try board.listTickets(db, a, .{ .parent = t.key })) |c| try subs.append(a, .{ .ticket = c, .status = ss.map.get(c.tmux) orelse "" });
    // Opened, the page asks for it every few seconds: 304 while nothing in
    // it (its session's screen included) changed.
    try okCached(req, try cached(a, .{
        .ticket = t,
        .status = ss.map.get(t.tmux) orelse "",
        .subtickets = subs.items,
        .blocks = try board.dependents(db, a, t.id),
        .comments = try board.comments(db, a, t.id),
        .events = try board.events(db, a, t.id),
        .tail = tail,
        .tail_cols = tail_cols,
        .dir = dir,
        .guide = review.hasGuide(ctx, db, a, t),
        .test_plan = plan,
        // Per step of the plan: its command's run, and whether its wait URL answers.
        .launches = if (plan) |p| try review.launchStates(ctx, a, t.key, .test_plan, p) else &.{},
        .ready = if (plan) |p| try review.waitStates(ctx, a, p) else &.{},
        // The demo, its runs and waits the same way (ticket.verified is the
        // Verified list, as markdown).
        .demo = demo,
        .demo_launches = if (demo) |p| try review.launchStates(ctx, a, t.key, .demo, p) else &.{},
        .demo_ready = if (demo) |p| try review.waitStates(ctx, a, p) else &.{},
        .gutter_port = gutter_port,
        .relays = relays.items,
        // Where they listen: the tailscale IP (the board uses its own host name
        // instead when that is a tailnet one).
        .relay_ip = relay_ip,
        // The last automated review (checked: one whose reviewer died or ran
        // too long reads as failed), and whether it is of an earlier round.
        .autoreview = ar,
        // Where it stands: unread, sent, handled, outdated... (`autoreview.standing`).
        .autoreview_standing = autoreview.standing(ar, t),
        // What "Send findings to Claude" sends (your edit, if you made one): Edit starts from it.
        .autoreview_message = if (ar) |r| (if (std.mem.eql(u8, r.status, "done")) try autoreview.message(a, r) else "") else "",
        .autoreview_session = try autoreview.sessionName(a, t.key),
        // gutter is installed: the board offers it for review.
        .gutter = t.repo and review.findGutter(ctx, a, cfg) != null,
        .main_branch = if (t.branch.len > 0 or t.change.len > 0) worktree.mergeBranch(ctx, a, (try board.getProject(db, a, t.project)).dir, t.onto) else "",
    }), null);
}
