//! Profiles: a name -> Claude config dir mapping, read from ~/.config/cl/config.
//!
//!   default = work
//!   work = ~/.claude-work
//!   personal = ~/.claude
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

    pub fn find(self: Config, name: []const u8) ?Profile {
        for (self.profiles) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    pub fn defaultProfile(self: Config) Profile {
        return self.find(self.default) orelse self.profiles[0];
    }
};

pub fn load(ctx: Ctx) !Config {
    const path = try std.fmt.allocPrint(ctx.perm, "{s}/.config/cl/config", .{ctx.home});
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.perm, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return fallback(ctx),
        else => return err,
    };

    var profiles: std.ArrayList(Profile) = .empty;
    var default: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "default")) {
            default = val;
        } else {
            try profiles.append(ctx.perm, .{ .name = key, .config_dir = try expandHomePerm(ctx, val) });
        }
    }
    if (profiles.items.len == 0) return fallback(ctx);
    return .{
        .profiles = try profiles.toOwnedSlice(ctx.perm),
        .default = default orelse profiles.items[0].name,
    };
}

fn fallback(ctx: Ctx) !Config {
    const profiles = try ctx.perm.alloc(Profile, 1);
    profiles[0] = .{ .name = "default", .config_dir = null };
    return .{ .profiles = profiles, .default = "default" };
}

fn expandHomePerm(ctx: Ctx, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        return std.fmt.allocPrint(ctx.perm, "{s}{s}", .{ ctx.home, path[1..] });
    }
    return path;
}
