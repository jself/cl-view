//! Web Push: notifications on the phone (and any browser) when something
//! lands in Needs You, while the board isn't open.
//!
//! The board registers a service worker (/sw.js) and a push subscription on
//! each device the human turns notifications on for; the subscription (the
//! push service's URL for that device and its keys) is kept here, one row
//! per device. `cl web` watches Needs You the way cl-window does (`loop`):
//! each flag or alert it hasn't seen before becomes one message, sent to
//! every device that is on and not in its quiet hours, as standard Web Push:
//! VAPID (RFC 8292) to say it's us, the payload encrypted for the device
//! (RFC 8291, aes128gcm). Push services: FCM for Chrome on Android, Apple's
//! for an iPhone (only for the app added to the home screen), Mozilla's for
//! Firefox. Tapping a notification opens the board on just that item (its
//! compact view); on Android it also has buttons that act on it there and
//! then (`act`): answer, approve the plan, merge, dismiss.
//!
//! The VAPID key pair is made on first use and kept in the board database;
//! a new one would make every device subscribe again.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");
const alerts = @import("alerts.zig");
const ticket_watch = @import("ticket_watch.zig");
const actions = @import("actions.zig");

const P256 = std.crypto.ecc.P256;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Aes = std.crypto.aead.aes_gcm.Aes128Gcm;
const b64 = std.base64.url_safe_no_pad;

/// Who sends (VAPID's `sub`): Apple's push service wants a mailto: or https:
/// URL there and refuses the message without one.
const contact = "https://github.com/jself/cl-view";

pub const schema =
    \\CREATE TABLE IF NOT EXISTS push_devices (
    \\  id INTEGER PRIMARY KEY,
    \\  endpoint TEXT NOT NULL UNIQUE,
    \\  p256dh TEXT NOT NULL,
    \\  auth TEXT NOT NULL,
    \\  name TEXT NOT NULL DEFAULT '',
    \\  enabled INTEGER NOT NULL DEFAULT 1,
    \\  tz_offset INTEGER NOT NULL DEFAULT 0,
    \\  created INTEGER NOT NULL,
    \\  seen INTEGER NOT NULL DEFAULT 0,
    \\  sent INTEGER NOT NULL DEFAULT 0,
    \\  error TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE TABLE IF NOT EXISTS push_settings (
    \\  id INTEGER PRIMARY KEY CHECK (id = 1),
    \\  vapid TEXT NOT NULL DEFAULT '',
    \\  kinds TEXT NOT NULL DEFAULT 'ask,review,problem,park,idle,alert',
    \\  quiet_from INTEGER NOT NULL DEFAULT -1,
    \\  quiet_to INTEGER NOT NULL DEFAULT -1,
    \\  mark_flag INTEGER NOT NULL DEFAULT -1,
    \\  mark_alert INTEGER NOT NULL DEFAULT -1
    \\);
    \\INSERT OR IGNORE INTO push_settings (id) VALUES (1);
    \\CREATE TABLE IF NOT EXISTS push_removed (
    \\  endpoint TEXT PRIMARY KEY,
    \\  at INTEGER NOT NULL
    \\);
;

// ---- what notifies ----

/// The kinds of thing the human picks to be notified about.
pub const Group = enum {
    /// A question, or a permission prompt.
    ask,
    /// A plan or work ready for review, a test plan, an umbrella ready to close.
    review,
    /// Work that didn't land, a conflict, a failed after-merge run, a session that ended.
    problem,
    /// A parked ticket woke (its condition came true), or its park ran out.
    park,
    /// Claude ended its turn and nothing else asks.
    idle,
    /// `cl alert` from a session or the operator.
    alert,

    pub fn ofFlag(kind: []const u8) Group {
        const eql = std.mem.eql;
        if (eql(u8, kind, board.flag_question) or eql(u8, kind, board.flag_input)) return .ask;
        if (eql(u8, kind, board.flag_review) or eql(u8, kind, board.flag_testing) or eql(u8, kind, board.flag_ready_to_close)) return .review;
        if (eql(u8, kind, board.flag_unparked) or eql(u8, kind, board.flag_park_expired)) return .park;
        if (eql(u8, kind, board.flag_idle)) return .idle;
        return .problem;
    }
};

/// One thing that asks for the human: a flag that puts a ticket in Needs
/// You, or an alert. `id` is what the board's /api/needs calls it.
pub const Item = struct {
    id: []const u8,
    group: Group,
    /// The flag's kind, or "alert".
    kind: []const u8,
    /// The ticket ("" for an alert about none).
    key: []const u8 = "",
    title: []const u8,
    body: []const u8,
    /// The flag's row id, or when the alert was raised: both only grow, so
    /// what is newer than the last one handled is new (`Marks`).
    seq: i64 = 0,
    /// The ticket's tab that answers it (the board's ticket popup).
    tab: []const u8 = "needs",
    /// The buttons on its notification (Android shows them; iOS doesn't).
    actions: []const Action = &.{},
    /// A question or prompt: which one (`askHash` of what it asked). A
    /// newer one can take over the same flag row, so an answer carries this
    /// and `act` refuses it once the flag asks something else.
    ask: []const u8 = "",
};

/// What a question or permission flag asks, as a short hash of its detail.
pub fn askHash(a: std.mem.Allocator, detail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{x:0>16}", .{std.hash.Wyhash.hash(0, detail)});
}

/// A button on a notification: `action` is what the service worker posts
/// back to /api/needs/act (see `act`), `title` its label.
pub const Action = struct {
    action: []const u8,
    title: []const u8,
};

const dismiss_only = [_]Action{.{ .action = "dismiss", .title = "Dismiss" }};

/// The one-tap answers to a flag, as its Needs You card offers them: a lone
/// single-choice question's options, a permission prompt's first two, Approve
/// plan, Merge (a review or test of work Merge can land), or Dismiss (a flag
/// that doesn't wait on the human). The service worker shows as many as the
/// phone takes (two on Chrome for Android), in this order.
fn actionsFor(a: std.mem.Allocator, t: ticket_watch.Seen, f: ticket_watch.SeenFlag) ![]const Action {
    const eql = std.mem.eql;
    var out: std.ArrayList(Action) = .empty;
    if (eql(u8, f.kind, board.flag_question) or eql(u8, f.kind, board.flag_input)) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, f.detail, .{}) catch return out.items;
        if (parsed != .object) return out.items;
        if (eql(u8, f.kind, board.flag_question)) {
            const qs = parsed.object.get("questions") orelse return out.items;
            if (qs != .array or qs.array.items.len != 1 or qs.array.items[0] != .object) return out.items;
            const q = qs.array.items[0].object;
            if (q.get("multiSelect")) |m| if (m == .bool and m.bool) return out.items;
            const opts = q.get("options") orelse return out.items;
            if (opts != .array) return out.items;
            for (opts.array.items, 1..) |o, n| {
                if (n > 3) break;
                const label = if (o == .object) o.object.get("label") orelse continue else continue;
                if (label != .string) continue;
                try out.append(a, .{ .action = try std.fmt.allocPrint(a, "answer:{d}", .{n}), .title = label.string });
            }
        } else {
            const opts = parsed.object.get("options") orelse return out.items;
            if (opts != .array) return out.items;
            for (opts.array.items) |o| {
                if (out.items.len == 2) break;
                if (o != .object) continue;
                const n = o.object.get("n") orelse continue;
                const label = o.object.get("label") orelse continue;
                if (n != .integer or label != .string) continue;
                try out.append(a, .{ .action = try std.fmt.allocPrint(a, "answer:{d}", .{n.integer}), .title = label.string });
            }
        }
        return out.items;
    }
    if (eql(u8, f.kind, board.flag_review) and t.stage == .planning) {
        // Not an umbrella's with nothing filed under it: approving is refused.
        if (eql(u8, f.detail, "plan") and !t.empty_umbrella) try out.append(a, .{ .action = "approve", .title = "Approve plan" });
        return out.items;
    }
    if (eql(u8, f.kind, board.flag_review) or eql(u8, f.kind, board.flag_testing)) {
        if (t.mergeable and (t.stage == .review or t.stage == .testing)) try out.append(a, .{ .action = "merge", .title = "Merge" });
        return out.items;
    }
    if (!board.waitingFlag(f.kind)) return &dismiss_only;
    return out.items;
}

