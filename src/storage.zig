const std = @import("std");

/// POSIX path conversion requires an interior-NUL-free byte slice.
pub fn validatePath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}

/// Publish complete contents only if the destination is still absent.
/// Returns false when any entry (including a dangling symlink) already exists.
pub fn createNew(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !bool {
    try validatePath(path);
    var file = try dir.createFileAtomic(io, path, .{});
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    file.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    return true;
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

test "new files are published completely without replacing existing entries" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expect(try createNew(io, tmp.dir, "new", "complete contents"));
    try std.testing.expect(!try createNew(io, tmp.dir, "new", "replacement"));
    const text = try tmp.dir.readFileAlloc(io, "new", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("complete contents", text);
    var iterator = tmp.dir.iterate();
    try std.testing.expectEqualStrings("new", (try iterator.next(io)).?.name);
    try std.testing.expect(try iterator.next(io) == null);
}
