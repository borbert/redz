const std = @import("std");
const server_mod = @import("server.zig");
const commands = @import("commands.zig");
const resp = @import("resp.zig");
const config_mod = @import("config.zig");
const persistence = @import("persistence.zig");
const aof = @import("aof.zig");
const store_mod = @import("store.zig");

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    mutex: *std.Thread.Mutex,
    config: *const config_mod.Config,
    persistence_runtime: *persistence.PersistenceRuntime,
    aof_writer: ?*aof.AofWriter = null,
};

const max_input_bytes: usize = 16 * 1024 * 1024;
const read_chunk: usize = 4096;

pub fn handleConnection(raw_context: ?*anyopaque, conn: *server_mod.Connection) !void {
    const app_context: *AppContext = @ptrCast(@alignCast(raw_context.?));

    var conn_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = conn_gpa.deinit();
    const allocator = conn_gpa.allocator();

    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    var read_buf: [read_chunk]u8 = undefined;
    var authenticated = !app_context.config.authRequired();

    while (true) {
        var parsed = resp.parseCommandFromBuffer(allocator, input.items) catch |err| switch (err) {
            error.IncompleteResp => {
                if (!try readMore(conn, allocator, &input, &read_buf)) return;
                continue;
            },
            error.OutOfMemory => return err,
            else => {
                try writeProtocolError(conn, "ERR invalid RESP");
                return;
            },
        };
        defer resp.freeCommand(allocator, &parsed.command);

        const raw_command = try allocator.dupe(u8, input.items[0..parsed.bytes_consumed]);
        defer allocator.free(raw_command);

        drainConsumed(&input, parsed.bytes_consumed);
        try processCommand(app_context, conn, &parsed.command, raw_command, &authenticated);
    }
}

fn drainConsumed(input: *std.ArrayList(u8), consumed: usize) void {
    const remaining = input.items.len - consumed;
    std.mem.copyForwards(u8, input.items[0..remaining], input.items[consumed..]);
    input.shrinkRetainingCapacity(remaining);
}

fn readMore(
    conn: *server_mod.Connection,
    allocator: std.mem.Allocator,
    input: *std.ArrayList(u8),
    read_buf: []u8,
) !bool {
    const n = conn.readRequest(read_buf) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return false,
        else => return err,
    };
    if (n == 0) return false;

    if (input.items.len + n > max_input_bytes) {
        try writeProtocolError(conn, "ERR protocol buffer overflow");
        return false;
    }
    try input.appendSlice(allocator, read_buf[0..n]);
    return true;
}

fn writeProtocolError(conn: *server_mod.Connection, message: []const u8) !void {
    var err_buf: [64]u8 = undefined;
    var err_fbs = std.io.fixedBufferStream(&err_buf);
    try resp.writeError(err_fbs.writer(), message);
    try conn.writeAll(err_fbs.getWritten());
}

fn processCommand(
    app_context: *AppContext,
    conn: *server_mod.Connection,
    cmd: *const resp.RespCommand,
    raw_command: []const u8,
    authenticated: *bool,
) !void {
    var out_buf: [65536]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    if (std.ascii.eqlIgnoreCase(cmd.name, "AUTH")) {
        try handleAuth(app_context, cmd.args, authenticated, out_fbs.writer());
        try conn.writeAll(out_fbs.getWritten());
        return;
    }

    if (app_context.config.authRequired() and !authenticated.*) {
        try resp.writeError(out_fbs.writer(), "NOAUTH Authentication required.");
        try conn.writeAll(out_fbs.getWritten());
        return;
    }

    app_context.mutex.lock();
    defer app_context.mutex.unlock();

    var ctx = commands.CommandContext{
        .store = app_context.store,
        .allocator = app_context.allocator,
        .persistence_config = &app_context.config.persistence,
        .persistence_runtime = app_context.persistence_runtime,
    };

    commands.dispatch(&ctx, cmd.name, cmd.args, out_fbs.writer()) catch |err| {
        out_fbs.reset();
        const message: []const u8 = switch (err) {
            error.UnknownCommand => "unknown command",
            error.WrongArity => "wrong number of arguments",
            error.InvalidInteger => "ERR value is not an integer",
            error.WrongType => "WRONGTYPE Operation against a key holding the wrong kind of value",
            else => @errorName(err),
        };
        try resp.writeError(out_fbs.writer(), message);
        try conn.writeAll(out_fbs.getWritten());
        return;
    };

    maybeAppendAof(app_context, cmd.name, raw_command);
    try conn.writeAll(out_fbs.getWritten());
}

