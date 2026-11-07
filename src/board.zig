//! The ticket board: projects, tickets, comments, flags and an event log in
//! SQLite (<board.dir>/board.db). Everything the CLI and the web board do to
//! tickets goes through here, so both behave the same.
//!
//! Stages are the workflow (columns). Flags say what needs the human and are
//! independent of the stage: several can be set at once, and each is set by
//! hand or automatically (by `done`, moves, or the session's state).
//!
//! A ticket can have sub-tickets (one level or more): full tickets with their
//! own key, stage, flags and comments, linked to a parent. The ticket's agent
//! creates them for pieces of its work; the board can hide them.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const sqlite = @import("db.zig");

pub const Db = sqlite.Db;

pub const Stage = enum {
    backlog,
    planning,
    queued,
    running,
    review,
    testing,
    done,

    pub fn parse(s: []const u8) ?Stage {
        return std.meta.stringToEnum(Stage, s);
    }
};

/// How a ticket gets a session: wait its turn in a chosen session (queue), or
/// get its own worktree and session, in parallel up to the project's slots.
pub const Mode = enum {
    queue,
    worktree,

    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

/// The flags the board knows. Others are allowed (set by hand).
pub const flag_input = "input"; // blocked on a permission prompt
pub const flag_question = "question"; // Claude asked something
pub const flag_review = "review"; // Claude said done; review it
pub const flag_testing = "testing"; // try it out
pub const flag_conflict = "conflict"; // merging it back conflicts
pub const flag_after_merge = "after-merge"; // the project's after-merge command failed
pub const flag_merge_failed = "merge-failed"; // approved, but its merge (or PR) didn't land
pub const flag_unmerged = "unmerged"; // Done, but its branch's work isn't on its target (trunk, or Ticket.onto)
pub const flag_unparked = "unparked"; // its park's condition came true; it resumed
pub const flag_park_expired = "park-expired"; // its park's check never passed in time
pub const flag_idle = "idle"; // Claude ended its turn; nothing else asks, so it waits on you
pub const flag_ready_to_close = "ready-to-close"; // its sub-tickets are all done, but it has work of its own

pub const Project = struct {
    name: []const u8,
    dir: []const u8,
    prefix: []const u8,
    /// Worktree tickets that may run at once.
    slots: i64,
    /// Default mode for new tickets.
    mode: Mode,
    /// cl profile for new sessions; "" means the default.
    profile: []const u8,
    /// Shell command run on the merged trunk after cl merges a ticket into
    /// it (see after_merge.zig); "" for none.
    after_merge: []const u8 = "",
    /// What Claude is asked to do after a merge when there is no command, or
    /// when it fails: "" for the default (rebuild and restart what runs from
    /// the checkout), "none" for nothing.
    after_merge_claude: []const u8 = "",
    /// Kept out of the board's views, Needs You, `cl ticket needs` and
    /// `cl ticket list` (unless asked for). Only what's shown: its queued
    /// tickets still run.
    hidden: bool = false,
    /// Planning sessions that may run at once. They write no code, so they
    /// don't wait for the queue or a worktree slot, only for this.
    planners: i64 = default_planners,
    /// The dispatcher starts nothing new in it (`cl project pause`): no queued
    /// ticket, planning session or park check's resume. What already runs
    /// goes on; what you start by hand starts.
    paused: bool = false,
    /// The branch (jj bookmark or git branch) its tickets start from and
    /// merge into, when it isn't trunk; "" for trunk. A ticket's own
    /// `Ticket.onto` wins.
    onto: []const u8 = "",
    /// The skill the automated review uses (`cl project set --review-skill`),
    /// "" for cl's own review instructions (see autoreview.zig).
    review_skill: []const u8 = "",
};

pub const Flag = struct {
    kind: []const u8,
    /// "auto" or "manual".
    source: []const u8,
    detail: []const u8,
    at: i64,
    /// Kept out of Needs You (and `cl ticket needs`) until the ticket raises
    /// a new flag or this one asks something new.
    hidden: bool = false,
};

pub const Comment = struct {
    /// "you" or "claude".
    author: []const u8,
    body: []const u8,
    /// Typed into the ticket's session.
    sent: bool,
    at: i64,
};

/// A parked ticket: its session was killed while it waits on something
/// outside cl (park.zig). It stays out of Needs You until it wakes.
pub const Park = struct {
    reason: []const u8,
    /// Shell command that says the wait is over (exit 0); "" for none (it
    /// waits for `unpark`).
    until: []const u8 = "",
    /// Seconds between checks.
    every: i64 = 0,
    /// When it was parked.
    at: i64,
    /// Checks stop after this (0: no checks).
    deadline: i64 = 0,
    /// When the next check is due.
    next: i64 = 0,
    /// When the last check finished (0: none yet) and what it said.
    checked: i64 = 0,
    result: []const u8 = "",
};

pub const Event = struct {
    kind: []const u8,
    detail: []const u8,
    at: i64,
};

/// A ticket another one waits on (Ticket.blocked_by).
pub const Dep = struct {
    id: i64,
    key: []const u8,
    title: []const u8,
    stage: Stage,
    /// From the order of sub-tickets (the one before it), not a link of its own.
    order: bool = false,
    /// Its parent, which has work of its own and runs first.
    parent: bool = false,
};

pub const Ticket = struct {
    id: i64,
    key: []const u8,
    project: []const u8,
    title: []const u8,
    body: []const u8,
    stage: Stage,
    mode: Mode,
    /// Starts with a planning step.
    plan: bool,
    /// A skill to plan with (grilling, wayfinder, ...), "" for none.
    skill: []const u8,
    /// The revision it started from (git commit, jj commit id): what gutter
    /// diffs against.
    base: []const u8 = "",
    /// Queue mode: the tmux session it runs in.
    target: []const u8,
    worktree: []const u8,
    /// Its branch (git) or bookmark (jj).
    branch: []const u8,
    /// The branch it starts from and merges into (a jj bookmark or git
    /// branch, like a long-lived feature branch), "" for trunk: its own
    /// (`onto_own`), else its project's (`Project.onto`).
    onto: []const u8 = "",
    /// The target set on the ticket itself (`cl ticket new/edit --onto`,
    /// or its parent's when it was made), "" to go by the project's.
    onto_own: []const u8 = "",
    /// jj: the change its work goes in (change ids survive rewrites), "" for
    /// none (git, or a sub-ticket going on in its parent's change).
    change: []const u8 = "",
    profile: []const u8,
    /// The tmux session working on it, once started.
    tmux: []const u8,
    session_id: []const u8,
    /// Claude's summary from `done`.
    summary: []const u8,
    /// The test plan Claude gave with `done` (markdown: Setup, Launch,
    /// Checks), "" for none.
    test_plan: []const u8 = "",
    /// The review guide for gutter its session last wrote, taken from
    /// .claude/review-guide.md at `done`; "" for none.
    review_guide: []const u8 = "",
    /// The last automated review (autoreview.zig), as JSON: its status,
    /// summary and findings; "" for none.
    autoreview: []const u8 = "",
    /// The plan its planning session gave with `done` (markdown), "" for
    /// none: what the session that builds it is told.
    plan_md: []const u8 = "",
    /// How far the human got testing it (the board's JSON: results, notes,
    /// comments, the step they're on), "" for not started. A new plan or
    /// submitted results start it over.
    test_progress: []const u8 = "",
    /// Claude said not to finish it the usual way (merge, PR): what to do
    /// instead. The board offers only that ("Custom close"); "" for none.
    custom_close: []const u8 = "",
    /// The AskUserQuestion its session has on screen, from the PreToolUse
    /// hook: {"id": tool_use_id, "input": the tool's input}, "" for none.
    /// Claude Code writes the call to the transcript only once it is
    /// answered, so while the menu is open this is where its questions are.
    asking: []const u8 = "",
    /// 1, then +1 each time it is sent back after Claude said done.
    round: i64,
    created: i64,
    updated: i64,
    /// Key of the parent ticket, "" for a top-level one.
    parent: []const u8,
    /// Number of sub-tickets.
    children: i64,
    /// How many of them are Done.
    children_done: i64 = 0,
    /// Only a container for its sub-tickets, with no work of its own: it
    /// never gets a session. Queued, it moves to Running when one of them
    /// starts, and to Done when the last one is done (see `subticketsSettled`).
    umbrella: bool = false,
    /// On its way to Done: "merge" or "pr" while Claude merges its branch or
    /// opens a PR (it moves to Done when Claude is finished), else "".
    finishing: []const u8 = "",
    /// Priority: lower comes first. The board shows each column in rank order
    /// and the dispatcher starts waiting tickets in it.
    rank: i64 = 0,
    /// Its session was killed on purpose (`cl ticket kill`, the board's Kill):
    /// it waits for you to restart it rather than for the dispatcher.
    killed: bool = false,
    /// A sub-ticket that doesn't wait for the sub-ticket before it (see
    /// `blocked_by`).
    parallel: bool = false,
    /// A session has taken it up to build it (a "started" event; planning
    /// doesn't count). A parent that never started has no work of its own:
    /// it runs as its sub-tickets (`held`).
    started: bool = false,
    /// What it waits on before the dispatcher starts it: the tickets linked
    /// with `cl ticket edit --after`, and for a sub-ticket that isn't
    /// parallel, the sub-ticket ranked before it (and the parallel ones in
    /// between, back to the first that isn't). Done ones included.
    blocked_by: []Dep = &.{},
    flags: []Flag = &.{},
    /// Set while it is parked.
    park: ?Park = null,
};

pub const Error = error{
    Sqlite,
    NotFound,
    Exists,
    BadInput,
    OutOfMemory,
    /// The tickets would wait on each other in a circle, so none would start.
    Cycle,
};

/// Worktree slots a new project gets when none are given.
pub const default_slots = 3;

/// Planning sessions a project runs at once when none are given.
pub const default_planners = 2;

const schema =
    \\PRAGMA journal_mode = WAL;
    \\CREATE TABLE IF NOT EXISTS projects (
    \\  name TEXT PRIMARY KEY,
    \\  dir TEXT NOT NULL,
    \\  prefix TEXT NOT NULL UNIQUE,
    \\  slots INTEGER NOT NULL DEFAULT
++ std.fmt.comptimePrint(" {d},\n", .{default_slots}) ++
    \\  mode TEXT NOT NULL DEFAULT 'queue',
    \\  profile TEXT NOT NULL DEFAULT '',
    \\  next_num INTEGER NOT NULL DEFAULT 1,
    \\  after_merge TEXT NOT NULL DEFAULT '',
    \\  after_merge_pid INTEGER NOT NULL DEFAULT 0,
    \\  after_merge_pending TEXT NOT NULL DEFAULT '',
    \\  after_merge_claude TEXT NOT NULL DEFAULT '',
    \\  hidden INTEGER NOT NULL DEFAULT 0,
    \\  paused INTEGER NOT NULL DEFAULT 0,
    \\  onto TEXT NOT NULL DEFAULT '',
    \\  review_skill TEXT NOT NULL DEFAULT '',
    \\  planners INTEGER NOT NULL DEFAULT
++ std.fmt.comptimePrint(" {d}\n", .{default_planners}) ++
    \\);
    \\CREATE TABLE IF NOT EXISTS tickets (
    \\  id INTEGER PRIMARY KEY,
    \\  key TEXT NOT NULL UNIQUE,
    \\  project TEXT NOT NULL REFERENCES projects(name) ON UPDATE CASCADE,
    \\  title TEXT NOT NULL,
    \\  body TEXT NOT NULL DEFAULT '',
    \\  stage TEXT NOT NULL DEFAULT 'backlog',
    \\  mode TEXT NOT NULL DEFAULT 'queue',
    \\  plan INTEGER NOT NULL DEFAULT 0,
    \\  target TEXT NOT NULL DEFAULT '',
    \\  worktree TEXT NOT NULL DEFAULT '',
    \\  branch TEXT NOT NULL DEFAULT '',
    \\  profile TEXT NOT NULL DEFAULT '',
    \\  tmux TEXT NOT NULL DEFAULT '',
    \\  session_id TEXT NOT NULL DEFAULT '',
    \\  summary TEXT NOT NULL DEFAULT '',
    \\  round INTEGER NOT NULL DEFAULT 1,
    \\  parent INTEGER REFERENCES tickets(id),
    \\  skill TEXT NOT NULL DEFAULT '',
    \\  base TEXT NOT NULL DEFAULT '',
    \\  finishing TEXT NOT NULL DEFAULT '',
    \\  change_id TEXT NOT NULL DEFAULT '',
    \\  rank INTEGER NOT NULL DEFAULT 0,
    \\  killed INTEGER NOT NULL DEFAULT 0,
    \\  test_plan TEXT NOT NULL DEFAULT '',
    \\  test_progress TEXT NOT NULL DEFAULT '',
    \\  custom_close TEXT NOT NULL DEFAULT '',
    \\  plan_md TEXT NOT NULL DEFAULT '',
    \\  review_guide TEXT NOT NULL DEFAULT '',
    \\  autoreview TEXT NOT NULL DEFAULT '',
    \\  asking TEXT NOT NULL DEFAULT '',
    \\  parallel INTEGER NOT NULL DEFAULT 0,
    \\  umbrella INTEGER NOT NULL DEFAULT 0,
    \\  onto TEXT NOT NULL DEFAULT '',
    \\  created INTEGER NOT NULL,
    \\  updated INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS tickets_stage ON tickets(stage);
    \\CREATE TABLE IF NOT EXISTS comments (
    \\  id INTEGER PRIMARY KEY,
    \\  ticket INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    \\  author TEXT NOT NULL,
    \\  body TEXT NOT NULL,
    \\  sent INTEGER NOT NULL DEFAULT 0,
    \\  at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS comments_ticket ON comments(ticket);
    \\CREATE TABLE IF NOT EXISTS flags (
    \\  id INTEGER PRIMARY KEY,
    \\  ticket INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    \\  kind TEXT NOT NULL,
    \\  source TEXT NOT NULL,
    \\  detail TEXT NOT NULL DEFAULT '',
    \\  at INTEGER NOT NULL,
    \\  cleared INTEGER,
    \\  hidden INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS flags_active ON flags(ticket, kind) WHERE cleared IS NULL;
    \\CREATE TABLE IF NOT EXISTS events (
    \\  id INTEGER PRIMARY KEY,
    \\  ticket INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    \\  kind TEXT NOT NULL,
    \\  detail TEXT NOT NULL DEFAULT '',
    \\  at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS events_ticket ON events(ticket);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS tickets_fts USING fts5(key, title, body, content='tickets', content_rowid='id');
    \\CREATE TRIGGER IF NOT EXISTS tickets_ai AFTER INSERT ON tickets BEGIN
    \\  INSERT INTO tickets_fts(rowid, key, title, body) VALUES (new.id, new.key, new.title, new.body);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS tickets_ad AFTER DELETE ON tickets BEGIN
    \\  INSERT INTO tickets_fts(tickets_fts, rowid, key, title, body) VALUES ('delete', old.id, old.key, old.title, old.body);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS tickets_au AFTER UPDATE OF key, title, body ON tickets BEGIN
    \\  INSERT INTO tickets_fts(tickets_fts, rowid, key, title, body) VALUES ('delete', old.id, old.key, old.title, old.body);
    \\  INSERT INTO tickets_fts(rowid, key, title, body) VALUES (new.id, new.key, new.title, new.body);
    \\END;
    \\CREATE VIRTUAL TABLE IF NOT EXISTS comments_fts USING fts5(body, content='comments', content_rowid='id');
    \\CREATE TRIGGER IF NOT EXISTS comments_ai AFTER INSERT ON comments BEGIN
    \\  INSERT INTO comments_fts(rowid, body) VALUES (new.id, new.body);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS comments_ad AFTER DELETE ON comments BEGIN
    \\  INSERT INTO comments_fts(comments_fts, rowid, body) VALUES ('delete', old.id, old.body);
    \\END;
    \\CREATE INDEX IF NOT EXISTS tickets_parent ON tickets(parent);
;

/// `board.dir`, or ~/.local/state/cl; created if missing.
pub fn dirPath(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    const dir = if (cfg.board.dir.len > 0) cfg.board.dir else try std.fmt.allocPrint(a, "{s}/.local/state/cl", .{ctx.home});
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    return dir;
}

/// Open (creating if needed) the board in `board.dir`.
pub fn open(ctx: Ctx, cfg: config.Config) !Db {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const dir = try dirPath(ctx, fba.allocator(), cfg);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/board.db", .{dir});
    const db = try Db.open(path);
    errdefer db.close();
    try migrate(db);
    return db;
}

const version = 11;

/// Version 11: parked tickets. Made whatever the version says, as the
/// columns above are.
const parks_schema =
    \\CREATE TABLE IF NOT EXISTS parks (
    \\  ticket INTEGER PRIMARY KEY REFERENCES tickets(id) ON DELETE CASCADE,
    \\  reason TEXT NOT NULL,
    \\  until_cmd TEXT NOT NULL DEFAULT '',
    \\  every INTEGER NOT NULL DEFAULT 0,
    \\  at INTEGER NOT NULL,
    \\  deadline INTEGER NOT NULL DEFAULT 0,
    \\  next INTEGER NOT NULL DEFAULT 0,
    \\  checked INTEGER NOT NULL DEFAULT 0,
    \\  result TEXT NOT NULL DEFAULT ''
    \\);
;

/// Dependencies: `ticket` doesn't start until `blocker` is Done. Made
/// whatever the version says, as the columns above are.
const deps_schema =
    \\CREATE TABLE IF NOT EXISTS deps (
    \\  ticket INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    \\  blocker INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    \\  PRIMARY KEY (ticket, blocker)
    \\);
    \\CREATE INDEX IF NOT EXISTS deps_blocker ON deps(blocker);
;

pub fn migrate(db: Db) !void {
    const have = (try db.int("PRAGMA user_version", .{})) orelse 0;
    // Added whatever the version says: branches built in parallel each take
    // the next version number, so a board another branch moved to it can
    // still lack these. Test plans used to be read from .claude/test-plan.md
    // in the ticket's directory, which tickets without a worktree shared.
    if (have >= 1) {
        _ = try addColumn(db, "tickets", "test_plan", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "test_progress", "TEXT NOT NULL DEFAULT ''");
        // Version 10: the after-merge command and its run queue.
        _ = try addColumn(db, "projects", "after_merge", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "projects", "after_merge_pid", "INTEGER NOT NULL DEFAULT 0");
        _ = try addColumn(db, "projects", "after_merge_pending", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "projects", "after_merge_claude", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "custom_close", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "projects", "hidden", "INTEGER NOT NULL DEFAULT 0");
        try db.execMulti(parks_schema);
        // Planning sessions used to run in the ticket's own session, so
        // nothing had to carry the plan over.
        _ = try addColumn(db, "tickets", "plan_md", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "projects", "planners", std.fmt.comptimePrint("INTEGER NOT NULL DEFAULT {d}", .{default_planners}));
        // Review guides used to be read from .claude/review-guide.md in the
        // ticket's directory, which tickets without a worktree shared.
        _ = try addColumn(db, "tickets", "review_guide", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "projects", "paused", "INTEGER NOT NULL DEFAULT 0");
        // AskUserQuestion's questions used to come only from the transcript.
        _ = try addColumn(db, "tickets", "asking", "TEXT NOT NULL DEFAULT ''");
        // Dependencies: links of their own, and sub-tickets in order.
        _ = try addColumn(db, "tickets", "parallel", "INTEGER NOT NULL DEFAULT 0");
        try db.execMulti(deps_schema);
        // Umbrellas used to be guessed: a parent that never started had no
        // work of its own. Those become umbrellas, once, as the column comes.
        if (try addColumn(db, "tickets", "umbrella", "INTEGER NOT NULL DEFAULT 0")) try db.execMulti(
            \\UPDATE tickets SET umbrella = 1 WHERE stage != 'done'
            \\  AND EXISTS (SELECT 1 FROM tickets c WHERE c.parent = tickets.id)
            \\  AND NOT EXISTS (SELECT 1 FROM events e WHERE e.ticket = tickets.id AND e.kind = 'started')
        );
        // Target branches other than trunk.
        _ = try addColumn(db, "projects", "onto", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "onto", "TEXT NOT NULL DEFAULT ''");
        // Automated reviews.
        _ = try addColumn(db, "tickets", "autoreview", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "projects", "review_skill", "TEXT NOT NULL DEFAULT ''");
    }
    if (have >= version) return;
    // Version 1 had no sub-tickets, version 2 no planning skill.
    if (have >= 1 and have < 2) try db.execMulti("ALTER TABLE tickets ADD COLUMN parent INTEGER REFERENCES tickets(id)");
    if (have >= 1 and have < 3) try db.execMulti("ALTER TABLE tickets ADD COLUMN skill TEXT NOT NULL DEFAULT ''");
    if (have >= 1 and have < 4) try db.execMulti("ALTER TABLE tickets ADD COLUMN base TEXT NOT NULL DEFAULT ''");
    if (have >= 1 and have < 5) try db.execMulti("ALTER TABLE tickets ADD COLUMN finishing TEXT NOT NULL DEFAULT ''");
    if (have >= 1 and have < 6) try db.execMulti("ALTER TABLE tickets ADD COLUMN change_id TEXT NOT NULL DEFAULT ''");
    // Version 6 had no priority: oldest first, as the dispatcher went.
    if (have >= 1 and have < 7) try db.execMulti(std.fmt.comptimePrint("ALTER TABLE tickets ADD COLUMN rank INTEGER NOT NULL DEFAULT 0; UPDATE tickets SET rank = id * {d}", .{rank_gap}));
    // Version 7 had no kill, nor hiding from Needs You. Added only if missing:
    // another branch's build may have taken version 8 for a column of its own.
    if (have >= 1 and have < 9) {
        _ = try addColumn(db, "tickets", "killed", "INTEGER NOT NULL DEFAULT 0");
        _ = try addColumn(db, "flags", "hidden", "INTEGER NOT NULL DEFAULT 0");
    }
    try db.execMulti(schema);
    try db.execMulti(parks_schema);
    try db.execMulti(deps_schema);
    try db.execMulti(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{version}));
}

/// Add a column unless the table has it; true when it was added.
fn addColumn(db: Db, comptime table: []const u8, comptime column: []const u8, comptime decl: []const u8) !bool {
    if ((try db.int("SELECT 1 FROM pragma_table_info('" ++ table ++ "') WHERE name = '" ++ column ++ "'", .{})) != null) return false;
    try db.execMulti("ALTER TABLE " ++ table ++ " ADD COLUMN " ++ column ++ " " ++ decl);
    return true;
}

test "an approved plan queues, and the plan is kept" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try std.testing.expectEqual(@as(i64, default_planners), (try getProject(db, a, "qa")).planners);
    try updateProject(db, "qa", .{ .name = "", .dir = "", .planners = 1 });
    try std.testing.expectEqual(@as(i64, 1), (try getProject(db, a, "qa")).planners);
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Plan me", .plan = true });
    const t = try getTicket(db, a, k);
    try setPlan(ctx, db, t.id, "## Steps\n1. do it\n");
    try done(ctx, db, a, k, "Plan ready");
    try std.testing.expectEqual(Stage.planning, (try getTicket(db, a, k)).stage);
    try std.testing.expectEqual(Stage.planning, try approve(ctx, db, a, k));
    const after = try getTicket(db, a, k);
    try std.testing.expectEqual(Stage.queued, after.stage);
    try std.testing.expectEqualStrings("## Steps\n1. do it\n", after.plan_md);
    try std.testing.expectEqual(@as(usize, 0), after.flags.len);
}

test "feedback on a ready plan keeps it ready to approve" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Plan me", .plan = true });
    try done(ctx, db, a, k, "Plan ready");
    // Claude may only answer it, without handing in a new plan: the one it
    // handed in can still be approved.
    const r = try addComment(ctx, db, a, k, "you", "why step 2?", true);
    try std.testing.expect(!r.sent_back);
    const t = try getTicket(db, a, k);
    try std.testing.expectEqual(Stage.planning, t.stage);
    try std.testing.expectEqual(@as(usize, 1), t.flags.len);
    try std.testing.expectEqual(Stage.planning, try approve(ctx, db, a, k));
    try std.testing.expectEqual(Stage.queued, (try getTicket(db, a, k)).stage);
}

test "a ticket's target branch: its own, else its parent's when made, else the project's" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const plain = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Plain" });
    try std.testing.expectEqualStrings("", (try getTicket(db, a, plain)).onto);
    const parent = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Venues", .onto = "feature/venues" });
    const sub = try createTicket(ctx, db, a, .{ .parent = parent, .title = "Part" });
    const st = try getTicket(db, a, sub);
    try std.testing.expectEqualStrings("feature/venues", st.onto);
    try std.testing.expectEqualStrings("feature/venues", st.onto_own);
    // The project's target, for tickets without one of their own.
    try updateProject(db, "qa", .{ .name = "", .dir = "", .onto = "develop" });
    try std.testing.expectEqualStrings("develop", (try getProject(db, a, "qa")).onto);
    const p = try getTicket(db, a, plain);
    try std.testing.expectEqualStrings("develop", p.onto);
    try std.testing.expectEqualStrings("", p.onto_own);
    try std.testing.expectEqualStrings("feature/venues", (try getTicket(db, a, sub)).onto);
    // Cleared, it goes by the project's again.
    try updateTicket(ctx, db, a, sub, .{ .onto = "" });
    try std.testing.expectEqualStrings("develop", (try getTicket(db, a, sub)).onto);
}

test "migrate: a board from before target branches gets the onto columns" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try db.execMulti("ALTER TABLE tickets DROP COLUMN onto; ALTER TABLE projects DROP COLUMN onto");
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'onto'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'onto'", .{})) != null);
}

