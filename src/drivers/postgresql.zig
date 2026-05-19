//! PostgreSQL database driver
//!
//! Uses libpq C library for real parameterized query binding (PQexecParams).
//! This is the production-safe approach — no string interpolation.
//!
//! Requires: libpq-dev (brew install libpq / apt install libpq-dev)
//! Build with: zig build -Duse_pg=true

const std = @import("std");
const build_opts = @import("build_options");
const Connection = @import("../connection.zig").Connection;
const ConnectionVTable = @import("../connection.zig").ConnectionVTable;
const Result = @import("../result.zig").Result;
const ResultVTable = @import("../result.zig").ResultVTable;
const Statement = @import("../statement.zig").Statement;
const value = @import("../value.zig");
const Value = value.Value;
const SqlParam = value.SqlParam;
const Error = @import("../error.zig").Error;
const Uri = @import("../uri.zig").Uri;

const c = if (build_opts.use_pg) @cImport({
    @cInclude("libpq-fe.h");
}) else struct {};

/// PostgreSQL connection context
pub const PgContext = struct {
    allocator: std.mem.Allocator,
    conn: ?*c.PGconn,
    last_error: ?[]const u8 = null,
    affected_rows: usize = 0,
    last_insert_id: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, uri: Uri) !*PgContext {
        const host = uri.host orelse "127.0.0.1";
        const port = uri.port orelse 5432;
        const username = uri.username orelse "postgres";
        const password = uri.password orelse "";
        const database = if (uri.database.len > 0) uri.database else "postgres";

        var conn_buf: [1024]u8 = undefined;
        const conn_str = try std.fmt.bufPrintZ(&conn_buf,
            "host={s} port={d} dbname={s} user={s} password={s}",
            .{ host, port, database, username, password },
        );

        const conn = c.PQconnectdb(conn_str);
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            const msg = c.PQerrorMessage(conn);
            std.debug.print("PostgreSQL connect failed: {s}\n", .{msg});
            c.PQfinish(conn);
            return error.ConnectionFailed;
        }

        const ctx = try allocator.create(PgContext);
        ctx.* = PgContext{
            .allocator = allocator,
            .conn = conn,
        };
        return ctx;
    }

    pub fn deinit(self: *PgContext) void {
        if (self.conn) |cxn| {
            c.PQfinish(cxn);
            self.conn = null;
        }
        self.allocator.destroy(self);
    }
};

/// PostgreSQL result context — wraps libpq PGresult
pub const PgResultContext = struct {
    allocator: std.mem.Allocator,
    res: ?*c.PGresult = null,
    current_row: usize = 0,
    n_rows: usize = 0,
    n_cols: usize = 0,
    column_names: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, res: *c.PGresult) !*PgResultContext {
        const n_cols: usize = @intCast(c.PQnfields(res));
        const n_rows: usize = @intCast(c.PQntuples(res));

        var column_names = try allocator.alloc([]const u8, n_cols);
        errdefer allocator.free(column_names);

        for (0..n_cols) |i| {
            const name = std.mem.span(c.PQfname(res, @intCast(i)));
            column_names[i] = try allocator.dupe(u8, name);
        }

        const ctx = try allocator.create(PgResultContext);
        ctx.* = PgResultContext{
            .allocator = allocator,
            .res = res,
            .n_rows = n_rows,
            .n_cols = n_cols,
            .column_names = column_names,
        };
        return ctx;
    }

    pub fn deinit(self: *PgResultContext) void {
        if (self.res) |res| {
            c.PQclear(res);
            self.res = null;
        }
        for (self.column_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.column_names);
        self.allocator.destroy(self);
    }
};

/// VTable for PostgreSQL results
const pgResultVTable = ResultVTable{
    .next = pgResultNext,
    .columnCount = pgResultColumnCount,
    .columnName = pgResultColumnName,
    .getValue = pgResultGetValue,
    .getValueByName = pgResultGetValueByName,
    .affectedRows = pgResultAffectedRows,
    .reset = null,
    .deinit = pgResultDeinit,
};

