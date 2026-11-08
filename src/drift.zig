//! Early warning that a ticket will conflict with trunk (CL-137).
//!
//! Merges only find conflicts at the end (the `conflict` flag, when Done
//! merges a change). So the dispatcher test-rebases each open ticket's jj
//! change onto its target (trunk, or its `onto` branch) once a minute, on a
//! thread of its own (`loop`), whenever the target or the change moved since
//! the last test:
//!
//! 1. A cheap first pass: do the files the change touches overlap the files
//!    the target changed since the change's parent? No overlap, no conflict.
//! 2. Otherwise a real three-way merge with `git merge-tree` (the change's
//!    parent as the base), which writes nothing but objects to the store: no
//!    working copy, bookmark or jj operation is touched, so a session working
//!    in the change never notices. Rename detection is off, as in jj's own
//!    rebase: a file trunk renamed and the ticket edited conflicts there.
//!
//! When the target moves, each ticket's workspace is snapshotted first (a
//! plain `jj log` there, which records a snapshot operation when files
//! changed, as any jj command would), so work not yet seen by jj counts;
//! otherwise everything is read as jj last recorded it
//! (`--ignore-working-copy`). Every command has a deadline, so a jj waiting
//! on a lock can't hold the pass up for long.
//!
//! A ticket whose result can't be told (its target or change gone, a merge
//! change, a failed command) loses its warning rather than keeping a stale one.
//!
//! A ticket that would conflict gets `Ticket.drift` (the board's "Will
//! conflict" pill, and `cl ticket show`); nothing is typed into its session.
//! Rebase now (`cl ticket rebase`) asks the ticket's Claude to rebase onto
//! the target and settle the conflicts, only while its session is idle on
//! that ticket. Git branches are left out: they have no change to test.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const worktree = @import("worktree.zig");
const actions = @import("actions.zig");
const dispatch = @import("dispatch.zig");

/// Seconds between passes.
pub const interval = 60;

/// The longest one jj or git command may take, in seconds.
const command_timeout = 30;

/// Each project target's commit at the last pass ("<project> <bookmark>" ->
/// commit), to tell when it moved. It lives as long as the process, so it
/// isn't on ctx.gpa (whose leak check would report it at exit).
var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
const seen_alloc = std.heap.smp_allocator;

/// Run a pass every `interval` until killed: the dispatcher starts it on a
/// thread of its own, so a slow jj never holds up starting tickets.
pub fn loop(ctx: Ctx, cfg: config.Config) void {
    while (true) : (ctx.sleepMs(interval * 1000)) once(ctx, cfg);
}

/// One pass, on a board connection of its own.
pub fn once(ctx: Ctx, cfg: config.Config) void {
    const db = board.open(ctx, cfg) catch return;
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    checkAll(ctx, db, arena_state.allocator()) catch {};
}

/// Test every open ticket with a jj change of its own against its target.
pub fn checkAll(ctx: Ctx, db: board.Db, a: std.mem.Allocator) !void {
    try board.pruneDrift(db);
    var by_project: std.StringArrayHashMapUnmanaged(std.ArrayList(board.Ticket)) = .empty;
    for (try board.listTickets(db, a, .{ .done = false })) |t| {
        if (t.change.len == 0 or t.umbrella) continue;
        const gop = try by_project.getOrPut(a, t.project);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, t);
    }
    var it = by_project.iterator();
    while (it.next()) |e| {
        const p = board.getProject(db, a, e.key_ptr.*) catch continue;
        checkProject(ctx, db, a, p, e.value_ptr.items) catch {};
    }
}