test "migrate: a board from before automated reviews gets their columns" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try db.execMulti("ALTER TABLE tickets DROP COLUMN autoreview; ALTER TABLE projects DROP COLUMN review_skill");
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'autoreview'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'review_skill'", .{})) != null);
}

test "migrate: a board from before planning sessions gets the plan and planners columns" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try db.execMulti("ALTER TABLE tickets DROP COLUMN plan_md; ALTER TABLE projects DROP COLUMN planners");
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'plan_md'", .{})) != null);
    try std.testing.expectEqual(@as(?i64, default_planners), try db.int("SELECT dflt_value FROM pragma_table_info('projects') WHERE name = 'planners'", .{}));
}

test "migrate: a board another branch moved to a later version still gets the test columns" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try db.execMulti(std.fmt.comptimePrint("ALTER TABLE tickets DROP COLUMN test_plan; ALTER TABLE tickets DROP COLUMN test_progress; ALTER TABLE projects DROP COLUMN after_merge; PRAGMA user_version = {d}", .{version}));
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'test_progress'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'test_plan'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'after_merge'", .{})) != null);
    try std.testing.expectEqual(@as(?i64, version), try db.int("PRAGMA user_version", .{}));
}

fn now(ctx: Ctx) i64 {
    return ctx.nowSeconds();
}

// ---- projects ----

pub const ProjectInput = struct {
    name: []const u8,
    dir: []const u8,
    prefix: ?[]const u8 = null,
    slots: ?i64 = null,
    mode: ?Mode = null,
    profile: ?[]const u8 = null,
    after_merge: ?[]const u8 = null,
    after_merge_claude: ?[]const u8 = null,
    planners: ?i64 = null,
    onto: ?[]const u8 = null,
    review_skill: ?[]const u8 = null,
};

/// A key prefix from a project name: a short first word as is (`qa-tool` →
/// QA, `cl-wrapper` → CL), else the initials of its words
/// (`epoch-website-astro` → EWA), else its first two letters (`boats` → BO).
pub fn defaultPrefix(buf: *[8]u8, name: []const u8) []const u8 {
    var n: usize = 0;
    var words_buf: [8][]const u8 = undefined;
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, name, "-_ .");
    while (it.next()) |w| {
        if (words == words_buf.len) break;
        words_buf[words] = w;
        words += 1;
    }
    const ws = words_buf[0..words];
    if (ws.len >= 2 and ws[0].len >= 2 and ws[0].len <= 3) {
        for (ws[0]) |ch| if (std.ascii.isAlphanumeric(ch)) {
            buf[n] = std.ascii.toUpper(ch);
            n += 1;
        };
        return buf[0..n];
    }
    if (ws.len >= 2) {
        for (ws) |w| if (std.ascii.isAlphanumeric(w[0])) {
            buf[n] = std.ascii.toUpper(w[0]);
            n += 1;
        };
        return buf[0..n];
    }
    for (name) |ch| {
        if (n == 2) break;
        if (!std.ascii.isAlphanumeric(ch)) continue;
        buf[n] = std.ascii.toUpper(ch);
        n += 1;
    }
    return buf[0..n];
}

test defaultPrefix {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("QA", defaultPrefix(&buf, "qa-tool"));
    try std.testing.expectEqualStrings("SOV", defaultPrefix(&buf, "sov_escape"));
    try std.testing.expectEqualStrings("CL", defaultPrefix(&buf, "cl-wrapper"));
    try std.testing.expectEqualStrings("NV", defaultPrefix(&buf, "nvim"));
    try std.testing.expectEqualStrings("BO", defaultPrefix(&buf, "boats"));
    try std.testing.expectEqualStrings("EWA", defaultPrefix(&buf, "epoch-website-astro"));
}

fn validPrefix(p: []const u8) bool {
    if (p.len == 0 or p.len > 8) return false;
    for (p) |ch| if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch)) return false;
    return true;
}

pub fn addProject(db: Db, in: ProjectInput) Error!void {
    if (in.name.len == 0 or in.dir.len == 0) return error.BadInput;
    var buf: [8]u8 = undefined;
    const prefix = in.prefix orelse defaultPrefix(&buf, in.name);
    if (!validPrefix(prefix)) return error.BadInput;
    if (try db.int("SELECT 1 FROM projects WHERE name = ?1 OR prefix = ?2", .{ in.name, prefix }) != null) return error.Exists;
    try db.exec("INSERT INTO projects (name, dir, prefix, slots, mode, profile, after_merge, after_merge_claude, planners, onto) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)", .{
        in.name, in.dir, prefix, in.slots orelse default_slots, @tagName(in.mode orelse .queue), in.profile orelse "", in.after_merge orelse "", in.after_merge_claude orelse "", in.planners orelse default_planners, in.onto orelse "",
    });
}

/// Change the given fields of a project.
pub fn updateProject(db: Db, name: []const u8, in: ProjectInput) Error!void {
    if (try db.int("SELECT 1 FROM projects WHERE name = ?1", .{name}) == null) return error.NotFound;
    if (in.prefix) |p| {
        if (!validPrefix(p)) return error.BadInput;
        if (try db.int("SELECT 1 FROM projects WHERE prefix = ?1 AND name != ?2", .{ p, name }) != null) return error.Exists;
        try db.exec("UPDATE projects SET prefix = ?2 WHERE name = ?1", .{ name, p });
    }
    if (in.dir.len > 0) try db.exec("UPDATE projects SET dir = ?2 WHERE name = ?1", .{ name, in.dir });
    if (in.slots) |s| try db.exec("UPDATE projects SET slots = ?2 WHERE name = ?1", .{ name, s });
    if (in.planners) |n| try db.exec("UPDATE projects SET planners = ?2 WHERE name = ?1", .{ name, n });
    if (in.mode) |m| try db.exec("UPDATE projects SET mode = ?2 WHERE name = ?1", .{ name, @tagName(m) });
    if (in.profile) |p| try db.exec("UPDATE projects SET profile = ?2 WHERE name = ?1", .{ name, p });
    if (in.after_merge) |c| try db.exec("UPDATE projects SET after_merge = ?2 WHERE name = ?1", .{ name, c });
    if (in.after_merge_claude) |c| try db.exec("UPDATE projects SET after_merge_claude = ?2 WHERE name = ?1", .{ name, c });
    if (in.onto) |o| try db.exec("UPDATE projects SET onto = ?2 WHERE name = ?1", .{ name, o });
    if (in.review_skill) |k| try db.exec("UPDATE projects SET review_skill = ?2 WHERE name = ?1", .{ name, k });
    // Renaming last, so the lookups above still match.
    if (in.name.len > 0 and !std.mem.eql(u8, in.name, name)) {
        if (try db.int("SELECT 1 FROM projects WHERE name = ?1", .{in.name}) != null) return error.Exists;
        try db.exec("UPDATE projects SET name = ?2 WHERE name = ?1", .{ name, in.name });
    }
}

