//! Alerts: `cl alert <text>` raised by a session (the operator, or any cl
//! session) for the human. tmux is the store, as for everything about a
//! session: each session holds at most one (@cl_alert, @cl_alert_at,
//! @cl_alert_ticket), so a new one from the same session replaces the last,
//! and it goes with the session. The chooser, the web board's Needs You and
//! `cl ticket needs` all read them from here. Opening the session (tmux.attach)
//! or dismissing the alert clears it everywhere.
const std = @import("std");
const Ctx = @import("ctx.zig");
const tmux = @import("tmux.zig");
const board = @import("board.zig");

pub const Alert = struct {
    /// The tmux session that raised it.
    tmux: []const u8,
    /// Who raised it: "operator", or the session's name.
    from: []const u8,
    operator: bool,
    text: []const u8,
    /// When it was raised (unix seconds).
    at: i64,
    /// The ticket it is about ("" for none) and that ticket's project.
    ticket: []const u8,
    project: []const u8,
};

/// Every pending alert, oldest first. Hidden sessions' are left out (the human
/// hid them to stop hearing about them), and so, unless `hidden_projects`, are
/// those about a hidden project's ticket.
pub fn list(ctx: Ctx, db: board.Db, a: std.mem.Allocator, hidden_projects: bool) ![]Alert {
    var out: std.ArrayList(Alert) = .empty;
    for (try tmux.listAll(ctx, a)) |s| {
        if (s.alert.len == 0 or s.hidden or std.mem.eql(u8, s.role, tmux.web_role)) continue;
        const is_op = std.mem.eql(u8, s.role, tmux.operator_role);
        var key = s.alert_ticket;
        var project: []const u8 = "";
        if (key.len > 0) {
            if (board.getTicket(db, a, key)) |t| {
                key = t.key;
                project = t.project;
                const hidden = if (board.getProject(db, a, t.project)) |p| p.hidden else |_| false;
                if (hidden and !hidden_projects) continue;
            } else |_| {}
        }
        try out.append(a, .{
            .tmux = s.tmux_name,
            .from = if (is_op) "operator" else s.name,
            .operator = is_op,
            .text = s.alert,
            .at = s.alert_at,
            .ticket = key,
            .project = project,
        });
    }
    std.mem.sort(Alert, out.items, {}, struct {
        fn lt(_: void, x: Alert, y: Alert) bool {
            return x.at < y.at;
        }
    }.lt);
    return out.items;
}

/// Dismiss the alert of the session `tmux_name` (a cl session); false if it
/// had none (already cleared, or the session is gone).
pub fn dismiss(ctx: Ctx, a: std.mem.Allocator, tmux_name: []const u8) !bool {
    for (try tmux.listAll(ctx, a)) |s| if (std.mem.eql(u8, s.tmux_name, tmux_name)) {
        if (s.alert.len == 0) return false;
        try tmux.clearAlert(ctx, s.tmux_name);
        return true;
    };
    return false;
}

/// The text as one line: the session listing (tmux.list_format) is tab- and
/// line-separated, so tabs and line breaks become spaces, and the ends are trimmed.
pub fn oneLine(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = try a.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
    for (t) |*c| if (c.* == '\t' or c.* == '\n' or c.* == '\r') {
        c.* = ' ';
    };
    return t;
}

test oneLine {
    const a = std.testing.allocator;
    const t = try oneLine(a, "  CL-3 needs you\n\tsoon\r\n");
    defer a.free(t);
    try std.testing.expectEqualStrings("CL-3 needs you  soon", t);
}