fn checkProject(ctx: Ctx, db: board.Db, a: std.mem.Allocator, p: board.Project, tickets: []const board.Ticket) !void {
    if (!p.repo) return;
    if ((worktree.detect(ctx, a, p.dir) catch return) != .jj) return;
    const trunk = trunkOf(ctx, a, p.dir) orelse "";
    // Each target's commit, read once.
    var commits: std.StringHashMapUnmanaged([]const u8) = .empty;
    var moved = false;
    for (tickets) |t| {
        const tgt = if (t.onto.len > 0) t.onto else trunk;
        if (tgt.len == 0 or commits.contains(tgt)) continue;
        const c = commitOf(ctx, a, p.dir, tgt) orelse continue; // its tickets lose their warning below
        try commits.put(a, tgt, c);
        const k = try std.fmt.allocPrint(a, "{s} {s}", .{ p.name, tgt });
        if (seen.get(k)) |old| if (std.mem.eql(u8, old, c)) continue;
        moved = true;
        const gop = try seen.getOrPut(seen_alloc, k);
        if (gop.found_existing) seen_alloc.free(gop.value_ptr.*) else gop.key_ptr.* = try seen_alloc.dupe(u8, k);
        gop.value_ptr.* = try seen_alloc.dupe(u8, c);
    }
    // The target moved: let jj see what each workspace has now.
    if (moved) {
        snapshot(ctx, a, p.dir);
        for (tickets) |t| if (t.worktree.len > 0) snapshot(ctx, a, t.worktree);
    }
    var git_dir: ?[]const u8 = null;
    for (tickets) |t| {
        const tgt = if (t.onto.len > 0) t.onto else trunk;
        // What can't be told now loses its warning: an old one would mislead.
        const target_c = commits.get(tgt) orelse {
            try forget(ctx, db, t.id, tgt);
            continue;
        };
        const s = stack(ctx, a, p.dir, t.change) orelse {
            try forget(ctx, db, t.id, tgt);
            continue;
        };
        const key = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ target_c, s.base, s.tip });
        const prev = try board.driftRow(db, a, t.id);
        if (prev) |r| if (std.mem.eql(u8, r.key, key)) continue;
        // Its own conflicts are the conflict flag's business (a merge that
        // stopped halfway): nothing to add.
        const found: ?[]const u8 = if (s.conflicted or std.mem.eql(u8, s.base, target_c)) "" else blk: {
            if (git_dir == null) git_dir = gitDir(ctx, a, p.dir);
            break :blk if (git_dir) |g| conflicts(ctx, a, g, s.base, target_c, s.tip) else null;
        };
        const files = found orelse {
            try forget(ctx, db, t.id, tgt);
            continue;
        };
        try board.setDrift(db, t.id, key, files, tgt, ctx.nowSeconds());
        const was = if (prev) |r| r.files.len > 0 else false;
        if (files.len > 0 and !(prev != null and std.mem.eql(u8, prev.?.files, files))) {
            try board.logEvent(ctx, db, t.id, "will conflict", try std.fmt.allocPrint(a, "with {s}: {s}", .{ tgt, try oneLine(a, files) }));
        } else if (files.len == 0 and was) {
            try board.logEvent(ctx, db, t.id, "no longer conflicts", tgt);
        }
    }
}

/// Drop a ticket's result (it is tested again at the next pass), saying so
/// when that took a warning away.
fn forget(ctx: Ctx, db: board.Db, id: i64, tgt: []const u8) !void {
    if (try board.dropDrift(db, id)) try board.logEvent(ctx, db, id, "conflict check unclear", if (tgt.len > 0) tgt else "no target");
}

/// The files, one per line, as "a, b, c".
pub fn oneLine(a: std.mem.Allocator, files: []const u8) ![]const u8 {
    return std.mem.join(a, ", ", try lines(a, files));
}

fn lines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| {
        const s = std.mem.trim(u8, l, " \r");
        if (s.len > 0) try out.append(a, s);
    }
    return out.items;
}

const Stack = struct {
    /// The commit the change sits on.
    base: []const u8,
    /// The last commit of its work: the change, or the last change on top
    /// of it that holds anything (as `worktree.mergeChange` takes it).
    tip: []const u8,
    /// jj has conflicts recorded in its tip already.
    conflicted: bool,
};

/// Where a ticket's change sits and ends; null when it can't tell (gone,
/// divergent, or a merge with several parents).
fn stack(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, change: []const u8) ?Stack {
    const one = std.fmt.allocPrint(a, "present({s})", .{change}) catch return null;
    // "<commit> <parents> c?": the change, then its work's heads.
    const tmpl = "commit_id ++ \" \" ++ parents.map(|c| c.commit_id()).join(\",\") ++ if(conflict, \" c\") ++ \"\\n\"";
    const head = jj(ctx, a, dir, &.{ "log", "--no-graph", "-r", one, "-T", tmpl }) orelse return null;
    const ls = lines(a, head) catch return null;
    if (ls.len != 1) return null;
    var f = std.mem.tokenizeScalar(u8, ls[0], ' ');
    const commit = f.next() orelse return null;
    const base = f.next() orelse return null;
    if (std.mem.indexOfScalar(u8, base, ',') != null) return null;
    var tip: []const u8 = commit;
    var conflicted = f.next() != null;
    const revs = std.fmt.allocPrint(a, "heads({s}:: ~ empty())", .{change}) catch return null;
    const out = jj(ctx, a, dir, &.{ "log", "--no-graph", "-r", revs, "-T", tmpl }) orelse return null;
    const heads = lines(a, out) catch return null;
    // One head: that is where its work ends, and only its own conflicts
    // count (not a stacked change's or a side branch's).
    if (heads.len == 1) {
        var h = std.mem.tokenizeScalar(u8, heads[0], ' ');
        tip = h.next() orelse return null;
        _ = h.next();
        conflicted = h.next() != null;
    }
    return .{ .base = base, .tip = tip, .conflicted = conflicted };
}

