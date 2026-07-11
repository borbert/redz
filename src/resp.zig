const std = @import("std");

pub const RespCommand = struct {
    name: []const u8,
    args: [][]const u8, // name excluded
};

pub fn parseCommand(allocator: std.mem.Allocator, reader: anytype) !RespCommand {
    var buf: [512]u8 = undefined;
    const first_byte = reader.readByte() catch return error.InvalidResp;
    if (first_byte != '*') return error.InvalidResp;

    const count_line = try readLine(reader, &buf);
    const count = std.fmt.parseInt(usize, count_line, 10) catch return error.InvalidResp;
    if (count == 0) return error.InvalidResp;

    var names = try allocator.alloc([]const u8, count);
    var filled: usize = 0;
    errdefer allocator.free(names);
    errdefer for (names[0..filled]) |s| allocator.free(s);
    for (0..count) |i| {
        names[i] = try readBulkString(allocator, reader);
        filled = i + 1;
    }

    const name = names[0];
    const args = if (count > 1) try allocator.dupe([]const u8, names[1..]) else try allocator.alloc([]const u8, 0);
    allocator.free(names);
    return .{
        .name = name,
        .args = args,
    };
}

fn readLine(reader: anytype, buf: []u8) ![]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const b = reader.readByte() catch return error.InvalidResp;
        if (b == '\r') {
            const next = reader.readByte() catch return error.InvalidResp;
            if (next != '\n') return error.InvalidResp;
            return buf[0..i];
        }
        buf[i] = b;
        i += 1;
    }
    return error.LineTooLong;
}

fn readBulkString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    var len_buf: [32]u8 = undefined;
    const dollar = reader.readByte() catch return error.InvalidResp;
    if (dollar != '$') return error.InvalidResp;
    const len_line = try readLine(reader, &len_buf);
    const len = std.fmt.parseInt(usize, len_line, 10) catch return error.InvalidResp;
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    reader.readNoEof(payload) catch return error.InvalidResp;
    var cr: [2]u8 = undefined;
    reader.readNoEof(cr[0..]) catch return error.InvalidResp;
    if (cr[0] != '\r' or cr[1] != '\n') return error.InvalidResp;
    return payload;
}

pub fn freeCommand(allocator: std.mem.Allocator, cmd: *RespCommand) void {
    allocator.free(cmd.name);
    for (cmd.args) |arg| allocator.free(arg);
    allocator.free(cmd.args);
}

pub fn writeSimpleString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("+");
    try writer.writeAll(s);
    try writer.writeAll("\r\n");
}

pub fn writeError(writer: anytype, s: []const u8) !void {
    try writer.writeAll("-");
    try writer.writeAll(s);
    try writer.writeAll("\r\n");
}

pub fn writeBulkString(writer: anytype, s: ?[]const u8) !void {
    if (s) |slice| {
        try writer.print("${d}\r\n", .{slice.len});
        try writer.writeAll(slice);
        try writer.writeAll("\r\n");
    } else {
        try writer.writeAll("$-1\r\n");
    }
}

pub fn writeInteger(writer: anytype, value: i64) !void {
    try writer.print(":{d}\r\n", .{value});
}

pub fn writeArray(writer: anytype, items: []const []const u8) !void {
    try writer.print("*{d}\r\n", .{items.len});
    for (items) |item| {
        try writeBulkString(writer, item);
    }
}

test "resp write helpers" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try writeSimpleString(fbs.writer(), "OK");
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "+OK\r\n"));

    fbs.reset();
    try writeError(fbs.writer(), "ERR bad");
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "-ERR bad\r\n"));

    fbs.reset();
    try writeBulkString(fbs.writer(), "hi");
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "$2\r\nhi\r\n"));

    fbs.reset();
    try writeBulkString(fbs.writer(), null);
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), "$-1\r\n"));

    fbs.reset();
    try writeInteger(fbs.writer(), 42);
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":42\r\n"));

    fbs.reset();
    try writeInteger(fbs.writer(), -2);
    try std.testing.expect(std.mem.eql(u8, fbs.getWritten(), ":-2\r\n"));
}

test "resp parseCommand PING SET EXPIRE" {
    const allocator = std.testing.allocator;

    const ping = "*1\r\n$4\r\nPING\r\n";
    var r1 = std.io.fixedBufferStream(ping);
    var cmd1 = try parseCommand(allocator, r1.reader());
    defer freeCommand(allocator, &cmd1);
    try std.testing.expectEqualStrings(cmd1.name, "PING");
    try std.testing.expect(cmd1.args.len == 0);

    const set_cmd = "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n";
    var r2 = std.io.fixedBufferStream(set_cmd);
    var cmd2 = try parseCommand(allocator, r2.reader());
    defer freeCommand(allocator, &cmd2);
    try std.testing.expectEqualStrings(cmd2.name, "SET");
    try std.testing.expect(cmd2.args.len == 2);
    try std.testing.expectEqualStrings(cmd2.args[0], "foo");
    try std.testing.expectEqualStrings(cmd2.args[1], "bar");

    const expire_cmd = "*3\r\n$6\r\nEXPIRE\r\n$3\r\nkey\r\n$1\r\n5\r\n";
    var r3 = std.io.fixedBufferStream(expire_cmd);
    var cmd3 = try parseCommand(allocator, r3.reader());
    defer freeCommand(allocator, &cmd3);
    try std.testing.expectEqualStrings(cmd3.name, "EXPIRE");
    try std.testing.expect(cmd3.args.len == 2);
    try std.testing.expectEqualStrings(cmd3.args[0], "key");
    try std.testing.expectEqualStrings(cmd3.args[1], "5");
}