/// Hide a project from what the board shows, or show it again.
pub fn setProjectHidden(db: Db, name: []const u8, hidden: bool) Error!void {
    try db.exec("UPDATE projects SET hidden = ?2 WHERE name = ?1", .{ name, @as(i64, @intFromBool(hidden)) });
    if (db.changes() == 0) return error.NotFound;
}

/// Pause a project's dispatching, or resume it (see `Project.paused`).
pub fn setProjectPaused(db: Db, name: []const u8, paused: bool) Error!void {
    try db.exec("UPDATE projects SET paused = ?2 WHERE name = ?1", .{ name, @as(i64, @intFromBool(paused)) });
    if (db.changes() == 0) return error.NotFound;
}

/// Pause or resume every project.
pub fn setAllPaused(db: Db, paused: bool) Error!void {
    try db.exec("UPDATE projects SET paused = ?1", .{@as(i64, @intFromBool(paused))});
}

/// The project named `name` is paused (false when there is none).
pub fn projectPaused(db: Db, name: []const u8) Error!bool {
    return ((try db.int("SELECT paused FROM projects WHERE name = ?1", .{name})) orelse 0) != 0;
}

/// Remove a project; refused while it has tickets.
pub fn removeProject(db: Db, name: []const u8) Error!void {
    if (try db.int("SELECT 1 FROM projects WHERE name = ?1", .{name}) == null) return error.NotFound;
    if (try db.int("SELECT 1 FROM tickets WHERE project = ?1", .{name}) != null) return error.Exists;
    try db.exec("DELETE FROM projects WHERE name = ?1", .{name});
}

const project_cols = "name, dir, prefix, slots, mode, profile, after_merge, after_merge_claude, hidden, planners, paused, onto, review_skill";

fn readProject(st: sqlite.Stmt, a: std.mem.Allocator) !Project {
    return .{
        .name = try st.dupe(a, 0),
        .dir = try st.dupe(a, 1),
        .prefix = try st.dupe(a, 2),
        .slots = st.int(3),
        .mode = Mode.parse(st.text(4)) orelse .queue,
        .profile = try st.dupe(a, 5),
        .after_merge = try st.dupe(a, 6),
        .after_merge_claude = try st.dupe(a, 7),
        .hidden = st.int(8) != 0,
        .planners = st.int(9),
        .paused = st.int(10) != 0,
        .onto = try st.dupe(a, 11),
        .review_skill = try st.dupe(a, 12),
    };
}

pub fn listProjects(db: Db, a: std.mem.Allocator) Error![]Project {
    var st = try db.query("SELECT " ++ project_cols ++ " FROM projects ORDER BY name", .{});
    defer st.finalize();
    var out: std.ArrayList(Project) = .empty;
    while (try st.step()) try out.append(a, try readProject(st, a));
    return out.toOwnedSlice(a);
}

pub fn getProject(db: Db, a: std.mem.Allocator, name: []const u8) Error!Project {
    var st = try db.query("SELECT " ++ project_cols ++ " FROM projects WHERE name = ?1", .{name});
    defer st.finalize();
    if (!try st.step()) return error.NotFound;
    return readProject(st, a);
}

// ---- after-merge runs ----
// One runner per project at a time (after_merge_pid); tickets merged while
// it runs wait in after_merge_pending (keys, one per line) and get one more
// run after it, on the newest trunk.

/// Add a merged ticket to the project's next after-merge run.
pub fn queueAfterMerge(db: Db, project: []const u8, key: []const u8) Error!void {
    try db.exec("UPDATE projects SET after_merge_pending = after_merge_pending || ?2 || char(10) WHERE name = ?1", .{ project, key });
    if (db.changes() == 0) return error.NotFound;
}

/// Become the project's runner unless `alive` says another one (a pid) is
/// still running. False when one is.
pub fn claimAfterMerge(db: Db, project: []const u8, pid: i64, alive: *const fn (i64) bool) Error!bool {
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    const cur = (try db.int("SELECT after_merge_pid FROM projects WHERE name = ?1", .{project})) orelse return error.NotFound;
    if (cur != 0 and cur != pid and alive(cur)) {
        try db.execMulti("COMMIT");
        return false;
    }
    try db.exec("UPDATE projects SET after_merge_pid = ?2 WHERE name = ?1", .{ project, pid });
    try db.execMulti("COMMIT");
    return true;
}

/// The runner takes what is waiting (ticket keys, one per line). With
/// nothing waiting it lets go of the project in the same step, so a ticket
/// queued just after starts a runner of its own; null then.
pub fn takeAfterMerge(db: Db, a: std.mem.Allocator, project: []const u8) Error!?[]const u8 {
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    var st = try db.query("SELECT after_merge_pending FROM projects WHERE name = ?1", .{project});
    const pending = blk: {
        defer st.finalize();
        if (!try st.step()) return error.NotFound;
        break :blk try st.dupe(a, 0);
    };
    if (std.mem.trim(u8, pending, " \n").len == 0) {
        try db.exec("UPDATE projects SET after_merge_pid = 0, after_merge_pending = '' WHERE name = ?1", .{project});
        try db.execMulti("COMMIT");
        return null;
    }
    try db.exec("UPDATE projects SET after_merge_pending = '' WHERE name = ?1", .{project});
    try db.execMulti("COMMIT");
    return pending;
}

fn testAlive(pid: i64) bool {
    return pid == 77;
}

test "after-merge runs: one runner, merges during it run once more after" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try addProject(db, .{ .name = "p", .dir = "/tmp", .after_merge = "make" });
    try std.testing.expectEqualStrings("make", (try getProject(db, a, "p")).after_merge);
    try queueAfterMerge(db, "p", "P-1");
    try std.testing.expect(try claimAfterMerge(db, "p", 77, testAlive));
    try std.testing.expectEqualStrings("P-1\n", (try takeAfterMerge(db, a, "p")).?);
    // Two merges land while it runs; another runner can't take over.
    try queueAfterMerge(db, "p", "P-2");
    try queueAfterMerge(db, "p", "P-3");
    try std.testing.expect(!try claimAfterMerge(db, "p", 78, testAlive));
    try std.testing.expectEqualStrings("P-2\nP-3\n", (try takeAfterMerge(db, a, "p")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try takeAfterMerge(db, a, "p"));
    // Let go: the next runner claims it.
    try std.testing.expect(try claimAfterMerge(db, "p", 78, testAlive));
    // A runner that died (not alive) doesn't hold it either.
    try db.exec("UPDATE projects SET after_merge_pid = 99", .{});
    try std.testing.expect(try claimAfterMerge(db, "p", 78, testAlive));
}

// ---- tickets ----

pub const TicketInput = struct {
    project: []const u8 = "",
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    stage: ?Stage = null,
    mode: ?Mode = null,
    plan: ?bool = null,
    target: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    /// Key of the parent ticket, for a sub-ticket.
    parent: ?[]const u8 = null,
    /// Planning skill.
    skill: ?[]const u8 = null,
    /// An umbrella (see `Ticket.umbrella`).
    umbrella: ?bool = null,
    /// Target branch (`Ticket.onto_own`); "" for the project's. A new
    /// sub-ticket without one takes its parent's.
    onto: ?[]const u8 = null,
    /// createTicket: the body to store once the key is known, or null to
    /// keep it (images pasted before the ticket had a key move to its own
    /// folder). Called before the ticket is visible, so nothing starts it
    /// with the old body.
    body_for_key: ?BodyForKey = null,
};

pub const BodyForKey = struct {
    ctx: *const anyopaque,
    call: *const fn (ctx: *const anyopaque, a: std.mem.Allocator, key: []const u8, body: []const u8) anyerror!?[]const u8,
};

/// Create a ticket and return its key (e.g. QA-12). Mode and profile default
/// to the project's; a planning ticket starts in Planning unless a stage is given.
pub fn createTicket(ctx: Ctx, db: Db, a: std.mem.Allocator, in: TicketInput) Error![]const u8 {
    const title = in.title orelse return error.BadInput;
    if (title.len == 0) return error.BadInput;
    // A sub-ticket lives in its parent's project unless told otherwise.
    const parent: ?Ticket = if (in.parent) |k| try getTicket(db, a, k) else null;
    const project = if (in.project.len > 0) in.project else if (parent) |pt| pt.project else return error.BadInput;
    const p = try getProject(db, a, project);
    const plan = in.plan orelse false;
    const stage = in.stage orelse (if (plan) Stage.planning else Stage.backlog);
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    const num = (try db.int("SELECT next_num FROM projects WHERE name = ?1", .{p.name})) orelse return error.NotFound;
    try db.exec("UPDATE projects SET next_num = next_num + 1 WHERE name = ?1", .{p.name});
    const key = try std.fmt.allocPrint(a, "{s}-{d}", .{ p.prefix, num });
    var body = in.body orelse "";
    if (in.body_for_key) |f| if (f.call(f.ctx, a, key, body) catch null) |b| {
        body = b;
    };
    const t = now(ctx);
    try db.exec(
        \\INSERT INTO tickets (key, project, title, body, stage, mode, plan, target, profile, parent, skill, created, updated, rank, umbrella, onto)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12, (SELECT coalesce(max(rank), 0) + ?13 FROM tickets), ?14, ?15)
    , .{ key, p.name, title, body, @tagName(stage), @tagName(in.mode orelse p.mode), plan, in.target orelse "", in.profile orelse p.profile, if (parent) |pt| pt.id else null, in.skill orelse "", t, rank_gap, in.umbrella orelse false, in.onto orelse if (parent) |pt| pt.onto_own else "" });
    const id = db.lastId();
    try logEvent(ctx, db, id, "created", @tagName(stage));
    if (parent) |pt| {
        try logEvent(ctx, db, pt.id, "sub-ticket", key);
        // Something new to do under it: it isn't ready to close any more.
        if (stage != .done) try clearFlagId(ctx, db, pt.id, flag_ready_to_close);
    }
    try db.execMulti("COMMIT");
    return key;
}

const ticket_cols = "t.id, t.key, t.project, t.title, t.body, t.stage, t.mode, t.plan, t.target, t.worktree, t.branch, t.profile, t.tmux, t.session_id, t.summary, t.round, t.created, t.updated, " ++
    "coalesce((SELECT p.key FROM tickets p WHERE p.id = t.parent), ''), (SELECT count(*) FROM tickets c WHERE c.parent = t.id), t.skill, t.base, t.finishing, t.change_id, t.rank, t.killed, t.test_plan, t.test_progress, t.custom_close, t.plan_md, t.review_guide, t.asking, t.parallel, " ++
    "EXISTS (SELECT 1 FROM events e WHERE e.ticket = t.id AND e.kind = 'started'), " ++
    "(SELECT count(*) FROM tickets c WHERE c.parent = t.id AND c.stage = 'done'), t.umbrella, " ++
    "t.onto, coalesce((SELECT p.onto FROM projects p WHERE p.name = t.project), ''), t.autoreview";

fn readTicket(st: sqlite.Stmt, a: std.mem.Allocator) !Ticket {
    return .{
        .id = st.int(0),
        .key = try st.dupe(a, 1),
        .project = try st.dupe(a, 2),
        .title = try st.dupe(a, 3),
        .body = try st.dupe(a, 4),
        .stage = Stage.parse(st.text(5)) orelse .backlog,
        .mode = Mode.parse(st.text(6)) orelse .queue,
        .plan = st.int(7) != 0,
        .target = try st.dupe(a, 8),
        .worktree = try st.dupe(a, 9),
        .branch = try st.dupe(a, 10),
        .profile = try st.dupe(a, 11),
        .tmux = try st.dupe(a, 12),
        .session_id = try st.dupe(a, 13),
        .summary = try st.dupe(a, 14),
        .round = st.int(15),
        .created = st.int(16),
        .updated = st.int(17),
        .parent = try st.dupe(a, 18),
        .children = st.int(19),
        .skill = try st.dupe(a, 20),
        .base = try st.dupe(a, 21),
        .finishing = try st.dupe(a, 22),
        .change = try st.dupe(a, 23),
        .rank = st.int(24),
        .killed = st.int(25) != 0,
        .test_plan = try st.dupe(a, 26),
        .test_progress = try st.dupe(a, 27),
        .custom_close = try st.dupe(a, 28),
        .plan_md = try st.dupe(a, 29),
        .review_guide = try st.dupe(a, 30),
        .asking = try st.dupe(a, 31),
        .parallel = st.int(32) != 0,
        .started = st.int(33) != 0,
        .children_done = st.int(34),
        .umbrella = st.int(35) != 0,
        .onto_own = try st.dupe(a, 36),
        .onto = if (st.text(36).len > 0) try st.dupe(a, 36) else try st.dupe(a, 37),
        .autoreview = try st.dupe(a, 38),
    };
}

fn activeFlags(db: Db, a: std.mem.Allocator, id: i64) Error![]Flag {
    var st = try db.query("SELECT kind, source, detail, at, hidden FROM flags WHERE ticket = ?1 AND cleared IS NULL ORDER BY at, id", .{id});
    defer st.finalize();
    var out: std.ArrayList(Flag) = .empty;
    while (try st.step()) try out.append(a, .{ .kind = try st.dupe(a, 0), .source = try st.dupe(a, 1), .detail = try st.dupe(a, 2), .at = st.int(3), .hidden = st.int(4) != 0 });
    return out.toOwnedSlice(a);
}

/// A ticket by key (case-insensitive), with its active flags.
pub fn getTicket(db: Db, a: std.mem.Allocator, key: []const u8) Error!Ticket {
    var st = try db.query("SELECT " ++ ticket_cols ++ " FROM tickets t WHERE t.key = ?1 COLLATE NOCASE", .{key});
    defer st.finalize();
    if (!try st.step()) return error.NotFound;
    var t = try readTicket(st, a);
    t.flags = try activeFlags(db, a, t.id);
    t.park = try parkOf(db, a, t.id);
    t.blocked_by = try blockers(db, a, t.id);
    return t;
}

pub fn comments(db: Db, a: std.mem.Allocator, id: i64) Error![]Comment {
    var st = try db.query("SELECT author, body, sent, at FROM comments WHERE ticket = ?1 ORDER BY at, id", .{id});
    defer st.finalize();
    var out: std.ArrayList(Comment) = .empty;
    while (try st.step()) try out.append(a, .{ .author = try st.dupe(a, 0), .body = try st.dupe(a, 1), .sent = st.int(2) != 0, .at = st.int(3) });
    return out.toOwnedSlice(a);
}

pub fn events(db: Db, a: std.mem.Allocator, id: i64) Error![]Event {
    var st = try db.query("SELECT kind, detail, at FROM events WHERE ticket = ?1 ORDER BY at, id", .{id});
    defer st.finalize();
    var out: std.ArrayList(Event) = .empty;
    while (try st.step()) try out.append(a, .{ .kind = try st.dupe(a, 0), .detail = try st.dupe(a, 1), .at = st.int(2) });
    return out.toOwnedSlice(a);
}

pub const Filter = struct {
    stage: ?Stage = null,
    project: ?[]const u8 = null,
    /// Only tickets with this active flag.
    flag: ?[]const u8 = null,
    /// Only tickets with any active flag (the inbox), oldest ask first.
    needs: bool = false,
    /// With `needs`: the tickets hidden from the inbox (every active flag
    /// hidden) instead of the ones in it.
    hidden: bool = false,
    /// With `needs`: the tmux sessions that are busy. A ticket one of them is
    /// working on is left out; it comes back once its session stops.
    busy: []const []const u8 = &.{},
    /// Full-text search over keys, titles, bodies and comments.
    search: ?[]const u8 = null,
    /// Include Done tickets (always included when filtering by stage).
    done: bool = true,
    /// Leave out sub-tickets.
    top: bool = false,
    /// Only the sub-tickets of this ticket (by key).
    parent: ?[]const u8 = null,
    /// Only parked tickets.
    parked: bool = false,
    /// Leave out the tickets of hidden projects.
    shown: bool = false,
};

/// Words of `q` as FTS5 prefix terms ("foo" bar → "foo"* "bar"*), so user
/// input never trips FTS5's query syntax.
fn ftsQuery(a: std.mem.Allocator, q: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, q, " \t\n\"");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.append(a, '"');
        try out.appendSlice(a, w);
        try out.appendSlice(a, "\"*");
    }
    return out.toOwnedSlice(a);
}