/// The trunk bookmark (as `worktree.trunkBookmark` finds it), read without
/// snapshotting the project's checkout.
fn trunkOf(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    const b = worktree.mainBranch(ctx, a, dir);
    if (!std.mem.eql(u8, b, "trunk()")) return b;
    const out = jj(ctx, a, dir, &.{ "log", "--no-graph", "-r", "trunk()", "-T", "local_bookmarks.map(|b| b.name()).join(\"\\n\")" }) orelse return null;
    var it = std.mem.tokenizeAny(u8, out, " \n");
    return it.next();
}

/// Let jj record what a workspace's files hold now (a plain `jj log` there).
fn snapshot(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) void {
    _ = exec(ctx, a, &.{ "jj", "-R", dir, "log", "--no-graph", "-r", "@", "-T", "change_id" });
}

/// The commit a bookmark points at.
fn commitOf(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, bookmark: []const u8) ?[]const u8 {
    const revs = std.fmt.allocPrint(a, "present(bookmarks(exact:\"{s}\"))", .{bookmark}) catch return null;
    const out = jj(ctx, a, dir, &.{ "log", "--no-graph", "-r", revs, "-T", "commit_id ++ \"\\n\"" }) orelse return null;
    const ls = lines(a, out) catch return null;
    return if (ls.len == 1) ls[0] else null;
}

/// The git repo jj keeps its commits in.
fn gitDir(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    const out = jj(ctx, a, dir, &.{ "git", "root" }) orelse return null;
    const d = std.mem.trim(u8, out, " \r\n");
    return if (d.len > 0) d else null;
}

/// The files rebasing `tip` (which sits on `base`) onto `target` would
/// conflict in, one per line; "" for none, null when it can't tell.
pub fn conflicts(ctx: Ctx, a: std.mem.Allocator, git_dir: []const u8, base: []const u8, target: []const u8, tip: []const u8) ?[]const u8 {
    // First pass: no file both sides touched, no conflict.
    const ours = git(ctx, a, git_dir, &.{ "diff", "--name-only", "--no-renames", base, tip }) orelse return null;
    if (ours.code != 0) return null;
    const theirs = git(ctx, a, git_dir, &.{ "diff", "--name-only", "--no-renames", base, target }) orelse return null;
    if (theirs.code != 0) return null;
    if (!overlap(a, ours.out, theirs.out)) return "";
    // Then the merge itself, written nowhere but the object store. Renames
    // aren't followed: jj's rebase merges path by path, so an edit to a file
    // the target renamed conflicts there, and must here too.
    const mb = std.fmt.allocPrint(a, "--merge-base={s}", .{base}) catch return null;
    const m = git(ctx, a, git_dir, &.{ "-c", "merge.renames=false", "merge-tree", "--write-tree", "--name-only", "--no-messages", mb, target, tip }) orelse return null;
    return switch (m.code) {
        0 => "",
        1 => mergeTreeFiles(a, m.out),
        else => null,
    };
}

/// Two `--name-only` lists share a file.
fn overlap(a: std.mem.Allocator, x: []const u8, y: []const u8) bool {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    for (lines(a, x) catch return true) |l| set.put(a, l, {}) catch return true;
    for (lines(a, y) catch return true) |l| if (set.contains(l)) return true;
    return false;
}

/// `git merge-tree --name-only --no-messages` with conflicts: the tree's id,
/// then the conflicted files (one per line).
fn mergeTreeFiles(a: std.mem.Allocator, out: []const u8) []const u8 {
    const ls = lines(a, out) catch return "conflicts";
    if (ls.len < 2) return "conflicts";
    return std.mem.join(a, "\n", ls[1..]) catch "conflicts";
}

