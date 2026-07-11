const std = @import("std");
const StoreMod = @import("store.zig");

const RDB_MAGIC: *const [4]u8 = "REDZ";
const RDB_VERSION: u32 = 1;
const EXPIRES_NONE: i64 = -1;

pub fn saveRdb(store: *StoreMod.Store, writer: anytype) !void {
    try writer.writeAll(RDB_MAGIC);
    try writer.writeInt(u32, RDB_VERSION, .little);
    const entry_count = store.map.count();
    try writer.writeInt(u32, @intCast(entry_count), .little);

    var it = store.map.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const entry = kv.value_ptr.*;

        try writer.writeInt(u32, @intCast(key.len), .little);
        try writer.writeAll(key);

        const exp: i64 = entry.expires_at orelse EXPIRES_NONE;
        try writer.writeInt(i64, exp, .little);

        switch (entry.value) {
            .string => |s| {
                try writer.writeInt(u8, 0, .little); // type string
                try writer.writeInt(u32, @intCast(s.len), .little);
                try writer.writeAll(s);
            },
            .list => |*list| {
                try writer.writeInt(u8, 1, .little); // type list
                try writer.writeInt(u32, @intCast(list.items.items.len), .little);
                for (list.items.items) |item| {
                    try writer.writeInt(u32, @intCast(item.len), .little);
                    try writer.writeAll(item);
                }
            },
            .set => |*set_val| {
                try writer.writeInt(u8, 2, .little); // type set
                const set_count = set_val.items.count();
                try writer.writeInt(u32, @intCast(set_count), .little);
                var kit = set_val.items.keyIterator();
                while (kit.next()) |k| {
                    const m = k.*;
                    try writer.writeInt(u32, @intCast(m.len), .little);
                    try writer.writeAll(m);
                }
            },
            .hash => |*hash| {
                try writer.writeInt(u8, 3, .little); // type hash
                const hash_count = hash.fields.count();
                try writer.writeInt(u32, @intCast(hash_count), .little);
                var hit = hash.fields.iterator();
                while (hit.next()) |kv_h| {
                    const f = kv_h.key_ptr.*;
                    const v = kv_h.value_ptr.*;
                    try writer.writeInt(u32, @intCast(f.len), .little);
                    try writer.writeAll(f);
                    try writer.writeInt(u32, @intCast(v.len), .little);
                    try writer.writeAll(v);
                }
            },
        }
    }
}

