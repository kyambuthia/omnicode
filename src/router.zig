const std = @import("std");

pub const Route = struct {
    provider: enum { anthropic, openrouter },
    model: []const u8,
    url: []const u8,
    key: []const u8,
    mode: enum { cost_max, free } = .cost_max,
    price: ?@import("pricing.zig").Price = null,
    context_length: usize = 128 * 1024,

    /// Classify once per user turn; tool results never change the selected model.
    pub fn forTask(self: Route, env: *const std.process.Environ.Map, task: []const u8) Route {
        var route = self;
        route.model = env.get(if (complex(task)) "MODEL" else "FAST_MODEL") orelse
            if (complex(task)) self.model else if (self.provider == .anthropic)
                "claude-haiku-4-5"
            else
                "auto";
        return route;
    }

    pub fn init(env: *const std.process.Environ.Map, provider: ?[]const u8, model: ?[]const u8) !Route {
        const name = provider orelse env.get("PROVIDER") orelse
            if (env.get("OPENROUTER_API_KEY") != null) "openrouter" else "anthropic";
        const p = std.meta.stringToEnum(@FieldType(Route, "provider"), name) orelse return error.UnknownProvider;
        const key = env.get(if (p == .anthropic) "ANTHROPIC_API_KEY" else "OPENROUTER_API_KEY") orelse "";
        const selected = model orelse env.get("MODEL") orelse
            if (p == .anthropic) "claude-haiku-4-5" else "auto";
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

pub fn complex(task: []const u8) bool {
    if (task.len > 240) return true;
    var words = std.mem.tokenizeAny(u8, task, " \t\r\n.,:;!?/()-");
    while (words.next()) |word| {
        inline for (.{ "implement", "add", "change", "update", "remove", "delete", "plan", "reason", "diagnose", "build", "create", "write", "edit", "fix", "debug", "refactor", "test", "tests", "migrate", "design", "architecture", "optimize", "security", "review" }) |verb| {
            if (std.ascii.eqlIgnoreCase(word, verb)) return true;
        }
    }
    return false;
}

test "task router chooses configured fast/strong models and preserves provider" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("FAST_MODEL", "cheap");
    try env.put("MODEL", "strong");
    const route = try Route.init(&env, "openrouter", null);
    try std.testing.expectEqualStrings("cheap", route.forTask(&env, "what files are here?").model);
    try std.testing.expectEqualStrings("strong", route.forTask(&env, "FIX a failing test").model);
    try std.testing.expectEqual(.openrouter, route.forTask(&env, "explain main.zig").provider);
    var long_task: [241]u8 = undefined;
    @memset(&long_task, 'x');
    try std.testing.expect(complex(&long_task));
    try std.testing.expect(!complex("list fixtures"));
}

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

test "defaults keep both task tiers economical without overriding configured models" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const route = try Route.init(&env, "openrouter", null);
    try std.testing.expectEqualStrings("auto", route.forTask(&env, "fix code").model);
    try std.testing.expectEqualStrings("auto", route.forTask(&env, "list files").model);
    const direct = try Route.init(&env, "anthropic", null);
    try std.testing.expectEqualStrings("claude-haiku-4-5", direct.forTask(&env, "fix code").model);
}