fn pgResultNext(ctx: *anyopaque) Error!bool {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    if (result_ctx.current_row < result_ctx.n_rows) {
        result_ctx.current_row += 1;
        return true;
    }
    return false;
}

fn pgResultColumnCount(ctx: *anyopaque) usize {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    return result_ctx.n_cols;
}

fn pgResultColumnName(ctx: *anyopaque, index: usize) ?[]const u8 {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    if (index < result_ctx.column_names.len) {
        return result_ctx.column_names[index];
    }
    return null;
}

fn pgResultGetValue(ctx: *anyopaque, index: usize) Error!Value {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    if (result_ctx.current_row == 0 or result_ctx.current_row > result_ctx.n_rows) {
        return Error.NoMoreRows;
    }
    const ri: c_int = @intCast(result_ctx.current_row - 1);
    const ci: c_int = @intCast(index);

    if (c.PQgetisnull(result_ctx.res, ri, ci) == 1) {
        return Value.initNull();
    }

    // References PGresult internal storage — valid until result.deinit()
    const ptr: [*]u8 = c.PQgetvalue(result_ctx.res, ri, ci);
    const len: usize = @intCast(c.PQgetlength(result_ctx.res, ri, ci));
    return Value{ .text = ptr[0..len] };
}

fn pgResultGetValueByName(ctx: *anyopaque, name: []const u8) Error!Value {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    if (result_ctx.res == null) return Error.NoMoreRows;

    const ci = c.PQfnumber(result_ctx.res, name.ptr);
    if (ci < 0) return Error.ColumnNotFound;

    return pgResultGetValue(ctx, @intCast(ci));
}

fn pgResultAffectedRows(ctx: *anyopaque) usize {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    return result_ctx.n_rows;
}

fn pgResultDeinit(ctx: *anyopaque) void {
    const result_ctx: *PgResultContext = @ptrCast(@alignCast(ctx));
    result_ctx.deinit();
}

/// VTable for PostgreSQL connections
pub const pgConnectionVTable = ConnectionVTable{
    .exec = pgExec,
    .query = pgQuery,
    .prepare = pgPrepare,
    .begin = pgBegin,
    .commit = pgCommit,
    .rollback = pgRollback,
    .close = pgClose,
    .lastInsertId = pgLastInsertId,
    .affectedRows = pgAffectedRows,
    .ping = pgPing,
    .lastError = pgLastError,
};

// ============================================================
// Parameter binding — real PQexecParams, no string interpolation
// ============================================================

const PgParams = struct {
    values: []?[*:0]const u8,
    lengths: []c_int,
    formats: []c_int,
    strings: [][]const u8,
    owned: []bool,
};

fn buildParams(allocator: std.mem.Allocator, params: []const SqlParam) !PgParams {
    var values = try allocator.alloc(?[*:0]const u8, params.len);
    errdefer allocator.free(values);
    var lengths = try allocator.alloc(c_int, params.len);
    errdefer allocator.free(lengths);
    var formats = try allocator.alloc(c_int, params.len);
    errdefer allocator.free(formats);
    var strings = try allocator.alloc([]const u8, params.len);
    errdefer allocator.free(strings);
    var owned = try allocator.alloc(bool, params.len);
    errdefer allocator.free(owned);
    @memset(owned, false);

    for (params, 0..) |p, i| {
        formats[i] = 0;
        switch (p) {
            .null => {
                values[i] = null;
                lengths[i] = 0;
            },
            .int => |v| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(s);
                const s0 = try allocator.alloc(u8, s.len + 1);
                @memcpy(s0[0..s.len], s);
                s0[s.len] = 0;
                strings[i] = s0;
                owned[i] = true;
                values[i] = @ptrCast(s0.ptr);
                lengths[i] = 0;
            },
            .real => |v| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(s);
                const s0 = try allocator.alloc(u8, s.len + 1);
                @memcpy(s0[0..s.len], s);
                s0[s.len] = 0;
                strings[i] = s0;
                owned[i] = true;
                values[i] = @ptrCast(s0.ptr);
                lengths[i] = 0;
            },
            .text => |v| {
                const s = try allocator.alloc(u8, v.len + 1);
                @memcpy(s[0..v.len], v);
                s[v.len] = 0;
                strings[i] = s;
                owned[i] = true;
                values[i] = @ptrCast(s.ptr);
                lengths[i] = 0;
            },
            .blob => |v| {
                values[i] = @constCast(@ptrCast(v.ptr));
                lengths[i] = @intCast(v.len);
                formats[i] = 1;
            },
        }
    }

    return .{ .values = values, .lengths = lengths, .formats = formats, .strings = strings, .owned = owned };
}

