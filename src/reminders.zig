//! Todos' reminders and due dates, the dispatcher's part (each pass, next to
//! park.checkDue; a `cl web` that doesn't dispatch runs `loop` instead).
//!
//! - A reminder whose time has come (`Ticket.remind_at`) flags the todo
//!   `reminder` once, saying when it was for, and is then cleared: it's
//!   informational, so Dismiss (or Hide) takes it away.
//! - A due todo is flagged `due` from the morning of its due day
//!   (`board.morning`), or at once for a time before that or a date gone by.
//!   `due` waits on the human: it goes when the todo is Done or its due date
//!   moves (board.updateTicket). What it says changes each day ("due today",
//!   then "overdue since Mon 2 Nov (1 day)"), and a flag that says something
//!   new comes out of hiding (board.setFlagId), so Hide means "not today".
//!
//! Both put the todo in Needs You's Today group, even while it's parked.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const when = @import("when.zig");

pub fn checkDue(ctx: Ctx, cfg: config.Config, db: board.Db) !void {
    return checkAt(ctx, db, ctx.nowSeconds(), cfg.board.morning);
}

/// `checkDue` at `now` (unix seconds), with the morning at `morning`
/// minutes after midnight.
pub fn checkAt(ctx: Ctx, db: board.Db, now: i64, morning: i64) !void {
    // Cheap enough to ask every pass: no open todo with a date, nothing to do.
    if ((try db.int("SELECT 1 FROM tickets WHERE (due_at != 0 OR remind_at != 0) AND todo != 0 AND stage != 'done' LIMIT 1", .{})) == null) return;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const Row = struct { id: i64, at: i64, has_time: bool = false, detail: ?[]const u8 = null };
    var reminders: std.ArrayList(Row) = .empty;
    {
        var st = try db.query("SELECT id, remind_at FROM tickets WHERE remind_at != 0 AND remind_at <= ?1 AND todo != 0 AND stage != 'done'", .{now});
        defer st.finalize();
        while (try st.step()) try reminders.append(a, .{ .id = st.int(0), .at = st.int(1) });
    }
    for (reminders.items) |r| {
        // One shot, even with two dispatchers at it.
        try db.exec("UPDATE tickets SET remind_at = 0 WHERE id = ?1 AND remind_at = ?2", .{ r.id, r.at });
        if (db.changes() == 0) continue;
        const said = try when.format(db, a, now, .{ .at = r.at, .has_time = true });
        try board.setFlagId(ctx, db, r.id, board.flag_reminder, "auto", try std.fmt.allocPrint(a, "reminder for {s}", .{said}));
    }

    // Due: by now, or later today once the morning has come.
    const tomorrow = try when.dayStart(db, now, 1);
    const after_morning = now >= try when.morningOf(db, now, morning);
    const due_from = if (after_morning) tomorrow else now + 1;
    const Due = struct { row: Row, flag: i64 = 0 };
    var due: std.ArrayList(Due) = .empty;
    {
        var st = try db.query(
            \\SELECT t.id, t.due_at, t.due_time, f.detail, f.id FROM tickets t
            \\  LEFT JOIN flags f ON f.ticket = t.id AND f.kind = ?2 AND f.cleared IS NULL
            \\WHERE t.due_at != 0 AND t.due_at < ?1 AND t.todo != 0 AND t.stage != 'done'
        , .{ due_from, board.flag_due });
        defer st.finalize();
        while (try st.step()) try due.append(a, .{
            .row = .{ .id = st.int(0), .at = st.int(1), .has_time = st.int(2) != 0, .detail = if (st.isNull(3)) null else try st.dupe(a, 3) },
            .flag = if (st.isNull(4)) 0 else st.int(4),
        });
    }
    for (due.items) |d| {
        const r = d.row;
        if (r.detail) |old| {
            // Between midnight and the morning a raised one stays as it
            // is: its new day starts in the morning, so one hidden last
            // night stays hidden until then.
            if (!after_morning) continue;
            const text = try when.dueText(db, a, now, .{ .at = r.at, .has_time = r.has_time });
            if (std.mem.eql(u8, old, text)) continue;
            // A new day: a new flag rather than new words on the old one, so
            // it comes back as new to everything that follows Needs You
            // (cl window's attention, push), not only out of hiding. Only
            // the dispatcher that cleared it raises the next one.
            try db.exec("UPDATE flags SET cleared = ?2 WHERE id = ?1 AND cleared IS NULL", .{ d.flag, now });
            if (db.changes() == 0) continue;
            board.setFlagId(ctx, db, r.id, board.flag_due, "auto", text) catch continue;
            continue;
        }
        const text = try when.dueText(db, a, now, .{ .at = r.at, .has_time = r.has_time });
        // Another dispatcher may have raised it meanwhile: one open flag per
        // kind (flags_active), so this one's insert fails and it's left be.
        board.setFlagId(ctx, db, r.id, board.flag_due, "auto", text) catch continue;
    }
}

