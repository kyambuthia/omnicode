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
        // USD per million tokens, checked 2026-10-24; estimates are not invoices.
        const rates: ?[4]f64 = if (std.mem.eql(u8, route.model, "openai/gpt-4.1-nano"))
            .{ 0.1, 0.4, 0.025, 0 }
        else if (std.mem.eql(u8, route.model, "openai/gpt-4.1-mini"))
            .{ 0.4, 1.6, 0.1, 0 }
        else if (std.mem.eql(u8, route.model, "claude-haiku-4-5") or std.mem.eql(u8, route.model, "anthropic/claude-haiku-4.5"))
            .{ 1, 5, 0.1, 1.25 }
        else
            null;
        // Non-Anthropic cache accounting varies by upstream; require reported cost.
        const translated_cache = route.provider == .openrouter and std.mem.startsWith(u8, route.model, "openai/") and (usage.read > 0 or usage.write > 0);
        if (rates != null and usage.missing == 0 and !translated_cache) {
            const r = rates.?;
            const cache = j.get(v, "cache_creation") catch .null;
            const hour = @min(usage.write, natural(cache, "ephemeral_1h_input_tokens") orelse 0);
            usage.usd = (float(usage.input) * r[0] + float(usage.output) * r[1] + float(usage.read) * r[2] +
                float(usage.write - hour) * r[3] + float(hour) * r[0] * 2) / 1_000_000;
            usage.estimated = 1;
        } else usage.unknown_cost = 1;
        return usage;
    }

    pub fn add(self: *Usage, other: Usage) void {
        inline for (.{ "requests", "input", "output", "read", "write", "missing", "unknown_cost", "estimated" }) |field|
            @field(self, field) +|= @field(other, field);
        self.usd += other.usd;
    }
};

fn natural(v: j.Value, key: []const u8) ?u64 {
    const n = j.get(v, key) catch return null;
    return if (n == .integer and n.integer >= 0) @intCast(n.integer) else null;
}
fn float(n: u64) f64 {
    return @floatFromInt(n);
}

test "usage distinguishes reported, estimated, missing and unknown pricing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    const route = try Route.init(&env, "openrouter", "openai/gpt-4.1-mini");
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
    try std.testing.expectEqual(1, Usage.response(try j.parse(a, "{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"), custom).unknown_cost);
    try std.testing.expectEqual(0, Usage.response(try j.parse(a, "{\"usage\":{\"cost\":0}}"), custom).unknown_cost);
}

test "cache estimates price Anthropic TTLs and avoid guessing translated cache billing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    const route = try Route.init(&env, "anthropic", null);
    const value = try j.parse(a, "{\"usage\":{\"input_tokens\":1000,\"output_tokens\":100,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":100,\"cache_creation\":{\"ephemeral_1h_input_tokens\":40}}}");
    const usage = Usage.response(value, route);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001675), usage.usd, 0.00000001);
    const translated = try Route.init(&env, "openrouter", "openai/gpt-4.1-mini");
    try std.testing.expectEqual(1, Usage.response(value, translated).unknown_cost);
    const invalid = try j.parse(a, "{\"usage\":{\"input_tokens\":-1,\"output_tokens\":null,\"cost\":-1}}");
    try std.testing.expectEqual(1, Usage.response(invalid, route).missing);
    try std.testing.expectEqual(1, Usage.response(invalid, route).unknown_cost);
}
