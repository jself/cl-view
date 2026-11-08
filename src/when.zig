//! Dates for todos (due dates and reminders): what `--due` and `--remind`
//! take, and how the board says them.
//!
//! cl has no time-zone code of its own: SQLite's date functions know the
//! local zone (`'localtime'` turns unix seconds into local time, `'utc'` a
//! local time into UTC), so every conversion goes through the board's
//! database. A date alone means that day in the morning (`board.morning`,
//! 08:00 unless set), when a reminder for it fires and a due todo shows up.
const std = @import("std");
const sqlite = @import("db.zig");

pub const Db = sqlite.Db;

/// A moment, and whether a time of day was given ("Mon 15:00") or only a
/// date ("Mon", resolved to that day's morning). `at` 0 is none.
pub const When = struct {
    at: i64 = 0,
    has_time: bool = false,
};

pub const Error = error{ BadWhen, Sqlite, OutOfMemory };

/// The forms `parse` takes, for usage text and error messages.
pub const forms = "today, tomorrow, a weekday (mon or monday: the next one, never today), +3d, +2w, +4h, +30m, now, YYYY-MM-DD or MM-DD, each optionally followed by a time (15:00, 3pm, 3:30pm); a time alone is today's (tomorrow's once it has passed); none clears";

/// The default `board.morning`: 08:00, in minutes after midnight.
pub const default_morning: i64 = 8 * 60;

/// `board.morning` ("HH:MM", "8am") as minutes after midnight; null when it
/// isn't a time.
pub fn parseMorning(text: []const u8) ?i64 {
    var buf: [16]u8 = undefined;
    if (text.len == 0 or text.len > buf.len) return null;
    return parseTime(std.ascii.lowerString(&buf, std.mem.trim(u8, text, " \t")));
}

/// Read what the human typed, at `now` (unix seconds). "" and "none" give
/// `.{}` (none: clears it). `morning` is minutes after midnight.
pub fn parse(db: Db, now: i64, morning: i64, text_in: []const u8) Error!When {
    var buf: [64]u8 = undefined;
    const trimmed = std.mem.trim(u8, text_in, " \t\r\n");
    if (trimmed.len > buf.len) return error.BadWhen;
    const text = std.ascii.lowerString(&buf, trimmed);
    if (text.len == 0 or std.mem.eql(u8, text, "none")) return .{};
    if (std.mem.eql(u8, text, "now")) return .{ .at = now, .has_time = true };

    // The browser's pickers send 2026-11-10T15:00.
    var words: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "at")) continue;
        if (n == words.len) return error.BadWhen;
        if (n == 0 and w.len > 11 and w[10] == 't' and isIsoDate(w[0..10])) {
            words[0] = w[0..10];
            words[1] = w[11..];
            n = 2;
            continue;
        }
        words[n] = w;
        n += 1;
    }
    if (n == 0) return error.BadWhen;

    var date_buf: [16]u8 = undefined;
    const today = try localDate(db, now, &date_buf);
    const first = words[0];

    // +4h, +30m: from now. +3d, +2w: that many days on, in the morning or
    // at the time given.
    if (first[0] == '+') {
        if (first.len < 3) return error.BadWhen;
        const num = std.fmt.parseInt(i64, first[1 .. first.len - 1], 10) catch return error.BadWhen;
        if (num < 0 or num > 3650) return error.BadWhen;
        switch (first[first.len - 1]) {
            'm' => return if (n == 1) .{ .at = now + num * 60, .has_time = true } else error.BadWhen,
            'h' => return if (n == 1) .{ .at = now + num * 3600, .has_time = true } else error.BadWhen,
            'd', 'w' => {
                const days = if (first[first.len - 1] == 'w') num * 7 else num;
                var mod_buf: [32]u8 = undefined;
                const mod = std.fmt.bufPrint(&mod_buf, "+{d} days", .{days}) catch return error.BadWhen;
                var out: [16]u8 = undefined;
                const date = try dateQuery(db, "SELECT date(?1, ?2)", .{ today, mod }, &out);
                return at(db, date, morning, words[1..n]);
            },
            else => return error.BadWhen,
        }
    }

    // A time alone: today, or tomorrow once it has passed.
    if (parseTime(first)) |_| {
        if (n != 1) return error.BadWhen;
        const w = try at(db, today, morning, words[0..1]);
        if (w.at > now) return w;
        var out: [16]u8 = undefined;
        return at(db, try dateQuery(db, "SELECT date(?1, '+1 day')", .{today}, &out), morning, words[0..1]);
    }

    var out: [16]u8 = undefined;
    const date: []const u8 = if (std.mem.eql(u8, first, "today"))
        today
    else if (std.mem.eql(u8, first, "tomorrow") or std.mem.eql(u8, first, "tmrw") or std.mem.eql(u8, first, "tmw"))
        try dateQuery(db, "SELECT date(?1, '+1 day')", .{today}, &out)
    else if (weekday(first)) |wd| blk: {
        var mod_buf: [16]u8 = undefined;
        const mod = std.fmt.bufPrint(&mod_buf, "weekday {d}", .{wd}) catch unreachable;
        // The next one: never today.
        break :blk try dateQuery(db, "SELECT date(?1, '+1 day', ?2)", .{ today, mod }, &out);
    } else if (isIsoDate(first))
        first
    else if (first.len == 5 and first[2] == '-' and std.ascii.isDigit(first[0]) and std.ascii.isDigit(first[1]) and std.ascii.isDigit(first[3]) and std.ascii.isDigit(first[4])) blk: {
        // MM-DD: this year's, or next year's once it has passed.
        var iso_buf: [16]u8 = undefined;
        const this_year = std.fmt.bufPrint(&iso_buf, "{s}-{s}", .{ today[0..4], first }) catch unreachable;
        if (!try validDate(db, this_year)) return error.BadWhen;
        if (std.mem.order(u8, this_year, today) != .lt) {
            @memcpy(out[0..this_year.len], this_year);
            break :blk out[0..this_year.len];
        }
        break :blk try dateQuery(db, "SELECT date(?1, '+1 year')", .{this_year}, &out);
    } else return error.BadWhen;
    if (!try validDate(db, date)) return error.BadWhen;
    return at(db, date, morning, words[1..n]);
}

