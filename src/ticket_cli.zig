//! `cl ticket ...` and `cl project ...`: the board from the command line.
//! Everything the web board can do to tickets is here too, and inside a
//! ticket's session (CL_TICKET set) the key can be left out.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const board = @import("board.zig");
const dispatch = @import("dispatch.zig");
const worktree = @import("worktree.zig");
const actions = @import("actions.zig");
const review = @import("review.zig");
const after_merge = @import("after_merge.zig");

pub const ticket_usage =
    \\usage: cl ticket <command>    (cl t for short)
    \\
    \\  new <project> <title> [-m <body>] [--worktree | --queue] [--target <session>]
    \\      [--plan [--skill <name>]] [--stage <stage>] [--profile <name>] [--parent <key>]
    \\                              create a ticket; prints its key. With --parent the
    \\                              project may be left out (it's the parent's)
    \\  sub <title> [-m <body>] [options of new]
    \\                              in a ticket's session: a sub-ticket of $CL_TICKET
    \\  list [--stage <s>] [--project <p>] [--flag <f>] [--needs] [--search <q>] [--open]
    \\      [--top] [--parent <key>]
    \\                              tickets, newest first (--needs: oldest ask first;
    \\                              --top: no sub-tickets; --parent: its sub-tickets)
    \\  needs [--hidden]            tickets with a flag, oldest first (the inbox); a ticket
    \\                              whose session is working on it is left out until it stops,
    \\                              and a hidden one until it raises a new flag (--hidden: those)
    \\  hide <key> / unhide <key>   keep it out of the inbox (Needs You) without clearing its
    \\                              flags, or bring it back; a new flag brings it back too
    \\  show <key>                  details, flags, sub-tickets, comments and activity
    \\  edit <key> [--title <t>] [-m <body>] [--project <p>] [--worktree | --queue]
    \\      [--target <session>] [--plan | --no-plan] [--skill <name>] [--profile <name>]
    \\  move <key> <stage> [--spin-off] [--merge | --pr | --tell <text> | --close]
    \\                              backlog planning queued running review testing done
    \\                              (done also closes the ticket's session; it's refused while
    \\                              sub-tickets are unfinished, --spin-off makes them top-level;
    \\                              --merge / --pr: Claude first merges the ticket's branch or
    \\                              opens a PR, then it goes to done (a jj change cl merges
    \\                              itself; Claude settles conflicts); --close, the default, and
    \\                              tickets without a branch of their own go straight there;
    \\                              --tell: Claude first does what <text> says, branch or not)
    \\  rank <key> --before <key> | --after <key> | --top | --bottom
    \\                              reorder: next to another ticket, as dragging its card on
    \\                              the board does, or first or last in its stage across all
    \\                              projects (the board column). The dispatcher starts queued
    \\                              tickets of a project in this order
    \\  start <key> [--now]         start it now: a worktree and session, or typed into its
    \\                              queue session (--now even if that session is busy); a ticket
    \\                              that ran before (killed, or its session ended) restarts,
    \\                              resuming its conversation where Claude still has it
    \\  kill <key>                  end its session, as cl kill does; it keeps its stage, raises
    \\                              no flag, and waits for start to restart it. A queue
    \\                              project's session is shared: other tickets on it let go too
    \\  approve <key> [--spin-off] [--merge | --pr | --tell <text> | --close]
    \\                              plan → running (tells Claude), review → testing, testing → done
    \\  answer <key> <answer>...    answer the question (one per question: an option number or
    \\                              your own words) or permission prompt (a number) it waits on;
    \\                              a multi-select question takes several numbers, maybe then
    \\                              your own words: "1,3", "1 3", "2,4,something else" or
    \\                              "1;2 more" (after ";" it's all your own words); a lone one
    \\                              also takes them as separate answers: answer <key> 1 3
    \\  key <key> esc|interrupt|enter|up|down
    \\                              press a key in its session
    \\  gutter <key> [--stop]       review its changes in gutter's window (with Claude's review
    \\                              guide); the review you submit there goes to its session
    \\  testplan <key> [--json]     the test plan Claude gave: its steps, in order
    \\  testplan --format           how to write one (for Claude)
    \\  launch <key> [--step <n>] [--stop]
    \\                              run a step's run: command (the first one by default) in tmux
    \\                              session clrun_<key>_s<n>; --stop: that step's, or all
    \\  test <key>                  walk through the test plan here; failures go back to Claude
    \\  relocate <key> worktree|queue
    \\                              move it to a worktree of its own, or back to the queue; one
    \\                              under way takes its jj change and conversation along and
    \\                              Claude is told it moved (edit --worktree/--queue does this too)
    \\  cleanup <key> [--branch]    remove its worktree (--branch: and the merged branch)
    \\  dispatch [--once]           start queued tickets as slots and sessions free up
    \\                              (cl web runs this too)
    \\  comment <key> <text> [--send] [--as you|claude]
    \\                              --send also types it into the ticket's session; on a
    \\                              ticket in review or testing that starts another round
    \\  flag <key> <kind> [detail]  set a flag (input question review testing, or your own)
    \\  unflag <key> <kind>
    \\  custom-close [<key>] <what to do instead> | --clear
    \\                              Claude: this ticket shouldn't be finished the usual way
    \\                              (merged or a PR); the board offers only this instead
    \\  done [<key>] [--summary <text>] [--test-plan <markdown> | -]
    \\                              Claude: finished, nothing more needed; moves to review.
    \\                              --test-plan (- reads stdin): what to try, kept in the ticket
    \\                              (steps; `testplan --format`); without it an
    \\                              earlier round's stays, "" drops it
    \\  done [<key>] --close [--pr-url <url>]
    \\                              Claude: merged or opened the PR it was asked to; moves to
    \\                              done (the PR link becomes a comment) and closes the session
    \\  rm <key>                    (refused while it has sub-tickets)
    \\
    \\  list, needs and show take --json. In a ticket's session ($CL_TICKET) the key
    \\  may be left out.
    \\
;