test ftsQuery {
    const a = std.testing.allocator;
    const q = try ftsQuery(a, "flaky  login-spec");
    defer a.free(q);
    try std.testing.expectEqualStrings("\"flaky\"* \"login-spec\"*", q);
}

pub fn listTickets(db: Db, a: std.mem.Allocator, f: Filter) Error![]Ticket {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(a);
    try sql.appendSlice(a, "SELECT " ++ ticket_cols ++ " FROM tickets t WHERE 1");
    if (f.stage != null) try sql.appendSlice(a, " AND t.stage = ?1");
    if (f.stage == null and !f.done) try sql.appendSlice(a, " AND t.stage != 'done'");
    if (f.project != null) try sql.appendSlice(a, " AND t.project = ?2");
    if (f.top) try sql.appendSlice(a, " AND t.parent IS NULL");
    if (f.parent != null) try sql.appendSlice(a, " AND t.parent = (SELECT id FROM tickets WHERE key = ?5 COLLATE NOCASE)");
    if (f.flag != null) try sql.appendSlice(a, " AND EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL AND g.kind = ?3)");
    if (f.parked) try sql.appendSlice(a, " AND EXISTS (SELECT 1 FROM parks k WHERE k.ticket = t.id)");
    if (f.shown) try sql.appendSlice(a, " AND NOT EXISTS (SELECT 1 FROM projects p WHERE p.name = t.project AND p.hidden != 0)");
    // Parked: it waits on something outside cl, not on you.
    if (f.needs) try sql.appendSlice(a, " AND NOT EXISTS (SELECT 1 FROM parks k WHERE k.ticket = t.id)");
    if (f.needs) try sql.appendSlice(a, if (f.hidden)
        " AND EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL) AND NOT EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL AND g.hidden = 0)"
    else
        " AND EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL AND g.hidden = 0)");
    const fts = if (f.search) |q| try ftsQuery(a, q) else "";
    if (fts.len > 0) try sql.appendSlice(a,
        \\ AND (t.id IN (SELECT rowid FROM tickets_fts WHERE tickets_fts MATCH ?4)
        \\  OR t.id IN (SELECT c.ticket FROM comments c JOIN comments_fts s ON s.rowid = c.id WHERE comments_fts MATCH ?4))
    );
    if (f.needs) {
        try sql.appendSlice(a, " ORDER BY (SELECT min(at) FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL), t.id");
    } else if (f.parent != null) {
        // The order they run in.
        try sql.appendSlice(a, " ORDER BY t.rank, t.id");
    } else {
        try sql.appendSlice(a, " ORDER BY t.updated DESC, t.id DESC");
    }
    var st = try db.prepare(sql.items);
    defer st.finalize();
    if (f.stage) |s| try st.bind(1, @as([]const u8, @tagName(s)));
    if (f.project) |p| try st.bind(2, p);
    if (f.flag) |g| try st.bind(3, g);
    if (fts.len > 0) try st.bind(4, fts);
    if (f.parent) |k| try st.bind(5, k);
    var out: std.ArrayList(Ticket) = .empty;
    while (try st.step()) {
        const t = try readTicket(st, a);
        if (f.needs and try isWorking(db, t, f.busy)) continue;
        try out.append(a, t);
    }
    for (out.items) |*t| {
        t.flags = try activeFlags(db, a, t.id);
        t.park = try parkOf(db, a, t.id);
        t.blocked_by = try blockers(db, a, t.id);
    }
    return out.toOwnedSlice(a);
}

/// The ticket a session is on: the newest one there in progress (Running,
/// Planning) or finishing, else the newest one there not done.
pub fn sessionTicket(db: Db, tmux_name: []const u8) Error!?i64 {
    return db.int(
        \\SELECT id FROM tickets WHERE tmux = ?1 AND stage != 'done'
        \\ORDER BY (stage IN ('running', 'planning') OR finishing != '') DESC, id DESC LIMIT 1
    , .{tmux_name});
}

/// Is Claude working on `t` right now: its session is one of the `busy` ones
/// and is on it, or an automated review of it is running (`reviewing`)? Then
/// it isn't waiting on the human, whatever its flags say.
pub fn isWorking(db: Db, t: Ticket, busy: []const []const u8) Error!bool {
    if (reviewing(t)) return true;
    if (t.tmux.len == 0) return false;
    for (busy) |b| if (std.mem.eql(u8, b, t.tmux)) return (try sessionTicket(db, t.tmux)) == t.id;
    return false;
}

/// Change the given fields of a ticket.
pub fn updateTicket(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, in: TicketInput) Error!void {
    const t = try getTicket(db, a, key);
    if (in.title) |v| {
        if (v.len == 0) return error.BadInput;
        try db.exec("UPDATE tickets SET title = ?2 WHERE id = ?1", .{ t.id, v });
    }
    if (in.body) |v| try db.exec("UPDATE tickets SET body = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.mode) |v| try db.exec("UPDATE tickets SET mode = ?2 WHERE id = ?1", .{ t.id, @as([]const u8, @tagName(v)) });
    if (in.plan) |v| try db.exec("UPDATE tickets SET plan = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.target) |v| try db.exec("UPDATE tickets SET target = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.profile) |v| try db.exec("UPDATE tickets SET profile = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.skill) |v| try db.exec("UPDATE tickets SET skill = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.umbrella) |v| try db.exec("UPDATE tickets SET umbrella = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.onto) |v| try db.exec("UPDATE tickets SET onto = ?2 WHERE id = ?1", .{ t.id, v });
    if (in.project.len > 0 and !std.mem.eql(u8, in.project, t.project)) {
        _ = try getProject(db, a, in.project);
        try db.exec("UPDATE tickets SET project = ?2 WHERE id = ?1", .{ t.id, in.project });
    }
    try touch(ctx, db, t.id);
    try logEvent(ctx, db, t.id, "edited", "");
    // Made an umbrella when its sub-tickets are done already.
    if (in.umbrella == true) try subticketsSettled(ctx, db, t.id);
}

/// Record what a session did for a ticket (set when the dispatcher starts it).
pub fn setSession(ctx: Ctx, db: Db, id: i64, tmux_name: []const u8, session_id: []const u8, worktree: []const u8, branch: []const u8) Error!void {
    // A session again: it isn't killed (or parked) any more.
    try db.exec("UPDATE tickets SET tmux = ?2, session_id = ?3, worktree = ?4, branch = ?5, killed = killed AND ?2 = '' WHERE id = ?1", .{ id, tmux_name, session_id, worktree, branch });
    if (tmux_name.len > 0 and tmux_name[0] != '(') {
        try db.exec("DELETE FROM parks WHERE ticket = ?1", .{id});
        if (db.changes() > 0) try logEvent(ctx, db, id, "unparked", "started");
    }
    try touch(ctx, db, id);
}

/// Keep the test plan Claude wrote for the ticket; testing it starts over.
pub fn setTestPlan(ctx: Ctx, db: Db, id: i64, md: []const u8) Error!void {
    try db.exec("UPDATE tickets SET test_plan = ?2, test_progress = '' WHERE id = ?1", .{ id, md });
    try touch(ctx, db, id);
}

/// Keep the AskUserQuestion the ticket's session is asking ("" when none).
pub fn setAsking(db: Db, id: i64, json: []const u8) Error!void {
    try db.exec("UPDATE tickets SET asking = ?2 WHERE id = ?1", .{ id, json });
}

/// Keep the review guide Claude wrote for the ticket.
pub fn setReviewGuide(ctx: Ctx, db: Db, id: i64, md: []const u8) Error!void {
    try db.exec("UPDATE tickets SET review_guide = ?2 WHERE id = ?1", .{ id, md });
    try touch(ctx, db, id);
}

/// An automated review of `t` is running (autoreview.zig): it stays out of
/// Needs You until the review is done (`raiseAfterReview`).
pub fn reviewing(t: Ticket) bool {
    return std.mem.indexOf(u8, t.autoreview, reviewing_json) != null;
}

/// How a running review reads in `Ticket.autoreview` (std.json's compact output).
pub const reviewing_json = "\"status\":\"running\"";

/// An automated review of the ticket finished: it is back in Needs You with
/// its stage's flag (Ready for review, or Needs testing), raised again or
/// brought back if it was dismissed or hidden while it ran.
pub fn raiseAfterReview(ctx: Ctx, db: Db, id: i64, stage: Stage) Error!void {
    const kind = switch (stage) {
        .review => flag_review,
        .testing => flag_testing,
        else => return,
    };
    try db.exec("UPDATE flags SET hidden = 0 WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ id, kind });
    if (db.changes() == 0 and (try db.int("SELECT 1 FROM flags WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ id, kind })) == null)
        try setFlagId(ctx, db, id, kind, "auto", "");
    try touch(ctx, db, id);
}

test "a ticket under automated review is out of Needs You until it is done, then back with its flag" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .review });
    const id = (try getTicket(db, a, k)).id;
    try setFlagId(ctx, db, id, flag_review, "auto", "");
    try std.testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
    try setAutoreview(db, id, "{\"status\":\"running\",\"started\":1}");
    try std.testing.expect(try isWorking(db, try getTicket(db, a, k), &.{}));
    try std.testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);
    // Cleared meanwhile; the review finishing raises it again.
    try clearFlagId(ctx, db, id, flag_review);
    try setAutoreview(db, id, "{\"status\":\"done\",\"started\":1}");
    try raiseAfterReview(ctx, db, id, .review);
    const back = try listTickets(db, a, .{ .needs = true });
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings(flag_review, back[0].flags[0].kind);
    // Hidden, likewise.
    _ = try hideNeeds(ctx, db, a, k, true);
    try raiseAfterReview(ctx, db, id, .review);
    try std.testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
}

/// Keep the ticket's automated review (autoreview.zig's JSON). Left out of
/// `updated`: the board's cards don't change with it.
pub fn setAutoreview(db: Db, id: i64, json: []const u8) Error!void {
    try db.exec("UPDATE tickets SET autoreview = ?2 WHERE id = ?1", .{ id, json });
}

/// `setAutoreview`, only if the stored review is still `old` (nothing
/// changed it since the caller read it). False when it was changed.
pub fn setAutoreviewIf(db: Db, id: i64, json: []const u8, old: []const u8) Error!bool {
    try db.exec("UPDATE tickets SET autoreview = ?2 WHERE id = ?1 AND autoreview = ?3", .{ id, json, old });
    return db.changes() > 0;
}

/// `setAutoreview`, only while the stored review is still running (it may
/// have finished since the caller read it). False when it wasn't.
pub fn setAutoreviewIfRunning(db: Db, id: i64, json: []const u8) Error!bool {
    try db.exec("UPDATE tickets SET autoreview = ?2 WHERE id = ?1 AND instr(autoreview, ?3) > 0", .{ id, json, reviewing_json });
    return db.changes() > 0;
}

/// When a session last took the ticket up (its last "started" event, in
/// seconds), or 0 when none did.
pub fn startedAt(db: Db, id: i64) Error!i64 {
    return (try db.int("SELECT coalesce(max(at), 0) FROM events WHERE ticket = ?1 AND kind = 'started'", .{id})) orelse 0;
}

/// Keep the plan a planning session gave, for the session that builds it.
pub fn setPlan(ctx: Ctx, db: Db, id: i64, md: []const u8) Error!void {
    try db.exec("UPDATE tickets SET plan_md = ?2 WHERE id = ?1", .{ id, md });
    try touch(ctx, db, id);
}

/// Your edit of the ticket's plan (the board's Edit on its Plan tab): what
/// the session that builds it is told. Only while that will be a fresh
/// session (`planEditable`): one that resumes a conversation is never told
/// the plan. `base` is the plan the edit started from: error.EditConflict
/// when it has changed since (Claude handed in a revised one), so yours
/// doesn't replace it unseen. One statement checks and writes, so a `done
/// --plan` or a start from another process can't land in between.
pub fn editPlan(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, md: []const u8, base: []const u8) (Error || error{ PlanStarted, EditConflict })!void {
    const t = try getTicket(db, a, key);
    if (!planEditable(t)) return error.PlanStarted;
    const ws = " \t\r\n";
    if (!std.mem.eql(u8, std.mem.trim(u8, base, ws), std.mem.trim(u8, t.plan_md, ws))) return error.EditConflict;
    const trimmed = std.mem.trim(u8, md, ws);
    if (std.mem.eql(u8, trimmed, std.mem.trim(u8, t.plan_md, ws))) return;
    const new = if (trimmed.len > 0) try std.fmt.allocPrint(a, "{s}\n", .{trimmed}) else "";
    try db.exec("UPDATE tickets SET plan_md = ?2 WHERE id = ?1 AND plan_md = ?3 AND " ++ plan_editable_sql, .{ t.id, new, t.plan_md });
    if (db.changes() == 0) {
        const now_t = try getTicket(db, a, key);
        return if (planEditable(now_t)) error.EditConflict else error.PlanStarted;
    }
    try touch(ctx, db, t.id);
    try logEvent(ctx, db, t.id, "plan edited", "");
}

/// Whether an edit of `t`'s plan reaches the session that builds it: in
/// Planning (approving starts a fresh session), or in Backlog or Queued with
/// no conversation to resume (a resumed one is only told it's back on).
pub fn planEditable(t: Ticket) bool {
    return t.stage == .planning or ((t.stage == .backlog or t.stage == .queued) and t.session_id.len == 0);
}

/// `planEditable` as SQL on the tickets table.
const plan_editable_sql = "(stage = 'planning' OR (stage IN ('backlog', 'queued') AND session_id = ''))";

test editPlan {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .planning });
    const id = (try getTicket(db, a, k)).id;
    try setPlan(ctx, db, id, "## Steps\n1. do it\n");
    try editPlan(ctx, db, a, k, "## Steps\n1. do it\n2. test it\n\n", "## Steps\n1. do it");
    try std.testing.expectEqualStrings("## Steps\n1. do it\n2. test it\n", (try getTicket(db, a, k)).plan_md);
    // Claude handed in a revised plan while you edited the old one: yours doesn't replace it.
    try setPlan(ctx, db, id, "## Revised\n");
    try std.testing.expectError(error.EditConflict, editPlan(ctx, db, a, k, "mine", "## Steps\n1. do it\n2. test it\n"));
    try std.testing.expectEqualStrings("## Revised\n", (try getTicket(db, a, k)).plan_md);
    // Once its build session started, that session would never see it...
    try move(ctx, db, a, k, .running);
    try std.testing.expectError(error.PlanStarted, editPlan(ctx, db, a, k, "x", "## Revised\n"));
    // ...nor when it's back in Queued with a conversation to resume.
    try move(ctx, db, a, k, .queued);
    try db.exec("UPDATE tickets SET session_id = 'abc' WHERE id = ?1", .{id});
    try std.testing.expectError(error.PlanStarted, editPlan(ctx, db, a, k, "x", "## Revised\n"));
    try db.exec("UPDATE tickets SET session_id = '' WHERE id = ?1", .{id});
    try editPlan(ctx, db, a, k, "## Mine\n", "## Revised\n");
    try std.testing.expectEqualStrings("## Mine\n", (try getTicket(db, a, k)).plan_md);
}

/// Save how far testing got (left out of `updated`: it changes as you type).
/// Claude's custom close (see Ticket.custom_close); "" clears it.
pub fn setCustomClose(ctx: Ctx, db: Db, id: i64, text: []const u8) Error!void {
    try db.exec("UPDATE tickets SET custom_close = ?2 WHERE id = ?1", .{ id, text });
    try logEvent(ctx, db, id, if (text.len > 0) "custom close" else "custom close cleared", text);
    try touch(ctx, db, id);
}

pub fn setTestProgress(db: Db, id: i64, json: []const u8) Error!void {
    try db.exec("UPDATE tickets SET test_progress = ?2 WHERE id = ?1", .{ id, json });
}

/// Sub-tickets of `key` that aren't Done yet; a ticket can't be Done while it has any.
pub fn openSubtickets(db: Db, a: std.mem.Allocator, key: []const u8) Error![]Ticket {
    return listTickets(db, a, .{ .parent = key, .done = false });
}

