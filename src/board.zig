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
const when = @import("when.zig");

pub const Db = sqlite.Db;

pub const Stage = enum {
    backlog,
    planning,
    queued,
    running,
    testing,
    review,
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

/// What a project does when Claude finishes one of its tickets in Running
/// (`cl project set --auto-review`): nothing, run the automated review
/// (autoreview.zig) while the ticket waits there, or run it and send what it
/// finds to the ticket's Claude for one round first.
pub const AutoReview = enum {
    off,
    on,
    send,

    pub fn parse(s: []const u8) ?AutoReview {
        return std.meta.stringToEnum(AutoReview, s);
    }
};

/// The flags the board knows. Others are allowed (set by hand).
pub const flag_input = "input"; // blocked on a permission prompt
pub const flag_question = "question"; // Claude asked something
pub const flag_review = "review"; // Claude said done; review it
pub const flag_testing = "testing"; // try it out
pub const flag_conflict = "conflict"; // merging it back conflicts
pub const flag_after_merge = "after-merge"; // the project's after-merge command failed
pub const flag_push_failed = "push-failed"; // pushing trunk to its remote after a merge failed (Project.push_after_merge)
pub const flag_ci_failed = "ci-failed"; // CI failed on the trunk commit pushed after a merge
pub const flag_merge_failed = "merge-failed"; // approved, but its merge (or PR) didn't land
pub const flag_unmerged = "unmerged"; // Done, but its branch's work isn't on its target (trunk, or Ticket.onto)
pub const flag_unparked = "unparked"; // its park's condition came true; it resumed
pub const flag_park_expired = "park-expired"; // its park's check never passed in time
pub const flag_idle = "idle"; // Claude ended its turn; nothing else asks, so it waits on you
pub const flag_pr_closed = "pr-closed"; // the PR its park waited on was closed without merging
pub const flag_ready_to_close = "ready-to-close"; // its sub-tickets are all done, but it has work of its own
pub const flag_reminder = "reminder"; // a todo's reminder came up (Ticket.remind_at): seen it, it can go
pub const flag_due = "due"; // a todo is due today or overdue (Ticket.due_at); raised again each morning

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
    /// Whether a ticket reaching Review gets an automated review by itself
    /// (`cl project set --auto-review`, `autoreview.startOnReview`).
    auto_review: AutoReview = .off,
    /// The git remote trunk is pushed to after each merge into it, whose CI
    /// run cl then watches (`cl project set --push-after-merge`, ci.zig); ""
    /// for none.
    push_after_merge: []const u8 = "",
    /// A code repo (the default). A project that isn't one (`cl project add
    /// --no-repo`, for todos that aren't about code) gets no jj or git: its
    /// tickets have no change, branch, worktree, review guide or automated
    /// review, run in the queue only, and Done just closes them.
    repo: bool = true,
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
    /// Parked on a pull request (`park --pr`): its URL. `until` is the gh
    /// check cl wrote for it, and a PR closed without merging ends the park.
    pr: []const u8 = "",
    /// Parked on the PR it was finished with (`Ticket.pr_url`): feedback on
    /// the PR wakes it to address it, and the merge moves it to Done.
    review: bool = false,
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
    /// Its project is a code repo (`Project.repo`).
    repo: bool = true,
    /// jj: the change its work goes in (change ids survive rewrites), "" for
    /// none (git, or a sub-ticket going on in its parent's change).
    change: []const u8 = "",
    profile: []const u8,
    /// The tmux session working on it, once started.
    tmux: []const u8,
    session_id: []const u8,
    /// Claude's summary from `done`.
    summary: []const u8,
    /// The Overview tab's two lines, from Claude (`cl ticket overview`):
    /// what it did last (or "In progress: ..."), and what comes next; ""
    /// for none. `done` puts its summary in `overview_last` and clears
    /// `overview_next` (what's next is then the human's, which the board
    /// works out from the stage and flags). `overview_at`: when they were
    /// last set, 0 for never.
    overview_last: []const u8 = "",
    overview_next: []const u8 = "",
    overview_at: i64 = 0,
    /// The test plan Claude gave with `done` (markdown steps, review.zig's
    /// format_help: only what needs the human), "" for none.
    test_plan: []const u8 = "",
    /// What Claude checked by itself before `done`, and what it saw
    /// (markdown, the handoff's "# Verified"), "" for none.
    verified: []const u8 = "",
    /// A guided tour of what changed (the handoff's "# Demo": steps like the
    /// test plan's, without checks), "" for none.
    demo: []const u8 = "",
    /// The review guide for gutter its session last wrote, taken from
    /// .claude/review-guide.md at `done`; "" for none.
    review_guide: []const u8 = "",
    /// The last automated review (autoreview.zig), as JSON: its status,
    /// summary and findings; "" for none.
    autoreview: []const u8 = "",
    /// What to do once its PR merges: Claude's suggestion (`custom-close
    /// --then`), or what you chose finishing it with a PR. Finished with a
    /// PR URL, it becomes a follow-up sub-ticket parked on that PR; "" for
    /// none.
    pr_then: []const u8 = "",
    /// The pull request it was finished with (`done --close --pr-url`), ""
    /// for none. Until it merges, the ticket stays in `pr_stage`, parked on
    /// it, and a round that woke for feedback on the PR goes back there and
    /// is parked on it again (`park.reparkOnPr`).
    pr_url: []const u8 = "",
    /// The stage it was in when it was parked on `pr_url`.
    pr_stage: []const u8 = "",
    /// Feedback on `pr_url` already handed to its session: outside reviews
    /// and comments up to this time, and the head commit whose failed
    /// required checks it was told about ("" for none). See pr_feedback.zig.
    pr_seen: i64 = 0,
    pr_seen_sha: []const u8 = "",
    /// The stage a round of work was sent back from ("review" or
    /// "testing"; "" for none): Claude's `done` returns it there
    /// (`nextAfterDone`). Set as it moves from Testing or Review to Running.
    back_to: []const u8 = "",
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
    /// The human's own ticket, not Claude's work: nothing about it runs by
    /// itself. The dispatcher never starts it (`hold`), it never closes when
    /// its sub-tickets are done, and it lives in Backlog ("to do"), Running
    /// ("doing") or Done only; waiting on someone is a park. Its sub-tickets
    /// are Claude tasks for it: parallel by default, and they don't wait on
    /// it. Never an umbrella or a planning ticket.
    todo: bool = false,
    /// Where it came from (a Slack permalink, an email, a PR URL), "" for
    /// none. Any ticket may have one; a todo's sub-tickets are told it.
    link: []const u8 = "",
    /// A todo's due date (unix seconds), 0 for none. A date alone is that
    /// day's morning (`board.morning`); `due_time` says a time was given.
    /// From its morning on, the dispatcher keeps it flagged `due`.
    due_at: i64 = 0,
    due_time: bool = false,
    /// A todo's next reminder (unix seconds), 0 for none: once it comes,
    /// the dispatcher flags it `reminder` and sets this back to 0.
    remind_at: i64 = 0,
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
    /// Set while its change would conflict with its target (trunk, or its
    /// `onto` branch) if rebased onto it now (drift.zig).
    drift: ?Drift = null,
};

/// A ticket's change would conflict with its target if rebased now: the
/// dispatcher's test rebase (drift.zig) found it.
pub const Drift = struct {
    /// The files that would conflict, one per line.
    files: []const u8,
    /// The bookmark it was tested against (trunk, or its `onto` branch).
    onto: []const u8,
    /// When that was found.
    at: i64,
};

pub const Error = error{
    Sqlite,
    NotFound,
    Exists,
    BadInput,
    OutOfMemory,
    /// The tickets would wait on each other in a circle, so none would start.
    Cycle,
    /// Asked for what only a code repo has (a worktree, an automated
    /// review, a target branch, a push or after-merge command) in a
    /// project that isn't one (`Project.repo`).
    NoRepo,
    /// A project can't stop being a code repo while its unfinished tickets
    /// have work in it (a worktree, a jj change or a branch).
    RepoWork,
    /// Not for a todo (`Ticket.todo`): a stage other than Backlog, Running
    /// or Done, a plan, being an umbrella, or Claude saying it's done.
    Todo,
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
    \\  auto_review TEXT NOT NULL DEFAULT 'off',
    \\  push_after_merge TEXT NOT NULL DEFAULT '',
    \\  repo INTEGER NOT NULL DEFAULT 1,
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
    \\  todo INTEGER NOT NULL DEFAULT 0,
    \\  link TEXT NOT NULL DEFAULT '',
    \\  due_at INTEGER NOT NULL DEFAULT 0,
    \\  due_time INTEGER NOT NULL DEFAULT 0,
    \\  remind_at INTEGER NOT NULL DEFAULT 0,
    \\  onto TEXT NOT NULL DEFAULT '',
    \\  pr_then TEXT NOT NULL DEFAULT '',
    \\  pr_url TEXT NOT NULL DEFAULT '',
    \\  pr_stage TEXT NOT NULL DEFAULT '',
    \\  pr_seen INTEGER NOT NULL DEFAULT 0,
    \\  pr_seen_sha TEXT NOT NULL DEFAULT '',
    \\  back_to TEXT NOT NULL DEFAULT '',
    \\  overview_last TEXT NOT NULL DEFAULT '',
    \\  overview_next TEXT NOT NULL DEFAULT '',
    \\  overview_at INTEGER NOT NULL DEFAULT 0,
    \\  verified TEXT NOT NULL DEFAULT '',
    \\  demo TEXT NOT NULL DEFAULT '',
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

const version = 13;

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
    \\  result TEXT NOT NULL DEFAULT '',
    \\  pr TEXT NOT NULL DEFAULT '',
    \\  review INTEGER NOT NULL DEFAULT 0
    \\);
;

/// The last test rebase of each open ticket's change onto its target
/// (drift.zig): `key` is what was tested (the target's commit, the change's
/// parent and tip), so it is tested again only when one of them moves;
/// `files` the files that would conflict, "" for none. Made whatever the
/// version says, as the columns above are.
const drift_schema =
    \\CREATE TABLE IF NOT EXISTS drift (
    \\  ticket INTEGER PRIMARY KEY REFERENCES tickets(id) ON DELETE CASCADE,
    \\  key TEXT NOT NULL,
    \\  files TEXT NOT NULL DEFAULT '',
    \\  onto TEXT NOT NULL DEFAULT '',
    \\  at INTEGER NOT NULL
    \\);
;