/// `date` (local YYYY-MM-DD) at the time in `rest` (one word, or none for
/// the morning).
fn at(db: Db, date: []const u8, morning: i64, rest: []const []const u8) Error!When {
    if (rest.len > 1) return error.BadWhen;
    const minutes = if (rest.len == 1) parseTime(rest[0]) orelse return error.BadWhen else morning;
    var local_buf: [32]u8 = undefined;
    const local = std.fmt.bufPrint(&local_buf, "{s} {d:0>2}:{d:0>2}", .{ date, @as(u64, @intCast(@divTrunc(minutes, 60))), @as(u64, @intCast(@mod(minutes, 60))) }) catch return error.BadWhen;
    const secs = try db.int("SELECT CAST(strftime('%s', ?1, 'utc') AS INTEGER)", .{local}) orelse return error.BadWhen;
    return .{ .at = secs, .has_time = rest.len == 1 };
}

/// 15:00, 9:30, 3pm, 3:30pm, 12am, noon: minutes after midnight.
fn parseTime(w: []const u8) ?i64 {
    if (std.mem.eql(u8, w, "noon")) return 12 * 60;
    if (std.mem.eql(u8, w, "midnight")) return 0;
    var s = w;
    var half: ?bool = null; // pm?
    if (std.mem.endsWith(u8, s, "am") or std.mem.endsWith(u8, s, "pm")) {
        half = s[s.len - 2] == 'p';
        s = s[0 .. s.len - 2];
    }
    if (s.len == 0) return null;
    const colon = std.mem.indexOfScalar(u8, s, ':');
    // A bare number is a time only with am/pm ("3pm"), so "3" isn't one.
    if (colon == null and half == null) return null;
    const hs = if (colon) |c| s[0..c] else s;
    const ms = if (colon) |c| s[c + 1 ..] else "00";
    if (hs.len == 0 or hs.len > 2 or ms.len != 2) return null;
    var h = std.fmt.parseInt(i64, hs, 10) catch return null;
    const m = std.fmt.parseInt(i64, ms, 10) catch return null;
    if (m > 59) return null;
    if (half) |pm| {
        if (h < 1 or h > 12) return null;
        if (h == 12) h = 0;
        if (pm) h += 12;
    } else if (h > 23) return null;
    return h * 60 + m;
}

