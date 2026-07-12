const std = @import("std");
const net = std.net;
const posix = std.posix;
const tls = @import("tls.zig");

pub const StopFlag = std.atomic.Value(bool);

pub const PollHook = struct {
    context: ?*anyopaque = null,
    onPollFn: *const fn (context: ?*anyopaque) void,

    pub fn onPoll(self: *const PollHook) void {
        self.onPollFn(self.context);
    }
};

pub const Server = struct {
    listener: std.net.Server,
    address: net.Address,
    tls_context: ?*tls.TlsContext = null,

    pub fn init(host: []const u8, port: u16, tls_context: ?*tls.TlsContext) !Server {
        const ip4 = try net.Ip4Address.parse(host, port);
        const addr = net.Address{ .in = ip4 };

        const server = try addr.listen(.{
            .reuse_address = true,
        });

        return Server{
            .listener = server,
            .address = addr,
            .tls_context = tls_context,
        };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }

    pub fn run(
        self: *Server,
        handler: *const ConnectionHandler,
        stop_flag: ?*const StopFlag,
        poll_hook: ?*const PollHook,
    ) !void {
        while (true) {
            if (stop_flag) |flag| {
                if (flag.load(.acquire)) break;

                var fds = [_]posix.pollfd{.{
                    .fd = self.listener.stream.handle,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = try posix.poll(&fds, 250);
                if (poll_hook) |hook| hook.onPoll();
                if (ready == 0) continue;
            }

            const client = try self.listener.accept();
            const conn = try std.heap.page_allocator.create(Connection);
            conn.* = .{
                .socket = client.stream.handle,
                .addr = client.address,
                .tls_conn = null,
            };

            if (self.tls_context) |tls_ctx| {
                conn.tls_conn = tls_ctx.accept(conn.socket) catch |err| {
                    std.log.err("TLS accept failed: {s}", .{@errorName(err)});
                    conn.close();
                    std.heap.page_allocator.destroy(conn);
                    continue;
                };
            }

            const thread = std.Thread.spawn(.{}, connectionWorker, .{ handler, conn }) catch |err| {
                conn.close();
                std.heap.page_allocator.destroy(conn);
                std.log.err("failed to spawn connection thread: {s}", .{@errorName(err)});
                continue;
            };
            thread.detach();
        }
    }
};

fn connectionWorker(handler: *const ConnectionHandler, conn: *Connection) void {
    defer {
        conn.close();
        std.heap.page_allocator.destroy(conn);
    }
    handler.handleConnection(conn) catch |err| {
        std.log.err("handler error: {s}", .{@errorName(err)});
    };
}

pub const Connection = struct {
    socket: posix.socket_t,
    addr: net.Address,
    tls_conn: ?tls.TlsConn = null,

    pub fn readRequest(self: *Connection, buf: []u8) !usize {
        if (self.tls_conn) |*tls_conn| {
            return tls_conn.read(buf);
        }
        return posix.read(self.socket, buf);
    }

    pub fn writeAll(self: *Connection, data: []const u8) !void {
        if (self.tls_conn) |*tls_conn| {
            return tls_conn.writeAll(data);
        }
        var offset: usize = 0;
        while (offset < data.len) {
            const written = try posix.write(
                self.socket,
                data[offset..],
            );
            if (written == 0) {
                return error.Closed;
            }
            offset += written;
        }
    }

    pub fn close(self: *Connection) void {
        if (self.tls_conn) |*tls_conn| {
            tls_conn.deinit();
            self.tls_conn = null;
        }
        posix.close(self.socket);
    }
};

pub const ConnectionHandler = struct {
    context: ?*anyopaque = null,
    handleConnectionFn: *const fn (context: ?*anyopaque, conn: *Connection) anyerror!void,

    pub fn handleConnection(self: *const ConnectionHandler, conn: *Connection) !void {
        return self.handleConnectionFn(self.context, conn);
    }
};