pub fn loadRdb(store: *StoreMod.Store, reader: anytype) !void {
    var magic: [4]u8 = undefined;
    reader.readNoEof(magic[0..]) catch return error.InvalidRdb;
    if (!std.mem.eql(u8, &magic, RDB_MAGIC)) return error.InvalidRdb;

    const version = try reader.readInt(u32, .little);
    if (version != RDB_VERSION) return error.UnsupportedRdbVersion;

    var entry_count_buf: [4]u8 = undefined;
    try reader.readNoEof(entry_count_buf[0..]);
    const entry_count = std.mem.readInt(u32, &entry_count_buf, .little);

    var entry_i: u32 = 0;
    while (entry_i < entry_count) : (entry_i += 1) {
        var key_len_buf: [4]u8 = undefined;
        try reader.readNoEof(key_len_buf[0..]);
        const key_len = std.mem.readInt(u32, &key_len_buf, .little);
        const key = try store.allocator.alloc(u8, key_len);
        errdefer store.allocator.free(key);
        reader.readNoEof(key) catch {
            store.allocator.free(key);
            return error.InvalidRdb;
        };

        var exp_buf: [8]u8 = undefined;
        reader.readNoEof(exp_buf[0..]) catch {
            store.allocator.free(key);
            return error.InvalidRdb;
        };
        const exp = std.mem.readInt(i64, &exp_buf, .little);

        const type_byte = reader.readByte() catch {
            store.allocator.free(key);
            return error.InvalidRdb;
        };

        const expires_at: ?i64 = if (exp == EXPIRES_NONE) null else exp;

        switch (type_byte) {
            0 => { // string
                var len_buf: [4]u8 = undefined;
                reader.readNoEof(len_buf[0..]) catch {
                    store.allocator.free(key);
                    return error.InvalidRdb;
                };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const value = try store.allocator.alloc(u8, len);
                errdefer store.allocator.free(value);
                reader.readNoEof(value) catch {
                    store.allocator.free(key);
                    store.allocator.free(value);
                    return error.InvalidRdb;
                };
                try store.map.put(key, .{
                    .value = .{ .string = value },
                    .expires_at = expires_at,
                });
            },
            1 => { // list
                var count_buf: [4]u8 = undefined;
                reader.readNoEof(count_buf[0..]) catch {
                    store.allocator.free(key);
                    return error.InvalidRdb;
                };
                const count = std.mem.readInt(u32, &count_buf, .little);
                var list = StoreMod.ListType{ .items = std.ArrayList([]u8).empty };
                errdefer list.items.deinit(store.allocator);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    var len_buf: [4]u8 = undefined;
                    reader.readNoEof(len_buf[0..]) catch {
                        store.allocator.free(key);
                        for (list.items.items) |item| store.allocator.free(item);
                        list.items.deinit(store.allocator);
                        return error.InvalidRdb;
                    };
                    const len = std.mem.readInt(u32, &len_buf, .little);
                    const item = try store.allocator.alloc(u8, len);
                    reader.readNoEof(item) catch {
                        store.allocator.free(key);
                        store.allocator.free(item);
                        for (list.items.items) |it| store.allocator.free(it);
                        list.items.deinit(store.allocator);
                        return error.InvalidRdb;
                    };
                    try list.items.append(store.allocator, item);
                }
                try store.map.put(key, .{
                    .value = .{ .list = list },
                    .expires_at = expires_at,
                });
            },
            2 => { // set
                var count_buf: [4]u8 = undefined;
                reader.readNoEof(count_buf[0..]) catch {
                    store.allocator.free(key);
                    return error.InvalidRdb;
                };
                const count = std.mem.readInt(u32, &count_buf, .little);
                var set = StoreMod.SetType{ .items = std.StringHashMap(void).init(store.allocator) };
                errdefer {
                    var kit = set.items.keyIterator();
                    while (kit.next()) |k| store.allocator.free(k.*);
                    set.items.deinit();
                }
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    var len_buf: [4]u8 = undefined;
                    reader.readNoEof(len_buf[0..]) catch {
                        store.allocator.free(key);
                        var kit = set.items.keyIterator();
                        while (kit.next()) |k| store.allocator.free(k.*);
                        set.items.deinit();
                        return error.InvalidRdb;
                    };
                    const len = std.mem.readInt(u32, &len_buf, .little);
                    const member = try store.allocator.alloc(u8, len);
                    reader.readNoEof(member) catch {
                        store.allocator.free(key);
                        store.allocator.free(member);
                        var kit = set.items.keyIterator();
                        while (kit.next()) |k| store.allocator.free(k.*);
                        set.items.deinit();
                        return error.InvalidRdb;
                    };
                    try set.items.put(member, {});
                }
                try store.map.put(key, .{
                    .value = .{ .set = set },
                    .expires_at = expires_at,
                });
            },
            3 => { // hash
                var count_buf: [4]u8 = undefined;
                reader.readNoEof(count_buf[0..]) catch {
                    store.allocator.free(key);
                    return error.InvalidRdb;
                };
                const count = std.mem.readInt(u32, &count_buf, .little);
                var hash = StoreMod.HashType{ .fields = std.StringHashMap([]u8).init(store.allocator) };
                errdefer {
                    var hit = hash.fields.iterator();
                    while (hit.next()) |kv_h| {
                        store.allocator.free(kv_h.key_ptr.*);
                        store.allocator.free(kv_h.value_ptr.*);
                    }
                    hash.fields.deinit();
                }
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    var flen_buf: [4]u8 = undefined;
                    reader.readNoEof(flen_buf[0..]) catch {
                        store.allocator.free(key);
                        var hit = hash.fields.iterator();
                        while (hit.next()) |kv_h| {
                            store.allocator.free(kv_h.key_ptr.*);
                            store.allocator.free(kv_h.value_ptr.*);
                        }
                        hash.fields.deinit();
                        return error.InvalidRdb;
                    };
                    const flen = std.mem.readInt(u32, &flen_buf, .little);
                    const field = try store.allocator.alloc(u8, flen);
                    reader.readNoEof(field) catch {
                        store.allocator.free(key);
                        store.allocator.free(field);
                        var hit = hash.fields.iterator();
                        while (hit.next()) |kv_h| {
                            store.allocator.free(kv_h.key_ptr.*);
                            store.allocator.free(kv_h.value_ptr.*);
                        }
                        hash.fields.deinit();
                        return error.InvalidRdb;
                    };
                    var vlen_buf: [4]u8 = undefined;
                    reader.readNoEof(vlen_buf[0..]) catch {
                        store.allocator.free(key);
                        store.allocator.free(field);
                        var hit = hash.fields.iterator();
                        while (hit.next()) |kv_h| {
                            store.allocator.free(kv_h.key_ptr.*);
                            store.allocator.free(kv_h.value_ptr.*);
                        }
                        hash.fields.deinit();
                        return error.InvalidRdb;
                    };
                    const vlen = std.mem.readInt(u32, &vlen_buf, .little);
                    const value = try store.allocator.alloc(u8, vlen);
                    reader.readNoEof(value) catch {
                        store.allocator.free(key);
                        store.allocator.free(field);
                        store.allocator.free(value);
                        var hit = hash.fields.iterator();
                        while (hit.next()) |kv_h| {
                            store.allocator.free(kv_h.key_ptr.*);
                            store.allocator.free(kv_h.value_ptr.*);
                        }
                        hash.fields.deinit();
                        return error.InvalidRdb;
                    };
                    try hash.fields.put(field, value);
                }
                try store.map.put(key, .{
                    .value = .{ .hash = hash },
                    .expires_at = expires_at,
                });
            },
            else => {
                store.allocator.free(key);
                return error.InvalidRdb;
            },
        }
    }
}

