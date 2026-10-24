const std = @import("std");
const j = @import("json.zig");

/// Require TLS outside literal loopback addresses. Do not trust DNS names to
/// remain local, and never accept embedded credentials in endpoint URLs.
pub fn validateEndpoint(url: []const u8) !void {
    for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidEndpoint;
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidEndpoint;
    const component = uri.host orelse return error.InvalidEndpoint;
    const host = switch (component) {
        .raw, .percent_encoded => |host| host,
    };
    if (host.len == 0) return error.InvalidEndpoint;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidEndpoint;
    if (std.Io.net.Ip4Address.parse(host, 0)) |address| {
        if (address.bytes[0] == 127) return;
    } else |_| {}
    if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') {
        if (std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0)) |address| {
            if (std.mem.eql(u8, &address.bytes, &std.Io.net.Ip6Address.loopback(0).bytes)) return;
        } else |_| {}
    }
    return error.InsecureEndpoint;
}

/// Bounded JSON transport; callers choose deadlines and credentials. Never follow redirects.
pub fn fetch(a: std.mem.Allocator, io: std.Io, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header, limit: usize, timeout: i64) !j.Value {
    try validateEndpoint(url);
    const buffer = try std.heap.page_allocator.alloc(u8, limit);
    defer std.heap.page_allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    const response = try @import("deadline.zig").run(io, std.http.Client.fetch, .{
        &client,
        std.http.Client.FetchOptions{
            .location = .{ .url = url },
            .payload = payload,
            .response_writer = &writer,
            .redirect_behavior = .unhandled,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            // Zig 0.17 does not emit privileged_headers; redirects stay disabled.
            .extra_headers = headers,
        },
    }, timeout);
    if (response.status != .ok) {
        std.debug.print("API HTTP {d}\n", .{@backingInt(response.status)});
        return error.ApiError;
    }
    return j.parse(a, writer.buffered());
}

test "endpoints require TLS or literal loopback HTTP" {
    for ([_][]const u8{
        "https://api.example.com/v1/messages", "https://127.0.0.1:8443/test",
        "http://127.0.0.1:1234/v1/messages",   "http://127.255.255.254/test",
        "http://[::1]:1234/test",              "http://[0:0:0:0:0:0:0:1]/test",
    }) |url| try validateEndpoint(url);
    for ([_][]const u8{
        "http://example.com/messages",    "http://localhost/messages",   "http://127.0.0.1.example.com/test",
        "http://192.168.1.1/test",        "http://0.0.0.0/test",         "http://[::]/test",
        "http://[::ffff:127.0.0.1]/test", "http://%31%32%37.0.0.1/test",
    }) |url| try std.testing.expectError(error.InsecureEndpoint, validateEndpoint(url));
    for ([_][]const u8{
        "file:///tmp/test",                       "ftp://example.com/test",             "https:///test",                     "not a url",
        "https://user:password@example.com/test", "http://127.0.0.1@evil.example/test", "https://example.com/test#fragment", "https://example.com/test\r\nInjected: header",
    }) |url| try std.testing.expectError(error.InvalidEndpoint, validateEndpoint(url));
}
