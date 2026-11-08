//! Images pasted into a ticket's description on the board. They live with the
//! board, never in a project's repository:
//!
//!   <board.dir>/images/<KEY>/<hash>.<ext>   a ticket's images
//!   <board.dir>/images/new/<hash>.<ext>     pasted into the New ticket dialog,
//!                                           before the ticket has a key
//!
//! The description refers to each by its absolute path, as a Markdown image
//! (`![image](/abs/path.png)`): the board shows it inline, and the session's
//! first message lists the paths for Claude to open with its Read tool (Claude
//! Code doesn't attach an image from a path in a message; Read of an image
//! file shows it the image). Creating a ticket copies the staged images it
//! refers to into its own folder; deleting the ticket deletes that folder.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const board = @import("board.zig");

/// The most an upload may be.
pub const max_bytes = 10 * 1024 * 1024;

/// Where images for the New ticket dialog wait for their ticket.
pub const staging = "new";

/// Staged images nobody created a ticket with go after this long.
const staging_max_age = 24 * 3600;

/// `<board.dir>/images`.
pub fn root(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/images", .{try board.dirPath(ctx, a, cfg)});
}

/// The image type `data` is, by its first bytes, as a file extension; null
/// for anything but png, jpeg, gif and webp.
pub fn detect(data: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "png";
    if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) return "jpg";
    if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) return "gif";
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "webp";
    return null;
}

/// The content type to serve a file with this extension as.
pub fn contentType(ext: []const u8) ?[]const u8 {
    const types = .{ .{ "png", "image/png" }, .{ "jpg", "image/jpeg" }, .{ "gif", "image/gif" }, .{ "webp", "image/webp" } };
    inline for (types) |t| if (std.mem.eql(u8, ext, t[0])) return t[1];
    return null;
}

/// A folder name under images/: a ticket key or `staging`.
pub fn validOwner(s: []const u8) bool {
    if (s.len == 0 or s.len > 40) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

/// A file name as `save` makes them: lowercase hex, a dot, a known extension.
pub fn validName(s: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return false;
    if (dot == 0) return false;
    for (s[0..dot]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return contentType(s[dot + 1 ..]) != null;
}

/// Store an image for `owner` (a ticket key, or `staging`) and return its
/// absolute path. Named by its content, so pasting it twice keeps one copy.
pub fn save(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, owner: []const u8, data: []const u8) ![]const u8 {
    if (!validOwner(owner)) return error.BadInput;
    const ext = detect(data) orelse return error.BadInput;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ try root(ctx, a, cfg), owner });
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    if (std.mem.eql(u8, owner, staging)) pruneStaging(ctx, a, dir);
    const path = try std.fmt.allocPrint(a, "{s}/{x}.{s}", .{ dir, hash[0..8], ext });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
    return path;
}

/// Delete staged images older than a day: their dialog was closed unsaved.
fn pruneStaging(ctx: Ctx, a: std.mem.Allocator, dir_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    const cutoff = ctx.nowSeconds() - staging_max_age;
    var old: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = dir.statFile(ctx.io, e.name, .{}) catch continue;
        if (st.mtime.toSeconds() < cutoff) old.append(a, a.dupe(u8, e.name) catch continue) catch continue;
    }
    for (old.items) |name| dir.deleteFile(ctx.io, name) catch {};
}

/// Move the staged images `body` refers to into ticket `key`'s folder and
/// return the body pointing at them there; null when it refers to none.
/// They are copied: another open dialog may have pasted the same image.
pub fn adopt(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, key: []const u8, body: []const u8) !?[]const u8 {
    const r = try root(ctx, a, cfg);
    const from = try std.fmt.allocPrint(a, "{s}/{s}/", .{ r, staging });
    if (std.mem.indexOf(u8, body, from) == null or !validOwner(key)) return null;
    const to = try std.fmt.allocPrint(a, "{s}/{s}/", .{ r, key });
    try std.Io.Dir.cwd().createDirPath(ctx.io, to);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, from)) |at| {
        const start = at + from.len;
        var end = start;
        while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '.')) end += 1;
        i = end;
        const name = body[start..end];
        if (!validName(name)) continue;
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, try std.mem.concat(a, u8, &.{ from, name }), a, .limited(max_bytes)) catch continue;
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = try std.mem.concat(a, u8, &.{ to, name }), .data = data });
    }
    return try std.mem.replaceOwned(u8, a, body, from, to);
}

/// Delete ticket `key`'s images.
pub fn removeTicket(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, key: []const u8) void {
    if (!validOwner(key) or std.mem.eql(u8, key, staging)) return;
    const r = root(ctx, a, cfg) catch return;
    const dir = std.fmt.allocPrint(a, "{s}/{s}", .{ r, key }) catch return;
    std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
}

/// The images a description shows: each `![alt](/absolute/path.ext)` with an
/// image extension, in order, without repeats.
pub fn paths(a: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "![")) |at| {
        i = at + 2;
        const close = std.mem.indexOfPos(u8, body, i, "](") orelse break;
        if (std.mem.indexOfScalar(u8, body[i..close], '\n') != null) continue;
        const start = close + 2;
        const end = std.mem.indexOfScalarPos(u8, body, start, ')') orelse break;
        i = end;
        const p = body[start..end];
        if (p.len < 2 or p[0] != '/' or std.mem.indexOfAny(u8, p, " \n\t") != null) continue;
        const ext = std.fs.path.extension(p);
        if (ext.len < 2 or (contentType(ext[1..]) == null and !std.ascii.eqlIgnoreCase(ext, ".jpeg"))) continue;
        for (out.items) |q| {
            if (std.mem.eql(u8, q, p)) break;
        } else try out.append(a, p);
    }
    return out.toOwnedSlice(a);
}