/// What is in Needs You now, as `Item`s: each ticket's asking flags, then alerts.
pub fn items(a: std.mem.Allocator, tickets: []const ticket_watch.Seen, al: []const alerts.Alert) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (tickets) |t| if (t.inNeeds()) for (t.flags) |f| if (t.asks(f)) {
        const detail = try flagText(a, f);
        try out.append(a, .{
            .id = try std.fmt.allocPrint(a, "f{d}", .{f.id}),
            .group = Group.ofFlag(f.kind),
            .kind = f.kind,
            .key = t.key,
            .title = try std.fmt.allocPrint(a, "{s}: {s}", .{ t.key, flagLabel(f) }),
            .body = if (detail.len > 0) try std.fmt.allocPrint(a, "{s}\n{s}", .{ detail, t.title }) else t.title,
            .tab = tabFor(f.kind, std.mem.eql(u8, f.detail, "plan")),
            .seq = f.id,
            .actions = try actionsFor(a, t, f),
            .ask = if (Group.ofFlag(f.kind) == .ask) try askHash(a, f.detail) else "",
        });
    };
    for (al) |x| try out.append(a, .{
        .id = try std.fmt.allocPrint(a, "a{s}@{d}", .{ x.tmux, x.at }),
        .group = .alert,
        .kind = "alert",
        .key = x.ticket,
        .title = if (x.ticket.len > 0)
            try std.fmt.allocPrint(a, "{s}: alert from {s}", .{ x.ticket, if (x.operator) "the operator" else x.from })
        else
            try std.fmt.allocPrint(a, "Alert from {s}", .{if (x.operator) "the operator" else x.from}),
        .body = x.text,
        .seq = x.at,
        .actions = &dismiss_only,
    });
    return out.items;
}

/// As the board names the flag, said of the ticket.
fn flagLabel(f: ticket_watch.SeenFlag) []const u8 {
    const eql = std.mem.eql;
    const k = f.kind;
    if (eql(u8, k, board.flag_review)) return if (eql(u8, f.detail, "plan")) "plan ready" else "ready for review";
    const names = [_][2][]const u8{
        .{ board.flag_question, "question" },
        .{ board.flag_input, "needs permission" },
        .{ board.flag_testing, "ready to test" },
        .{ board.flag_ready_to_close, "ready to close" },
        .{ board.flag_idle, "waiting on you" },
        .{ board.flag_unparked, "woke from park" },
        .{ board.flag_park_expired, "park expired" },
        .{ board.flag_conflict, "conflicts" },
        .{ board.flag_after_merge, "after-merge failed" },
        .{ board.flag_push_failed, "push failed" },
        .{ board.flag_ci_failed, "CI failed" },
        .{ board.flag_merge_failed, "didn't land" },
        .{ board.flag_unmerged, "not merged" },
        .{ "ended", "session ended" },
        .{ "start-failed", "didn't start" },
    };
    for (names) |n| if (eql(u8, k, n[0])) return n[1];
    return k;
}

/// What the flag says, on one line: the questions asked, the tool wanting
/// permission, or its plain detail ("" for none).
fn flagText(a: std.mem.Allocator, f: ticket_watch.SeenFlag) ![]const u8 {
    const eql = std.mem.eql;
    const d = std.mem.trim(u8, f.detail, " \t\r\n");
    if (d.len == 0 or eql(u8, d, "plan")) return "";
    if (d[0] != '{') return clip(a, d, 200);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, d, .{}) catch return "";
    if (parsed != .object) return "";
    if (eql(u8, f.kind, board.flag_question)) {
        const qs = parsed.object.get("questions") orelse return "";
        if (qs != .array) return "";
        var out: std.ArrayList(u8) = .empty;
        for (qs.array.items) |q| if (q == .object) if (q.object.get("question")) |text| if (text == .string) {
            if (out.items.len > 0) try out.appendSlice(a, " · ");
            try out.appendSlice(a, text.string);
        };
        return clip(a, out.items, 300);
    }
    if (eql(u8, f.kind, board.flag_input)) {
        const tool = if (parsed.object.get("tool")) |v| (if (v == .string) v.string else "") else "";
        const summary = if (parsed.object.get("summary")) |v| (if (v == .string) v.string else "") else "";
        if (tool.len == 0 and summary.len == 0) return "";
        return clip(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ tool, if (tool.len > 0 and summary.len > 0) ": " else "", summary }), 200);
    }
    return "";
}

/// At most `n` bytes, cut at a character boundary, with "…" when cut.
fn clip(a: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 {
    if (s.len <= n) return s;
    var end = n;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}…", .{s[0..end]});
}

/// Which of the board's ticket tabs answers this flag (as its Needs You
/// card's main button opens).
fn tabFor(kind: []const u8, detail_plan: bool) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, kind, board.flag_review)) return if (detail_plan) "plan" else "review";
    if (eql(u8, kind, board.flag_testing)) return "test";
    if (eql(u8, kind, board.flag_after_merge)) return "after-merge";
    if (eql(u8, kind, board.flag_merge_failed) or eql(u8, kind, board.flag_unmerged)) return "landing";
    if (eql(u8, kind, board.flag_idle)) return "session";
    return "needs";
}

/// The message the service worker shows (src/web/sw.js), as JSON. `url`
/// opens the board's compact view of the item (`focus`: the ticket's tab that
/// answers it, alone); `item` and `actions` are what its buttons send to
/// /api/needs/act.
pub fn payload(a: std.mem.Allocator, it: Item, at: i64) ![]const u8 {
    const url = if (it.key.len > 0 and it.group != .alert)
        try std.fmt.allocPrint(a, "/board?open={s}&tab={s}&focus=1", .{ it.key, it.tab })
    else if (it.key.len > 0)
        try std.fmt.allocPrint(a, "/board?open={s}&tab={s}", .{ it.key, it.tab })
    else
        "/board";
    // One notification per ticket (or session): a newer one replaces it.
    const tag = if (it.key.len > 0) it.key else it.id[0 .. std.mem.indexOfScalar(u8, it.id, '@') orelse it.id.len];
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{
        .title = it.title,
        .body = try clip(a, it.body, 600),
        .tag = tag,
        .url = url,
        .key = it.key,
        .kind = it.kind,
        .item = it.id,
        .actions = it.actions,
        .ask = it.ask,
        .at = at,
    }, .{})});
}

// ---- acting from a notification ----

/// What a notification's button did, said back on the phone.
pub const Acted = struct { message: []const u8 };

/// Do what a notification's button says (`Action.action`) to the item it
/// was about (`Item.id`), as the board's own buttons would. The item is
/// looked up again first: one dealt with since (on the board, by another
/// device, or Claude moving on) is error.Handled, so an old notification
/// never answers a newer question. An answer also carries `ask` (`Item.ask`):
/// a newer question in the same flag row asks something else, and is Handled
/// too. So is an alert replaced by a newer one from the same session.
pub fn act(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, item: []const u8, action: []const u8, ask: []const u8) !Acted {
    const eql = std.mem.eql;
    if (item.len < 2) return error.BadInput;
    if (item[0] == 'a') {
        if (!eql(u8, action, "dismiss")) return error.BadAction;
        const i = std.mem.lastIndexOfScalar(u8, item, '@') orelse return error.BadInput;
        const at = std.fmt.parseInt(i64, item[i + 1 ..], 10) catch return error.BadInput;
        if (!try alerts.dismissAt(ctx, a, item[1..i], at)) return error.Handled;
        return .{ .message = "Alert dismissed" };
    }
    if (item[0] != 'f') return error.BadInput;
    const id = std.fmt.parseInt(i64, item[1..], 10) catch return error.BadInput;
    var st = try db.query("SELECT t.key, f.kind, f.detail, f.cleared IS NULL FROM flags f JOIN tickets t ON t.id = f.ticket WHERE f.id = ?1", .{id});
    defer st.finalize();
    if (!try st.step()) return error.Handled;
    if (st.int(3) == 0) return error.Handled;
    const key = try st.dupe(a, 0);
    const kind = try st.dupe(a, 1);
    const detail = try st.dupe(a, 2);
    const t = try board.getTicket(db, a, key);
    if (eql(u8, action, "approve")) {
        if (!eql(u8, kind, board.flag_review) or !eql(u8, detail, "plan") or t.stage != .planning) return error.BadAction;
        _ = try actions.approve(ctx, db, a, key, false, .close);
        return .{ .message = try std.fmt.allocPrint(a, "{s}: plan approved; {s}", .{ key, if (t.umbrella) "its sub-tickets are queued" else "a new session builds it" }) };
    }
    if (eql(u8, action, "merge")) {
        if (!eql(u8, kind, board.flag_review) and !eql(u8, kind, board.flag_testing)) return error.BadAction;
        if (t.stage != .review and t.stage != .testing) return error.BadAction;
        if (t.finishing.len > 0) return error.Handled;
        if (t.branch.len == 0 and t.change.len == 0) return error.BadAction;
        if (t.custom_close.len > 0) return error.CustomClose;
        try actions.move(ctx, cfg, db, a, key, .done, false, .merge);
        return .{ .message = try std.fmt.allocPrint(a, "{s}: merging it; it goes to Done once it lands", .{key}) };
    }
    if (std.mem.startsWith(u8, action, "answer:")) {
        if (!eql(u8, kind, board.flag_question) and !eql(u8, kind, board.flag_input)) return error.BadAction;
        const n = action["answer:".len..];
        _ = std.fmt.parseInt(u8, n, 10) catch return error.BadAction;
        if (!eql(u8, ask, try askHash(a, detail))) return error.Handled;
        try actions.answer(ctx, cfg, db, a, key, &.{n});
        return .{ .message = try std.fmt.allocPrint(a, "{s}: Claude got your answer", .{key}) };
    }
    if (eql(u8, action, "dismiss")) {
        if (board.waitingFlag(kind)) return error.WaitingFlag;
        if (!try board.dismissFlag(ctx, db, a, key, kind)) return error.Handled;
        return .{ .message = try std.fmt.allocPrint(a, "{s}: dismissed", .{key}) };
    }
    return error.BadAction;
}

