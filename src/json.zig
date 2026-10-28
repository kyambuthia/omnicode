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

/// Insert a map key owned by the JSON value, so secureClear may wipe it.
pub fn putOwnedKey(a: Allocator, object: *@FieldType(Value, "object"), key: []const u8, value: Value) !void {
    if (object.contains(key)) return object.put(a, key, value);
    const owned_key = try a.dupe(u8, key);
    errdefer std.crypto.secureZero(u8, owned_key);
    try object.put(a, owned_key, value);
}

/// Clear every parsed JSON string before releasing its owning scratch arena.
/// Object keys added after parsing must go through putOwnedKey.
/// An explicit worklist keeps deeply nested responses off the call stack.
pub fn secureClear(a: Allocator, value: *Value) !void {
    var pending: std.ArrayList(*Value) = .empty;
    defer pending.deinit(a);
    try pending.append(a, value);
    while (pending.pop()) |current| {
        switch (current.*) {
            .string => |text| std.crypto.secureZero(u8, @constCast(text)),
            .number_string => |text| std.crypto.secureZero(u8, @constCast(text)),
            .array => |*array| for (array.items) |*item| try clearOrQueue(a, &pending, item),
            .object => |*object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    std.crypto.secureZero(u8, @constCast(entry.key_ptr.*));
                    try clearOrQueue(a, &pending, entry.value_ptr);
                }
            },
            else => {},
        }
    }
}

fn clearOrQueue(a: Allocator, pending: *std.ArrayList(*Value), value: *Value) !void {
    switch (value.*) {
        .string => |text| std.crypto.secureZero(u8, @constCast(text)),
        .number_string => |text| std.crypto.secureZero(u8, @constCast(text)),
        .array, .object => try pending.append(a, value),
        else => {},
    }
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

test "owned object insertion keeps borrowed keys safe during cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const borrowed_key = "tools";
    const secret = try a.dupe(u8, "secret");
    var value: Value = .{ .object = .empty };
    try putOwnedKey(a, &value.object, borrowed_key, .{ .string = secret });
    var it = value.object.iterator();
    const stored_key = it.next().?.key_ptr.*;

    try std.testing.expect(stored_key.ptr != borrowed_key.ptr);
    try secureClear(std.heap.page_allocator, &value);

    const expected_key = [_]u8{ 't', 'o', 'o', 'l', 's' };
    for (expected_key, borrowed_key) |expected, actual|
        try std.testing.expectEqual(expected, actual);
    for (stored_key) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
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
