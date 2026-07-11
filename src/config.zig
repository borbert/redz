const std = @import("std");

pub const PersistenceMode = enum {
    none,
    rdb,
    aof,
    both,
};

pub const AofFsyncMode = enum {
    always,
    everysec,
    no,
};

pub const PersistenceConfig = struct {
    mode: PersistenceMode = .none,
    data_dir: []const u8 = ".",
    rdb_filename: []const u8 = "dump.redz",
    aof_filename: []const u8 = "appendonly.redz.aof",
    snapshot_interval_seconds: u32 = 60,
    aof_fsync: AofFsyncMode = .everysec,
    owns_data_dir: bool = false,
    owns_rdb_filename: bool = false,
    owns_aof_filename: bool = false,

    pub fn deinit(self: *PersistenceConfig, allocator: std.mem.Allocator) void {
        if (self.owns_data_dir) allocator.free(self.data_dir);
        if (self.owns_rdb_filename) allocator.free(self.rdb_filename);
        if (self.owns_aof_filename) allocator.free(self.aof_filename);
        self.* = .{};
    }

    pub fn rdbPath(self: *const PersistenceConfig, allocator: std.mem.Allocator) ![]const u8 {
        if (self.data_dir.len == 0) return allocator.dupe(u8, self.rdb_filename);
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, self.rdb_filename });
    }

    pub fn aofPath(self: *const PersistenceConfig, allocator: std.mem.Allocator) ![]const u8 {
        if (self.data_dir.len == 0) return allocator.dupe(u8, self.aof_filename);
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, self.aof_filename });
    }

    pub fn rdbEnabled(self: *const PersistenceConfig) bool {
        return self.mode == .rdb or self.mode == .both;
    }

    pub fn aofEnabled(self: *const PersistenceConfig) bool {
        return self.mode == .aof or self.mode == .both;
    }

    pub fn persistenceEnabled(self: *const PersistenceConfig) bool {
        return self.rdbEnabled() or self.aofEnabled();
    }
};

pub fn parsePersistenceMode(s: []const u8) ?PersistenceMode {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "rdb")) return .rdb;
    if (std.mem.eql(u8, s, "aof")) return .aof;
    if (std.mem.eql(u8, s, "both")) return .both;
    return null;
}

pub fn parseAofFsyncMode(s: []const u8) ?AofFsyncMode {
    if (std.mem.eql(u8, s, "always")) return .always;
    if (std.mem.eql(u8, s, "everysec")) return .everysec;
    if (std.mem.eql(u8, s, "no")) return .no;
    return null;
}

fn replaceOwnedString(
    allocator: std.mem.Allocator,
    slot: *[]const u8,
    owns_slot: *bool,
    value: []const u8,
) !void {
    const owned_value = try allocator.dupe(u8, value);
    if (owns_slot.*) allocator.free(slot.*);
    slot.* = owned_value;
    owns_slot.* = true;
}

fn parseOptionArgs(allocator: std.mem.Allocator, args: []const []const u8) !PersistenceConfig {
    var config = PersistenceConfig{};
    errdefer config.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--persistence")) {
            i += 1;
            if (i >= args.len) return error.MissingPersistenceValue;
            config.mode = parsePersistenceMode(args[i]) orelse return error.InvalidPersistenceMode;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingDataDirValue;
            try replaceOwnedString(allocator, &config.data_dir, &config.owns_data_dir, args[i]);
        } else if (std.mem.eql(u8, arg, "--rdb-filename")) {
            i += 1;
            if (i >= args.len) return error.MissingRdbFilenameValue;
            try replaceOwnedString(allocator, &config.rdb_filename, &config.owns_rdb_filename, args[i]);
        } else if (std.mem.eql(u8, arg, "--aof-filename")) {
            i += 1;
            if (i >= args.len) return error.MissingAofFilenameValue;
            try replaceOwnedString(allocator, &config.aof_filename, &config.owns_aof_filename, args[i]);
        } else if (std.mem.eql(u8, arg, "--snapshot-interval")) {
            i += 1;
            if (i >= args.len) return error.MissingSnapshotIntervalValue;
            config.snapshot_interval_seconds = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidSnapshotInterval;
        } else if (std.mem.eql(u8, arg, "--aof-fsync")) {
            i += 1;
            if (i >= args.len) return error.MissingAofFsyncValue;
            config.aof_fsync = parseAofFsyncMode(args[i]) orelse return error.InvalidAofFsync;
        }
    }

    return config;
}

pub fn parseFromArgv(allocator: std.mem.Allocator, argv: []const []const u8) !PersistenceConfig {
    if (argv.len == 0) return parseOptionArgs(allocator, &.{});
    return parseOptionArgs(allocator, argv[1..]);
}

pub fn parseFromArgs(allocator: std.mem.Allocator) !PersistenceConfig {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    while (args.next()) |arg| {
        try argv.append(allocator, arg);
    }

    return parseFromArgv(allocator, argv.items);
}

test "parsePersistenceMode accepts supported modes" {
    try std.testing.expectEqual(PersistenceMode.none, parsePersistenceMode("none").?);
    try std.testing.expectEqual(PersistenceMode.rdb, parsePersistenceMode("rdb").?);
    try std.testing.expectEqual(PersistenceMode.aof, parsePersistenceMode("aof").?);
    try std.testing.expectEqual(PersistenceMode.both, parsePersistenceMode("both").?);
    try std.testing.expectEqual(@as(?PersistenceMode, null), parsePersistenceMode("invalid"));
}

test "parseFromArgv parses persistence options" {
    const argv = [_][]const u8{
        "redz",
        "--persistence",
        "both",
        "--data-dir",
        "var/redz",
        "--rdb-filename",
        "snapshot.rdb",
        "--aof-filename",
        "append.aof",
        "--snapshot-interval",
        "120",
        "--aof-fsync",
        "always",
    };

    var config = try parseFromArgv(std.testing.allocator, &argv);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(PersistenceMode.both, config.mode);
    try std.testing.expectEqualStrings("var/redz", config.data_dir);
    try std.testing.expectEqualStrings("snapshot.rdb", config.rdb_filename);
    try std.testing.expectEqualStrings("append.aof", config.aof_filename);
    try std.testing.expectEqual(@as(u32, 120), config.snapshot_interval_seconds);
    try std.testing.expectEqual(AofFsyncMode.always, config.aof_fsync);
    try std.testing.expect(config.rdbEnabled());
    try std.testing.expect(config.aofEnabled());
}

test "parseFromArgv rejects invalid and missing values" {
    try std.testing.expectError(
        error.InvalidPersistenceMode,
        parseFromArgv(std.testing.allocator, &[_][]const u8{ "redz", "--persistence", "snapshot" }),
    );
    try std.testing.expectError(
        error.MissingRdbFilenameValue,
        parseFromArgv(std.testing.allocator, &[_][]const u8{ "redz", "--rdb-filename" }),
    );
    try std.testing.expectError(
        error.InvalidSnapshotInterval,
        parseFromArgv(std.testing.allocator, &[_][]const u8{ "redz", "--snapshot-interval", "soon" }),
    );
}