// ---- settings and devices ----

pub const Settings = struct {
    kinds: []const Group,
    /// Quiet hours, as minutes after midnight in each device's own time;
    /// null when off. From == to is off too.
    quiet_from: ?u16 = null,
    quiet_to: ?u16 = null,

    pub fn wants(self: Settings, g: Group) bool {
        return std.mem.indexOfScalar(Group, self.kinds, g) != null;
    }

    /// Quiet at `now` (unix seconds) for a device `tz_offset` minutes east of UTC.
    pub fn quiet(self: Settings, now: i64, tz_offset: i64) bool {
        const from = self.quiet_from orelse return false;
        const to = self.quiet_to orelse return false;
        if (from == to) return false;
        const m: u16 = @intCast(@mod(@divFloor(now, 60) + tz_offset, 24 * 60));
        return if (from < to) m >= from and m < to else m >= from or m < to;
    }
};

pub fn ensureSchema(db: board.Db) !void {
    try db.execMulti(schema);
    // Boards that had push before the marks.
    if ((try db.int("SELECT 1 FROM pragma_table_info('push_settings') WHERE name = 'mark_flag'", .{})) == null)
        try db.execMulti("ALTER TABLE push_settings ADD COLUMN mark_flag INTEGER NOT NULL DEFAULT -1; ALTER TABLE push_settings ADD COLUMN mark_alert INTEGER NOT NULL DEFAULT -1");
}

pub fn settings(db: board.Db, a: std.mem.Allocator) !Settings {
    try ensureSchema(db);
    var st = try db.query("SELECT kinds, quiet_from, quiet_to FROM push_settings WHERE id = 1", .{});
    defer st.finalize();
    if (!try st.step()) return .{ .kinds = &.{} };
    var kinds: std.ArrayList(Group) = .empty;
    var it = std.mem.tokenizeScalar(u8, st.text(0), ',');
    while (it.next()) |k| if (std.meta.stringToEnum(Group, k)) |g| try kinds.append(a, g);
    const from = st.int(1);
    const to = st.int(2);
    const valid = from >= 0 and from < 24 * 60 and to >= 0 and to < 24 * 60;
    return .{ .kinds = kinds.items, .quiet_from = if (valid) @intCast(from) else null, .quiet_to = if (valid) @intCast(to) else null };
}

pub fn saveSettings(db: board.Db, a: std.mem.Allocator, s: Settings) !void {
    try ensureSchema(db);
    var kinds: std.ArrayList(u8) = .empty;
    for (s.kinds) |g| {
        if (kinds.items.len > 0) try kinds.append(a, ',');
        try kinds.appendSlice(a, @tagName(g));
    }
    const from: i64 = if (s.quiet_from) |f| f else -1;
    const to: i64 = if (s.quiet_to) |t| t else -1;
    try db.exec("UPDATE push_settings SET kinds = ?1, quiet_from = ?2, quiet_to = ?3 WHERE id = 1", .{ kinds.items, from, to });
}

pub const Device = struct {
    id: i64,
    endpoint: []const u8,
    p256dh: []const u8,
    auth: []const u8,
    /// What the board called it ("Android · Chrome").
    name: []const u8,
    enabled: bool,
    tz_offset: i64,
    created: i64,
    /// When the board last checked in from it, and when it was last sent to.
    seen: i64,
    sent: i64,
    /// Why the last send failed ("" when it didn't).
    @"error": []const u8,
};

pub fn devices(db: board.Db, a: std.mem.Allocator) ![]Device {
    try ensureSchema(db);
    var st = try db.query("SELECT id, endpoint, p256dh, auth, name, enabled, tz_offset, created, seen, sent, error FROM push_devices ORDER BY id", .{});
    defer st.finalize();
    var out: std.ArrayList(Device) = .empty;
    while (try st.step()) try out.append(a, .{
        .id = st.int(0),
        .endpoint = try st.dupe(a, 1),
        .p256dh = try st.dupe(a, 2),
        .auth = try st.dupe(a, 3),
        .name = try st.dupe(a, 4),
        .enabled = st.int(5) != 0,
        .tz_offset = st.int(6),
        .created = st.int(7),
        .seen = st.int(8),
        .sent = st.int(9),
        .@"error" = try st.dupe(a, 10),
    });
    return out.items;
}

pub const Subscription = struct {
    endpoint: []const u8,
    p256dh: []const u8,
    auth: []const u8,
    /// "" keeps the name it had.
    name: []const u8 = "",
    tz_offset: i64 = 0,
    /// The human pressed Turn on (rather than the board or the service
    /// worker checking in by itself): only that brings back a removed device.
    explicit: bool = false,
    /// The browser renewed the subscription: the one it replaces, whose row
    /// (name, on or off) it takes over.
    old_endpoint: []const u8 = "",
};

/// Add the device, or update it (same endpoint: its keys, name and time
/// zone; whether it is on stays as it was). Returns its id. A device the
/// human removed stays removed (error.Removed) until they turn it on there.
pub fn subscribe(db: board.Db, a: std.mem.Allocator, now: i64, s: Subscription) !i64 {
    try ensureSchema(db);
    if (!std.mem.startsWith(u8, s.endpoint, "https://")) return error.BadInput;
    // The keys must be ones a message can be encrypted for.
    _ = P256.fromSec1(try decode64(a, s.p256dh)) catch return error.BadInput;
    if ((try decode64(a, s.auth)).len != 16) return error.BadInput;
    if (s.explicit) {
        try db.exec("DELETE FROM push_removed WHERE endpoint IN (?1, ?2)", .{ s.endpoint, s.old_endpoint });
    } else if ((try db.int("SELECT 1 FROM push_removed WHERE endpoint IN (?1, ?2)", .{ s.endpoint, s.old_endpoint })) != null) {
        return error.Removed;
    }
    const tz = std.math.clamp(s.tz_offset, -24 * 60, 24 * 60);
    if (s.old_endpoint.len > 0 and (try db.int("SELECT 1 FROM push_devices WHERE endpoint = ?1", .{s.endpoint})) == null)
        try db.exec("UPDATE push_devices SET endpoint = ?2 WHERE endpoint = ?1", .{ s.old_endpoint, s.endpoint });
    try db.exec(
        \\INSERT INTO push_devices (endpoint, p256dh, auth, name, tz_offset, created, seen) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
        \\ON CONFLICT (endpoint) DO UPDATE SET p256dh = ?2, auth = ?3, name = CASE WHEN ?4 = '' THEN name ELSE ?4 END, tz_offset = ?5, seen = ?6
    , .{ s.endpoint, s.p256dh, s.auth, s.name, tz, now });
    return (try db.int("SELECT id FROM push_devices WHERE endpoint = ?1", .{s.endpoint})).?;
}

pub fn setEnabled(db: board.Db, id: i64, on: bool) !void {
    try ensureSchema(db);
    try db.exec("UPDATE push_devices SET enabled = ?2 WHERE id = ?1", .{ id, @as(i64, @intFromBool(on)) });
    if (db.changes() == 0) return error.NotFound;
}

/// Remove a device. `forget`: the human removed it, so its browser
/// checking in again doesn't bring it back (see `subscribe`); a device whose
/// browser unsubscribed just goes.
pub fn remove(db: board.Db, id: i64, forget: bool, now: i64) !void {
    try ensureSchema(db);
    if (forget) try db.exec("INSERT OR REPLACE INTO push_removed (endpoint, at) SELECT endpoint, ?2 FROM push_devices WHERE id = ?1", .{ id, now });
    try db.exec("DELETE FROM push_devices WHERE id = ?1", .{id});
    if (db.changes() == 0) return error.NotFound;
}

/// The highest flag id and alert time handled so far (-1: never ran).
pub const Marks = struct {
    flag: i64 = -1,
    alert: i64 = -1,

    pub fn covers(self: Marks, it: Item) bool {
        return it.seq <= if (it.group == .alert) self.alert else self.flag;
    }

    /// Raised to take in `its`.
    pub fn after(self: Marks, its: []const Item) Marks {
        var m = self;
        for (its) |it| {
            if (it.group == .alert) m.alert = @max(m.alert, it.seq) else m.flag = @max(m.flag, it.seq);
        }
        return m;
    }
};

