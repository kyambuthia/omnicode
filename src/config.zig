const std = @import("std");
const Io = std.Io;
const router = @import("router.zig");
const status = @import("status.zig");

pub const allowed_keys = [_][]const u8{
    "AN_ABLE_KEY",
    "OPENROUTER_API_KEY",
    "ANTHROPIC_API_KEY",
    "DEEPSEEK_API_KEY",
    "XAI_API_KEY",
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GROQ_API_KEY",
    "PROVIDER",
    "MODEL",
    "FAST_MODEL",
    "VOICE_MODEL",
    "VOICE_URL",
    "API_URL",
    "MODELS_URL",
    "OMNICODE_STATUS",
};

pub fn isAllowedKey(key: []const u8) bool {
    for (allowed_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

pub const all_providers = [_]router.Provider{
    .abliteration,
    .openrouter,
    .anthropic,
    .deepseek,
    .xai,
    .openai,
    .gemini,
    .groq,
};

pub fn resolveProvider(token: []const u8) ?router.Provider {
    if (std.meta.stringToEnum(router.Provider, token)) |p| return p;
    if (std.fmt.parseInt(usize, token, 10) catch null) |idx| {
        if (idx >= 1 and idx <= all_providers.len) return all_providers[idx - 1];
    }
    for (all_providers) |p| {
        if (std.ascii.eqlIgnoreCase(@tagName(p), token) or std.ascii.eqlIgnoreCase(p.envKey(), token)) return p;
    }
    return null;
}

/// Resolve a provider name (e.g. "openrouter", "openai") or an explicit allowed env key name.
pub fn resolveKeyName(token: []const u8) ?[]const u8 {
    if (std.meta.stringToEnum(router.Provider, token)) |p| return p.envKey();
    for (allowed_keys) |k| {
        if (std.ascii.eqlIgnoreCase(k, token)) return k;
    }
    return null;
}

pub fn configPath(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("OMNICODE_CONFIG")) |p| if (p.len > 0) return a.dupe(u8, p);
    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) return std.fmt.allocPrint(a, "{s}/omnicode/config.env", .{xdg});
    if (env.get("HOME")) |home| if (home.len > 0) return std.fmt.allocPrint(a, "{s}/.config/omnicode/config.env", .{home});
    return a.dupe(u8, ".omnicode/config.env");
}

/// Load persisted settings into `env` without overwriting variables already set in the process environment.
pub fn loadIntoEnv(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map) !void {
    const path = try configPath(a, env);
    const text = dir.readFileAlloc(io, path, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (!isAllowedKey(key)) continue;
        if (env.get(key) == null) {
            try env.put(key, val);
        }
    }
}

const Entry = struct { key: []const u8, val: []const u8 };

fn readEntries(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) !std.ArrayList(Entry) {
    var list: std.ArrayList(Entry) = .empty;
    const text = dir.readFileAlloc(io, path, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!isAllowedKey(key)) continue;
        try list.append(a, .{ .key = key, .val = val });
    }
    return list;
}

fn writeEntries(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, entries: []const Entry) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try dir.createDirPath(io, parent);
    }
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("# Omnicode configuration (managed by /setup)\n");
    for (entries) |e| {
        try out.writer.print("{s}={s}\n", .{ e.key, e.val });
    }
    const data = try out.toOwnedSlice();
    try @import("storage.zig").writePrivate(io, dir, path, data);
}

pub fn set(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, key: []const u8, value: []const u8) !void {
    if (!isAllowedKey(key)) return error.InvalidConfigKey;
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidConfigValue;
    if (std.mem.eql(u8, key, "API_URL") or std.mem.eql(u8, key, "VOICE_URL") or std.mem.eql(u8, key, "MODELS_URL"))
        try @import("http.zig").validateEndpoint(value);
    const path = try configPath(a, env);
    var entries = try readEntries(a, io, dir, path);
    var replaced = false;
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            e.val = value;
            replaced = true;
            break;
        }
    }
    if (!replaced) try entries.append(a, .{ .key = key, .val = value });
    try writeEntries(a, io, dir, path, entries.items);
    try env.put(key, value);
}

