const std = @import("std");
const Io = std.Io;

pub const OutputObserver = struct {
    context: *anyopaque,
    on_bytes: *const fn (context: *anyopaque, stream: usize, bytes: []const u8) void,
    on_finish: *const fn (context: *anyopaque, stream: usize, complete: bool) void,
};

/// Capture a command like std.process.run, but cancel its process group too.
/// The group is established by spawn before exec, so children inherit it.
pub fn run(a: std.mem.Allocator, io: Io, options: std.process.RunOptions) !std.process.RunResult {
    return runObserved(a, io, options, null);
}

pub fn runObserved(a: std.mem.Allocator, io: Io, options: std.process.RunOptions, output_observer: ?OutputObserver) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .exe = options.exe,
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const group = child.id.?;
    std.debug.assert(group > 1);
    var waited = false;
    defer {
        // Kill before reaping the leader; its PID still identifies our group.
        // SIGKILL also bounds cleanup when a command ignores SIGTERM.
        if (!waited) {
            std.posix.kill(-group, .KILL) catch {};
            // A cancelled Zig wait closes handles and clears id before reaping.
            if (child.id == null) child.id = group;
        }
        child.kill(io);
    }
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    var observed: [2]usize = .{ 0, 0 };
    var observer_finished = false;
    defer if (!observer_finished) {
        if (output_observer) |observer| {
            for (0..2) |index| observer.on_finish(observer.context, index, false);
        }
    };
    defer {
        // Join pending reads before erasing their destination buffers.
        reader.batch.cancel(io);
        for (0..2) |index| {
            const stream = reader.reader(index);
            std.crypto.secureZero(u8, stream.buffer[0..stream.end]);
        }
        reader.deinit();
    }
    while (reader.fill(options.reserve_amount, options.timeout)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (reader.reader(0).buffered().len > limit) return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (reader.reader(1).buffered().len > limit) return error.StreamTooLong;
        }
        if (output_observer) |observer| {
            for (0..2) |index| {
                const bytes = reader.reader(index).buffered();
                if (bytes.len > observed[index]) {
                    observer.on_bytes(observer.context, index, bytes[observed[index]..]);
                    observed[index] = bytes.len;
                }
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    waited = true;
    if (output_observer) |observer| {
        for (0..2) |index| observer.on_finish(observer.context, index, true);
    }
    observer_finished = true;
    const stdout = try reader.toOwnedSlice(0);
    errdefer {
        std.crypto.secureZero(u8, stdout);
        a.free(stdout);
    }
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

test "command output observer receives pipe data before process completion" {
    const State = struct {
        bytes: std.ArrayList(u8) = .empty,
        observed_before_finish: bool = false,
        finished_streams: usize = 0,

        fn onBytes(context: *anyopaque, stream: usize, bytes: []const u8) void {
            if (stream != 0) return;
            const state: *@This() = @ptrCast(@alignCast(context));
            state.observed_before_finish = true;
            state.bytes.appendSlice(std.testing.allocator, bytes) catch @panic("observer allocation failed");
        }

        fn onFinish(context: *anyopaque, stream: usize, complete: bool) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            if (complete and stream < 2) state.finished_streams += 1;
        }
    };

    var state: State = .{};
    defer state.bytes.deinit(std.testing.allocator);
    const observer: OutputObserver = .{ .context = &state, .on_bytes = State.onBytes, .on_finish = State.onFinish };
    const result = try runObserved(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "sh", "-c", "printf 'first\\n'; sleep 0.05; printf 'last\\n'" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }, observer);
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    try std.testing.expect(result.term.success());
    try std.testing.expect(state.observed_before_finish);
    try std.testing.expectEqual(@as(usize, 2), state.finished_streams);
    try std.testing.expectEqualStrings("first\nlast\n", state.bytes.items);
}
