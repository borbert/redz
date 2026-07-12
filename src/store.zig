const std = @import("std");

pub const Value = union(enum) {
    string: []u8,
    list: ListType,
    set: SetType,
    hash: HashType,
};

pub const ListType = struct {
    items: std.ArrayList([]u8),
};

pub const SetType = struct {
    items: std.StringHashMap(void),
};

pub const HashType = struct {
    fields: std.StringHashMap([]u8),
};

pub const Entry = struct {
    value: Value,
    expires_at: ?i64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator) !Store {
        return Store{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
        };
    }

    fn freeEntryValue(self: *Store, value: *Value) void {
        switch (value.*) {
            .string => |s| self.allocator.free(s),
            .list => |*list| {
                for (list.items.items) |item| self.allocator.free(item);
                list.items.deinit(self.allocator);
            },
            .set => |*set_val| {
                var it = set_val.items.keyIterator();
                while (it.next()) |k| self.allocator.free(k.*);
                set_val.items.deinit();
            },
            .hash => |*hash| {
                var it = hash.fields.iterator();
                while (it.next()) |kv| {
                    self.allocator.free(kv.key_ptr.*);
                    self.allocator.free(kv.value_ptr.*);
                }
                hash.fields.deinit();
            },
        }
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.freeEntryValue(&kv.value_ptr.*.value);
        }
        self.map.deinit();
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            self.freeEntryValue(&gop.value_ptr.*.value);
            gop.value_ptr.*.value = .{ .string = try self.allocator.dupe(u8, value) };
            gop.value_ptr.*.expires_at = null;
            return;
        }
        gop.key_ptr.* = try self.allocator.dupe(u8, key);
        gop.value_ptr.* = .{
            .value = .{ .string = try self.allocator.dupe(u8, value) },
            .expires_at = null,
        };
    }

    pub fn get(self: *Store, key: []const u8) ?[]const u8 {
        const entry = self.map.getPtr(key) orelse return null;
        const now = std.time.timestamp();
        if (self.isExpired(now, entry)) {
            _ = self.removeIfExpired(now, key);
            return null;
        }
        return switch (entry.value) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn del(self: *Store, keys: []const []const u8) usize {
        const now = std.time.timestamp();
        var removed: usize = 0;
        for (keys) |key| {
            if (self.removeIfExpired(now, key)) removed += 1 else if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.freeEntryValue(@constCast(&kv.value.value));
                removed += 1;
            }
        }
        return removed;
    }

    pub fn exists(self: *Store, keys: []const []const u8) usize {
        const now = std.time.timestamp();
        var count: usize = 0;
        for (keys) |key| {
            const entry = self.map.getPtr(key) orelse continue;
            if (self.isExpired(now, entry)) {
                _ = self.removeIfExpired(now, key);
            } else {
                count += 1;
            }
        }
        return count;
    }

    pub fn expire(self: *Store, key: []const u8, seconds: i64) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (self.isExpired(std.time.timestamp(), entry)) {
            _ = self.removeIfExpired(std.time.timestamp(), key);
            return false;
        }
        const now = std.time.timestamp();
        entry.expires_at = now + seconds;
        return true;
    }

    pub fn ttl(self: *Store, key: []const u8) i64 {
        const entry = self.map.getPtr(key) orelse return -2;
        if (entry.expires_at) |exp| {
            const now = std.time.timestamp();
            if (now >= exp) return -2;
            return @as(i64, @intCast(exp - now));
        }
        return -1;
    }

    pub fn persist(self: *Store, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (self.isExpired(std.time.timestamp(), entry)) {
            _ = self.removeIfExpired(std.time.timestamp(), key);
            return false;
        }
        entry.expires_at = null;
        return true;
    }

    pub fn isExpired(self: *const Store, now: i64, entry: *const Entry) bool {
        _ = self;
        const exp = entry.expires_at orelse return false;
        return now >= exp;
    }

    pub fn removeIfExpired(self: *Store, now: i64, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (!self.isExpired(now, entry)) return false;
        const kv = self.map.fetchRemove(key).?;
        self.allocator.free(kv.key);
        self.freeEntryValue(@constCast(&kv.value.value));
        return true;
    }

    // --- List helpers ---

    pub const GetListResult = union(enum) {
        missing,
        wrong_type,
        list: *ListType,
    };

    pub fn getList(self: *Store, key: []const u8) GetListResult {
        const entry = self.map.getPtr(key) orelse return .missing;
        if (self.isExpired(std.time.timestamp(), entry)) {
            _ = self.removeIfExpired(std.time.timestamp(), key);
            return .missing;
        }
        return switch (entry.value) {
            .list => |*list| .{ .list = list },
            else => .wrong_type,
        };
    }

    pub fn getOrCreateList(self: *Store, key: []const u8) !*ListType {
        const entry = self.map.getPtr(key);
        if (entry) |e| {
            if (self.isExpired(std.time.timestamp(), e)) {
                _ = self.removeIfExpired(std.time.timestamp(), key);
            } else {
                return switch (e.*.value) {
                    .list => |*list| list,
                    else => error.WrongType,
                };
            }
        }
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        var list = ListType{ .items = std.ArrayList([]u8).empty };
        errdefer list.items.deinit(self.allocator);
        try self.map.put(k, .{ .value = .{ .list = list }, .expires_at = null });
        return &self.map.getPtr(key).?.*.value.list;
    }

    pub fn listPushHead(self: *Store, key: []const u8, values: []const []const u8) !usize {
        const list_ptr = try self.getOrCreateList(key);
        var i = values.len;
        while (i > 0) {
            i -= 1;
            try list_ptr.items.insert(self.allocator, 0, try self.allocator.dupe(u8, values[i]));
        }
        return list_ptr.items.items.len;
    }

    pub fn listPushTail(self: *Store, key: []const u8, values: []const []const u8) !usize {
        const list_ptr = try self.getOrCreateList(key);
        for (values) |v| {
            try list_ptr.items.append(self.allocator, try self.allocator.dupe(u8, v));
        }
        return list_ptr.items.items.len;
    }

    pub fn listPopHead(self: *Store, key: []const u8) ?[]const u8 {
        const res = self.getList(key);
        return switch (res) {
            .missing, .wrong_type => null,
            .list => |list_ptr| blk: {
                if (list_ptr.items.items.len == 0) break :blk null;
                const item = list_ptr.items.orderedRemove(0);
                break :blk item;
            },
        };
    }

    pub fn listPopTail(self: *Store, key: []const u8) ?[]const u8 {
        const res = self.getList(key);
        return switch (res) {
            .missing, .wrong_type => null,
            .list => |list_ptr| blk: {
                if (list_ptr.items.items.len == 0) break :blk null;
                break :blk list_ptr.items.pop();
            },
        };
    }

    pub fn listRange(self: *Store, key: []const u8, start: isize, stop: isize) []const []const u8 {
        const res = self.getList(key);
        return switch (res) {
            .missing, .wrong_type => &[_][]const u8{},
            .list => |list_ptr| blk: {
                const len: isize = @intCast(list_ptr.items.items.len);
                var s = start;
                var e = stop;
                if (s < 0) s += len;
                if (e < 0) e += len;
                if (s < 0) s = 0;
                if (e >= len) e = len - 1;
                if (s > e) break :blk &[_][]const u8{};
                const start_u: usize = @intCast(s);
                const end_u: usize = @intCast(e);
                break :blk list_ptr.items.items[start_u .. end_u + 1];
            },
        };
    }

    // --- Set helpers ---

    pub const GetSetResult = union(enum) {
        missing,
        wrong_type,
        set: *SetType,
    };

    pub fn getSet(self: *Store, key: []const u8) GetSetResult {
        const entry = self.map.getPtr(key) orelse return .missing;
        if (self.isExpired(std.time.timestamp(), entry)) {
            _ = self.removeIfExpired(std.time.timestamp(), key);
            return .missing;
        }
        return switch (entry.value) {
            .set => |*set_val| .{ .set = set_val },
            else => .wrong_type,
        };
    }

    pub fn getOrCreateSet(self: *Store, key: []const u8) !*SetType {
        const entry = self.map.getPtr(key);
        if (entry) |e| {
            if (self.isExpired(std.time.timestamp(), e)) {
                _ = self.removeIfExpired(std.time.timestamp(), key);
            } else {
                return switch (e.*.value) {
                    .set => |*set_val| set_val,
                    else => error.WrongType,
                };
            }
        }
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        try self.map.put(k, .{ .value = .{ .set = SetType{ .items = std.StringHashMap(void).init(self.allocator) } }, .expires_at = null });
        return &self.map.getPtr(key).?.*.value.set;
    }

    pub fn setAdd(self: *Store, key: []const u8, members: []const []const u8) !usize {
        const set_ptr = try self.getOrCreateSet(key);
        var added: usize = 0;
        for (members) |m| {
            const dup = try self.allocator.dupe(u8, m);
            const gop = try set_ptr.items.getOrPut(dup);
            if (!gop.found_existing) added += 1 else self.allocator.free(dup);
        }
        return added;
    }

    pub fn setRemove(self: *Store, key: []const u8, members: []const []const u8) usize {
        const res = self.getSet(key);
        return switch (res) {
            .missing, .wrong_type => 0,
            .set => |set_ptr| blk: {
                var removed: usize = 0;
                for (members) |m| {
                    if (set_ptr.items.fetchRemove(m)) |kv| {
                        self.allocator.free(kv.key);
                        removed += 1;
                    }
                }
                break :blk removed;
            },
        };
    }

    pub fn setMembers(self: *Store, key: []const u8) ![]const []const u8 {
        const res = self.getSet(key);
        return switch (res) {
            .missing, .wrong_type => self.allocator.alloc([]const u8, 0),
            .set => |set_ptr| blk: {
                var list = std.ArrayList([]const u8).empty;
                var it = set_ptr.items.keyIterator();
                while (it.next()) |k| try list.append(self.allocator, k.*);
                break :blk list.toOwnedSlice(self.allocator);
            },
        };
    }

    pub fn setIsMember(self: *Store, key: []const u8, member: []const u8) bool {
        const res = self.getSet(key);
        return switch (res) {
            .missing, .wrong_type => false,
            .set => |set_ptr| set_ptr.items.contains(member),
        };
    }

    // --- Hash helpers ---

    pub const GetHashResult = union(enum) {
        missing,
        wrong_type,
        hash: *HashType,
    };

    pub fn getHash(self: *Store, key: []const u8) GetHashResult {
        const entry = self.map.getPtr(key) orelse return .missing;
        if (self.isExpired(std.time.timestamp(), entry)) {
            _ = self.removeIfExpired(std.time.timestamp(), key);
            return .missing;
        }
        return switch (entry.value) {
            .hash => |*hash| .{ .hash = hash },
            else => .wrong_type,
        };
    }

    pub fn getOrCreateHash(self: *Store, key: []const u8) !*HashType {
        const entry = self.map.getPtr(key);
        if (entry) |e| {
            if (self.isExpired(std.time.timestamp(), e)) {
                _ = self.removeIfExpired(std.time.timestamp(), key);
            } else {
                return switch (e.*.value) {
                    .hash => |*hash| hash,
                    else => error.WrongType,
                };
            }
        }
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        try self.map.put(k, .{ .value = .{ .hash = HashType{ .fields = std.StringHashMap([]u8).init(self.allocator) } }, .expires_at = null });
        return &self.map.getPtr(key).?.*.value.hash;
    }

    pub fn hashSet(self: *Store, key: []const u8, pairs: []const []const u8) !usize {
        if (pairs.len % 2 != 0) return error.InvalidHashPairs;
        const hash_ptr = try self.getOrCreateHash(key);
        var new_count: usize = 0;
        var i: usize = 0;
        while (i < pairs.len) : (i += 2) {
            const field = pairs[i];
            const val = pairs[i + 1];
            const gop = try hash_ptr.fields.getOrPut(field);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, field);
                new_count += 1;
            }
            gop.value_ptr.* = try self.allocator.dupe(u8, val);
        }
        return new_count;
    }

    pub fn hashGet(self: *Store, key: []const u8, field: []const u8) ?[]const u8 {
        const res = self.getHash(key);
        return switch (res) {
            .missing, .wrong_type => null,
            .hash => |hash_ptr| hash_ptr.fields.get(field),
        };
    }

    pub fn hashDel(self: *Store, key: []const u8, fields: []const []const u8) usize {
        const res = self.getHash(key);
        return switch (res) {
            .missing, .wrong_type => 0,
            .hash => |hash_ptr| blk: {
                var removed: usize = 0;
                for (fields) |f| {
                    if (hash_ptr.fields.fetchRemove(f)) |kv| {
                        self.allocator.free(kv.key);
                        self.allocator.free(kv.value);
                        removed += 1;
                    }
                }
                break :blk removed;
            },
        };
    }

    pub fn hashGetAll(self: *Store, key: []const u8) ![]const []const u8 {
        const res = self.getHash(key);
        return switch (res) {
            .missing, .wrong_type => self.allocator.alloc([]const u8, 0),
            .hash => |hash_ptr| blk: {
                const n = hash_ptr.fields.count();
                const out = try self.allocator.alloc([]const u8, n * 2);
                var i: usize = 0;
                var it = hash_ptr.fields.iterator();
                while (it.next()) |kv| : (i += 2) {
                    out[i] = kv.key_ptr.*;
                    out[i + 1] = kv.value_ptr.*;
                }
                break :blk out;
            },
        };
    }
};