/// The dispatcher looks for todos that are due or have a reminder each
/// pass (reminders.zig): only the few with a date. Made whatever the version
/// says, as the columns above are.
const dates_schema =
    \\CREATE INDEX IF NOT EXISTS tickets_due ON tickets(due_at) WHERE due_at != 0;
    \\CREATE INDEX IF NOT EXISTS tickets_remind ON tickets(remind_at) WHERE remind_at != 0;
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
        _ = try addColumn(db, "projects", "auto_review", "TEXT NOT NULL DEFAULT 'off'");
        // Parks on a PR, and the steps for after one merges.
        _ = try addColumn(db, "parks", "pr", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "pr_then", "TEXT NOT NULL DEFAULT ''");
        // Early warnings of conflicts with trunk.
        try db.execMulti(drift_schema);
        // Pushing trunk after a merge.
        _ = try addColumn(db, "projects", "push_after_merge", "TEXT NOT NULL DEFAULT ''");
        // Projects that aren't code repos.
        _ = try addColumn(db, "projects", "repo", "INTEGER NOT NULL DEFAULT 1");
        // Version 12: todos, and where a ticket came from.
        _ = try addColumn(db, "tickets", "todo", "INTEGER NOT NULL DEFAULT 0");
        _ = try addColumn(db, "tickets", "link", "TEXT NOT NULL DEFAULT ''");
        // Version 13: todos' due dates and reminders.
        _ = try addColumn(db, "tickets", "due_at", "INTEGER NOT NULL DEFAULT 0");
        _ = try addColumn(db, "tickets", "due_time", "INTEGER NOT NULL DEFAULT 0");
        _ = try addColumn(db, "tickets", "remind_at", "INTEGER NOT NULL DEFAULT 0");
        try db.execMulti(dates_schema);
        // The Overview tab's lines.
        _ = try addColumn(db, "tickets", "overview_last", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "overview_next", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "overview_at", "INTEGER NOT NULL DEFAULT 0");
        // Tickets finished with a PR wait on it parked, woken by its feedback.
        _ = try addColumn(db, "tickets", "pr_url", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "pr_stage", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "pr_seen", "INTEGER NOT NULL DEFAULT 0");
        _ = try addColumn(db, "tickets", "pr_seen_sha", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "parks", "review", "INTEGER NOT NULL DEFAULT 0");
        // The handoff's other two parts, next to the test plan.
        _ = try addColumn(db, "tickets", "verified", "TEXT NOT NULL DEFAULT ''");
        _ = try addColumn(db, "tickets", "demo", "TEXT NOT NULL DEFAULT ''");
        // CL-168 reversed Review and Testing (test first, review last). The
        // column comes with a one-time swap of the open tickets, so nobody
        // changes position in the flow: see `reverse_stages`.
        if (!try hasBackTo(db)) try reverseStages(db);
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
    try db.execMulti(drift_schema);
    try db.execMulti(dates_schema);
    try db.execMulti(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{version}));
}

fn hasBackTo(db: Db) !bool {
    return (try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'back_to'", .{})) != null;
}

/// The one-time migration that came with `Ticket.back_to` (CL-168): the
/// order went from Running, Review, Testing to Running, Testing, Review, so
/// a ticket in Review goes to Testing and one in Testing to Review, and
/// their open stage flags are renamed to match (a Planning ticket's plan
/// flag isn't touched), as is the stage a ticket waits on its PR in
/// (`pr_stage`). One write transaction, column and all, with the column
/// checked again inside it: two cl processes starting at once (cl web, a
/// hook) don't both run it, and a failure rolls it all back. Running the
/// stage and pr_stage UPDATEs again by hand undoes it.
fn reverseStages(db: Db) !void {
    try db.execMulti("BEGIN IMMEDIATE");
    errdefer db.execMulti("ROLLBACK") catch {};
    if (!try hasBackTo(db)) try db.execMulti(reverse_stages);
    try db.execMulti("COMMIT");
}

/// `reverseStages`' SQL. A ticket can have both stage flags open (a PR
/// feedback round, or one set by hand): one is kept (the oldest) before the
/// rename, since open flags are unique per kind (`flags_active`).
const reverse_stages =
    \\ALTER TABLE tickets ADD COLUMN back_to TEXT NOT NULL DEFAULT '';
    \\UPDATE flags SET cleared = CAST(strftime('%s', 'now') AS INTEGER)
    \\  WHERE cleared IS NULL AND kind IN ('review', 'testing')
    \\  AND ticket IN (SELECT id FROM tickets WHERE stage IN ('review', 'testing'))
    \\  AND id NOT IN (SELECT min(f.id) FROM flags f JOIN tickets t ON t.id = f.ticket
    \\    WHERE f.cleared IS NULL AND f.kind IN ('review', 'testing') AND t.stage IN ('review', 'testing') GROUP BY f.ticket);
    \\UPDATE tickets SET stage = CASE stage WHEN 'review' THEN 'testing' ELSE 'review' END WHERE stage IN ('review', 'testing');
    \\UPDATE tickets SET pr_stage = CASE pr_stage WHEN 'review' THEN 'testing' ELSE 'review' END WHERE pr_stage IN ('review', 'testing') AND stage != 'done';
    \\UPDATE flags SET kind = (SELECT t.stage FROM tickets t WHERE t.id = flags.ticket)
    \\  WHERE cleared IS NULL AND kind IN ('review', 'testing') AND NOT (kind = 'review' AND detail = 'plan')
    \\  AND ticket IN (SELECT id FROM tickets WHERE stage IN ('review', 'testing'));
    \\INSERT INTO events (ticket, kind, detail, at)
    \\  SELECT id, 'moved', CASE stage WHEN 'testing' THEN 'review -> testing' ELSE 'testing -> review' END || ' (stages reversed, CL-168)', CAST(strftime('%s', 'now') AS INTEGER)
    \\  FROM tickets WHERE stage IN ('review', 'testing');
;

/// Add a column unless the table has it; true when it was added.
fn addColumn(db: Db, comptime table: []const u8, comptime column: []const u8, comptime decl: []const u8) !bool {
    if ((try db.int("SELECT 1 FROM pragma_table_info('" ++ table ++ "') WHERE name = '" ++ column ++ "'", .{})) != null) return false;
    try db.execMulti("ALTER TABLE " ++ table ++ " ADD COLUMN " ++ column ++ " " ++ decl);
    return true;
}

test "an approved plan queues, and the plan is kept" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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

test "overview: Claude's lines, and done puts its summary in Last and clears Next" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Build it" });
    const id = (try getTicket(db, a, k)).id;
    try setOverview(ctx, db, id, "In progress: the schema", "The CLI");
    const at = (try getTicket(db, a, k)).overview_at;
    try std.testing.expect(at > 0);
    // Only what's given changes, and only a new Last moves its date.
    try db.exec("UPDATE tickets SET overview_at = 1 WHERE id = ?1", .{id});
    try setOverview(ctx, db, id, null, "The tab");
    var t = try getTicket(db, a, k);
    try std.testing.expectEqual(@as(i64, 1), t.overview_at);
    try std.testing.expectEqualStrings("In progress: the schema", t.overview_last);
    try std.testing.expectEqualStrings("The tab", t.overview_next);
    try done(ctx, db, a, k, "Added the tab");
    t = try getTicket(db, a, k);
    try std.testing.expectEqualStrings("Added the tab", t.overview_last);
    try std.testing.expectEqualStrings("", t.overview_next);
    // Done without a summary keeps the last line.
    try setOverview(ctx, db, id, null, "Tests");
    try done(ctx, db, a, k, "");
    t = try getTicket(db, a, k);
    try std.testing.expectEqualStrings("Added the tab", t.overview_last);
    try std.testing.expectEqualStrings("", t.overview_next);
}

test "migrate: a board from before the Overview gets its columns" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try db.execMulti("ALTER TABLE tickets DROP COLUMN overview_last; ALTER TABLE tickets DROP COLUMN overview_next; ALTER TABLE tickets DROP COLUMN overview_at");
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'overview_at'", .{})) != null);
}

test "feedback on a ready plan keeps it ready to approve" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    try db.execMulti("ALTER TABLE tickets DROP COLUMN autoreview; ALTER TABLE projects DROP COLUMN review_skill; ALTER TABLE projects DROP COLUMN auto_review");
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'auto_review'", .{})) != null);
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
    try db.execMulti(std.fmt.comptimePrint("ALTER TABLE tickets DROP COLUMN test_plan; ALTER TABLE tickets DROP COLUMN test_progress; ALTER TABLE tickets DROP COLUMN verified; ALTER TABLE tickets DROP COLUMN demo; ALTER TABLE projects DROP COLUMN after_merge; PRAGMA user_version = {d}", .{version}));
    try migrate(db);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'test_progress'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'test_plan'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'verified'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = 'demo'", .{})) != null);
    try std.testing.expect((try db.int("SELECT 1 FROM pragma_table_info('projects') WHERE name = 'after_merge'", .{})) != null);
    try std.testing.expectEqual(@as(?i64, version), try db.int("PRAGMA user_version", .{}));
}

test "migrate: the stages reversed (CL-168) swap open tickets' Review and Testing once, flags and all" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    // A board from before: no back_to, tickets in the old order's stages.
    const rv = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Reviewed next", .stage = .running });
    const ts = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Tested next", .stage = .running });
    const pl = try createTicket(ctx, db, a, .{ .project = "qa", .title = "A plan", .plan = true });
    const rn = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Running", .stage = .running });
    const rv_id = (try getTicket(db, a, rv)).id;
    const ts_id = (try getTicket(db, a, ts)).id;
    const pl_id = (try getTicket(db, a, pl)).id;
    try db.execMulti("ALTER TABLE tickets DROP COLUMN back_to");
    try db.exec("UPDATE tickets SET stage = 'review' WHERE id = ?1", .{rv_id});
    try db.exec("INSERT INTO flags (ticket, kind, source, detail, at) VALUES (?1, 'review', 'auto', '', 1)", .{rv_id});
    try db.exec("UPDATE tickets SET stage = 'testing', pr_url = 'https://github.com/o/r/pull/1', pr_stage = 'testing' WHERE id = ?1", .{ts_id});
    try db.exec("INSERT INTO flags (ticket, kind, source, detail, at) VALUES (?1, 'testing', 'auto', '', 1)", .{ts_id});
    // Both stage flags open (a PR feedback round left them): one stays.
    try db.exec("INSERT INTO flags (ticket, kind, source, detail, at) VALUES (?1, 'review', 'auto', '', 2)", .{ts_id});
    try db.exec("INSERT INTO flags (ticket, kind, source, detail, at) VALUES (?1, 'review', 'auto', 'plan', 1)", .{pl_id});
    try migrate(db);
    // Nobody changes position: the old Review is the new Testing.
    var t = try getTicket(db, a, rv);
    try std.testing.expectEqual(Stage.testing, t.stage);
    try std.testing.expectEqual(@as(usize, 1), t.flags.len);
    try std.testing.expectEqualStrings(flag_testing, t.flags[0].kind);
    t = try getTicket(db, a, ts);
    try std.testing.expectEqual(Stage.review, t.stage);
    // Waiting on its PR there: it waits in Review now.
    try std.testing.expectEqual(Stage.review, prStage(t).?);
    try std.testing.expectEqualStrings(flag_review, t.flags[0].kind);
    try std.testing.expectEqual(@as(usize, 1), t.flags.len);
    var logged = false;
    for (try events(db, a, t.id)) |e| logged = logged or std.mem.indexOf(u8, e.detail, "stages reversed") != null;
    try std.testing.expect(logged);
    // The plan's flag and Running are untouched.
    t = try getTicket(db, a, pl);
    try std.testing.expectEqual(Stage.planning, t.stage);
    try std.testing.expectEqualStrings(flag_review, t.flags[0].kind);
    try std.testing.expectEqualStrings("plan", t.flags[0].detail);
    try std.testing.expectEqual(Stage.running, (try getTicket(db, a, rn)).stage);
    // Once: migrating again swaps nothing back.
    try migrate(db);
    try std.testing.expectEqual(Stage.testing, (try getTicket(db, a, rv)).stage);
    try std.testing.expectEqual(Stage.review, (try getTicket(db, a, ts)).stage);
}

