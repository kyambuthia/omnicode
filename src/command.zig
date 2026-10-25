const std = @import("std");
const Io = std.Io;

/// Capture a command like std.process.run, but cancel its process group too.
/// The group is established by spawn before exec, so children inherit it.
pub fn run(a: std.mem.Allocator, io: Io, options: std.process.RunOptions) !std.process.RunResult {
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
    defer reader.deinit();
    while (reader.fill(options.reserve_amount, options.timeout)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (reader.reader(0).buffered().len > limit) return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (reader.reader(1).buffered().len > limit) return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    waited = true;
    const stdout = try reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}
