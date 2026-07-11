const std = @import("std");
const config_mod = @import("config.zig");

const NEVER_FSYNCED_UNIX = std.math.minInt(i64);

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