test "done: to Testing with a test plan, Review without; a round sent back returns where it came from; approve goes Testing, Review, Done" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "T", .stage = .running });
    const id = (try getTicket(db, a, k)).id;
    const only = struct {
        fn flag(d: Db, al: std.mem.Allocator, key: []const u8, stage: Stage, kind: []const u8) !void {
            const t = try getTicket(d, al, key);
            try std.testing.expectEqual(stage, t.stage);
            try std.testing.expectEqual(@as(usize, 1), t.flags.len);
            try std.testing.expectEqualStrings(kind, t.flags[0].kind);
        }
    }.flag;
    // Nothing to test: straight to Review.
    try done(ctx, db, a, k, "Done");
    try only(db, a, k, .review, flag_review);
    // Done again while there: it stays, flag and all.
    try done(ctx, db, a, k, "Done again");
    try only(db, a, k, .review, flag_review);
    // Sent back from Review: done returns it to Review, even with a test plan now.
    _ = try addComment(ctx, db, a, k, "you", "Rename it", true);
    try std.testing.expectEqualStrings("review", (try getTicket(db, a, k)).back_to);
    try setHandoff(ctx, db, id, "", "- [ ] it works", "");
    try done(ctx, db, a, k, "Renamed");
    try only(db, a, k, .review, flag_review);
    try std.testing.expectEqualStrings("", (try getTicket(db, a, k)).back_to);
    // A Verified list alone is something to test too ("Try it").
    const kv = try createTicket(ctx, db, a, .{ .project = "qa", .title = "V", .stage = .running });
    try setHandoff(ctx, db, (try getTicket(db, a, kv)).id, "- ran it", "", "");
    try done(ctx, db, a, kv, "Done");
    try only(db, a, kv, .testing, flag_testing);
    // Moved back to Running by hand from Testing: done returns to Testing.
    try move(ctx, db, a, k, .testing);
    try only(db, a, k, .testing, flag_testing);
    _ = try addComment(ctx, db, a, k, "you", "Step 2 fails", true);
    try std.testing.expectEqual(Stage.running, (try getTicket(db, a, k)).stage);
    try done(ctx, db, a, k, "Fixed step 2");
    try only(db, a, k, .testing, flag_testing);
    // Approve: Testing to Review (its flag), Review to Done.
    try std.testing.expectEqual(Stage.testing, try approve(ctx, db, a, k));
    try only(db, a, k, .review, flag_review);
    try std.testing.expectEqual(Stage.review, try approve(ctx, db, a, k));
    try std.testing.expectEqual(Stage.done, (try getTicket(db, a, k)).stage);
    // A fresh ticket with a test plan goes to Testing first; sent back from
    // Testing without one any more, there's nothing to test: Review.
    const k2 = try createTicket(ctx, db, a, .{ .project = "qa", .title = "U", .stage = .running });
    const id2 = (try getTicket(db, a, k2)).id;
    try setHandoff(ctx, db, id2, "", "- [ ] it works", "");
    try done(ctx, db, a, k2, "Done");
    try only(db, a, k2, .testing, flag_testing);
    _ = try addComment(ctx, db, a, k2, "you", "No, redo it", true);
    try setHandoff(ctx, db, id2, "", "", "");
    try done(ctx, db, a, k2, "Redone");
    try only(db, a, k2, .review, flag_review);
    // Queued again, where it was sent back from no longer counts.
    _ = try addComment(ctx, db, a, k2, "you", "Again", true);
    try move(ctx, db, a, k2, .queued);
    try std.testing.expectEqualStrings("", (try getTicket(db, a, k2)).back_to);
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
    auto_review: ?AutoReview = null,
    push_after_merge: ?[]const u8 = null,
    repo: ?bool = null,
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

/// A git remote's name as cl passes it to git: one word, not an option
/// (`--upload-pack=...` would be read as one). "" is none.
fn validRemote(r: []const u8) bool {
    if (r.len == 0) return true;
    if (r[0] == '-') return false;
    for (r) |ch| if (std.ascii.isWhitespace(ch) or ch < 0x20) return false;
    return true;
}

test validRemote {
    try std.testing.expect(validRemote(""));
    try std.testing.expect(validRemote("origin"));
    try std.testing.expect(!validRemote("--upload-pack=x"));
    try std.testing.expect(!validRemote("-origin"));
    try std.testing.expect(!validRemote("origin main"));
}

/// What `addProject` would refuse, without adding it: callers that make the
/// directory first (`--no-repo`) check before they do. `in.dir` may be left
/// "" here.
pub fn checkNewProject(db: Db, in: ProjectInput) Error!void {
    if (in.name.len == 0) return error.BadInput;
    if (in.push_after_merge) |r| if (!validRemote(r)) return error.BadInput;
    var buf: [8]u8 = undefined;
    const prefix = in.prefix orelse defaultPrefix(&buf, in.name);
    if (!validPrefix(prefix)) return error.BadInput;
    if (!(in.repo orelse true) and repoOnly(in)) return error.NoRepo;
    if (try db.int("SELECT 1 FROM projects WHERE name = ?1 OR prefix = ?2", .{ in.name, prefix }) != null) return error.Exists;
}

/// `in` asks for something only a code repo has.
fn repoOnly(in: ProjectInput) bool {
    const set = struct {
        fn f(v: ?[]const u8) bool {
            return if (v) |x| x.len > 0 else false;
        }
    }.f;
    return in.mode == .worktree or (in.auto_review orelse .off) != .off or set(in.onto) or set(in.push_after_merge) or set(in.after_merge);
}

/// What a new project reviews by itself when it isn't told: a code repo runs
/// the automated review and sends its findings to Claude for one round; a
/// repo-less project has no automated review. Only new projects: the
/// `auto_review` column's DEFAULT stays 'off' so a migration never turns it on
/// for a project that's already there.
pub fn defaultAutoReview(repo: bool) AutoReview {
    return if (repo) .send else .off;
}

pub fn addProject(db: Db, in: ProjectInput) Error!void {
    if (in.dir.len == 0) return error.BadInput;
    try checkNewProject(db, in);
    var buf: [8]u8 = undefined;
    const prefix = in.prefix orelse defaultPrefix(&buf, in.name);
    try db.exec("INSERT INTO projects (name, dir, prefix, slots, mode, profile, after_merge, after_merge_claude, planners, onto, review_skill, auto_review, push_after_merge, repo) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)", .{
        in.name,                             in.dir,               prefix,                    in.slots orelse default_slots,
        @tagName(in.mode orelse .queue),     in.profile orelse "", in.after_merge orelse "",  in.after_merge_claude orelse "",
        in.planners orelse default_planners, in.onto orelse "",    in.review_skill orelse "", @tagName(in.auto_review orelse defaultAutoReview(in.repo orelse true)),
        in.push_after_merge orelse "",       in.repo orelse true,
    });
}

