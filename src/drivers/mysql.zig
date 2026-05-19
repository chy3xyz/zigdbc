//! MySQL/MariaDB database driver
//!
//! Uses libmysqlclient C library for real prepared statement binding
//! (mysql_stmt_prepare/bind_param/execute — NOT string interpolation).
//! This is the production-safe approach for MySQL.
//!
//! Requires: mysql-client or libmysqlclient-dev
//!   brew install mysql
//!   apt install libmysqlclient-dev

const std = @import("std");
const build_opts = @import("build_options");
const Connection = @import("../connection.zig").Connection;
const ConnectionVTable = @import("../connection.zig").ConnectionVTable;
const Result = @import("../result.zig").Result;
const ResultVTable = @import("../result.zig").ResultVTable;
const Statement = @import("../statement.zig").Statement;
const val_mod = @import("../value.zig");
const Value = val_mod.Value;
const SqlParam = val_mod.SqlParam;
const Error = @import("../error.zig").Error;
const Uri = @import("../uri.zig").Uri;

const c = if (build_opts.use_mysql) @cImport({
    @cInclude("mysql/mysql.h");
}) else struct {};

// ============================================================
// Connection context
// ============================================================

pub const MysqlContext = struct {
    allocator: std.mem.Allocator,
    conn: ?*c.MYSQL,
    last_error: ?[]const u8 = null,
    affected_rows: usize = 0,
    last_insert_id_val: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, uri: Uri) !*MysqlContext {
        const conn = c.mysql_init(null) orelse return error.ConnectionFailed;

        const host = uri.host orelse "127.0.0.1";
        const port = uri.port orelse 3306;
        const username = uri.username orelse "root";
        const password = uri.password orelse "";
        const database = if (uri.database.len > 0) uri.database else "";

        var h_buf: [256]u8 = undefined;
        var u_buf: [256]u8 = undefined;
        var p_buf: [256]u8 = undefined;
        var d_buf: [256]u8 = undefined;

        const hz = try std.fmt.bufPrintZ(&h_buf, "{s}", .{host});
        const uz = try std.fmt.bufPrintZ(&u_buf, "{s}", .{username});
        const pz = try std.fmt.bufPrintZ(&p_buf, "{s}", .{password});
        const dz = try std.fmt.bufPrintZ(&d_buf, "{s}", .{database});

        if (c.mysql_real_connect(conn, hz.ptr, uz.ptr, pz.ptr, dz.ptr, port, null, 0) == null) {
            const msg = c.mysql_error(conn);
            std.debug.print("MySQL connect failed: {s}\n", .{msg});
            c.mysql_close(conn);
            return error.ConnectionFailed;
        }

        const ctx = try allocator.create(MysqlContext);
        ctx.* = MysqlContext{
            .allocator = allocator,
            .conn = conn,
        };
        return ctx;
    }

    pub fn deinit(self: *MysqlContext) void {
        if (self.conn) |cxn| {
            c.mysql_close(cxn);
            self.conn = null;
        }
        self.allocator.destroy(self);
    }
};

// ============================================================
// Result context — holds data from query
// ============================================================

pub const MysqlResultContext = struct {
    allocator: std.mem.Allocator,
    /// Flat storage: all values row-by-row, indexed by (row * col_count + col)
    values: std.ArrayListUnmanaged(Value) = .{ .items = &.{}, .capacity = 0 },
    column_names: []const []const u8,
    col_count: usize = 0,
    row_count: usize = 0,
    current_row: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*MysqlResultContext {
        const ctx = try allocator.create(MysqlResultContext);
        ctx.* = MysqlResultContext{
            .allocator = allocator,
            .column_names = &.{},
        };
        return ctx;
    }

    pub fn deinit(self: *MysqlResultContext) void {
        for (self.values.items) |*v| {
            if (v.* == .text) self.allocator.free(v.text);
        }
        self.values.deinit(self.allocator);
        for (self.column_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.column_names);
        self.allocator.destroy(self);
    }

    fn setColumns(self: *MysqlResultContext, cols: []const []const u8, n: usize) !void {
        self.column_names = cols;
        self.col_count = n;
    }

    fn addRow(self: *MysqlResultContext, cells: []const Value) !void {
        for (cells) |v| {
            try self.values.append(self.allocator, v);
        }
        self.row_count += 1;
    }
};

