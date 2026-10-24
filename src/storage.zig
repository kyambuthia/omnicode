const std = @import("std");

/// POSIX path conversion requires an interior-NUL-free byte slice.
pub fn validatePath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}

/// Replace private state only after its complete contents have been written.
/// Replacing the directory entry also avoids following a destination symlink
/// or modifying another hard link to the old file.
pub fn writePrivate(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try validatePath(path);
    var file = try dir.createFileAtomic(io, path, .{
        .permissions = .fromMode(0o600),
        .make_path = true,
        .replace = true,
    });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.replace(io);
}

test "failed replacement leaves destination intact and removes temporary file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "state", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "state/marker", .data = "keep" });
    if (writePrivate(io, tmp.dir, "state", "replacement")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    const marker = try tmp.dir.readFileAlloc(io, "state/marker", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(marker);
    try std.testing.expectEqualStrings("keep", marker);
    var iterator = tmp.dir.iterate();
    const entry = (try iterator.next(io)).?;
    try std.testing.expectEqualStrings("state", entry.name);
    try std.testing.expect(try iterator.next(io) == null);
}

test "private writes reject NUL paths before replacing a destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "state", .data = "original" });
    try std.testing.expectError(error.InvalidPath, writePrivate(io, tmp.dir, "state\x00suffix", "replacement"));
    const text = try tmp.dir.readFileAlloc(io, "state", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("original", text);
}