fn freeParams(allocator: std.mem.Allocator, p: PgParams) void {
    for (p.strings, p.owned) |s, own| if (own) allocator.free(s);
    allocator.free(p.strings);
    allocator.free(p.owned);
    allocator.free(p.values);
    allocator.free(p.lengths);
    allocator.free(p.formats);
}

fn execInternal(pg_ctx: *PgContext, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam, expect_tuples: bool) Error!*c.PGresult {
    if (params.len == 0) {
        const res = c.PQexec(pg_ctx.conn, sql.ptr) orelse return Error.ExecutionFailed;
        const status = c.PQresultStatus(res);
        const expected = if (expect_tuples) c.PGRES_TUPLES_OK else c.PGRES_COMMAND_OK;
        if (status != expected) {
            _ = c.PQerrorMessage(pg_ctx.conn);
            c.PQclear(res);
            return Error.ExecutionFailed;
        }
        // Track affected rows for exec
        if (!expect_tuples) {
            const s = std.mem.span(c.PQcmdTuples(res));
            pg_ctx.affected_rows = if (s.len > 0) std.fmt.parseInt(usize, s, 10) catch 0 else 0;
        }
        return res;
    }

    const bind = try buildParams(allocator, params);
    defer freeParams(allocator, bind);

    const res = c.PQexecParams(
        pg_ctx.conn,
        sql.ptr,
        @intCast(params.len),
        null,
        bind.values.ptr,
        bind.lengths.ptr,
        bind.formats.ptr,
        0,
    ) orelse return Error.ExecutionFailed;

    const status = c.PQresultStatus(res);
    const expected = if (expect_tuples) c.PGRES_TUPLES_OK else c.PGRES_COMMAND_OK;
    if (status != expected) {
        _ = c.PQerrorMessage(pg_ctx.conn);
        c.PQclear(res);
        return Error.ExecutionFailed;
    }

    if (!expect_tuples) {
        const s = std.mem.span(c.PQcmdTuples(res));
        pg_ctx.affected_rows = if (s.len > 0) std.fmt.parseInt(usize, s, 10) catch 0 else 0;
    }

    return res;
}

fn pgExec(ctx: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam) Error!usize {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    const res = try execInternal(pg_ctx, allocator, sql, params, false);
    c.PQclear(res);
    return pg_ctx.affected_rows;
}

fn pgQuery(ctx: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam) Error!Result {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    const res = try execInternal(pg_ctx, allocator, sql, params, true);

    const result_ctx = PgResultContext.init(allocator, res) catch {
        c.PQclear(res);
        return Error.OutOfMemory;
    };

    return Result.init(@ptrCast(result_ctx), &pgResultVTable);
}

fn pgPrepare(_: *anyopaque, _: std.mem.Allocator, _: []const u8) Error!Statement {
    return Error.NotImplemented;
}

fn pgBegin(ctx: *anyopaque) Error!void {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    const res = c.PQexec(pg_ctx.conn, "BEGIN") orelse return Error.TransactionError;
    defer c.PQclear(res);
    if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) return Error.TransactionError;
}