/// Make `key`'s unfinished sub-tickets tickets of their own, so it can be Done.
pub fn spinOff(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8) Error!void {
    const t = try getTicket(db, a, key);
    for (try openSubtickets(db, a, key)) |c| {
        try db.exec("UPDATE tickets SET parent = NULL WHERE id = ?1", .{c.id});
        try logEvent(ctx, db, c.id, "spun off", t.key);
        try logEvent(ctx, db, t.id, "spun off", c.key);
        try touch(ctx, db, c.id);
    }
}

/// Remove a ticket; refused while it has sub-tickets. The tickets linked to
/// wait on it go on without it: their keys come back, so the caller can say so.
/// A sub-ticket's parent may be left with only Done ones: see `subticketsSettled`.
pub fn removeTicket(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8) Error![]const []const u8 {
    const t = try getTicket(db, a, key);
    if (t.children > 0) return error.Exists;
    var freed: std.ArrayList([]const u8) = .empty;
    {
        var st = try db.query("SELECT w.id, w.key FROM deps d JOIN tickets w ON w.id = d.ticket WHERE d.blocker = ?1 ORDER BY w.id", .{t.id});
        defer st.finalize();
        var ids: std.ArrayList(i64) = .empty;
        while (try st.step()) {
            try ids.append(a, st.int(0));
            try freed.append(a, try st.dupe(a, 1));
        }
        var buf: [64]u8 = undefined;
        for (ids.items) |id| {
            try logEvent(ctx, db, id, "no longer waits on", std.fmt.bufPrint(&buf, "{s} (removed)", .{t.key}) catch t.key);
            try touch(ctx, db, id);
        }
    }
    try db.exec("DELETE FROM deps WHERE ticket = ?1 OR blocker = ?1", .{t.id});
    const pid = try parentId(db, t.id);
    try db.exec("DELETE FROM tickets WHERE id = ?1", .{t.id});
    if (pid) |p| if (t.stage != .done) {
        try logEvent(ctx, db, p, "sub-ticket deleted", t.key);
        try subticketsSettled(ctx, db, p);
    };
    return freed.toOwnedSlice(a);
}

// ---- dependencies ----

fn readDep(st: sqlite.Stmt, a: std.mem.Allocator, order: bool) !Dep {
    return .{ .id = st.int(0), .key = try st.dupe(a, 1), .title = try st.dupe(a, 2), .stage = Stage.parse(st.text(3)) orelse .backlog, .order = order };
}

/// What ticket `id` waits on (see Ticket.blocked_by): its links, its parent
/// when that has work of its own (isn't an umbrella), then the sub-tickets
/// before it.
pub fn blockers(db: Db, a: std.mem.Allocator, id: i64) Error![]Dep {
    var out: std.ArrayList(Dep) = .empty;
    {
        var st = try db.query("SELECT b.id, b.key, b.title, b.stage FROM deps d JOIN tickets b ON b.id = d.blocker WHERE d.ticket = ?1 ORDER BY b.rank, b.id", .{id});
        defer st.finalize();
        while (try st.step()) try out.append(a, try readDep(st, a, false));
    }
    {
        // The parent runs first: split-off work builds on it.
        var st = try db.query("SELECT p.id, p.key, p.title, p.stage FROM tickets t JOIN tickets p ON p.id = t.parent WHERE t.id = ?1 AND p.umbrella = 0", .{id});
        defer st.finalize();
        if (try st.step()) {
            var d = try readDep(st, a, false);
            d.parent = true;
            for (out.items) |x| {
                if (x.id == d.id) break;
            } else try out.append(a, d);
        }
    }
    const linked = out.items.len;
    var st = try db.query(
        \\SELECT s.id, s.key, s.title, s.stage, s.parallel FROM tickets t JOIN tickets s ON s.parent = t.parent
        \\WHERE t.id = ?1 AND t.parallel = 0 AND s.id != t.id AND (s.rank < t.rank OR (s.rank = t.rank AND s.id < t.id))
        \\ORDER BY s.rank DESC, s.id DESC
    , .{id});
    defer st.finalize();
    while (try st.step()) {
        const d = try readDep(st, a, true);
        // Linked as well: once is enough.
        for (out.items[0..linked]) |x| {
            if (x.id == d.id) break;
        } else try out.append(a, d);
        // Back to the first one that runs in order: that one waits for the rest.
        if (st.int(4) == 0) break;
    }
    // Listed in their order.
    std.mem.reverse(Dep, out.items[linked..]);
    return out.toOwnedSlice(a);
}

/// Why the dispatcher leaves a queued ticket alone (null: nothing does).
pub const Hold = enum {
    /// A ticket it waits on isn't Done yet.
    blocked,
    /// An umbrella: it has no work of its own, its sub-tickets run.
    subtickets,
};

pub fn hold(t: Ticket) ?Hold {
    if (t.umbrella) return .subtickets;
    for (t.blocked_by) |d| if (d.stage != .done) return .blocked;
    return null;
}

/// The tickets `t` waits on that aren't Done yet.
pub fn waitingOn(a: std.mem.Allocator, t: Ticket) ![]const Dep {
    var out: std.ArrayList(Dep) = .empty;
    for (t.blocked_by) |d| if (d.stage != .done) try out.append(a, d);
    return out.items;
}

/// Ticket `from` waits on `target`, directly or through others.
fn reaches(db: Db, a: std.mem.Allocator, from: i64, target: i64) Error!bool {
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    var stack: std.ArrayList(i64) = .empty;
    try stack.append(a, from);
    while (stack.pop()) |id| {
        if (id == target) return true;
        if ((try seen.getOrPut(a, id)).found_existing) continue;
        for (try blockers(db, a, id)) |d| try stack.append(a, d.id);
    }
    return false;
}

/// Some sub-ticket of `id`'s parent (or `id` itself) waits on itself: the
/// order of sub-tickets and the links between them disagree.
fn orderCycle(db: Db, a: std.mem.Allocator, id: i64) Error!bool {
    var st = try db.query("SELECT s.id FROM tickets t JOIN tickets s ON s.parent = t.parent WHERE t.id = ?1", .{id});
    defer st.finalize();
    var ids: std.ArrayList(i64) = .empty;
    while (try st.step()) try ids.append(a, st.int(0));
    for (ids.items) |s| for (try blockers(db, a, s)) |d| {
        if (try reaches(db, a, d.id, s)) return true;
    };
    return false;
}

/// Link `key` to wait on `blocker_key` (any project): the dispatcher doesn't
/// start it until that one is Done. error.Cycle when the blocker already
/// waits on it (or it's the same ticket); false when they were linked already.
pub fn addBlocker(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, blocker_key: []const u8) Error!bool {
    const t = try getTicket(db, a, key);
    const b = try getTicket(db, a, blocker_key);
    if (t.id == b.id or try reaches(db, a, b.id, t.id)) return error.Cycle;
    try db.exec("INSERT OR IGNORE INTO deps (ticket, blocker) VALUES (?1, ?2)", .{ t.id, b.id });
    if (db.changes() == 0) return false;
    try logEvent(ctx, db, t.id, "waits on", b.key);
    try touch(ctx, db, t.id);
    return true;
}

/// Drop the link from `key` to `blocker_key`; false when there was none.
/// The order of sub-tickets isn't a link: rank or --parallel changes that.
pub fn removeBlocker(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, blocker_key: []const u8) Error!bool {
    const t = try getTicket(db, a, key);
    const b = try getTicket(db, a, blocker_key);
    try db.exec("DELETE FROM deps WHERE ticket = ?1 AND blocker = ?2", .{ t.id, b.id });
    if (db.changes() == 0) return false;
    try logEvent(ctx, db, t.id, "no longer waits on", b.key);
    try touch(ctx, db, t.id);
    return true;
}

/// A sub-ticket runs in order (waits for the one before it), or in parallel.
/// error.Cycle when back in order it would wait on itself.
pub fn setParallel(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, on: bool) Error!void {
    const t = try getTicket(db, a, key);
    if (t.parallel == on) return;
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    try db.exec("UPDATE tickets SET parallel = ?2 WHERE id = ?1", .{ t.id, on });
    if (!on and try orderCycle(db, a, t.id)) return error.Cycle;
    try logEvent(ctx, db, t.id, if (on) "parallel" else "in order", "");
    try touch(ctx, db, t.id);
    try db.execMulti("COMMIT");
}

/// The tickets that wait on `id`: linked to it, the sub-tickets after it,
/// or its own sub-tickets (when it isn't an umbrella).
pub fn dependents(db: Db, a: std.mem.Allocator, id: i64) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var st = try db.query(
        \\SELECT w.id, w.key FROM tickets w WHERE w.id IN (SELECT ticket FROM deps WHERE blocker = ?1)
        \\  OR w.parent = (SELECT parent FROM tickets WHERE id = ?1) OR w.parent = ?1
        \\ORDER BY w.rank, w.id
    , .{id});
    defer st.finalize();
    var cands: std.ArrayList(struct { id: i64, key: []const u8 }) = .empty;
    while (try st.step()) try cands.append(a, .{ .id = st.int(0), .key = try st.dupe(a, 1) });
    for (cands.items) |c| {
        if (c.id == id) continue;
        for (try blockers(db, a, c.id)) |d| if (d.id == id) {
            try out.append(a, c.key);
            break;
        };
    }
    return out.items;
}

/// Queueing an umbrella queues its sub-tickets (it has no work of its own:
/// it runs as them), and shelving it in Backlog shelves the ones that
/// haven't started yet.
fn moveSubtickets(ctx: Ctx, db: Db, id: i64, from: Stage, to: Stage) Error!void {
    if ((try db.int("SELECT 1 FROM tickets WHERE id = ?1 AND umbrella != 0", .{id})) == null) return;
    while (try db.int(
        \\SELECT id FROM tickets c WHERE c.parent = ?1 AND c.stage = ?2 AND c.tmux = ''
        \\  AND NOT EXISTS (SELECT 1 FROM events e WHERE e.ticket = c.id AND e.kind = 'started') ORDER BY c.rank, c.id LIMIT 1
    , .{ id, @as([]const u8, @tagName(from)) })) |c| {
        try moveId(ctx, db, c, from, to);
        try logEvent(ctx, db, c, if (to == .queued) "queued" else "shelved", "with its parent");
    }
}

fn parentId(db: Db, id: i64) Error!?i64 {
    return db.int("SELECT parent FROM tickets WHERE id = ?1 AND parent IS NOT NULL", .{id});
}

/// Under way: queued, or further along but not Done. An umbrella in
/// Backlog or Planning is still being filled with sub-tickets.
fn underWay(stage: Stage) bool {
    return switch (stage) {
        .queued, .running, .review, .testing => true,
        .backlog, .planning, .done => false,
    };
}

/// A sub-ticket of `pid` reached Done (or an unfinished one was deleted, or
/// `pid` became an umbrella under way). Once none is left unfinished, and at
/// least one is Done:
/// - an umbrella under way goes to Done by itself, which may in turn finish
///   its own umbrella; one in Backlog or Planning stays put (more sub-tickets
///   may come);
/// - any other parent gets `ready-to-close`: it may have work of its own
///   left, so the human decides.
fn subticketsSettled(ctx: Ctx, db: Db, pid: i64) Error!void {
    if ((try db.int("SELECT 1 FROM tickets WHERE parent = ?1 AND stage != 'done'", .{pid})) != null) return;
    const n = (try db.int("SELECT count(*) FROM tickets WHERE parent = ?1", .{pid})) orelse 0;
    if (n == 0) return;
    var st = try db.query("SELECT stage, umbrella FROM tickets WHERE id = ?1", .{pid});
    const stage, const umbrella = blk: {
        defer st.finalize();
        if (!try st.step()) return;
        break :blk .{ Stage.parse(st.text(0)) orelse return, st.int(1) != 0 };
    };
    if (stage == .done) return;
    var buf: [256]u8 = undefined;
    const all = std.fmt.bufPrint(&buf, "{s} {d} sub-ticket{s} done", .{ if (n == 1) "its" else "all", n, if (n == 1) " is" else "s are" }) catch unreachable;
    if (umbrella) {
        if (!underWay(stage)) return;
        try db.exec("UPDATE tickets SET summary = ?2 WHERE id = ?1 AND summary = ''", .{ pid, std.fmt.bufPrint(buf[all.len..], "Closed by cl: {s}.", .{all}) catch unreachable });
        try logEvent(ctx, db, pid, "closed", all);
        try moveId(ctx, db, pid, stage, .done);
        return;
    }
    var dbuf: [512]u8 = undefined;
    const detail = std.fmt.bufPrint(&dbuf, "{s}. Move it to Done if nothing of its own is left, or dismiss this to keep it open.", .{all}) catch unreachable;
    try setFlagId(ctx, db, pid, flag_ready_to_close, "auto", detail);
}

/// A sub-ticket of `pid` got under way: a Queued umbrella moves to Running,
/// since its sub-tickets are being worked on (and so may its own umbrella).
fn pickUp(ctx: Ctx, db: Db, pid: i64) Error!void {
    if ((try db.int("SELECT 1 FROM tickets WHERE id = ?1 AND umbrella != 0 AND stage = 'queued'", .{pid})) == null) return;
    try logEvent(ctx, db, pid, "picked up", "a sub-ticket started");
    try moveId(ctx, db, pid, .queued, .running);
}

fn touch(ctx: Ctx, db: Db, id: i64) Error!void {
    try db.exec("UPDATE tickets SET updated = ?2 WHERE id = ?1", .{ id, now(ctx) });
}

pub fn logEvent(ctx: Ctx, db: Db, id: i64, kind: []const u8, detail: []const u8) Error!void {
    try db.exec("INSERT INTO events (ticket, kind, detail, at) VALUES (?1, ?2, ?3, ?4)", .{ id, kind, detail, now(ctx) });
}

/// Move a ticket to `stage`. Flags follow the workflow: entering Testing sets
/// `testing`, leaving Review or Testing clears its flag, Done clears them all.
/// Any move ends finishing.
pub fn move(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, stage: Stage) Error!void {
    const t = try getTicket(db, a, key);
    if (t.stage == stage) return;
    try moveId(ctx, db, t.id, t.stage, stage);
}

fn moveId(ctx: Ctx, db: Db, id: i64, from: Stage, to: Stage) Error!void {
    // Queued again, a killed ticket waits for the dispatcher like any other.
    try db.exec("UPDATE tickets SET stage = ?2, finishing = '', killed = killed AND ?2 != 'queued' WHERE id = ?1", .{ id, @as([]const u8, @tagName(to)) });
    var buf: [64]u8 = undefined;
    try logEvent(ctx, db, id, "moved", std.fmt.bufPrint(&buf, "{s} -> {s}", .{ @tagName(from), @tagName(to) }) catch "");
    if (from == .review) try clearFlagId(ctx, db, id, flag_review);
    if (from == .testing) try clearFlagId(ctx, db, id, flag_testing);
    // Moved, it is the move that says what's next (the dispatcher raises it
    // again if it's still in progress and idle).
    try setIdle(ctx, db, id, false);
    if (to == .testing) try setFlagId(ctx, db, id, flag_testing, "auto", "");
    // All but a failed after-merge run's: that comes after the merge, so it
    // stays until the next run (or the human) clears it.
    if (to == .done) try db.exec("UPDATE flags SET cleared = ?2 WHERE ticket = ?1 AND cleared IS NULL AND kind != ?3", .{ id, now(ctx), flag_after_merge });
    // Out of Done, it is under way again: "done without merging" no longer holds.
    if (from == .done) try clearFlagId(ctx, db, id, flag_unmerged);
    if (to == .queued) try moveSubtickets(ctx, db, id, .backlog, .queued);
    // Picked up (see `pickUp`), an umbrella may be shelved from Running too.
    if (underWay(from) and to == .backlog) try moveSubtickets(ctx, db, id, .queued, .backlog);
    try touch(ctx, db, id);
    // Its parent: one sub-ticket fewer to wait on, or one more again, or
    // one being worked on.
    if (try parentId(db, id)) |pid| {
        if (to == .done) try subticketsSettled(ctx, db, pid);
        if (from == .done) try clearFlagId(ctx, db, pid, flag_ready_to_close);
        if (to == .running or to == .review or to == .testing) try pickUp(ctx, db, pid);
    }
    // An umbrella queued with its sub-tickets all done has nothing to wait for.
    if (underWay(to) and !underWay(from) and (try db.int("SELECT 1 FROM tickets WHERE id = ?1 AND umbrella != 0", .{id})) != null)
        try subticketsSettled(ctx, db, id);
}