/// Change the given fields of a project. Everything is checked before
/// anything is written, so a refused change changes nothing.
/// Making it repo-less (`repo` false) sets its mode to queue and clears what
/// only a code repo has (automated reviews, target branch, push and
/// after-merge command); asking for any of them along with that, or of a
/// repo-less project, is refused (`error.NoRepo`), and so is making it
/// repo-less while its unfinished tickets have work in the repo
/// (`error.RepoWork`).
pub fn updateProject(db: Db, name: []const u8, in: ProjectInput) Error!void {
    const repo = (try db.int("SELECT repo FROM projects WHERE name = ?1", .{name})) orelse return error.NotFound;
    if (in.push_after_merge) |r| if (!validRemote(r)) return error.BadInput;
    if (!(in.repo orelse (repo != 0)) and repoOnly(in)) return error.NoRepo;
    if (in.repo == false and repo != 0 and try db.int(
        "SELECT 1 FROM tickets WHERE project = ?1 AND stage != 'done' AND (mode = 'worktree' OR worktree != '' OR branch != '' OR change_id != '')",
        .{name},
    ) != null) return error.RepoWork;
    if (in.prefix) |p| {
        if (!validPrefix(p)) return error.BadInput;
        if (try db.int("SELECT 1 FROM projects WHERE prefix = ?1 AND name != ?2", .{ p, name }) != null) return error.Exists;
    }
    if (in.name.len > 0 and !std.mem.eql(u8, in.name, name)) {
        if (try db.int("SELECT 1 FROM projects WHERE name = ?1", .{in.name}) != null) return error.Exists;
    }
    if (in.repo) |r| {
        try db.exec("UPDATE projects SET repo = ?2 WHERE name = ?1", .{ name, r });
        if (!r) try db.exec("UPDATE projects SET mode = 'queue', auto_review = 'off', onto = '', push_after_merge = '', after_merge = '' WHERE name = ?1", .{name});
    }
    if (in.prefix) |p| try db.exec("UPDATE projects SET prefix = ?2 WHERE name = ?1", .{ name, p });
    if (in.dir.len > 0) try db.exec("UPDATE projects SET dir = ?2 WHERE name = ?1", .{ name, in.dir });
    if (in.slots) |s| try db.exec("UPDATE projects SET slots = ?2 WHERE name = ?1", .{ name, s });
    if (in.planners) |n| try db.exec("UPDATE projects SET planners = ?2 WHERE name = ?1", .{ name, n });
    if (in.mode) |m| try db.exec("UPDATE projects SET mode = ?2 WHERE name = ?1", .{ name, @tagName(m) });
    if (in.profile) |p| try db.exec("UPDATE projects SET profile = ?2 WHERE name = ?1", .{ name, p });
    if (in.after_merge) |c| try db.exec("UPDATE projects SET after_merge = ?2 WHERE name = ?1", .{ name, c });
    if (in.after_merge_claude) |c| try db.exec("UPDATE projects SET after_merge_claude = ?2 WHERE name = ?1", .{ name, c });
    if (in.onto) |o| try db.exec("UPDATE projects SET onto = ?2 WHERE name = ?1", .{ name, o });
    if (in.review_skill) |k| try db.exec("UPDATE projects SET review_skill = ?2 WHERE name = ?1", .{ name, k });
    if (in.auto_review) |r| try db.exec("UPDATE projects SET auto_review = ?2 WHERE name = ?1", .{ name, @tagName(r) });
    if (in.push_after_merge) |r| try db.exec("UPDATE projects SET push_after_merge = ?2 WHERE name = ?1", .{ name, r });
    // Renaming last, so the lookups above still match.
    if (in.name.len > 0 and !std.mem.eql(u8, in.name, name)) {
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

const project_cols = "name, dir, prefix, slots, mode, profile, after_merge, after_merge_claude, hidden, planners, paused, onto, review_skill, auto_review, push_after_merge, repo";

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
        .auto_review = AutoReview.parse(st.text(13)) orelse .off,
        .push_after_merge = try st.dupe(a, 14),
        .repo = st.int(15) != 0,
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
    /// A todo (see `Ticket.todo`).
    todo: ?bool = null,
    /// Where it came from (`Ticket.link`).
    link: ?[]const u8 = null,
    /// createTicket: a sub-ticket that doesn't wait for the one before it;
    /// null for the default (parallel under a todo, in order otherwise).
    /// Changed later with `setParallel`.
    parallel: ?bool = null,
    /// A todo's due date (`Ticket.due_at`, `due_time`); `.{}` clears it.
    due: ?when.When = null,
    /// A todo's next reminder (`Ticket.remind_at`); 0 clears it.
    remind: ?i64 = null,
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
    if (!p.repo and (in.mode == .worktree or (in.onto orelse @as([]const u8, "")).len > 0)) return error.NoRepo;
    const plan = in.plan orelse false;
    const stage = in.stage orelse (if (plan) Stage.planning else Stage.backlog);
    const todo = in.todo orelse false;
    if (todo and (plan or in.umbrella == true or !todoStage(stage))) return error.Todo;
    if (!validLink(in.link orelse "")) return error.BadInput;
    // Dates are for todos: nothing else waits on the human that way.
    const due = in.due orelse when.When{};
    const remind = in.remind orelse 0;
    if (!todo and (due.at != 0 or remind != 0)) return error.BadInput;
    // A Claude task for a todo goes on its own: it neither waits on the todo
    // (see `blockers`) nor on the tasks before it.
    const parallel = in.parallel orelse if (parent) |pt| pt.todo else false;
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
        \\INSERT INTO tickets (key, project, title, body, stage, mode, plan, target, profile, parent, skill, created, updated, rank, umbrella, onto, todo, link, parallel, due_at, due_time, remind_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12, (SELECT coalesce(max(rank), 0) + ?13 FROM tickets), ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
    , .{ key, p.name, title, body, @tagName(stage), @tagName(in.mode orelse p.mode), plan, in.target orelse "", in.profile orelse p.profile, if (parent) |pt| pt.id else null, in.skill orelse "", t, rank_gap, in.umbrella orelse false, if (!p.repo) @as([]const u8, "") else in.onto orelse if (parent) |pt| pt.onto_own else "", todo, std.mem.trim(u8, in.link orelse "", " \t\r\n"), parallel, due.at, due.at != 0 and due.has_time, remind });
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
    "t.onto, coalesce((SELECT p.onto FROM projects p WHERE p.name = t.project), ''), t.autoreview, t.pr_then, " ++
    "coalesce((SELECT p.repo FROM projects p WHERE p.name = t.project), 1), t.todo, t.link, t.due_at, t.due_time, t.remind_at, t.overview_last, t.overview_next, t.overview_at, " ++
    "t.pr_url, t.pr_stage, t.pr_seen, t.pr_seen_sha, t.verified, t.demo, t.back_to";

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
        .pr_then = try st.dupe(a, 39),
        .repo = st.int(40) != 0,
        .todo = st.int(41) != 0,
        .link = try st.dupe(a, 42),
        .due_at = st.int(43),
        .due_time = st.int(44) != 0,
        .remind_at = st.int(45),
        .overview_last = try st.dupe(a, 46),
        .overview_next = try st.dupe(a, 47),
        .overview_at = st.int(48),
        .pr_url = try st.dupe(a, 49),
        .pr_stage = try st.dupe(a, 50),
        .pr_seen = st.int(51),
        .pr_seen_sha = try st.dupe(a, 52),
        .verified = try st.dupe(a, 53),
        .demo = try st.dupe(a, 54),
        .back_to = try st.dupe(a, 55),
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
    t.drift = try driftOf(db, a, t.id);
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
    /// Only todos (true), or no todos (false).
    todo: ?bool = null,
    /// Only todos with a due date, the soonest first.
    due: bool = false,
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
    if (f.todo) |v| try sql.appendSlice(a, if (v) " AND t.todo != 0" else " AND t.todo = 0");
    if (f.due) try sql.appendSlice(a, " AND t.todo != 0 AND t.due_at != 0");
    // Parked: it waits on something outside cl, not on you. Only a todo's
    // reminder or due date still asks then (`todayFlag`).
    if (f.needs) try sql.appendSlice(a, if (f.hidden)
        " AND EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL AND (g.kind IN ('" ++ flag_reminder ++ "', '" ++ flag_due ++ "') OR NOT EXISTS (SELECT 1 FROM parks k WHERE k.ticket = t.id)))" ++
            " AND NOT EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL AND g.hidden = 0)" ++
            // Snoozed (a todo with a reminder still to come): not hidden, it comes back by itself then.
            " AND NOT (t.todo != 0 AND t.remind_at != 0)"
    else
        " AND EXISTS (SELECT 1 FROM flags g WHERE g.ticket = t.id AND g.cleared IS NULL AND g.hidden = 0 AND (g.kind IN ('" ++ flag_reminder ++ "', '" ++ flag_due ++ "') OR NOT EXISTS (SELECT 1 FROM parks k WHERE k.ticket = t.id)))");
    const fts = if (f.search) |q| try ftsQuery(a, q) else "";
    if (fts.len > 0) try sql.appendSlice(a,
        \\ AND (t.id IN (SELECT rowid FROM tickets_fts WHERE tickets_fts MATCH ?4)
        \\  OR t.id IN (SELECT c.ticket FROM comments c JOIN comments_fts s ON s.rowid = c.id WHERE comments_fts MATCH ?4))
    );
    if (f.due) {
        try sql.appendSlice(a, " ORDER BY t.due_at, t.id");
    } else if (f.needs) {
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
        t.drift = try driftOf(db, a, t.id);
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
    // Where it will be: moving to another project goes by that one's repo.
    const moving = in.project.len > 0 and !std.mem.eql(u8, in.project, t.project);
    const repo = if (moving) (try getProject(db, a, in.project)).repo else t.repo;
    if (in.title) |v| if (v.len == 0) return error.BadInput;
    // A todo is the human's: never planned, never an umbrella, never further
    // along than Running.
    const todo = in.todo orelse t.todo;
    if (todo and ((in.plan orelse t.plan) or (in.umbrella orelse t.umbrella) or !todoStage(t.stage))) return error.Todo;
    // Claude's work under way (a session, a worktree, a change) can't become
    // yours: nothing would finish it.
    if (todo and !t.todo and t.stage != .done and (t.tmux.len > 0 or t.worktree.len > 0 or t.change.len > 0 or t.branch.len > 0)) return error.Todo;
    if (!validLink(in.link orelse "")) return error.BadInput;
    // Dates are for todos (see createTicket).
    if (!todo and ((in.due orelse when.When{}).at != 0 or (in.remind orelse 0) != 0)) return error.BadInput;
    if (!repo) {
        if (in.mode == .worktree or (in.onto orelse @as([]const u8, "")).len > 0) return error.NoRepo;
        // Into a repo-less project: work it has in a repo would be left
        // behind; with none, it goes to the queue, with no target branch.
        if (moving and t.repo) {
            if (t.stage != .done and (t.worktree.len > 0 or t.branch.len > 0 or t.change.len > 0)) return error.RepoWork;
            try db.exec("UPDATE tickets SET mode = 'queue', onto = '' WHERE id = ?1", .{t.id});
        }
    }
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
    if (in.todo) |v| try db.exec("UPDATE tickets SET todo = ?2 WHERE id = ?1", .{ t.id, v });
    // Made a todo: its unfinished sub-tickets become its tasks, which don't
    // wait on one another (as new ones under it don't: see createTicket).
    if (in.todo == true and !t.todo) try db.exec("UPDATE tickets SET parallel = 1 WHERE parent = ?1 AND stage != 'done'", .{t.id});
    if (in.link) |v| try db.exec("UPDATE tickets SET link = ?2 WHERE id = ?1", .{ t.id, std.mem.trim(u8, v, " \t\r\n") });
    // A new due date: `due` goes, and the dispatcher raises it again if the
    // new one is due too (a later one clears it).
    if (in.due) |d| if (d.at != t.due_at or (d.at != 0 and d.has_time != t.due_time)) {
        try db.exec("UPDATE tickets SET due_at = ?2, due_time = ?3 WHERE id = ?1", .{ t.id, d.at, d.at != 0 and d.has_time });
        try clearFlagId(ctx, db, t.id, flag_due);
    };
    if (in.remind) |r| if (r != t.remind_at) try setRemind(ctx, db, t.id, r);
    // No longer a todo: no dates either.
    if (in.todo == false and t.todo) {
        try db.exec("UPDATE tickets SET due_at = 0, due_time = 0, remind_at = 0 WHERE id = ?1", .{t.id});
        try clearFlagId(ctx, db, t.id, flag_due);
        try clearFlagId(ctx, db, t.id, flag_reminder);
    }
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

/// Keep the handoff Claude gave for the ticket: what it verified, the test
/// plan and the demo. Testing it starts over.
pub fn setHandoff(ctx: Ctx, db: Db, id: i64, verified: []const u8, test_plan: []const u8, demo: []const u8) Error!void {
    try db.exec("UPDATE tickets SET verified = ?2, test_plan = ?3, demo = ?4, test_progress = '' WHERE id = ?1", .{ id, verified, test_plan, demo });
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
/// its stage's flag (Ready to test, or Ready for review), raised again or
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
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
/// Planning (approving starts a fresh session, or for an umbrella, it is
/// what you approve), or in Backlog or Queued with no conversation to resume
/// (a resumed one is only told it's back on). Never an umbrella's past
/// Planning: no session builds it, its sub-tickets run.
pub fn planEditable(t: Ticket) bool {
    return t.stage == .planning or (!t.umbrella and (t.stage == .backlog or t.stage == .queued) and t.session_id.len == 0);
}

/// `planEditable` as SQL on the tickets table.
const plan_editable_sql = "(stage = 'planning' OR (umbrella = 0 AND stage IN ('backlog', 'queued') AND session_id = ''))";

/// Where a ticket that plans first stands, for `show`, the terminal board and
/// (as planFact in board.html) the web board.
pub const PlanState = enum {
    /// It doesn't plan first, or it left Planning without a plan.
    none,
    /// Planning, or in Backlog before it was planned.
    plan_first,
    /// Past Planning with the plan it handed in.
    planned,
    /// The same, an umbrella: the plan became its sub-tickets.
    planned_umbrella,
};

pub fn planState(t: Ticket) PlanState {
    if (!t.plan) return .none;
    if (t.stage == .planning) return .plan_first;
    if (std.mem.trim(u8, t.plan_md, " \t\r\n").len > 0) return if (t.umbrella) .planned_umbrella else .planned;
    return if (t.stage == .backlog) .plan_first else .none;
}

test editPlan {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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
    // An umbrella's plan is editable while it waits for approval, not after:
    // nothing reads it then.
    const ku = try createTicket(ctx, db, a, .{ .project = "qa", .title = "U", .plan = true, .umbrella = true });
    try editPlan(ctx, db, a, ku, "## Tickets\n", "");
    try move(ctx, db, a, ku, .queued);
    try std.testing.expectError(error.PlanStarted, editPlan(ctx, db, a, ku, "x", "## Tickets\n"));
}

test planState {
    var t: Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Ideate", .body = "", .stage = .planning,
        .mode = .queue, .plan = true, .skill = "", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0,
    };
    try std.testing.expectEqual(PlanState.plan_first, planState(t));
    t.umbrella = true;
    t.plan_md = "## Sub-tickets\n";
    try std.testing.expectEqual(PlanState.plan_first, planState(t));
    t.stage = .running;
    try std.testing.expectEqual(PlanState.planned_umbrella, planState(t));
    t.umbrella = false;
    try std.testing.expectEqual(PlanState.planned, planState(t));
    t.stage = .backlog;
    try std.testing.expectEqual(PlanState.planned, planState(t));
    // Shelved before it was planned: it still plans first.
    t.plan_md = "";
    try std.testing.expectEqual(PlanState.plan_first, planState(t));
    // Moved on by hand without a plan: neither planned nor planning.
    t.stage = .queued;
    try std.testing.expectEqual(PlanState.none, planState(t));
    t.plan = false;
    t.stage = .planning;
    try std.testing.expectEqual(PlanState.none, planState(t));
}

/// Save how far testing got (left out of `updated`: it changes as you type).
/// What to do once its PR merges (see Ticket.pr_then); "" clears it.
pub fn setPrThen(ctx: Ctx, db: Db, id: i64, text: []const u8) Error!void {
    try db.exec("UPDATE tickets SET pr_then = ?2 WHERE id = ?1", .{ id, text });
    try logEvent(ctx, db, id, if (text.len > 0) "after the PR" else "after the PR cleared", text);
    try touch(ctx, db, id);
}

/// The Overview tab's lines (see Ticket.overview_last): each one given
/// replaces what was there ("" clears it); null leaves it. `overview_at`
/// dates Last (the board shows it beside it), so only a new Last moves it.
/// Not `touch`ed: Claude sets them as it goes, and that isn't news for the
/// board's order.
pub fn setOverview(ctx: Ctx, db: Db, id: i64, last: ?[]const u8, next: ?[]const u8) Error!void {
    try db.exec(
        \\UPDATE tickets SET overview_last = coalesce(?2, overview_last), overview_next = coalesce(?3, overview_next),
        \\  overview_at = CASE WHEN ?2 IS NULL THEN overview_at ELSE ?4 END WHERE id = ?1
    , .{ id, last, next, now(ctx) });
}

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
    // Foreign keys aren't enforced, and a new ticket may get its id back.
    try db.exec("DELETE FROM parks WHERE ticket = ?1", .{t.id});
    try db.exec("DELETE FROM drift WHERE ticket = ?1", .{t.id});
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
        var st = try db.query("SELECT p.id, p.key, p.title, p.stage FROM tickets t JOIN tickets p ON p.id = t.parent WHERE t.id = ?1 AND p.umbrella = 0 AND p.todo = 0", .{id});
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
    /// A todo: it's the human's, so nothing starts it by itself.
    todo,
};

pub fn hold(t: Ticket) ?Hold {
    if (t.umbrella) return .subtickets;
    if (t.todo) return .todo;
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
        \\SELECT id FROM tickets c WHERE c.parent = ?1 AND c.stage = ?2 AND c.tmux = '' AND c.todo = 0
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
///   left, so the human decides;
/// - a todo gets nothing: it is the human's, and closes when they say so.
fn subticketsSettled(ctx: Ctx, db: Db, pid: i64) Error!void {
    if ((try db.int("SELECT 1 FROM tickets WHERE id = ?1 AND todo != 0", .{pid})) != null) return;
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

/// Whether the ticket's log has an event of `kind`.
pub fn hasEvent(db: Db, id: i64, kind: []const u8) Error!bool {
    return (try db.int("SELECT 1 FROM events WHERE ticket = ?1 AND kind = ?2 LIMIT 1", .{ id, kind })) != null;
}

pub fn logEvent(ctx: Ctx, db: Db, id: i64, kind: []const u8, detail: []const u8) Error!void {
    try db.exec("INSERT INTO events (ticket, kind, detail, at) VALUES (?1, ?2, ?3, ?4)", .{ id, kind, detail, now(ctx) });
}

/// Move a ticket to `stage`. Flags follow the workflow: entering Testing sets
/// `testing`, entering Review sets `review`, leaving Planning, Review or
/// Testing clears its flag, Done clears them all. Sent back from Testing or
/// Review to Running, it remembers where from (`Ticket.back_to`).
/// Any move ends finishing.
pub fn move(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, stage: Stage) Error!void {
    const t = try getTicket(db, a, key);
    if (t.stage == stage) return;
    try moveId(ctx, db, t.id, t.stage, stage);
}

fn moveId(ctx: Ctx, db: Db, id: i64, from: Stage, to: Stage) Error!void {
    if (!todoStage(to) and (try db.int("SELECT 1 FROM tickets WHERE id = ?1 AND todo != 0", .{id})) != null) return error.Todo;
    // Queued again, a killed ticket waits for the dispatcher like any other.
    try db.exec("UPDATE tickets SET stage = ?2, finishing = '', killed = killed AND ?2 != 'queued' WHERE id = ?1", .{ id, @as([]const u8, @tagName(to)) });
    // A round sent back from Testing or Review returns there when Claude is
    // done (`nextAfterDone`); shelved, queued again or Done, that's over.
    if (to == .running and (from == .testing or from == .review))
        try db.exec("UPDATE tickets SET back_to = ?2 WHERE id = ?1", .{ id, @as([]const u8, @tagName(from)) })
    else if (to == .queued or to == .backlog or to == .done)
        try db.exec("UPDATE tickets SET back_to = '' WHERE id = ?1", .{id});
    var buf: [64]u8 = undefined;
    try logEvent(ctx, db, id, "moved", std.fmt.bufPrint(&buf, "{s} -> {s}", .{ @tagName(from), @tagName(to) }) catch "");
    // Out of Planning by any path (approved, queued or shelved by hand), the
    // plan is no longer waiting for review: its `review` (detail "plan") goes.
    if (from == .review or from == .planning) try clearFlagId(ctx, db, id, flag_review);
    if (from == .testing) try clearFlagId(ctx, db, id, flag_testing);
    // Moved, it is the move that says what's next (the dispatcher raises it
    // again if it's still in progress and idle).
    try setIdle(ctx, db, id, false);
    if (to == .testing) try setFlagId(ctx, db, id, flag_testing, "auto", "");
    if (to == .review) try setFlagId(ctx, db, id, flag_review, "auto", "");
    // Done, nothing waits on its park any more: it ends without resuming.
    // (Shelved in Backlog it stays parked: queued again, it still waits.)
    if (to == .done) {
        try db.exec("DELETE FROM parks WHERE ticket = ?1", .{id});
        if (db.changes() > 0) try logEvent(ctx, db, id, "unparked", "moved to Done");
    }
    // All but what runs after the merge (the after-merge command, the push
    // and its CI): that stays until the next run (or the human) clears it.
    if (to == .done) try db.exec("UPDATE flags SET cleared = ?2 WHERE ticket = ?1 AND cleared IS NULL AND kind NOT IN (?3, ?4, ?5)", .{ id, now(ctx), flag_after_merge, flag_push_failed, flag_ci_failed });
    // A todo done: its reminder has nothing left to remind of.
    if (to == .done) try db.exec("UPDATE tickets SET remind_at = 0 WHERE id = ?1", .{id});
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

/// The project's ticket that went into trunk last, as its after-merge run
/// was queued (only merges into trunk queue one: "merged" is also logged
/// for a ticket's --onto branch); null for none.
pub fn lastMergedTicket(db: Db, a: std.mem.Allocator, project: []const u8) Error!?[]const u8 {
    var st = try db.query("SELECT t.key FROM events e JOIN tickets t ON t.id = e.ticket WHERE t.project = ?1 AND e.kind = 'after-merge queued' ORDER BY e.at DESC, e.id DESC LIMIT 1", .{project});
    defer st.finalize();
    if (!try st.step()) return null;
    return try st.dupe(a, 0);
}

/// Flags that still ask something of a Done ticket, so Needs You keeps it:
/// its work didn't land (not merged, or merging it later conflicted) or what
/// runs after the merge failed. Going to Done clears the others.
pub fn asksWhenDone(kind: []const u8) bool {
    for ([_][]const u8{ flag_after_merge, flag_push_failed, flag_ci_failed, flag_unmerged, flag_merge_failed, flag_conflict }) |k| {
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
    for ([_][]const u8{ flag_question, flag_input, flag_review, flag_testing, flag_conflict, flag_idle, flag_due }) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

/// A todo's reminder or due date: Needs You keeps these apart, in a compact
/// Today group under Claude's asks, and they show even while it's parked
/// (waiting on Josh doesn't stop it being due).
pub fn todayFlag(kind: []const u8) bool {
    return std.mem.eql(u8, kind, flag_reminder) or std.mem.eql(u8, kind, flag_due);
}

/// Every flag that puts it in Needs You is a todo's reminder or due date
/// (on a parked ticket, those are the only ones that do): a line in the
/// Today group, under Claude's asks.
pub fn todayOnly(t: Ticket) bool {
    var any = false;
    for (t.flags) |f| if (!f.hidden and (t.stage != .done or asksWhenDone(f.kind)) and (t.park == null or todayFlag(f.kind))) {
        if (!todayFlag(f.kind)) return false;
        any = true;
    };
    return any;
}

test todayOnly {
    const due = [_]Flag{.{ .kind = flag_due, .source = "auto", .detail = "due today", .at = 1 }};
    const both = [_]Flag{ due[0], .{ .kind = flag_idle, .source = "auto", .detail = "", .at = 2 } };
    const hidden = [_]Flag{.{ .kind = flag_reminder, .source = "auto", .detail = "", .at = 1, .hidden = true }};
    const base: Ticket = .{ .id = 1, .key = "ME-1", .project = "me", .title = "t", .body = "", .stage = .backlog, .mode = .queue, .plan = false, .skill = "", .base = "", .change = "", .target = "", .worktree = "", .branch = "", .profile = "", .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0, .todo = true };
    var t = base;
    t.flags = @constCast(&due);
    try std.testing.expect(todayOnly(t));
    // Claude idle in its talk session asks too: a card, not a Today line...
    t.flags = @constCast(&both);
    try std.testing.expect(!todayOnly(t));
    // ...unless it's parked, when only the due date asks.
    t.park = .{ .reason = "Josh", .at = 0 };
    try std.testing.expect(todayOnly(t));
    // Nothing that asks: not in Today; Done: nothing asks.
    t = base;
    t.flags = @constCast(&hidden);
    try std.testing.expect(!todayOnly(t));
    t.flags = @constCast(&due);
    t.stage = .done;
    try std.testing.expect(!todayOnly(t));
}

/// Set a todo's next reminder (0 for none). The reminder that came up
/// before goes: this one replaces it.
fn setRemind(ctx: Ctx, db: Db, id: i64, at: i64) Error!void {
    try db.exec("UPDATE tickets SET remind_at = ?2 WHERE id = ?1", .{ id, at });
    try clearFlagId(ctx, db, id, flag_reminder);
}

/// Snooze a todo until `at`: a reminder then, and nothing in Needs You
/// until it comes (its `reminder` goes, its `due` is hidden: that comes back
/// with the reminder, or the next morning, whichever is first).
/// `said` is `at` as the human reads it ("Mon 9 Nov 08:00"), for the
/// activity log. BadInput
/// for a ticket that isn't a todo, or one that's Done.
pub fn snooze(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, at: i64, said: []const u8) Error!void {
    const t = try getTicket(db, a, key);
    if (!t.todo or t.stage == .done or at <= 0) return error.BadInput;
    try setRemind(ctx, db, t.id, at);
    try db.exec("UPDATE flags SET hidden = 1 WHERE ticket = ?1 AND kind = ?2 AND cleared IS NULL", .{ t.id, flag_due });
    try logEvent(ctx, db, t.id, "snoozed", said);
    try touch(ctx, db, t.id);
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

/// A ticket other than `id` is in progress in `tmux_name`. A todo isn't
/// (its talk session is no ticket's work: `dispatch.startTodo`).
pub fn sessionHasTicket(db: Db, tmux_name: []const u8, id: i64) Error!bool {
    return (try db.int("SELECT 1 FROM tickets WHERE tmux = ?1 AND id != ?2 AND todo = 0 AND stage IN " ++ in_progress, .{ tmux_name, id })) != null;
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

/// Start another round without moving the ticket (a send back from Review
/// does it as it moves to Running: `addComment`).
pub fn nextRound(db: Db, id: i64) Error!void {
    try db.exec("UPDATE tickets SET round = round + 1 WHERE id = ?1", .{id});
}

/// Claude says the ticket is finished and needs nothing more: it moves on
/// (`advance`: to Testing, or Review without a test plan), and the summary
/// is kept as its comment. During Planning it means the plan is ready: the
/// ticket stays in Planning with `review` (detail "plan") until the plan is
/// approved.
pub fn done(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, summary: []const u8) Error!void {
    try finishRound(ctx, db, a, key, summary);
    if ((try getTicket(db, a, key)).stage != .planning) _ = try advance(ctx, db, a, key);
}

/// `done` without the move: what Claude said is kept and what it waited on
/// is cleared, but the ticket stays where it is, so an automated review can
/// run on it in Running first (autoreview.startOnDone); `advance` moves it.
pub fn finishRound(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8, summary: []const u8) Error!void {
    const t = try getTicket(db, a, key);
    // Yours: it closes when you move it to Done.
    if (t.todo) return error.Todo;
    if (t.stage == .planning) {
        if (summary.len > 0) try db.exec("INSERT INTO comments (ticket, author, body, sent, at) VALUES (?1, 'claude', ?2, 0, ?3)", .{ t.id, summary, now(ctx) });
        try clearFlagId(ctx, db, t.id, flag_question);
        try clearFlagId(ctx, db, t.id, flag_input);
        try setFlagId(ctx, db, t.id, flag_review, "auto", "plan");
        try setOverview(ctx, db, t.id, if (summary.len > 0) summary else null, "");
        try logEvent(ctx, db, t.id, "plan ready", "");
        return;
    }
    try db.exec("UPDATE tickets SET summary = ?2 WHERE id = ?1", .{ t.id, summary });
    // What's next is the human's now: the board says what from the stage.
    try setOverview(ctx, db, t.id, if (summary.len > 0) summary else null, "");
    if (summary.len > 0) try db.exec("INSERT INTO comments (ticket, author, body, sent, at) VALUES (?1, 'claude', ?2, 0, ?3)", .{ t.id, summary, now(ctx) });
    try clearFlagId(ctx, db, t.id, flag_question);
    try clearFlagId(ctx, db, t.id, flag_input);
    // Woken from a park and finished since: its stage's flag says it now.
    try clearFlagId(ctx, db, t.id, flag_unparked);
    try logEvent(ctx, db, t.id, "done", "");
}

/// Where a ticket goes when Claude is done with a round. A round on its PR's
/// feedback goes back where it waited on the PR, not through the stages
/// before it again; one sent back from Testing or Review returns there
/// (`back_to`); otherwise Testing, or Review when it has nothing to test (no
/// handoff: a Verified list or a demo alone still gets a "Try it" step,
/// review.ticketTestPlan). Already in Testing or Review, it stays.
pub fn nextAfterDone(t: Ticket) Stage {
    if (prStage(t)) |s| return s;
    if (t.stage == .testing or t.stage == .review) return t.stage;
    const has_plan = t.test_plan.len > 0 or t.verified.len > 0 or t.demo.len > 0;
    if (std.mem.eql(u8, t.back_to, "review")) return .review;
    return if (has_plan) .testing else .review;
}

/// Move the ticket on after a round (`nextAfterDone`), with that stage's
/// flag: raised again if it was there already. Returns where it went.
pub fn advance(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8) Error!Stage {
    const t = try getTicket(db, a, key);
    const to = nextAfterDone(t);
    if (t.stage != to) try moveId(ctx, db, t.id, t.stage, to) else try raiseAfterReview(ctx, db, t.id, to);
    try db.exec("UPDATE tickets SET back_to = '' WHERE id = ?1", .{t.id});
    return to;
}

/// The stage a ticket finished with a PR waits in, parked on it; null when
/// it has no PR (or is Done).
pub fn prStage(t: Ticket) ?Stage {
    if (t.pr_url.len == 0 or t.stage == .done) return null;
    const s = Stage.parse(t.pr_stage) orelse return null;
    return if (s == .done) null else s;
}

/// The ticket was finished with the pull request `url` and waits in
/// `stage` for it. What its feedback rounds handed over starts afresh for
/// another PR, and is kept for the same one (finished with it again).
pub fn setPr(ctx: Ctx, db: Db, id: i64, url: []const u8, stage: Stage) Error!void {
    try db.exec(
        \\UPDATE tickets SET pr_seen = CASE WHEN pr_url = ?2 THEN pr_seen ELSE 0 END,
        \\  pr_seen_sha = CASE WHEN pr_url = ?2 THEN pr_seen_sha ELSE '' END,
        \\  pr_url = ?2, pr_stage = ?3 WHERE id = ?1
    , .{ id, url, @as([]const u8, @tagName(stage)) });
    try touch(ctx, db, id);
}

/// It no longer waits on a PR (closed without merging): `prStage` is null.
pub fn clearPr(ctx: Ctx, db: Db, id: i64) Error!void {
    try db.exec("UPDATE tickets SET pr_url = '', pr_stage = '', pr_seen = 0, pr_seen_sha = '' WHERE id = ?1", .{id});
    try touch(ctx, db, id);
}

/// What of its PR's feedback has been handed to its session (Ticket.pr_seen).
pub fn setPrSeen(db: Db, id: i64, at: i64, sha: []const u8) Error!void {
    try db.exec("UPDATE tickets SET pr_seen = max(pr_seen, ?2), pr_seen_sha = ?3 WHERE id = ?1", .{ id, at, sha });
}

/// The stage `approve` moves a ticket to: an approved plan goes to Queued
/// (a new session builds it when there is room), a tested ticket to Review,
/// a reviewed one to Done.
pub fn approvedStage(stage: Stage) ?Stage {
    return switch (stage) {
        .planning => .queued,
        .testing => .review,
        .review => .done,
        else => null,
    };
}

/// Approve what the ticket is waiting on; returns the stage it moved from.
pub fn approve(ctx: Ctx, db: Db, a: std.mem.Allocator, key: []const u8) Error!Stage {
    const t = try getTicket(db, a, key);
    const to = approvedStage(t.stage) orelse return error.BadInput;
    // (Leaving Planning clears the plan's review flag: see moveId.)
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

/// A ticket's link (`Ticket.link`) is a web page, a mail or a Slack link
/// ("" for none): the board opens it, so nothing that would run there
/// (javascript:, data:).
pub fn validLink(link: []const u8) bool {
    const l = std.mem.trim(u8, link, " \t\r\n");
    if (l.len == 0) return true;
    for ([_][]const u8{ "https://", "http://", "mailto:", "slack://" }) |p| {
        if (l.len > p.len and std.ascii.startsWithIgnoreCase(l, p)) return true;
    }
    return false;
}

test validLink {
    try std.testing.expect(validLink(""));
    try std.testing.expect(validLink("https://slack.com/archives/C1/p2"));
    try std.testing.expect(validLink("MAILTO:josh@example.com"));
    try std.testing.expect(!validLink("javascript:alert(1)"));
    try std.testing.expect(!validLink(" data:text/html,x"));
    try std.testing.expect(!validLink("https://"));
}

/// What error.Todo means to the human.
pub const todo_refused = "it's a todo: it's yours, so it is only ever in Backlog (to do), Running (doing) or Done, never planned, an umbrella or run by Claude; waiting on someone is a park";

/// The stages a todo can be in: Backlog (to do), Running (doing) and Done.
pub fn todoStage(s: Stage) bool {
    return s == .backlog or s == .running or s == .done;
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

// ---- drift ----

/// Its last test rebase when that found conflicts (see `Drift`).
fn driftOf(db: Db, a: std.mem.Allocator, id: i64) Error!?Drift {
    // A Done ticket's result is history until the next pass prunes it.
    var st = try db.query("SELECT d.files, d.onto, d.at FROM drift d JOIN tickets t ON t.id = d.ticket WHERE d.ticket = ?1 AND d.files != '' AND t.stage != 'done'", .{id});
    defer st.finalize();
    if (!try st.step()) return null;
    return .{ .files = try st.dupe(a, 0), .onto = try st.dupe(a, 1), .at = st.int(2) };
}

pub const DriftRow = struct { key: []const u8, files: []const u8 };

/// What its last test rebase tested and found; null when it had none.
pub fn driftRow(db: Db, a: std.mem.Allocator, id: i64) Error!?DriftRow {
    var st = try db.query("SELECT key, files FROM drift WHERE ticket = ?1", .{id});
    defer st.finalize();
    if (!try st.step()) return null;
    return .{ .key = try st.dupe(a, 0), .files = try st.dupe(a, 1) };
}

/// Keep a test rebase's result: `files` "" when it was clean.
pub fn setDrift(db: Db, id: i64, key: []const u8, files: []const u8, onto: []const u8, at: i64) Error!void {
    try db.exec("INSERT OR REPLACE INTO drift (ticket, key, files, onto, at) VALUES (?1, ?2, ?3, ?4, ?5)", .{ id, key, files, onto, at });
}

/// Forget a ticket's result, so it is tested afresh; true when that took a
/// warning away.
pub fn dropDrift(db: Db, id: i64) Error!bool {
    const warned = (try db.int("SELECT 1 FROM drift WHERE ticket = ?1 AND files != ''", .{id})) != null;
    try db.exec("DELETE FROM drift WHERE ticket = ?1", .{id});
    return warned;
}

/// Forget the results of tickets that are Done or have no change of their own.
pub fn pruneDrift(db: Db) Error!void {
    try db.execMulti("DELETE FROM drift WHERE ticket NOT IN (SELECT id FROM tickets WHERE stage != 'done' AND change_id != '')");
}

// ---- parks ----

fn parkOf(db: Db, a: std.mem.Allocator, id: i64) Error!?Park {
    var st = try db.query("SELECT reason, until_cmd, every, at, deadline, next, checked, result, pr, review FROM parks WHERE ticket = ?1", .{id});
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
        .pr = try st.dupe(a, 8),
        .review = st.int(9) != 0,
    };
}

/// Park a ticket (or change its park): `p.at` is now, and with a check the
/// first one is due at once.
pub fn setPark(ctx: Ctx, db: Db, id: i64, p: Park) Error!void {
    try db.exec(
        \\INSERT OR REPLACE INTO parks (ticket, reason, until_cmd, every, at, deadline, next, checked, result, pr, review)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, '', ?8, ?9)
    , .{ id, p.reason, p.until, p.every, p.at, p.deadline, p.next, p.pr, p.review });
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
    return .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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

test "a new code repo reviews by itself and sends the findings; a repo-less one, and one already there, don't" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try testing.expectEqual(AutoReview.send, (try getProject(db, a, "qa")).auto_review);
    try addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    try testing.expectEqual(AutoReview.off, (try getProject(db, a, "me")).auto_review);
    try addProject(db, .{ .name = "web", .dir = "/x/web", .auto_review = .off });
    try testing.expectEqual(AutoReview.off, (try getProject(db, a, "web")).auto_review);
    // A board from before the column: its projects stay off.
    try db.execMulti("ALTER TABLE projects DROP COLUMN auto_review");
    try migrate(db);
    try testing.expectEqual(AutoReview.off, (try getProject(db, a, "qa")).auto_review);
}

test "a project that isn't a code repo runs its tickets in the queue, with no automated review" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    // Projects are code repos unless told otherwise; their tickets say which.
    try addProject(db, .{ .name = "qa", .dir = "/x/qa", .mode = .worktree, .auto_review = .on });
    try testing.expect((try getProject(db, a, "qa")).repo);
    try testing.expect((try getTicket(db, a, try createTicket(ctx, db, a, .{ .project = "qa", .title = "Code", .mode = .queue }))).repo);

    // Not one: no worktrees or automated reviews, from the start.
    try testing.expectError(error.NoRepo, addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false, .mode = .worktree }));
    try testing.expectError(error.NoRepo, addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false, .auto_review = .send }));
    try addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    const p = try getProject(db, a, "me");
    try testing.expect(!p.repo);
    try testing.expectEqual(Mode.queue, p.mode);
    try testing.expectError(error.NoRepo, updateProject(db, "me", .{ .name = "", .dir = "", .mode = .worktree }));
    try testing.expectError(error.NoRepo, updateProject(db, "me", .{ .name = "", .dir = "", .auto_review = .on }));
    // Its tickets: the queue only.
    try testing.expectError(error.NoRepo, createTicket(ctx, db, a, .{ .project = "me", .title = "Call the bank", .mode = .worktree }));
    const k = try createTicket(ctx, db, a, .{ .project = "me", .title = "Call the bank" });
    const t = try getTicket(db, a, k);
    try testing.expect(!t.repo);
    try testing.expectEqual(Mode.queue, t.mode);
    try testing.expectError(error.NoRepo, updateTicket(ctx, db, a, k, .{ .mode = .worktree, .title = "Changed" }));
    // Refused whole: nothing else in the edit was made either.
    try testing.expectEqualStrings("Call the bank", (try getTicket(db, a, k)).title);

    // Made a code repo again, it can have them.
    try updateProject(db, "me", .{ .name = "", .dir = "", .repo = true, .mode = .worktree });
    try testing.expect((try getProject(db, a, "me")).repo);
    try updateTicket(ctx, db, a, k, .{ .mode = .worktree });

    // A code repo made repo-less goes to the queue and drops its automated reviews.
    try updateProject(db, "qa", .{ .name = "", .dir = "", .repo = false });
    const q = try getProject(db, a, "qa");
    try testing.expect(!q.repo);
    try testing.expectEqual(Mode.queue, q.mode);
    try testing.expectEqual(AutoReview.off, q.auto_review);
    // Asking for a worktree with it is refused, and changes nothing.
    try testing.expectError(error.NoRepo, updateProject(db, "me", .{ .name = "", .dir = "", .repo = false, .mode = .worktree }));
    try testing.expect((try getProject(db, a, "me")).repo);
}

test "what only a code repo has is refused, cleared or carried off when a project isn't one" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    // Target branch, push and after-merge command: none for a repo-less project.
    for ([_]ProjectInput{
        .{ .name = "me", .dir = "/x/me", .repo = false, .onto = "feature" },
        .{ .name = "me", .dir = "/x/me", .repo = false, .push_after_merge = "origin" },
        .{ .name = "me", .dir = "/x/me", .repo = false, .after_merge = "make install" },
    }) |in| {
        try testing.expectError(error.NoRepo, checkNewProject(db, in));
        try testing.expectError(error.NoRepo, addProject(db, in));
    }
    try addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false, .onto = "", .push_after_merge = "" });
    try testing.expectError(error.NoRepo, updateProject(db, "me", .{ .name = "", .dir = "", .onto = "feature" }));
    try testing.expectError(error.NoRepo, updateProject(db, "me", .{ .name = "", .dir = "", .push_after_merge = "origin" }));
    // checkNewProject checks before anything exists: a name taken is refused.
    try testing.expectError(error.Exists, checkNewProject(db, .{ .name = "me", .dir = "" }));
    // Its tickets get no target branch, given or inherited.
    try testing.expectError(error.NoRepo, createTicket(ctx, db, a, .{ .project = "me", .title = "Errand", .onto = "feature" }));
    const k = try createTicket(ctx, db, a, .{ .project = "me", .title = "Errand" });
    try testing.expectError(error.NoRepo, updateTicket(ctx, db, a, k, .{ .onto = "feature" }));

    // A code repo with all of them, made repo-less: they're cleared.
    try addProject(db, .{ .name = "qa", .dir = "/x/qa", .onto = "feature", .push_after_merge = "origin", .after_merge = "make" });
    const sub = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Code", .onto = "feature" });
    // A refused change changes nothing: here the prefix is taken.
    try testing.expectError(error.Exists, updateProject(db, "qa", .{ .name = "", .dir = "", .repo = false, .prefix = "ME" }));
    try testing.expect((try getProject(db, a, "qa")).repo);
    // Unfinished work in the repo holds it back (a worktree ticket here).
    const w = try createTicket(ctx, db, a, .{ .project = "qa", .title = "In a worktree", .mode = .worktree });
    try testing.expectError(error.RepoWork, updateProject(db, "qa", .{ .name = "", .dir = "", .repo = false }));
    try db.exec("UPDATE tickets SET stage = 'done' WHERE key = ?1", .{w});
    try db.exec("UPDATE tickets SET onto = '' WHERE key = ?1", .{sub});
    try updateProject(db, "qa", .{ .name = "", .dir = "", .repo = false });
    const q = try getProject(db, a, "qa");
    try testing.expectEqualStrings("", q.onto);
    try testing.expectEqualStrings("", q.push_after_merge);
    try testing.expectEqualStrings("", q.after_merge);
    try testing.expectEqualStrings("", (try getTicket(db, a, sub)).onto);

    // Moving a ticket into a repo-less project goes by that project's repo.
    try addProject(db, .{ .name = "code", .dir = "/x/code", .prefix = "CO" });
    const c1 = try createTicket(ctx, db, a, .{ .project = "code", .title = "Worktree one", .mode = .worktree, .onto = "feature" });
    try testing.expectError(error.NoRepo, updateTicket(ctx, db, a, c1, .{ .project = "me", .mode = .worktree }));
    try testing.expectEqualStrings("code", (try getTicket(db, a, c1)).project);
    // Without work under way it goes to the queue, with no target branch.
    try updateTicket(ctx, db, a, c1, .{ .project = "me" });
    const moved = try getTicket(db, a, c1);
    try testing.expectEqualStrings("me", moved.project);
    try testing.expectEqual(Mode.queue, moved.mode);
    try testing.expectEqualStrings("", moved.onto);
    try testing.expect(!moved.repo);
    // With a jj change of its own, it is refused: the work would be left behind.
    const c2 = try createTicket(ctx, db, a, .{ .project = "code", .title = "Has a change" });
    try db.exec("UPDATE tickets SET change_id = 'abc' WHERE key = ?1", .{c2});
    try testing.expectError(error.RepoWork, updateTicket(ctx, db, a, c2, .{ .project = "me" }));
}

test "an older board's projects are code repos" {
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    try db.execMulti("ALTER TABLE projects DROP COLUMN repo");
    try migrate(db);
    try testing.expect((try getProject(db, arena_state.allocator(), "qa")).repo);
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
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
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

test "plan, then tickets: an approved umbrella plan queues the sub-tickets it filed and runs as them" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Ideate", .plan = true, .umbrella = true });
    var t = try getTicket(db, a, k);
    try testing.expectEqual(Stage.planning, t.stage);
    try testing.expect(t.umbrella and t.plan);

    // The planning session files the sub-tickets (in Backlog, in order, one
    // linked to wait on another), then hands in the plan.
    const s1 = try createTicket(ctx, db, a, .{ .parent = k, .title = "One" });
    const s2 = try createTicket(ctx, db, a, .{ .parent = k, .title = "Two" });
    const s3 = try createTicket(ctx, db, a, .{ .parent = k, .title = "Three" });
    try setParallel(ctx, db, a, s2, true);
    try setParallel(ctx, db, a, s3, true);
    _ = try addBlocker(ctx, db, a, s3, s1);
    try setPlan(ctx, db, t.id, "## Sub-tickets\n1. One\n2. Two\n3. Three\n");
    try done(ctx, db, a, k, "Three tickets");
    try testing.expectEqual(@as(usize, 1), (try listTickets(db, a, .{ .needs = true })).len);
    // Nothing of it runs while the plan waits.
    for ([_][]const u8{ s1, s2, s3 }) |s| try testing.expectEqual(Stage.backlog, (try getTicket(db, a, s)).stage);

    // Approved: the review flag goes, the umbrella and its sub-tickets queue.
    try testing.expectEqual(Stage.planning, try approve(ctx, db, a, k));
    t = try getTicket(db, a, k);
    try testing.expectEqual(Stage.queued, t.stage);
    try testing.expectEqual(@as(usize, 0), t.flags.len);
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);
    for ([_][]const u8{ s1, s2, s3 }) |s| try testing.expectEqual(Stage.queued, (try getTicket(db, a, s)).stage);
    try testing.expectEqualStrings("## Sub-tickets\n1. One\n2. Two\n3. Three\n", t.plan_md);
    // Two runs alongside One; Three waits on One only.
    try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, s2)).blocked_by.len);
    const b3 = (try getTicket(db, a, s3)).blocked_by;
    try testing.expectEqual(@as(usize, 1), b3.len);
    try testing.expectEqualStrings(s1, b3[0].key);

    // It runs as its sub-tickets: Running when one starts, Done when all are.
    try move(ctx, db, a, s1, .running);
    try testing.expectEqual(Stage.running, (try getTicket(db, a, k)).stage);
    try move(ctx, db, a, s1, .done);
    try move(ctx, db, a, s2, .done);
    try testing.expectEqual(Stage.running, (try getTicket(db, a, k)).stage);
    try move(ctx, db, a, s3, .done);
    t = try getTicket(db, a, k);
    try testing.expectEqual(Stage.done, t.stage);
    try testing.expectEqual(@as(usize, 0), t.flags.len);
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);
}

