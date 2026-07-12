const std = @import("std");
const builtin = @import("builtin");
const server_mod = @import("server.zig");
const store_mod = @import("store.zig");
const config_mod = @import("config.zig");
const persistence = @import("persistence.zig");
const aof = @import("aof.zig");
const client = @import("client.zig");

var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var global_store: store_mod.Store = undefined;
var shutdown_requested = server_mod.StopFlag.init(false);
var store_mutex = std.Thread.Mutex{};

fn handleShutdownSignal(_: i32) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn installShutdownSignalHandlers() void {
    if (builtin.os.tag == .windows) return;

    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.log.err(fmt, args);
}

fn preparePersistenceDataDir(config: *const config_mod.PersistenceConfig) !void {
    if (!config.persistenceEnabled() or config.data_dir.len == 0) return;

    std.fs.cwd().makePath(config.data_dir) catch |err| {
        logErr("failed to create persistence data dir '{s}': {}", .{ config.data_dir, err });
        return err;
    };
}

fn loadStartupRdb(
    allocator: std.mem.Allocator,
    config: *const config_mod.PersistenceConfig,
    store: *store_mod.Store,
) !void {
    if (!config.rdbEnabled()) return;

    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);

    const file = std.fs.cwd().openFile(rdb_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("rdb file '{s}' not found; starting with empty store", .{rdb_path});
            return;
        },
        else => {
            logErr("failed to open rdb file '{s}': {}", .{ rdb_path, err });
            return err;
        },
    };
    defer file.close();

    persistence.loadRdb(store, file.deprecatedReader()) catch |err| {
        logErr("failed to load rdb file '{s}': {}", .{ rdb_path, err });
        return err;
    };

    std.log.info("loaded rdb file '{s}'", .{rdb_path});
}

fn replayStartupAof(
    allocator: std.mem.Allocator,
    config: *const config_mod.PersistenceConfig,
    store: *store_mod.Store,
) !void {
    if (!config.aofEnabled()) return;

    const aof_path = try config.aofPath(allocator);
    defer allocator.free(aof_path);

    aof.replayAof(allocator, store, aof_path) catch |err| {
        logErr("failed to replay aof file '{s}': {}", .{ aof_path, err });
        return err;
    };

    std.log.info("replayed aof file '{s}'", .{aof_path});
}

fn openStartupAof(
    allocator: std.mem.Allocator,
    config: *const config_mod.PersistenceConfig,
) !?aof.AofWriter {
    if (!config.aofEnabled()) return null;

    const aof_path = try config.aofPath(allocator);
    defer allocator.free(aof_path);

    var writer = aof.AofWriter.open(aof_path, config.aof_fsync) catch |err| {
        logErr("failed to open aof file '{s}': {}", .{ aof_path, err });
        return err;
    };
    errdefer writer.close() catch {};

    std.log.info("opened aof file '{s}' with fsync mode {s}", .{ aof_path, @tagName(config.aof_fsync) });
    return writer;
}

fn closeAofWriter(writer_opt: *?aof.AofWriter) void {
    if (writer_opt.*) |*writer| {
        writer.close() catch |err| {
            std.log.err("aof close failed: {}", .{err});
        };
        writer_opt.* = null;
    }
}

fn saveShutdownRdb(
    allocator: std.mem.Allocator,
    config: *const config_mod.PersistenceConfig,
    runtime: *persistence.PersistenceRuntime,
    store: *store_mod.Store,
) !void {
    if (!config.rdbEnabled()) return;

    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);

    try persistence.saveRdbAtomic(allocator, rdb_path, store);
    runtime.last_save_unix = std.time.timestamp();
    std.log.info("saved rdb file '{s}'", .{rdb_path});
}

fn maybeSavePeriodicSnapshot(
    now_unix: i64,
    allocator: std.mem.Allocator,
    config: *const config_mod.PersistenceConfig,
    runtime: *persistence.PersistenceRuntime,
    store: *store_mod.Store,
) !bool {
    if (!config.rdbEnabled()) return false;
    if (config.snapshot_interval_seconds == 0) return false;

    const interval_seconds: i64 = @intCast(config.snapshot_interval_seconds);
    if (runtime.last_save_unix != 0 and now_unix - runtime.last_save_unix < interval_seconds) {
        return false;
    }

    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);

    try persistence.saveRdbAtomic(allocator, rdb_path, store);
    runtime.last_save_unix = now_unix;
    std.log.info("periodic rdb snapshot saved '{s}'", .{rdb_path});
    return true;
}

fn pollPeriodicSnapshot(raw_context: ?*anyopaque) void {
    const app_context: *client.AppContext = @ptrCast(@alignCast(raw_context.?));
    app_context.mutex.lock();
    defer app_context.mutex.unlock();

    const now_unix = std.time.timestamp();
    _ = maybeSavePeriodicSnapshot(
        now_unix,
        app_context.allocator,
        &app_context.config.persistence,
        app_context.persistence_runtime,
        app_context.store,
    ) catch |err| {
        std.log.err("periodic rdb snapshot failed: {}", .{err});
        return;
    };
}

