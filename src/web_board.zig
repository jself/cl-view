//! The board in `cl web`: the /board page and its JSON API. Every action is
//! the same code `cl ticket` runs (board.zig, actions.zig, dispatch.zig,
//! review.zig), so the two always agree.
//!
//!   GET  /board                         the page
//!   GET  /api/board                     projects, tickets, sessions, profiles
//!   GET  /api/ticket/<key>              one ticket in full (+ session tail, review, test plan)
//!   POST /api/ticket                    new ticket
//!   POST /api/image/<key|new>           upload an image (the raw bytes) for a ticket's description
//!   GET  /api/image/<key|new>/<file>    one such image
//!   POST /api/ticket/<key>/<action>     edit move rank comment flag unflag dismiss done approve
//!                                       start answer key kill hide unhide rm cleanup gutter
//!                                       gutter-stop launch launch-stop test-progress
//!                                       test-results relocate park unpark
//!   POST /api/flags/dismiss             dismiss one kind of flag on several tickets
//!   POST /api/alert/<tmux>/dismiss      clear a session's alert (cl alert)
//!   POST /api/project                   add a project
//!   POST /api/project/<name>/<action>   set rm hide unhide after-merge
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const board = @import("board.zig");
const actions = @import("actions.zig");
const dispatch = @import("dispatch.zig");
const review = @import("review.zig");
const worktree = @import("worktree.zig");
const web = @import("web.zig");
const operator = @import("operator.zig");
const after_merge = @import("after_merge.zig");
const park = @import("park.zig");
const images = @import("images.zig");
const alerts = @import("alerts.zig");

const board_html = @embedFile("web/board.html");

/// Which board page this server serves: an open board whose page came from
/// another build (cl was rebuilt and restarted under it) offers a reload.
fn buildId(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{x:0>16}", .{std.hash.Wyhash.hash(0, board_html)});
}

const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
};

const html_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
};