/// For a `cl web` that doesn't run the dispatcher (a second server, or
/// board.dispatch = false): reminders still come up.
pub fn loop(ctx: Ctx, cfg: config.Config) void {
    while (true) : (ctx.sleepMs(30_000)) {
        const db = board.open(ctx, cfg) catch continue;
        defer db.close();
        checkDue(ctx, cfg, db) catch {};
    }
}

// ---- tests ----

const testing = std.testing;

fn testCtx() Ctx {
    return .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = undefined, .home = "/tmp" };
}

fn flagOf(t: board.Ticket, kind: []const u8) ?board.Flag {
    for (t.flags) |f| if (std.mem.eql(u8, f.kind, kind)) return f;
    return null;
}

test "a reminder comes up once, then it's gone; a snooze sets the next one" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    when.testZone();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    const now = when.test_now; // Wed 4 Nov 10:00
    const k = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Reply to Josh", .todo = true, .remind = now + 3600 });
    try checkAt(ctx, db, now, when.default_morning);
    try testing.expectEqual(@as(usize, 0), (try board.getTicket(db, a, k)).flags.len);
    try checkAt(ctx, db, now + 3600, when.default_morning);
    var t = try board.getTicket(db, a, k);
    try testing.expectEqual(@as(i64, 0), t.remind_at);
    try testing.expectEqualStrings("reminder for Wed 4 Nov 11:00", flagOf(t, board.flag_reminder).?.detail);
    // It's in Needs You, and can be dismissed (seen it).
    try testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);
    try testing.expect(!board.waitingFlag(board.flag_reminder));
    // Once only.
    try board.clearFlag(ctx, db, a, k, board.flag_reminder);
    try checkAt(ctx, db, now + 7200, when.default_morning);
    try testing.expectEqual(@as(usize, 0), (try board.getTicket(db, a, k)).flags.len);
    // Snoozed: a new one, and the one up now goes.
    try board.updateTicket(ctx, db, a, k, .{ .remind = now });
    try checkAt(ctx, db, now, when.default_morning);
    try testing.expect(flagOf(try board.getTicket(db, a, k), board.flag_reminder) != null);
    try board.snooze(ctx, db, a, k, now + 86400, "tomorrow");
    t = try board.getTicket(db, a, k);
    try testing.expectEqual(@as(usize, 0), t.flags.len);
    try testing.expectEqual(now + 86400, t.remind_at);
    // Done: nothing left to remind of.
    try board.move(ctx, db, a, k, .done);
    try testing.expectEqual(@as(i64, 0), (try board.getTicket(db, a, k)).remind_at);
    // Only todos have dates.
    try testing.expectError(error.BadInput, board.createTicket(ctx, db, a, .{ .project = "me", .title = "x", .remind = now }));
    try testing.expectError(error.BadInput, board.snooze(ctx, db, a, k, now + 60, "soon"));
}