pub fn marks(db: board.Db) !Marks {
    try ensureSchema(db);
    var st = try db.query("SELECT mark_flag, mark_alert FROM push_settings WHERE id = 1", .{});
    defer st.finalize();
    if (!try st.step()) return .{};
    return .{ .flag = st.int(0), .alert = st.int(1) };
}

pub fn saveMarks(db: board.Db, m: Marks) !void {
    try db.exec("UPDATE push_settings SET mark_flag = ?1, mark_alert = ?2 WHERE id = 1", .{ m.flag, m.alert });
}

/// The VAPID key pair, made and kept on first use.
pub fn vapid(ctx: Ctx, db: board.Db, a: std.mem.Allocator) !Ecdsa.KeyPair {
    try ensureSchema(db);
    var st = try db.query("SELECT vapid FROM push_settings WHERE id = 1", .{});
    const stored = if (try st.step()) try st.dupe(a, 0) else "";
    st.finalize();
    if (stored.len > 0) {
        const raw = try decode64(a, stored);
        if (raw.len == 32) if (Ecdsa.SecretKey.fromBytes(raw[0..32].*)) |sk| return Ecdsa.KeyPair.fromSecretKey(sk) else |_| {};
    }
    const kp = Ecdsa.KeyPair.generate(ctx.io);
    const sk = kp.secret_key.toBytes();
    try db.exec("UPDATE push_settings SET vapid = ?1 WHERE id = 1 AND vapid = ?2", .{ try encode64(a, &sk), stored });
    // Another server made one first: use that one.
    if (db.changes() == 0) return vapid(ctx, db, a);
    return kp;
}

/// The public key the board subscribes with (applicationServerKey).
pub fn publicKey(ctx: Ctx, db: board.Db, a: std.mem.Allocator) ![]const u8 {
    const kp = try vapid(ctx, db, a);
    return encode64(a, &kp.public_key.toUncompressedSec1());
}

// ---- RFC 8291: the message, encrypted for one device ----

/// The request body for a device whose keys are `ua_public` (65 bytes,
/// uncompressed) and `auth_secret`: one aes128gcm record, with the
/// sender's one-time public key as the key id. `as_secret` and `salt` are
/// random per message (fixed only by tests).
pub fn encrypt(a: std.mem.Allocator, plaintext: []const u8, ua_public: []const u8, auth_secret: []const u8, as_secret: [32]u8, salt: [16]u8) ![]u8 {
    const ua = try P256.fromSec1(ua_public);
    const ua_raw = ua.toUncompressedSec1();
    const as_public = (try P256.basePoint.mul(as_secret, .big)).toUncompressedSec1();
    const shared = (try ua.mul(as_secret, .big)).affineCoordinates().x.toBytes(.big);

    // IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info" || 0 || ua_public || as_public, 32)
    const prk_key = Hkdf.extract(auth_secret, &shared);
    var key_info: [14 + 65 + 65]u8 = undefined;
    @memcpy(key_info[0..14], "WebPush: info\x00");
    @memcpy(key_info[14..79], &ua_raw);
    @memcpy(key_info[79..144], &as_public);
    var ikm: [32]u8 = undefined;
    Hkdf.expand(&ikm, &key_info, prk_key);

    const prk = Hkdf.extract(&salt, &ikm);
    var cek: [16]u8 = undefined;
    Hkdf.expand(&cek, "Content-Encoding: aes128gcm\x00", prk);
    var nonce: [12]u8 = undefined;
    Hkdf.expand(&nonce, "Content-Encoding: nonce\x00", prk);

    // One record: the text, then 0x02 (the last record, no padding).
    const header_len = 16 + 4 + 1 + 65;
    const rs: u32 = 4096;
    if (plaintext.len + 1 + Aes.tag_length > rs) return error.TooBig;
    const out = try a.alloc(u8, header_len + plaintext.len + 1 + Aes.tag_length);
    @memcpy(out[0..16], &salt);
    std.mem.writeInt(u32, out[16..20], rs, .big);
    out[20] = 65;
    @memcpy(out[21..86], &as_public);
    const padded = try a.alloc(u8, plaintext.len + 1);
    @memcpy(padded[0..plaintext.len], plaintext);
    padded[plaintext.len] = 2;
    const c = out[header_len .. header_len + padded.len];
    Aes.encrypt(c, out[header_len + padded.len ..][0..Aes.tag_length], padded, "", nonce, cek);
    return out;
}

// ---- RFC 8292: VAPID ----

/// `Authorization: vapid t=<JWT>, k=<public key>` for a push service at
/// `endpoint`: an ES256 JWT for its origin, good for 12 hours.
pub fn vapidHeader(a: std.mem.Allocator, kp: Ecdsa.KeyPair, endpoint: []const u8, now: i64) ![]const u8 {
    const uri = try std.Uri.parse(endpoint);
    const host = (uri.host orelse return error.BadInput).percent_encoded;
    const aud = if (uri.port) |p| try std.fmt.allocPrint(a, "https://{s}:{d}", .{ host, p }) else try std.fmt.allocPrint(a, "https://{s}", .{host});
    const head = try encode64(a, "{\"typ\":\"JWT\",\"alg\":\"ES256\"}");
    const claims = try encode64(a, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .aud = aud, .exp = now + 12 * 3600, .sub = contact }, .{})}));
    const signing = try std.fmt.allocPrint(a, "{s}.{s}", .{ head, claims });
    const sig = try kp.sign(signing, null);
    return std.fmt.allocPrint(a, "vapid t={s}.{s}, k={s}", .{ signing, try encode64(a, &sig.toBytes()), try encode64(a, &kp.public_key.toUncompressedSec1()) });
}

// ---- sending ----

pub const SendError = error{
    /// The push service says the device unsubscribed (404, 410): forget it.
    Gone,
    /// Any other refusal; `lastError` says what.
    Refused,
};

threadlocal var last_error_buf: [300]u8 = undefined;
threadlocal var last_error_len: usize = 0;

/// Why the last send on this thread failed.
pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    last_error_len = if (std.fmt.bufPrint(&last_error_buf, fmt, args)) |m| m.len else |_| last_error_buf.len;
}

/// Send `message` (the JSON from `payload`) to one device.
pub fn send(ctx: Ctx, a: std.mem.Allocator, client: *std.http.Client, kp: Ecdsa.KeyPair, d: Device, message: []const u8, now: i64) !void {
    last_error_len = 0;
    var as_secret: [32]u8 = undefined;
    var salt: [16]u8 = undefined;
    ctx.io.random(&salt);
    const body = while (true) {
        ctx.io.random(&as_secret);
        break encrypt(a, message, try decode64(a, d.p256dh), try decode64(a, d.auth), as_secret, salt) catch |err| switch (err) {
            // A secret that isn't a valid scalar: draw again (vanishingly rare).
            error.IdentityElement, error.NonCanonical => continue,
            else => return err,
        };
    };
    const auth_header = try vapidHeader(a, kp, d.endpoint, now);
    var tries: u8 = 0;
    const res = while (true) : (tries += 1) {
        break post(a, client, d.endpoint, body, auth_header) catch |err| {
            // A network blip (a DNS lookup that failed once, a reset): once more.
            if (tries == 0) {
                ctx.sleepMs(1000);
                continue;
            }
            setLastError("couldn't reach the push service: {s}", .{@errorName(err)});
            return error.Refused;
        };
    };
    switch (@intFromEnum(res.status)) {
        200...299 => return,
        404, 410 => {
            setLastError("the browser unsubscribed ({d})", .{@intFromEnum(res.status)});
            return error.Gone;
        },
        else => {
            const text = std.mem.trim(u8, res.body, " \t\r\n");
            setLastError("the push service answered {d}: {s}", .{ @intFromEnum(res.status), text[0..@min(text.len, 200)] });
            return error.Refused;
        },
    }
}

fn post(a: std.mem.Allocator, client: *std.http.Client, endpoint: []const u8, body: []const u8, auth_header: []const u8) !struct { status: std.http.Status, body: []const u8 } {
    var resp: std.Io.Writer.Allocating = .init(a);
    const res = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-encoding", .value = "aes128gcm" },
            // Kept a day for a phone that is off; then it's old news.
            .{ .name = "ttl", .value = "86400" },
            .{ .name = "urgency", .value = "high" },
        },
        .response_writer = &resp.writer,
    });
    return .{ .status = res.status, .body = resp.written() };
}

// ---- one send, on a thread of its own ----