/// mon / monday ... as SQLite's weekday number (0 is Sunday).
fn weekday(w: []const u8) ?u8 {
    const names = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
    for (names, 0..) |name, i| {
        if (w.len >= 3 and w.len <= name.len and std.mem.startsWith(u8, name, w)) return @intCast(i);
    }
    return null;
}

fn isIsoDate(w: []const u8) bool {
    if (w.len != 10 or w[4] != '-' or w[7] != '-') return false;
    for (w, 0..) |ch, i| if (i != 4 and i != 7 and !std.ascii.isDigit(ch)) return false;
    return true;
}

/// A real day: SQLite reads 2026-02-30 as March 2nd, so it must come back
/// as itself.
fn validDate(db: Db, date: []const u8) Error!bool {
    return ((try db.int("SELECT date(?1) = ?1", .{date})) orelse 0) != 0;
}

fn dateQuery(db: Db, sql: []const u8, args: anytype, out: *[16]u8) Error![]const u8 {
    var st = try db.query(sql, args);
    defer st.finalize();
    if (!try st.step()) return error.BadWhen;
    const s = st.text(0);
    if (s.len == 0 or s.len > out.len) return error.BadWhen;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

/// The local date of `t` (unix seconds), YYYY-MM-DD.
pub fn localDate(db: Db, t: i64, out: *[16]u8) Error![]const u8 {
    return dateQuery(db, "SELECT date(?1, 'unixepoch', 'localtime')", .{t}, out);
}

/// Unix seconds of local midnight starting the day `days` after `t`'s.
pub fn dayStart(db: Db, t: i64, days: i64) Error!i64 {
    var mod_buf: [32]u8 = undefined;
    const mod = std.fmt.bufPrint(&mod_buf, "{d} days", .{days}) catch unreachable;
    return try db.int("SELECT CAST(strftime('%s', date(?1, 'unixepoch', 'localtime', ?2), 'utc') AS INTEGER)", .{ t, mod }) orelse error.BadWhen;
}

/// Unix seconds of the morning of `t`'s local day.
pub fn morningOf(db: Db, t: i64, morning: i64) Error!i64 {
    return (try dayStart(db, t, 0)) + morning * 60;
}

/// Local days from `from`'s day to `to`'s: 0 the same day, 1 the next.
pub fn daysBetween(db: Db, from: i64, to: i64) Error!i64 {
    return try db.int(
        "SELECT CAST(julianday(date(?2, 'unixepoch', 'localtime')) - julianday(date(?1, 'unixepoch', 'localtime')) AS INTEGER)",
        .{ from, to },
    ) orelse error.BadWhen;
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "Mon 10 Nov", "Mon 10 Nov 15:00" (with its year when it isn't `now`'s).
pub fn format(db: Db, a: std.mem.Allocator, now: i64, w: When) Error![]const u8 {
    var st = try db.query("SELECT strftime('%w %d %m %Y %H:%M', ?1, 'unixepoch', 'localtime'), strftime('%Y', ?2, 'unixepoch', 'localtime')", .{ w.at, now });
    defer st.finalize();
    if (!try st.step()) return error.BadWhen;
    const s = st.text(0); // "1 10 11 2026 15:00"
    if (s.len < 18) return error.BadWhen;
    const wd = std.fmt.parseInt(usize, s[0..1], 10) catch return error.BadWhen;
    const day = std.fmt.parseInt(u8, s[2..4], 10) catch return error.BadWhen;
    const month = std.fmt.parseInt(usize, s[5..7], 10) catch return error.BadWhen;
    const year = s[8..12];
    const time = s[13..18];
    const other_year = !std.mem.eql(u8, year, st.text(1));
    return std.fmt.allocPrint(a, "{s} {d} {s}{s}{s}{s}{s}", .{
        day_names[wd],                         day,                          month_names[month - 1],
        if (other_year) " " else "",           if (other_year) year else "", if (w.has_time) " " else "",
        if (w.has_time) time else "",
    });
}

/// Local ISO: 2026-11-10T15:00, or 2026-11-10 without a time.
pub fn iso(db: Db, a: std.mem.Allocator, w: When) Error![]const u8 {
    var st = try db.query("SELECT strftime(?2, ?1, 'unixepoch', 'localtime')", .{ w.at, @as([]const u8, if (w.has_time) "%Y-%m-%dT%H:%M" else "%Y-%m-%d") });
    defer st.finalize();
    if (!try st.step()) return error.BadWhen;
    return a.dupe(u8, st.text(0));
}

/// Said from `now`: "today", "today 15:00", "tomorrow 9:00", else `format`.
pub fn label(db: Db, a: std.mem.Allocator, now: i64, w: When) Error![]const u8 {
    const d = try daysBetween(db, now, w.at);
    if (d == 0 or d == 1) {
        const word = if (d == 0) "today" else "tomorrow";
        if (!w.has_time) return word;
        const full = try format(db, a, now, w);
        return std.fmt.allocPrint(a, "{s} {s}", .{ word, full[full.len - 5 ..] });
    }
    return format(db, a, now, w);
}

/// What a due date says at `now`: "due today", "due today 15:00", "due
/// Mon 10 Nov", or "overdue since Mon 2 Nov (2 days)". It changes once a
/// day, so a `due` flag hidden today comes back tomorrow.
pub fn dueText(db: Db, a: std.mem.Allocator, now: i64, w: When) Error![]const u8 {
    const d = try daysBetween(db, now, w.at);
    if (d >= 0) return std.fmt.allocPrint(a, "due {s}", .{try label(db, a, now, w)});
    return std.fmt.allocPrint(a, "overdue since {s} ({d} day{s})", .{ try format(db, a, now, .{ .at = w.at }), -d, if (d == -1) "" else "s" });
}

// ---- tests ----

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn tzset() void;

/// Central time with its daylight saving rules, written out (no zoneinfo
/// needed): CST, UTC-6, in November.
pub fn testZone() void {
    _ = setenv("TZ", "CST6CDT,M3.2.0,M11.1.0", 1);
    tzset();
}

/// Wed 4 Nov 2026, 10:00 CST.
pub const test_now: i64 = 1793808000;

fn testDb() !Db {
    testZone();
    return Db.open(":memory:");
}

test parse {
    const db = try testDb();
    defer db.close();
    const p = struct {
        fn f(d: Db, text: []const u8) !When {
            return parse(d, test_now, default_morning, text);
        }
    }.f;
    // Thu 5 Nov 08:00 CST is 14:00 UTC.
    const thu_morning: i64 = 1793887200;
    try testing.expectEqual(When{}, try p(db, ""));
    try testing.expectEqual(When{}, try p(db, " None "));
    try testing.expectEqual(When{ .at = test_now, .has_time = true }, try p(db, "now"));
    try testing.expectEqual(When{ .at = thu_morning }, try p(db, "tomorrow"));
    try testing.expectEqual(When{ .at = thu_morning }, try p(db, "+1d"));
    try testing.expectEqual(When{ .at = thu_morning + 6 * 86400 }, try p(db, "+1w"));
    try testing.expectEqual(When{ .at = thu_morning }, try p(db, "thu"));
    try testing.expectEqual(When{ .at = thu_morning }, try p(db, "2026-11-05"));
    try testing.expectEqual(When{ .at = thu_morning }, try p(db, "11-05"));
    // Today, in the morning (already past: it fires at once).
    try testing.expectEqual(When{ .at = thu_morning - 86400 }, try p(db, "today"));
    // A weekday is the next one, never today (it's Wednesday).
    try testing.expectEqual(When{ .at = thu_morning + 6 * 86400 }, try p(db, "wednesday"));
    try testing.expectEqual(When{ .at = 1794232800 }, try p(db, "Mon"));
    // With a time.
    try testing.expectEqual(When{ .at = 1793826000, .has_time = true }, try p(db, "today 15:00"));
    try testing.expectEqual(When{ .at = 1793826000, .has_time = true }, try p(db, "today at 3pm"));
    try testing.expectEqual(When{ .at = 1793824200, .has_time = true }, try p(db, "2:30pm"));
    try testing.expectEqual(When{ .at = 1794232800 + 7 * 3600 + 1800, .has_time = true }, try p(db, "mon 3:30pm"));
    try testing.expectEqual(When{ .at = 1794232800 + 7 * 3600 + 1800, .has_time = true }, try p(db, "2026-11-09T15:30"));
    // A time alone that has passed today is tomorrow's.
    try testing.expectEqual(When{ .at = thu_morning + 3600, .has_time = true }, try p(db, "9:00"));
    try testing.expectEqual(When{ .at = thu_morning - 86400 + 4 * 3600, .has_time = true }, try p(db, "noon"));
    // From now.
    try testing.expectEqual(When{ .at = test_now + 4 * 3600, .has_time = true }, try p(db, "+4h"));
    try testing.expectEqual(When{ .at = test_now + 30 * 60, .has_time = true }, try p(db, "+30m"));
    // MM-DD that has passed this year is next year's.
    try testing.expectEqual(When{ .at = 1803909600 }, try p(db, "03-01"));
    try testing.expectEqual(When{ .at = 1798207200 }, try p(db, "12-25"));
    // Another morning.
    try testing.expectEqual(When{ .at = thu_morning - 2 * 3600 }, try parse(db, test_now, 6 * 60, "tomorrow"));
    for ([_][]const u8{ "someday", "2026-02-30", "13-01", "+3x", "+d", "tomorrow 25:00", "3", "mon 3pm extra", "+2h 15:00", "13pm" }) |bad|
        try testing.expectError(error.BadWhen, p(db, bad));
}

test parseMorning {
    try testing.expectEqual(@as(?i64, 8 * 60), parseMorning("08:00"));
    try testing.expectEqual(@as(?i64, 7 * 60 + 30), parseMorning("7:30am"));
    try testing.expectEqual(@as(?i64, null), parseMorning("8"));
    try testing.expectEqual(@as(?i64, null), parseMorning("soon"));
}

test "format, label and dueText say it from now" {
    const db = try testDb();
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const thu_morning: i64 = 1793887200;
    try testing.expectEqualStrings("Thu 5 Nov", try format(db, a, test_now, .{ .at = thu_morning }));
    try testing.expectEqualStrings("Thu 5 Nov 08:00", try format(db, a, test_now, .{ .at = thu_morning, .has_time = true }));
    try testing.expectEqualStrings("Mon 1 Mar 2027", try format(db, a, test_now, .{ .at = 1803909600 }));
    try testing.expectEqualStrings("today 15:00", try label(db, a, test_now, .{ .at = 1793826000, .has_time = true }));
    try testing.expectEqualStrings("tomorrow", try label(db, a, test_now, .{ .at = thu_morning }));
    try testing.expectEqualStrings("Mon 9 Nov", try label(db, a, test_now, .{ .at = 1794232800 }));
    try testing.expectEqualStrings("due today", try dueText(db, a, test_now, .{ .at = thu_morning - 86400 }));
    try testing.expectEqualStrings("due today 15:00", try dueText(db, a, test_now, .{ .at = 1793826000, .has_time = true }));
    try testing.expectEqualStrings("due tomorrow", try dueText(db, a, test_now, .{ .at = thu_morning }));
    try testing.expectEqualStrings("overdue since Mon 2 Nov (2 days)", try dueText(db, a, test_now, .{ .at = thu_morning - 3 * 86400 }));
    try testing.expectEqualStrings("overdue since Tue 3 Nov (1 day)", try dueText(db, a, test_now, .{ .at = thu_morning - 2 * 86400 + 3600, .has_time = true }));
    try testing.expectEqual(@as(i64, 1793858400), try dayStart(db, test_now, 1));
    try testing.expectEqualStrings("2026-11-04T15:00", try iso(db, a, .{ .at = 1793826000, .has_time = true }));
    try testing.expectEqualStrings("2026-11-05", try iso(db, a, .{ .at = thu_morning }));
    try testing.expectEqual(thu_morning - 86400, try morningOf(db, test_now, default_morning));
}