pub const project_usage =
    \\usage: cl project <command>
    \\
    \\  add <name> <dir> [--prefix <KEY>] [--slots <n>] [--mode queue|worktree] [--profile <name>]
    \\      [--after-merge <command>] [--after-merge-claude <steps> | none]
    \\  set <name> [--name <new>] [--dir <dir>] [--prefix <KEY>] [--slots <n>]
    \\      [--mode queue|worktree] [--profile <name>] [--after-merge <command>]
    \\      [--after-merge-claude <steps> | none]
    \\  rm <name>
    \\  list [--json]
    \\  after-merge <name>          run the after-merge command now, on trunk as it is
    \\
    \\--after-merge: a shell command cl runs after it merges a ticket into trunk, in a
    \\  clean checkout of the merged commit (not the project's own), detached. It
    \\  gets CL_TICKET, CL_TICKETS, CL_PROJECT, CL_COMMIT, CL_PROJECT_DIR and
    \\  CL_CHECKOUT; output goes to ~/.local/state/cl/after-merge-<name>.log, and a
    \\  failure flags the ticket. "" removes it.
    \\--after-merge-claude: what Claude is asked to do after a merge when there is no
    \\  command (the ticket's Claude, or the operator once its session is gone), and
    \\  what the operator is asked to sort out when the command fails. "" (the
    \\  default): rebuild and restart what runs from the checkout. none: nothing.
    \\
++ std.fmt.comptimePrint("--slots: worktree tickets in progress at once (default {d})\n", .{board.default_slots});

fn out(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), text);
}

fn fail(comptime fmt: []const u8, a: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cl: " ++ fmt ++ "\n", a) catch "cl: error\n";
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
    std.process.exit(1);
}

/// Positional arguments and --options, in any order. Options listed in
/// `valued` take the next argument as their value; others are switches.
const Args = struct {
    pos: std.ArrayList([]const u8) = .empty,
    opts: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn parse(a: std.mem.Allocator, argv: []const []const u8, valued: []const []const u8, usage: []const u8) !Args {
        var r: Args = .{};
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const s = argv[i];
            if (s.len > 1 and s[0] == '-' and !isNumber(s)) {
                const name = if (std.mem.eql(u8, s, "-m")) "--body" else s;
                const takes = for (valued) |v| {
                    if (std.mem.eql(u8, v, name)) break true;
                } else false;
                if (takes) {
                    i += 1;
                    if (i >= argv.len) fail("{s} needs a value\n{s}", .{ s, usage });
                    try r.opts.put(a, name, argv[i]);
                } else try r.opts.put(a, name, "");
            } else try r.pos.append(a, s);
        }
        return r;
    }

    fn has(self: Args, name: []const u8) bool {
        return self.opts.contains(name);
    }

    fn get(self: Args, name: []const u8) ?[]const u8 {
        return self.opts.get(name);
    }

    /// Fail on any option not in `allowed`.
    fn only(self: Args, allowed: []const []const u8, usage: []const u8) void {
        var it = self.opts.keyIterator();
        while (it.next()) |k| {
            for (allowed) |x| {
                if (std.mem.eql(u8, x, k.*)) break;
            } else fail("unknown option {s}\n{s}", .{ k.*, usage });
        }
    }
};

fn isNumber(s: []const u8) bool {
    _ = std.fmt.parseInt(i64, s, 10) catch return false;
    return true;
}

/// Report a board error and exit.
fn boardFail(db: board.Db, err: anyerror, what: []const u8) noreturn {
    switch (err) {
        error.NotFound => fail("no such {s}", .{what}),
        error.Exists => fail("{s} already exists (or is still in use)", .{what}),
        error.BadInput => fail("invalid {s}", .{what}),
        error.NoSession => fail("its session isn't running, so Claude can't finish it; use --close", .{}),
        error.CustomClose => fail("Claude asked to close it its own way (see custom close in `cl ticket show`); use --tell, or --close, or clear it with `cl ticket custom-close <key> --clear`", .{}),
        error.OpenSubtickets => fail("it has sub-tickets that aren't done yet; finish them, or make them tickets of their own with `cl ticket move <key> done --spin-off`", .{}),
        error.Conflicts => fail("merging it back conflicts (see `cl ticket show`); resolve them in its change, then try again", .{}),
        error.MergeFailed => fail("jj couldn't merge it: {s}", .{worktree.lastError()}),
        error.Sqlite => fail("board database: {s}", .{db.message()}),
        else => fail("{s}: {s}", .{ what, @errorName(err) }),
    }
}

fn openBoard(ctx: Ctx, cfg: config.Config) board.Db {
    return board.open(ctx, cfg) catch |err| switch (err) {
        error.Sqlite => fail("cannot open the board database", .{}),
        else => fail("cannot open the board database: {s}", .{@errorName(err)}),
    };
}

fn parseStage(s: []const u8) board.Stage {
    return board.Stage.parse(s) orelse fail("no such stage: {s} (backlog planning queued running review testing done)", .{s});
}

/// Move a ticket to `to` (see `dispatch.relocate`) and say where it went.
fn relocate(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, to: board.Mode) !void {
    const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    const r = dispatch.relocate(ctx, cfg, db, a, t, to) catch |e| switch (e) {
        error.Busy => fail("{s}: Claude is working in its session or waiting on you; move it once it is idle", .{t.key}),
        error.NoChange => fail("{s} is under way, but its work has no jj change of its own to move with it", .{t.key}),
        error.WorktreeFailed => fail("jj: {s}", .{worktree.lastError()}),
        error.SessionFailed => fail("cannot start the session", .{}),
        else => boardFail(db, e, "ticket"),
    };
    const after = board.getTicket(db, a, t.key) catch |e| boardFail(db, e, "ticket");
    return out(switch (r) {
        .mode => try std.fmt.allocPrint(a, "{s} runs {s} when it starts\n", .{ t.key, if (to == .worktree) "in a worktree of its own" else "in the queue" }),
        .moved => try std.fmt.allocPrint(a, "{s} moved to {s}{s}{s}\n", .{ t.key, after.tmux, if (after.worktree.len > 0) " at " else "", try ctx.shortenHomeIn(a, after.worktree) }),
        .waiting => try std.fmt.allocPrint(a, "{s} waits in Queued for {s}\n", .{ t.key, if (to == .worktree) "a worktree slot (the project's are all taken)" else "the project's session" }),
    });
}

fn parseMode(args: Args) ?board.Mode {
    if (args.has("--worktree") and args.has("--queue")) fail("--worktree or --queue, not both", .{});
    if (args.has("--worktree")) return .worktree;
    if (args.has("--queue")) return .queue;
    return null;
}

