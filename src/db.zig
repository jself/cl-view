//! A small SQLite wrapper: open, run statements with bound arguments, step
//! through rows. Errors come back as error.Sqlite; `Db.message` says why.
const std = @import("std");
const c = @import("sqlite");

pub const Error = error{Sqlite};

/// sqlite3_bind_text with SQLITE_TRANSIENT (SQLite copies the text), in
/// sqlite_shim.c.
extern fn cl_sqlite_bind_text(stmt: *c.sqlite3_stmt, i: c_int, text: [*]const u8, len: c_int) c_int;
extern fn cl_sqlite_page_cache(page_size: c_int, lines: c_int) c_int;

/// Give SQLite one page cache for the whole process, before anything opens
/// a database. Without it each connection mallocs its own pages and frees
/// them on close; `cl web` opens one for every request and loop pass, and
/// the allocator behind malloc in release builds (std.heap.SmpAllocator)
/// keeps freed memory on per-CPU free lists and never returns it, so those
/// short-lived caches pile up (CL-165: ~200 MB after a day). SQLite reuses
/// this buffer itself; past it, pages come from malloc as before. Measured
/// with two ReleaseSafe `cl web`s side by side on copies of the board, the
/// dispatcher on, sampling VmRSS each minute for 30 minutes: +16.5 MB over
/// the last 20 without this, +3.5 MB with it.
///
/// It must run before SQLite initializes (anything opening a database);
/// after that SQLite refuses it, which Debug builds stop on.
pub fn configure() void {
    // 4096 is SQLite's default page size (the board's); 2048 pages is 8 MiB
    // of address space, touched only as it is used.
    const rc = cl_sqlite_page_cache(4096, 2048);
    if (rc != c.SQLITE_OK) {
        if (@import("builtin").mode == .Debug) std.debug.panic("SQLite page cache: {s} (configure must run before any database is opened)", .{c.sqlite3_errstr(rc)});
        std.debug.print("cl: SQLite page cache not set up: {s}\n", .{c.sqlite3_errstr(rc)});
    }
}

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Db {
        var h: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &h, flags, null) != c.SQLITE_OK) {
            if (h) |x| _ = c.sqlite3_close(x);
            return error.Sqlite;
        }
        const db: Db = .{ .handle = h.? };
        // Several processes share the file (the CLI, `cl web`, hooks): wait
        // for each other rather than fail.
        _ = c.sqlite3_busy_timeout(db.handle, 5000);
        return db;
    }

    /// SQLite won't close a connection with a statement still open
    /// (SQLITE_BUSY), and the connection then lives as long as the process:
    /// a leak, for `cl web`'s loops that open one each pass. Debug builds
    /// (the tests) stop on it; release builds say so on stderr (`cl web`'s
    /// log).
    pub fn close(self: Db) void {
        const rc = c.sqlite3_close(self.handle);
        if (rc == c.SQLITE_OK) return;
        if (@import("builtin").mode == .Debug) std.debug.panic("sqlite3_close: {s} (a statement wasn't finalized)", .{c.sqlite3_errstr(rc)});
        std.debug.print("cl: sqlite3_close: {s} (a statement wasn't finalized; the connection stays open)\n", .{c.sqlite3_errstr(rc)});
    }

    /// The last error, for messages.
    pub fn message(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    /// Run SQL with no arguments; may hold several statements.
    pub fn execMulti(self: Db, sql: [:0]const u8) Error!void {
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, null) != c.SQLITE_OK) return error.Sqlite;
    }

    pub fn prepare(self: Db, sql: []const u8) Error!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &s, null) != c.SQLITE_OK) return error.Sqlite;
        return .{ .handle = s.? };
    }

    /// Prepare `sql`, bind `args` (a tuple) and return the statement, ready
    /// to step. The caller finalizes it.
    pub fn query(self: Db, sql: []const u8, args: anytype) Error!Stmt {
        var st = try self.prepare(sql);
        errdefer st.finalize();
        try st.bindAll(args);
        return st;
    }

    /// Run one statement that returns no rows.
    pub fn exec(self: Db, sql: []const u8, args: anytype) Error!void {
        var st = try self.query(sql, args);
        defer st.finalize();
        while (try st.step()) {}
    }

    /// The first column of the first row as an integer, or null with no row.
    pub fn int(self: Db, sql: []const u8, args: anytype) Error!?i64 {
        var st = try self.query(sql, args);
        defer st.finalize();
        if (!try st.step()) return null;
        return st.int(0);
    }

    pub fn lastId(self: Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: Db) i64 {
        return c.sqlite3_changes64(self.handle);
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// Bind each element of `args` to ?1, ?2, ... Strings bind as text,
    /// integers and bools as integers, null as NULL.
    pub fn bindAll(self: Stmt, args: anytype) Error!void {
        inline for (args, 1..) |a, i| try self.bind(i, a);
    }

    pub fn bind(self: Stmt, i: c_int, v: anytype) Error!void {
        const T = @TypeOf(v);
        const rc = switch (@typeInfo(T)) {
            .null => c.sqlite3_bind_null(self.handle, i),
            .bool => c.sqlite3_bind_int64(self.handle, i, @intFromBool(v)),
            .int, .comptime_int => c.sqlite3_bind_int64(self.handle, i, @intCast(v)),
            .optional => if (v) |x| return self.bind(i, x) else c.sqlite3_bind_null(self.handle, i),
            .pointer => blk: {
                const s: []const u8 = v;
                break :blk cl_sqlite_bind_text(self.handle, i, s.ptr, @intCast(s.len));
            },
            else => @compileError("cannot bind " ++ @typeName(T)),
        };
        if (rc != c.SQLITE_OK) return error.Sqlite;
    }

    /// Advance; true while there is a row.
    pub fn step(self: Stmt) Error!bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.Sqlite,
        };
    }

    /// Column text, valid until the next step; "" for NULL.
    pub fn text(self: Stmt, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.handle, col) orelse return "";
        const n: usize = @intCast(c.sqlite3_column_bytes(self.handle, col));
        return @as([*]const u8, @ptrCast(p))[0..n];
    }

    /// Column text copied into `alloc`.
    pub fn dupe(self: Stmt, alloc: std.mem.Allocator, col: c_int) ![]const u8 {
        return alloc.dupe(u8, self.text(col));
    }

    pub fn int(self: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn isNull(self: Stmt, col: c_int) bool {
        return c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL;
    }
};

test "open, insert, read back" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.execMulti("CREATE TABLE t(a TEXT, b INTEGER);");
    try db.exec("INSERT INTO t VALUES (?1, ?2)", .{ "hello", 42 });
    try db.exec("INSERT INTO t VALUES (?1, ?2)", .{ @as(?[]const u8, null), 7 });
    var st = try db.query("SELECT a, b FROM t ORDER BY b DESC", .{});
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("hello", st.text(0));
    try std.testing.expectEqual(@as(i64, 42), st.int(1));
    try std.testing.expect(try st.step());
    try std.testing.expect(st.isNull(0));
    try std.testing.expect(!try st.step());
    try std.testing.expectEqual(@as(?i64, 2), try db.int("SELECT count(*) FROM t", .{}));
}