/// std.http.Client has no timeouts, and a push service (or the route to it)
/// can take a connection and never answer. So each send runs on its own
/// thread: the watch doesn't wait for it, a test waits at most
/// `test_wait_ms`, and a device gets no second send while one is still out
/// (`InFlight`), so a hung one costs one thread, not one per message.
const Job = struct {
    ctx: Ctx,
    cfg: config.Config,
    arena: std.heap.ArenaAllocator,
    device: Device,
    message: []const u8,
    /// running, done (the result is in), or abandoned (nobody waits: the
    /// thread frees the job).
    state: std.atomic.Value(u8) = .init(running),
    failed: ?anyerror = null,
    why: []const u8 = "",

    const running = 0;
    const done = 1;
    const abandoned = 2;

    fn start(ctx: Ctx, cfg: config.Config, d: Device, message: []const u8, waited: bool) !*Job {
        if (!in_flight.add(d.id)) return error.StillSending;
        errdefer in_flight.drop(d.id);
        const job = try ctx.gpa.create(Job);
        errdefer ctx.gpa.destroy(job);
        job.* = .{ .ctx = ctx, .cfg = cfg, .arena = .init(ctx.gpa), .device = undefined, .message = undefined, .state = .init(if (waited) running else abandoned) };
        const a = job.arena.allocator();
        job.device = d;
        inline for (.{ "endpoint", "p256dh", "auth", "name" }) |f| @field(job.device, f) = try a.dupe(u8, @field(d, f));
        job.message = try a.dupe(u8, message);
        (try std.Thread.spawn(.{}, run, .{job})).detach();
        return job;
    }

    fn run(job: *Job) void {
        job.sendOnce();
        in_flight.drop(job.device.id);
        if (job.state.cmpxchgStrong(running, done, .acq_rel, .acquire) != null) job.free();
    }

    fn sendOnce(job: *Job) void {
        const a = job.arena.allocator();
        const d = job.device;
        const db = board.open(job.ctx, job.cfg) catch |err| return job.fail(err, "can't open the board database");
        defer db.close();
        const kp = vapid(job.ctx, db, a) catch |err| return job.fail(err, "no VAPID key");
        var client: std.http.Client = .{ .allocator = a, .io = job.ctx.io };
        defer client.deinit();
        const now = job.ctx.nowSeconds();
        if (send(job.ctx, a, &client, kp, d, job.message, now)) {
            db.exec("UPDATE push_devices SET sent = ?2, error = '' WHERE id = ?1", .{ d.id, now }) catch {};
        } else |err| {
            job.fail(err, lastError());
            log("push to {s} (#{d}): {s}", .{ d.name, d.id, job.why });
            if (err == error.Gone) {
                remove(db, d.id, false, now) catch {};
            } else {
                db.exec("UPDATE push_devices SET error = ?2 WHERE id = ?1", .{ d.id, job.why }) catch {};
            }
        }
    }

    fn fail(job: *Job, err: anyerror, why: []const u8) void {
        job.failed = err;
        job.why = job.arena.allocator().dupe(u8, why) catch "";
    }

    fn free(job: *Job) void {
        const gpa = job.ctx.gpa;
        job.arena.deinit();
        gpa.destroy(job);
    }
};

/// The devices a send is out to.
const InFlight = struct {
    mutex: std.atomic.Mutex = .unlocked,
    ids: [64]i64 = undefined,
    n: usize = 0,

    fn add(self: *InFlight, id: i64) bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (std.mem.indexOfScalar(i64, self.ids[0..self.n], id) != null or self.n == self.ids.len) return false;
        self.ids[self.n] = id;
        self.n += 1;
        return true;
    }

    fn drop(self: *InFlight, id: i64) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const i = std.mem.indexOfScalar(i64, self.ids[0..self.n], id) orelse return;
        self.ids[i] = self.ids[self.n - 1];
        self.n -= 1;
    }
};

var in_flight: InFlight = .{};

const test_wait_ms = 20_000;

/// A test message to one device, now. error.Refused or error.Gone (then the
/// device is removed), with `lastError` saying why; error.Timeout when the
/// push service doesn't answer in time.
pub fn sendTest(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, id: i64) !void {
    last_error_len = 0;
    for (try devices(db, a)) |d| if (d.id == id) {
        const msg = try payload(a, .{ .id = "test", .group = .alert, .kind = "test", .title = "cl", .body = "Notifications work on this device." }, ctx.nowSeconds());
        const job = Job.start(ctx, cfg, d, msg, true) catch |err| {
            if (err == error.StillSending) setLastError("a send to it is still waiting on its push service", .{});
            return if (err == error.StillSending) error.Refused else err;
        };
        var waited: i64 = 0;
        while (waited < test_wait_ms) : (waited += 100) {
            if (job.state.load(.acquire) == Job.done) break;
            ctx.sleepMs(100);
        } else if (job.state.cmpxchgStrong(Job.running, Job.abandoned, .acq_rel, .acquire) == null) {
            setLastError("its push service didn't answer within {d} s", .{test_wait_ms / 1000});
            return error.Refused;
        }
        defer job.free();
        const err = job.failed orelse return;
        setLastError("{s}", .{job.why});
        return if (err == error.Gone) error.Gone else error.Refused;
    };
    return error.NotFound;
}

// ---- the watch, in cl web ----

/// Watch Needs You and notify, every few seconds, for as long as cl web
/// runs. Only one server sends: the one holding `<board dir>/push.lock`
/// (a test server next to the main one doesn't send twice).
pub fn loop(ctx: Ctx, cfg: config.Config, logLine: *const fn ([]const u8) void) void {
    log_line = logLine;
    var lock_file: ?std.Io.File = null;
    var watch: Watch = .{};
    while (true) : (ctx.sleepMs(3000)) {
        if (lock_file == null) {
            lock_file = takeLock(ctx, cfg);
            if (lock_file == null) {
                ctx.sleepMs(30_000);
                continue;
            }
        }
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        tick(ctx, cfg, arena_state.allocator(), &watch) catch |err| log("push: {s}", .{@errorName(err)});
    }
}

fn takeLock(ctx: Ctx, cfg: config.Config) ?std.Io.File {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const dir = board.dirPath(ctx, fba.allocator(), cfg) catch return null;
    const path = std.fmt.allocPrint(fba.allocator(), "{s}/push.lock", .{dir}) catch return null;
    const f = std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = false }) catch return null;
    if (f.tryLock(ctx.io, .exclusive) catch false) return f;
    f.close(ctx.io);
    return null;
}

/// What has been notified. Each flag or alert notifies once, when it first
/// shows in Needs You, as cl-window's attention does: one that leaves while
/// Claude works and comes back doesn't again. The marks (in the board
/// database) carry this over a restart: what landed while no server was
/// watching is newer than them, and still notifies. On the very first run
/// what is already there is taken as seen.
pub const Watch = struct {
    seen: std.StringHashMapUnmanaged(void) = .empty,
    started: bool = false,

    /// The items in `now` that are new, given the marks as stored (`stored`);
    /// returns them and the marks to store.
    pub fn look(self: *Watch, gpa: std.mem.Allocator, a: std.mem.Allocator, now: []const Item, stored: Marks) !struct { []Item, Marks } {
        const first_run = stored.flag < 0 and stored.alert < 0;
        var fresh: std.ArrayList(Item) = .empty;
        for (now) |it| {
            if (self.seen.contains(it.id)) continue;
            try self.seen.put(gpa, try gpa.dupe(u8, it.id), {});
            if (!self.started and (first_run or stored.covers(it))) continue;
            try fresh.append(a, it);
        }
        self.started = true;
        var m = stored.after(now);
        if (first_run) {
            m.flag = @max(m.flag, 0);
            m.alert = @max(m.alert, 0);
        }
        return .{ fresh.items, m };
    }

    pub fn deinit(self: *Watch, gpa: std.mem.Allocator) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.seen.deinit(gpa);
    }
};

/// One message and the devices it goes to.
pub const Send = struct { item: Item, to: []const Device };

/// What to send for the new items: the kinds wanted (`pick`), to each device
/// that is on and not in its quiet hours.
pub fn plan(a: std.mem.Allocator, fresh: []const Item, s: Settings, all: []const Device, now: i64) ![]Send {
    var to: std.ArrayList(Device) = .empty;
    for (all) |d| if (d.enabled and !s.quiet(now, d.tz_offset)) try to.append(a, d);
    var out: std.ArrayList(Send) = .empty;
    if (to.items.len == 0) return out.items;
    for (try pick(a, fresh, s)) |it| try out.append(a, .{ .item = it, .to = to.items });
    return out.items;
}

var alerts_failed = false;