test "store set get del exists" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try Store.init(gpa.allocator());
    defer store.deinit();

    try store.set("foo", "bar");
    try std.testing.expectEqualStrings(store.get("foo").?, "bar");

    try store.set("foo", "baz");
    try std.testing.expectEqualStrings(store.get("foo").?, "baz");

    try store.set("a", "1");
    try std.testing.expect(store.exists(&[_][]const u8{ "foo", "a" }) == 2);

    const n = store.del(&[_][]const u8{"foo"});
    try std.testing.expect(n == 1);
    try std.testing.expect(store.get("foo") == null);
    try std.testing.expect(store.exists(&[_][]const u8{"a"}) == 1);

    _ = store.del(&[_][]const u8{"a"});
    try std.testing.expect(store.get("a") == null);
}

test "store TTL expire persist" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try Store.init(gpa.allocator());
    defer store.deinit();

    try store.set("k", "v");
    try std.testing.expect(store.ttl("k") == -1);
    try std.testing.expect(store.expire("k", 10));
    try std.testing.expect(store.ttl("k") >= 9 and store.ttl("k") <= 10);
    try std.testing.expect(store.persist("k"));
    try std.testing.expect(store.ttl("k") == -1);
    try std.testing.expect(store.get("k") != null);

    try std.testing.expect(!store.expire("nonexistent", 1));
    try std.testing.expect(store.ttl("nonexistent") == -2);
}