fn jj(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "jj", "-R", dir, "--ignore-working-copy" }) catch return null;
    argv.appendSlice(a, args) catch return null;
    const r = exec(ctx, a, argv.items) orelse return null;
    return if (r.code == 0) r.out else null;
}

fn git(ctx: Ctx, a: std.mem.Allocator, git_dir: []const u8, args: []const []const u8) ?Ran {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "git", "--git-dir", git_dir }) catch return null;
    argv.appendSlice(a, args) catch return null;
    return exec(ctx, a, argv.items);
}

const Ran = struct { code: u8, out: []const u8 };

/// Run a command to its end or `command_timeout` (then it is killed: null).
fn exec(ctx: Ctx, a: std.mem.Allocator, argv: []const []const u8) ?Ran {
    const limit: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(command_timeout), .clock = .awake } };
    const res = std.process.run(a, ctx.io, .{ .argv = argv, .timeout = limit.toDeadline(ctx.io) }) catch return null;
    return switch (res.term) {
        .exited => |c| .{ .code = c, .out = res.stdout },
        else => null,
    };
}

pub const Error = error{
    /// Its last test rebase found nothing that would conflict.
    NoDrift,
    /// Its session is on another ticket (a shared queue session).
    SessionElsewhere,
    /// Claude is working in its session or waiting on you.
    Working,
};

/// Rebase now: ask the ticket's Claude to rebase its change onto its target
/// and settle the conflicts. Only into an idle session that is on this
/// ticket, so nothing is cut off or answered by accident. A ticket in Review
/// or Testing goes back to Running (a sent comment), and is told to say done
/// again after.
pub fn rebase(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = try board.getTicket(db, a, key);
    const d = t.drift orelse return error.NoDrift;
    const s = actions.liveSession(ctx, t) orelse return error.NoSession;
    if ((try board.sessionTicket(db, s)) != t.id) return error.SessionElsewhere;
    const view = try dispatch.View.read(ctx, a, cfg);
    if (!view.idle(ctx, s)) return error.Working;
    _ = try actions.comment(ctx, db, a, t.key, "you", try rebaseText(a, t, d), true);
    try board.logEvent(ctx, db, t.id, "rebase asked", d.onto);
}

pub fn rebaseText(a: std.mem.Allocator, t: board.Ticket, d: board.Drift) ![]const u8 {
    const then = switch (t.stage) {
        .review, .testing => try std.fmt.allocPrint(a, "Then run `cl ticket done {s} --summary \"...\"` again (with a test plan if there is something new to try).", .{t.key}),
        else => "Then carry on with the ticket.",
    };
    return std.fmt.allocPrint(a, "{0s} has moved on since this ticket's change was made, and rebasing the change onto it would conflict in:\n{1s}\nRebase it now: `jj rebase -b {2s} -d '\"{0s}\"'`. Then settle the conflicts jj records in the change: edit the conflict markers out, keeping what both sides meant (`jj resolve --list` shows what's left), and check it still builds and its tests pass. If one can't be settled with confidence, ask me. {3s}", .{ d.onto, std.mem.trim(u8, d.files, "\n"), t.change, then });
}

test "overlap and merge-tree output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(overlap(a, "a.zig\nb.zig\n", "c.zig\nb.zig\n"));
    try std.testing.expect(!overlap(a, "a.zig\n", "c.zig\n"));
    try std.testing.expect(!overlap(a, "", "c.zig\n"));
    try std.testing.expectEqualStrings("src/a.zig\nb.md", mergeTreeFiles(a, "0123abcd\nsrc/a.zig\nb.md\n"));
    try std.testing.expectEqualStrings("src/a.zig, b.md", try oneLine(a, "src/a.zig\nb.md\n"));
}

