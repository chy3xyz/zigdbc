const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const use_pg = b.option(bool, "use_pg", "Enable PostgreSQL driver (requires libpq)") orelse false;
    const use_mysql = b.option(bool, "use_mysql", "Enable MySQL driver (requires libmysqlclient)") orelse false;

    // Get dependencies (zqlite for SQLite, always available)
    const zqlite_dep = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options module for conditional compilation
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "use_pg", use_pg);
    build_opts.addOption(bool, "use_mysql", use_mysql);

    // Main library module
    const zdbc_mod = b.addModule("zdbc", .{
        .root_source_file = b.path("src/zdbc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
            .{ .name = "build_options", .module = build_opts.createModule() },
        },
    });
    zdbc_mod.linkSystemLibrary("sqlite3", .{});
    if (use_pg) {
        zdbc_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
        zdbc_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
        zdbc_mod.linkSystemLibrary("pq", .{});
    }
    if (use_mysql) {
        zdbc_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/mysql/include" });
        zdbc_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/mysql/lib" });
        zdbc_mod.linkSystemLibrary("mysqlclient", .{});
    }

    // Unit tests module
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zdbc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
            .{ .name = "build_options", .module = build_opts.createModule() },
        },
    });
    test_mod.linkSystemLibrary("sqlite3", .{});
    if (use_pg) {
        test_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
        test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
        test_mod.linkSystemLibrary("pq", .{});
    }
    if (use_mysql) {
        test_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/mysql/include" });
        test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/mysql/lib" });
        test_mod.linkSystemLibrary("mysqlclient", .{});
    }

    // Unit tests
    const main_tests = b.addTest(.{
        .name = "zdbc-test",
        .root_module = test_mod,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_tests.step);

    // Integration tests module
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
            .{ .name = "build_options", .module = build_opts.createModule() },
        },
    });
    integration_test_mod.linkSystemLibrary("sqlite3", .{});
    if (use_pg) {
        integration_test_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
        integration_test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
        integration_test_mod.linkSystemLibrary("pq", .{});
    }
    if (use_mysql) {
        integration_test_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/mysql/include" });
        integration_test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/mysql/lib" });
        integration_test_mod.linkSystemLibrary("mysqlclient", .{});
    }

    const integration_tests = b.addTest(.{
        .name = "zdbc-integration-test",
        .root_module = integration_test_mod,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
