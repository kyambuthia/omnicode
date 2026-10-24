const std = @import("std");

pub const Provider = enum {
    abliteration,
    anthropic,
    openrouter,
    deepseek,
    xai,
    openai,
    gemini,
    groq,

    pub fn envKey(self: Provider) []const u8 {
        return switch (self) {
            .abliteration => "AN_ABLE_KEY",
            .anthropic => "ANTHROPIC_API_KEY",
            .openrouter => "OPENROUTER_API_KEY",
            .deepseek => "DEEPSEEK_API_KEY",
            .xai => "XAI_API_KEY",
            .openai => "OPENAI_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .groq => "GROQ_API_KEY",
        };
    }

    pub fn defaultUrl(self: Provider) []const u8 {
        return switch (self) {
            .abliteration => "https://api.abliteration.ai/v1/messages",
            .anthropic => "https://api.anthropic.com/v1/messages",
            .openrouter => "https://openrouter.ai/api/v1/messages",
            .deepseek => "https://api.deepseek.com/anthropic/v1/messages",
            .xai => "https://api.x.ai/v1/messages",
            .openai => "https://api.openai.com/v1/messages",
            .gemini => "https://generativelanguage.googleapis.com/v1beta/openai/messages",
            .groq => "https://api.groq.com/openai/v1/messages",
        };
    }

    pub fn defaultModel(self: Provider, strong: bool) []const u8 {
        return switch (self) {
            .abliteration => if (strong) "abliterated-model-large-flash" else "abliterated-model",
            .anthropic => "claude-haiku-4-5",
            .openrouter => "auto",
            .deepseek => if (strong) "deepseek-reasoner" else "deepseek-chat",
            .xai => if (strong) "grok-4" else "grok-3-mini",
            .openai => if (strong) "gpt-4.1" else "gpt-4.1-mini",
            .gemini => if (strong) "gemini-2.5-pro" else "gemini-2.5-flash",
            .groq => "llama-3.3-70b-versatile",
        };
    }

    pub fn infer(model_id: []const u8, fallback: Provider) Provider {
        if (std.mem.indexOfScalar(u8, model_id, '/') != null) return .openrouter;
        if (std.mem.startsWith(u8, model_id, "abliterated-")) return .abliteration;
        if (std.mem.startsWith(u8, model_id, "claude-")) return .anthropic;
        if (std.mem.startsWith(u8, model_id, "deepseek-")) return .deepseek;
        if (std.mem.startsWith(u8, model_id, "grok-")) return .xai;
        if (std.mem.startsWith(u8, model_id, "gpt-") or std.mem.startsWith(u8, model_id, "o1") or std.mem.startsWith(u8, model_id, "o3") or std.mem.startsWith(u8, model_id, "o4")) return .openai;
        if (std.mem.startsWith(u8, model_id, "gemini-")) return .gemini;
        if (std.mem.startsWith(u8, model_id, "llama-")) return .groq;
        return fallback;
    }
};

pub const Route = struct {
    provider: Provider,
    model: []const u8,
    url: []const u8,
    key: []const u8,
    mode: enum { cost_max, free } = .cost_max,
    price: ?@import("pricing.zig").Price = null,
    context_length: usize = 128 * 1024,

    /// Classify once per user turn; tool results never change the selected model.
    pub fn forTask(self: Route, env: *const std.process.Environ.Map, task: []const u8) Route {
        var route = self;
        const is_complex = complex(task);
        route.model = env.get(if (is_complex) "MODEL" else "FAST_MODEL") orelse
            if (is_complex) self.model else self.provider.defaultModel(false);
        return route;
    }

    pub fn init(env: *const std.process.Environ.Map, provider: ?[]const u8, model: ?[]const u8) !Route {
        const name = provider orelse env.get("PROVIDER") orelse detectProvider(env);
        const p = std.meta.stringToEnum(Provider, name) orelse return error.UnknownProvider;
        const key = env.get(p.envKey()) orelse "";
        const selected = model orelse env.get("MODEL") orelse p.defaultModel(true);
        if (selected.len == 0) return error.EmptyModel;
        return .{
            .provider = p,
            .model = selected,
            .url = env.get("API_URL") orelse p.defaultUrl(),
            .key = key,
        };
    }

    fn detectProvider(env: *const std.process.Environ.Map) []const u8 {
        inline for (.{ Provider.abliteration, Provider.openrouter, Provider.anthropic, Provider.deepseek, Provider.xai, Provider.openai, Provider.gemini, Provider.groq }) |p| {
            if (env.get(p.envKey())) |v| if (v.len > 0) return @tagName(p);
        }
        return "anthropic";
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