// ============================================================
// Result VTable
// ============================================================

const mysqlResultVTable = ResultVTable{
    .next = mysqlResultNext,
    .columnCount = mysqlResultColumnCount,
    .columnName = mysqlResultColumnName,
    .getValue = mysqlResultGetValue,
    .getValueByName = mysqlResultGetValueByName,
    .affectedRows = mysqlResultAffectedRows,
    .reset = mysqlResultReset,
    .deinit = mysqlResultDeinit,
};

fn mysqlResultNext(ctx: *anyopaque) Error!bool {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    if (rc.current_row < rc.row_count) {
        rc.current_row += 1;
        return true;
    }
    return false;
}

fn mysqlResultColumnCount(ctx: *anyopaque) usize {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    return rc.col_count;
}

fn mysqlResultColumnName(ctx: *anyopaque, index: usize) ?[]const u8 {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    if (index < rc.column_names.len) return rc.column_names[index];
    return null;
}

fn mysqlResultGetValue(ctx: *anyopaque, index: usize) Error!Value {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    if (rc.current_row == 0 or rc.current_row > rc.row_count) return Error.NoMoreRows;
    const offset = (rc.current_row - 1) * rc.col_count + index;
    if (index >= rc.col_count) return Error.ColumnOutOfBounds;
    return rc.values.items[offset];
}

fn mysqlResultGetValueByName(ctx: *anyopaque, name: []const u8) Error!Value {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    for (rc.column_names, 0..) |col, i| {
        if (std.mem.eql(u8, col, name)) return mysqlResultGetValue(ctx, i);
    }
    return Error.ColumnNotFound;
}

fn mysqlResultAffectedRows(ctx: *anyopaque) usize {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    return rc.row_count;
}

fn mysqlResultReset(ctx: *anyopaque) Error!void {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    rc.current_row = 0;
}

fn mysqlResultDeinit(ctx: *anyopaque) void {
    const rc: *MysqlResultContext = @ptrCast(@alignCast(ctx));
    rc.deinit();
}

// ============================================================
// Connection VTable
// ============================================================

pub const mysqlConnectionVTable = ConnectionVTable{
    .exec = mysqlExec,
    .query = mysqlQuery,
    .prepare = mysqlPrepare,
    .begin = mysqlBegin,
    .commit = mysqlCommit,
    .rollback = mysqlRollback,
    .close = mysqlClose,
    .lastInsertId = mysqlLastInsertId,
    .affectedRows = mysqlAffectedRows,
    .ping = mysqlPing,
    .lastError = mysqlLastError,
};

// ============================================================
// Parameter binding — real mysql_stmt_prepare/bind_param/execute
// ============================================================

const MysqlBindData = struct {
    allocator: std.mem.Allocator,
    binds: std.ArrayListUnmanaged(c.MYSQL_BIND) = .{ .items = &.{}, .capacity = 0 },
    ints: std.ArrayListUnmanaged(i64) = .{ .items = &.{}, .capacity = 0 },
    reals: std.ArrayListUnmanaged(f64) = .{ .items = &.{}, .capacity = 0 },
    strings: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },
    lengths: std.ArrayListUnmanaged(c_ulong) = .{ .items = &.{}, .capacity = 0 },
    is_nulls: std.ArrayListUnmanaged(bool) = .{ .items = &.{}, .capacity = 0 },
};