/// Tell the session about the description's images (nothing when it has
/// none): it sees them only by opening them.
pub fn writeNote(w: *std.Io.Writer, a: std.mem.Allocator, body: []const u8) !void {
    const ps = try paths(a, body);
    if (ps.len == 0) return;
    try w.writeAll(if (ps.len == 1)
        "\nThe description has an image (pasted on the board). Open it with your Read tool to see it:\n"
    else
        "\nThe description has images (pasted on the board). Open each with your Read tool to see it:\n");
    for (ps) |p| try w.print("- {s}\n", .{p});
}

/// Ticket `key`'s image folder, when it has one (for --add-dir).
pub fn ticketDir(ctx: Ctx, a: std.mem.Allocator, cfg: config.Config, key: []const u8) ?[]const u8 {
    if (!validOwner(key)) return null;
    const dir = std.fmt.allocPrint(a, "{s}/{s}", .{ root(ctx, a, cfg) catch return null, key }) catch return null;
    const st = std.Io.Dir.cwd().statFile(ctx.io, dir, .{}) catch return null;
    return if (st.kind == .directory) dir else null;
}

const testing = std.testing;

test detect {
    try testing.expectEqualStrings("png", detect("\x89PNG\r\n\x1a\nrest").?);
    try testing.expectEqualStrings("jpg", detect("\xff\xd8\xff\xe0").?);
    try testing.expectEqualStrings("gif", detect("GIF89a..").?);
    try testing.expectEqualStrings("webp", detect("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try testing.expectEqual(@as(?[]const u8, null), detect("<svg xmlns="));
    try testing.expectEqual(@as(?[]const u8, null), detect(""));
}

test "names and owners" {
    try testing.expect(validName("0123abcd.png"));
    try testing.expect(!validName("../x.png"));
    try testing.expect(!validName("abc.svg"));
    try testing.expect(!validName(".png"));
    try testing.expect(validOwner("CL-59"));
    try testing.expect(validOwner(staging));
    try testing.expect(!validOwner(".."));
    try testing.expect(!validOwner("a/b"));
}

test paths {
    const body =
        \\Look: ![shot](/s/images/CL-1/ab.png) and again ![x](/s/images/CL-1/ab.png)
        \\![rel](images/x.png) [link](/s/doc.png) ![svg](/s/a.svg) ![j](/s/b.JPEG)
        \\![broken
        \\](/s/c.png) ![w](/s/d.webp)
    ;
    const ps = try paths(testing.allocator, body);
    defer testing.allocator.free(ps);
    try testing.expectEqual(@as(usize, 3), ps.len);
    try testing.expectEqualStrings("/s/images/CL-1/ab.png", ps[0]);
    try testing.expectEqualStrings("/s/b.JPEG", ps[1]);
    try testing.expectEqualStrings("/s/d.webp", ps[2]);
}

test "save, adopt, remove" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const ctx: Ctx = .{ .io = testing.io, .gpa = testing.allocator, .perm = testing.allocator, .env = Ctx.testEnv(), .home = "/nonexistent" };
    var cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "" };
    cfg.board.dir = dir;
    const png = "\x89PNG\r\n\x1a\nfake";
    try testing.expectError(error.BadInput, save(ctx, a, cfg, staging, "not an image"));
    try testing.expectError(error.BadInput, save(ctx, a, cfg, "../x", png));
    const p = try save(ctx, a, cfg, staging, png);
    try testing.expect(std.mem.startsWith(u8, p, try std.fmt.allocPrint(a, "{s}/images/new/", .{dir})));
    try testing.expect(validName(std.fs.path.basename(p)));
    // The same image again: the same file.
    try testing.expectEqualStrings(p, try save(ctx, a, cfg, staging, png));

    try testing.expectEqual(@as(?[]const u8, null), try adopt(ctx, a, cfg, "QA-1", "no images"));
    const body = try std.fmt.allocPrint(a, "see ![image]({s}) twice ![image]({s})", .{ p, p });
    const moved = (try adopt(ctx, a, cfg, "QA-1", body)).?;
    const want = try std.fmt.allocPrint(a, "{s}/images/QA-1/{s}", .{ dir, std.fs.path.basename(p) });
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "see ![image]({s}) twice ![image]({s})", .{ want, want }), moved);
    try testing.expectEqualStrings(png, try std.Io.Dir.cwd().readFileAlloc(testing.io, want, a, .limited(100)));
    try testing.expect(ticketDir(ctx, a, cfg, "QA-1") != null);

    removeTicket(ctx, a, cfg, "QA-1");
    try testing.expect(ticketDir(ctx, a, cfg, "QA-1") == null);
    // The staged copy stays for other dialogs, until it's a day old.
    try testing.expect(ticketDir(ctx, a, cfg, staging) != null);
}
