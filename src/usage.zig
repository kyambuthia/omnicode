const std = @import("std");
const j = @import("json.zig");
const Route = @import("router.zig").Route;

/// Counts only returned responses; unavailable metadata is never represented as free usage.
pub const Usage = struct {
    requests: u64 = 0,
    input: u64 = 0,
    output: u64 = 0,
    read: u64 = 0,
    write: u64 = 0,
    missing: u64 = 0,
    unknown_cost: u64 = 0,
    estimated: u64 = 0,
    compactions: u64 = 0,
    usd: f64 = 0,

    pub fn response(value: j.Value, route: Route) Usage {
        var usage: Usage = .{ .requests = 1 };
        const v = j.get(value, "usage") catch .null;
        const input = natural(v, "input_tokens");
        const output = natural(v, "output_tokens");
        usage.input = input orelse 0;
        usage.output = output orelse 0;
        usage.read = natural(v, "cache_read_input_tokens") orelse 0;
        usage.write = natural(v, "cache_creation_input_tokens") orelse 0;
        usage.missing = @intFromBool(input == null or output == null);
        const cost = j.get(v, "cost") catch .null;
        const reported: ?f64 = switch (cost) {
            .float => cost.float,
            .integer => @floatFromInt(cost.integer),
            else => null,
        };
        if (reported) |usd| {
            if (std.math.isFinite(usd) and usd >= 0) {
                usage.usd = usd;
                return usage;
            }
        }
        const price = route.price orelse {
            usage.unknown_cost = 1;
            return usage;
        };
        // Cache counter conventions vary on translated non-Anthropic responses.
        const translated_cache = !std.mem.startsWith(u8, route.model, "anthropic/") and route.provider == .openrouter and (usage.read > 0 or usage.write > 0);
        if (!price.variable and usage.missing == 0 and !translated_cache) {
            const cache = j.get(v, "cache_creation") catch .null;
            const hour = @min(usage.write, natural(cache, "ephemeral_1h_input_tokens") orelse 0);
            const read_cost = charge(usage.read, price.read);
            const write_cost = charge(usage.write - hour, price.write);
            const hour_cost = charge(hour, price.hour);
            if (read_cost != null and write_cost != null and hour_cost != null) {
                usage.usd = float(usage.input) * price.input + float(usage.output) * price.output +
                    read_cost.? + write_cost.? + hour_cost.? + price.request;
                usage.estimated = 1;
                return usage;
            }
        }
        usage.unknown_cost = 1;
        return usage;
    }

    pub fn add(self: *Usage, other: Usage) void {
        inline for (.{ "requests", "input", "output", "read", "write", "missing", "unknown_cost", "estimated", "compactions" }) |field|
            @field(self, field) +|= @field(other, field);
        self.usd += other.usd;
    }
};

fn natural(v: j.Value, key: []const u8) ?u64 {
    const n = j.get(v, key) catch return null;
    return if (n == .integer and n.integer >= 0) @intCast(n.integer) else null;
}
fn charge(tokens: u64, price: ?f64) ?f64 {
    return if (tokens == 0) 0 else float(tokens) * (price orelse return null);
}
fn float(n: u64) f64 {
    return @floatFromInt(n);
}

test "usage distinguishes reported, estimated, missing and unknown pricing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var route = try Route.init(&env, "openrouter", "catalog/model");
    route.price = .{ .input = 0.0000004, .output = 0.0000016 };
    const estimate = Usage.response(try j.parse(a, "{\"usage\":{\"input_tokens\":1000,\"output_tokens\":100}}"), route);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00056), estimate.usd, 0.00000001);
    try std.testing.expectEqual(1, estimate.estimated);
    var total = estimate;
    const actual = Usage.response(try j.parse(a, "{\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"cost\":0.002}}"), route);
    total.add(actual);
    try std.testing.expectEqual(1010, total.input);
    try std.testing.expectEqual(120, total.output);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00256), total.usd, 0.00000001);
    try std.testing.expectEqual(1, Usage.response(try j.parse(a, "{}"), route).missing);
    var custom = route;
    custom.model = "custom";
    custom.price = null;
    try std.testing.expectEqual(1, Usage.response(try j.parse(a, "{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"), custom).unknown_cost);
    try std.testing.expectEqual(0, Usage.response(try j.parse(a, "{\"usage\":{\"cost\":0}}"), custom).unknown_cost);
}

test "cache estimates price Anthropic TTLs and avoid guessing translated cache billing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var route = try Route.init(&env, "anthropic", null);
    route.price = .{ .input = 0.000001, .output = 0.000005, .read = 0.0000001, .write = 0.00000125, .hour = 0.000002 };
    const value = try j.parse(a, "{\"usage\":{\"input_tokens\":1000,\"output_tokens\":100,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":100,\"cache_creation\":{\"ephemeral_1h_input_tokens\":40}}}");
    const usage = Usage.response(value, route);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001675), usage.usd, 0.00000001);
    const translated = try Route.init(&env, "openrouter", "openai/gpt-4.1-mini");
    try std.testing.expectEqual(1, Usage.response(value, translated).unknown_cost);
    const invalid = try j.parse(a, "{\"usage\":{\"input_tokens\":-1,\"output_tokens\":null,\"cost\":-1}}");
    try std.testing.expectEqual(1, Usage.response(invalid, route).missing);
    try std.testing.expectEqual(1, Usage.response(invalid, route).unknown_cost);
}