/// Handle /board and /api/*; false when the path is someone else's.
pub fn handle(ctx: Ctx, cfg: config.Config, req: *std.http.Server.Request, path: []const u8, authed: bool) !bool {
    const is_api = std.mem.startsWith(u8, path, "/api/");
    if (!is_api and !std.mem.eql(u8, path, "/board")) return false;
    if (!authed) {
        if (is_api) {
            try req.respond("{\"error\":\"log in first\"}", .{ .status = .unauthorized, .extra_headers = &json_headers });
        } else {
            try req.respond("", .{ .status = .see_other, .extra_headers = &.{.{ .name = "location", .value = "/" }} });
        }
        return true;
    }
    if (!is_api) {
        const page = try web.withFontSize(ctx.gpa, board_html, cfg.web.font_size);
        defer ctx.gpa.free(page);
        try req.respond(page, .{ .extra_headers = &html_headers });
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

    const body: Body = if (post) readBody(req, a) catch {
        try fail(req, .bad_request, "the request body isn't valid JSON");
        return true;
    } else .{};

    route(ctx, cfg, db, a, req, post, what, name, action, body) catch |err| {
        const status: std.http.Status, const msg: []const u8 = switch (err) {
            error.NotFound => .{ .not_found, "no such ticket or project" },
            error.Exists => .{ .conflict, "already exists, or still in use" },
            error.BadInput => .{ .bad_request, "invalid input" },
            error.NoSuchDir => .{ .bad_request, "no such directory" },
            error.NoSession => .{ .conflict, "the ticket has no live session" },
            error.CustomClose => .{ .conflict, "Claude asked to close it its own way; tell Claude, or just close it" },
            error.WaitingFlag => .{ .bad_request, "that flag is waiting on you (a question, a prompt, a review, a test or a conflict); answer it or act on the ticket instead" },
            error.NothingAsked => .{ .conflict, "nothing is waiting for an answer" },
            error.BadAnswer => .{ .bad_request, "one answer per question: an option number or your own words (several numbers for a multi-select one)" },
            error.GutterFailed => .{ .internal_server_error, "gutter didn't start" },
            error.GutterMissing => .{ .conflict, review.not_installed },
            error.NotDelivered => .{ .conflict, "Claude didn't take the answer; it's still waiting. Check the session" },
            error.AlreadyStarted => .{ .conflict, "it already has a session" },
            error.TargetBusy => .{ .conflict, "its session is busy or has another ticket in progress; it waits in Queued and starts there when the session is free" },
            error.WorktreeFailed => .{ .internal_server_error, worktree.lastError() },
            error.Busy => .{ .conflict, "Claude is working in its session or waiting on you; it can move once it is idle" },
            error.NoChange => .{ .conflict, "its work has no jj change of its own to move with it" },
            error.NotParked => .{ .conflict, "it isn't parked" },
            error.Finished => .{ .conflict, "it's done; there's nothing to park" },
            error.BadDuration => .{ .bad_request, "every and max are durations like 90s, 30m, 1h, 1d, 1w (every at least 1m)" },
            error.SessionFailed => .{ .internal_server_error, "the session didn't start" },
            error.OperatorFailed => .{ .internal_server_error, "couldn't reach the operator; open Chat to check on it" },
            error.OpenSubtickets => .{ .conflict, "it has sub-tickets that aren't done yet; finish them or spin them off" },
            error.NoTestPlan => .{ .not_found, "no test plan" },
            error.NoLaunch => .{ .not_found, "the test plan has no launch command" },
            error.Conflicts => .{ .conflict, "merging it back conflicts (the files are on the ticket); it stays in Testing" },
            error.MergeFailed => .{ .internal_server_error, worktree.lastError() },
            error.SharedSession => .{ .conflict, "another ticket is in progress in its session, so stopping it would cut that one off; move or finish that ticket first, or kill the session for both" },
            error.Starting => .{ .conflict, "it is starting right now; try again in a moment" },
            error.Sqlite => .{ .internal_server_error, db.message() },
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
    skill: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    text: ?[]const u8 = null,
    send: ?bool = null,
    kind: ?[]const u8 = null,
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
    name: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    slots: ?i64 = null,
    after_merge: ?[]const u8 = null,
    after_merge_claude: ?[]const u8 = null,
    /// finish "tell": what Claude should do first.
    tell: ?[]const u8 = null,
    planners: ?i64 = null,
    spin_off: ?bool = null,
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
};

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
    if (!post) {
        if (std.mem.eql(u8, what, "board")) return getBoard(ctx, cfg, db, a, req);
        if (std.mem.eql(u8, what, "ticket") and name.len > 0) return getTicket(ctx, cfg, db, a, req, name);
        if (std.mem.eql(u8, what, "image")) return getImage(ctx, cfg, a, req, name, action);
        return error.NotFound;
    }
    if (std.mem.eql(u8, what, "ticket")) {
        if (name.len == 0) {
            const adopt_ctx: AdoptCtx = .{ .ctx = ctx, .cfg = cfg };
            const key = try board.createTicket(ctx, db, a, .{
                .project = b.project orelse "",
                .title = b.title,
                .body = b.body,
                .stage = if (b.stage) |s| board.Stage.parse(s) orelse return error.BadInput else null,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .plan = b.plan,
                .skill = nonEmpty(b.skill),
                .target = b.target,
                .profile = b.profile,
                .parent = nonEmpty(b.parent),
                .body_for_key = .{ .ctx = &adopt_ctx, .call = adoptImages },
            });
            return ok(req, a, .{ .key = key });
        }
        try ticketAction(ctx, cfg, db, a, req, name, action, b);
        return;
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
        const started = operator.sendInBackground(ctx, cfg, text) catch return error.OperatorFailed;
        return ok(req, a, .{ .ok = true, .started = started });
    }
    if (std.mem.eql(u8, what, "project")) {
        if (name.len == 0) {
            const dir = try realDir(ctx, a, b.dir orelse return error.BadInput);
            board.addProject(db, .{
                .name = b.name orelse "",
                .dir = dir,
                .prefix = nonEmpty(b.prefix),
                .slots = b.slots,
                .planners = b.planners,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .profile = b.profile,
                .after_merge = b.after_merge,
                .after_merge_claude = b.after_merge_claude,
            }) catch |e| return projectFail(req, e);
            _ = worktree.ensureJj(ctx, a, dir);
            return ok(req, a, .{ .ok = true });
        }
        if (std.mem.eql(u8, action, "set")) {
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
            }) catch |e| return projectFail(req, e);
        } else if (std.mem.eql(u8, action, "after-merge")) {
            if ((try board.getProject(db, a, name)).after_merge.len == 0) return error.BadInput;
            try after_merge.startByHand(ctx, db, a, name, nonEmpty(b.key) orelse "-");
        } else if (std.mem.eql(u8, action, "hide") or std.mem.eql(u8, action, "unhide")) {
            try board.setProjectHidden(db, name, std.mem.eql(u8, action, "hide"));
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

fn ticketAction(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, key: []const u8, action: []const u8, b: Body) !void {
    const eql = std.mem.eql;
    if (eql(u8, action, "edit")) {
        const mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null;
        try board.updateTicket(ctx, db, a, key, .{
            .project = b.project orelse "",
            .title = b.title,
            .body = b.body,
            .plan = b.plan,
            .skill = b.skill,
            .target = b.target,
            .profile = b.profile,
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
        try actions.move(ctx, cfg, db, a, key, stage, b.spin_off orelse false, try finishOf(b));
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
    } else if (eql(u8, action, "approve")) {
        _ = try actions.approve(ctx, db, a, key, b.spin_off orelse false, try finishOf(b));
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
        const r = try park.park(ctx, db, a, key, .{ .reason = b.reason orelse "", .until = b.until orelse "", .every = every, .max = try durationOr(b.max, park.default_max) });
        try park.stopSession(ctx, cfg, db, a, key);
        return ok(req, a, .{ .session = r.session orelse "", .others = r.others });
    } else if (eql(u8, action, "unpark")) {
        const r = try park.unpark(ctx, cfg, db, a, key, !(b.no_resume orelse false));
        return ok(req, a, .{ .resumed = if (r.resumed) |x| @tagName(x) else "" });
    } else if (eql(u8, action, "hide") or eql(u8, action, "unhide")) {
        _ = try board.hideNeeds(ctx, db, a, key, eql(u8, action, "hide"));
    } else if (eql(u8, action, "key")) {
        try actions.press(ctx, db, a, key, std.meta.stringToEnum(actions.Key, b.key orelse "") orelse return error.BadInput);
    } else if (eql(u8, action, "rm")) {
        const t = try board.getTicket(db, a, key);
        try board.removeTicket(db, a, t.key);
        images.removeTicket(ctx, a, cfg, t.key);
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
    } else if (eql(u8, action, "launch")) {
        _ = try review.launch(ctx, db, a, try board.getTicket(db, a, key), b.step);
    } else if (eql(u8, action, "launch-stop")) {
        try review.stopLaunch(ctx, a, key, b.step);
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
        return ok(req, a, try actions.testResults(ctx, db, a, key, steps, b.note orelse "", b.send, b.spin_off orelse false, try finishOf(b)));
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
};

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
    for (tickets) |t| try rows.append(a, .{ .ticket = t, .status = ss.map.get(t.tmux) orelse "", .working = try board.isWorking(db, t, ss.busy) });
    var profiles: std.ArrayList([]const u8) = .empty;
    for (cfg.profiles) |p| try profiles.append(a, p.name);
    try ok(req, a, .{
        .projects = try board.listProjects(db, a),
        .tickets = rows.items,
        .sessions = ss.rows,
        // Hidden projects' too: the page leaves them out as it does their tickets.
        .alerts = try alerts.list(ctx, db, a, true),
        .profiles = profiles.items,
        .now = ctx.nowSeconds(),
        .build = try buildId(a),
        // Descriptions refer to pasted images by their path under here.
        .images_dir = try images.root(ctx, a, cfg),
    });
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
    const plan = review.readTestPlan(a, t);
    // gutter may have been opened elsewhere (cl t gutter): relay it too.
    const gutter_port = try review.gutterPort(ctx, a, t.key);
    if (gutter_port) |p| web.relayGutter(ctx, cfg, t.key, p);
    var subs: std.ArrayList(TicketRow) = .empty;
    for (try board.listTickets(db, a, .{ .parent = t.key })) |c| try subs.append(a, .{ .ticket = c, .status = ss.map.get(c.tmux) orelse "" });
    try ok(req, a, .{
        .ticket = t,
        .status = ss.map.get(t.tmux) orelse "",
        .subtickets = subs.items,
        .comments = try board.comments(db, a, t.id),
        .events = try board.events(db, a, t.id),
        .tail = tail,
        .tail_cols = tail_cols,
        .dir = dir,
        .guide = dir.len > 0 and review.hasGuide(ctx, a, dir),
        .test_plan = plan,
        // Per step of the plan: its command's run, and whether its wait URL answers.
        .launches = if (plan) |p| try review.launchStates(ctx, a, t.key, p) else &.{},
        .ready = if (plan) |p| try review.waitStates(ctx, a, p) else &.{},
        .gutter_port = gutter_port,
        // gutter is installed: the board offers it for review.
        .gutter = review.findGutter(ctx, a, cfg) != null,
        .main_branch = if (t.branch.len > 0 or t.change.len > 0) worktree.mainBranch(ctx, a, (try board.getProject(db, a, t.project)).dir) else "",
    });
}