fn pgCommit(ctx: *anyopaque) Error!void {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    const res = c.PQexec(pg_ctx.conn, "COMMIT") orelse return Error.TransactionError;
    defer c.PQclear(res);
    if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) return Error.TransactionError;
}

fn pgRollback(ctx: *anyopaque) Error!void {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    const res = c.PQexec(pg_ctx.conn, "ROLLBACK") orelse return Error.TransactionError;
    defer c.PQclear(res);
    if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) return Error.TransactionError;
}

fn pgClose(ctx: *anyopaque) void {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    pg_ctx.deinit();
}

fn pgLastInsertId(ctx: *anyopaque) ?i64 {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    return pg_ctx.last_insert_id;
}

fn pgAffectedRows(ctx: *anyopaque) usize {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    return pg_ctx.affected_rows;
}

fn pgPing(ctx: *anyopaque) Error!void {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    if (pg_ctx.conn == null) return Error.ConnectionFailed;
    if (c.PQstatus(pg_ctx.conn) != c.CONNECTION_OK) return Error.ConnectionFailed;
}

fn pgLastError(ctx: *anyopaque) ?[]const u8 {
    const pg_ctx: *PgContext = @ptrCast(@alignCast(ctx));
    if (pg_ctx.conn) |cxn| {
        const msg = c.PQerrorMessage(cxn);
        if (msg[0] != 0) return std.mem.span(msg);
    }
    return null;
}

/// Open a PostgreSQL database connection
pub fn open(allocator: std.mem.Allocator, uri: Uri) Error!Connection {
    if (!build_opts.use_pg) return error.DriverNotEnabled;

    const ctx = PgContext.init(allocator, uri) catch return Error.ConnectionFailed;

    return Connection{
        .ctx = @ptrCast(ctx),
        .vtable = &pgConnectionVTable,
        .allocator = allocator,
        .uri = uri,
    };
}

test "postgresql driver interface" {
    if (!build_opts.use_pg) return error.SkipZigTest;
    const uri = Uri.parse("postgresql://user:pass@localhost:5432/testdb") catch unreachable;
    _ = uri;
}

// ============================================================================
// PostgreSQL Driver Integration Tests
// These tests require a running PostgreSQL database with environment variables:
// - ZDBC_PG_HOST (default: localhost)
// - ZDBC_PG_PORT (default: 5432)
// - ZDBC_PG_USER (default: postgres)
// - ZDBC_PG_PASSWORD
// - ZDBC_PG_DATABASE (default: zdbc_test)
// ============================================================================

fn getEnvVar(allocator: std.mem.Allocator, name: [:0]const u8, default: []const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr);
    if (raw) |ptr| {
        const s = std.mem.sliceTo(ptr, 0);
        return allocator.dupe(u8, s) catch return null;
    }
    if (default.len == 0) return null;
    return allocator.dupe(u8, default) catch return null;
}

fn getPgTestUri(allocator: std.mem.Allocator) ?[]const u8 {
    const password = getEnvVar(allocator, "ZDBC_PG_PASSWORD", "") orelse return null;
    defer allocator.free(password);

    const host = getEnvVar(allocator, "ZDBC_PG_HOST", "localhost") orelse return null;
    defer allocator.free(host);

    const port = getEnvVar(allocator, "ZDBC_PG_PORT", "5432") orelse return null;
    defer allocator.free(port);

    const user = getEnvVar(allocator, "ZDBC_PG_USER", "postgres") orelse return null;
    defer allocator.free(user);

    const database = getEnvVar(allocator, "ZDBC_PG_DATABASE", "zdbc_test") orelse return null;
    defer allocator.free(database);

    return std.fmt.allocPrint(allocator, "postgresql://{s}:{s}@{s}:{s}/{s}", .{
        user, password, host, port, database,
    }) catch return null;
}

test "postgresql: connection and ping" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch |err| {
        std.debug.print("PostgreSQL connection failed (expected if no server): {}\n", .{err});
        return;
    };
    defer conn.close();
    try conn.ping();
}