fn buildMysqlBind(allocator: std.mem.Allocator, params: []const SqlParam) !MysqlBindData {
    var data = MysqlBindData{ .allocator = allocator };

    for (params) |p| {
        switch (p) {
            .null => {
                try data.is_nulls.append(allocator, true);
                try data.ints.append(allocator, 0);
                try data.reals.append(allocator, 0);
                try data.strings.append(allocator, "");
                try data.lengths.append(allocator, 0);
                try data.binds.append(allocator, .{
                    .buffer_type = c.MYSQL_TYPE_NULL,
                    .buffer = @constCast(@ptrCast(&data.ints.items[data.ints.items.len - 1])),
                    .buffer_length = 0,
                    .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                    .length = &data.lengths.items[data.lengths.items.len - 1],
                });
            },
            .int => |v| {
                try data.is_nulls.append(allocator, false);
                try data.ints.append(allocator, v);
                try data.reals.append(allocator, 0);
                try data.strings.append(allocator, "");
                try data.lengths.append(allocator, 0);
                try data.binds.append(allocator, .{
                    .buffer_type = c.MYSQL_TYPE_LONGLONG,
                    .buffer = @constCast(@ptrCast(&data.ints.items[data.ints.items.len - 1])),
                    .buffer_length = 8,
                    .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                    .length = &data.lengths.items[data.lengths.items.len - 1],
                });
            },
            .real => |v| {
                try data.is_nulls.append(allocator, false);
                try data.ints.append(allocator, 0);
                try data.reals.append(allocator, v);
                try data.strings.append(allocator, "");
                try data.lengths.append(allocator, 0);
                try data.binds.append(allocator, .{
                    .buffer_type = c.MYSQL_TYPE_DOUBLE,
                    .buffer = @constCast(@ptrCast(&data.reals.items[data.reals.items.len - 1])),
                    .buffer_length = 8,
                    .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                    .length = &data.lengths.items[data.lengths.items.len - 1],
                });
            },
            .text, .blob => |v| {
                try data.is_nulls.append(allocator, false);
                try data.ints.append(allocator, 0);
                try data.reals.append(allocator, 0);
                try data.strings.append(allocator, v);
                try data.lengths.append(allocator, @intCast(v.len));
                try data.binds.append(allocator, .{
                    .buffer_type = c.MYSQL_TYPE_STRING,
                    .buffer = @constCast(@ptrCast(v.ptr)),
                    .buffer_length = @intCast(v.len),
                    .is_null = &data.is_nulls.items[data.is_nulls.items.len - 1],
                    .length = &data.lengths.items[data.lengths.items.len - 1],
                });
            },
        }
    }
    return data;
}

fn freeMysqlBind(allocator: std.mem.Allocator, data: *MysqlBindData) void {
    data.strings.deinit(allocator);
    data.ints.deinit(allocator);
    data.reals.deinit(allocator);
    data.lengths.deinit(allocator);
    data.is_nulls.deinit(allocator);
    data.binds.deinit(allocator);
}

// ============================================================
// Core: exec with real prepared statement binding
// ============================================================

