const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Linux builds default to musl: static binaries that run anywhere, and
    // linking libc (for SQLite) doesn't depend on the host's glibc.
    var query = b.standardTargetOptionsQueryOnly(.{});
    if (query.abi == null and (query.os_tag orelse builtin.os.tag) == .linux) query.abi = .musl;
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    // SQLite for the ticket board, compiled from the amalgamation so the
    // binaries stay self-contained.
    const sqlite = b.dependency("sqlite", .{});
    const sqlite_c = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "cl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                .{ .name = "sqlite", .module = sqlite_c.createModule() },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
        },
    });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/sqlite_shim.c") });
    exe.root_module.addIncludePath(sqlite.path(""));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run cl").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