test "store list listPush listPop listRange" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try Store.init(gpa.allocator());
    defer store.deinit();

    const n1 = try store.listPushTail("q", &[_][]const u8{ "1", "2", "3" });
    try std.testing.expect(n1 == 3);
    const r = store.listRange("q", 0, -1);
    try std.testing.expect(r.len == 3);
    try std.testing.expectEqualStrings(r[0], "1");
    try std.testing.expectEqualStrings(r[1], "2");
    try std.testing.expectEqualStrings(r[2], "3");

    const pop1 = store.listPopHead("q").?;
    defer store.allocator.free(pop1);
    try std.testing.expectEqualStrings(pop1, "1");
    const pop2 = store.listPopTail("q").?;
    defer store.allocator.free(pop2);
    try std.testing.expectEqualStrings(pop2, "3");
    try std.testing.expect(store.listRange("q", 0, -1).len == 1);
}

test "store set setAdd setRemove setMembers setIsMember" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try Store.init(gpa.allocator());
    defer store.deinit();

    const added = try store.setAdd("s", &[_][]const u8{ "a", "b", "c" });
    try std.testing.expect(added == 3);
    try std.testing.expect(store.setIsMember("s", "a"));
    try std.testing.expect(!store.setIsMember("s", "z"));
    const rem = store.setRemove("s", &[_][]const u8{"b"});
    try std.testing.expect(rem == 1);
    const members = try store.setMembers("s");
    defer store.allocator.free(members);
    try std.testing.expect(members.len == 2);
}

test "store hash hashSet hashGet hashDel hashGetAll" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try Store.init(gpa.allocator());
    defer store.deinit();

    const new_count = try store.hashSet("h", &[_][]const u8{ "f1", "v1", "f2", "v2" });
    try std.testing.expect(new_count == 2);
    try std.testing.expectEqualStrings(store.hashGet("h", "f1").?, "v1");
    const del_count = store.hashDel("h", &[_][]const u8{"f1"});
    try std.testing.expect(del_count == 1);
    try std.testing.expect(store.hashGet("h", "f1") == null);
}