fn handleAuth(
    app_context: *AppContext,
    args: []const []const u8,
    authenticated: *bool,
    writer: anytype,
) !void {
    if (!app_context.config.authRequired()) {
        try resp.writeError(writer, "ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?");
        return;
    }

    const password = switch (args.len) {
        1 => args[0],
        2 => args[1], // AUTH username password — username ignored for now
        else => {
            try resp.writeError(writer, "ERR wrong number of arguments for 'auth' command");
            return;
        },
    };

    if (app_context.config.passwordsEqual(password)) {
        authenticated.* = true;
        try resp.writeSimpleString(writer, "OK");
    } else {
        authenticated.* = false;
        try resp.writeError(writer, "WRONGPASS invalid username-password pair or user is disabled.");
    }
}

fn maybeAppendAof(app_context: *AppContext, cmd_name: []const u8, raw_command: []const u8) void {
    if (!commands.isMutatingCommand(cmd_name)) return;
    const aof_writer = app_context.aof_writer orelse return;

    aof_writer.append(raw_command) catch |err| {
        std.log.err("aof append failed after successful command '{s}': {}", .{ cmd_name, err });
        return;
    };
    aof_writer.maybeFsync(std.time.timestamp()) catch |fsync_err| {
        std.log.err("aof fsync failed after successful command '{s}': {}", .{ cmd_name, fsync_err });
    };
}

test "pipeline parses multiple commands from one buffer" {
    const allocator = std.testing.allocator;
    const payload =
        "*1\r\n$4\r\nPING\r\n" ++
        "*2\r\n$4\r\nECHO\r\n$5\r\nhello\r\n";

    var first = try resp.parseCommandFromBuffer(allocator, payload);
    defer resp.freeCommand(allocator, &first.command);
    try std.testing.expectEqualStrings("PING", first.command.name);
    try std.testing.expectEqual(@as(usize, 14), first.bytes_consumed);

    var second = try resp.parseCommandFromBuffer(allocator, payload[first.bytes_consumed..]);
    defer resp.freeCommand(allocator, &second.command);
    try std.testing.expectEqualStrings("ECHO", second.command.name);
    try std.testing.expectEqualStrings("hello", second.command.args[0]);
}

test "incomplete command waits for more bytes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.IncompleteResp,
        resp.parseCommandFromBuffer(allocator, "*1\r\n$4\r\nPI"),
    );
}

test "auth gate rejects until valid password" {
    var store = try store_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var mutex = std.Thread.Mutex{};
    var runtime = persistence.PersistenceRuntime{};
    var config = config_mod.Config{
        .requirepass = "hunter2",
    };
    var app = AppContext{
        .allocator = std.testing.allocator,
        .store = &store,
        .mutex = &mutex,
        .config = &config,
        .persistence_runtime = &runtime,
    };

    var authenticated = false;
    var buf: [128]u8 = undefined;

    {
        var fbs = std.io.fixedBufferStream(&buf);
        try handleAuth(&app, &[_][]const u8{"wrong"}, &authenticated, fbs.writer());
        try std.testing.expect(!authenticated);
        try std.testing.expect(std.mem.startsWith(u8, fbs.getWritten(), "-WRONGPASS"));
    }
    {
        var fbs = std.io.fixedBufferStream(&buf);
        try handleAuth(&app, &[_][]const u8{"hunter2"}, &authenticated, fbs.writer());
        try std.testing.expect(authenticated);
        try std.testing.expectEqualStrings("+OK\r\n", fbs.getWritten());
    }
    {
        var fbs = std.io.fixedBufferStream(&buf);
        try handleAuth(&app, &[_][]const u8{ "default", "hunter2" }, &authenticated, fbs.writer());
        try std.testing.expect(authenticated);
        try std.testing.expectEqualStrings("+OK\r\n", fbs.getWritten());
    }
}
