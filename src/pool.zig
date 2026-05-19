//! Connection pool for database connections
//!
//! Provides a thread-safe pool of database connections for efficient
//! connection reuse and management.
//!
//! Uses std.atomic.Mutex (spinlock) for thread safety in Zig 0.16.

const std = @import("std");
const Connection = @import("connection.zig").Connection;
const Error = @import("error.zig").Error;
const Uri = @import("uri.zig").Uri;
const zdbc = @import("zdbc.zig");

/// Configuration for the connection pool
pub const PoolConfig = struct {
    /// Minimum number of connections to maintain
    min_size: usize = 1,

    /// Maximum number of connections allowed
    max_size: usize = 10,

    /// Maximum time to wait for a connection (in milliseconds)
    acquire_timeout_ms: u64 = 30000,

    /// Time before an idle connection is closed (in milliseconds)
    idle_timeout_ms: u64 = 300000,

    /// Whether to validate connections before returning them
    validate_on_acquire: bool = true,

    /// Callback to initialize each connection
    on_connection: ?*const fn (*Connection) Error!void = null,
};

/// Pooled connection wrapper
pub const PooledConnection = struct {
    conn: Connection,
    pool: *Pool,
    in_use: bool = false,
    index: usize = 0,

    pub fn release(self: *PooledConnection) void {
        self.pool.releaseConnection(self);
    }

    pub fn connection(self: *PooledConnection) *Connection {
        return &self.conn;
    }
};

/// Thread-safe connection pool using spinlock-based synchronization.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    uri: Uri,
    connections: std.ArrayListUnmanaged(PooledConnection) = .{ .items = &.{}, .capacity = 0 },
    available: std.ArrayListUnmanaged(usize) = .{ .items = &.{}, .capacity = 0 },
    mutex: std.atomic.Mutex = .unlocked,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, uri_string: []const u8, config: PoolConfig) Error!*Pool {
        const uri = Uri.parse(uri_string) catch return Error.InvalidUri;
        return initWithUri(allocator, uri, config);
    }

    pub fn initWithUri(allocator: std.mem.Allocator, uri: Uri, config: PoolConfig) Error!*Pool {
        const pool = allocator.create(Pool) catch return Error.OutOfMemory;
        pool.* = Pool{
            .allocator = allocator,
            .config = config,
            .uri = uri,
        };

        // Create minimum number of connections
        var i: usize = 0;
        while (i < config.min_size) : (i += 1) {
            pool.createConnection() catch |err| {
                pool.deinit();
                return err;
            };
        }

        return pool;
    }

    fn createConnection(self: *Pool) Error!void {
        var conn = try zdbc.openWithUri(self.allocator, self.uri);

        if (self.config.on_connection) |callback| {
            try callback(&conn);
        }

        const index = self.connections.items.len;
        try self.connections.append(self.allocator, PooledConnection{
            .conn = conn,
            .pool = self,
            .in_use = false,
            .index = index,
        });

        try self.available.append(self.allocator, index);
    }

    fn lock(self: *Pool) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Pool) void {
        self.mutex.unlock();
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *Pool) Error!*PooledConnection {
        self.lock();
        defer self.unlock();

        if (self.closed) return Error.PoolExhausted;

        var attempts: usize = 0;
        const max_attempts: usize = @intCast(@divTrunc(self.config.acquire_timeout_ms, 10));
        if (max_attempts < 1) return Error.Timeout;

        while (self.available.items.len == 0) {
            if (self.connections.items.len < self.config.max_size) {
                self.createConnection() catch {};
                if (self.available.items.len > 0) break;
            }

            attempts += 1;
            if (attempts > max_attempts) return Error.Timeout;

            // Drop lock, yield, reacquire (spin-based wait for Zig 0.16)
            self.unlock();
            var spin: usize = 10000;
            while (spin > 0) : (spin -= 1) {
                std.atomic.spinLoopHint();
            }
            self.lock();

            if (self.closed) return Error.PoolExhausted;
        }

        const index = self.available.pop() orelse return Error.PoolExhausted;
        var pooled_conn = &self.connections.items[index];
        pooled_conn.in_use = true;

        if (self.config.validate_on_acquire) {
            pooled_conn.conn.ping() catch {
                pooled_conn.conn.close();
                pooled_conn.conn = zdbc.openWithUri(self.allocator, self.uri) catch {
                    pooled_conn.in_use = false;
                    return Error.ConnectionFailed;
                };
            };
        }

        return pooled_conn;
    }

    /// Release a connection back to the pool
    pub fn releaseConnection(self: *Pool, pooled_conn: *PooledConnection) void {
        self.lock();
        defer self.unlock();

        if (self.closed) {
            pooled_conn.conn.close();
            return;
        }

        pooled_conn.in_use = false;
        self.available.append(self.allocator, pooled_conn.index) catch {};
    }

    /// Release a connection (alternative to pooled_conn.release())
    pub fn release(self: *Pool, pooled_conn: *PooledConnection) void {
        self.releaseConnection(pooled_conn);
    }

    /// Get the number of connections in the pool
    pub fn size(self: *Pool) usize {
        self.lock();
        defer self.unlock();
        return self.connections.items.len;
    }

    /// Get the number of available connections
    pub fn availableCount(self: *Pool) usize {
        self.lock();
        defer self.unlock();
        return self.available.items.len;
    }

    /// Close all connections and release resources
    pub fn deinit(self: *Pool) void {
        self.lock();
        self.closed = true;
        self.unlock();

        for (self.connections.items) |*pc| {
            pc.conn.close();
        }

        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

test "PoolConfig defaults" {
    const config = PoolConfig{};
    try std.testing.expectEqual(@as(usize, 1), config.min_size);
    try std.testing.expectEqual(@as(usize, 10), config.max_size);
    try std.testing.expect(config.validate_on_acquire);
}
