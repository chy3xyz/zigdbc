# ZDBC - Zig Database Connector

A high-performance, type-safe database abstraction layer for Zig using the VTable pattern.

## Features

- **VTable Pattern**: Zero-cost abstraction using Zig's compile-time features
- **Multiple Backends**: SQLite, PostgreSQL, MySQL, Mock
- **Real Parameter Binding**: SQLite (`bindValue`), PostgreSQL (`PQexecParams`), MySQL (`mysql_stmt_bind_param`) — no string interpolation
- **Unified Interface**: Consistent API across all database backends
- **Connection Pooling**: Built-in thread-safe connection pool
- **URI-based Connections**: Easy connection string parsing
- **Type Safety**: Compile-time type checking for database operations

## Supported Databases

| Database   | Driver                       | Parameter Binding            | Build Flag        |
|------------|------------------------------|------------------------------|-------------------|
| SQLite     | [zqlite.zig](https://github.com/karlseguin/zqlite.zig) | ✅ `bindValue` (real prepared statement) | Always enabled |
| PostgreSQL | libpq (C library, system)    | ✅ `PQexecParams` (binary protocol) | `-Duse_pg=true`   |
| MySQL      | libmysqlclient (C library, system) | ✅ `mysql_stmt_bind_param` (binary protocol) | `-Duse_mysql=true` |
| Mock       | Built-in                     | N/A (testing only)           | Always enabled |

## Requirements

- **Zig** 0.16.0 or later
- **SQLite**: `libsqlite3` (system library) — always required for build
- **PostgreSQL**: `libpq` (Homebrew: `brew install libpq`, apt: `libpq-dev`) — opt-in
- **MySQL**: `libmysqlclient` (Homebrew: `brew install mysql`, apt: `libmysqlclient-dev`) — opt-in

## Installation

Add ZDBC to your `build.zig.zon`:

```zig
.dependencies = .{
    .zdbc = .{
        .url = "https://github.com/chy3xyz/zigdbc/archive/refs/heads/main.tar.gz",
        .hash = "zdbc-0.3.0-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    },
},
```

In your `build.zig`:

```zig
const zdbc = b.dependency("zdbc", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zdbc", zdbc.module("zdbc"));
```

## Quick Start

```zig
const std = @import("std");
const zdbc = @import("zdbc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open a connection
    var conn = try zdbc.open(allocator, "sqlite:///path/to/db.sqlite");
    defer conn.close();

    // Execute DDL
    _ = try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    // Insert with parameters — real prepared statement binding
    _ = try conn.exec(
        "INSERT INTO users (name) VALUES (?)",
        &.{zdbc.SqlParam.bindText("John")},
    );

    // Query rows
    var result = try conn.query("SELECT * FROM users", &.{});
    defer result.deinit();

    while (try result.next()) |row| {
        const id = (try row.getInt(0)).?;
        const name = (try row.getText(1)).?;
        std.debug.print("User: {} - {s}\n", .{id, name});
    }
}
```

## URI Formats

```
# SQLite
sqlite:///path/to/database.db
sqlite://:memory:

# PostgreSQL (requires -Duse_pg=true)
postgresql://user:password@host:port/database
postgres://user:password@host:port/database

# MySQL (requires -Duse_mysql=true)
mysql://user:password@host:port/database
mariadb://user:password@host:port/database
```

## API Reference

### Connection

```zig
// Create a connection
var conn = try zdbc.open(allocator, "sqlite:///test.db");
defer conn.close();

// Execute queries (INSERT, UPDATE, DELETE)
// Uses real parameter binding — parameters and SQL are sent separately
const affected = try conn.exec("INSERT INTO users (name) VALUES (?)", &.{
    zdbc.SqlParam.bindText("John"),
});

// Query rows (SELECT)
var result = try conn.query("SELECT * FROM users WHERE age > ?", &.{
    zdbc.SqlParam.bindInt(18),
});
defer result.deinit();

// Transactions
try conn.begin();
errdefer conn.rollback() catch {};
// ... operations ...
try conn.commit();

// Ping health check
try conn.ping();

// Get last insert row ID
const id = conn.lastInsertId();

// Get affected rows count
const rows = conn.affectedRows();
```

### Parameter Types (SqlParam)

All drivers use `SqlParam` for safe, binary parameter binding:

```zig
const null_val = zdbc.SqlParam.bindNull();
const int_val = zdbc.SqlParam.bindInt(42);
const real_val = zdbc.SqlParam.bindReal(3.14);
const text_val = zdbc.SqlParam.bindText("hello");
const blob_val = zdbc.SqlParam.bindBlob(&[_]u8{0x01, 0x02});
```

> **SQL injection prevention**: Parameters are sent via native binary protocols — SQL template and values are never concatenated. This is safe against all forms of SQL injection.

### Placeholder Syntax

| Driver | Placeholder | Example |
|--------|------------|---------|
| SQLite | `?` | `... WHERE id = ?` |
| PostgreSQL | `$1, $2, $N` | `... WHERE id = $1 AND name = $2` |
| MySQL | `?` | `... WHERE id = ?` |

### Result Iteration

```zig
var result = try conn.query("SELECT id, name, age FROM users", &.{});
defer result.deinit();

// Get column info
const col_count = result.columnCount();
const col_name = result.columnName(0);

// Iterate rows
while (try result.next()) |row| {
    const id = try row.getInt(0);
    const name = try row.getText(1);
    const age = try row.getInt(2);
}
```

### Connection Pool

```zig
const pool = try zdbc.Pool.init(allocator, "postgresql://localhost/mydb", .{
    .min_size = 5,
    .max_size = 20,
    .acquire_timeout_ms = 30000,
});
defer pool.deinit();

// Acquire connection from pool
const pooled = try pool.acquire();
defer pooled.release();

const conn = pooled.connection();
_ = try conn.exec("SELECT 1", &.{});
```

## Architecture

ZDBC uses the VTable pattern for zero-cost polymorphism:

```
┌─────────────────┐
│    Connection   │ ──── User Interface
├─────────────────┤
│     VTable      │ ──── Function Pointers
├─────────────────┤
│  ctx: *anyopaque│ ──── Driver-specific Context
└─────────────────┘
         │
         ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  SQLite Driver  │ │   PG Driver     │ │  MySQL Driver   │
│  (zqlite.zig)   │ │  (libpq)        │ │ (libmysqlclient)│
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

This pattern provides:
- **Zero-cost abstraction**: Direct function calls through pointers
- **Type safety**: Compile-time interface verification
- **Extensibility**: Easy to add new database drivers

## Building

```bash
# Basic build (SQLite only)
zig build

# With PostgreSQL support (requires libpq)
zig build -Duse_pg=true

# With MySQL support (requires libmysqlclient)
zig build -Duse_mysql=true

# With both
zig build -Duse_pg=true -Duse_mysql=true

# Run tests
zig build test
zig build test -Duse_pg=true -Duse_mysql=true

# Format code
zig fmt src
```

### Homebrew Users (macOS)

The build system auto-detects Homebrew paths for:
- PostgreSQL: `/opt/homebrew/opt/libpq/{include,lib}`
- MySQL: `/opt/homebrew/opt/mysql/{include,lib}`

For other install locations, set `addIncludePath` and `addLibraryPath` in your `build.zig`.

## Testing

Run the test suite:

```bash
# All enabled backends
zig build test -Duse_pg=true -Duse_mysql=true

# SQLite + Mock only (no external services)
zig build test
```

Integration tests require running database servers and environment variables:

**PostgreSQL:**
```bash
ZDBC_PG_HOST=localhost ZDBC_PG_USER=postgres ZDBC_PG_PASSWORD=secret zig build test -Duse_pg=true
```

**MySQL:**
```bash
ZDBC_MY_HOST=localhost ZDBC_MY_USER=root ZDBC_MY_PASSWORD=secret zig build test -Duse_mysql=true
```

For testing without a real database, use the mock driver:

```zig
var conn = try zdbc.openMock(allocator);
defer conn.close();
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `zig fmt src` and `zig build test`
5. Submit a pull request

## License

MIT License — see LICENSE file for details.

## Acknowledgments

- [zqlite.zig](https://github.com/karlseguin/zqlite.zig) — SQLite wrapper for Zig
- [libpq](https://www.postgresql.org/docs/current/libpq.html) — PostgreSQL C client library
- [libmysqlclient](https://dev.mysql.com/doc/c-api/9.0/en/) — MySQL C client library