test "a ticket's change is tested against trunk as trunk moves" {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = exec(ctx, a, &.{ "jj", "--version" }) orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const sh = struct {
        fn run(c: Ctx, al: std.mem.Allocator, argv: []const []const u8) !void {
            const r = exec(c, al, argv) orelse return error.SkipZigTest;
            if (r.code != 0) return error.CommandFailed;
        }
    }.run;
    sh(ctx, a, &.{ "git", "init", "-q", "-b", "master", repo }) catch return error.SkipZigTest;
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "1\n2\n3\n" });
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "b.txt", .data = "b\n" });
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "old.txt", .data = "1\n2\n3\n4\n5\n6\n7\n8\n" });
    try sh(ctx, a, &.{ "git", "-C", repo, "add", "." });
    try sh(ctx, a, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" });
    try std.testing.expect(worktree.ensureJj(ctx, a, repo));
    const trunk = worktree.trunkBookmark(ctx, a, repo).?;
    try std.testing.expectEqualStrings(trunk, trunkOf(ctx, a, repo).?);

    // T-1 edits line 2 of a.txt; T-2 edits b.txt only; T-4 edits old.txt.
    const one = try worktree.newChange(ctx, a, repo, trunk, "T-1: one", "t-1");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "1\none\n3\n" });
    const two = try worktree.newChange(ctx, a, repo, trunk, "T-2: two", "t-2");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "b.txt", .data = "two\n" });
    const four = try worktree.newChange(ctx, a, repo, trunk, "T-4: four", "t-4");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "old.txt", .data = "1\n2\n3\n4\nfour\n6\n7\n8\n" });
    // Trunk moves: another change edits the same line of a.txt, renames
    // old.txt, and lands.
    const three = try worktree.newChange(ctx, a, repo, trunk, "T-3: three", "t-3");
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "1\nthree\n3\n" });
    try tmp.dir.rename("old.txt", tmp.dir, "new.txt", ctx.io);
    const m = try worktree.mergeChange(ctx, a, repo, "", three.id, three.bookmark, trunk);
    try std.testing.expect(m.merged);
    _ = try worktree.newChange(ctx, a, repo, trunk, "idle", "idle");

    const target = commitOf(ctx, a, repo, trunk).?;
    const gd = gitDir(ctx, a, repo).?;
    const s1 = stack(ctx, a, repo, one.id).?;
    try std.testing.expect(!s1.conflicted);
    try std.testing.expectEqualStrings("a.txt", conflicts(ctx, a, gd, s1.base, target, s1.tip).?);
    const s2 = stack(ctx, a, repo, two.id).?;
    try std.testing.expectEqualStrings("", conflicts(ctx, a, gd, s2.base, target, s2.tip).?);
    // A file trunk renamed and the ticket edited: jj doesn't follow renames,
    // so it conflicts at the merge, and must be warned about.
    const s4 = stack(ctx, a, repo, four.id).?;
    try std.testing.expectEqualStrings("old.txt", conflicts(ctx, a, gd, s4.base, target, s4.tip).?);
    // Nothing was rewritten: T-1 still sits where it did, with no conflicts.
    try std.testing.expectEqualStrings(s1.tip, stack(ctx, a, repo, one.id).?.tip);
    try std.testing.expectEqual(worktree.ChangeState.open, worktree.changeState(ctx, a, repo, one.id, trunk));

    // On the board: T-1 and T-4 get drift, T-2 doesn't.
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = repo });
    const T = struct {
        fn ticket(c: Ctx, d: board.Db, al: std.mem.Allocator, title: []const u8, ch: worktree.Change) ![]const u8 {
            const k = try board.createTicket(c, d, al, .{ .project = "qa", .title = title, .stage = .running });
            try board.setChange(d, (try board.getTicket(d, al, k)).id, ch.id, ch.bookmark);
            return k;
        }
        fn hasEvent(d: board.Db, al: std.mem.Allocator, id: i64, kind: []const u8) !bool {
            for (try board.events(d, al, id)) |e| if (std.mem.eql(u8, e.kind, kind)) return true;
            return false;
        }
    };
    const k1 = try T.ticket(ctx, db, a, "one", one);
    const k2 = try T.ticket(ctx, db, a, "two", two);
    const k4 = try T.ticket(ctx, db, a, "four", four);
    try checkAll(ctx, db, a);
    const t1 = try board.getTicket(db, a, k1);
    try std.testing.expectEqualStrings("a.txt", t1.drift.?.files);
    try std.testing.expectEqualStrings("master", t1.drift.?.onto);
    try std.testing.expect(try T.hasEvent(db, a, t1.id, "will conflict"));
    try std.testing.expect((try board.getTicket(db, a, k2)).drift == null);
    try std.testing.expectEqualStrings("old.txt", (try board.getTicket(db, a, k4)).drift.?.files);
    try std.testing.expect(std.mem.indexOf(u8, try rebaseText(a, t1, t1.drift.?), "jj rebase -b ") != null);
    try std.testing.expect(std.mem.indexOf(u8, try rebaseText(a, t1, t1.drift.?), "-d '\"master\"'") != null);

    // T-1 rebases and settles it: the warning goes at the next pass.
    try sh(ctx, a, &.{ "jj", "-R", repo, "rebase", "-b", one.id, "-d", trunk });
    try sh(ctx, a, &.{ "jj", "-R", repo, "edit", one.id });
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "a.txt", .data = "1\none and three\n3\n" });
    _ = try worktree.workingChange(ctx, a, repo);
    try checkAll(ctx, db, a);
    try std.testing.expect((try board.getTicket(db, a, k1)).drift == null);
    try std.testing.expect(try T.hasEvent(db, a, t1.id, "no longer conflicts"));

    // T-4's target can't be found any more: its old warning goes rather
    // than staying up for good.
    const t4 = try board.getTicket(db, a, k4);
    try db.exec("UPDATE tickets SET onto = 'gone' WHERE id = ?1", .{t4.id});
    try checkAll(ctx, db, a);
    try std.testing.expect((try board.getTicket(db, a, k4)).drift == null);
    try std.testing.expect(try T.hasEvent(db, a, t4.id, "conflict check unclear"));

    // Done: the warning stops showing at once, and the next pass drops it.
    try db.exec("UPDATE tickets SET onto = '' WHERE id = ?1", .{t4.id});
    try checkAll(ctx, db, a);
    try std.testing.expect((try board.getTicket(db, a, k4)).drift != null);
    try board.move(ctx, db, a, k4, .done);
    try std.testing.expect((try board.getTicket(db, a, k4)).drift == null);
    try checkAll(ctx, db, a);
    try std.testing.expect(try board.driftRow(db, a, t4.id) == null);
}

