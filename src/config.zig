//! Profiles: a name -> Claude config dir mapping, read from ~/.config/cl/config.
//!
//!   default = work
//!   operator = work
//!   work = ~/.claude-work
//!   personal = ~/.claude
//!
//!   web.autostart = true
//!   web.listen = 127.0.0.1:8421, tailscale:8421
//!   web.password = $argon2id$...      (from `cl web hash`)
//!
//! `default`, `operator` and dotted keys are settings; every other key is a
//! profile. `operator` picks the operator's profile and falls back to `default`.
//!
//! When CLAUDE_CONFIG_DIR is set in the environment it overrides `default`:
//! the profile with that directory is used, or one named after the directory
//! is added if none matches.
const std = @import("std");
const Ctx = @import("ctx.zig");

pub const Profile = struct {
    name: []const u8,
    /// Absolute Claude config dir, or null to leave CLAUDE_CONFIG_DIR alone.
    config_dir: ?[]const u8,
};

pub const Config = struct {
    profiles: []Profile,
    default: []const u8,
    /// Profile for the operator session. Not affected by CLAUDE_CONFIG_DIR.
    operator: []const u8,
    web: Web = .{},

    pub fn find(self: Config, name: []const u8) ?Profile {
        for (self.profiles) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    pub fn defaultProfile(self: Config) Profile {
        return self.find(self.default) orelse self.profiles[0];
    }
};

pub const Web = struct {
    /// Start `cl web` in the background whenever cl launches, lists or attaches.
    autostart: bool = false,
    /// Comma-separated host:port list; the host `tailscale` means this machine's tailnet IPv4.
    listen: []const u8 = "127.0.0.1:8421",
    /// argon2id PHC string; the server refuses to start without one.
    password: []const u8 = "",
};

pub fn load(ctx: Ctx) !Config {
    const path = try std.fmt.allocPrint(ctx.perm, "{s}/.config/cl/config", .{ctx.home});
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.perm, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return fallback(ctx),
        else => return err,
    };

    var profiles: std.ArrayList(Profile) = .empty;
    var default: ?[]const u8 = null;
    var operator: ?[]const u8 = null;
    var web: Web = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "default")) {
            default = val;
        } else if (std.mem.eql(u8, key, "operator")) {
            operator = val;
        } else if (std.mem.eql(u8, key, "web.autostart")) {
            web.autostart = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "on");
        } else if (std.mem.eql(u8, key, "web.listen")) {
            web.listen = val;
        } else if (std.mem.eql(u8, key, "web.password")) {
            web.password = val;
        } else if (std.mem.indexOfScalar(u8, key, '.') != null) {
            continue; // unknown setting
        } else {
            try profiles.append(ctx.perm, .{ .name = key, .config_dir = try expandHomePerm(ctx, val) });
        }
    }
    if (profiles.items.len == 0) {
        var c = try fallback(ctx);
        c.web = web;
        return c;
    }
    const operator_profile = operator orelse default orelse profiles.items[0].name;
    if (ctx.env.get("CLAUDE_CONFIG_DIR")) |env_dir| {
        default = try fromEnv(ctx, &profiles, env_dir);
    }
    return .{
        .profiles = try profiles.toOwnedSlice(ctx.perm),
        .default = default orelse profiles.items[0].name,
        .operator = operator_profile,
        .web = web,
    };
}

/// Return the name of the profile whose config dir is `env_dir`, adding one if needed.
fn fromEnv(ctx: Ctx, profiles: *std.ArrayList(Profile), env_dir: []const u8) ![]const u8 {
    const want = std.mem.trimEnd(u8, try expandHomePerm(ctx, env_dir), "/");
    for (profiles.items) |p| {
        const have = std.mem.trimEnd(u8, p.config_dir orelse continue, "/");
        if (std.mem.eql(u8, have, want)) return p.name;
    }
    const base = std.fs.path.basename(want);
    const name = std.mem.trimStart(u8, base, ".");
    try profiles.append(ctx.perm, .{ .name = if (name.len > 0) name else "env", .config_dir = want });
    return profiles.items[profiles.items.len - 1].name;
}

fn fallback(ctx: Ctx) !Config {
    const profiles = try ctx.perm.alloc(Profile, 1);
    profiles[0] = .{ .name = "default", .config_dir = null };
    return .{ .profiles = profiles, .default = "default", .operator = "default" };
}

fn expandHomePerm(ctx: Ctx, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        return std.fmt.allocPrint(ctx.perm, "{s}{s}", .{ ctx.home, path[1..] });
    }
    return path;
}
