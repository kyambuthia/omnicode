const std = @import("std");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;

// Parsed values and encoded strings share the caller's arena lifetime.
pub fn parse(a: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
}
pub fn encode(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
pub fn get(v: Value, key: []const u8) !Value {
    if (v != .object) return error.ExpectedObject;
    return v.object.get(key) orelse error.MissingField;
}
pub fn string(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.ExpectedString;
}
pub fn str(v: Value, key: []const u8) ![]const u8 {
    return string(try get(v, key));
}
pub fn number(v: Value, key: []const u8, default: usize) !usize {
    if (v != .object) return error.ExpectedObject;
    const n = v.object.get(key) orelse return default;
    if (n != .integer or n.integer < 0) return error.ExpectedNaturalNumber;
    return std.math.cast(usize, n.integer) orelse error.ExpectedNaturalNumber;
}
pub fn optional(v: Value, key: []const u8, default: []const u8) ![]const u8 {
    if (v != .object) return error.ExpectedObject;
    return if (v.object.get(key)) |s| string(s) else default;
}

/// Accept a compatibility spelling without silently choosing conflicting input.
pub fn aliasedString(v: Value, key: []const u8, alias: []const u8) ![]const u8 {
    if (v != .object) return error.ExpectedObject;
    const alternate = v.object.get(alias);
    if (v.object.get(key)) |primary| {
        const value = try string(primary);
        if (alternate) |other| {
            if (!std.mem.eql(u8, value, try string(other))) return error.ConflictingArguments;
        }
        return value;
    }
    return string(alternate orelse return error.MissingField);
}

test "string aliases validate both spellings and reject conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"cmd\":\"same\"}", "{\"command\":\"same\"}", "{\"cmd\":\"same\",\"command\":\"same\"}" }) |raw| {
        try std.testing.expectEqualStrings("same", try aliasedString(try parse(a, raw), "cmd", "command"));
    }
    try std.testing.expectError(error.MissingField, aliasedString(try parse(a, "{}"), "cmd", "command"));
    try std.testing.expectError(error.ExpectedObject, aliasedString(.null, "cmd", "command"));
    for ([_][]const u8{ "{\"command\":false}", "{\"cmd\":false,\"command\":\"same\"}", "{\"cmd\":\"same\",\"command\":false}" }) |raw| {
        try std.testing.expectError(error.ExpectedString, aliasedString(try parse(a, raw), "cmd", "command"));
    }
    try std.testing.expectError(error.ConflictingArguments, aliasedString(try parse(a, "{\"cmd\":\"one\",\"command\":\"two\"}"), "cmd", "command"));
}

test "generated JSON values retain strings, numbers, and canonical encoding" {
    for (0..256) |index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var seed: u64 = @as(u64, index) + 1;
        var bytes: [48]u8 = undefined;
        const input = bytes[0 .. index % (bytes.len + 1)];
        for (input) |*byte| {
            seed = seed *% 6364136223846793005 +% 1;
            byte.* = @intCast(seed >> 57);
        }
        const signed: i64 = @bitCast(seed);
        const encoded = try encode(a, .{ .text = input, .number = signed, .enabled = index % 2 == 0 });
        const parsed = try parse(a, encoded);
        try std.testing.expectEqualStrings(input, try str(parsed, "text"));
        const number_value = try get(parsed, "number");
        try std.testing.expectEqual(signed, number_value.integer);
        const enabled = try get(parsed, "enabled");
        try std.testing.expectEqual(index % 2 == 0, enabled.bool);
        try std.testing.expectEqualStrings(encoded, try encode(a, try parse(a, try encode(a, parsed))));
    }
}

test "fuzz JSON parsing and serialization" {
    try std.testing.fuzz({}, fuzzJson, .{ .corpus = &.{
        "\x02\x00\x00\x00{}",
        "\x02\x00\x00\x00[]",
        "\x04\x00\x00\x00null",
        "\x07\x00\x00\x00{\"x\":1}",
    } });
}

fn fuzzJson(_: void, smith: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    const len = smith.slice(&bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = parse(a, bytes[0..len]) catch return;
    const encoded = try encode(a, parsed);
    try std.testing.expectEqualStrings(encoded, try encode(a, try parse(a, encoded)));
}
