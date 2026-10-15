//! Turn `tmux capture-pane -e` output (text with SGR escapes) into styled segments.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Segment = vaxis.Segment;

/// Split one line into segments. Non-SGR escape sequences are dropped.
pub fn parseLine(arena: std.mem.Allocator, line: []const u8, start: vaxis.Style) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    var style = start;
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            if (i > run_start) try segs.append(arena, .{ .text = line[run_start..i], .style = style });
            // CSI: parameters until a final byte in 0x40..0x7e
            var j = i + 2;
            while (j < line.len and (line[j] < 0x40 or line[j] > 0x7e)) : (j += 1) {}
            if (j >= line.len) break;
            if (line[j] == 'm') applySgr(&style, line[i + 2 .. j]);
            i = j + 1;
            run_start = i;
        } else if (line[i] == 0x1b) {
            // Other escapes (OSC etc.): skip ESC and the next byte.
            if (i > run_start) try segs.append(arena, .{ .text = line[run_start..i], .style = style });
            i += 2;
            run_start = @min(i, line.len);
        } else {
            i += 1;
        }
    }
    if (run_start < line.len) try segs.append(arena, .{ .text = line[run_start..], .style = style });
    return segs.toOwnedSlice(arena);
}

fn applySgr(style: *vaxis.Style, params: []const u8) void {
    if (params.len == 0) {
        style.* = .{};
        return;
    }
    var nums: [32]u16 = undefined;
    var n: usize = 0;
    var it = std.mem.splitAny(u8, params, ";:");
    while (it.next()) |p| {
        if (n == nums.len) break;
        nums[n] = std.fmt.parseInt(u16, p, 10) catch 0;
        n += 1;
    }
    var k: usize = 0;
    while (k < n) : (k += 1) {
        switch (nums[k]) {
            0 => style.* = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.ul_style = .single,
            5 => style.blink = true,
            7 => style.reverse = true,
            8 => style.invisible = true,
            9 => style.strikethrough = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.ul_style = .off,
            25 => style.blink = false,
            27 => style.reverse = false,
            28 => style.invisible = false,
            29 => style.strikethrough = false,
            30...37 => style.fg = .{ .index = @intCast(nums[k] - 30) },
            39 => style.fg = .default,
            40...47 => style.bg = .{ .index = @intCast(nums[k] - 40) },
            49 => style.bg = .default,
            90...97 => style.fg = .{ .index = @intCast(nums[k] - 90 + 8) },
            100...107 => style.bg = .{ .index = @intCast(nums[k] - 100 + 8) },
            38, 48, 58 => {
                const color = extended(nums[0..n], &k) orelse continue;
                switch (nums[k]) {
                    38 => style.fg = color,
                    48 => style.bg = color,
                    else => style.ul = color,
                }
            },
            else => {},
        }
    }
}

/// Parse "38;5;n" or "38;2;r;g;b" starting at nums[k.*]; advances k past the color.
fn extended(nums: []const u16, k: *usize) ?vaxis.Color {
    const base = k.*;
    if (base + 1 >= nums.len) return null;
    switch (nums[base + 1]) {
        5 => {
            if (base + 2 >= nums.len) return null;
            defer k.* = base + 2;
            return .{ .index = @intCast(nums[base + 2] & 0xff) };
        },
        2 => {
            if (base + 4 >= nums.len) return null;
            defer k.* = base + 4;
            return .{ .rgb = .{ @intCast(nums[base + 2] & 0xff), @intCast(nums[base + 3] & 0xff), @intCast(nums[base + 4] & 0xff) } };
        },
        else => return null,
    }
}

test "basic sgr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const segs = try parseLine(arena.allocator(), "a\x1b[1;31mb\x1b[0mc", .{});
    try std.testing.expectEqual(3, segs.len);
    try std.testing.expect(segs[1].style.bold);
    try std.testing.expectEqual(vaxis.Color{ .index = 1 }, segs[1].style.fg);
    try std.testing.expectEqualStrings("c", segs[2].text);
}