pub fn main() !void {
    gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();

    const allocator = gpa_impl.allocator();

    var config = try config_mod.parseFromArgs(allocator);
    defer config.deinit(allocator);

    global_store = try store_mod.Store.init(allocator);
    defer global_store.deinit();

    try preparePersistenceDataDir(&config.persistence);
    try loadStartupRdb(allocator, &config.persistence, &global_store);
    try replayStartupAof(allocator, &config.persistence, &global_store);
    var aof_writer = try openStartupAof(allocator, &config.persistence);
    defer closeAofWriter(&aof_writer);
    var persistence_runtime = persistence.PersistenceRuntime{
        .last_save_unix = std.time.timestamp(),
    };
    installShutdownSignalHandlers();

    std.log.info("starting redz on {s}:{d}", .{ config.host, config.port });

    var srv = try server_mod.Server.init(config.host, config.port);
    defer srv.deinit();

    var app_context = client.AppContext{
        .allocator = allocator,
        .store = &global_store,
        .mutex = &store_mutex,
        .config = &config,
        .persistence_runtime = &persistence_runtime,
        .aof_writer = if (aof_writer) |*writer| writer else null,
    };
    const handler = server_mod.ConnectionHandler{
        .context = &app_context,
        .handleConnectionFn = client.handleConnection,
    };
    const poll_hook = server_mod.PollHook{
        .context = &app_context,
        .onPollFn = pollPeriodicSnapshot,
    };

    try srv.run(&handler, &shutdown_requested, &poll_hook);

    closeAofWriter(&aof_writer);

    store_mutex.lock();
    defer store_mutex.unlock();
    try saveShutdownRdb(allocator, &config.persistence, &persistence_runtime, &global_store);
}

test "startup rdb loads existing file and ignores missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "data",
    });
    defer allocator.free(data_dir);

    var persistence_config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "dump.redz",
    };

    try preparePersistenceDataDir(&persistence_config);
    try std.fs.cwd().access(data_dir, .{});

    var source_store = try store_mod.Store.init(allocator);
    defer source_store.deinit();
    try source_store.set("startup", "loaded");

    const rdb_path = try persistence_config.rdbPath(allocator);
    defer allocator.free(rdb_path);

    {
        const file = try std.fs.cwd().createFile(rdb_path, .{});
        defer file.close();
        try persistence.saveRdb(&source_store, file.deprecatedWriter());
    }

    var loaded_store = try store_mod.Store.init(allocator);
    defer loaded_store.deinit();
    try loadStartupRdb(allocator, &persistence_config, &loaded_store);
    try std.testing.expectEqualStrings("loaded", loaded_store.get("startup").?);

    var missing_config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "missing.redz",
    };
    var missing_store = try store_mod.Store.init(allocator);
    defer missing_store.deinit();
    try loadStartupRdb(allocator, &missing_config, &missing_store);
    try std.testing.expectEqual(@as(usize, 0), missing_store.map.count());

    var corrupt_config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "corrupt.redz",
    };
    const corrupt_path = try corrupt_config.rdbPath(allocator);
    defer allocator.free(corrupt_path);
    {
        const file = try std.fs.cwd().createFile(corrupt_path, .{});
        defer file.close();
        try file.deprecatedWriter().writeAll("not an rdb");
    }

    var corrupt_store = try store_mod.Store.init(allocator);
    defer corrupt_store.deinit();
    try std.testing.expectError(error.InvalidRdb, loadStartupRdb(allocator, &corrupt_config, &corrupt_store));
}

test "periodic snapshot helper saves only after interval elapses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "periodic",
    });
    defer allocator.free(data_dir);

    var persistence_config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "periodic.redz",
        .snapshot_interval_seconds = 10,
    };
    try preparePersistenceDataDir(&persistence_config);

    var source_store = try store_mod.Store.init(allocator);
    defer source_store.deinit();
    try source_store.set("periodic", "saved");

    var runtime = persistence.PersistenceRuntime{
        .last_save_unix = 100,
    };

    try std.testing.expect(!try maybeSavePeriodicSnapshot(109, allocator, &persistence_config, &runtime, &source_store));

    const rdb_path = try persistence_config.rdbPath(allocator);
    defer allocator.free(rdb_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(rdb_path, .{}));

    try std.testing.expect(try maybeSavePeriodicSnapshot(110, allocator, &persistence_config, &runtime, &source_store));
    try std.testing.expectEqual(@as(i64, 110), runtime.last_save_unix);

    const file = try std.fs.cwd().openFile(rdb_path, .{});
    defer file.close();

    var loaded_store = try store_mod.Store.init(allocator);
    defer loaded_store.deinit();
    try persistence.loadRdb(&loaded_store, file.deprecatedReader());
    try std.testing.expectEqualStrings("saved", loaded_store.get("periodic").?);
}

test "periodic snapshot helper skips disabled autosnapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "disabled",
    });
    defer allocator.free(data_dir);

    var store = try store_mod.Store.init(allocator);
    defer store.deinit();
    try store.set("disabled", "unchanged");

    var runtime = persistence.PersistenceRuntime{};
    var interval_zero_config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "zero.redz",
        .snapshot_interval_seconds = 0,
    };
    try preparePersistenceDataDir(&interval_zero_config);

    try std.testing.expect(!try maybeSavePeriodicSnapshot(10, allocator, &interval_zero_config, &runtime, &store));
    try std.testing.expectEqual(@as(i64, 0), runtime.last_save_unix);

    const zero_path = try interval_zero_config.rdbPath(allocator);
    defer allocator.free(zero_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(zero_path, .{}));

    var disabled_config = config_mod.PersistenceConfig{
        .mode = .none,
        .data_dir = data_dir,
        .rdb_filename = "none.redz",
        .snapshot_interval_seconds = 1,
    };
    try std.testing.expect(!try maybeSavePeriodicSnapshot(10, allocator, &disabled_config, &runtime, &store));
    try std.testing.expectEqual(@as(i64, 0), runtime.last_save_unix);
}