test "leaving Planning by any path clears the plan's review flag" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    // Moved by hand (the board's stage select, `cl ticket move`, dragging
    // the card) to Queued, Backlog or further on: CL-128 kept its flag.
    for ([_]Stage{ .queued, .backlog, .running, .done }) |to| {
        const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Plan me", .plan = true, .umbrella = to == .queued });
        try done(ctx, db, a, k, "Plan ready");
        try testing.expectEqual(@as(usize, 1), (try getTicket(db, a, k)).flags.len);
        try move(ctx, db, a, k, to);
        try testing.expectEqual(@as(usize, 0), (try getTicket(db, a, k)).flags.len);
    }
    try testing.expectEqual(@as(usize, 0), (try listTickets(db, a, .{ .needs = true })).len);
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

test "migrate: a board from before todos gets the todo and link columns" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "Old" });
    try db.execMulti("ALTER TABLE tickets DROP COLUMN todo; ALTER TABLE tickets DROP COLUMN link");
    try migrate(db);
    const t = try getTicket(db, a, k);
    try testing.expect(!t.todo);
    try testing.expectEqualStrings("", t.link);
}

test "a todo is the human's: only backlog, running or done, never planned, an umbrella or done by Claude, and never held to start" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    const k = try createTicket(ctx, db, a, .{ .project = "me", .title = "Reply to Josh", .todo = true, .link = " https://slack.example/p1 \n" });
    const t = try getTicket(db, a, k);
    try testing.expect(t.todo);
    try testing.expectEqualStrings("https://slack.example/p1", t.link);
    try testing.expectEqual(Stage.backlog, t.stage);
    // The dispatcher leaves it alone, in any stage.
    try testing.expectEqual(Hold.todo, hold(t).?);
    // Never a plan, an umbrella, or in a stage Claude's work goes through.
    try testing.expectError(error.Todo, createTicket(ctx, db, a, .{ .project = "me", .title = "x", .todo = true, .plan = true }));
    try testing.expectError(error.Todo, createTicket(ctx, db, a, .{ .project = "me", .title = "x", .todo = true, .umbrella = true }));
    try testing.expectError(error.Todo, createTicket(ctx, db, a, .{ .project = "me", .title = "x", .todo = true, .stage = .queued }));
    try testing.expectError(error.Todo, updateTicket(ctx, db, a, k, .{ .umbrella = true }));
    try testing.expectError(error.Todo, updateTicket(ctx, db, a, k, .{ .plan = true }));
    for ([_]Stage{ .planning, .queued, .review, .testing }) |s| try testing.expectError(error.Todo, move(ctx, db, a, k, s));
    try testing.expectError(error.Todo, done(ctx, db, a, k, "finished"));
    try move(ctx, db, a, k, .running);
    try testing.expectEqual(Stage.running, (try getTicket(db, a, k)).stage);
    // A ticket in Review can't become one; one in Backlog can, and back.
    const r = try createTicket(ctx, db, a, .{ .project = "me", .title = "R", .stage = .review });
    try testing.expectError(error.Todo, updateTicket(ctx, db, a, r, .{ .todo = true }));
    const b = try createTicket(ctx, db, a, .{ .project = "me", .title = "B" });
    try updateTicket(ctx, db, a, b, .{ .todo = true, .link = "https://mail.example/1" });
    try testing.expect((try getTicket(db, a, b)).todo);
    try updateTicket(ctx, db, a, b, .{ .todo = false, .link = "" });
    try testing.expect(!(try getTicket(db, a, b)).todo);
    try testing.expectEqualStrings("", (try getTicket(db, a, b)).link);
    // Listing: only todos, or none.
    const todos = try listTickets(db, a, .{ .todo = true });
    try testing.expectEqual(@as(usize, 1), todos.len);
    try testing.expectEqualStrings(k, todos[0].key);
    try testing.expectEqual(@as(usize, 2), (try listTickets(db, a, .{ .todo = false })).len);
}

