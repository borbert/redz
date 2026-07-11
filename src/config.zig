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

pub fn parseFromArgs(allocator: std.mem.Allocator) !PersistenceConfig {
    var config = PersistenceConfig{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--persistence")) {
            const value = args.next() orelse return error.MissingPersistenceValue;
            config.mode = parsePersistenceMode(value) orelse return error.InvalidPersistenceMode;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            const value = args.next() orelse return error.MissingDataDirValue;
            config.data_dir = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--rdb-filename")) {
            const value = args.next() orelse return error.MissingRdbFilenameValue;
            config.rdb_filename = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--aof-filename")) {
            const value = args.next() orelse return error.MissingAofFilenameValue;
            config.aof_filename = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--snapshot-interval")) {
            const value = args.next() orelse return error.MissingSnapshotIntervalValue;
            config.snapshot_interval_seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidSnapshotInterval;
        } else if (std.mem.eql(u8, arg, "--aof-fsync")) {
            const value = args.next() orelse return error.MissingAofFsyncValue;
            config.aof_fsync = parseAofFsyncMode(value) orelse return error.InvalidAofFsync;
        }
    }
    return config;
}
