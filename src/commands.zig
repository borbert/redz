const std = @import("std");
const StoreMod = @import("store.zig");
const resp = @import("resp.zig");
const config_mod = @import("config.zig");
const persistence = @import("persistence.zig");

pub const CommandContext = struct {
    store: *StoreMod.Store,
    allocator: ?std.mem.Allocator = null,
    persistence_config: ?*const config_mod.PersistenceConfig = null,
    persistence_runtime: ?*persistence.PersistenceRuntime = null,
};

pub fn isMutatingCommand(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "SET") or
        std.ascii.eqlIgnoreCase(name, "DEL") or
        std.ascii.eqlIgnoreCase(name, "EXPIRE") or
        std.ascii.eqlIgnoreCase(name, "PERSIST") or
        std.ascii.eqlIgnoreCase(name, "LPUSH") or
        std.ascii.eqlIgnoreCase(name, "RPUSH") or
        std.ascii.eqlIgnoreCase(name, "LPOP") or
        std.ascii.eqlIgnoreCase(name, "RPOP") or
        std.ascii.eqlIgnoreCase(name, "SADD") or
        std.ascii.eqlIgnoreCase(name, "SREM") or
        std.ascii.eqlIgnoreCase(name, "HSET") or
        std.ascii.eqlIgnoreCase(name, "HDEL");
}

pub fn dispatch(ctx: *CommandContext, name: []const u8, args: []const []const u8, writer: anytype) !void {
    if (std.ascii.eqlIgnoreCase(name, "PING")) return handlePing(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "ECHO")) return handleEcho(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "SET")) return handleSet(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "GET")) return handleGet(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "DEL")) return handleDel(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "EXISTS")) return handleExists(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "EXPIRE")) return handleExpire(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "TTL")) return handleTtl(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "PERSIST")) return handlePersist(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "SAVE")) return handleSave(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "LASTSAVE")) return handleLastSave(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "LPUSH")) return handleLpush(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "RPUSH")) return handleRpush(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "LPOP")) return handleLpop(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "RPOP")) return handleRpop(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "LRANGE")) return handleLrange(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "SADD")) return handleSadd(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "SREM")) return handleSrem(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "SMEMBERS")) return handleSmembers(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "SISMEMBER")) return handleSismember(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "HSET")) return handleHset(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "HGET")) return handleHget(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "HDEL")) return handleHdel(ctx, args, writer);
    if (std.ascii.eqlIgnoreCase(name, "HGETALL")) return handleHgetall(ctx, args, writer);
    return error.UnknownCommand;
}

fn handlePing(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    _ = ctx;
    const msg = if (args.len > 0) args[0] else "PONG";
    try resp.writeSimpleString(writer, msg);
}

fn handleEcho(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    _ = ctx;
    if (args.len != 1) return error.WrongArity;
    try resp.writeBulkString(writer, args[0]);
}

fn handleSet(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 2) return error.WrongArity;
    try ctx.store.set(args[0], args[1]);
    try resp.writeSimpleString(writer, "OK");
}

fn handleGet(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const value = ctx.store.get(args[0]);
    try resp.writeBulkString(writer, value);
}

fn handleDel(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 1) return error.WrongArity;
    const n = ctx.store.del(args);
    try resp.writeInteger(writer, @as(i64, @intCast(n)));
}

fn handleExists(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 1) return error.WrongArity;
    const n = ctx.store.exists(args);
    try resp.writeInteger(writer, @as(i64, @intCast(n)));
}

fn handleExpire(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 2) return error.WrongArity;
    const seconds = std.fmt.parseInt(i64, args[1], 10) catch return error.InvalidInteger;
    const ok = ctx.store.expire(args[0], seconds);
    try resp.writeInteger(writer, if (ok) 1 else 0);
}

fn handleTtl(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const t = ctx.store.ttl(args[0]);
    try resp.writeInteger(writer, t);
}

fn handlePersist(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const ok = ctx.store.persist(args[0]);
    try resp.writeInteger(writer, if (ok) 1 else 0);
}

fn handleSave(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 0) return error.WrongArity;

    const config = ctx.persistence_config orelse {
        try resp.writeError(writer, "ERR RDB persistence is disabled");
        return;
    };
    if (!config.rdbEnabled()) {
        try resp.writeError(writer, "ERR RDB persistence is disabled");
        return;
    }

    const allocator = ctx.allocator orelse return error.PersistenceNotConfigured;
    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);

    try persistence.saveRdbAtomic(allocator, rdb_path, ctx.store);
    if (ctx.persistence_runtime) |runtime| {
        runtime.last_save_unix = std.time.timestamp();
    }
    try resp.writeSimpleString(writer, "OK");
}

fn handleLastSave(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 0) return error.WrongArity;
    const ts: i64 = if (ctx.persistence_runtime) |runtime| runtime.last_save_unix else 0;
    try resp.writeInteger(writer, ts);
}

fn handleLpush(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 2) return error.WrongArity;
    const len = try ctx.store.listPushHead(args[0], args[1..]);
    try resp.writeInteger(writer, @as(i64, @intCast(len)));
}