test "a todo's tasks are parallel and don't wait on it, and it doesn't close or get ready-to-close when they're done" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try createTicket(ctx, db, a, .{ .project = "qa", .title = "1:1 prep", .todo = true });
    const c1 = try createTicket(ctx, db, a, .{ .parent = k, .title = "Notes", .stage = .queued });
    const c2 = try createTicket(ctx, db, a, .{ .parent = k, .title = "Agenda", .stage = .queued });
    for ([_][]const u8{ c1, c2 }) |c| {
        const t = try getTicket(db, a, c);
        try testing.expect(t.parallel);
        // Not the todo, not the task before it: nothing holds it.
        try testing.expectEqual(@as(usize, 0), t.blocked_by.len);
        try testing.expect(hold(t) == null);
    }
    // Told otherwise, a task waits for the one before it.
    const c3 = try createTicket(ctx, db, a, .{ .parent = k, .title = "After agenda", .parallel = false });
    const t3 = try getTicket(db, a, c3);
    try testing.expectEqual(@as(usize, 2), t3.blocked_by.len);
    try testing.expectEqualStrings(c2, t3.blocked_by[1].key);
    try move(ctx, db, a, c1, .done);
    try move(ctx, db, a, c2, .done);
    try move(ctx, db, a, c3, .done);
    const after = try getTicket(db, a, k);
    try testing.expectEqual(Stage.backlog, after.stage);
    try testing.expectEqual(@as(usize, 0), after.flags.len);
    // An umbrella still closes by itself (and a plain parent is flagged).
    const u = try createTicket(ctx, db, a, .{ .project = "qa", .title = "U", .umbrella = true, .stage = .queued });
    const uc = try createTicket(ctx, db, a, .{ .parent = u, .title = "Only", .stage = .queued });
    try move(ctx, db, a, uc, .done);
    try testing.expectEqual(Stage.done, (try getTicket(db, a, u)).stage);
    // A todo under an umbrella isn't queued with it: it's still the human's.
    const ub = try createTicket(ctx, db, a, .{ .project = "qa", .title = "U2", .umbrella = true });
    const ut = try createTicket(ctx, db, a, .{ .parent = ub, .title = "Mine", .todo = true });
    const uw = try createTicket(ctx, db, a, .{ .parent = ub, .title = "Claude's" });
    try move(ctx, db, a, ub, .queued);
    try testing.expectEqual(Stage.backlog, (try getTicket(db, a, ut)).stage);
    try testing.expectEqual(Stage.queued, (try getTicket(db, a, uw)).stage);
}