fn roundTripStore(src: *StoreMod.Store, dst: *StoreMod.Store) !void {
    var buf: [4096]u8 = undefined;
    var out = std.io.fixedBufferStream(&buf);
    try saveRdb(src, out.writer());

    var in = std.io.fixedBufferStream(out.getWritten());
    try loadRdb(dst, in.reader());
}

fn expectEntry(store: *StoreMod.Store, key: []const u8, expires_at: ?i64) !*StoreMod.Entry {
    const entry = store.map.getPtr(key) orelse return error.MissingEntry;
    try std.testing.expectEqual(expires_at, entry.expires_at);
    return entry;
}

fn expectStringValue(store: *StoreMod.Store, key: []const u8, expected: []const u8, expires_at: ?i64) !void {
    const entry = try expectEntry(store, key, expires_at);
    switch (entry.value) {
        .string => |value| try std.testing.expectEqualStrings(expected, value),
        else => return error.WrongType,
    }
}

fn expectListValue(store: *StoreMod.Store, key: []const u8, expected: []const []const u8, expires_at: ?i64) !void {
    const entry = try expectEntry(store, key, expires_at);
    switch (entry.value) {
        .list => |*list| {
            try std.testing.expectEqual(expected.len, list.items.items.len);
            for (expected, list.items.items) |expected_item, actual_item| {
                try std.testing.expectEqualStrings(expected_item, actual_item);
            }
        },
        else => return error.WrongType,
    }
}

fn expectSetValue(store: *StoreMod.Store, key: []const u8, expected: []const []const u8, expires_at: ?i64) !void {
    const entry = try expectEntry(store, key, expires_at);
    switch (entry.value) {
        .set => |*set_val| {
            try std.testing.expectEqual(expected.len, set_val.items.count());
            for (expected) |member| {
                try std.testing.expect(set_val.items.contains(member));
            }
        },
        else => return error.WrongType,
    }
}