fn tick(ctx: Ctx, cfg: config.Config, a: std.mem.Allocator, watch: *Watch) !void {
    const db = try board.open(ctx, cfg);
    defer db.close();
    const sessions = ticket_watch.readSessions(ctx, cfg, a);
    // No tmux to read alerts from (or it failed): the flags still notify.
    const al = alerts.list(ctx, db, a, false) catch |err| blk: {
        if (!alerts_failed) log("push: can't read alerts ({s}); notifying flags only", .{@errorName(err)});
        alerts_failed = true;
        break :blk &.{};
    };
    const stored = try marks(db);
    const fresh, const m = try watch.look(ctx.gpa, a, try items(a, try ticket_watch.snapshot(db, a, sessions), al), stored);
    if (m.flag != stored.flag or m.alert != stored.alert) try saveMarks(db, m);
    if (fresh.len == 0) return;
    const now = ctx.nowSeconds();
    for (try plan(a, fresh, try settings(db, a), try devices(db, a), now)) |snd| {
        const msg = try payload(a, snd.item, now);
        for (snd.to) |d| _ = Job.start(ctx, cfg, d, msg, false) catch |err| log("push to {s} (#{d}): {s}", .{ d.name, d.id, if (err == error.StillSending) "skipped: the last send is still waiting on its push service" else @errorName(err) });
    }
}

/// What to notify about among the new items: the kinds the human wants,
/// one per ticket (the first new one in Needs You order) and one per alert.
pub fn pick(a: std.mem.Allocator, fresh: []const Item, s: Settings) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (fresh) |it| {
        if (!s.wants(it.group)) continue;
        if (it.group != .alert and it.key.len > 0) {
            for (out.items) |o| {
                if (o.group != .alert and std.mem.eql(u8, o.key, it.key)) break;
            } else try out.append(a, it);
            continue;
        }
        try out.append(a, it);
    }
    return out.items;
}

// ---- helpers ----

fn decode64(a: std.mem.Allocator, s: []const u8) ![]u8 {
    // Browsers give unpadded base64url; take padded too.
    const t = std.mem.trimEnd(u8, std.mem.trim(u8, s, " \t\r\n"), "=");
    const out = try a.alloc(u8, b64.Decoder.calcSizeForSlice(t) catch return error.BadInput);
    b64.Decoder.decode(out, t) catch return error.BadInput;
    return out;
}

fn encode64(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const out = try a.alloc(u8, b64.Encoder.calcSize(raw.len));
    return b64.Encoder.encode(out, raw);
}

/// cl web's log, once `loop` runs.
var log_line: ?*const fn ([]const u8) void = null;

fn log(comptime fmt: []const u8, args: anytype) void {
    const f = log_line orelse return;
    var buf: [512]u8 = undefined;
    f(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

// ---- tests ----

const testing = std.testing;

test "encrypt: RFC 8291's example message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const as_secret = try decode64(a, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    const salt = try decode64(a, "DGv6ra1nlYgDCS1FRnbzlw");
    const ua_public = try decode64(a, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
    const auth = try decode64(a, "BTBZMqHH6r4Tts7J_aSIgg");
    const body = try encrypt(a, "When I grow up, I want to be a watermelon", ua_public, auth, as_secret[0..32].*, salt[0..16].*);
    try testing.expectEqualStrings(
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
        try encode64(a, body),
    );
}

test "vapidHeader: an ES256 JWT for the push service's origin, that verifies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = try Ecdsa.KeyPair.generateDeterministic([_]u8{7} ** 32);
    const h = try vapidHeader(a, kp, "https://fcm.googleapis.com/fcm/send/abc:def", 1000);
    try testing.expect(std.mem.startsWith(u8, h, "vapid t="));
    const t = h["vapid t=".len..std.mem.indexOf(u8, h, ", k=").?];
    const k = h[std.mem.indexOf(u8, h, ", k=").? + 4 ..];
    try testing.expectEqualStrings(try encode64(a, &kp.public_key.toUncompressedSec1()), k);
    var parts = std.mem.splitScalar(u8, t, '.');
    const head = parts.next().?;
    const claims = parts.next().?;
    const sig = try decode64(a, parts.next().?);
    try testing.expectEqualStrings("{\"aud\":\"https://fcm.googleapis.com\",\"exp\":44200,\"sub\":\"" ++ contact ++ "\"}", try decode64(a, claims));
    const signed = t[0 .. head.len + 1 + claims.len];
    try Ecdsa.Signature.fromBytes(sig[0..64].*).verify(signed, kp.public_key);
}

test "Settings: kinds and quiet hours in the device's own time" {
    const s: Settings = .{ .kinds = &.{ .ask, .alert }, .quiet_from = 22 * 60, .quiet_to = 7 * 60 };
    try testing.expect(s.wants(.ask) and s.wants(.alert) and !s.wants(.idle));
    const day = 20_000 * 86400; // a midnight, UTC
    try testing.expect(s.quiet(day + 23 * 3600, 0));
    try testing.expect(s.quiet(day + 3 * 3600, 0));
    try testing.expect(!s.quiet(day + 7 * 3600, 0));
    try testing.expect(!s.quiet(day + 12 * 3600, 0));
    // 12:00 UTC is 23:00 eleven hours east, 21:00 three hours west... of 00:00.
    try testing.expect(s.quiet(day + 12 * 3600, 11 * 60));
    try testing.expect(!s.quiet(day + 0 * 3600, -3 * 60));
    // Not over midnight; and off.
    const work: Settings = .{ .kinds = &.{}, .quiet_from = 9 * 60, .quiet_to = 17 * 60 };
    try testing.expect(work.quiet(day + 10 * 3600, 0) and !work.quiet(day + 18 * 3600, 0));
    try testing.expect(!(Settings{ .kinds = &.{} }).quiet(day, 0));
}

test "items and pick: what notifies, as Needs You has it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flags = [_]ticket_watch.SeenFlag{
        .{ .id = 7, .kind = "question", .detail = "{\"questions\":[{\"question\":\"Which port?\"},{\"question\":\"And the name?\"}]}" },
        .{ .id = 8, .kind = "testing", .detail = "" },
        .{ .id = 9, .kind = "idle", .detail = "", .hidden = true },
    };
    const plan_flags = [_]ticket_watch.SeenFlag{.{ .id = 10, .kind = "review", .detail = "plan" }};
    const base: ticket_watch.Seen = .{ .id = 1, .key = "CL-1", .project = "p", .title = "Fix it", .stage = .running, .hidden = false, .flags = &flags };
    var other = base;
    other.key = "CL-2";
    other.title = "Plan it";
    other.flags = &plan_flags;
    var parked = base;
    parked.key = "CL-3";
    parked.parked = true;
    const al = [_]alerts.Alert{.{ .tmux = "cl_op", .from = "operator", .operator = true, .text = "Look at CL-2", .at = 42, .ticket = "", .project = "" }};
    const its = try items(a, &.{ base, other, parked }, &al);
    try testing.expectEqual(@as(usize, 4), its.len);
    try testing.expectEqualStrings("f7", its[0].id);
    try testing.expectEqualStrings("CL-1: question", its[0].title);
    try testing.expectEqualStrings("Which port? · And the name?\nFix it", its[0].body);
    try testing.expectEqual(Group.review, its[1].group);
    try testing.expectEqualStrings("CL-2: plan ready", its[2].title);
    try testing.expectEqualStrings("Plan it", its[2].body);
    try testing.expectEqualStrings("acl_op@42", its[3].id);
    try testing.expectEqualStrings("Alert from the operator", its[3].title);

    // One per ticket; only the kinds wanted.
    const all = try pick(a, its, .{ .kinds = &.{ .ask, .review, .alert } });
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("f7", all[0].id);
    try testing.expectEqualStrings("f10", all[1].id);
    const no_ask = try pick(a, its, .{ .kinds = &.{.review} });
    try testing.expectEqual(@as(usize, 2), no_ask.len);
    try testing.expectEqualStrings("f8", no_ask[0].id);

    // The message: the board opens on the ticket's tab.
    const m = try std.json.parseFromSliceLeaky(struct { url: []const u8, tag: []const u8, item: []const u8 }, a, try payload(a, its[2], 5), .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("/board?open=CL-2&tab=plan&focus=1", m.url);
    try testing.expectEqualStrings("CL-2", m.tag);
    const am = try std.json.parseFromSliceLeaky(struct { url: []const u8, tag: []const u8 }, a, try payload(a, its[3], 5), .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("/board", am.url);
    try testing.expectEqualStrings("acl_op", am.tag);
}

test "devices: subscribe, update, settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    const p256dh = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
    const id = try subscribe(db, a, 10, .{ .endpoint = "https://push.example/1", .p256dh = p256dh, .auth = "BTBZMqHH6r4Tts7J_aSIgg", .name = "Android · Chrome", .tz_offset = 60 });
    try setEnabled(db, id, false);
    // The same device checking in again keeps it off.
    try testing.expectEqual(id, try subscribe(db, a, 20, .{ .endpoint = "https://push.example/1", .p256dh = p256dh, .auth = "BTBZMqHH6r4Tts7J_aSIgg==", .name = "Android · Chrome", .tz_offset = 120 }));
    const ds = try devices(db, a);
    try testing.expectEqual(@as(usize, 1), ds.len);
    try testing.expect(!ds[0].enabled);
    try testing.expectEqual(@as(i64, 120), ds[0].tz_offset);
    try testing.expectEqual(@as(i64, 20), ds[0].seen);
    try testing.expectError(error.BadInput, subscribe(db, a, 1, .{ .endpoint = "http://x", .p256dh = p256dh, .auth = "BTBZMqHH6r4Tts7J_aSIgg" }));
    try testing.expectError(error.BadInput, subscribe(db, a, 1, .{ .endpoint = "https://x", .p256dh = "AAAA", .auth = "BTBZMqHH6r4Tts7J_aSIgg" }));

    // Settings: all kinds by default, no quiet hours.
    const s0 = try settings(db, a);
    try testing.expectEqual(@as(usize, 6), s0.kinds.len);
    try testing.expect(s0.quiet_from == null);
    try saveSettings(db, a, .{ .kinds = &.{ .ask, .alert }, .quiet_from = 1320, .quiet_to = 420 });
    const s1 = try settings(db, a);
    try testing.expectEqualSlices(Group, &.{ .ask, .alert }, s1.kinds);
    try testing.expectEqual(@as(?u16, 1320), s1.quiet_from);

    // The key pair stays the same once made.
    const k1 = try publicKey(ctx, db, a);
    try testing.expectEqualStrings(k1, try publicKey(ctx, db, a));
    try testing.expectEqual(@as(usize, 87), k1.len);
    try remove(db, id, true, 30);
    try testing.expectEqual(@as(usize, 0), (try devices(db, a)).len);
    try testing.expectError(error.NotFound, remove(db, id, true, 30));
    try testing.expectError(error.NotFound, setEnabled(db, id, true));

    // Removed: the board checking in from it doesn't bring it back; turning
    // it on there does.
    const sub: Subscription = .{ .endpoint = "https://push.example/1", .p256dh = p256dh, .auth = "BTBZMqHH6r4Tts7J_aSIgg" };
    try testing.expectError(error.Removed, subscribe(db, a, 40, sub));
    var again = sub;
    again.explicit = true;
    const id2 = try subscribe(db, a, 40, again);
    try testing.expectEqual(id2, try subscribe(db, a, 50, sub));

    // The browser renewed its subscription: the same row, with its name and
    // its off switch, at the new endpoint.
    try setEnabled(db, id2, false);
    try db.exec("UPDATE push_devices SET name = 'Pixel' WHERE id = ?1", .{id2});
    const id3 = try subscribe(db, a, 60, .{ .endpoint = "https://push.example/2", .p256dh = p256dh, .auth = "BTBZMqHH6r4Tts7J_aSIgg", .old_endpoint = "https://push.example/1" });
    try testing.expectEqual(id2, id3);
    const ds2 = try devices(db, a);
    try testing.expectEqual(@as(usize, 1), ds2.len);
    try testing.expectEqualStrings("https://push.example/2", ds2[0].endpoint);
    try testing.expectEqualStrings("Pixel", ds2[0].name);
    try testing.expect(!ds2[0].enabled);
}