test "a ticket made a todo: its tasks stop waiting on one another; Claude's work under way can't become one; links are checked" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const db = try Db.open(":memory:");
    defer db.close();
    try migrate(db);
    try addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const p = try createTicket(ctx, db, a, .{ .project = "qa", .title = "P" });
    _ = try createTicket(ctx, db, a, .{ .parent = p, .title = "One" });
    const two = try createTicket(ctx, db, a, .{ .parent = p, .title = "Two" });
    try testing.expectEqual(@as(usize, 2), (try getTicket(db, a, two)).blocked_by.len);
    try updateTicket(ctx, db, a, p, .{ .todo = true });
    const t2 = try getTicket(db, a, two);
    try testing.expect(t2.parallel);
    try testing.expectEqual(@as(usize, 0), t2.blocked_by.len);
    // Running with a session (or a change): refused.
    const r = try createTicket(ctx, db, a, .{ .project = "qa", .title = "R", .stage = .running });
    try db.exec("UPDATE tickets SET tmux = 'cl_qa_9' WHERE key = ?1", .{r});
    try testing.expectError(error.Todo, updateTicket(ctx, db, a, r, .{ .todo = true }));
    // Links the board would run rather than open.
    try testing.expectError(error.BadInput, createTicket(ctx, db, a, .{ .project = "qa", .title = "x", .link = "javascript:alert(1)" }));
    try testing.expectError(error.BadInput, updateTicket(ctx, db, a, p, .{ .link = "javascript:alert(1)" }));
    try updateTicket(ctx, db, a, p, .{ .link = "mailto:josh@example.com" });
}
