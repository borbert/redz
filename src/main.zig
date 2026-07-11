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

fn handleClient(conn: *server_mod.Connection) !void {
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
    var ctx = commands.CommandContext{ .store = &global_store };

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

    std.log.info("starting redz on 127.0.0.1:6379", .{});

    var srv = try server_mod.Server.init("127.0.0.1", 6379);
    defer srv.deinit();

    const handler = server_mod.ConnectionHandler{
        .handleConnectionFn = handleClient,
    };

    try srv.run(&handler);
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