test "Rebase now goes only into an idle session that is on the ticket" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const probe = std.process.run(gpa, io, .{ .argv = &.{ "tmux", "-V" } }) catch return error.SkipZigTest;
    gpa.free(probe.stdout);
    gpa.free(probe.stderr);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A tmux server of the test's own, named on every call; never the real one.
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const sock = try std.fmt.allocPrint(a, "/tmp/cl-test-tmux-{x}", .{rnd});
    defer std.Io.Dir.deleteFileAbsolute(io, sock) catch {};
    defer if (std.process.run(gpa, io, .{ .argv = &.{ "tmux", "-S", sock, "kill-server" } })) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {};
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const ctx: Ctx = .{ .io = io, .gpa = gpa, .perm = a, .env = &env, .home = "/tmp", .tmux_socket = sock };
    const tmux = @import("tmux.zig");
    gpa.free(try tmux.run(ctx, &.{ "new-session", "-d", "-s", "cl_qa", "sleep", "600" }));
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };

    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x/qa" });
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Drifted", .stage = .review });
    const id = (try board.getTicket(db, a, k)).id;
    try board.setChange(db, id, "zzzz", "qa-1");

    // Nothing found yet: nothing to ask.
    try std.testing.expectError(error.NoDrift, rebase(ctx, cfg, db, a, k));
    try board.setDrift(db, id, "key", "a.txt\n", "master", 1);
    // No session.
    try std.testing.expectError(error.NoSession, rebase(ctx, cfg, db, a, k));
    // Its session, but Claude isn't idle there (the pane runs something else).
    try board.setSession(ctx, db, id, "cl_qa", "", "", "qa-1");
    try std.testing.expectError(error.Working, rebase(ctx, cfg, db, a, k));
    // A shared session another ticket is in progress in now.
    const other = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Next", .stage = .running });
    try board.setSession(ctx, db, (try board.getTicket(db, a, other)).id, "cl_qa", "", "", "");
    try std.testing.expectError(error.SessionElsewhere, rebase(ctx, cfg, db, a, k));
    // Nothing was typed or sent back: it stays in Review, round 1.
    const t = try board.getTicket(db, a, k);
    try std.testing.expectEqual(board.Stage.review, t.stage);
    try std.testing.expectEqual(@as(i64, 1), t.round);
    // Its text says to finish again from Review.
    try std.testing.expect(std.mem.indexOf(u8, try rebaseText(a, t, t.drift.?), "cl ticket done ") != null);
    // Done: no warning, nothing to ask.
    try board.move(ctx, db, a, k, .done);
    try std.testing.expectError(error.NoDrift, rebase(ctx, cfg, db, a, k));
}