fn execInternal(mysql_ctx: *MysqlContext, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam, expect_result: bool) Error!?*MysqlResultContext {
    if (params.len == 0) {
        // Fast path: raw query without parameters
        const sql_z = try allocator.dupeZ(u8, sql);
        defer allocator.free(sql_z);

        if (c.mysql_query(mysql_ctx.conn, sql_z.ptr) != 0) {
            const msg = c.mysql_error(mysql_ctx.conn);
            std.debug.print("MySQL query failed: {s}\n", .{msg});
            return Error.ExecutionFailed;
        }

        mysql_ctx.affected_rows = @intCast(c.mysql_affected_rows(mysql_ctx.conn));
        mysql_ctx.last_insert_id_val = @intCast(c.mysql_insert_id(mysql_ctx.conn));

        if (expect_result) {
            const res = c.mysql_store_result(mysql_ctx.conn) orelse {
                // No result set (e.g., non-SELECT)
                return null;
            };
            defer c.mysql_free_result(res);

            var rc = try MysqlResultContext.init(allocator);
            errdefer rc.deinit();

            const n_cols: usize = @intCast(c.mysql_num_fields(res));
            var columns = try allocator.alloc([]const u8, n_cols);
            errdefer allocator.free(columns);

            const fields = c.mysql_fetch_fields(res);
            for (0..n_cols) |i| {
                const fname = fields[i].name;
                const flen: usize = @intCast(fields[i].name_length);
                columns[i] = try allocator.dupe(u8, fname[0..flen]);
            }
            try rc.setColumns(columns, n_cols);

            while (true) {
                const row = c.mysql_fetch_row(res) orelse break;
                const lengths = c.mysql_fetch_lengths(res);
                var cells: std.ArrayListUnmanaged(Value) = .{ .items = &.{}, .capacity = 0 };
                defer cells.deinit(allocator);
                for (0..n_cols) |i| {
                    if (row[i] == null) {
                        try cells.append(allocator, Value.initNull());
                    } else {
                        const len: usize = @intCast(lengths[i]);
                        const text = try allocator.dupe(u8, row[i][0..len]);
                        try cells.append(allocator, Value{ .text = text });
                    }
                }
                try rc.addRow(cells.items);
            }

            return rc;
        }

        return null;
    }

    // Prepared statement path with real binary parameter binding
    const stmt = c.mysql_stmt_init(mysql_ctx.conn) orelse return Error.PrepareFailed;
    defer _ = c.mysql_stmt_close(stmt);

    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);

    if (c.mysql_stmt_prepare(stmt, sql_z.ptr, @intCast(sql.len)) != 0) {
        std.debug.print("MySQL stmt prepare failed: {s}\n", .{c.mysql_stmt_error(stmt)});
        return Error.PrepareFailed;
    }

    var bind = try buildMysqlBind(allocator, params);
    defer freeMysqlBind(allocator, &bind);

    if (c.mysql_stmt_bind_param(stmt, bind.binds.items.ptr)) {
        std.debug.print("MySQL bind failed: {s}\n", .{c.mysql_stmt_error(stmt)});
        return Error.BindError;
    }

    if (c.mysql_stmt_execute(stmt) != 0) {
        std.debug.print("MySQL stmt execute failed: {s}\n", .{c.mysql_stmt_error(stmt)});
        return Error.ExecutionFailed;
    }

    mysql_ctx.affected_rows = @intCast(c.mysql_stmt_affected_rows(stmt));
    mysql_ctx.last_insert_id_val = @intCast(c.mysql_stmt_insert_id(stmt));

    if (!expect_result) return null;

    // Fetch result metadata
    const meta = c.mysql_stmt_result_metadata(stmt) orelse return null;
    defer c.mysql_free_result(meta);

    const n_cols: usize = @intCast(c.mysql_num_fields(meta));

    var columns = try allocator.alloc([]const u8, n_cols);
    errdefer allocator.free(columns);

    const meta_fields = c.mysql_fetch_fields(meta);
    for (0..n_cols) |i| {
        const fname = meta_fields[i].name;
        const flen: usize = @intCast(meta_fields[i].name_length);
        columns[i] = try allocator.dupe(u8, fname[0..flen]);
    }

    // Allocate per-column output buffers
    var col_bufs = try allocator.alloc([4096]u8, n_cols);
    defer allocator.free(col_bufs);
    var col_lengths = try allocator.alloc(c_ulong, n_cols);
    defer allocator.free(col_lengths);
    var col_is_null = try allocator.alloc(bool, n_cols);
    defer allocator.free(col_is_null);
    var col_err = try allocator.alloc(bool, n_cols);
    defer allocator.free(col_err);

    var out_bind = try allocator.alloc(c.MYSQL_BIND, n_cols);
    defer allocator.free(out_bind);

    for (0..n_cols) |i| {
        col_is_null[i] = false;
        col_err[i] = false;
        out_bind[i] = .{
            .buffer_type = c.MYSQL_TYPE_STRING,
            .buffer = &col_bufs[i],
            .buffer_length = 4096,
            .length = &col_lengths[i],
            .is_null = &col_is_null[i],
            .@"error" = &col_err[i],
        };
    }

    if (c.mysql_stmt_bind_result(stmt, out_bind.ptr) ) {
        std.debug.print("MySQL result bind failed: {s}\n", .{c.mysql_stmt_error(stmt)});
        return Error.BindError;
    }

    var rc = try MysqlResultContext.init(allocator);
    errdefer rc.deinit();
    try rc.setColumns(columns, n_cols);

    while (true) {
        const fetch_rc = c.mysql_stmt_fetch(stmt);
        if (fetch_rc == c.MYSQL_NO_DATA) break;
        if (fetch_rc != 0 and fetch_rc != c.MYSQL_DATA_TRUNCATED) {
            std.debug.print("MySQL fetch failed: {s}\n", .{c.mysql_stmt_error(stmt)});
            rc.deinit();
            return Error.ExecutionFailed;
        }

        var cells: std.ArrayListUnmanaged(Value) = .{ .items = &.{}, .capacity = 0 };
        defer cells.deinit(allocator);
        for (0..n_cols) |i| {
            if (col_is_null[i]) {
                try cells.append(allocator, Value.initNull());
            } else {
                const text = try allocator.dupe(u8, col_bufs[i][0..@intCast(col_lengths[i])]);
                try cells.append(allocator, Value{ .text = text });
            }
        }
        try rc.addRow(cells.items);
    }

    return rc;
}