fn expectHashValue(store: *StoreMod.Store, key: []const u8, expected_pairs: []const []const u8, expires_at: ?i64) !void {
    const entry = try expectEntry(store, key, expires_at);
    switch (entry.value) {
        .hash => |*hash| {
            try std.testing.expectEqual(expected_pairs.len / 2, hash.fields.count());
            var i: usize = 0;
            while (i < expected_pairs.len) : (i += 2) {
                const actual = hash.fields.get(expected_pairs[i]) orelse return error.MissingHashField;
                try std.testing.expectEqualStrings(expected_pairs[i + 1], actual);
            }
        },
        else => return error.WrongType,
    }
}

test "rdb round-trip string values and expiry sentinels" {
    var src = try StoreMod.Store.init(std.testing.allocator);
    defer src.deinit();
    var dst = try StoreMod.Store.init(std.testing.allocator);
    defer dst.deinit();

    try src.set("plain", "persisted");
    try src.set("volatile", "expires");
    src.map.getPtr("plain").?.expires_at = null;
    src.map.getPtr("volatile").?.expires_at = 1_700_000_123;

    try roundTripStore(&src, &dst);

    try std.testing.expectEqual(@as(usize, 2), dst.map.count());
    try expectStringValue(&dst, "plain", "persisted", null);
    try expectStringValue(&dst, "volatile", "expires", 1_700_000_123);
}

test "rdb round-trip list values" {
    var src = try StoreMod.Store.init(std.testing.allocator);
    defer src.deinit();
    var dst = try StoreMod.Store.init(std.testing.allocator);
    defer dst.deinit();

    const values = [_][]const u8{ "one", "two", "three" };
    _ = try src.listPushTail("numbers", &values);
    src.map.getPtr("numbers").?.expires_at = 1_700_000_456;

    try roundTripStore(&src, &dst);

    try expectListValue(&dst, "numbers", &values, 1_700_000_456);
}

test "rdb round-trip set values" {
    var src = try StoreMod.Store.init(std.testing.allocator);
    defer src.deinit();
    var dst = try StoreMod.Store.init(std.testing.allocator);
    defer dst.deinit();

    const members = [_][]const u8{ "alpha", "beta", "gamma" };
    _ = try src.setAdd("letters", &members);
    src.map.getPtr("letters").?.expires_at = null;

    try roundTripStore(&src, &dst);

    try expectSetValue(&dst, "letters", &members, null);
}

test "rdb round-trip hash values" {
    var src = try StoreMod.Store.init(std.testing.allocator);
    defer src.deinit();
    var dst = try StoreMod.Store.init(std.testing.allocator);
    defer dst.deinit();

    const pairs = [_][]const u8{ "field-a", "value-a", "field-b", "value-b" };
    _ = try src.hashSet("record", &pairs);
    src.map.getPtr("record").?.expires_at = 1_700_000_789;

    try roundTripStore(&src, &dst);

    try expectHashValue(&dst, "record", &pairs, 1_700_000_789);
}

test "rdb rejects invalid magic" {
    var store = try StoreMod.Store.init(std.testing.allocator);
    defer store.deinit();

    var input = std.io.fixedBufferStream("NOPE");
    try std.testing.expectError(error.InvalidRdb, loadRdb(&store, input.reader()));
}

test "rdb rejects unsupported version" {
    var store = try StoreMod.Store.init(std.testing.allocator);
    defer store.deinit();

    var bytes: [8]u8 = undefined;
    var out = std.io.fixedBufferStream(&bytes);
    try out.writer().writeAll(RDB_MAGIC);
    try out.writer().writeInt(u32, RDB_VERSION + 1, .little);

    var input = std.io.fixedBufferStream(out.getWritten());
    try std.testing.expectError(error.UnsupportedRdbVersion, loadRdb(&store, input.reader()));
}
