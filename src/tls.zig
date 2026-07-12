const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

var openssl_initialized = false;

fn ensureOpenSsl() void {
    if (openssl_initialized) return;
    _ = c.OPENSSL_init_ssl(0, null);
    openssl_initialized = true;
}

fn openSslError() []const u8 {
    const err = c.ERR_get_error();
    if (err == 0) return "unknown OpenSSL error";
    const msg = c.ERR_reason_error_string(err);
    if (msg == null) return "unknown OpenSSL error";
    return std.mem.span(msg);
}

pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    pub fn init(cert_path: []const u8, key_path: []const u8) !TlsContext {
        ensureOpenSsl();

        const method = c.TLS_server_method();
        const ctx = c.SSL_CTX_new(method) orelse return error.TlsContextInitFailed;
        errdefer c.SSL_CTX_free(ctx);

        // TLS 1.2+
        _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);

        var cert_z: [std.fs.max_path_bytes:0]u8 = undefined;
        var key_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (cert_path.len >= cert_z.len or key_path.len >= key_z.len) return error.TlsPathTooLong;
        @memcpy(cert_z[0..cert_path.len], cert_path);
        cert_z[cert_path.len] = 0;
        @memcpy(key_z[0..key_path.len], key_path);
        key_z[key_path.len] = 0;

        if (c.SSL_CTX_use_certificate_file(ctx, &cert_z, c.SSL_FILETYPE_PEM) != 1) {
            std.log.err("TLS certificate load failed: {s}", .{openSslError()});
            return error.TlsCertLoadFailed;
        }
        if (c.SSL_CTX_use_PrivateKey_file(ctx, &key_z, c.SSL_FILETYPE_PEM) != 1) {
            std.log.err("TLS private key load failed: {s}", .{openSslError()});
            return error.TlsKeyLoadFailed;
        }
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            std.log.err("TLS private key does not match certificate: {s}", .{openSslError()});
            return error.TlsKeyMismatch;
        }

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
        self.* = undefined;
    }

    pub fn accept(self: *TlsContext, socket: posix.socket_t) !TlsConn {
        const ssl = c.SSL_new(self.ctx) orelse return error.TlsConnInitFailed;
        errdefer c.SSL_free(ssl);

        if (c.SSL_set_fd(ssl, socket) != 1) return error.TlsSetFdFailed;
        const rc = c.SSL_accept(ssl);
        if (rc != 1) {
            const err = c.SSL_get_error(ssl, rc);
            std.log.err("TLS handshake failed (ssl_error={d}): {s}", .{ err, openSslError() });
            return error.TlsHandshakeFailed;
        }
        return .{ .ssl = ssl };
    }
};

pub const TlsConn = struct {
    ssl: *c.SSL,

    pub fn read(self: *TlsConn, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        const n = c.SSL_read(self.ssl, buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        if (n == 0) return 0;

        const err = c.SSL_get_error(self.ssl, n);
        return switch (err) {
            c.SSL_ERROR_ZERO_RETURN => 0,
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => error.WouldBlock,
            c.SSL_ERROR_SYSCALL => error.ConnectionResetByPeer,
            else => error.TlsReadFailed,
        };
    }

    pub fn writeAll(self: *TlsConn, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const n = c.SSL_write(self.ssl, data[offset..].ptr, @intCast(data.len - offset));
            if (n <= 0) {
                const err = c.SSL_get_error(self.ssl, n);
                return switch (err) {
                    c.SSL_ERROR_ZERO_RETURN => error.Closed,
                    c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => error.WouldBlock,
                    else => error.TlsWriteFailed,
                };
            }
            offset += @intCast(n);
        }
    }

    pub fn deinit(self: *TlsConn) void {
        _ = c.SSL_shutdown(self.ssl);
        c.SSL_free(self.ssl);
        self.* = undefined;
    }
};
