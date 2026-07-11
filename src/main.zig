const std = @import("std");
const server_mod = @import("server.zig");
const store_mod = @import("store.zig");
const commands = @import("commands.zig");
const resp = @import("resp.zig");

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

pub fn main() !void {
    gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();

    global_store = try store_mod.Store.init(gpa_impl.allocator());
    defer global_store.deinit();

    std.log.info("starting redz on 127.0.0.1:6379", .{});

    var srv = try server_mod.Server.init("127.0.0.1", 6379);
    defer srv.deinit();

    const handler = server_mod.ConnectionHandler{
        .handleConnectionFn = handleClient,
    };

    try srv.run(&handler);
}
