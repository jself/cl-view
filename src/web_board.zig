//! The board in `cl web`: the /board page and its JSON API. Every action is
//! the same code `cl ticket` runs (board.zig, actions.zig, dispatch.zig,
//! review.zig), so the two always agree.
//!
//!   GET  /board                         the page
//!   GET  /api/board                     projects, tickets, sessions, profiles
//!   GET  /api/ticket/<key>              one ticket in full (+ session tail, review, test plan)
//!   POST /api/ticket                    new ticket
//!   POST /api/ticket/<key>/<action>     edit move rank comment flag unflag done approve start
//!                                       answer key rm cleanup gutter gutter-stop launch
//!                                       launch-stop test-results relocate
//!   POST /api/project                   add a project
//!   POST /api/project/<name>/<action>   set rm
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

const board_html = @embedFile("web/board.html");

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
    const name = parts.next() orelse "";
    const action = parts.next() orelse "";

    const body: Body = if (post) readBody(req, a) catch {
        try fail(req, .bad_request, "the request body isn't valid JSON");
        return true;
    } else .{};

    route(ctx, cfg, db, a, req, post, what, name, action, body) catch |err| {
        const status: std.http.Status, const msg: []const u8 = switch (err) {
            error.NotFound => .{ .not_found, "no such ticket or project" },
            error.Exists => .{ .conflict, "already exists, or still in use" },
            error.BadInput => .{ .bad_request, "invalid input" },
            error.NoSession => .{ .conflict, "the ticket has no live session" },
            error.NothingAsked => .{ .conflict, "nothing is waiting for an answer" },
            error.BadAnswer => .{ .bad_request, "one answer per question: an option number or your own words (several numbers for a multi-select one)" },
            error.GutterFailed => .{ .internal_server_error, "gutter didn't start (is it installed?)" },
            error.NotDelivered => .{ .conflict, "Claude didn't take the answer; it's still waiting. Check the session" },
            error.AlreadyStarted => .{ .conflict, "it already has a session" },
            error.TargetBusy => .{ .conflict, "its session is busy or has another ticket in progress; it waits in Queued and starts there when the session is free" },
            error.WorktreeFailed => .{ .internal_server_error, worktree.lastError() },
            error.Busy => .{ .conflict, "Claude is working in its session or waiting on you; it can move once it is idle" },
            error.NoChange => .{ .conflict, "its work has no jj change of its own to move with it" },
            error.SessionFailed => .{ .internal_server_error, "the session didn't start" },
            error.OpenSubtickets => .{ .conflict, "it has sub-tickets that aren't done yet; finish them or spin them off" },
            error.NoTestPlan => .{ .not_found, "no test plan (.claude/test-plan.md)" },
            error.NoLaunch => .{ .not_found, "the test plan has no launch command" },
            error.Conflicts => .{ .conflict, "merging it back conflicts (the files are on the ticket); it stays in Testing" },
            error.MergeFailed => .{ .internal_server_error, worktree.lastError() },
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
    detail: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    now: ?bool = null,
    answers: ?[]const []const u8 = null,
    key: ?[]const u8 = null,
    branch: ?bool = null,
    checks: ?[]const review.Check = null,
    note: ?[]const u8 = null,
    name: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    slots: ?i64 = null,
    spin_off: ?bool = null,
    /// Going to Done: "merge", "pr" or "close" (the default).
    finish: ?[]const u8 = null,
    /// Moving or ranking: the keys of the tickets it lands between.
    after: ?[]const u8 = null,
    before: ?[]const u8 = null,
};

fn finishOf(b: Body) !actions.Finish {
    return actions.Finish.parse(b.finish orelse "close") orelse error.BadInput;
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
        return error.NotFound;
    }
    if (std.mem.eql(u8, what, "ticket")) {
        if (name.len == 0) {
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
            });
            return ok(req, a, .{ .key = key });
        }
        try ticketAction(ctx, cfg, db, a, req, name, action, b);
        return;
    }
    if (std.mem.eql(u8, what, "project")) {
        if (name.len == 0) {
            const dir = try realDir(ctx, a, b.dir orelse return error.BadInput);
            try board.addProject(db, .{
                .name = b.name orelse "",
                .dir = dir,
                .prefix = nonEmpty(b.prefix),
                .slots = b.slots,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .profile = b.profile,
            });
            _ = worktree.ensureJj(ctx, a, dir);
            return ok(req, a, .{ .ok = true });
        }
        if (std.mem.eql(u8, action, "set")) {
            try board.updateProject(db, name, .{
                .name = b.name orelse "",
                .dir = if (b.dir) |d| try realDir(ctx, a, d) else "",
                .prefix = nonEmpty(b.prefix),
                .slots = b.slots,
                .mode = if (b.mode) |m| board.Mode.parse(m) orelse return error.BadInput else null,
                .profile = b.profile,
            });
        } else if (std.mem.eql(u8, action, "rm")) {
            try board.removeProject(db, name);
        } else return error.NotFound;
        return ok(req, a, .{ .ok = true });
    }
    return error.NotFound;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn realDir(ctx: Ctx, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const expanded = try ctx.expandHome(path);
    defer ctx.gpa.free(expanded);
    return std.Io.Dir.cwd().realPathFileAlloc(ctx.io, expanded, a) catch error.BadInput;
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
        if (mode) |m| _ = try dispatch.relocate(ctx, cfg, db, a, try board.getTicket(db, a, key), m);
    } else if (eql(u8, action, "relocate")) {
        const m = board.Mode.parse(b.mode orelse "") orelse return error.BadInput;
        const r = try dispatch.relocate(ctx, cfg, db, a, try board.getTicket(db, a, key), m);
        return ok(req, a, .{ .result = @tagName(r) });
    } else if (eql(u8, action, "move")) {
        const stage = board.Stage.parse(b.stage orelse "") orelse return error.BadInput;
        // Ranked first, so the dispatcher never sees it queued in the wrong place.
        if (nonEmpty(b.after) != null or nonEmpty(b.before) != null) try board.rankTicket(db, a, key, nonEmpty(b.after), nonEmpty(b.before));
        try actions.move(ctx, db, a, key, stage, b.spin_off orelse false, try finishOf(b));
    } else if (eql(u8, action, "rank")) {
        try board.rankTicket(db, a, key, nonEmpty(b.after), nonEmpty(b.before));
    } else if (eql(u8, action, "comment")) {
        const r = try actions.comment(ctx, db, a, key, "you", b.text orelse return error.BadInput, b.send orelse false);
        return ok(req, a, r);
    } else if (eql(u8, action, "flag")) {
        try board.setFlag(ctx, db, a, key, b.kind orelse return error.BadInput, "manual", b.detail orelse "");
    } else if (eql(u8, action, "unflag")) {
        try board.clearFlag(ctx, db, a, key, b.kind orelse return error.BadInput);
    } else if (eql(u8, action, "done")) {
        try board.done(ctx, db, a, key, b.summary orelse "");
    } else if (eql(u8, action, "approve")) {
        _ = try actions.approve(ctx, db, a, key, b.spin_off orelse false, try finishOf(b));
    } else if (eql(u8, action, "start")) {
        const t = try board.getTicket(db, a, key);
        try dispatch.start(ctx, cfg, db, a, t, b.now orelse false);
    } else if (eql(u8, action, "answer")) {
        try actions.answer(ctx, cfg, db, a, key, b.answers orelse return error.BadInput);
    } else if (eql(u8, action, "key")) {
        try actions.press(ctx, db, a, key, std.meta.stringToEnum(actions.Key, b.key orelse "") orelse return error.BadInput);
    } else if (eql(u8, action, "rm")) {
        try board.removeTicket(db, a, key);
    } else if (eql(u8, action, "cleanup")) {
        const t = try board.getTicket(db, a, key);
        if (t.worktree.len == 0) return error.BadInput;
        const p = try board.getProject(db, a, t.project);
        try worktree.remove(ctx, a, p.dir, .{ .path = t.worktree, .branch = t.branch }, b.branch orelse false);
        try board.setSession(ctx, db, t.id, t.tmux, t.session_id, "", if (b.branch orelse false) "" else t.branch);
        try board.logEvent(ctx, db, t.id, "worktree removed", t.worktree);
    } else if (eql(u8, action, "gutter")) {
        const t = try board.getTicket(db, a, key);
        const port = try review.startGutter(ctx, db, a, t);
        web.relayGutter(ctx, cfg, t.key, port);
        return ok(req, a, .{ .port = port });
    } else if (eql(u8, action, "gutter-stop")) {
        try review.stopGutter(ctx, a, key);
    } else if (eql(u8, action, "launch")) {
        try review.launch(ctx, db, a, try board.getTicket(db, a, key));
    } else if (eql(u8, action, "launch-stop")) {
        try review.stopLaunch(ctx, a, key);
    } else if (eql(u8, action, "test-results")) {
        const passed = try actions.testResults(ctx, db, a, key, b.checks orelse return error.BadInput, b.note orelse "", b.spin_off orelse false, try finishOf(b));
        return ok(req, a, .{ .passed = passed });
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
        .profiles = profiles.items,
        .now = ctx.nowSeconds(),
    });
}

fn getTicket(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, req: *std.http.Server.Request, key: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    const ss = try sessionStatuses(ctx, cfg, a);
    const live = t.tmux.len > 0 and ss.map.contains(t.tmux);
    var tail: []const u8 = "";
    if (live) {
        const raw = tmux.capturePlainLines(ctx, t.tmux, 50) catch "";
        tail = try a.dupe(u8, std.mem.trimEnd(u8, raw, "\n "));
        if (raw.len > 0) ctx.gpa.free(raw);
    }
    const dir = review.ticketDir(db, a, t) catch "";
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
        .dir = dir,
        .guide = dir.len > 0 and review.hasGuide(ctx, a, dir),
        .test_plan = if (dir.len > 0) review.readTestPlan(ctx, a, dir) else null,
        .launch = try review.launchState(ctx, a, t.key),
        .gutter_port = gutter_port,
        .main_branch = if (t.branch.len > 0 or t.change.len > 0) worktree.mainBranch(ctx, a, (try board.getProject(db, a, t.project)).dir) else "",
    });
}
