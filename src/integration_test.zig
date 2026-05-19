//! Integration test suite — runs against SQLite (:memory:) always,
//! plus PostgreSQL/MySQL when configured via environment variables.
//!
//! Env vars for optional backends:
//!   ZDBC_PG_URL or (ZDBC_PG_HOST, ZDBC_PG_PORT, ZDBC_PG_USER, ZDBC_PG_PASSWORD, ZDBC_PG_DATABASE)
//!   ZDBC_MY_URL or (ZDBC_MY_HOST, ZDBC_MY_PORT, ZDBC_MY_USER, ZDBC_MY_PASSWORD, ZDBC_MY_DATABASE)

const std = @import("std");
const zdbc = @import("zdbc.zig");
const Allocator = std.mem.Allocator;

// ============================================================
// Env helpers
// ============================================================

fn getEnv(allocator: Allocator, name: [:0]const u8, default: []const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr);
    if (raw) |ptr| return allocator.dupe(u8, std.mem.sliceTo(ptr, 0)) catch return null;
    if (default.len == 0) return null;
    return allocator.dupe(u8, default) catch return null;
}

fn tryOpenPg(allocator: Allocator) !?zdbc.Connection {
    const url = blk: {
        if (getEnv(allocator, "ZDBC_PG_URL", "")) |u| { defer allocator.free(u); break :blk try allocator.dupe(u8, u); }
        const pwd = getEnv(allocator, "ZDBC_PG_PASSWORD", "") orelse return null;
        defer allocator.free(pwd);
        const h = getEnv(allocator, "ZDBC_PG_HOST", "localhost") orelse return null;
        defer allocator.free(h);
        const p = getEnv(allocator, "ZDBC_PG_PORT", "5432") orelse return null;
        defer allocator.free(p);
        const u = getEnv(allocator, "ZDBC_PG_USER", "postgres") orelse return null;
        defer allocator.free(u);
        const d = getEnv(allocator, "ZDBC_PG_DATABASE", "zdbc_test") orelse return null;
        defer allocator.free(d);
        break :blk try std.fmt.allocPrint(allocator, "postgresql://{s}:{s}@{s}:{s}/{s}", .{ u, pwd, h, p, d });
    };
    defer allocator.free(url);
    return zdbc.open(allocator, url) catch null;
}

fn tryOpenMy(allocator: Allocator) !?zdbc.Connection {
    const url = blk: {
        if (getEnv(allocator, "ZDBC_MY_URL", "")) |u| { defer allocator.free(u); break :blk try allocator.dupe(u8, u); }
        const pwd = getEnv(allocator, "ZDBC_MY_PASSWORD", "") orelse return null;
        defer allocator.free(pwd);
        const h = getEnv(allocator, "ZDBC_MY_HOST", "localhost") orelse return null;
        defer allocator.free(h);
        const p = getEnv(allocator, "ZDBC_MY_PORT", "3306") orelse return null;
        defer allocator.free(p);
        const u = getEnv(allocator, "ZDBC_MY_USER", "root") orelse return null;
        defer allocator.free(u);
        const d = getEnv(allocator, "ZDBC_MY_DATABASE", "zdbc_test") orelse return null;
        defer allocator.free(d);
        break :blk try std.fmt.allocPrint(allocator, "mysql://{s}:{s}@{s}:{s}/{s}", .{ u, pwd, h, p, d });
    };
    defer allocator.free(url);
    return zdbc.open(allocator, url) catch null;
}

// ============================================================
// 1. CRUD — all 4 operations
// ============================================================