fn parseSlots(args: Args) ?i64 {
    const s = args.get("--slots") orelse return null;
    const n = std.fmt.parseInt(i64, s, 10) catch fail("not a number: {s}", .{s});
    if (n < 1) fail("--slots must be at least 1", .{});
    return n;
}

// ---- projects ----

pub fn projectMain(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len == 0) return out(project_usage);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = argv[0];
    const args = try Args.parse(a, argv[1..], &.{ "--prefix", "--slots", "--mode", "--profile", "--name", "--dir", "--after-merge", "--after-merge-claude" }, project_usage);
    const db = openBoard(ctx, cfg);
    defer db.close();

    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        args.only(&.{"--json"}, project_usage);
        const ps = board.listProjects(db, a) catch |e| boardFail(db, e, "project");
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(ps, .{})}));
        var aw: std.Io.Writer.Allocating = .init(a);
        for (ps) |p| try aw.writer.print("{s}\t{s}\t{s}\tslots {d}\t{s}{s}{s}{s}{s}{s}{s}\n", .{
            p.name, p.prefix, try ctx.shortenHomeIn(a, p.dir), p.slots, @tagName(p.mode),
            if (p.profile.len > 0) "\t" else "", p.profile,
            if (p.after_merge.len > 0) "\tafter merge: " else "", p.after_merge,
            if (p.after_merge_claude.len > 0) "\tclaude after merge: " else "", p.after_merge_claude,
        });
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "add")) {
        args.only(&.{ "--prefix", "--slots", "--mode", "--profile", "--after-merge", "--after-merge-claude" }, project_usage);
        if (args.pos.items.len != 2) fail("usage: cl project add <name> <dir> [options]", .{});
        const dir = try realDir(ctx, a, args.pos.items[1]);
        try checkProfile(cfg, args.get("--profile"));
        board.addProject(db, .{
            .name = args.pos.items[0],
            .dir = dir,
            .prefix = args.get("--prefix"),
            .slots = parseSlots(args),
            .mode = if (args.get("--mode")) |m| board.Mode.parse(m) orelse fail("--mode is queue or worktree", .{}) else null,
            .profile = args.get("--profile"),
            .after_merge = args.get("--after-merge"),
            .after_merge_claude = args.get("--after-merge-claude"),
        }) catch |e| boardFail(db, e, "project (name or prefix)");
        const p = board.getProject(db, a, args.pos.items[0]) catch |e| boardFail(db, e, "project");
        const jj = worktree.ensureJj(ctx, a, dir);
        return out(try std.fmt.allocPrint(a, "{s}: tickets are {s}-1, {s}-2, ...{s}\n", .{ p.name, p.prefix, p.prefix, if (jj) "\n(set up jj alongside git: jj git init --colocate)" else "" }));
    }
    if (std.mem.eql(u8, cmd, "set")) {
        args.only(&.{ "--prefix", "--slots", "--mode", "--profile", "--name", "--dir", "--after-merge", "--after-merge-claude" }, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project set <name> [options]", .{});
        try checkProfile(cfg, args.get("--profile"));
        board.updateProject(db, args.pos.items[0], .{
            .name = args.get("--name") orelse "",
            .dir = if (args.get("--dir")) |d| try realDir(ctx, a, d) else "",
            .prefix = args.get("--prefix"),
            .slots = parseSlots(args),
            .mode = if (args.get("--mode")) |m| board.Mode.parse(m) orelse fail("--mode is queue or worktree", .{}) else null,
            .profile = args.get("--profile"),
            .after_merge = args.get("--after-merge"),
            .after_merge_claude = args.get("--after-merge-claude"),
        }) catch |e| boardFail(db, e, "project (name or prefix)");
        return;
    }
    if (std.mem.eql(u8, cmd, "after-merge")) {
        args.only(&.{"--run"}, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project after-merge <name>", .{});
        const name = args.pos.items[0];
        // --run: the detached runner cl starts (see after_merge.zig).
        if (args.has("--run")) return after_merge.runLoop(ctx, cfg, db, name);
        const p = board.getProject(db, a, name) catch |e| boardFail(db, e, "project");
        if (p.after_merge.len == 0) fail("{s} has no after-merge command (cl project set {s} --after-merge <command>)", .{ name, name });
        after_merge.startByHand(ctx, db, a, name, "-") catch |e| boardFail(db, e, "project");
        return out(try std.fmt.allocPrint(a, "{s}: after-merge run started; log: {s}\n", .{ name, try ctx.shortenHomeIn(a, try after_merge.logPath(ctx, a, cfg, name)) }));
    }
    if (std.mem.eql(u8, cmd, "rm")) {
        args.only(&.{}, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project rm <name>", .{});
        board.removeProject(db, args.pos.items[0]) catch |e| switch (e) {
            error.Exists => fail("{s} still has tickets; remove or move them first", .{args.pos.items[0]}),
            else => boardFail(db, e, "project"),
        };
        return;
    }
    fail("unknown project command: {s}\n{s}", .{ cmd, project_usage });
}

fn realDir(ctx: Ctx, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const expanded = try ctx.expandHome(path);
    defer ctx.gpa.free(expanded);
    return std.Io.Dir.cwd().realPathFileAlloc(ctx.io, expanded, a) catch fail("no such directory: {s}", .{path});
}

fn checkProfile(cfg: config.Config, name: ?[]const u8) !void {
    const n = name orelse return;
    if (n.len > 0 and cfg.find(n) == null) fail("no such profile: {s}", .{n});
}

// ---- tickets ----

pub fn ticketMain(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len == 0) return out(ticket_usage);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = argv[0];
    const args = try Args.parse(a, argv[1..], &.{
        "--body", "--target", "--stage", "--profile", "--project", "--flag", "--search", "--title", "--as", "--summary", "--test-plan", "--step", "--parent", "--skill", "--pr-url", "--before", "--after", "--tell",
    }, ticket_usage);
    const env_key = ctx.env.get("CL_TICKET");
    const db = openBoard(ctx, cfg);
    defer db.close();
    const pos = args.pos.items;

    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "sub")) {
        args.only(&.{ "--body", "--worktree", "--queue", "--target", "--plan", "--skill", "--stage", "--profile", "--parent", "--json" }, ticket_usage);
        const is_sub = std.mem.eql(u8, cmd, "sub");
        const parent = args.get("--parent") orelse if (is_sub) (env_key orelse fail("cl ticket sub runs in a ticket's session ($CL_TICKET); elsewhere use new --parent <key>", .{})) else null;
        // With a parent, the project is optional: new --parent QA-2 "title".
        const project, const title = if (pos.len == 2) .{ pos[0], pos[1] } else if (pos.len == 1 and parent != null) .{ "", pos[0] } else fail("usage: cl ticket {s}", .{if (is_sub) "sub <title> [options]" else "new <project> <title> [options]"});
        try checkProfile(cfg, args.get("--profile"));
        const key = board.createTicket(ctx, db, a, .{
            .project = project,
            .parent = parent,
            .title = title,
            .body = args.get("--body"),
            .mode = parseMode(args),
            .target = args.get("--target"),
            .plan = args.has("--plan") or args.has("--skill"),
            .skill = args.get("--skill"),
            .stage = if (args.get("--stage")) |s| parseStage(s) else null,
            .profile = args.get("--profile"),
        }) catch |e| boardFail(db, e, if (parent != null) "parent ticket or project" else "project");
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .key = key }, .{})}));
        return out(try std.fmt.allocPrint(a, "{s}\n", .{key}));
    }
    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "needs")) {
        args.only(&.{ "--stage", "--project", "--flag", "--needs", "--hidden", "--search", "--open", "--top", "--parent", "--json" }, ticket_usage);
        if (pos.len != 0) fail("{s} takes no arguments\n{s}", .{ cmd, ticket_usage });
        const needs = args.has("--needs") or args.has("--hidden") or std.mem.eql(u8, cmd, "needs");
        const ts = board.listTickets(db, a, .{
            .stage = if (args.get("--stage")) |s| parseStage(s) else null,
            .project = args.get("--project"),
            .flag = args.get("--flag"),
            .needs = needs,
            .hidden = args.has("--hidden"),
            // Tickets Claude is working on aren't waiting on the human.
            .busy = if (needs) claude.busySessions(ctx, a, cfg) catch &.{} else &.{},
            .search = args.get("--search"),
            .done = !args.has("--open"),
            .top = args.has("--top"),
            .parent = args.get("--parent"),
        }) catch |e| boardFail(db, e, "ticket");
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(ts, .{})}));
        var aw: std.Io.Writer.Allocating = .init(a);
        // key, stage, project, flags, parent, title
        for (ts) |t| try aw.writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ t.key, @tagName(t.stage), t.project, try flagList(a, t.flags), if (t.parent.len > 0) t.parent else "-", t.title });
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "show")) {
        args.only(&.{"--json"}, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket show <key>");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const cs = board.comments(db, a, t.id) catch |e| boardFail(db, e, "ticket");
        const evs = board.events(db, a, t.id) catch |e| boardFail(db, e, "ticket");
        const subs = board.listTickets(db, a, .{ .parent = t.key }) catch |e| boardFail(db, e, "ticket");
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .ticket = t, .subtickets = subs, .comments = cs, .events = evs }, .{})}));
        return out(try showText(ctx, a, t, subs, cs, evs));
    }
    if (std.mem.eql(u8, cmd, "edit")) {
        args.only(&.{ "--title", "--body", "--project", "--worktree", "--queue", "--target", "--plan", "--no-plan", "--skill", "--profile" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket edit <key> [options]");
        try checkProfile(cfg, args.get("--profile"));
        board.updateTicket(ctx, db, a, key, .{
            .project = args.get("--project") orelse "",
            .title = args.get("--title"),
            .body = args.get("--body"),
            .plan = if (args.has("--plan")) true else if (args.has("--no-plan")) false else null,
            .target = args.get("--target"),
            .profile = args.get("--profile"),
            .skill = args.get("--skill"),
        }) catch |e| boardFail(db, e, "ticket or project");
        if (parseMode(args)) |m| return relocate(ctx, cfg, db, a, key, m);
        return;
    }
    if (std.mem.eql(u8, cmd, "relocate")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket relocate <key> worktree|queue", .{});
        return relocate(ctx, cfg, db, a, pos[0], board.Mode.parse(pos[1]) orelse fail("worktree or queue", .{}));
    }
    if (std.mem.eql(u8, cmd, "move") or std.mem.eql(u8, cmd, "mv")) {
        args.only(&.{ "--spin-off", "--merge", "--pr", "--tell", "--close" }, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket move <key> <stage> [--spin-off] [--merge | --pr | --tell <text> | --close]", .{});
        const finish = finishArg(args);
        actions.move(ctx, db, a, pos[0], parseStage(pos[1]), args.has("--spin-off"), finish) catch |e| boardFail(db, e, "ticket");
        return finishNote(db, a, pos[0]);
    }
    if (std.mem.eql(u8, cmd, "rank")) {
        const usage = "usage: cl ticket rank <key> --before <key> | --after <key> | --top | --bottom";
        args.only(&.{ "--before", "--after", "--top", "--bottom" }, ticket_usage);
        if (pos.len != 1) fail("{s}", .{usage});
        const before = args.get("--before");
        const after = args.get("--after");
        var places: u8 = 0;
        for ([_]bool{ before != null, after != null, args.has("--top"), args.has("--bottom") }) |b| places += @intFromBool(b);
        if (places != 1) fail("give one of --before, --after, --top or --bottom\n{s}", .{usage});
        for ([_]?[]const u8{ pos[0], before, after }) |k| if (k) |key| {
            _ = board.getTicket(db, a, key) catch |e| boardFail(db, e, try std.fmt.allocPrint(a, "ticket {s}", .{key}));
        };
        if (before orelse after) |ref| if (std.mem.eql(u8, ref, pos[0])) fail("can't rank {s} next to itself", .{ref});
        (if (before != null or after != null)
            board.rankTicket(db, a, pos[0], after, before)
        else
            board.rankInStage(db, a, pos[0], args.has("--top"))) catch |e| boardFail(db, e, "ticket");
        return;
    }
    if (std.mem.eql(u8, cmd, "comment")) {
        args.only(&.{ "--send", "--as" }, ticket_usage);
        // One argument inside a ticket's session: just the text.
        const key, const text = if (pos.len == 1 and env_key != null) .{ env_key.?, pos[0] } else if (pos.len == 2) .{ pos[0], pos[1] } else fail("usage: cl ticket comment <key> <text> [--send] [--as you|claude]", .{});
        const author = args.get("--as") orelse (if (env_key != null) "claude" else "you");
        if (!std.mem.eql(u8, author, "you") and !std.mem.eql(u8, author, "claude")) fail("--as is you or claude", .{});
        const r = actions.comment(ctx, db, a, key, author, text, args.has("--send")) catch |e| boardFail(db, e, "ticket or comment");
        if (r.unsent) std.Io.File.stderr().writeStreamingAll(ctx.io, "cl: the ticket has no session yet; saved without sending\n") catch {};
        if (r.sent_back) return out(try std.fmt.allocPrint(a, "{s} is back in running (round {d})\n", .{ key, r.round }));
        return;
    }
    if (std.mem.eql(u8, cmd, "custom-close")) {
        args.only(&.{"--clear"}, ticket_usage);
        const clear = args.has("--clear");
        const with_key = pos.len == @as(usize, if (clear) 1 else 2);
        const key = if (with_key) pos[0] else (env_key orelse fail("usage: cl ticket custom-close [<key>] <what to do instead> | --clear", .{}));
        const rest = if (with_key) pos[1..] else pos;
        if (clear != (rest.len == 0) or rest.len > 1) fail("usage: cl ticket custom-close [<key>] <what to do instead> | --clear", .{});
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const text = if (clear) "" else std.mem.trim(u8, rest[0], " \t\r\n");
        if (!clear and text.len == 0) fail("say what to do instead", .{});
        board.setCustomClose(ctx, db, t.id, text) catch |e| boardFail(db, e, "ticket");
        return out(try std.fmt.allocPrint(a, "{s}: {s}\n", .{ t.key, if (clear) "back to the usual finish" else "the board offers only this close instead of merge or PR" }));
    }
    if (std.mem.eql(u8, cmd, "flag") or std.mem.eql(u8, cmd, "unflag")) {
        args.only(&.{}, ticket_usage);
        const setting = std.mem.eql(u8, cmd, "flag");
        // Inside a ticket's session the key may be left out.
        const with_key = pos.len >= 2 and !(env_key != null and setting and pos.len == 2 and isFlagWord(pos[0]) and !looksLikeKey(pos[0]));
        const key = if (with_key) pos[0] else (env_key orelse fail("usage: cl ticket {s} <key> <kind>{s}", .{ cmd, if (setting) " [detail]" else "" }));
        const rest = if (with_key) pos[1..] else pos;
        if (rest.len == 0 or rest.len > @as(usize, if (setting) 2 else 1)) fail("usage: cl ticket {s} <key> <kind>{s}", .{ cmd, if (setting) " [detail]" else "" });
        if (setting) {
            const source = if (env_key != null) "auto" else "manual";
            board.setFlag(ctx, db, a, key, rest[0], source, if (rest.len == 2) rest[1] else "") catch |e| boardFail(db, e, "ticket or flag (lower case letters, digits, -)");
        } else board.clearFlag(ctx, db, a, key, rest[0]) catch |e| boardFail(db, e, "ticket");
        return;
    }
    if (std.mem.eql(u8, cmd, "done")) {
        args.only(&.{ "--summary", "--test-plan", "--close", "--pr-url" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket done [<key>] [--summary <text>] [--test-plan <markdown> | -] [--close [--pr-url <url>]]");
        const t0 = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        // While finishing, a plain `done` means the merge or PR is done too.
        if (args.has("--close") or t0.finishing.len > 0) {
            if (t0.finishing.len == 0) fail("{s} isn't finishing (--close is for after a merge or PR the board asked for); use done without it", .{t0.key});
            // Settled conflicts merge first, so a refusal comes before the message.
            const merged_now = actions.mergeSettled(ctx, db, a, t0) catch |e| boardFail(db, e, "ticket");
            // Just merged, with no after-merge command: Claude does the steps first.
            if (merged_now) if (actions.stepsAfterSettled(ctx, db, a, t0) catch |e| boardFail(db, e, "ticket")) |steps| {
                if (args.get("--summary")) |sum| _ = board.addComment(ctx, db, a, key, "claude", sum, false) catch {};
                return out(try std.fmt.allocPrint(a, "{s}: {s}\n", .{ t0.key, steps }));
            };
            // Printed first: closing kills the session this may be running in.
            try out(try std.fmt.allocPrint(a, "{s}: done; its session closes now.\n", .{t0.key}));
            actions.finished(ctx, db, a, key, args.get("--summary") orelse "", args.get("--pr-url") orelse "") catch |e| boardFail(db, e, "ticket");
            return;
        }
        if (args.get("--pr-url") != null) fail("--pr-url goes with --close", .{});
        var test_plan = args.get("--test-plan");
        if (test_plan != null and std.mem.eql(u8, test_plan.?, "-")) {
            var buf: [4096]u8 = undefined;
            var r = std.Io.File.stdin().reader(ctx.io, &buf);
            test_plan = r.interface.allocRemaining(a, .limited(256 * 1024)) catch fail("cannot read the test plan from stdin", .{});
        }
        review.done(ctx, db, a, key, args.get("--summary") orelse "", test_plan) catch |e| switch (e) {
            error.BadTestPlan => fail("{s}", .{if (t0.stage == .planning) "a plan being approved has no test plan yet" else "the test plan needs at least one \"- [ ] ...\" check (cl ticket testplan --format)"}),
            else => boardFail(db, e, "ticket"),
        };
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        // Said when Claude finishes, as that's when it knows: its work has a
        // branch the human will be offered to merge.
        const hint = if (t.stage != .planning and (t.branch.len > 0 or t.change.len > 0) and t.custom_close.len == 0)
            try std.fmt.allocPrint(a, "\nIf its work shouldn't be merged (or made a PR) as it is, say so now: `cl ticket custom-close {s} \"<what to do with it instead>\"`.", .{t.key})
        else
            "";
        return out(try std.fmt.allocPrint(a, "{s}: {s}. The board shows it to the human; nothing more to do.{s}\n", .{
            t.key, if (t.stage == .planning) "plan ready for approval" else "moved to review", hint,
        }));
    }
    if (std.mem.eql(u8, cmd, "rm")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket rm <key>", .{});
        board.removeTicket(db, a, pos[0]) catch |e| switch (e) {
            error.Exists => fail("{s} has sub-tickets; remove them first", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "start")) {
        args.only(&.{"--now"}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket start <key> [--now]", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        dispatch.start(ctx, cfg, db, a, t, args.has("--now")) catch |e| switch (e) {
            error.AlreadyStarted => fail("{s} already has a session: {s}", .{ t.key, t.tmux }),
            error.TargetBusy => fail("{s}'s session is busy or has another ticket in progress; it waits in Queued (--now types it in anyway)", .{t.key}),
            error.WorktreeFailed => fail("cannot make the worktree: {s}", .{worktree.lastError()}),
            error.SessionFailed => fail("cannot start the session", .{}),
            else => boardFail(db, e, "ticket"),
        };
        const after = board.getTicket(db, a, t.key) catch |e| boardFail(db, e, "ticket");
        return out(try std.fmt.allocPrint(a, "{s} started in {s}{s}{s}\n", .{
            after.key, after.tmux, if (after.worktree.len > 0) " at " else "", try ctx.shortenHomeIn(a, after.worktree),
        }));
    }
    if (std.mem.eql(u8, cmd, "kill")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket kill <key>", .{});
        const r = actions.kill(ctx, cfg, db, a, pos[0]) catch |e| switch (e) {
            error.NoSession => fail("{s} has no live session", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        var aw: std.Io.Writer.Allocating = .init(a);
        try aw.writer.print("killed {s}; {s} stays in {s}. `cl ticket start {s}` restarts it{s}.\n", .{
            r.session, t.key, @tagName(t.stage), t.key, if (r.resumes) ", resuming its conversation" else "",
        });
        if (r.others.len > 0) try aw.writer.print("it was shared: {s} let go of it too\n", .{try std.mem.join(a, ", ", r.others)});
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "hide") or std.mem.eql(u8, cmd, "unhide")) {
        args.only(&.{}, ticket_usage);
        const key = keyArg(pos, 0, env_key, try std.fmt.allocPrint(a, "cl ticket {s} <key>", .{cmd}));
        const any = board.hideNeeds(ctx, db, a, key, std.mem.eql(u8, cmd, "hide")) catch |e| boardFail(db, e, "ticket");
        if (!any) fail("{s} has no flag, so it isn't in the inbox", .{key});
        return;
    }
    if (std.mem.eql(u8, cmd, "approve")) {
        args.only(&.{ "--spin-off", "--merge", "--pr", "--tell", "--close" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket approve <key>");
        _ = actions.approve(ctx, db, a, key, args.has("--spin-off"), finishArg(args)) catch |e| switch (e) {
            error.BadInput => fail("only a ticket in planning, review or testing can be approved", .{}),
            else => boardFail(db, e, "ticket"),
        };
        return finishNote(db, a, key);
    }
    if (std.mem.eql(u8, cmd, "answer")) {
        args.only(&.{}, ticket_usage);
        if (pos.len < 2) fail("usage: cl ticket answer <key> <answer>...", .{});
        actions.answer(ctx, cfg, db, a, pos[0], pos[1..]) catch |e| switch (e) {
            error.NoSession => fail("{s} has no live session", .{pos[0]}),
            error.NothingAsked => fail("{s} isn't waiting on a question or permission prompt", .{pos[0]}),
            error.BadAnswer => fail("give one answer per question: an option number or your own words; for a multi-select one, option numbers like 1,3 (permission prompts take a number)", .{}),
            error.NotDelivered => fail("{s}: the answer was typed, but Claude is still waiting on the same thing; check the session", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "key")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket key <key> esc|interrupt|enter|up|down", .{});
        const k = std.meta.stringToEnum(actions.Key, pos[1]) orelse fail("keys: esc interrupt enter up down", .{});
        actions.press(ctx, db, a, pos[0], k) catch |e| switch (e) {
            error.NoSession => fail("{s} has no live session", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "gutter")) {
        args.only(&.{ "--stop", "--submitted" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket gutter <key> [--stop]");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        if (args.has("--stop")) return review.stopGutter(ctx, a, t.key);
        if (args.has("--submitted")) {
            const r = actions.gutterSubmitted(ctx, db, a, t.key) catch |e| switch (e) {
                error.NoReview => fail("no review from gutter for {s}", .{t.key}),
                else => boardFail(db, e, "ticket"),
            };
            if (r.unsent) fail("{s} has no session to send the review to; it is kept as a comment", .{t.key});
            return out(if (r.sent) "Sent the review to the session.\n" else "No comments; nothing sent.\n");
        }
        const port = review.startGutter(ctx, cfg, db, a, t) catch |e| switch (e) {
            error.GutterMissing => fail("{s}", .{review.not_installed}),
            else => fail("gutter didn't start", .{}),
        };
        return out(try std.fmt.allocPrint(a, "gutter's window is open (http://127.0.0.1:{d}); the review you submit goes to the session\n", .{port}));
    }
    if (std.mem.eql(u8, cmd, "testplan")) {
        args.only(&.{ "--json", "--format" }, ticket_usage);
        if (args.has("--format")) return out(review.format_help);
        const key = keyArg(pos, 0, env_key, "cl ticket testplan <key> [--json] | --format");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const plan = review.readTestPlan(a, t) orelse fail("{s} has no test plan", .{t.key});
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(plan, .{})}));
        var aw: std.Io.Writer.Allocating = .init(a);
        for (plan.steps, 1..) |st, i| try printStep(&aw.writer, st, i, plan.steps.len);
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "launch")) {
        args.only(&.{ "--stop", "--step" }, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket launch <key> [--step <n>] [--stop]", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        const step: ?usize = if (args.get("--step")) |v| std.fmt.parseInt(usize, v, 10) catch fail("--step takes a step number", .{}) else null;
        if (args.has("--stop")) return review.stopLaunch(ctx, a, t.key, step);
        const i = review.launch(ctx, db, a, t, step) catch |e| switch (e) {
            error.NoTestPlan => fail("{s} has no test plan", .{t.key}),
            error.NoLaunch => fail("{s}", .{if (step != null) "that step has no run: command" else "the test plan has no run: command"}),
            else => boardFail(db, e, "ticket"),
        };
        const name = try std.ascii.allocLowerString(a, t.key);
        return out(try std.fmt.allocPrint(a, "step {d} running in tmux session clrun_{s}_s{d} (tmux attach -t clrun_{s}_s{d})\n", .{ i, name, i, name, i }));
    }
    if (std.mem.eql(u8, cmd, "test")) {
        args.only(&.{}, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket test <key>");
        return walkTest(ctx, db, a, key);
    }
    if (std.mem.eql(u8, cmd, "cleanup")) {
        args.only(&.{"--branch"}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket cleanup <key> [--branch]", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        if (t.worktree.len == 0) fail("{s} has no worktree", .{t.key});
        const p = board.getProject(db, a, t.project) catch |e| boardFail(db, e, "project");
        worktree.remove(ctx, a, p.dir, .{ .path = t.worktree, .branch = t.branch }, args.has("--branch")) catch
            fail("cannot remove the worktree: {s}", .{worktree.lastError()});
        board.setSession(ctx, db, t.id, t.tmux, t.session_id, "", if (args.has("--branch")) "" else t.branch) catch |e| boardFail(db, e, "ticket");
        board.logEvent(ctx, db, t.id, "worktree removed", t.worktree) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "dispatch")) {
        args.only(&.{"--once"}, ticket_usage);
        if (args.has("--once")) {
            const n = dispatch.tick(ctx, cfg, db) catch |e| boardFail(db, e, "ticket");
            return out(try std.fmt.allocPrint(a, "started {d}\n", .{n}));
        }
        dispatch.loop(ctx, cfg, &logLine);
        return;
    }
    if (std.mem.eql(u8, cmd, "hook")) {
        if (pos.len != 1) return;
        var buf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().reader(ctx.io, &buf);
        const input = r.interface.allocRemaining(a, .limited(4 * 1024 * 1024)) catch "";
        dispatch.hook(ctx, cfg, pos[0], input);
        return;
    }
    if (std.mem.eql(u8, cmd, "help")) return out(ticket_usage);
    fail("unknown ticket command: {s}\n{s}", .{ cmd, ticket_usage });
}

/// `cl t test`: the test plan as a walk-through in the terminal.
fn walkTest(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    const plan = review.readTestPlan(a, t) orelse fail("{s} has no test plan", .{t.key});
    var in_buf: [4096]u8 = undefined;
    var in = std.Io.File.stdin().reader(ctx.io, &in_buf);
    const ask = struct {
        fn line(r: *std.Io.File.Reader, al: std.mem.Allocator, prompt: []const u8) ![]const u8 {
            try out(prompt);
            const l = r.interface.takeDelimiterExclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return "",
                else => return e,
            };
            r.interface.toss(1);
            return al.dupe(u8, std.mem.trim(u8, l, " \r"));
        }
    };
    try out(try std.fmt.allocPrint(a, "Testing {s}: {s}\n", .{ t.key, t.title }));
    var results: std.ArrayList(review.StepResult) = .empty;
    const yes = struct {
        fn of(s: []const u8) bool {
            return s.len == 0 or s[0] == 'y' or s[0] == 'Y';
        }
    }.of;
    for (plan.steps, 1..) |st, i| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try aw.writer.writeAll("\n");
        try printStep(&aw.writer, st, i, plan.steps.len);
        try out(aw.writer.buffered());
        // Like the board's buttons: nothing runs or opens without a yes.
        if (st.run.len > 0 and yes(try ask.line(&in, a, "  Run it? [Y/n] "))) {
            _ = review.launch(ctx, db, a, t, i) catch |e| fail("launch failed: {s}", .{@errorName(e)});
            const name = try std.ascii.allocLowerString(a, t.key);
            try out(try std.fmt.allocPrint(a, "  running in tmux session clrun_{s}_s{d}\n", .{ name, i }));
        }
        for (st.open) |url| if (yes(try ask.line(&in, a, try std.fmt.allocPrint(a, "  Open {s}? [Y/n] ", .{url})))) openUrl(ctx, url);
        var checks: std.ArrayList(review.Check) = .empty;
        for (st.checks) |c| {
            const ans = try ask.line(&in, a, try std.fmt.allocPrint(a, "  Check: {s}\n  Pass? [y/n] ", .{c}));
            const pass = ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y');
            const note = if (pass) "" else try ask.line(&in, a, "  What happened? ");
            try checks.append(a, .{ .text = c, .pass = pass, .note = note });
        }
        const comment = try ask.line(&in, a, "  Comment on this step? (Enter to skip) ");
        try results.append(a, .{ .title = st.title, .comment = comment, .checks = checks.items });
    }
    const note = try ask.line(&in, a, "\nAnything else for Claude? (Enter to skip) ");
    var finish: actions.Finish = .close;
    const cur = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    const res = review.recordResults(a, results.items, note) catch |e| boardFail(db, e, "ticket");
    // Comments with everything passing: send them, or finish without.
    var send = !res.passed;
    if (res.passed and res.commented) send = yes(try ask.line(&in, a, "\nAll passed, with comments. Send them to Claude for another round? [Y/n] "));
    if (res.passed and !send and cur.stage == .testing and (cur.branch.len > 0 or cur.change.len > 0)) {
        const main = worktree.mainBranch(ctx, a, (board.getProject(db, a, cur.project) catch |e| boardFail(db, e, "project")).dir);
        const ans = try ask.line(&in, a, try std.fmt.allocPrint(a, "\nAll passed. [m]erge {s} into {s}, open a [p]R, or just [c]lose? ", .{ if (cur.branch.len > 0) cur.branch else "its change", main }));
        if (ans.len > 0) finish = switch (std.ascii.toLower(ans[0])) {
            'm' => .merge,
            'p' => .pr,
            else => .close,
        };
    }
    const o = actions.testResults(ctx, db, a, key, results.items, note, send, false, finish) catch |e| boardFail(db, e, "ticket");
    try out(if (o.sent)
        "\nSent the results to Claude for another round.\n"
    else if (o.unsent)
        "\nIt has no session to send them to; they're kept as a comment.\n"
    else if (!o.approved)
        "\nAll passed; kept on the ticket (it isn't in testing, so nothing moved).\n"
    else if (finish != .close)
        "\nAll passed: Claude is finishing it; it goes to done when that's through.\n"
    else
        "\nAll passed: the ticket is done.\n");
}

/// A test plan step as text: `cl t testplan` and `cl t test`.
fn printStep(w: *std.Io.Writer, st: review.Step, i: usize, n: usize) !void {
    try w.print("Step {d}/{d}: {s}\n", .{ i, n, st.title });
    for (st.do) |x| try w.print("  {s}\n", .{x});
    if (st.run.len > 0) try w.print("  run: {s}\n", .{st.run});
    if (st.wait.len > 0) try w.print("  wait: {s}\n", .{st.wait});
    for (st.open) |x| try w.print("  open: {s}\n", .{x});
    for (st.checks) |x| try w.print("  [ ] {s}\n", .{x});
}

/// Open a URL in the browser, as the wizard does; say it when that fails.
fn openUrl(ctx: Ctx, url: []const u8) void {
    for ([_][]const u8{ "xdg-open", "open", "wslview" }) |cmd| {
        var child = std.process.spawn(ctx.io, .{ .argv = &.{ cmd, url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch continue;
        _ = child.wait(ctx.io) catch continue;
        return;
    }
    out("  couldn't open a browser; visit it by hand\n") catch {};
}

/// --merge, --pr, --tell <text> or --close (the default).
fn finishArg(args: Args) actions.Finish {
    const n = @as(u8, @intFromBool(args.has("--merge"))) + @intFromBool(args.has("--pr")) + @intFromBool(args.has("--tell")) + @intFromBool(args.has("--close"));
    if (n > 1) fail("pick one of --merge, --pr, --tell and --close", .{});
    if (args.get("--tell")) |text| return actions.Finish.told(text) orelse fail("--tell needs what Claude should do", .{});
    return if (args.has("--merge")) .merge else if (args.has("--pr")) .pr else .close;
}

/// Say so when a move left the ticket finishing rather than done.
fn finishNote(db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = board.getTicket(db, a, key) catch return;
    if (t.finishing.len == 0) return;
    try out(try std.fmt.allocPrint(a, "{s}: Claude is {s}; it moves to done when that's through.\n", .{
        t.key, finishingWhat(t.finishing),
    }));
}

fn finishingWhat(how: []const u8) []const u8 {
    if (std.mem.eql(u8, how, "pr")) return "opening a PR";
    if (std.mem.eql(u8, how, "after-merge")) return "doing the after-merge steps";
    if (std.mem.eql(u8, how, "tell")) return "doing what you told it";
    return "merging its branch";
}

fn logLine(text: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{text}) catch return;
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line) catch {};
}

/// The key at `pos[i]`, or $CL_TICKET when it is missing.
fn keyArg(pos: []const []const u8, i: usize, env_key: ?[]const u8, usage: []const u8) []const u8 {
    if (pos.len == i + 1) return pos[i];
    if (pos.len == i) if (env_key) |k| return k;
    fail("usage: {s}", .{usage});
}

fn looksLikeKey(s: []const u8) bool {
    const dash = std.mem.lastIndexOfScalar(u8, s, '-') orelse return false;
    return dash > 0 and isNumber(s[dash + 1 ..]);
}

fn isFlagWord(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    return s.len > 0;
}

fn flagList(a: std.mem.Allocator, flags: []const board.Flag) ![]const u8 {
    if (flags.len == 0) return "-";
    var out_buf: std.ArrayList(u8) = .empty;
    for (flags, 0..) |f, i| {
        if (i > 0) try out_buf.append(a, ',');
        try out_buf.appendSlice(a, f.kind);
    }
    return out_buf.items;
}

fn stamp(a: std.mem.Allocator, t: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(t, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
}

fn showText(ctx: Ctx, a: std.mem.Allocator, t: board.Ticket, subs: []const board.Ticket, cs: []const board.Comment, evs: []const board.Event) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("{s}  {s}\n", .{ t.key, t.title });
    try w.print("stage: {s}{s}{s}   round: {d}   project: {s}   mode: {s}{s}\n", .{
        @tagName(t.stage), if (t.plan) " (plan first" else "", if (!t.plan) "" else if (t.skill.len > 0) try std.fmt.allocPrint(a, ", {s})", .{t.skill}) else ")", t.round, t.project, @tagName(t.mode),
        if (t.mode == .queue and t.target.len > 0) try std.fmt.allocPrint(a, " in {s}", .{t.target}) else "",
    });
    if (t.parent.len > 0) try w.print("sub-ticket of: {s}\n", .{t.parent});
    if (t.tmux.len > 0) try w.print("session: {s}\n", .{t.tmux});
    if (t.killed) try w.print("session: killed; `cl ticket start {s}` restarts it\n", .{t.key});
    if (t.custom_close.len > 0) try w.print("custom close: {s}\n", .{t.custom_close});
    if (t.finishing.len > 0) try w.print("finishing: {s} (Claude is {s}; it goes to done after)\n", .{ t.finishing, finishingWhat(t.finishing) });
    if (t.worktree.len > 0) try w.print("worktree: {s}   branch: {s}\n", .{ try ctx.shortenHomeIn(a, t.worktree), t.branch });
    if (t.change.len > 0) try w.print("change: {s}{s}{s}\n", .{ t.change[0..@min(t.change.len, 12)], if (t.branch.len > 0) "   bookmark: " else "", t.branch });
    for (t.flags) |f| try w.print("flag: {s} ({s}, {s}){s}{s}\n", .{ f.kind, f.source, try stamp(a, f.at), if (f.detail.len > 0) ": " else "", f.detail });
    if (t.body.len > 0) try w.print("\n{s}\n", .{t.body});
    if (subs.len > 0) {
        try w.writeAll("\nsub-tickets:\n");
        for (subs) |c| try w.print("  {s}\t{s}\t{s}\t{s}\n", .{ c.key, @tagName(c.stage), try flagList(a, c.flags), c.title });
    }
    if (cs.len > 0) {
        try w.writeAll("\ncomments:\n");
        for (cs) |c| try w.print("  {s} · {s}{s}\n    {s}\n", .{ c.author, try stamp(a, c.at), if (c.sent) " · sent" else "", c.body });
    }
    if (evs.len > 0) {
        try w.writeAll("\nactivity:\n");
        for (evs) |e| try w.print("  {s}  {s}{s}{s}\n", .{ try stamp(a, e.at), e.kind, if (e.detail.len > 0) " " else "", e.detail });
    }
    return aw.writer.buffered();
}

test looksLikeKey {
    try std.testing.expect(looksLikeKey("QA-12"));
    try std.testing.expect(!looksLikeKey("needs-review"));
}