fn handleRpush(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 2) return error.WrongArity;
    const len = try ctx.store.listPushTail(args[0], args[1..]);
    try resp.writeInteger(writer, @as(i64, @intCast(len)));
}

fn handleLpop(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const val = ctx.store.listPopHead(args[0]);
    if (val) |v| {
        defer ctx.store.allocator.free(v);
        try resp.writeBulkString(writer, v);
    } else {
        try resp.writeBulkString(writer, null);
    }
}

fn handleRpop(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const val = ctx.store.listPopTail(args[0]);
    if (val) |v| {
        defer ctx.store.allocator.free(v);
        try resp.writeBulkString(writer, v);
    } else {
        try resp.writeBulkString(writer, null);
    }
}

fn handleLrange(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 3) return error.WrongArity;
    const start = std.fmt.parseInt(isize, args[1], 10) catch return error.InvalidInteger;
    const stop = std.fmt.parseInt(isize, args[2], 10) catch return error.InvalidInteger;
    const items = ctx.store.listRange(args[0], start, stop);
    try resp.writeArray(writer, items);
}

fn handleSadd(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 2) return error.WrongArity;
    const n = try ctx.store.setAdd(args[0], args[1..]);
    try resp.writeInteger(writer, @as(i64, @intCast(n)));
}

fn handleSrem(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 2) return error.WrongArity;
    const n = ctx.store.setRemove(args[0], args[1..]);
    try resp.writeInteger(writer, @as(i64, @intCast(n)));
}

fn handleSmembers(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const members = try ctx.store.setMembers(args[0]);
    defer ctx.store.allocator.free(members);
    try resp.writeArray(writer, members);
}

fn handleSismember(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 2) return error.WrongArity;
    const n: i64 = if (ctx.store.setIsMember(args[0], args[1])) 1 else 0;
    try resp.writeInteger(writer, n);
}

fn handleHset(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 3 or args.len % 2 == 0) return error.WrongArity;
    const n = try ctx.store.hashSet(args[0], args[1..]);
    try resp.writeInteger(writer, @as(i64, @intCast(n)));
}

fn handleHget(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 2) return error.WrongArity;
    const value = ctx.store.hashGet(args[0], args[1]);
    try resp.writeBulkString(writer, value);
}

fn handleHdel(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len < 2) return error.WrongArity;
    const n = ctx.store.hashDel(args[0], args[1..]);
    try resp.writeInteger(writer, @as(i64, @intCast(n)));
}

fn handleHgetall(ctx: *CommandContext, args: []const []const u8, writer: anytype) !void {
    if (args.len != 1) return error.WrongArity;
    const pairs = try ctx.store.hashGetAll(args[0]);
    defer ctx.store.allocator.free(pairs);
    try resp.writeArray(writer, pairs);
}

test "commands handlers RESP output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try StoreMod.Store.init(gpa.allocator());
    defer store.deinit();

    var ctx = CommandContext{ .store = &store };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const empty: []const []const u8 = &[_][]const u8{};
    try dispatch(&ctx, "PING", empty, fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "+PONG\r\n"));

    fbs.reset();
    const echo_args = [_][]const u8{"hello"};
    try dispatch(&ctx, "ECHO", echo_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "$5\r\nhello\r\n"));

    fbs.reset();
    const set_args = [_][]const u8{ "k", "v" };
    try dispatch(&ctx, "SET", set_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "+OK\r\n"));

    fbs.reset();
    const get_args = [_][]const u8{"k"};
    try dispatch(&ctx, "GET", get_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "$1\r\nv\r\n"));

    fbs.reset();
    const get_none = [_][]const u8{"nonexistent"};
    try dispatch(&ctx, "GET", get_none[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "$-1\r\n"));

    fbs.reset();
    const del_args = [_][]const u8{"k"};
    try dispatch(&ctx, "DEL", del_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":1\r\n"));

    fbs.reset();
    const exists_args = [_][]const u8{ "a", "b" };
    try dispatch(&ctx, "EXISTS", exists_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":0\r\n"));

    try store.set("x", "y");
    fbs.reset();
    const expire_args = [_][]const u8{ "x", "10" };
    try dispatch(&ctx, "EXPIRE", expire_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":1\r\n"));

    fbs.reset();
    const ttl_args = [_][]const u8{"x"};
    try dispatch(&ctx, "TTL", ttl_args[0..], fbs.writer());
    const ttl_out = fbs.getWritten();
    try std.testing.expect(ttl_out[0] == ':');
    try std.testing.expect(ttl_out[ttl_out.len - 2] == '\r' and ttl_out[ttl_out.len - 1] == '\n');

    fbs.reset();
    const persist_args = [_][]const u8{"x"};
    try dispatch(&ctx, "PERSIST", persist_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":1\r\n"));

    // Phase 2: list/set/hash
    fbs.reset();
    const rpush_args = [_][]const u8{ "q", "1", "2", "3" };
    try dispatch(&ctx, "RPUSH", rpush_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":3\r\n"));

    fbs.reset();
    const lrange_args = [_][]const u8{ "q", "0", "-1" };
    try dispatch(&ctx, "LRANGE", lrange_args[0..], fbs.writer());
    try std.testing.expect(std.mem.startsWith(u8, fbs.getWritten(), "*3\r\n"));

    fbs.reset();
    const sadd_args = [_][]const u8{ "s", "a", "b", "c" };
    try dispatch(&ctx, "SADD", sadd_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":3\r\n"));

    fbs.reset();
    const hset_args = [_][]const u8{ "h", "f1", "v1", "f2", "v2" };
    try dispatch(&ctx, "HSET", hset_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":2\r\n"));

    fbs.reset();
    const hget_args = [_][]const u8{ "h", "f1" };
    try dispatch(&ctx, "HGET", hget_args[0..], fbs.writer());
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "$2\r\nv1\r\n"));

    // WRONGTYPE: SET x then RPUSH x bar
    try store.set("bad", "string");
    fbs.reset();
    const rpush_wrong = [_][]const u8{ "bad", "bar" };
    try std.testing.expectError(error.WrongType, dispatch(&ctx, "RPUSH", rpush_wrong[0..], fbs.writer()));
}

