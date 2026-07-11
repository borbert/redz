const std = @import("std");
const config_mod = @import("config.zig");
const commands = @import("commands.zig");
const persistence = @import("persistence.zig");
const resp = @import("resp.zig");
const store_mod = @import("store.zig");

const NEVER_FSYNCED_UNIX = std.math.minInt(i64);
const MAX_REPLAY_BYTES = 64 * 1024 * 1024;

pub const AofWriter = struct {
    file: ?std.fs.File,
    fsync_mode: config_mod.AofFsyncMode,
    last_fsync_unix: i64 = NEVER_FSYNCED_UNIX,
    fsync_count: usize = 0,

    pub fn open(path: []const u8, fsync_mode: config_mod.AofFsyncMode) !AofWriter {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        errdefer file.close();
        try file.seekFromEnd(0);

        return .{
            .file = file,
            .fsync_mode = fsync_mode,
        };
    }

    pub fn append(self: *AofWriter, bytes: []const u8) !void {
        const file = self.file orelse return error.AofClosed;
        try file.writeAll(bytes);
    }

    pub fn maybeFsync(self: *AofWriter, now_unix: i64) !void {
        switch (self.fsync_mode) {
            .always => try self.fsync(now_unix),
            .everysec => {
                if (self.last_fsync_unix == NEVER_FSYNCED_UNIX or
                    now_unix - self.last_fsync_unix >= 1)
                {
                    try self.fsync(now_unix);
                }
            },
            .no => {},
        }
    }

    pub fn close(self: *AofWriter) !void {
        var file = self.file orelse return;
        self.file = null;
        defer file.close();

        try file.sync();
        self.fsync_count += 1;
        self.last_fsync_unix = std.time.timestamp();
    }

    fn fsync(self: *AofWriter, now_unix: i64) !void {
        const file = self.file orelse return error.AofClosed;
        try file.sync();
        self.fsync_count += 1;
        self.last_fsync_unix = now_unix;
    }
};

pub fn replayAof(allocator: std.mem.Allocator, store: *store_mod.Store, path: []const u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, MAX_REPLAY_BYTES);
    defer allocator.free(bytes);

    try replayAofBytes(allocator, store, bytes);
}

pub fn replayAofBytes(allocator: std.mem.Allocator, store: *store_mod.Store, bytes: []const u8) !void {
    var stream = std.io.fixedBufferStream(bytes);
    var ctx = commands.CommandContext{
        .store = store,
        .allocator = allocator,
    };
    var discard_buffer: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);

    while (stream.pos < bytes.len) {
        var cmd = resp.parseCommand(allocator, stream.reader()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResp,
        };
        defer resp.freeCommand(allocator, &cmd);

        commands.dispatch(&ctx, cmd.name, cmd.args, &discard.writer) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAof,
        };
    }
}

test "aof append writes raw bytes and preserves existing file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "appendonly.aof",
    });
    defer allocator.free(path);

    {
        var writer = try AofWriter.open(path, .no);
        try writer.append("*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n");
        try writer.close();
    }

    {
        var writer = try AofWriter.open(path, .no);
        try writer.append("*2\r\n$3\r\nDEL\r\n$1\r\na\r\n");
        try writer.close();
    }

    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(
        "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n*2\r\n$3\r\nDEL\r\n$1\r\na\r\n",
        contents,
    );
}

test "aof fsync always syncs each maybeFsync call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "always.aof",
    });
    defer allocator.free(path);

    var writer = try AofWriter.open(path, .always);
    defer writer.close() catch {};

    try writer.append("a");
    try writer.maybeFsync(10);
    try std.testing.expectEqual(@as(usize, 1), writer.fsync_count);

    try writer.append("b");
    try writer.maybeFsync(10);
    try std.testing.expectEqual(@as(usize, 2), writer.fsync_count);
    try std.testing.expectEqual(@as(i64, 10), writer.last_fsync_unix);
}

test "aof fsync everysec syncs at most once per second" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "everysec.aof",
    });
    defer allocator.free(path);

    var writer = try AofWriter.open(path, .everysec);
    defer writer.close() catch {};

    try writer.append("a");
    try writer.maybeFsync(20);
    try std.testing.expectEqual(@as(usize, 1), writer.fsync_count);
    try std.testing.expectEqual(@as(i64, 20), writer.last_fsync_unix);

    try writer.append("b");
    try writer.maybeFsync(20);
    try std.testing.expectEqual(@as(usize, 1), writer.fsync_count);

    try writer.append("c");
    try writer.maybeFsync(21);
    try std.testing.expectEqual(@as(usize, 2), writer.fsync_count);
    try std.testing.expectEqual(@as(i64, 21), writer.last_fsync_unix);
}

test "aof fsync no mode skips explicit sync on append path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "no.aof",
    });
    defer allocator.free(path);

    var writer = try AofWriter.open(path, .no);
    defer writer.close() catch {};

    try writer.append("a");
    try writer.maybeFsync(30);
    try std.testing.expectEqual(@as(usize, 0), writer.fsync_count);
    try std.testing.expectEqual(NEVER_FSYNCED_UNIX, writer.last_fsync_unix);
}

test "aof replay applies commands into empty store" {
    const allocator = std.testing.allocator;
    var store = try store_mod.Store.init(allocator);
    defer store.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "replay.aof",
    });
    defer allocator.free(path);

    {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.deprecatedWriter().writeAll(
            "*3\r\n$3\r\nSET\r\n$5\r\nalpha\r\n$3\r\none\r\n" ++
                "*3\r\n$3\r\nSET\r\n$4\r\nbeta\r\n$3\r\ntwo\r\n" ++
                "*2\r\n$3\r\nDEL\r\n$4\r\nbeta\r\n",
        );
    }

    try replayAof(allocator, &store, path);

    try std.testing.expectEqualStrings("one", store.get("alpha").?);
    try std.testing.expect(store.get("beta") == null);
}

test "aof replay ignores missing file and rejects truncated input" {
    const allocator = std.testing.allocator;
    var store = try store_mod.Store.init(allocator);
    defer store.deinit();

    try replayAof(allocator, &store, ".zig-cache/tmp/redz-missing-replay.aof");
    try std.testing.expectEqual(@as(usize, 0), store.map.count());

    try std.testing.expectError(
        error.InvalidResp,
        replayAofBytes(allocator, &store, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalu"),
    );
}

test "aof replay applies delta after rdb baseline" {
    const allocator = std.testing.allocator;
    var baseline = try store_mod.Store.init(allocator);
    defer baseline.deinit();
    var loaded = try store_mod.Store.init(allocator);
    defer loaded.deinit();

    try baseline.set("base", "rdb");
    var rdb_buffer: [1024]u8 = undefined;
    var out = std.io.fixedBufferStream(&rdb_buffer);
    try persistence.saveRdb(&baseline, out.writer());

    var input = std.io.fixedBufferStream(out.getWritten());
    try persistence.loadRdb(&loaded, input.reader());
    try replayAofBytes(
        allocator,
        &loaded,
        "*3\r\n$3\r\nSET\r\n$5\r\ndelta\r\n$3\r\naof\r\n" ++
            "*3\r\n$3\r\nSET\r\n$4\r\nbase\r\n$7\r\nupdated\r\n",
    );

    try std.testing.expectEqualStrings("updated", loaded.get("base").?);
    try std.testing.expectEqualStrings("aof", loaded.get("delta").?);
}