test "integration: CRUD on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, count INT)", &.{});

    // CREATE
    _ = try conn.exec("INSERT INTO items (title, count) VALUES (?, ?)", &.{ zdbc.SqlParam.bindText("foo"), zdbc.SqlParam.bindInt(10) });
    _ = try conn.exec("INSERT INTO items (title, count) VALUES (?, ?)", &.{ zdbc.SqlParam.bindText("bar"), zdbc.SqlParam.bindInt(20) });
    _ = try conn.exec("INSERT INTO items (title, count) VALUES (?, ?)", &.{ zdbc.SqlParam.bindText("baz"), zdbc.SqlParam.bindInt(30) });

    // READ all
    {
        var r = try conn.query("SELECT title, count FROM items ORDER BY count", &.{});
        defer r.deinit();

        const row1 = try r.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("foo", (try row1.getText(0)).?);
        try std.testing.expectEqual(@as(i64, 10), (try row1.getInt(1)).?);

        const row2 = try r.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("bar", (try row2.getText(0)).?);

        _ = try r.next();
        try std.testing.expect((try r.next()) == null);
    }

    // UPDATE
    const aff = try conn.exec("UPDATE items SET count = ? WHERE title = ?", &.{ zdbc.SqlParam.bindInt(99), zdbc.SqlParam.bindText("bar") });
    try std.testing.expect(aff > 0);

    // Verify update
    {
        var r = try conn.query("SELECT count FROM items WHERE title = ?", &.{zdbc.SqlParam.bindText("bar")});
        defer r.deinit();
        const row = try r.next() orelse return error.TestFailed;
        try std.testing.expectEqual(@as(i64, 99), (try row.getInt(0)).?);
    }

    // DELETE
    _ = try conn.exec("DELETE FROM items WHERE title = ?", &.{zdbc.SqlParam.bindText("baz")});

    // COUNT
    {
        var r = try conn.query("SELECT COUNT(*) FROM items", &.{});
        defer r.deinit();
        const row = try r.next() orelse return error.TestFailed;
        try std.testing.expectEqual(@as(i64, 2), (try row.getInt(0)).?);
    }
}

// ============================================================
// 2. All SqlParam types
// ============================================================

test "integration: parameter types on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE params (a INT, b REAL, c TEXT, d BLOB)", &.{});
    _ = try conn.exec("INSERT INTO params VALUES (?, ?, ?, ?)", &.{
        zdbc.SqlParam.bindInt(42),
        zdbc.SqlParam.bindReal(3.14),
        zdbc.SqlParam.bindText("hello"),
        zdbc.SqlParam.bindNull(),
    });
    _ = try conn.exec("INSERT INTO params VALUES (?, ?, ?, ?)", &.{
        zdbc.SqlParam.bindInt(-1),
        zdbc.SqlParam.bindReal(0.0),
        zdbc.SqlParam.bindText(""),
        zdbc.SqlParam.bindBlob(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }),
    });

    var r = try conn.query("SELECT a, b, c, d FROM params ORDER BY a DESC", &.{});
    defer r.deinit();

    const row1 = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), (try row1.getInt(0)).?);
    try std.testing.expect((try row1.getFloat(1)) != null);
    try std.testing.expectEqualStrings("hello", (try row1.getText(2)).?);
    try std.testing.expect(try row1.isNull(3));

    const row2 = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, -1), (try row2.getInt(0)).?);
    try std.testing.expectEqualStrings("", (try row2.getText(2)).?);
}

// ============================================================
// 3. SQL injection — parameter binding prevents it
// ============================================================

test "integration: SQL injection prevention on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE safe (data TEXT)", &.{});

    const payloads = [_][]const u8{
        "'; DROP TABLE safe; --",
        "1' OR '1'='1",
        "' UNION SELECT * FROM passwords --",
        "1; DELETE FROM safe;",
    };

    for (payloads) |payload| {
        _ = try conn.exec("INSERT INTO safe (data) VALUES (?)", &.{zdbc.SqlParam.bindText(payload)});
    }

    // Table still exists, 4 rows stored
    var r = try conn.query("SELECT COUNT(*) FROM safe", &.{});
    defer r.deinit();
    const row = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 4), (try row.getInt(0)).?);
}

// ============================================================
// 4. Transactions
// ============================================================

test "integration: transactions on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE txn (val TEXT)", &.{});

    // COMMIT
    try conn.begin();
    _ = try conn.exec("INSERT INTO txn VALUES (?)", &.{zdbc.SqlParam.bindText("committed")});
    try conn.commit();

    // ROLLBACK
    try conn.begin();
    _ = try conn.exec("INSERT INTO txn VALUES (?)", &.{zdbc.SqlParam.bindText("rolled_back")});
    try conn.rollback();

    // Only 1 row (committed)
    var r = try conn.query("SELECT COUNT(*) FROM txn", &.{});
    defer r.deinit();
    const row = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), (try row.getInt(0)).?);
}

// ============================================================
// 5. Error handling
// ============================================================