test "save command returns error when rdb disabled" {
    var store = try StoreMod.Store.init(std.testing.allocator);
    defer store.deinit();

    var config = config_mod.PersistenceConfig{};
    var ctx = CommandContext{
        .store = &store,
        .allocator = std.testing.allocator,
        .persistence_config = &config,
    };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const args = [_][]const u8{};
    try dispatch(&ctx, "SAVE", args[0..], fbs.writer());

    try std.testing.expectEqualStrings("-ERR RDB persistence is disabled\r\n", fbs.getWritten());
}

test "save command atomically writes rdb and updates last save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    defer allocator.free(data_dir);

    var store = try StoreMod.Store.init(allocator);
    defer store.deinit();
    try store.set("saved", "value");

    var config = config_mod.PersistenceConfig{
        .mode = .rdb,
        .data_dir = data_dir,
        .rdb_filename = "save-command.redz",
    };
    var runtime = persistence.PersistenceRuntime{};
    var ctx = CommandContext{
        .store = &store,
        .allocator = allocator,
        .persistence_config = &config,
        .persistence_runtime = &runtime,
    };

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const args = [_][]const u8{};
    try dispatch(&ctx, "SAVE", args[0..], fbs.writer());

    try std.testing.expectEqualStrings("+OK\r\n", fbs.getWritten());
    try std.testing.expect(runtime.last_save_unix > 0);

    const rdb_path = try config.rdbPath(allocator);
    defer allocator.free(rdb_path);
    var file = try std.fs.cwd().openFile(rdb_path, .{});
    defer file.close();

    var loaded = try StoreMod.Store.init(allocator);
    defer loaded.deinit();
    try persistence.loadRdb(&loaded, file.deprecatedReader());
    const value = loaded.get("saved") orelse return error.MissingSavedValue;
    try std.testing.expectEqualStrings("value", value);
}

test "lastsave returns zero then updated timestamp" {
    var store = try StoreMod.Store.init(std.testing.allocator);
    defer store.deinit();

    var runtime = persistence.PersistenceRuntime{};
    var ctx = CommandContext{
        .store = &store,
        .persistence_runtime = &runtime,
    };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const args = [_][]const u8{};
    try dispatch(&ctx, "LASTSAVE", args[0..], fbs.writer());
    try std.testing.expectEqualStrings(":0\r\n", fbs.getWritten());

    runtime.last_save_unix = 1_700_000_000;
    fbs.reset();
    try dispatch(&ctx, "LASTSAVE", args[0..], fbs.writer());
    try std.testing.expectEqualStrings(":1700000000\r\n", fbs.getWritten());
}

test "both mode rdb baseline plus aof delta and mutating classification" {
    const allocator = std.testing.allocator;
    var baseline = try StoreMod.Store.init(allocator);
    defer baseline.deinit();
    var loaded = try StoreMod.Store.init(allocator);
    defer loaded.deinit();

    try baseline.set("base", "from-rdb");
    var rdb_buf: [1024]u8 = undefined;
    var out = std.io.fixedBufferStream(&rdb_buf);
    try persistence.saveRdb(&baseline, out.writer());

    var input = std.io.fixedBufferStream(out.getWritten());
    try persistence.loadRdb(&loaded, input.reader());

    const aof = @import("aof.zig");
    try aof.replayAofBytes(
        allocator,
        &loaded,
        "*3\r\n$3\r\nSET\r\n$5\r\ndelta\r\n$3\r\naof\r\n",
    );

    try std.testing.expectEqualStrings("from-rdb", loaded.get("base").?);
    try std.testing.expectEqualStrings("aof", loaded.get("delta").?);
    try std.testing.expect(isMutatingCommand("SET"));
    try std.testing.expect(isMutatingCommand("HDEL"));
    try std.testing.expect(!isMutatingCommand("GET"));
    try std.testing.expect(!isMutatingCommand("LASTSAVE"));
    try std.testing.expect(!isMutatingCommand("SAVE"));
}