/// Set a flag (a no-op if it is already set).
pub fn setFlag(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, kind: []const u8, source: []const u8, detail: []const u8) Error!void {
    if (!validFlag(kind)) return error.BadInput;
    const t = try getTicket(db, a, key);
    try setFlagId(ctx, db, t.id, kind, source, detail);
}

fn validFlag(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > 32) return false;
    for (kind) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    return true;
}

pub fn setFlagId(ctx: Ctx, db: Db, id: i64, kind: []const u8, source: []const u8, detail: []const u8) Error!void {
    if (try db.int("SELECT id FROM flags WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ id, kind })) |fid| {
        // Keep its age (the inbox orders by it); refresh what it says. Asking
        // something new brings a hidden one back.
        try db.exec("UPDATE flags SET hidden = (hidden AND detail = ?2), detail = ?2 WHERE id = ?1", .{ fid, detail });
        return;
    }
    // Anything else it asks says more than "idle": that one goes.
    if (!std.mem.eql(u8, kind, flag_idle)) try setIdle(ctx, db, id, false);
    try db.exec("INSERT INTO flags (ticket, kind, source, detail, at) VALUES (?1, ?2, ?3, ?4, ?5)", .{ id, kind, source, detail, now(ctx) });
    try touch(ctx, db, id);
    try logEvent(ctx, db, id, "flagged", kind);
}

/// What the `idle` flag says (one text, so a hidden one stays hidden).
pub const idle_detail = "Claude ended its turn and is waiting for you";

/// Raise or clear the `idle` flag (the dispatcher keeps it in step with the
/// session: signals.syncIdle). Raised only when the ticket has no other
/// flag; it comes and goes with every turn, so it is left out of the
/// activity log.
pub fn setIdle(ctx: Ctx, db: Db, id: i64, on: bool) Error!void {
    if (!on) {
        try db.exec("UPDATE flags SET cleared = ?3 WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ id, flag_idle, now(ctx) });
        if (db.changes() > 0) try touch(ctx, db, id);
        return;
    }
    if ((try db.int("SELECT 1 FROM flags WHERE ticket = ?1 AND cleared IS NULL", .{id})) != null) return;
    try db.exec("INSERT INTO flags (ticket, kind, source, detail, at) VALUES (?1, ?2, 'auto', ?3, ?4)", .{ id, flag_idle, idle_detail, now(ctx) });
    try touch(ctx, db, id);
}

pub fn clearFlag(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, kind: []const u8) Error!void {
    const t = try getTicket(db, a, key);
    try clearFlagId(ctx, db, t.id, kind);
}

pub fn clearFlagId(ctx: Ctx, db: Db, id: i64, kind: []const u8) Error!void {
    try db.exec("UPDATE flags SET cleared = ?3 WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ id, kind, now(ctx) });
    if (db.changes() > 0) {
        try touch(ctx, db, id);
        try logEvent(ctx, db, id, "unflagged", kind);
    }
}

/// Flags that still ask something of a Done ticket, so Needs You keeps it:
/// its work didn't land (not merged, or merging it later conflicted) or what
/// runs after the merge failed. Going to Done clears the others.
pub fn asksWhenDone(kind: []const u8) bool {
    for ([_][]const u8{ flag_after_merge, flag_unmerged, flag_merge_failed, flag_conflict }) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

/// Flags that wait on the human to do something with the ticket: Claude is
/// blocked on a question or a permission prompt, or the ticket's next step is
/// theirs (review it, test it, sort out a conflict), or Claude is idle and
/// waits for its next prompt (dismissing that would only raise it again).
/// Answering or acting
/// clears them, so the board doesn't offer to dismiss them; Hide is for "not
/// now". `cl ticket unflag` still clears any flag.
pub fn waitingFlag(kind: []const u8) bool {
    for ([_][]const u8{ flag_question, flag_input, flag_review, flag_testing, flag_conflict, flag_idle }) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

/// Dismiss a flag from the board: "seen it, it's dealt with". It clears the
/// flag as `cl ticket unflag` does (logged as unflagged, dismissed) and
/// changes nothing else about the ticket; the flag comes back only if the
/// same thing happens again. BadInput for a waiting flag; false when the
/// ticket doesn't have the flag (already cleared).
pub fn dismissFlag(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, kind: []const u8) Error!bool {
    if (waitingFlag(kind)) return error.BadInput;
    const t = try getTicket(db, a, key);
    try db.exec("UPDATE flags SET cleared = ?3 WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ t.id, kind, now(ctx) });
    if (db.changes() == 0) return false;
    try touch(ctx, db, t.id);
    var buf: [64]u8 = undefined;
    try logEvent(ctx, db, t.id, "unflagged", std.fmt.bufPrint(&buf, "{s} (dismissed)", .{kind}) catch kind);
    return true;
}

/// Hide the ticket from Needs You (and `cl ticket needs`), or bring it back.
/// Its flags stay set, so its card still shows them; a new flag brings it
/// back by itself. False when it has no flag to hide.
pub fn hideNeeds(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, hidden: bool) Error!bool {
    const t = try getTicket(db, a, key);
    if (t.flags.len == 0) return false;
    try db.exec("UPDATE flags SET hidden = ?2 WHERE ticket = ?1 AND cleared IS NULL", .{ t.id, hidden });
    try logEvent(ctx, db, t.id, if (hidden) "hidden from needs" else "back in needs", "");
    return true;
}

/// A session was killed on purpose: the tickets on it that aren't done let
/// go of it and wait to be restarted (`killed`), with no flag raised. What
/// the session was waiting on (a question, a permission prompt) went with it.
/// The conversation id is kept, so a restart resumes it.
pub fn sessionKilled(ctx: Ctx, db: Db, a: std.mem.Allocator, tmux_name: []const u8) Error!void {
    var st = try db.query("SELECT id FROM tickets WHERE tmux = ?1 AND stage != 'done'", .{tmux_name});
    defer st.finalize();
    var ids: std.ArrayList(i64) = .empty;
    while (try st.step()) try ids.append(a, st.int(0));
    for (ids.items) |id| {
        try db.exec("UPDATE tickets SET tmux = '', killed = 1 WHERE id = ?1", .{id});
        for ([_][]const u8{ flag_question, flag_input, "ended" }) |k| try clearFlagId(ctx, db, id, k);
        try setIdle(ctx, db, id, false);
        try logEvent(ctx, db, id, "killed", tmux_name);
        try touch(ctx, db, id);
    }
}

/// The stages of a ticket in progress: it holds its session (planning
/// runs in one of its own; see `dispatch.in_progress`).
pub const in_progress = "('running', 'review', 'testing')";

/// A ticket other than `id` is in progress in `tmux_name`.
pub fn sessionHasTicket(db: Db, tmux_name: []const u8, id: i64) Error!bool {
    return (try db.int("SELECT 1 FROM tickets WHERE tmux = ?1 AND id != ?2 AND stage IN " ++ in_progress, .{ tmux_name, id })) != null;
}

/// Keep the ticket's conversation id current (/clear starts a new one).
pub fn setSessionId(db: Db, id: i64, session_id: []const u8) Error!void {
    try db.exec("UPDATE tickets SET session_id = ?2 WHERE id = ?1", .{ id, session_id });
}

pub const CommentResult = struct {
    /// The ticket was in Review or Testing and went back to Running.
    sent_back: bool = false,
};

/// Add a comment. `sent` marks one typed into the session; a sent comment
/// on a ticket Claude said was done is a request for more work, so the
/// ticket goes back to Running for another round (not while it is finishing:
/// then it answers Claude's merge or PR).
pub fn addComment(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, author: []const u8, body: []const u8, sent: bool) Error!CommentResult {
    if (body.len == 0) return error.BadInput;
    const t = try getTicket(db, a, key);
    try db.exec("INSERT INTO comments (ticket, author, body, sent, at) VALUES (?1, ?2, ?3, ?4, ?5)", .{ t.id, author, body, sent, now(ctx) });
    try touch(ctx, db, t.id);
    var r: CommentResult = .{};
    if (sent and std.mem.eql(u8, author, "you") and t.finishing.len == 0 and (t.stage == .review or t.stage == .testing)) {
        try db.exec("UPDATE tickets SET round = round + 1 WHERE id = ?1", .{t.id});
        try moveId(ctx, db, t.id, t.stage, .running);
        r.sent_back = true;
    }
    // An answer typed into the session settles what Claude was waiting on.
    if (sent and std.mem.eql(u8, author, "you")) {
        try clearFlagId(ctx, db, t.id, flag_question);
        try clearFlagId(ctx, db, t.id, flag_input);
        try setIdle(ctx, db, t.id, false);
    }
    return r;
}

/// Claude says the ticket is finished and needs nothing more: it moves to
/// Review with the `review` flag, and the summary is kept as its comment.
/// During Planning it means the plan is ready: the ticket stays in Planning
/// with `review` (detail "plan") until the plan is approved.
pub fn done(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, summary: []const u8) Error!void {
    const t = try getTicket(db, a, key);
    if (t.stage == .planning) {
        if (summary.len > 0) try db.exec("INSERT INTO comments (ticket, author, body, sent, at) VALUES (?1, 'claude', ?2, 0, ?3)", .{ t.id, summary, now(ctx) });
        try clearFlagId(ctx, db, t.id, flag_question);
        try clearFlagId(ctx, db, t.id, flag_input);
        try setFlagId(ctx, db, t.id, flag_review, "auto", "plan");
        try logEvent(ctx, db, t.id, "plan ready", "");
        return;
    }
    try db.exec("UPDATE tickets SET summary = ?2 WHERE id = ?1", .{ t.id, summary });
    if (summary.len > 0) try db.exec("INSERT INTO comments (ticket, author, body, sent, at) VALUES (?1, 'claude', ?2, 0, ?3)", .{ t.id, summary, now(ctx) });
    try clearFlagId(ctx, db, t.id, flag_question);
    try clearFlagId(ctx, db, t.id, flag_input);
    // Woken from a park and finished since: the review flag says it now.
    try clearFlagId(ctx, db, t.id, flag_unparked);
    if (t.stage != .review) try moveId(ctx, db, t.id, t.stage, .review);
    try setFlagId(ctx, db, t.id, flag_review, "auto", "");
    try logEvent(ctx, db, t.id, "done", "");
}

/// The stage `approve` moves a ticket to: an approved plan goes to Queued
/// (a new session builds it when there is room), a reviewed ticket to
/// Testing, a tested one to Done.
pub fn approvedStage(stage: Stage) ?Stage {
    return switch (stage) {
        .planning => .queued,
        .review => .testing,
        .testing => .done,
        else => null,
    };
}

/// Approve what the ticket is waiting on; returns the stage it moved from.
pub fn approve(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8) Error!Stage {
    const t = try getTicket(db, a, key);
    const to = approvedStage(t.stage) orelse return error.BadInput;
    if (t.stage == .planning) try clearFlagId(ctx, db, t.id, flag_review);
    try moveId(ctx, db, t.id, t.stage, to);
    try logEvent(ctx, db, t.id, "approved", @tagName(t.stage));
    return t.stage;
}

/// Start finishing: Claude merges its branch or opens a PR ("merge" or "pr")
/// and then moves it to Done; it stays in its stage until then.
pub fn setFinishing(ctx: Ctx, db: Db, id: i64, how: []const u8) Error!void {
    try db.exec("UPDATE tickets SET finishing = ?2 WHERE id = ?1", .{ id, how });
    // Another try: the last one's failure no longer says where it stands.
    if (how.len > 0) try clearFlagId(ctx, db, id, flag_merge_failed);
    try logEvent(ctx, db, id, "finishing", how);
    try touch(ctx, db, id);
}

/// Mark a ticket as being started, so two dispatchers never start it twice.
/// False when it already has a session (or another start claimed it).
pub fn claimStart(db: Db, id: i64) Error!bool {
    try db.exec("UPDATE tickets SET tmux = '(starting)' WHERE id = ?1 AND tmux = ''", .{id});
    return db.changes() == 1;
}

/// Undo claimStart after a failed start.
pub fn releaseStart(db: Db, id: i64) Error!void {
    try db.exec("UPDATE tickets SET tmux = '' WHERE id = ?1 AND tmux = '(starting)'", .{id});
}

/// Move without the key lookup (the dispatcher has the ticket already).
pub fn moveTicket(ctx: Ctx, db: Db, t: Ticket, stage: Stage) Error!void {
    if (t.stage != stage) try moveId(ctx, db, t.id, t.stage, stage);
}

/// Back to Queued (or still there), not killed: the dispatcher starts it.
pub fn requeue(ctx: Ctx, db: Db, t: Ticket) Error!void {
    try moveTicket(ctx, db, t, .queued);
    try db.exec("UPDATE tickets SET killed = 0 WHERE id = ?1", .{t.id});
}

/// The ticket's jj change and its bookmark ("" and "" to forget them).
pub fn setChange(db: Db, id: i64, change: []const u8, bookmark: []const u8) Error!void {
    try db.exec("UPDATE tickets SET change_id = ?2, branch = ?3 WHERE id = ?1", .{ id, change, bookmark });
}

/// Space between neighboring ranks: room to put tickets in between.
const rank_gap = 1024;

/// Reprioritize: put a ticket right after the one keyed `after`, or right
/// before `before` when there is no `after` (a drop at the top of a column).
/// New tickets go last.
pub fn rankTicket(db: Db, a: std.mem.Allocator, key: []const u8, after: ?[]const u8, before: ?[]const u8) Error!void {
    const t = try getTicket(db, a, key);
    const ref = try getTicket(db, a, after orelse before orelse return error.BadInput);
    if (ref.id == t.id) return;
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    for (0..2) |_| {
        const r = (try db.int("SELECT rank FROM tickets WHERE id = ?1", .{ref.id})).?;
        // The rank on the other side of `ref`, leaving the moved ticket out.
        const other = (if (after != null)
            try db.int("SELECT coalesce(min(rank), ?1 + 2 * ?3) FROM tickets WHERE rank > ?1 AND id != ?2", .{ r, t.id, rank_gap })
        else
            try db.int("SELECT coalesce(max(rank), ?1 - 2 * ?3) FROM tickets WHERE rank < ?1 AND id != ?2", .{ r, t.id, rank_gap })).?;
        const mid = @divFloor(r + other, 2);
        if (mid != r and mid != other) {
            try db.exec("UPDATE tickets SET rank = ?2 WHERE id = ?1", .{ t.id, mid });
            // Sub-tickets run in rank order: a new order mustn't have one
            // wait on a sibling that (through links) waits on it.
            if (try orderCycle(db, a, t.id)) return error.Cycle;
            return db.execMulti("COMMIT");
        }
        // No room between them: spread every ticket out again, keeping the order.
        try db.exec(
            \\UPDATE tickets SET rank = ?1 * (1 + (SELECT count(*) FROM tickets u
            \\  WHERE u.rank < tickets.rank OR (u.rank = tickets.rank AND u.id < tickets.id)))
        , .{rank_gap});
    }
    unreachable;
}

/// Put a ticket first (`top`) or last among the tickets in its stage, across
/// every project: the top or bottom of its board column with all projects
/// shown, so also of its own project's tickets there.
pub fn rankInStage(db: Db, a: std.mem.Allocator, key: []const u8, top: bool) Error!void {
    const t = try getTicket(db, a, key);
    var st = try db.query(if (top)
        "SELECT key FROM tickets WHERE stage = ?1 AND id != ?2 ORDER BY rank, id LIMIT 1"
    else
        "SELECT key FROM tickets WHERE stage = ?1 AND id != ?2 ORDER BY rank DESC, id DESC LIMIT 1", .{ @tagName(t.stage), t.id });
    defer st.finalize();
    if (!try st.step()) return; // Alone in its column.
    const ref = try st.dupe(a, 0);
    if (top) return rankTicket(db, a, key, null, ref);
    return rankTicket(db, a, key, ref, null);
}

pub fn setBase(db: Db, id: i64, base: []const u8) Error!void {
    try db.exec("UPDATE tickets SET base = ?2 WHERE id = ?1", .{ id, base });
}

/// Set the queue-mode target (once the dispatcher made a session for it).
pub fn setTarget(db: Db, id: i64, target: []const u8) Error!void {
    try db.exec("UPDATE tickets SET target = ?2 WHERE id = ?1", .{ id, target });
}

// ---- parks ----

fn parkOf(db: Db, a: std.mem.Allocator, id: i64) Error!?Park {
    var st = try db.query("SELECT reason, until_cmd, every, at, deadline, next, checked, result FROM parks WHERE ticket = ?1", .{id});
    defer st.finalize();
    if (!try st.step()) return null;
    return .{
        .reason = try st.dupe(a, 0),
        .until = try st.dupe(a, 1),
        .every = st.int(2),
        .at = st.int(3),
        .deadline = st.int(4),
        .next = st.int(5),
        .checked = st.int(6),
        .result = try st.dupe(a, 7),
    };
}

/// Park a ticket (or change its park): `p.at` is now, and with a check the
/// first one is due at once.
pub fn setPark(ctx: Ctx, db: Db, id: i64, p: Park) Error!void {
    try db.exec(
        \\INSERT OR REPLACE INTO parks (ticket, reason, until_cmd, every, at, deadline, next, checked, result)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, '')
    , .{ id, p.reason, p.until, p.every, p.at, p.deadline, p.next });
    try logEvent(ctx, db, id, "parked", p.reason);
    try touch(ctx, db, id);
}

/// End a ticket's park and return it; null when it wasn't parked. With
/// `at`, only the park made then (a check finishing late leaves a newer
/// park alone).
pub fn takePark(ctx: Ctx, db: Db, a: std.mem.Allocator, id: i64, at: ?i64) Error!?Park {
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    const p = try parkOf(db, a, id) orelse {
        try db.execMulti("COMMIT");
        return null;
    };
    if (at != null and at.? != p.at) {
        try db.execMulti("COMMIT");
        return null;
    }
    try db.exec("DELETE FROM parks WHERE ticket = ?1", .{id});
    try db.execMulti("COMMIT");
    try touch(ctx, db, id);
    return p;
}

pub const DuePark = struct { id: i64, key: []const u8, park: Park };

/// Parks whose check is due (`next` has come), or whose time is up
/// (`deadline` has passed), at `t`.
pub fn dueParks(db: Db, a: std.mem.Allocator, t: i64) Error![]DuePark {
    var st = try db.query("SELECT k.ticket, t.key FROM parks k JOIN tickets t ON t.id = k.ticket WHERE k.until_cmd != '' AND (k.next <= ?1 OR (k.deadline > 0 AND k.deadline <= ?1))", .{t});
    defer st.finalize();
    var ids: std.ArrayList(struct { i64, []const u8 }) = .empty;
    while (try st.step()) try ids.append(a, .{ st.int(0), try st.dupe(a, 1) });
    var out: std.ArrayList(DuePark) = .empty;
    for (ids.items) |x| if (try parkOf(db, a, x[0])) |p| try out.append(a, .{ .id = x[0], .key = x[1], .park = p });
    return out.toOwnedSlice(a);
}

/// Take the due check of the park made at `at`: the next one moves an
/// interval on, so another dispatcher doesn't run it too. False when it
/// isn't due (any more).
pub fn claimParkCheck(db: Db, id: i64, at: i64, t: i64) Error!bool {
    try db.exec("UPDATE parks SET next = ?3 + every WHERE ticket = ?1 AND at = ?2 AND next <= ?3", .{ id, at, t });
    return db.changes() == 1;
}

/// What a check said, on the park made at `at` (if it is still there).
pub fn recordParkCheck(db: Db, id: i64, at: i64, t: i64, result: []const u8) Error!void {
    try db.exec("UPDATE parks SET checked = ?3, result = ?4 WHERE ticket = ?1 AND at = ?2", .{ id, at, t, result });
}

/// Unsent notes from you (or from cl, about what it did to the ticket),
/// oldest first: they go along with the next prompt.
pub fn unsentNotes(db: Db, a: std.mem.Allocator, id: i64) Error![]Comment {
    var st = try db.query("SELECT author, body, sent, at FROM comments WHERE ticket = ?1 AND author IN ('you', 'cl') AND sent = 0 ORDER BY at, id", .{id});
    defer st.finalize();
    var out: std.ArrayList(Comment) = .empty;
    while (try st.step()) try out.append(a, .{ .author = try st.dupe(a, 0), .body = try st.dupe(a, 1), .sent = false, .at = st.int(3) });
    return out.toOwnedSlice(a);
}

pub fn markNotesSent(db: Db, id: i64) Error!void {
    try db.exec("UPDATE comments SET sent = 1 WHERE ticket = ?1 AND author IN ('you', 'cl') AND sent = 0", .{id});
}

// ---- tests ----

const testing = std.testing;

fn testCtx() Ctx {
    return .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = undefined, .home = "/tmp" };
}

test "projects, tickets, flags, comments, done" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);

    try addProject(db, .{ .name = "qa-tool", .dir = "/x/qa-tool", .slots = 2 });
    try testing.expectEqual(@as(i64, 2), (try getProject(db, a, "qa-tool")).slots);
    try addProject(db, .{ .name = "boats", .dir = "/x/boats" });
    try testing.expectEqual(@as(i64, default_slots), (try getProject(db, a, "boats")).slots);
    try db.exec("INSERT INTO projects (name, dir, prefix) VALUES ('raw', '/x/raw', 'RAW')", .{});
    try testing.expectEqual(@as(i64, default_slots), (try getProject(db, a, "raw")).slots);
    try testing.expectError(error.Exists, addProject(db, .{ .name = "qa-thing", .dir = "/x", .prefix = "QA" }));

    const k1 = try createTicket(ctx, db, a, .{ .project = "qa-tool", .title = "Flaky login spec", .body = "fails on CI" });
    const k2 = try createTicket(ctx, db, a, .{ .project = "qa-tool", .title = "CSV export", .plan = true });
    try testing.expectEqualStrings("QA-1", k1);
    try testing.expectEqualStrings("QA-2", k2);
    try testing.expectEqual(Stage.planning, (try getTicket(db, a, "qa-2")).stage);

    try setFlag(ctx, db, a, k1, flag_question, "auto", "{\"q\":\"which?\"}");
    try setFlag(ctx, db, a, k1, flag_question, "auto", "again");
    const t1 = try getTicket(db, a, k1);
    try testing.expectEqual(@as(usize, 1), t1.flags.len);
    try testing.expectEqualStrings("again", t1.flags[0].detail);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);

    // Answering clears it; done moves to Review with the review flag.
    _ = try addComment(ctx, db, a, k1, "you", "use the staging DB", true);
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, k1)).flags.len);
    try done(ctx, db, a, k1, "Fixed the race in the login spec");
    const t2 = try getTicket(db, a, k1);
    try testing.expectEqual(Stage.review, t2.stage);
    try testing.expectEqualStrings(flag_review, t2.flags[0].kind);

    // A sent comment on a done ticket sends it back for another round.
    const r = try addComment(ctx, db, a, k1, "you", "also cover logout", true);
    try testing.expect(r.sent_back);
    const t3 = try getTicket(db, a, k1);
    try testing.expectEqual(Stage.running, t3.stage);
    try testing.expectEqual(@as(i64, 2), t3.round);
    try testing.expectEqual(@as(usize, 0), t3.flags.len);

    // A busy session's ticket isn't waiting on the human; it is again once
    // the session stops. A busy session speaks only for the ticket it is on.
    try setSession(ctx, db, t3.id, "cl_qa_1", "", "", "");
    try done(ctx, db, a, k1, "Covered logout too");
    const busy: []const []const u8 = &.{"cl_qa_1"};
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true, .busy = busy })).len);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
    // QA-2 (Planning) starts in the same session: busy, it is on QA-2.
    const t2b = try getTicket(db, a, k2);
    try setSession(ctx, db, t2b.id, "cl_qa_1", "", "", "");
    try testing.expect(!try isWorking(db, try getTicket(db, a, k1), busy));
    try testing.expect(try isWorking(db, try getTicket(db, a, k2), busy));
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true, .busy = busy })).len);
    try setSession(ctx, db, t2b.id, "", "", "", "");
    _ = try addComment(ctx, db, a, k1, "you", "also cover logout", true);

    // Search covers titles and comments.
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .search = "logout" })).len);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .search = "csv" })).len);

    // Testing sets its flag; Done clears every flag.
    try move(ctx, db, a, k1, .testing);
    try testing.expectEqualStrings(flag_testing, (try getTicket(db, a, k1)).flags[0].kind);
    try move(ctx, db, a, k1, .done);
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, k1)).flags.len);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .done = false })).len);

    // Finishing keeps it in place through sent comments; moving ends it.
    try move(ctx, db, a, k1, .testing);
    try setFinishing(ctx, db, (try getTicket(db, a, k1)).id, "merge");
    try testing.expectEqualStrings("merge", (try getTicket(db, a, k1)).finishing);
    try testing.expect(!(try addComment(ctx, db, a, k1, "you", "keep their version", true)).sent_back);
    try move(ctx, db, a, k1, .done);
    try testing.expectEqualStrings("", (try getTicket(db, a, k1)).finishing);

    // Sub-tickets: in the parent's project, hidden by `top`, listed by parent.
    const sub = try createTicket(ctx, db, a, .{ .parent = k2, .title = "CSV quoting rules" });
    try testing.expectEqualStrings("QA-3", sub);
    try testing.expectEqualStrings("QA-2", (try getTicket(db, a, sub)).parent);
    try testing.expectEqual(@as(i64, 1), (try getTicket(db, a, k2)).children);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .parent = k2 })).len);
    try testing.expectEqual(@as(usize, 2), (try listTickets(db, a, .{ .top = true })).len);
    try testing.expectError(error.Exists, removeTicket(ctx, db, a, k2));
    try testing.expectEqual(@as(usize, 1), (try openSubtickets(db, a, k2)).len);
    try spinOff(ctx, db, a, k2);
    try testing.expectEqual(@as(usize, 0), (try openSubtickets(db, a, k2)).len);
    try testing.expectEqualStrings("", (try getTicket(db, a, sub)).parent);
    _ = try removeTicket(ctx, db, a, sub);

    try testing.expectError(error.Exists, removeProject(db, "qa-tool"));
    _ = try removeTicket(ctx, db, a, k1);
    _ = try removeTicket(ctx, db, a, k2);
    try removeProject(db, "qa-tool");
}

