const std = @import("std");

pub const Protocol = enum { anthropic_messages, openai_chat_completions };
pub const AuthStyle = enum { bearer, x_api_key };

pub const Provider = enum {
    abliteration,
    anthropic,
    openrouter,
    deepseek,
    xai,
    openai,
    gemini,
    groq,
    runinfra,
    mistral,
    together,
    fireworks,
    cerebras,
    deepinfra,
    nvidia,
    custom,

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
            .runinfra => "RUNINFRA_API_KEY",
            .mistral => "MISTRAL_API_KEY",
            .together => "TOGETHER_API_KEY",
            .fireworks => "FIREWORKS_API_KEY",
            .cerebras => "CEREBRAS_API_KEY",
            .deepinfra => "DEEPINFRA_API_KEY",
            .nvidia => "NVIDIA_API_KEY",
            .custom => "CUSTOM_API_KEY",
        };
    }

    pub fn aliasEnvKey(self: Provider) ?[]const u8 {
        return switch (self) {
            .runinfra => "RUNINFRA_GATEWAY_KEY",
            else => null,
        };
    }

    pub fn key(self: Provider, env: *const std.process.Environ.Map) []const u8 {
        if (env.get(self.envKey())) |value| if (value.len > 0) return value;
        if (self.aliasEnvKey()) |name| return env.get(name) orelse "";
        return "";
    }

    pub fn configuredEnvKey(self: Provider, env: *const std.process.Environ.Map) []const u8 {
        if (env.get(self.envKey())) |value| if (value.len > 0) return self.envKey();
        if (self.aliasEnvKey()) |name| {
            if (env.get(name)) |value| if (value.len > 0) return name;
        }
        return self.envKey();
    }

    pub fn defaultUrl(self: Provider) []const u8 {
        return switch (self) {
            .abliteration => "https://api.abliteration.ai/v1/messages",
            .anthropic => "https://api.anthropic.com/v1/messages",
            .openrouter => "https://openrouter.ai/api/v1/messages",
            .deepseek => "https://api.deepseek.com/anthropic/v1/messages",
            .xai => "https://api.x.ai/v1/messages",
            .openai => "https://api.openai.com/v1/chat/completions",
            .gemini => "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            .groq => "https://api.groq.com/openai/v1/messages",
            .runinfra => "https://api.runinfra.ai/v1/messages",
            .mistral => "https://api.mistral.ai/v1/chat/completions",
            .together => "https://api.together.ai/v1/chat/completions",
            .fireworks => "https://api.fireworks.ai/inference/v1/chat/completions",
            .cerebras => "https://api.cerebras.ai/v1/chat/completions",
            .deepinfra => "https://api.deepinfra.com/v1/openai/chat/completions",
            .nvidia => "https://integrate.api.nvidia.com/v1/chat/completions",
            .custom => "",
        };
    }

    pub fn defaultProtocol(self: Provider) Protocol {
        return switch (self) {
            .openai, .gemini, .mistral, .together, .fireworks, .cerebras, .deepinfra, .nvidia, .custom => .openai_chat_completions,
            else => .anthropic_messages,
        };
    }

    pub fn defaultAuthStyle(self: Provider) AuthStyle {
        return if (self == .anthropic or self == .runinfra) .x_api_key else .bearer;
    }

    pub fn defaultModel(self: Provider, strong: bool) []const u8 {
        return switch (self) {
            .abliteration => if (strong) "abliterated-model-large-flash" else "abliterated-model",
            .anthropic => "claude-haiku-4-5",
            .openrouter => "auto",
            .deepseek => if (strong) "deepseek-v4-pro" else "deepseek-flash",
            .xai => if (strong) "grok-4" else "grok-3-mini",
            .openai => if (strong) "gpt-4.1" else "gpt-4.1-mini",
            .gemini => if (strong) "gemini-2.5-pro" else "gemini-2.5-flash",
            .groq => "llama-3.3-70b-versatile",
            .runinfra => if (strong) "glm-5-3" else "deepseek-v4-1-flash-1017",
            .mistral => if (strong) "mistral-large-latest" else "mistral-small-latest",
            .together => if (strong) "deepseek-ai/DeepSeek-V4-Pro-0813" else "deepseek-ai/DeepSeek-V4.1-Flash",
            .fireworks => "accounts/fireworks/models/glm-5p3-flash",
            .cerebras => "qwen-3.8-27b",
            .deepinfra => if (strong) "zai-org/GLM-5.3" else "deepseek-ai/DeepSeek-V4.1-Flash",
            .nvidia => if (strong) "z-ai/glm-5.3" else "openai/gpt-oss-20b",
            .custom => "",
        };
    }

    pub fn infer(model_id: []const u8, fallback: Provider) Provider {
        if (std.mem.startsWith(u8, model_id, "accounts/fireworks/")) return if (fallback == .openrouter) .openrouter else .fireworks;
        if (std.mem.startsWith(u8, model_id, "deepseek-ai/") or std.mem.startsWith(u8, model_id, "zai-org/")) return if (fallback == .openrouter or fallback == .together) fallback else .deepinfra;
        if (std.mem.startsWith(u8, model_id, "z-ai/") or std.mem.startsWith(u8, model_id, "openai/gpt-oss-")) return if (fallback == .openrouter or fallback == .together) fallback else .nvidia;
        if (std.mem.indexOfScalar(u8, model_id, '/') != null) return if (fallback == .openrouter) .openrouter else fallback;
        if (std.mem.startsWith(u8, model_id, "abliterated-")) return .abliteration;
        if (std.mem.startsWith(u8, model_id, "claude-")) return .anthropic;
        if (fallback == .runinfra and std.mem.startsWith(u8, model_id, "deepseek-v4-1-")) return .runinfra;
        if (std.mem.startsWith(u8, model_id, "deepseek-")) return .deepseek;
        if (std.mem.startsWith(u8, model_id, "grok-")) return .xai;
        if (std.mem.startsWith(u8, model_id, "gpt-") or std.mem.startsWith(u8, model_id, "o1") or std.mem.startsWith(u8, model_id, "o3") or std.mem.startsWith(u8, model_id, "o4")) return .openai;
        if (std.mem.startsWith(u8, model_id, "gemini-")) return .gemini;
        if (std.mem.startsWith(u8, model_id, "llama-")) return if (fallback == .cerebras) .cerebras else .groq;
        if (std.mem.startsWith(u8, model_id, "mistral-") or std.mem.startsWith(u8, model_id, "codestral-")) return .mistral;
        return fallback;
    }
};

