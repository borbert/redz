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

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    owns_host: bool = false,
    persistence: PersistenceConfig = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.owns_host) allocator.free(self.host);
        self.persistence.deinit(allocator);
        self.* = .{};
    }
};

pub fn parsePersistenceMode(s: []const u8) ?PersistenceMode {
    return std.meta.stringToEnum(PersistenceMode, s);
}

pub fn parseAofFsyncMode(s: []const u8) ?AofFsyncMode {
    return std.meta.stringToEnum(AofFsyncMode, s);
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

fn requireArg(args: []const []const u8, index: *usize, missing: anyerror) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return missing;
    return args[index.*];
}

fn applyEnvDefaults(allocator: std.mem.Allocator, config: *Config) !void {
    if (std.posix.getenv("REDZ_HOST")) |host| {
        try replaceOwnedString(allocator, &config.host, &config.owns_host, host);
    }
    if (std.posix.getenv("REDZ_PORT")) |port_str| {
        config.port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
    }
    if (std.posix.getenv("REDZ_PERSISTENCE")) |mode| {
        config.persistence.mode = parsePersistenceMode(mode) orelse return error.InvalidPersistenceMode;
    }
    if (std.posix.getenv("REDZ_DATA_DIR")) |dir| {
        try replaceOwnedString(allocator, &config.persistence.data_dir, &config.persistence.owns_data_dir, dir);
    }
    if (std.posix.getenv("REDZ_RDB_FILENAME")) |name| {
        try replaceOwnedString(allocator, &config.persistence.rdb_filename, &config.persistence.owns_rdb_filename, name);
    }
    if (std.posix.getenv("REDZ_AOF_FILENAME")) |name| {
        try replaceOwnedString(allocator, &config.persistence.aof_filename, &config.persistence.owns_aof_filename, name);
    }
    if (std.posix.getenv("REDZ_SNAPSHOT_INTERVAL")) |value| {
        config.persistence.snapshot_interval_seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidSnapshotInterval;
    }
    if (std.posix.getenv("REDZ_AOF_FSYNC")) |value| {
        config.persistence.aof_fsync = parseAofFsyncMode(value) orelse return error.InvalidAofFsync;
    }
}

fn parseOptionArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var config = Config{};
    errdefer config.deinit(allocator);

    try applyEnvDefaults(allocator, &config);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            const value = try requireArg(args, &i, error.MissingHostValue);
            try replaceOwnedString(allocator, &config.host, &config.owns_host, value);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const value = try requireArg(args, &i, error.MissingPortValue);
            config.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--persistence")) {
            const value = try requireArg(args, &i, error.MissingPersistenceValue);
            config.persistence.mode = parsePersistenceMode(value) orelse return error.InvalidPersistenceMode;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            const value = try requireArg(args, &i, error.MissingDataDirValue);
            try replaceOwnedString(allocator, &config.persistence.data_dir, &config.persistence.owns_data_dir, value);
        } else if (std.mem.eql(u8, arg, "--rdb-filename")) {
            const value = try requireArg(args, &i, error.MissingRdbFilenameValue);
            try replaceOwnedString(allocator, &config.persistence.rdb_filename, &config.persistence.owns_rdb_filename, value);
        } else if (std.mem.eql(u8, arg, "--aof-filename")) {
            const value = try requireArg(args, &i, error.MissingAofFilenameValue);
            try replaceOwnedString(allocator, &config.persistence.aof_filename, &config.persistence.owns_aof_filename, value);
        } else if (std.mem.eql(u8, arg, "--snapshot-interval")) {
            const value = try requireArg(args, &i, error.MissingSnapshotIntervalValue);
            config.persistence.snapshot_interval_seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidSnapshotInterval;
        } else if (std.mem.eql(u8, arg, "--aof-fsync")) {
            const value = try requireArg(args, &i, error.MissingAofFsyncValue);
            config.persistence.aof_fsync = parseAofFsyncMode(value) orelse return error.InvalidAofFsync;
        }
    }

    return config;
}

pub fn parseFromArgv(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
    if (argv.len == 0) return parseOptionArgs(allocator, &.{});
    return parseOptionArgs(allocator, argv[1..]);
}

pub fn parseFromArgs(allocator: std.mem.Allocator) !Config {
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

test "parseFromArgv parses host port and persistence options" {
    const argv = [_][]const u8{
        "redz",
        "--host",
        "0.0.0.0",
        "--port",
        "6380",
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

    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expectEqual(@as(u16, 6380), config.port);
    try std.testing.expectEqual(PersistenceMode.both, config.persistence.mode);
    try std.testing.expectEqualStrings("var/redz", config.persistence.data_dir);
    try std.testing.expectEqualStrings("snapshot.rdb", config.persistence.rdb_filename);
    try std.testing.expectEqualStrings("append.aof", config.persistence.aof_filename);
    try std.testing.expectEqual(@as(u32, 120), config.persistence.snapshot_interval_seconds);
    try std.testing.expectEqual(AofFsyncMode.always, config.persistence.aof_fsync);
    try std.testing.expect(config.persistence.rdbEnabled());
    try std.testing.expect(config.persistence.aofEnabled());
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
    try std.testing.expectError(
        error.InvalidAofFsync,
        parseFromArgv(std.testing.allocator, &[_][]const u8{ "redz", "--aof-fsync", "sometimes" }),
    );
    try std.testing.expectError(
        error.InvalidPort,
        parseFromArgv(std.testing.allocator, &[_][]const u8{ "redz", "--port", "notaport" }),
    );
}

test "parseAofFsyncMode accepts supported modes" {
    try std.testing.expectEqual(AofFsyncMode.always, parseAofFsyncMode("always").?);
    try std.testing.expectEqual(AofFsyncMode.everysec, parseAofFsyncMode("everysec").?);
    try std.testing.expectEqual(AofFsyncMode.no, parseAofFsyncMode("no").?);
    try std.testing.expectEqual(@as(?AofFsyncMode, null), parseAofFsyncMode("weekly"));
}