pub fn unset(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, key: []const u8) !void {
    if (!isAllowedKey(key)) return error.InvalidConfigKey;
    const path = try configPath(a, env);
    const entries = try readEntries(a, io, dir, path);
    var kept: std.ArrayList(Entry) = .empty;
    for (entries.items) |e| {
        if (!std.mem.eql(u8, e.key, key)) try kept.append(a, e);
    }
    try writeEntries(a, io, dir, path, kept.items);
    _ = env.swapRemove(key);
}

pub fn maskSecret(val: []const u8, buf: *[32]u8) []const u8 {
    if (val.len == 0) return "(not set)";
    if (val.len <= 8) return "configured (***)";
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ val[0..4], val[val.len - 4 ..] }) catch "configured";
}

pub fn statusReport(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const raw_path = try configPath(a, env);
    const path = try status.shortenHome(a, raw_path, env.get("HOME") orelse "");
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.print("Config file: {s}\nProviders & API keys:\n", .{path});
    inline for (.{
        router.Provider.abliteration,
        router.Provider.openrouter,
        router.Provider.anthropic,
        router.Provider.deepseek,
        router.Provider.xai,
        router.Provider.openai,
        router.Provider.gemini,
        router.Provider.groq,
    }) |p| {
        var mask_buf: [32]u8 = undefined;
        const val = env.get(p.envKey()) orelse "";
        try out.writer.print("  {s:<11} ({s}): {s}\n", .{ @tagName(p), p.envKey(), maskSecret(val, &mask_buf) });
    }
    const route = router.Route.init(env, null, null) catch null;
    const active_provider = if (route) |r| @tagName(r.provider) else (env.get("PROVIDER") orelse "auto");
    const active_model = if (route) |r| r.model else (env.get("MODEL") orelse "auto");
    const fast_model = env.get("FAST_MODEL") orelse "auto";
    const voice_model = env.get("VOICE_MODEL") orelse "auto (cheapest OpenRouter audio model)";
    try out.writer.print(
        \\Settings:
        \\  PROVIDER    = {s}
        \\  MODEL       = {s}
        \\  FAST_MODEL  = {s}
        \\  VOICE_MODEL = {s}
        \\Usage:
        \\  /setup <provider> <api_key>     Save API key (e.g. /setup openrouter sk-or-...)
        \\  /setup set <KEY> <VALUE>        Set PROVIDER, MODEL, FAST_MODEL, VOICE_MODEL, etc.
        \\  /setup unset <provider|KEY>     Remove a saved key or setting
        \\
    , .{ active_provider, active_model, fast_model, voice_model });
    return out.toOwnedSlice();
}

/// Process a `/setup ...` or `--setup ...` argument string and return a user-facing summary message.
pub fn execute(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, rest: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t\r\n");
    if (trimmed.len == 0) return statusReport(a, env);
    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = parts.next() orelse return statusReport(a, env);
    if (std.mem.eql(u8, first, "unset") or std.mem.eql(u8, first, "clear")) {
        const target = parts.next() orelse return error.InvalidSetupCommand;
        if (parts.next() != null) return error.InvalidSetupCommand;
        const key = resolveKeyName(target) orelse return error.InvalidConfigKey;
        try unset(a, io, dir, env, key);
        return std.fmt.allocPrint(a, "Cleared {s} from session and config.", .{key});
    }
    if (std.mem.eql(u8, first, "set")) {
        const raw_key = parts.next() orelse return error.InvalidSetupCommand;
        const val = std.mem.trim(u8, parts.rest(), " \t");
        if (val.len == 0) return error.InvalidSetupCommand;
        const key = resolveKeyName(raw_key) orelse return error.InvalidConfigKey;
        if (std.mem.eql(u8, key, "PROVIDER") and std.meta.stringToEnum(router.Provider, val) == null) return error.UnknownProvider;
        try set(a, io, dir, env, key, val);
        var mask_buf: [32]u8 = undefined;
        const shown = if (std.mem.endsWith(u8, key, "_KEY")) maskSecret(val, &mask_buf) else val;
        return std.fmt.allocPrint(a, "Saved {s} = {s}", .{ key, shown });
    }
    // `/setup <provider_or_key> <value>`
    const val = std.mem.trim(u8, parts.rest(), " \t");
    if (val.len == 0) return error.InvalidSetupCommand;
    const key = resolveKeyName(first) orelse return error.InvalidConfigKey;
    try set(a, io, dir, env, key, val);
    if (std.meta.stringToEnum(router.Provider, first)) |p| {
        if (env.get("PROVIDER") == null) try set(a, io, dir, env, "PROVIDER", @tagName(p));
    }
    var mask_buf: [32]u8 = undefined;
    const shown = if (std.mem.endsWith(u8, key, "_KEY")) maskSecret(val, &mask_buf) else val;
    return std.fmt.allocPrint(a, "Saved {s} ({s}).", .{ key, shown });
}

