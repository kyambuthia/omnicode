const std = @import("std");
const Io = std.Io;

/// A short-lived tmux side pane for readable Bash output.
pub const Feed = struct {
    io: Io,
    child: std.process.Child,
    pane: [32]u8 = undefined,
    pane_len: usize = 0,
    active: bool = true,
    closed: bool = false,

    pub fn start(io: Io, env: *const std.process.Environ.Map, width: usize) !?Feed {
        if (width < 100) return null;
        const target = env.get("TMUX_PANE") orelse return null;
        if (!validPaneId(target)) return null;

        const argv = [_][]const u8{
            "tmux", "split-window", "-d", "-h", "-p", "35", "-P", "-F", "#{pane_id}", "-I", "-t", target,
        };
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .environ_map = env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        var stdout_buffer: [64]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
        const pane_id = try reader.interface.takeDelimiterExclusive('\n');
        if (!validPaneId(pane_id) or pane_id.len > 32) return error.InvalidTmuxPane;

        var feed: Feed = .{ .io = io, .child = child, .pane_len = pane_id.len };
        @memcpy(feed.pane[0..pane_id.len], pane_id);
        child.id = null;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;

        feed.child.stdout.?.close(io);
        feed.child.stdout = null;
        feed.writeRaw("  OMNICODE · BASH OUTPUT\r\n  Command results appear here. Scroll with tmux copy mode.\r\n\r\n") catch {
            feed.deinit();
            return error.TmuxPaneWriteFailed;
        };
        return feed;
    }

    pub fn writer(feed: *Feed, buffer: []u8) ?std.Io.File.Writer {
        if (!feed.active) return null;
        const stdin = feed.child.stdin orelse return null;
        return stdin.writerStreaming(feed.io, buffer);
    }

    pub fn disable(feed: *Feed) void {
        feed.deinit();
    }

    pub fn deinit(feed: *Feed) void {
        if (feed.closed) return;
        feed.active = false;
        feed.closed = true;
        if (feed.child.stdin) |stdin| {
            stdin.close(feed.io);
            feed.child.stdin = null;
        }
        feed.child.kill(feed.io);
        var pane_buf: [32]u8 = undefined;
        const target = feed.paneId(&pane_buf);
        const argv = [_][]const u8{ "tmux", "kill-pane", "-t", target };
        const result = std.process.run(std.heap.page_allocator, feed.io, .{
            .argv = &argv,
            .stdout_limit = .limited(128),
            .stderr_limit = .limited(128),
        }) catch return;
        defer {
            std.crypto.secureZero(u8, result.stdout);
            std.crypto.secureZero(u8, result.stderr);
            std.heap.page_allocator.free(result.stdout);
            std.heap.page_allocator.free(result.stderr);
        }
    }

    pub fn paneId(feed: *const Feed, buffer: *[32]u8) []const u8 {
        @memcpy(buffer[0..feed.pane_len], feed.pane[0..feed.pane_len]);
        return buffer[0..feed.pane_len];
    }

    fn writeRaw(feed: *Feed, bytes: []const u8) !void {
        const stdin = feed.child.stdin orelse return error.TmuxPaneClosed;
        try stdin.writeStreamingAll(feed.io, bytes);
    }
};

fn validPaneId(value: []const u8) bool {
    if (value.len < 2 or value[0] != '%') return false;
    for (value[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