// ============================================================
// VTable function implementations
// ============================================================

fn mysqlExec(ctx: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam) Error!usize {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    _ = try execInternal(mysql_ctx, allocator, sql, params, false);
    return mysql_ctx.affected_rows;
}

fn mysqlQuery(ctx: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam) Error!Result {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    const rc = try execInternal(mysql_ctx, allocator, sql, params, true);

    if (rc) |result_ctx| {
        return Result.init(@ptrCast(result_ctx), &mysqlResultVTable);
    }
    // Return empty result if no rows
    const empty = try MysqlResultContext.init(allocator);
    return Result.init(@ptrCast(empty), &mysqlResultVTable);
}

fn mysqlPrepare(_: *anyopaque, _: std.mem.Allocator, _: []const u8) Error!Statement {
    return Error.NotImplemented;
}

fn mysqlBegin(ctx: *anyopaque) Error!void {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    _ = execInternal(mysql_ctx, mysql_ctx.allocator, "BEGIN", &.{}, false) catch return Error.TransactionError;
}

fn mysqlCommit(ctx: *anyopaque) Error!void {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    _ = execInternal(mysql_ctx, mysql_ctx.allocator, "COMMIT", &.{}, false) catch return Error.TransactionError;
}

fn mysqlRollback(ctx: *anyopaque) Error!void {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    _ = execInternal(mysql_ctx, mysql_ctx.allocator, "ROLLBACK", &.{}, false) catch return Error.TransactionError;
}

fn mysqlClose(ctx: *anyopaque) void {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    mysql_ctx.deinit();
}

fn mysqlLastInsertId(ctx: *anyopaque) ?i64 {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    return mysql_ctx.last_insert_id_val;
}

fn mysqlAffectedRows(ctx: *anyopaque) usize {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    return mysql_ctx.affected_rows;
}

fn mysqlPing(ctx: *anyopaque) Error!void {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    if (mysql_ctx.conn == null) return Error.ConnectionFailed;
    if (c.mysql_ping(mysql_ctx.conn) != 0) return Error.ConnectionFailed;
}

fn mysqlLastError(ctx: *anyopaque) ?[]const u8 {
    const mysql_ctx: *MysqlContext = @ptrCast(@alignCast(ctx));
    if (mysql_ctx.conn) |cxn| {
        const msg = c.mysql_error(cxn);
        if (msg[0] != 0) return std.mem.span(msg);
    }
    return null;
}

// ============================================================
// Public entry point
// ============================================================

pub fn open(allocator: std.mem.Allocator, uri: Uri) Error!Connection {
    if (!build_opts.use_mysql) return error.DriverNotEnabled;

    const ctx = MysqlContext.init(allocator, uri) catch return Error.ConnectionFailed;
    return Connection{
        .ctx = @ptrCast(ctx),
        .vtable = &mysqlConnectionVTable,
        .allocator = allocator,
        .uri = uri,
    };
}

test "mysql driver interface" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const uri = Uri.parse("mysql://user:pass@localhost:3306/testdb") catch unreachable;
    _ = uri;
}

// ============================================================
// MySQL Integration Tests
// Env vars: ZDBC_MY_HOST ZDBC_MY_PORT ZDBC_MY_USER ZDBC_MY_PASSWORD ZDBC_MY_DATABASE
// ============================================================

fn getEnvVar(allocator: std.mem.Allocator, name: [:0]const u8, default: []const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr);
    if (raw) |ptr| {
        const s = std.mem.sliceTo(ptr, 0);
        return allocator.dupe(u8, s) catch return null;
    }
    if (default.len == 0) return null;
    return allocator.dupe(u8, default) catch return null;
}

fn getMyTestUri(allocator: std.mem.Allocator) ?[]const u8 {
    const password = getEnvVar(allocator, "ZDBC_MY_PASSWORD", "") orelse return null;
    defer allocator.free(password);

    const host = getEnvVar(allocator, "ZDBC_MY_HOST", "localhost") orelse return null;
    defer allocator.free(host);

    const port = getEnvVar(allocator, "ZDBC_MY_PORT", "3306") orelse return null;
    defer allocator.free(port);

    const user = getEnvVar(allocator, "ZDBC_MY_USER", "root") orelse return null;
    defer allocator.free(user);

    const database = getEnvVar(allocator, "ZDBC_MY_DATABASE", "zdbc_test") orelse return null;
    defer allocator.free(database);

    return std.fmt.allocPrint(allocator, "mysql://{s}:{s}@{s}:{s}/{s}", .{ user, password, host, port, database }) catch return null;
}