pub fn providersReport(a: std.mem.Allocator, env: *const std.process.Environ.Map, active_override: ?router.Provider) ![]const u8 {
    const raw_path = try configPath(a, env);
    const path = try status.shortenHome(a, raw_path, env.get("HOME") orelse "");
    const detected = router.Route.init(env, null, null) catch null;
    const active: ?router.Provider = active_override orelse if (detected) |r| r.provider else null;
    const custom_url = env.get("API_URL") orelse "";
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.print("Config file: {s}\nProviders (* = active):\n", .{path});
    for (all_providers, 1..) |p, idx| {
        var mask_buf: [32]u8 = undefined;
        const val = env.get(p.envKey()) orelse "";
        const mark: u8 = if (active != null and active.? == p) '*' else ' ';
        const strong = p.defaultModel(true);
        const fast = p.defaultModel(false);
        const models_buf = if (std.mem.eql(u8, strong, fast))
            try std.fmt.allocPrint(a, "{s}", .{strong})
        else
            try std.fmt.allocPrint(a, "{s} / {s}", .{ strong, fast });
        const url = if (custom_url.len > 0 and active != null and active.? == p) custom_url else p.defaultUrl();
        try out.writer.print("  {c} {d:>2}. {s:<12} key: {s:<14} [{s}]  models: {s}  url: {s}\n", .{
            mark, idx, @tagName(p), maskSecret(val, &mask_buf), p.envKey(), models_buf, url,
        });
    }
    if (custom_url.len > 0) {
        try out.writer.print("Custom API_URL override: {s}\n", .{custom_url});
    }
    try out.writer.writeAll(
        \\Usage:
        \\  /providers                       List providers, key status, default models, and endpoints
        \\  /providers <N|provider>          Switch active provider (e.g. /providers 2 or /providers openrouter)
        \\  /providers <provider> <api_key>  Save API key and activate provider (e.g. /providers deepseek sk-...)
        \\  /providers url <url|default>     Set or reset custom API_URL endpoint
        \\  /providers unset <provider>      Remove saved API key for a provider
        \\
    );
    return out.toOwnedSlice();
}

/// Process a `/providers ...` or `--providers ...` command and return a user-facing summary message.
pub fn executeProviders(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, active_override: ?router.Provider, rest: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return providersReport(a, env, active_override);
    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = parts.next() orelse return providersReport(a, env, active_override);
    if (std.mem.eql(u8, first, "unset") or std.mem.eql(u8, first, "clear") or std.mem.eql(u8, first, "remove")) {
        const target = parts.next() orelse return error.InvalidProvidersCommand;
        if (parts.next() != null) return error.InvalidProvidersCommand;
        const p = resolveProvider(target) orelse return error.UnknownProvider;
        try unset(a, io, dir, env, p.envKey());
        if (std.mem.eql(u8, env.get("PROVIDER") orelse "", @tagName(p))) {
            try unset(a, io, dir, env, "PROVIDER");
        }
        return std.fmt.allocPrint(a, "Cleared API key for {s} ({s}).", .{ @tagName(p), p.envKey() });
    }
    if (std.mem.eql(u8, first, "url")) {
        const url = std.mem.trim(u8, parts.rest(), " \t");
        if (url.len == 0) return error.InvalidProvidersCommand;
        if (std.mem.eql(u8, url, "default") or std.mem.eql(u8, url, "reset") or std.mem.eql(u8, url, "clear")) {
            try unset(a, io, dir, env, "API_URL");
            return a.dupe(u8, "Reset API_URL to provider default.");
        }
        try set(a, io, dir, env, "API_URL", url);
        return std.fmt.allocPrint(a, "Saved API_URL = {s}", .{url});
    }
    const is_explicit_verb = std.mem.eql(u8, first, "use") or std.mem.eql(u8, first, "select") or std.mem.eql(u8, first, "set");
    const target_tok = if (is_explicit_verb) (parts.next() orelse return error.InvalidProvidersCommand) else first;
    const p = resolveProvider(target_tok) orelse return error.UnknownProvider;
    const remainder = std.mem.trim(u8, parts.rest(), " \t");
    if (remainder.len == 0) {
        if (std.mem.eql(u8, first, "set")) return error.InvalidProvidersCommand;
        try set(a, io, dir, env, "PROVIDER", @tagName(p));
        const key_val: []const u8 = env.get(p.envKey()) orelse "";
        if (key_val.len > 0) {
            return std.fmt.allocPrint(a, "Active provider set to {s} (default model: {s}).", .{ @tagName(p), p.defaultModel(true) });
        }
        return std.fmt.allocPrint(a, "Active provider set to {s} (note: {s} is not set; run /providers {s} <api_key>).", .{ @tagName(p), p.envKey(), @tagName(p) });
    }
    try set(a, io, dir, env, p.envKey(), remainder);
    try set(a, io, dir, env, "PROVIDER", @tagName(p));
    var mask_buf: [32]u8 = undefined;
    return std.fmt.allocPrint(a, "Configured {s} ({s} = {s}) and set as active provider.", .{ @tagName(p), p.envKey(), maskSecret(remainder, &mask_buf) });
}