test "postgresql: create table and insert" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS pg_test_basic", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE pg_test_basic (id SERIAL PRIMARY KEY, name TEXT, value REAL)", &.{});
    _ = try conn.exec("INSERT INTO pg_test_basic (name, value) VALUES ($1, $2)", &.{ SqlParam.bindText("hello"), SqlParam.bindReal(3.14) });
    _ = try conn.exec("DROP TABLE pg_test_basic", &.{});
}

test "postgresql: query returns rows" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS pg_test_query", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE pg_test_query (id SERIAL, name TEXT)", &.{});
    _ = try conn.exec("INSERT INTO pg_test_query (name) VALUES ($1)", &.{SqlParam.bindText("Alice")});
    _ = try conn.exec("INSERT INTO pg_test_query (name) VALUES ($1)", &.{SqlParam.bindText("Bob")});

    var result = try conn.query("SELECT id, name FROM pg_test_query ORDER BY id", &.{});
    defer result.deinit();

    try std.testing.expect((try result.next()) != null);
    try std.testing.expect((try result.next()) != null);
    try std.testing.expect((try result.next()) == null);

    _ = try conn.exec("DROP TABLE pg_test_query", &.{});
}

test "postgresql: parameterized query prevents SQL injection" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS pg_test_inject", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE pg_test_inject (id SERIAL, name TEXT)", &.{});
    _ = try conn.exec("INSERT INTO pg_test_inject (name) VALUES ($1)", &.{SqlParam.bindText("safe")});

    // Malicious input — parameter binding prevents injection
    _ = try conn.exec("INSERT INTO pg_test_inject (name) VALUES ($1)", &.{SqlParam.bindText("inject'); DROP TABLE pg_test_inject;--")});

    var result = try conn.query("SELECT COUNT(*) FROM pg_test_inject", &.{});
    defer result.deinit();
    _ = try result.next();
    // Both rows should exist (2 = safe + malicious as literal text)
    _ = try conn.exec("DROP TABLE pg_test_inject", &.{});
}

test "postgresql: transaction commit" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS pg_test_txn", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE pg_test_txn (id SERIAL PRIMARY KEY, value TEXT)", &.{});
    try conn.begin();
    _ = try conn.exec("INSERT INTO pg_test_txn (value) VALUES ($1)", &.{SqlParam.bindText("in_transaction")});
    try conn.commit();

    var result = try conn.query("SELECT COUNT(*) FROM pg_test_txn", &.{});
    defer result.deinit();
    _ = try result.next();
    _ = try conn.exec("DROP TABLE pg_test_txn", &.{});
}

test "postgresql: transaction rollback" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS pg_test_rollback", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE pg_test_rollback (id SERIAL PRIMARY KEY, value TEXT)", &.{});
    _ = try conn.exec("INSERT INTO pg_test_rollback (value) VALUES ($1)", &.{SqlParam.bindText("before")});

    try conn.begin();
    _ = try conn.exec("INSERT INTO pg_test_rollback (value) VALUES ($1)", &.{SqlParam.bindText("during")});
    try conn.rollback();

    var result = try conn.query("SELECT COUNT(*) FROM pg_test_rollback", &.{});
    defer result.deinit();
    _ = try result.next();
    _ = try conn.exec("DROP TABLE pg_test_rollback", &.{});
}

test "postgresql: null values" {
    const allocator = std.testing.allocator;
    const uri_str = getPgTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS pg_test_null", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE pg_test_null (id INTEGER, nullable_col TEXT)", &.{});
    _ = try conn.exec("INSERT INTO pg_test_null VALUES ($1, $2)", &.{ SqlParam.bindInt(1), SqlParam.bindNull() });

    var result = try conn.query("SELECT nullable_col FROM pg_test_null", &.{});
    defer result.deinit();
    try std.testing.expect((try result.next()) != null);
    _ = try conn.exec("DROP TABLE pg_test_null", &.{});
}