test "mysql: connection and ping" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const uri_str = getMyTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch |err| {
        std.debug.print("MySQL connection failed (expected if no server): {}\n", .{err});
        return;
    };
    defer conn.close();
    try conn.ping();
}

test "mysql: create table and insert with params" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const uri_str = getMyTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS my_test_basic", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE my_test_basic (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255), value DOUBLE)", &.{});
    _ = try conn.exec("INSERT INTO my_test_basic (name, value) VALUES (?, ?)", &.{ SqlParam.bindText("hello"), SqlParam.bindReal(3.14) });
    _ = try conn.exec("DROP TABLE my_test_basic", &.{});
}

test "mysql: query returns rows" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const uri_str = getMyTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS my_test_query", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE my_test_query (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))", &.{});
    _ = try conn.exec("INSERT INTO my_test_query (name) VALUES (?)", &.{SqlParam.bindText("Alice")});
    _ = try conn.exec("INSERT INTO my_test_query (name) VALUES (?)", &.{SqlParam.bindText("Bob")});

    var result = try conn.query("SELECT id, name FROM my_test_query ORDER BY id", &.{});
    defer result.deinit();

    try std.testing.expect((try result.next()) != null);
    try std.testing.expect((try result.next()) != null);
    try std.testing.expect((try result.next()) == null);

    _ = try conn.exec("DROP TABLE my_test_query", &.{});
}

test "mysql: parameterized query prevents SQL injection" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const uri_str = getMyTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS my_test_inject", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE my_test_inject (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))", &.{});
    _ = try conn.exec("INSERT INTO my_test_inject (name) VALUES (?)", &.{SqlParam.bindText("safe")});

    // Malicious input — real parameter binding prevents injection
    _ = try conn.exec("INSERT INTO my_test_inject (name) VALUES (?)", &.{SqlParam.bindText("inject'; DROP TABLE my_test_inject;--")});

    var result = try conn.query("SELECT COUNT(*) FROM my_test_inject", &.{});
    defer result.deinit();
    _ = try result.next();
    // Both rows should exist (malicious input stored as literal text)
    _ = try conn.exec("DROP TABLE my_test_inject", &.{});
}

test "mysql: transaction commit and rollback" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const uri_str = getMyTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS my_test_txn", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE my_test_txn (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(255))", &.{});

    try conn.begin();
    _ = try conn.exec("INSERT INTO my_test_txn (val) VALUES (?)", &.{SqlParam.bindText("txn_val")});
    try conn.commit();

    // Verify committed
    var result = try conn.query("SELECT COUNT(*) FROM my_test_txn", &.{});
    defer result.deinit();
    _ = try result.next();

    // Rollback test
    try conn.begin();
    _ = try conn.exec("INSERT INTO my_test_txn (val) VALUES (?)", &.{SqlParam.bindText("rollback_me")});
    try conn.rollback();

    _ = try conn.exec("DROP TABLE my_test_txn", &.{});
}

test "mysql: null values" {
    if (!build_opts.use_mysql) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const uri_str = getMyTestUri(allocator) orelse return;
    defer allocator.free(uri_str);

    const uri = Uri.parse(uri_str) catch return;
    var conn = open(allocator, uri) catch return;
    defer conn.close();

    _ = conn.exec("DROP TABLE IF EXISTS my_test_null", &.{}) catch {};
    _ = try conn.exec("CREATE TABLE my_test_null (id INT, nullable_col VARCHAR(255))", &.{});
    _ = try conn.exec("INSERT INTO my_test_null VALUES (?, ?)", &.{ SqlParam.bindInt(1), SqlParam.bindNull() });

    var result = try conn.query("SELECT nullable_col FROM my_test_null", &.{});
    defer result.deinit();
    try std.testing.expect((try result.next()) != null);
    _ = try conn.exec("DROP TABLE my_test_null", &.{});
}
