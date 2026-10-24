const std = @import("std");
const j = @import("json.zig");

/// Bounded JSON transport; callers choose deadlines and credentials. Never follow redirects.
pub fn fetch(a: std.mem.Allocator, io: std.Io, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header, limit: usize, timeout: i64) !j.Value {
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