test "Watch: each item once, and what landed while no server watched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q: Item = .{ .id = "f5", .group = .ask, .kind = "question", .key = "CL-1", .title = "", .body = "", .seq = 5 };
    const r: Item = .{ .id = "f9", .group = .review, .kind = "review", .key = "CL-2", .title = "", .body = "", .seq = 9 };
    const al: Item = .{ .id = "acl_x@100", .group = .alert, .kind = "alert", .title = "", .body = "", .seq = 100 };

    // The very first run: what is there is taken as seen.
    var w: Watch = .{};
    defer w.deinit(testing.allocator);
    const f0, const m0 = try w.look(testing.allocator, a, &.{q}, .{});
    try testing.expectEqual(@as(usize, 0), f0.len);
    try testing.expectEqual(Marks{ .flag = 5, .alert = 0 }, m0);
    // New ones notify, once.
    const f1, const m1 = try w.look(testing.allocator, a, &.{ q, r, al }, m0);
    try testing.expectEqual(@as(usize, 2), f1.len);
    try testing.expectEqual(Marks{ .flag = 9, .alert = 100 }, m1);
    try testing.expectEqual(@as(usize, 0), (try w.look(testing.allocator, a, &.{ q, r, al }, m1))[0].len);
    // Out of Needs You (Claude working on it) and back: not again.
    _ = try w.look(testing.allocator, a, &.{al}, m1);
    try testing.expectEqual(@as(usize, 0), (try w.look(testing.allocator, a, &.{ q, r, al }, m1))[0].len);

    // A restart: what the marks cover is old; what landed since isn't.
    var w2: Watch = .{};
    defer w2.deinit(testing.allocator);
    const late: Item = .{ .id = "f12", .group = .ask, .kind = "question", .key = "CL-3", .title = "", .body = "", .seq = 12 };
    const f2, _ = try w2.look(testing.allocator, a, &.{ q, r, al, late }, m1);
    try testing.expectEqual(@as(usize, 1), f2.len);
    try testing.expectEqualStrings("f12", f2[0].id);
}

test "plan: devices that are off or in quiet hours get nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q: Item = .{ .id = "f5", .group = .ask, .kind = "question", .key = "CL-1", .title = "", .body = "", .seq = 5 };
    const idle: Item = .{ .id = "f6", .group = .idle, .kind = "idle", .key = "CL-2", .title = "", .body = "", .seq = 6 };
    const base: Device = .{ .id = 1, .endpoint = "", .p256dh = "", .auth = "", .name = "", .enabled = true, .tz_offset = 0, .created = 0, .seen = 0, .sent = 0, .@"error" = "" };
    var off = base;
    off.id = 2;
    off.enabled = false;
    var night = base;
    night.id = 3;
    night.tz_offset = 12 * 60; // midnight there at noon UTC
    const s: Settings = .{ .kinds = &.{.ask}, .quiet_from = 22 * 60, .quiet_to = 7 * 60 };
    const noon = 20_000 * 86400 + 12 * 3600;
    const sends = try plan(a, &.{ q, idle }, s, &.{ base, off, night }, noon);
    try testing.expectEqual(@as(usize, 1), sends.len);
    try testing.expectEqualStrings("f5", sends[0].item.id);
    try testing.expectEqual(@as(usize, 1), sends[0].to.len);
    try testing.expectEqual(@as(i64, 1), sends[0].to[0].id);
    try testing.expectEqual(@as(usize, 0), (try plan(a, &.{q}, s, &.{ off, night }, noon)).len);
}

