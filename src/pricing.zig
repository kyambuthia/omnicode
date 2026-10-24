const std = @import("std");
const j = @import("json.zig");

/// Catalog rates are USD per token; missing dimensions stay unknown.
pub const Price = struct {
    input: f64,
    output: f64,
    read: ?f64 = null,
    write: ?f64 = null,
    hour: ?f64 = null,
    request: f64 = 0,
    variable: bool = false,
    free: bool = false,

    pub fn parse(v: j.Value) ?Price {
        var price: Price = .{
            .input = rate(v, "prompt") orelse return null,
            .output = rate(v, "completion") orelse return null,
            .read = rate(v, "input_cache_read"),
            .write = rate(v, "input_cache_write"),
            .hour = rate(v, "input_cache_write_1h"),
            .request = if ((j.get(v, "request") catch .null) == .null) 0 else rate(v, "request") orelse return null,
            .variable = (j.get(v, "overrides") catch .null) != .null,
            .free = true,
        };
        var fields = v.object.iterator();
        while (fields.next()) |field| {
            if ((rate(v, field.key_ptr.*) orelse 1) != 0) price.free = false;
        }
        return price;
    }
};

pub fn rate(v: j.Value, key: []const u8) ?f64 {
    const n = j.get(v, key) catch return null;
    const value: f64 = switch (n) {
        .string => std.fmt.parseFloat(f64, n.string) catch return null,
        .float => n.float,
        .integer => @floatFromInt(n.integer),
        else => return null,
    };
    return if (std.math.isFinite(value) and value >= 0) value else null;
}