pub const Route = struct {
    provider: Provider,
    model: []const u8,
    url: []const u8,
    key: []const u8,
    protocol: Protocol = .anthropic_messages,
    auth_style: AuthStyle = .bearer,
    mode: enum { cost_max, free } = .cost_max,
    price: ?@import("pricing.zig").Price = null,
    context_length: usize = 128 * 1024,

    /// Classify once per user turn; tool results never change the selected model.
    pub fn forTask(self: Route, env: *const std.process.Environ.Map, task: []const u8) Route {
        var route = self;
        const is_complex = complex(task);
        route.model = env.get(if (is_complex) "MODEL" else "FAST_MODEL") orelse
            if (is_complex) self.model else if (self.provider == .custom) self.model else self.provider.defaultModel(false);
        return route;
    }

    pub fn init(env: *const std.process.Environ.Map, provider: ?[]const u8, model: ?[]const u8) !Route {
        const name = provider orelse env.get("PROVIDER") orelse detectProvider(env);
        const p = std.meta.stringToEnum(Provider, name) orelse return error.UnknownProvider;
        const key = p.key(env);
        if (p == .custom and (env.get("API_URL") == null or env.get("API_URL").?.len == 0)) return error.MissingCustomEndpoint;
        const selected = model orelse env.get("MODEL") orelse p.defaultModel(true);
        if (selected.len == 0) return error.EmptyModel;
        const protocol_name = env.get("API_PROTOCOL");
        const protocol: Protocol = if (protocol_name) |protocol_value| blk: {
            if (std.ascii.eqlIgnoreCase(protocol_value, "openai") or std.ascii.eqlIgnoreCase(protocol_value, "chat") or std.ascii.eqlIgnoreCase(protocol_value, "openai_chat_completions")) break :blk .openai_chat_completions;
            if (std.ascii.eqlIgnoreCase(protocol_value, "anthropic") or std.ascii.eqlIgnoreCase(protocol_value, "messages") or std.ascii.eqlIgnoreCase(protocol_value, "anthropic_messages")) break :blk .anthropic_messages;
            return error.InvalidApiProtocol;
        } else p.defaultProtocol();
        const auth_name = env.get("API_AUTH");
        const auth_style: AuthStyle = if (auth_name) |auth_value| blk: {
            if (std.ascii.eqlIgnoreCase(auth_value, "bearer")) break :blk .bearer;
            if (std.ascii.eqlIgnoreCase(auth_value, "x-api-key") or std.ascii.eqlIgnoreCase(auth_value, "x_api_key")) break :blk .x_api_key;
            return error.InvalidApiAuth;
        } else p.defaultAuthStyle();
        return .{
            .provider = p,
            .model = selected,
            .url = env.get("API_URL") orelse p.defaultUrl(),
            .key = key,
            .protocol = protocol,
            .auth_style = auth_style,
        };
    }

    fn detectProvider(env: *const std.process.Environ.Map) []const u8 {
        inline for (.{ Provider.abliteration, Provider.openrouter, Provider.runinfra, Provider.anthropic, Provider.deepseek, Provider.xai, Provider.openai, Provider.gemini, Provider.groq, Provider.mistral, Provider.together, Provider.fireworks, Provider.cerebras, Provider.deepinfra, Provider.nvidia }) |p| {
            if (p.key(env).len > 0) return @tagName(p);
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