test "hidden projects: their tickets leave the shown lists, not the dispatcher's" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try addProject(db, .{ .name = "web", .dir = "/x/web" });
    const k1 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Shown", .stage = .queued });
    _ = try createTicket(ctx, db, a, .{ .project = "web", .title = "Hidden", .stage = .queued });
    try setProjectHidden(db, "web", true);
    try testing.expect((try getProject(db, a, "web")).hidden);
    try testing.expect(!(try getProject(db, a, "qa")).hidden);
    const shown = try listTickets(db, a, .{ .shown = true });
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expectEqualStrings(k1, shown[0].key);
    try testing.expectEqual(@as(usize, 2), (try listTickets(db, a, .{ .stage = .queued })).len);
    try setProjectHidden(db, "web", false);
    try testing.expectEqual(@as(usize, 2), (try listTickets(db, a, .{ .shown = true })).len);
    try testing.expectError(error.NotFound, setProjectHidden(db, "nope", true));
}

test "rank: new tickets go last, a drop goes between its neighbors" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k1 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "One" });
    const k2 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Two" });
    const k3 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Three" });
    const order = struct {
        fn of(d: Db, al: std.mem.Allocator) ![]const u8 {
            var st = try d.query("SELECT title FROM tickets ORDER BY rank, id", .{});
            defer st.finalize();
            var out: std.ArrayList(u8) = .empty;
            while (try st.step()) {
                if (out.items.len > 0) try out.append(al, ' ');
                try out.appendSlice(al, st.text(0));
            }
            return out.items;
        }
    }.of;
    try testing.expectEqualStrings("One Two Three", try order(db, a));
    try rankTicket(db, a, k3, null, k1);
    try testing.expectEqualStrings("Three One Two", try order(db, a));
    try rankTicket(db, a, k3, k1, null);
    try testing.expectEqualStrings("One Three Two", try order(db, a));
    try rankTicket(db, a, k1, k2, null);
    try testing.expectEqualStrings("Three Two One", try order(db, a));

    // Out of room between two ranks: everything spreads out again.
    try db.exec("UPDATE tickets SET rank = 5 WHERE key = ?1", .{k3});
    try db.exec("UPDATE tickets SET rank = 6 WHERE key = ?1", .{k2});
    try rankTicket(db, a, k1, k3, null);
    try testing.expectEqualStrings("Three One Two", try order(db, a));
    try testing.expectEqual(@as(i64, rank_gap + rank_gap / 2), (try getTicket(db, a, k1)).rank);
}

test "rank: --top and --bottom go to the ends of the ticket's stage" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try addProject(db, .{ .name = "web", .dir = "/x/web" });
    // Ranks: Back1 < Q1 < Q2 (web) < Q3 < Back2. Only Q1..Q3 are queued.
    const b1 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Back1", .stage = .backlog });
    const q1 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Q1", .stage = .queued });
    const q2 = try createTicket(ctx, db, a, .{ .project = "web", .title = "Q2", .stage = .queued });
    const q3 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Q3", .stage = .queued });
    const b2 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Back2", .stage = .backlog });
    const rank = struct {
        fn of(d: Db, al: std.mem.Allocator, k: []const u8) !i64 {
            return (try getTicket(d, al, k)).rank;
        }
    }.of;

    // First in the column, across projects; still behind the backlog's Back1.
    try rankInStage(db, a, q3, true);
    try testing.expect(try rank(db, a, q3) < try rank(db, a, q1));
    try testing.expect(try rank(db, a, q3) > try rank(db, a, b1));
    // Last in the column, ahead of the backlog's Back2.
    try rankInStage(db, a, q1, false);
    try testing.expect(try rank(db, a, q1) > try rank(db, a, q2));
    try testing.expect(try rank(db, a, q1) < try rank(db, a, b2));
    // Already there, or alone in its stage: nothing breaks.
    try rankInStage(db, a, q3, true);
    try testing.expect(try rank(db, a, q3) < try rank(db, a, q2));
    try rankInStage(db, a, b2, true);
    try testing.expect(try rank(db, a, b2) < try rank(db, a, b1));
    try testing.expectError(error.NotFound, rankInStage(db, a, "QA-99", true));
}

test "a killed session's tickets let go of it, unflagged, and wait to be restarted" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k1 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Asking", .stage = .running });
    const k2 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "In review", .stage = .review });
    const k3 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Finished", .stage = .done });
    const k4 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Elsewhere", .stage = .running });
    for ([_][]const u8{ k1, k2, k3 }) |k| try setSession(ctx, db, (try getTicket(db, a, k)).id, "cl_qa_1", "0e8c3f8a-0000-4000-8000-000000000001", "", "");
    try setSession(ctx, db, (try getTicket(db, a, k4)).id, "cl_other_2", "", "", "");
    try setFlag(ctx, db, a, k1, flag_question, "auto", "{}");
    try setFlag(ctx, db, a, k2, flag_review, "auto", "");

    try sessionKilled(ctx, db, a, "cl_qa_1");
    const t1 = try getTicket(db, a, k1);
    try testing.expectEqualStrings("", t1.tmux);
    try testing.expect(t1.killed);
    try testing.expectEqual(Stage.running, t1.stage);
    // Its conversation id stays, for the restart to resume.
    try testing.expectEqualStrings("0e8c3f8a-0000-4000-8000-000000000001", t1.session_id);
    // What the session asked went with it; Review still needs you.
    try testing.expectEqual(@as(usize, 0), t1.flags.len);
    const t2 = try getTicket(db, a, k2);
    try testing.expect(t2.killed);
    try testing.expectEqualStrings(flag_review, t2.flags[0].kind);
    // Done tickets and other sessions are left alone.
    try testing.expectEqualStrings("cl_qa_1", (try getTicket(db, a, k3)).tmux);
    try testing.expect(!(try getTicket(db, a, k4)).killed);

    // A new session, or queueing it again, ends the wait.
    try setSession(ctx, db, t1.id, "cl_qa_3", t1.session_id, "", "");
    try testing.expect(!(try getTicket(db, a, k1)).killed);
    try move(ctx, db, a, k2, .backlog);
    try testing.expect((try getTicket(db, a, k2)).killed);
    try move(ctx, db, a, k2, .queued);
    try testing.expect(!(try getTicket(db, a, k2)).killed);
}

