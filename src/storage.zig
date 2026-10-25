const std = @import("std");

/// POSIX path conversion requires an interior-NUL-free byte slice.
pub fn validatePath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}

/// Reject non-regular filesystem entries before a potentially blocking open.
/// This metadata precheck does not protect against concurrent path replacement.
pub fn readRegular(io: std.Io, dir: std.Io.Dir, path: []const u8, a: std.mem.Allocator, limit: std.Io.Limit) ![]const u8 {
    try validatePath(path);
    const metadata = try dir.statFile(io, path, .{});
    if (metadata.kind != .file) return error.NotRegularFile;
    return dir.readFileAlloc(io, path, a, limit);
}

/// Direct writes may create a new file or overwrite a regular file, but must
/// not open an existing special entry. Like reads, this is a metadata precheck.
pub fn checkWriteTarget(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    try validatePath(path);
    const metadata = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (metadata.kind != .file) return error.NotRegularFile;
}

pub fn writeRegular(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try checkWriteTarget(io, dir, path);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
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

test "regular reads preserve limits and reject directories and NUL paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "text" });
    const text = try readRegular(io, tmp.dir, "file", a, .limited(5));
    defer a.free(text);
    try std.testing.expectEqualStrings("text", text);
    try std.testing.expectError(error.StreamTooLong, readRegular(io, tmp.dir, "file", a, .limited(4)));
    try std.testing.expectError(error.NotRegularFile, readRegular(io, tmp.dir, ".", a, .limited(16)));
    try std.testing.expectError(error.InvalidPath, readRegular(io, tmp.dir, "file\x00suffix", a, .limited(16)));
}

test "regular writes create and overwrite files but preserve directory targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeRegular(io, tmp.dir, "new", "first");
    try writeRegular(io, tmp.dir, "new", "second");
    const text = try readRegular(io, tmp.dir, "new", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("second", text);
    try tmp.dir.createDir(io, "directory", .default_dir);
    try std.testing.expectError(error.NotRegularFile, writeRegular(io, tmp.dir, "directory", "data"));
    try std.testing.expectError(error.InvalidPath, writeRegular(io, tmp.dir, "new\x00suffix", "data"));
}
