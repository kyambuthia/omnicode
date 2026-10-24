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