test "hiding a ticket from Needs You keeps its flags until it raises a new one" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Ended", .stage = .running });
    try testing.expect(!try hideNeeds(ctx, db, a, k, true)); // no flag: nothing to hide
    try setFlag(ctx, db, a, k, "ended", "auto", "gone");
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);

    try testing.expect(try hideNeeds(ctx, db, a, k, true));
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true, .hidden = true })).len);
    const t = try getTicket(db, a, k);
    try testing.expectEqual(@as(usize, 1), t.flags.len);
    try testing.expect(t.flags[0].hidden);
    // The same flag set again, saying the same, stays hidden.
    try setFlag(ctx, db, a, k, "ended", "auto", "gone");
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);

    // A new flag brings it back; the hidden one stays hidden.
    try setFlag(ctx, db, a, k, flag_question, "auto", "{}");
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true, .hidden = true })).len);

    // So does the same flag asking something new.
    _ = try hideNeeds(ctx, db, a, k, true);
    try setFlag(ctx, db, a, k, flag_question, "auto", "{\"q\":\"another\"}");
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);

    // Unhiding puts it all back.
    _ = try hideNeeds(ctx, db, a, k, true);
    _ = try hideNeeds(ctx, db, a, k, false);
    for ((try getTicket(db, a, k)).flags) |f| try testing.expect(!f.hidden);
}

test "dismissing a flag clears it for good, but never a waiting one" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Didn't start", .stage = .queued });
    try setFlag(ctx, db, a, k, "start-failed", "auto", "SessionFailed");
    try setFlag(ctx, db, a, k, flag_question, "auto", "{}");
    _ = try hideNeeds(ctx, db, a, k, true);

    // A question is Claude waiting: the board can't dismiss it.
    try testing.expectError(error.BadInput, dismissFlag(ctx, db, a, k, flag_question));
    try testing.expect(try dismissFlag(ctx, db, a, k, "start-failed"));
    try testing.expect(!try dismissFlag(ctx, db, a, k, "start-failed")); // already gone
    const t = try getTicket(db, a, k);
    try testing.expectEqual(@as(usize, 1), t.flags.len);
    try testing.expectEqualStrings(flag_question, t.flags[0].kind);
    try testing.expectEqual(Stage.queued, t.stage); // nothing else changes
    var st = try db.query("SELECT detail FROM events WHERE ticket = ?1 AND kind = 'unflagged'", .{t.id});
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqualStrings("start-failed (dismissed)", st.text(0));

    // The same thing happening again brings it back, not hidden.
    try setFlag(ctx, db, a, k, "start-failed", "auto", "SessionFailed");
    const f = (try getTicket(db, a, k)).flags;
    for (f) |x| if (std.mem.eql(u8, x.kind, "start-failed")) try testing.expect(!x.hidden);
}

test "an idle session raises idle only when nothing else asks, and it goes when anything happens" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Idle", .stage = .running });
    const id = (try getTicket(db, a, k)).id;
    const kinds = struct {
        fn of(d: Db, al: std.mem.Allocator, key: []const u8) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for ((try getTicket(d, al, key)).flags) |f| try out.print(al, "{s}{s}", .{ if (out.items.len > 0) "," else "", f.kind });
            return out.items;
        }
    }.of;

    try setIdle(ctx, db, id, true);
    try testing.expectEqualStrings("idle", try kinds(db, a, k));
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
    const busy: []const []const u8 = &.{"cl_qa"};
    try db.exec("UPDATE tickets SET tmux = 'cl_qa' WHERE id = ?1", .{id});
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true, .busy = busy })).len);
    try setIdle(ctx, db, id, false);
    try testing.expectEqualStrings("", try kinds(db, a, k));

    // Hidden, it stays hidden while it stays idle; the next idle turn brings it back.
    try setIdle(ctx, db, id, true);
    _ = try hideNeeds(ctx, db, a, k, true);
    try setIdle(ctx, db, id, true);
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);
    try setIdle(ctx, db, id, false);
    try setIdle(ctx, db, id, true);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);

    // Something sent to the session settles it.
    _ = try addComment(ctx, db, a, k, "you", "go on", true);
    try testing.expectEqualStrings("", try kinds(db, a, k));

    // Another flag replaces it, and while one is up idle isn't raised.
    try setIdle(ctx, db, id, true);
    try setFlag(ctx, db, a, k, flag_question, "auto", "{}");
    try testing.expectEqualStrings("question", try kinds(db, a, k));
    try setIdle(ctx, db, id, true);
    try testing.expectEqualStrings("question", try kinds(db, a, k));
    try clearFlag(ctx, db, a, k, flag_question);

    // Done (it moves to Review), a kill, or a move clear it too.
    try setIdle(ctx, db, id, true);
    try done(ctx, db, a, k, "did it");
    try testing.expectEqualStrings("review", try kinds(db, a, k));
    try move(ctx, db, a, k, .running);
    try setIdle(ctx, db, id, true);
    try sessionKilled(ctx, db, a, "cl_qa");
    try testing.expectEqualStrings("", try kinds(db, a, k));
    try setIdle(ctx, db, id, true);
    try move(ctx, db, a, k, .backlog);
    try testing.expectEqualStrings("", try kinds(db, a, k));

    // It comes and goes every turn: not in the activity log. Never dismissed (it would only come back).
    try testing.expect(waitingFlag(flag_idle));
    try testing.expectEqual(@as(?i64, null), try db.int("SELECT 1 FROM events WHERE ticket = ?1 AND detail = 'idle'", .{id}));
}

test "dependencies: links, cycles, a removed blocker, and shelving a parent" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = undefined, .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k1 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "One" });
    const k2 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Two" });
    const k3 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Three" });

    // Itself, and circles through other tickets, are refused.
    try testing.expectError(error.Cycle, addBlocker(ctx, db, a, k1, k1));
    _ = try addBlocker(ctx, db, a, k2, k1);
    _ = try addBlocker(ctx, db, a, k3, k2);
    try testing.expectError(error.Cycle, addBlocker(ctx, db, a, k1, k3));
    try testing.expectError(error.NotFound, addBlocker(ctx, db, a, k1, "QA-99"));
    try testing.expectEqual(@as(usize, 1), (try dependents(db, a, (try getTicket(db, a, k1)).id)).len);

    // Removing a blocker: what waited on it goes on without it, and says so.
    const freed = try removeTicket(ctx, db, a, k2);
    try testing.expectEqual(@as(usize, 1), freed.len);
    try testing.expectEqualStrings(k3, freed[0]);
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, k3)).blocked_by.len);
    try testing.expectEqual(@as(i64, 0), (try db.int("SELECT count(*) FROM deps", .{})).?);
    try testing.expect(!try removeBlocker(ctx, db, a, k3, k1));
    _ = try addBlocker(ctx, db, a, k3, k1);
    try testing.expect(try removeBlocker(ctx, db, a, k3, k1));

    // Sub-tickets: a link against their order is a circle, and so is a
    // reorder or a return to order that would make one.
    const kp = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Parent", .umbrella = true });
    const s1 = try createTicket(ctx, db, a, .{ .parent = kp, .title = "S1" });
    const s2 = try createTicket(ctx, db, a, .{ .parent = kp, .title = "S2" });
    try testing.expectError(error.Cycle, addBlocker(ctx, db, a, s1, s2));
    try setParallel(ctx, db, a, s2, true);
    _ = try addBlocker(ctx, db, a, s1, s2);
    try testing.expectError(error.Cycle, setParallel(ctx, db, a, s2, false));
    try testing.expect((try getTicket(db, a, s2)).parallel);
    try testing.expect(try removeBlocker(ctx, db, a, s1, s2));
    try setParallel(ctx, db, a, s2, false);
    _ = try addBlocker(ctx, db, a, s2, s1);
    const r1 = (try getTicket(db, a, s1)).rank;
    try testing.expectError(error.Cycle, rankTicket(db, a, s1, s2, null));
    try testing.expectEqual(r1, (try getTicket(db, a, s1)).rank);

    // Queued with their umbrella, shelved with it while not started.
    try move(ctx, db, a, kp, .queued);
    try testing.expectEqual(Stage.queued, (try getTicket(db, a, s1)).stage);
    try testing.expectEqual(Stage.queued, (try getTicket(db, a, s2)).stage);
    try move(ctx, db, a, kp, .backlog);
    try testing.expectEqual(Stage.backlog, (try getTicket(db, a, s1)).stage);
    try testing.expectEqual(Stage.backlog, (try getTicket(db, a, s2)).stage);
    try testing.expectEqual(Hold.subtickets, hold(try getTicket(db, a, kp)).?);
    // A parent that isn't an umbrella has work of its own: queueing it leaves
    // them be, and it starts first.
    try updateTicket(ctx, db, a, kp, .{ .umbrella = false });
    try move(ctx, db, a, kp, .queued);
    try testing.expectEqual(Stage.backlog, (try getTicket(db, a, s1)).stage);
    try testing.expect(hold(try getTicket(db, a, kp)) == null);
}

test "an umbrella is picked up when a sub-ticket starts and closes when they are all done" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const top = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Roadmap", .umbrella = true, .stage = .queued });
    const u = try createTicket(ctx, db, a, .{ .parent = top, .title = "Venues v1", .umbrella = true, .stage = .queued });
    const s1 = try createTicket(ctx, db, a, .{ .parent = u, .title = "One", .stage = .queued });
    const s2 = try createTicket(ctx, db, a, .{ .parent = u, .title = "Two", .stage = .queued });
    const s3 = try createTicket(ctx, db, a, .{ .parent = u, .title = "Three" });
    try testing.expect((try getTicket(db, a, u)).umbrella);

    // A sub-ticket starting picks up its umbrella, and that one's umbrella.
    try move(ctx, db, a, s1, .running);
    try testing.expectEqual(Stage.running, (try getTicket(db, a, u)).stage);
    try testing.expectEqual(Stage.running, (try getTicket(db, a, top)).stage);

    // Progress: how many of its sub-tickets are done.
    try move(ctx, db, a, s1, .done);
    var t = try getTicket(db, a, u);
    try testing.expectEqual(@as(i64, 3), t.children);
    try testing.expectEqual(@as(i64, 1), t.children_done);
    try testing.expectEqual(Stage.running, t.stage);

    // A deleted unfinished one no longer holds it up, nor counts.
    try move(ctx, db, a, s2, .done);
    _ = try removeTicket(ctx, db, a, s3);
    t = try getTicket(db, a, u);
    try testing.expectEqual(Stage.done, t.stage);
    try testing.expectEqual(@as(i64, 2), t.children);
    try testing.expectEqualStrings("Closed by cl: all 2 sub-tickets are done.", t.summary);
    try testing.expectEqual(@as(usize, 0), t.flags.len);
    // Its own umbrella had only it left: it closes as well.
    try testing.expectEqual(Stage.done, (try getTicket(db, a, top)).stage);
}

test "an umbrella in Backlog stays put; queued with its sub-tickets done, it closes" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const u = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Later", .umbrella = true });
    const s1 = try createTicket(ctx, db, a, .{ .parent = u, .title = "One", .stage = .queued });

    // Sub-tickets run on their own stage; the Backlog umbrella isn't moved,
    // nor closed or flagged: more sub-tickets may come.
    try move(ctx, db, a, s1, .running);
    try move(ctx, db, a, s1, .done);
    const t = try getTicket(db, a, u);
    try testing.expectEqual(Stage.backlog, t.stage);
    try testing.expectEqual(@as(usize, 0), t.flags.len);

    // Queued now, it has nothing left to wait for.
    try move(ctx, db, a, u, .queued);
    try testing.expectEqual(Stage.done, (try getTicket(db, a, u)).stage);

    // Made an umbrella while queued with its sub-tickets done: the same.
    const p = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Parent", .stage = .queued });
    try move(ctx, db, a, try createTicket(ctx, db, a, .{ .parent = p, .title = "Sub" }), .done);
    try testing.expectEqualStrings(flag_ready_to_close, (try getTicket(db, a, p)).flags[0].kind);
    try updateTicket(ctx, db, a, p, .{ .umbrella = true });
    try testing.expectEqual(Stage.done, (try getTicket(db, a, p)).stage);

    // No sub-tickets left at all (all deleted) isn't "all done".
    const empty = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Nothing yet", .umbrella = true, .stage = .queued });
    _ = try removeTicket(ctx, db, a, try createTicket(ctx, db, a, .{ .parent = empty, .title = "Dropped" }));
    try testing.expectEqual(Stage.queued, (try getTicket(db, a, empty)).stage);
}

test "a parent that isn't an umbrella is flagged ready-to-close instead, in any stage" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const p = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Parent", .stage = .queued });
    const s1 = try createTicket(ctx, db, a, .{ .parent = p, .title = "One", .stage = .queued });

    // It runs first: its sub-tickets wait until it's Done (started by hand
    // here). Waiting on a sub-ticket in turn would be a circle.
    const w = try getTicket(db, a, s1);
    try testing.expectEqual(Hold.blocked, hold(w).?);
    try testing.expectEqualStrings(p, w.blocked_by[0].key);
    try testing.expect(w.blocked_by[0].parent);
    try testing.expect(hold(try getTicket(db, a, p)) == null);
    try testing.expectEqualStrings(s1, (try dependents(db, a, (try getTicket(db, a, p)).id))[0]);
    try testing.expectError(error.Cycle, addBlocker(ctx, db, a, p, s1));

    // Not picked up either: it has work of its own to start.
    try move(ctx, db, a, s1, .running);
    try testing.expectEqual(Stage.queued, (try getTicket(db, a, p)).stage);
    try move(ctx, db, a, s1, .done);
    var t = try getTicket(db, a, p);
    try testing.expectEqual(Stage.queued, t.stage);
    try testing.expectEqual(@as(usize, 1), t.flags.len);
    try testing.expectEqualStrings(flag_ready_to_close, t.flags[0].kind);
    try testing.expectEqualStrings("its 1 sub-ticket is done. Move it to Done if nothing of its own is left, or dismiss this to keep it open.", t.flags[0].detail);
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
    // Dismissable: "keep it open".
    try testing.expect(!waitingFlag(flag_ready_to_close));

    // A new sub-ticket, or one taken out of Done, means it isn't ready after all.
    const s2 = try createTicket(ctx, db, a, .{ .parent = p, .title = "Two" });
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, p)).flags.len);
    try move(ctx, db, a, s2, .done);
    try testing.expectEqual(@as(usize, 1), (try getTicket(db, a, p)).flags.len);
    try move(ctx, db, a, s2, .review);
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, p)).flags.len);

    // In Backlog too; going to Done clears it.
    try move(ctx, db, a, p, .backlog);
    try move(ctx, db, a, s2, .done);
    t = try getTicket(db, a, p);
    try testing.expectEqual(Stage.backlog, t.stage);
    try testing.expectEqualStrings(flag_ready_to_close, t.flags[0].kind);
    try move(ctx, db, a, p, .done);
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, p)).flags.len);
}

test "migrate: a board from before umbrellas gets the column, and its parents that never started become umbrellas" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const roadmap = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Roadmap" });
    _ = try createTicket(ctx, db, a, .{ .parent = roadmap, .title = "Step" });
    const ran = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Ran" });
    try logEvent(ctx, db, (try getTicket(db, a, ran)).id, "started", "cl_qa_1");
    _ = try createTicket(ctx, db, a, .{ .parent = ran, .title = "Split off" });
    const lone = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Alone" });
    try db.execMulti("ALTER TABLE tickets DROP COLUMN umbrella");
    try migrate(db);
    try testing.expect((try getTicket(db, a, roadmap)).umbrella);
    try testing.expect(!(try getTicket(db, a, ran)).umbrella);
    try testing.expect(!(try getTicket(db, a, lone)).umbrella);
    // Once: marked by hand afterwards, it stays as it was set.
    try updateTicket(ctx, db, a, roadmap, .{ .umbrella = false });
    try migrate(db);
    try testing.expect(!(try getTicket(db, a, roadmap)).umbrella);
}
