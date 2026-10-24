const std = @import("std");

pub const Route = struct {
    provider: enum { anthropic, openrouter },
    model: []const u8,
    url: []const u8,
    key: []const u8,

    pub fn init(env: *const std.process.Environ.Map, provider: ?[]const u8, model: ?[]const u8) !Route {
        const name = provider orelse env.get("PROVIDER") orelse
            if (env.get("OPENROUTER_API_KEY") != null) "openrouter" else "anthropic";
        const p = std.meta.stringToEnum(@FieldType(Route, "provider"), name) orelse return error.UnknownProvider;
        const key = env.get(if (p == .anthropic) "ANTHROPIC_API_KEY" else "OPENROUTER_API_KEY") orelse "";
        const selected = model orelse env.get("MODEL") orelse
            if (p == .anthropic) "claude-sonnet-4-5" else "anthropic/claude-sonnet-4.5";
        if (selected.len == 0) return error.EmptyModel;
        return .{
            .provider = p,
            .model = selected,
            .url = env.get("API_URL") orelse if (p == .anthropic)
                "https://api.anthropic.com/v1/messages"
            else
                "https://openrouter.ai/api/v1/messages",
            .key = key,
        };
    }
};

test "route selection, explicit overrides, and invalid config" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(.anthropic, (try Route.init(&env, null, null)).provider);
    try env.put("OPENROUTER_API_KEY", "test-only");
    const route = try Route.init(&env, null, null);
    try std.testing.expectEqual(.openrouter, route.provider);
    try std.testing.expectEqualStrings("test-only", route.key);
    try env.put("PROVIDER", "anthropic");
    try env.put("MODEL", "configured");
    try std.testing.expectEqualStrings("configured", (try Route.init(&env, null, null)).model);
    try std.testing.expectEqualStrings("override", (try Route.init(&env, "openrouter", "override")).model);
    try std.testing.expectError(error.UnknownProvider, Route.init(&env, "typo", null));
    try std.testing.expectError(error.EmptyModel, Route.init(&env, null, ""));
}