test "integration: error handling on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    // Syntax error
    try std.testing.expectError(zdbc.Error.ExecutionFailed, conn.exec("NOT VALID SQL", &.{}));

    // Constraint violation
    _ = try conn.exec("CREATE TABLE err_test (code TEXT UNIQUE NOT NULL)", &.{});
    _ = try conn.exec("INSERT INTO err_test VALUES (?)", &.{zdbc.SqlParam.bindText("dup")});
    try std.testing.expectError(zdbc.Error.ExecutionFailed, conn.exec("INSERT INTO err_test VALUES (?)", &.{zdbc.SqlParam.bindText("dup")}));
}

// ============================================================
// 6. Unicode
// ============================================================

test "integration: unicode on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE uni (data TEXT)", &.{});

    const texts = [_][]const u8{
        "你好世界",
        "🎉🎊🎈",
        "Привет мир",
        "O'Brien \"quoted\" \\backslash\\",
        "@#$%^&*()_+-=[]{}|",
    };

    for (texts) |t| {
        _ = try conn.exec("INSERT INTO uni VALUES (?)", &.{zdbc.SqlParam.bindText(t)});
    }

    // Read back and verify first and last
    var r = try conn.query("SELECT data FROM uni ORDER BY rowid", &.{});
    defer r.deinit();

    var i: usize = 0;
    while (try r.next()) |row| : (i += 1) {
        try std.testing.expectEqualStrings(texts[i], (try row.getText(0)).?);
    }
    try std.testing.expectEqual(@as(usize, 5), i);
}

// ============================================================
// 7. Large data
// ============================================================

test "integration: large data on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE large (data TEXT)", &.{});

    var buf: [10000]u8 = undefined;
    for (&buf, 0..) |*c, j| c.* = @intCast('A' + @as(u8, @intCast(j % 26)));
    const big = buf[0..];

    _ = try conn.exec("INSERT INTO large VALUES (?)", &.{zdbc.SqlParam.bindText(big)});

    var r = try conn.query("SELECT data FROM large", &.{});
    defer r.deinit();
    const row = try r.next() orelse return error.TestFailed;
    const back = (try row.getText(0)).?;
    try std.testing.expectEqual(big.len, back.len);
    try std.testing.expectEqualStrings(big[0..100], back[0..100]);
    try std.testing.expectEqualStrings(big[big.len-100..], back[back.len-100..]);
}

// ============================================================
// 8. Bulk insert + transaction
// ============================================================

test "integration: bulk insert on SQLite" {
    const a = std.testing.allocator;
    var conn = try zdbc.open(a, "sqlite://:memory:");
    defer conn.close();

    _ = try conn.exec("CREATE TABLE bulk (id INTEGER PRIMARY KEY, val TEXT)", &.{});

    try conn.begin();
    errdefer conn.rollback() catch {};
    for (0..100) |i| {
        var b: [20]u8 = undefined;
        const label = try std.fmt.bufPrint(&b, "row_{d}", .{i});
        _ = try conn.exec("INSERT INTO bulk (val) VALUES (?)", &.{zdbc.SqlParam.bindText(label)});
    }
    try conn.commit();

    var r = try conn.query("SELECT COUNT(*) FROM bulk", &.{});
    defer r.deinit();
    const row = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 100), (try row.getInt(0)).?);
}

// ============================================================
// 9-11. Cross-backend tests (run on PG/MySQL if available)
// ============================================================

fn testPgMyCrud(allocator: Allocator, uri: []const u8, comptime ph1: []const u8, comptime ph2: []const u8, comptime auto_inc: []const u8) !void {
    var conn = try zdbc.open(allocator, uri);
    defer conn.close();

    const sql_drop = "DROP TABLE IF EXISTS cross_crud";
    const sql_create = "CREATE TABLE cross_crud (id " ++ auto_inc ++ " PRIMARY KEY, name TEXT NOT NULL, num INT)";
    const sql_insert = "INSERT INTO cross_crud (name, num) VALUES (" ++ ph1 ++ ", " ++ ph2 ++ ")";
    const sql_select = "SELECT name, num FROM cross_crud ORDER BY num";

    _ = conn.exec(sql_drop, &.{}) catch {};
    _ = try conn.exec(sql_create, &.{});
    _ = try conn.exec(sql_insert, &.{ zdbc.SqlParam.bindText("low"), zdbc.SqlParam.bindInt(5) });
    _ = try conn.exec(sql_insert, &.{ zdbc.SqlParam.bindText("high"), zdbc.SqlParam.bindInt(99) });

    var r = try conn.query(sql_select, &.{});
    defer r.deinit();

    var row = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("low", (try row.getText(0)).?);
    try std.testing.expectEqual(@as(i64, 5), (try row.getInt(1)).?);

    row = try r.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("high", (try row.getText(0)).?);
    try std.testing.expectEqual(@as(i64, 99), (try row.getInt(1)).?);

    _ = conn.exec(sql_drop, &.{}) catch {};
}