test "actionsFor: the buttons each kind of item gets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: ticket_watch.Seen = .{ .id = 1, .key = "CL-1", .project = "p", .title = "T", .stage = .running, .hidden = false, .flags = &.{} };
    const names = struct {
        fn of(a2: std.mem.Allocator, acts: []const Action) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (acts) |x| try out.print(a2, "{s}={s};", .{ x.action, x.title });
            return out.items;
        }
    }.of;
    // A lone single-choice question: its first three options.
    const q = try actionsFor(a, t, .{ .id = 1, .kind = "question", .detail = "{\"questions\":[{\"question\":\"Port?\",\"options\":[{\"label\":\"8080\"},{\"label\":\"9090\"},{\"label\":\"Either\"},{\"label\":\"None\"}]}]}" });
    try testing.expectEqualStrings("answer:1=8080;answer:2=9090;answer:3=Either;", try names(a, q));
    // Two questions, or a multi-select one: the compact view answers those.
    try testing.expectEqual(@as(usize, 0), (try actionsFor(a, t, .{ .id = 1, .kind = "question", .detail = "{\"questions\":[{\"question\":\"A?\",\"options\":[{\"label\":\"x\"}]},{\"question\":\"B?\"}]}" })).len);
    try testing.expectEqual(@as(usize, 0), (try actionsFor(a, t, .{ .id = 1, .kind = "question", .detail = "{\"questions\":[{\"question\":\"A?\",\"multiSelect\":true,\"options\":[{\"label\":\"x\"}]}]}" })).len);
    // A permission prompt: its first two options, by their numbers.
    const p = try actionsFor(a, t, .{ .id = 1, .kind = "input", .detail = "{\"tool\":\"Bash\",\"options\":[{\"n\":1,\"label\":\"Yes\"},{\"n\":2,\"label\":\"Yes, always\"},{\"n\":3,\"label\":\"No\"}]}" });
    try testing.expectEqualStrings("answer:1=Yes;answer:2=Yes, always;", try names(a, p));
    // A plan ready: Approve plan.
    var planning = t;
    planning.stage = .planning;
    try testing.expectEqualStrings("approve=Approve plan;", try names(a, try actionsFor(a, planning, .{ .id = 1, .kind = "review", .detail = "plan" })));
    // Not an umbrella's with no sub-tickets yet: approving it is refused.
    planning.empty_umbrella = true;
    try testing.expectEqual(@as(usize, 0), (try actionsFor(a, planning, .{ .id = 1, .kind = "review", .detail = "plan" })).len);
    // Review or test: Merge, only for work Merge can land.
    var rev = t;
    rev.stage = .review;
    try testing.expectEqual(@as(usize, 0), (try actionsFor(a, rev, .{ .id = 1, .kind = "review", .detail = "" })).len);
    rev.mergeable = true;
    try testing.expectEqualStrings("merge=Merge;", try names(a, try actionsFor(a, rev, .{ .id = 1, .kind = "review", .detail = "" })));
    rev.stage = .testing;
    try testing.expectEqualStrings("merge=Merge;", try names(a, try actionsFor(a, rev, .{ .id = 1, .kind = "testing", .detail = "" })));
    // What doesn't wait on you: Dismiss. What does (idle, a conflict): nothing.
    try testing.expectEqualStrings("dismiss=Dismiss;", try names(a, try actionsFor(a, t, .{ .id = 1, .kind = "after-merge", .detail = "boom" })));
    try testing.expectEqual(@as(usize, 0), (try actionsFor(a, t, .{ .id = 1, .kind = "idle", .detail = "" })).len);
    try testing.expectEqual(@as(usize, 0), (try actionsFor(a, t, .{ .id = 1, .kind = "conflict", .detail = "a.zig" })).len);

    // The payload carries them for the service worker.
    const its = try items(a, &.{.{ .id = 1, .key = "CL-1", .project = "p", .title = "T", .stage = .planning, .hidden = false, .flags = &.{.{ .id = 4, .kind = "review", .detail = "plan" }} }}, &.{});
    const m = try std.json.parseFromSliceLeaky(struct { item: []const u8, actions: []const Action }, a, try payload(a, its[0], 5), .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("f4", m.item);
    try testing.expectEqualStrings("approve", m.actions[0].action);
    // A question's carries which question it is.
    const qs = try items(a, &.{.{ .id = 1, .key = "CL-1", .project = "p", .title = "T", .stage = .running, .hidden = false, .flags = &.{.{ .id = 5, .kind = "question", .detail = "{}" }} }}, &.{});
    const qm = try std.json.parseFromSliceLeaky(struct { ask: []const u8 }, a, try payload(a, qs[0], 5), .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(try askHash(a, "{}"), qm.ask);
}

test "act: a notification's button does what the board's would, once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = a, .env = &env, .home = "/tmp", .tmux_blocked = true };
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    const db = try board.Db.open(":memory:");
    defer db.close();
    try board.migrate(db);
    try board.addProject(db, .{ .name = "qa", .dir = "/x" });
    const flagItem = struct {
        fn of(a2: std.mem.Allocator, db2: board.Db, key: []const u8, kind: []const u8) ![]const u8 {
            const id = (try db2.int("SELECT f.id FROM flags f JOIN tickets t ON t.id = f.ticket WHERE t.key = ?1 AND f.kind = ?2 AND f.cleared IS NULL", .{ key, kind })) orelse return error.NoFlag;
            return std.fmt.allocPrint(a2, "f{d}", .{id});
        }
    }.of;

    // Approve plan: to Queued; the same button again finds it dealt with.
    const k = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Plan it", .stage = .planning });
    try board.setFlag(ctx, db, a, k, "review", "auto", "plan");
    const plan_item = try flagItem(a, db, k, "review");
    try testing.expectError(error.BadAction, act(ctx, cfg, db, a, plan_item, "merge", ""));
    try testing.expectError(error.BadAction, act(ctx, cfg, db, a, plan_item, "answer:1", ""));
    try testing.expectEqualStrings("Kn: plan approved; a new session builds it", try std.mem.replaceOwned(u8, a, (try act(ctx, cfg, db, a, plan_item, "approve", "")).message, k, "Kn"));
    try testing.expectEqual(board.Stage.queued, (try board.getTicket(db, a, k)).stage);
    try testing.expectError(error.Handled, act(ctx, cfg, db, a, plan_item, "approve", ""));
    // An umbrella's plan: refused while nothing is filed under it, then its sub-tickets queue.
    const ku = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Plan tickets", .stage = .planning, .umbrella = true });
    try board.setFlag(ctx, db, a, ku, "review", "auto", "plan");
    const u_item = try flagItem(a, db, ku, "review");
    try testing.expectError(error.NoSubtickets, act(ctx, cfg, db, a, u_item, "approve", ""));
    _ = try board.createTicket(ctx, db, a, .{ .parent = ku, .title = "One" });
    try testing.expectEqualStrings("Kn: plan approved; its sub-tickets are queued", try std.mem.replaceOwned(u8, a, (try act(ctx, cfg, db, a, u_item, "approve", "")).message, ku, "Kn"));

    // Dismiss: only what doesn't wait on you; then it's gone.
    try board.setFlag(ctx, db, a, k, "after-merge", "auto", "make failed");
    const am = try flagItem(a, db, k, "after-merge");
    _ = try act(ctx, cfg, db, a, am, "dismiss", "");
    try testing.expectError(error.Handled, act(ctx, cfg, db, a, am, "dismiss", ""));
    try board.setFlag(ctx, db, a, k, "conflict", "auto", "a.zig");
    try testing.expectError(error.WaitingFlag, act(ctx, cfg, db, a, try flagItem(a, db, k, "conflict"), "dismiss", ""));

    // Merge: not for work with no branch of its own.
    const r = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Review it", .stage = .review });
    try board.setFlag(ctx, db, a, r, "review", "auto", "");
    try testing.expectError(error.BadAction, act(ctx, cfg, db, a, try flagItem(a, db, r, "review"), "merge", ""));

    // Merge: past act's checks to the move itself (a git branch with no
    // session to merge it in); not while finishing, nor with a custom close.
    try db.exec("UPDATE tickets SET branch = 'r' WHERE key = ?1", .{r});
    const rev = try flagItem(a, db, r, "review");
    try testing.expectError(error.NoSession, act(ctx, cfg, db, a, rev, "merge", ""));
    try db.exec("UPDATE tickets SET custom_close = 'leave it' WHERE key = ?1", .{r});
    try testing.expectError(error.CustomClose, act(ctx, cfg, db, a, rev, "merge", ""));
    try db.exec("UPDATE tickets SET custom_close = '', finishing = 'merge' WHERE key = ?1", .{r});
    try testing.expectError(error.Handled, act(ctx, cfg, db, a, rev, "merge", ""));

    // Answers: only to the question the notification showed. A newer one in
    // the same flag row (its detail replaced) is Handled.
    const q = try board.createTicket(ctx, db, a, .{ .project = "qa", .title = "Ask", .stage = .running });
    const first = "{\"questions\":[{\"question\":\"Port?\"}]}";
    try board.setFlag(ctx, db, a, q, "question", "auto", first);
    const qi = try flagItem(a, db, q, "question");
    try testing.expectError(error.BadAction, act(ctx, cfg, db, a, qi, "answer:x", try askHash(a, first)));
    try testing.expectError(error.WaitingFlag, act(ctx, cfg, db, a, qi, "dismiss", try askHash(a, first)));
    // The right question: on to the session (none here).
    try testing.expectError(error.NoSession, act(ctx, cfg, db, a, qi, "answer:1", try askHash(a, first)));
    try testing.expectError(error.Handled, act(ctx, cfg, db, a, qi, "answer:1", ""));
    try board.setFlag(ctx, db, a, q, "question", "auto", "{\"questions\":[{\"question\":\"Delete it?\"}]}");
    try testing.expectEqualStrings(qi, try flagItem(a, db, q, "question"));
    try testing.expectError(error.Handled, act(ctx, cfg, db, a, qi, "answer:1", try askHash(a, first)));

    // Alerts: only Dismiss, and only a well-formed id.
    try testing.expectError(error.BadAction, act(ctx, cfg, db, a, "acl_x@5", "approve", ""));
    try testing.expectError(error.BadInput, act(ctx, cfg, db, a, "acl_x@soon", "dismiss", ""));

    try testing.expectError(error.BadInput, act(ctx, cfg, db, a, "fx", "dismiss", ""));
    try testing.expectError(error.Handled, act(ctx, cfg, db, a, "f9999", "dismiss", ""));
}

test "flagLabel: the push and CI flags read as words" {
    try std.testing.expectEqualStrings("push failed", flagLabel(.{ .id = 1, .kind = board.flag_push_failed, .detail = "" }));
    try std.testing.expectEqualStrings("CI failed", flagLabel(.{ .id = 2, .kind = board.flag_ci_failed, .detail = "" }));
}
