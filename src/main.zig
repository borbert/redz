const std = @import("std");
const builtin = @import("builtin");
const server_mod = @import("server.zig");
const store_mod = @import("store.zig");
const commands = @import("commands.zig");
const resp = @import("resp.zig");
const config_mod = @import("config.zig");
const persistence = @import("persistence.zig");

var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var global_store: store_mod.Store = undefined;
var shutdown_requested = server_mod.StopFlag.init(false);

const AppContext = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    persistence_config: *const config_mod.PersistenceConfig,
    persistence_runtime: *persistence.PersistenceRuntime,
};

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

fn handleClient(raw_context: ?*anyopaque, conn: *server_mod.Connection) !void {
    const app_context: *AppContext = @ptrCast(@alignCast(raw_context.?));

    var buf: [4096]u8 = undefined;
    const n = try conn.readRequest(&buf);
    if (n == 0) return;

    var conn_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = conn_gpa.deinit();
    const allocator = conn_gpa.allocator();

    const read_slice = buf[0..n];
    var read_fbs = std.io.fixedBufferStream(read_slice);
    var cmd = resp.parseCommand(allocator, read_fbs.reader()) catch {
        var out_buf: [256]u8 = undefined;
        var out_fbs = std.io.fixedBufferStream(&out_buf);
        try resp.writeError(out_fbs.writer(), "ERR invalid RESP");
        try conn.writeAll(out_fbs.getWritten());
        return;
    };
    defer resp.freeCommand(allocator, &cmd);

    var out_buf: [4096]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);
    var ctx = commands.CommandContext{
        .store = app_context.store,
        .allocator = app_context.allocator,
        .persistence_config = app_context.persistence_config,
        .persistence_runtime = app_context.persistence_runtime,
    };

    commands.dispatch(&ctx, cmd.name, cmd.args, out_fbs.writer()) catch |err| {
        var err_fbs = std.io.fixedBufferStream(&out_buf);
        if (err == error.UnknownCommand) {
            try resp.writeError(err_fbs.writer(), "unknown command");
        } else if (err == error.WrongArity) {
            try resp.writeError(err_fbs.writer(), "wrong number of arguments");
        } else if (err == error.InvalidInteger) {
            try resp.writeError(err_fbs.writer(), "ERR value is not an integer");
        } else if (err == error.WrongType) {
            try resp.writeError(err_fbs.writer(), "WRONGTYPE Operation against a key holding the wrong kind of value");
        } else {
            try resp.writeError(err_fbs.writer(), @errorName(err));
        }
        try conn.writeAll(err_fbs.getWritten());
        return;
    };

    try conn.writeAll(out_fbs.getWritten());
}

fn preparePersistenceDataDir(config: *const config_mod.PersistenceConfig) !void {
    if (!config.persistenceEnabled() or config.data_dir.len == 0) return;

    std.fs.cwd().makePath(config.data_dir) catch |err| {
        if (!builtin.is_test) {
            std.log.err("failed to create persistence data dir '{s}': {}", .{ config.data_dir, err });
        }
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
            if (!builtin.is_test) {
                std.log.err("failed to open rdb file '{s}': {}", .{ rdb_path, err });
            }
            return err;
        },
    };
    defer file.close();

    persistence.loadRdb(store, file.deprecatedReader()) catch |err| {
        if (!builtin.is_test) {
            std.log.err("failed to load rdb file '{s}': {}", .{ rdb_path, err });
        }
        return err;
    };

    std.log.info("loaded rdb file '{s}'", .{rdb_path});
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
    const app_context: *AppContext = @ptrCast(@alignCast(raw_context.?));
    const now_unix = std.time.timestamp();
    _ = maybeSavePeriodicSnapshot(
        now_unix,
        app_context.allocator,
        app_context.persistence_config,
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

    var persistence_config = try config_mod.parseFromArgs(allocator);
    defer persistence_config.deinit(allocator);

    global_store = try store_mod.Store.init(allocator);
    defer global_store.deinit();

    try preparePersistenceDataDir(&persistence_config);
    try loadStartupRdb(allocator, &persistence_config, &global_store);
    var persistence_runtime = persistence.PersistenceRuntime{
        .last_save_unix = std.time.timestamp(),
    };
    installShutdownSignalHandlers();

    std.log.info("starting redz on 127.0.0.1:6379", .{});

    var srv = try server_mod.Server.init("127.0.0.1", 6379);
    defer srv.deinit();

    var app_context = AppContext{
        .allocator = allocator,
        .store = &global_store,
        .persistence_config = &persistence_config,
        .persistence_runtime = &persistence_runtime,
    };
    const handler = server_mod.ConnectionHandler{
        .context = &app_context,
        .handleConnectionFn = handleClient,
    };
    const poll_hook = server_mod.PollHook{
        .context = &app_context,
        .onPollFn = pollPeriodicSnapshot,
    };

    try srv.run(&handler, &shutdown_requested, &poll_hook);
    try saveShutdownRdb(allocator, &persistence_config, &persistence_runtime, &global_store);
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

    var config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "dump.redz",
    };

    try preparePersistenceDataDir(&config);
    try std.fs.cwd().access(data_dir, .{});

    var source_store = try store_mod.Store.init(allocator);
    defer source_store.deinit();
    try source_store.set("startup", "loaded");

    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);

    {
        const file = try std.fs.cwd().createFile(rdb_path, .{});
        defer file.close();
        try persistence.saveRdb(&source_store, file.deprecatedWriter());
    }

    var loaded_store = try store_mod.Store.init(allocator);
    defer loaded_store.deinit();
    try loadStartupRdb(allocator, &config, &loaded_store);
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

    var config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "periodic.redz",
        .snapshot_interval_seconds = 10,
    };
    try preparePersistenceDataDir(&config);

    var source_store = try store_mod.Store.init(allocator);
    defer source_store.deinit();
    try source_store.set("periodic", "saved");

    var runtime = persistence.PersistenceRuntime{
        .last_save_unix = 100,
    };

    try std.testing.expect(!try maybeSavePeriodicSnapshot(109, allocator, &config, &runtime, &source_store));

    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(rdb_path, .{}));

    try std.testing.expect(try maybeSavePeriodicSnapshot(110, allocator, &config, &runtime, &source_store));
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
