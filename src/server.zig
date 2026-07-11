const std = @import("std");
const net = std.net;
const posix = std.posix;

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

    pub fn init(host: []const u8, port: u16) !Server {
        // Build an Address from host/port
        const ip4 = try net.Ip4Address.parse(host, port);
        const addr = net.Address{ .in = ip4 };

        // Use the high-level listen helper (handles bind/listen/reuseaddr).[page:3]
        const server = try addr.listen(.{
            .reuse_address = true,
        });

        return Server{
            .listener = server,
            .address = addr,
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
        while (stop_flag == null or !stop_flag.?.load(.acquire)) {
            if (stop_flag != null) {
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
            // client has: .stream (TcpStream) and .address

            var conn = Connection{
                .socket = client.stream.handle, // underlying fd
                .addr = client.address,
            };

            handler.handleConnection(&conn) catch |err| {
                std.log.err("handler error: {s}", .{@errorName(err)});
            };

            conn.close(); // closes the stream via fd
        }
    }
};

pub const Connection = struct {
    socket: posix.socket_t,
    addr: net.Address,
    // later we can add buffer(s), timeouts, etc.

    pub fn readRequest(self: *Connection, buf: []u8) !usize {
        // blocking read into buf, return bytes read or error

        const n = try posix.read(self.socket, buf);
        return n;
    }

    pub fn writeAll(self: *Connection, data: []const u8) !void {
        // loop on posix.write until all bytes written
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
        // close socket
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