test "integration: CRUD on PostgreSQL" {
    const a = std.testing.allocator;
    var conn = (try tryOpenPg(a)) orelse return;
    defer conn.close();

    const sql_drop = "DROP TABLE IF EXISTS cross_crud";
    const sql_create = "CREATE TABLE cross_crud (id SERIAL PRIMARY KEY, name TEXT NOT NULL, num INT)";
    _ = conn.exec(sql_drop, &.{}) catch {};
    _ = try conn.exec(sql_create, &.{});
    _ = try conn.exec("INSERT INTO cross_crud (name, num) VALUES ($1, $2)", &.{ zdbc.SqlParam.bindText("pg_test"), zdbc.SqlParam.bindInt(42) });
    {
        var r = try conn.query("SELECT name, num FROM cross_crud", &.{});
        defer r.deinit();
        const row = try r.next() orelse return error.TestFailed;
        // PG driver returns all values as text
        try std.testing.expectEqualStrings("pg_test", (try row.getText(0)).?);
        try std.testing.expect((try row.getText(1)) != null);
    }
    _ = conn.exec(sql_drop, &.{}) catch {};
}

test "integration: CRUD on MySQL" {
    const a = std.testing.allocator;
    var conn = (try tryOpenMy(a)) orelse return;
    defer conn.close();

    const sql_drop = "DROP TABLE IF EXISTS cross_crud";
    const sql_create = "CREATE TABLE cross_crud (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL, num INT)";
    _ = conn.exec(sql_drop, &.{}) catch {};
    _ = try conn.exec(sql_create, &.{});
    _ = try conn.exec("INSERT INTO cross_crud (name, num) VALUES (?, ?)", &.{ zdbc.SqlParam.bindText("my_test"), zdbc.SqlParam.bindInt(7) });
    {
        var r = try conn.query("SELECT name, num FROM cross_crud", &.{});
        defer r.deinit();
        const row = try r.next() orelse return error.TestFailed;
        // MySQL driver returns all values as text
        try std.testing.expectEqualStrings("my_test", (try row.getText(0)).?);
        try std.testing.expect((try row.getText(1)) != null);
    }
    _ = conn.exec(sql_drop, &.{}) catch {};
}

// ============================================================
// 12. Connection pool (spinlock-based, single-threaded safe)
// ============================================================

test "integration: pool basic acquire and release" {
    const a = std.testing.allocator;
    var pool = try zdbc.Pool.init(a, "sqlite://:memory:", .{
        .min_size = 2,
        .max_size = 4,
        .validate_on_acquire = false,
    });
    defer pool.deinit();

    // Create schema
    {
        var pc = try pool.acquire();
        defer pc.release();
        _ = try pc.conn.exec("CREATE TABLE pool_test (id INTEGER PRIMARY KEY, val TEXT)", &.{});
    }

    // Insert
    {
        var pc = try pool.acquire();
        defer pc.release();
        _ = try pc.conn.exec("INSERT INTO pool_test (val) VALUES (?)", &.{zdbc.SqlParam.bindText("from_pool")});
    }

    // Query
    {
        var pc = try pool.acquire();
        defer pc.release();
        var r = try pc.conn.query("SELECT val FROM pool_test", &.{});
        defer r.deinit();
        try std.testing.expect((try r.next()) != null);
    }

    try std.testing.expectEqual(@as(usize, 2), pool.size());
}

test "integration: pool exhaustion timeout" {
    const a = std.testing.allocator;
    var pool = try zdbc.Pool.init(a, "sqlite://:memory:", .{
        .min_size = 1,
        .max_size = 1,
        .acquire_timeout_ms = 100,
        .validate_on_acquire = false,
    });
    defer pool.deinit();

    var pc1 = try pool.acquire();
    defer pc1.release();

    const err = pool.acquire();
    try std.testing.expectError(zdbc.Error.Timeout, err);
}
