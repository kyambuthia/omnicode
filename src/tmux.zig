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
    current_call_id: usize = 0,
    streamed_call_id: usize = 0,
    streamed: bool = false,
    stream_complete: bool = false,

    pub fn start(io: Io, env: *const std.process.Environ.Map, width: usize) !?Feed {
        if (width < 100) return null;
        const target = env.get("TMUX_PANE") orelse return null;
        if (!validPaneId(target)) return null;

        const pane_percent = std.math.clamp(@divTrunc(5_000, width), 30, 45);
        var percent_buffer: [3]u8 = undefined;
        const percent_text = std.fmt.bufPrint(&percent_buffer, "{d}", .{pane_percent}) catch unreachable;
        const argv = [_][]const u8{
            "tmux", "split-window", "-d", "-h", "-p", percent_text, "-P", "-F", "#{pane_id}", "-I", "-t", target,
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
        feed.writeRaw("  OMNICODE · BASH OUTPUT\r\n  prefix+Right focus · prefix+z zoom\r\n  prefix+[ scroll · Ctrl+O cycle outputs\r\n  /out list · /out #<id> full\r\n\r\n") catch {
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

    pub fn beginCall(feed: *Feed, id: usize) void {
        feed.current_call_id = id;
        feed.streamed_call_id = 0;
        feed.streamed = false;
        feed.stream_complete = false;
    }

    pub fn markStreamComplete(feed: *Feed, id: usize, complete: bool) void {
        if (feed.current_call_id == id) feed.stream_complete = complete;
    }

    pub fn hasCompleteStream(feed: *const Feed, id: usize) bool {
        return feed.streamed_call_id == id and feed.streamed and feed.stream_complete;
    }

    /// Write one already-redacted output line, replacing terminal controls before they reach tmux.
    pub fn writeLiveLine(feed: *Feed, text: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        var file_writer = feed.writer(&buffer) orelse return error.TmuxPaneClosed;
        const out = &file_writer.interface;
        try out.writeAll("  ┃ ");
        const view = std.unicode.Utf8View.init(text) catch {
            try out.writeAll("[non-UTF-8 line withheld]\r\n");
            try out.flush();
            feed.streamed_call_id = feed.current_call_id;
            feed.streamed = true;
            return;
        };
        var it = view.iterator();
        var ended = false;
        while (it.nextCodepointSlice()) |bytes| {
            const cp = try std.unicode.utf8Decode(bytes);
            if (cp == '\n') {
                try out.writeAll("\r\n");
                ended = true;
            } else if (cp < 32 or (cp >= 127 and cp <= 159)) {
                try out.writeByte(if (cp == '\t' or cp == '\r') ' ' else '?');
                ended = false;
            } else {
                try out.writeAll(bytes);
                ended = false;
            }
        }
        if (!ended) try out.writeAll("\r\n");
        try out.flush();
        feed.streamed_call_id = feed.current_call_id;
        feed.streamed = true;
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