test "config persists keys, respects environment precedence, and masks secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_CONFIG", "custom/config.env");
    _ = try execute(a, std.testing.io, tmp.dir, &env, "openrouter sk-or-v1-1234567890abcdef");
    try std.testing.expectEqualStrings("sk-or-v1-1234567890abcdef", env.get("OPENROUTER_API_KEY").?);
    try std.testing.expectEqualStrings("openrouter", env.get("PROVIDER").?);
    const report = try execute(a, std.testing.io, tmp.dir, &env, "");
    try std.testing.expect(std.mem.indexOf(u8, report, "sk-o...cdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "1234567890") == null);
    _ = try execute(a, std.testing.io, tmp.dir, &env, "set VOICE_MODEL google/gemini-2.0-flash-lite-001");
    try std.testing.expectEqualStrings("google/gemini-2.0-flash-lite-001", env.get("VOICE_MODEL").?);
    // Process environment variable takes precedence over persisted file on loadIntoEnv.
    var fresh_env = std.process.Environ.Map.init(a);
    try fresh_env.put("OMNICODE_CONFIG", "custom/config.env");
    try fresh_env.put("VOICE_MODEL", "override-voice-model");
    try loadIntoEnv(a, std.testing.io, tmp.dir, &fresh_env);
    try std.testing.expectEqualStrings("sk-or-v1-1234567890abcdef", fresh_env.get("OPENROUTER_API_KEY").?);
    try std.testing.expectEqualStrings("override-voice-model", fresh_env.get("VOICE_MODEL").?);
    _ = try execute(a, std.testing.io, tmp.dir, &fresh_env, "unset openrouter");
    try std.testing.expect(fresh_env.get("OPENROUTER_API_KEY") == null);
    try std.testing.expectError(error.InvalidConfigKey, execute(a, std.testing.io, tmp.dir, &fresh_env, "set BOGUS_KEY 1"));
    const prov_msg = try executeProviders(a, std.testing.io, tmp.dir, &fresh_env, null, "deepseek sk-ds-1234567890abcdef");
    try std.testing.expect(std.mem.indexOf(u8, prov_msg, "Configured deepseek") != null);
    try std.testing.expectEqualStrings("deepseek", fresh_env.get("PROVIDER").?);
    try std.testing.expectEqualStrings("sk-ds-1234567890abcdef", fresh_env.get("DEEPSEEK_API_KEY").?);
    _ = try executeProviders(a, std.testing.io, tmp.dir, &fresh_env, .deepseek, "2");
    try std.testing.expectEqualStrings("openrouter", fresh_env.get("PROVIDER").?);
    const list_out = try executeProviders(a, std.testing.io, tmp.dir, &fresh_env, .openrouter, "");
    try std.testing.expect(std.mem.indexOf(u8, list_out, "*  2. openrouter") != null);
}