test "due: from the morning of its day, again each day it's overdue, gone when done or moved later" {
    const ctx = testCtx();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    when.testZone();
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "me", .dir = "/x/me", .repo = false });
    const now = when.test_now; // Wed 4 Nov 10:00
    const m = when.default_morning;
    const thu = try when.parse(db, now, m, "tomorrow");
    const thu3pm = try when.parse(db, now, m, "tomorrow 15:00");
    const k = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "1:1 prep", .todo = true, .due = thu });
    const k2 = try board.createTicket(ctx, db, a, .{ .project = "me", .title = "Budget", .todo = true, .due = thu3pm });
    // Not yet: Thursday 07:00 is before the morning.
    try checkAt(ctx, db, thu.at - 3600, m);
    try testing.expectEqual(@as(usize, 0), (try board.listTickets(db, a, .{ .needs = true })).len);
    // Thursday morning: both, the one at 15:00 too.
    try checkAt(ctx, db, thu.at, m);
    try testing.expectEqualStrings("due today", flagOf(try board.getTicket(db, a, k), board.flag_due).?.detail);
    try testing.expectEqualStrings("due today 15:00", flagOf(try board.getTicket(db, a, k2), board.flag_due).?.detail);
    // Hidden (not today), it stays hidden today...
    _ = try board.hideNeeds(ctx, db, a, k, true);
    try checkAt(ctx, db, thu.at + 5 * 3600, m);
    try testing.expect(flagOf(try board.getTicket(db, a, k), board.flag_due).?.hidden);
    // ...and through the night (Fri 00:30)...
    const first_id = try db.int("SELECT id FROM flags WHERE ticket = (SELECT id FROM tickets WHERE key = ?1) AND kind = 'due' AND cleared IS NULL", .{k});
    try checkAt(ctx, db, thu.at + 86400 - 7 * 3600 - 1800, m);
    const night = flagOf(try board.getTicket(db, a, k), board.flag_due).?;
    try testing.expect(night.hidden);
    try testing.expectEqualStrings("due today", night.detail);
    // ...and comes back the next morning, overdue, as a new flag.
    try checkAt(ctx, db, thu.at + 86400, m);
    const f = flagOf(try board.getTicket(db, a, k), board.flag_due).?;
    try testing.expect(!f.hidden);
    try testing.expectEqualStrings("overdue since Thu 5 Nov (1 day)", f.detail);
    const new_id = try db.int("SELECT id FROM flags WHERE ticket = (SELECT id FROM tickets WHERE key = ?1) AND kind = 'due' AND cleared IS NULL", .{k});
    try testing.expectEqual(@as(?i64, 1), try db.int("SELECT count(*) FROM flags WHERE ticket = (SELECT id FROM tickets WHERE key = ?1) AND kind = 'due' AND cleared IS NULL", .{k}));
    try testing.expect(new_id.? != first_id.?);
    // A second pass that day (another dispatcher too) changes nothing.
    try checkAt(ctx, db, thu.at + 86400 + 60, m);
    try testing.expectEqual(new_id, try db.int("SELECT id FROM flags WHERE ticket = (SELECT id FROM tickets WHERE key = ?1) AND kind = 'due' AND cleared IS NULL", .{k}));
    // It waits on the human: no Dismiss.
    try testing.expectError(error.BadInput, board.dismissFlag(ctx, db, a, k, board.flag_due));
    // Parked (waiting on someone), it still shows, in Today (todayOnly)...
    try db.exec("INSERT INTO parks (ticket, reason, at) VALUES ((SELECT id FROM tickets WHERE key = ?1), 'Josh', 0)", .{k});
    try testing.expectEqual(@as(usize, 2), (try board.listTickets(db, a, .{ .needs = true })).len);
    try testing.expect(board.todayOnly(try board.getTicket(db, a, k)));
    // ...and hidden, among the hidden ones.
    _ = try board.hideNeeds(ctx, db, a, k, true);
    const hidden = try board.listTickets(db, a, .{ .needs = true, .hidden = true });
    try testing.expectEqual(@as(usize, 1), hidden.len);
    try testing.expectEqualStrings(k, hidden[0].key);
    _ = try board.hideNeeds(ctx, db, a, k, false);
    // Snoozed, it leaves Needs you and isn't among the hidden ones either:
    // it comes back by itself with its reminder.
    try board.snooze(ctx, db, a, k, thu.at + 2 * 86400, "tomorrow");
    try testing.expectEqual(@as(usize, 1), (try board.listTickets(db, a, .{ .needs = true })).len);
    try testing.expectEqual(@as(usize, 0), (try board.listTickets(db, a, .{ .needs = true, .hidden = true })).len);
    try board.updateTicket(ctx, db, a, k, .{ .remind = 0 });
    _ = try board.hideNeeds(ctx, db, a, k, false);
    // Moved later, it goes (and isn't raised again before then).
    try board.updateTicket(ctx, db, a, k, .{ .due = .{ .at = thu.at + 7 * 86400 } });
    try checkAt(ctx, db, thu.at + 86400, m);
    try testing.expect(flagOf(try board.getTicket(db, a, k), board.flag_due) == null);
    // Done clears it.
    try board.move(ctx, db, a, k2, .done);
    try checkAt(ctx, db, thu.at + 86400, m);
    try testing.expectEqual(@as(usize, 0), (try board.getTicket(db, a, k2)).flags.len);
    // Due soonest first.
    const ds = try board.listTickets(db, a, .{ .due = true });
    try testing.expectEqualStrings(k2, ds[0].key);
    // No longer a todo: no dates.
    try board.updateTicket(ctx, db, a, k, .{ .todo = false });
    const t = try board.getTicket(db, a, k);
    try testing.expectEqual(@as(i64, 0), t.due_at);
}

test "migrate: a board from before due dates gets the date columns" {
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try db.execMulti("DROP INDEX tickets_due; DROP INDEX tickets_remind; ALTER TABLE tickets DROP COLUMN due_at; ALTER TABLE tickets DROP COLUMN due_time; ALTER TABLE tickets DROP COLUMN remind_at");
    try board.migrate(db);
    for ([_][]const u8{ "due_at", "due_time", "remind_at" }) |c|
        try testing.expect((try db.int("SELECT 1 FROM pragma_table_info('tickets') WHERE name = ?1", .{c})) != null);
}
