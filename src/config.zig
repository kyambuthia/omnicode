const std = @import("std");
const Io = std.Io;
const router = @import("router.zig");
const status = @import("status.zig");

pub const default_max_turns: usize = 32;
pub const default_max_tool_calls: usize = 256;
pub const default_max_requests_per_minute: usize = 60;

pub fn parseMaxTurns(value: []const u8) !usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidTurnLimit;
    if (count == 0 or count > 256) return error.InvalidTurnLimit;
    return count;
}

pub fn parseMaxToolCalls(value: []const u8) !usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidToolLimit;
    if (count == 0 or count > 4096) return error.InvalidToolLimit;
    return count;
}

/// Zero disables pacing; positive values cap sustained model request starts.
pub fn parseMaxRequestsPerMinute(value: []const u8) !usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRequestRate;
    if (count > 600) return error.InvalidRequestRate;
    return count;
}

const max_file_bytes = 64 * 1024;
const version_prefix = "# Omnicode configuration v";
const header = "# Omnicode configuration v2 (JSON values; managed by /setup)";

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
    "MAX_TURNS",
    "MAX_TOOL_CALLS",
    "MAX_REQUESTS_PER_MINUTE",
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
    return loadForUpdate(a, io, dir, env, null);
}

/// Only an explicit numeric-setting repair may bypass that setting's old range check.
pub fn loadForUpdate(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, repair_key: ?[]const u8) !void {
    const path = try configPath(a, env);
    const entries = try readEntries(a, io, dir, path, repair_key);
    defer clearEntryValues(entries.items);
    var pending = std.process.Environ.Map.init(env.allocator);
    defer {
        for (pending.values()) |value| std.crypto.secureZero(u8, @constCast(value));
        pending.deinit();
    }
    for (entries.items) |entry| {
        if (env.get(entry.key) == null and pending.get(entry.key) == null)
            try pending.put(entry.key, entry.val);
    }
    try env.array_hash_map.ensureUnusedCapacity(env.allocator, pending.count());
    applyPending(env, &pending);
}

const Entry = struct { key: []const u8, val: []const u8 };

fn clearEntryValues(entries: []const Entry) void {
    for (entries) |entry| std.crypto.secureZero(u8, @constCast(entry.val));
}

fn readEntries(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, repair_key: ?[]const u8) !std.ArrayList(Entry) {
    var list: std.ArrayList(Entry) = .empty;
    errdefer clearEntryValues(list.items);
    const text = @import("storage.zig").readRegular(io, dir, path, a, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return err,
    };
    defer std.crypto.secureZero(u8, @constCast(text));
    var json_values = false;
    var headers = std.mem.splitScalar(u8, text, '\n');
    while (headers.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, version_prefix)) {
            if (!std.mem.eql(u8, line, header)) return error.InvalidConfigFile;
            json_values = true;
        }
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var parsed_value: ?[]const u8 = null;
        defer {
            if (parsed_value) |value| std.crypto.secureZero(u8, @constCast(value));
        }
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigFile;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!isAllowedKey(key)) continue;
        if (json_values) {
            val = std.json.parseFromSliceLeaky([]const u8, a, val, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidConfigFile,
            };
            parsed_value = val;
        } else if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.indexOfAny(u8, val, "\x00\r\n") != null) return error.InvalidConfigValue;
        const repairing = if (repair_key) |target| std.mem.eql(u8, key, target) else false;
        if (!repairing) {
            if (std.mem.eql(u8, key, "MAX_TURNS")) _ = try parseMaxTurns(val);
            if (std.mem.eql(u8, key, "MAX_TOOL_CALLS")) _ = try parseMaxToolCalls(val);
            if (std.mem.eql(u8, key, "MAX_REQUESTS_PER_MINUTE")) _ = try parseMaxRequestsPerMinute(val);
        }
        // First entry wins, matching the legacy startup loader.
        var duplicate = false;
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) duplicate = true;
        }
        if (!duplicate) {
            const owned_key = try a.dupe(u8, key);
            const owned_val = try a.dupe(u8, val);
            errdefer std.crypto.secureZero(u8, owned_val);
            try list.append(a, .{ .key = owned_key, .val = owned_val });
        }
    }
    return list;
}

fn writeEntries(a: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, entries: []const Entry) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try dir.createDirPath(io, parent);
    }
    var out: Io.Writer.Allocating = .init(a);
    defer {
        std.crypto.secureZero(u8, out.written());
        out.deinit();
    }
    try out.writer.print("{s}\n", .{header});
    for (entries) |e| {
        try out.writer.print("{s}=", .{e.key});
        try std.json.Stringify.value(e.val, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    const data = try out.toOwnedSlice();
    defer std.crypto.secureZero(u8, @constCast(data));
    if (data.len > max_file_bytes) return error.InvalidConfigValue;
    try @import("storage.zig").writePrivate(io, dir, path, data);
}

pub fn set(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, key: []const u8, value: []const u8) !void {
    if (!isAllowedKey(key)) return error.InvalidConfigKey;
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidConfigValue;
    if (std.mem.eql(u8, key, "API_URL") or std.mem.eql(u8, key, "VOICE_URL") or std.mem.eql(u8, key, "MODELS_URL"))
        try @import("http.zig").validateEndpoint(value);
    if (std.mem.eql(u8, key, "MAX_TURNS")) _ = try parseMaxTurns(value);
    if (std.mem.eql(u8, key, "MAX_TOOL_CALLS")) _ = try parseMaxToolCalls(value);
    if (std.mem.eql(u8, key, "MAX_REQUESTS_PER_MINUTE")) _ = try parseMaxRequestsPerMinute(value);
    const path = try configPath(a, env);
    var entries = try readEntries(a, io, dir, path, key);
    defer {
        clearEntryValues(entries.items);
    }
    var replaced = false;
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            const owned_value = try a.dupe(u8, value);
            std.crypto.secureZero(u8, @constCast(e.val));
            e.val = owned_value;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        const owned_value = try a.dupe(u8, value);
        errdefer std.crypto.secureZero(u8, owned_value);
        try entries.append(a, .{ .key = key, .val = owned_value });
    }
    var pending = std.process.Environ.Map.init(env.allocator);
    defer {
        for (pending.values()) |pending_value| std.crypto.secureZero(u8, @constCast(pending_value));
        pending.deinit();
    }
    try pending.put(key, value);
    try env.array_hash_map.ensureUnusedCapacity(env.allocator, pending.count());
    try writeEntries(a, io, dir, path, entries.items);
    applyPending(env, &pending);
}

// Capacity and owned strings must be prepared before committing persistent state.
fn applyPending(env: *std.process.Environ.Map, pending: *std.process.Environ.Map) void {
    for (pending.keys(), pending.values()) |key, value| {
        clearOwnedSensitiveValue(env, key);
        env.putMove(@constCast(key), @constCast(value)) catch unreachable;
    }
    pending.array_hash_map.clearRetainingCapacity();
}

fn clearOwnedSensitiveValue(env: *std.process.Environ.Map, key: []const u8) void {
    const sensitive = std.mem.endsWith(u8, key, "_KEY") or std.mem.eql(u8, key, "API_URL") or
        std.mem.eql(u8, key, "VOICE_URL") or std.mem.eql(u8, key, "MODELS_URL");
    if (!sensitive) return;
    if (env.get(key)) |old| std.crypto.secureZero(u8, @constCast(old));
}

pub fn unset(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, key: []const u8) !void {
    if (!isAllowedKey(key)) return error.InvalidConfigKey;
    const path = try configPath(a, env);
    const entries = try readEntries(a, io, dir, path, key);
    defer clearEntryValues(entries.items);
    var kept: std.ArrayList(Entry) = .empty;
    for (entries.items) |e| {
        if (!std.mem.eql(u8, e.key, key)) try kept.append(a, e);
    }
    try writeEntries(a, io, dir, path, kept.items);
    clearOwnedSensitiveValue(env, key);
    _ = env.swapRemove(key);
}

pub fn maskSecret(val: []const u8) []const u8 {
    if (val.len == 0) return "(not set)";
    return "configured (***)";
}

fn displayEndpoint(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    if (query + 1 == url.len) return url;
    return std.fmt.allocPrint(a, "{s}?<redacted>", .{url[0..query]});
}

fn displayConfigValue(a: std.mem.Allocator, key: []const u8, value: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, key, "_KEY")) return maskSecret(value);
    if (std.mem.eql(u8, key, "API_URL") or std.mem.eql(u8, key, "VOICE_URL") or std.mem.eql(u8, key, "MODELS_URL"))
        return displayEndpoint(a, value);
    return value;
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
        const val = env.get(p.envKey()) orelse "";
        try out.writer.print("  {s:<11} ({s}): {s}\n", .{ @tagName(p), p.envKey(), maskSecret(val) });
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
        \\  MAX_TURNS   = {s} (1-256 per compaction batch; default 32)
        \\  MAX_TOOL_CALLS = {s} (1-4096 per request, including children; default 256)
        \\  MAX_REQUESTS_PER_MINUTE = {s} (0 disables model pacing; default 60)
        \\Usage:
        \\  /setup <provider> <api_key>     Save API key (e.g. /setup openrouter sk-or-...)
        \\  /setup set <KEY> <VALUE>        Set PROVIDER, MODEL, FAST_MODEL, VOICE_MODEL, etc.
        \\  /setup unset <provider|KEY>     Remove a saved key or setting
        \\
    , .{ active_provider, active_model, fast_model, voice_model, env.get("MAX_TURNS") orelse "32", env.get("MAX_TOOL_CALLS") orelse "256", env.get("MAX_REQUESTS_PER_MINUTE") orelse "60" });
    return out.toOwnedSlice();
}

/// Identify the exact limit targeted by a syntactically complete setup command.
pub fn repairKey(command: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, std.mem.trim(u8, command, " \t\r\n"), " \t");
    const first = parts.next() orelse return null;
    const removing = std.mem.eql(u8, first, "unset") or std.mem.eql(u8, first, "clear");
    const explicit_set = std.mem.eql(u8, first, "set");
    const target = if (removing or explicit_set) parts.next() orelse return null else first;
    if (removing) {
        if (parts.next() != null) return null;
    } else if (std.mem.trim(u8, parts.rest(), " \t").len == 0) return null;
    const key = resolveKeyName(target) orelse return null;
    return if (std.mem.eql(u8, key, "MAX_TURNS") or std.mem.eql(u8, key, "MAX_TOOL_CALLS") or
        std.mem.eql(u8, key, "MAX_REQUESTS_PER_MINUTE")) key else null;
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
        const shown = try displayConfigValue(a, key, val);
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
    const shown = try displayConfigValue(a, key, val);
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
        const val = env.get(p.envKey()) orelse "";
        const mark: u8 = if (active != null and active.? == p) '*' else ' ';
        const strong = p.defaultModel(true);
        const fast = p.defaultModel(false);
        const models_buf = if (std.mem.eql(u8, strong, fast))
            try std.fmt.allocPrint(a, "{s}", .{strong})
        else
            try std.fmt.allocPrint(a, "{s} / {s}", .{ strong, fast });
        const raw_url = if (custom_url.len > 0 and active != null and active.? == p) custom_url else p.defaultUrl();
        const url = try displayEndpoint(a, raw_url);
        try out.writer.print("  {c} {d:>2}. {s:<12} key: {s:<14} [{s}]  models: {s}  url: {s}\n", .{
            mark, idx, @tagName(p), maskSecret(val), p.envKey(), models_buf, url,
        });
    }
    if (custom_url.len > 0) {
        try out.writer.print("Custom API_URL override: {s}\n", .{try displayEndpoint(a, custom_url)});
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
        return std.fmt.allocPrint(a, "Saved API_URL = {s}", .{try displayEndpoint(a, url)});
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
    return std.fmt.allocPrint(a, "Configured {s} ({s} = {s}) and set as active provider.", .{ @tagName(p), p.envKey(), maskSecret(remainder) });
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
    try std.testing.expect(std.mem.indexOf(u8, report, "configured (***)") != null);
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

test "config values survive JSON persistence and legacy migration exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_CONFIG", "config.env");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.env", .data = "# legacy\nMODEL=\"legacy model\"\nMODEL=ignored duplicate\nFAST_MODEL='fast model'\nUNRELATED=ignored\n" });
    for ([_][]const u8{ "  spaced value  ", "\"quoted\"", "'single quotes'", "back\\slash\tvalue", "\x01\x7f\xff", "雪= #value" }) |value| {
        try set(a, std.testing.io, tmp.dir, &env, "OPENAI_API_KEY", value);
        var fresh = std.process.Environ.Map.init(a);
        try fresh.put("OMNICODE_CONFIG", "config.env");
        try loadIntoEnv(a, std.testing.io, tmp.dir, &fresh);
        try std.testing.expectEqualStrings(value, fresh.get("OPENAI_API_KEY").?);
        try std.testing.expectEqualStrings("legacy model", fresh.get("MODEL").?);
        try std.testing.expectEqualStrings("fast model", fresh.get("FAST_MODEL").?);
        try std.testing.expect(fresh.get("UNRELATED") == null);
    }
    try set(a, std.testing.io, tmp.dir, &env, "MODEL", "replacement-model");
    var fresh = std.process.Environ.Map.init(a);
    try fresh.put("OMNICODE_CONFIG", "config.env");
    try loadIntoEnv(a, std.testing.io, tmp.dir, &fresh);
    try std.testing.expectEqualStrings("replacement-model", fresh.get("MODEL").?);
}

test "malformed config loads and failed writes preserve environment and file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_CONFIG", "config.env");
    try env.put("MODEL", "process-model");
    const invalid = [_][]const u8{
        "FAST_MODEL=must-not-load\nmalformed line\n",
        "FAST_MODEL=must-not-load\n# Omnicode configuration v99\n",
        header ++ "\nFAST_MODEL=\"must-not-load\"\nMODEL=invalid-json\n",
        header ++ "\nFAST_MODEL=\"must-not-load\"\nMODEL=\"nul\\u0000value\"\n",
    };
    for (invalid) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = "config.env", .data = data });
        if (loadIntoEnv(a, io, tmp.dir, &env)) |_| return error.TestUnexpectedResult else |_| {}
        try std.testing.expect(env.get("FAST_MODEL") == null);
        try std.testing.expectEqualStrings("process-model", env.get("MODEL").?);
        if (set(a, io, tmp.dir, &env, "MODEL", "new-model")) |_| return error.TestUnexpectedResult else |_| {}
        const saved = try tmp.dir.readFileAlloc(io, "config.env", a, .limited(max_file_bytes));
        try std.testing.expectEqualStrings(data, saved);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "config.env", .data = "MODEL=old-model\n" });
    const oversized: [max_file_bytes]u8 = @splat('x');
    try std.testing.expectError(error.InvalidConfigValue, set(a, io, tmp.dir, &env, "MODEL", &oversized));
    try std.testing.expectError(error.InvalidConfigValue, set(a, io, tmp.dir, &env, "MODEL", "nul\x00value"));
    try std.testing.expectEqualStrings("process-model", env.get("MODEL").?);
    try std.testing.expectEqualStrings("MODEL=old-model\n", try tmp.dir.readFileAlloc(io, "config.env", a, .limited(max_file_bytes)));
}

test "environment allocation failures occur before config writes or partial loads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Sweep every allocation in the environment map while leaving scratch allocations independent.
    for (0..16) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var env = std.process.Environ.Map.init(failing.allocator());
        defer env.deinit();
        try env.put("OMNICODE_CONFIG", "config.env");
        try env.put("MODEL", "old-model");
        try tmp.dir.writeFile(io, .{ .sub_path = "config.env", .data = "MODEL=old-model\n" });
        failing.fail_index = failing.alloc_index + offset;
        if (set(a, io, tmp.dir, &env, "MODEL", "new-model")) |_| {
            try std.testing.expectEqualStrings("new-model", env.get("MODEL").?);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualStrings("old-model", env.get("MODEL").?);
            try std.testing.expectEqualStrings("MODEL=old-model\n", try tmp.dir.readFileAlloc(io, "config.env", a, .limited(max_file_bytes)));
        }
    }
    for (0..20) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var env = std.process.Environ.Map.init(failing.allocator());
        defer env.deinit();
        try env.put("OMNICODE_CONFIG", "config.env");
        try tmp.dir.writeFile(io, .{ .sub_path = "config.env", .data = "MODEL=loaded-model\nFAST_MODEL=loaded-fast\n" });
        failing.fail_index = failing.alloc_index + offset;
        if (loadIntoEnv(a, io, tmp.dir, &env)) |_| {
            try std.testing.expectEqualStrings("loaded-model", env.get("MODEL").?);
            try std.testing.expectEqualStrings("loaded-fast", env.get("FAST_MODEL").?);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(env.get("MODEL") == null);
            try std.testing.expect(env.get("FAST_MODEL") == null);
        }
    }
}

test "turn limit settings are bounded and invalid updates preserve live and saved values" {
    try std.testing.expectEqual(1, try parseMaxTurns("1"));
    try std.testing.expectEqual(256, try parseMaxTurns("256"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_CONFIG", "config.env");
    try set(a, std.testing.io, tmp.dir, &env, "MAX_TURNS", "64");
    const saved = try tmp.dir.readFileAlloc(std.testing.io, "config.env", a, .limited(max_file_bytes));
    for ([_][]const u8{ "0", "257", "-1", "1.5", "forever", "999999999999999999999999999999" }) |invalid| {
        try std.testing.expectError(error.InvalidTurnLimit, set(a, std.testing.io, tmp.dir, &env, "MAX_TURNS", invalid));
        try std.testing.expectEqualStrings("64", env.get("MAX_TURNS").?);
        try std.testing.expectEqualStrings(saved, try tmp.dir.readFileAlloc(std.testing.io, "config.env", a, .limited(max_file_bytes)));
    }
    var fresh = std.process.Environ.Map.init(a);
    try fresh.put("OMNICODE_CONFIG", "config.env");
    try loadIntoEnv(a, std.testing.io, tmp.dir, &fresh);
    try std.testing.expectEqualStrings("64", fresh.get("MAX_TURNS").?);
}

test "config reloads at the exact serialized byte maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_CONFIG", "config.env");
    const value = try a.alloc(u8, max_file_bytes - header.len - 1 - "MODEL=\"\"\n".len);
    @memset(value, 'm');
    try set(a, io, tmp.dir, &env, "MODEL", value);
    const saved = try tmp.dir.readFileAlloc(io, "config.env", a, .limited(max_file_bytes + 1));
    try std.testing.expectEqual(max_file_bytes, saved.len);
    var fresh = std.process.Environ.Map.init(a);
    try fresh.put("OMNICODE_CONFIG", "config.env");
    try loadIntoEnv(a, io, tmp.dir, &fresh);
    try std.testing.expectEqualStrings(value, fresh.get("MODEL").?);
    try std.testing.expectError(error.InvalidConfigValue, set(a, io, tmp.dir, &env, "MODEL", try std.mem.concat(a, u8, &.{ value, "m" })));
    try std.testing.expectEqualStrings(saved, try tmp.dir.readFileAlloc(io, "config.env", a, .limited(max_file_bytes + 1)));
    try tmp.dir.writeFile(io, .{ .sub_path = "config.env", .data = try std.mem.concat(a, u8, &.{ saved, " " }) });
    try std.testing.expectError(error.StreamTooLong, loadIntoEnv(a, io, tmp.dir, &fresh));
    try std.testing.expectEqualStrings(value, fresh.get("MODEL").?);
}

test "tool-call limits persist and invalid replacements preserve saved and live settings" {
    try std.testing.expectEqual(1, try parseMaxToolCalls("1"));
    try std.testing.expectEqual(4096, try parseMaxToolCalls("4096"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_CONFIG", "config.env");
    try set(a, std.testing.io, tmp.dir, &env, "MAX_TOOL_CALLS", "5");
    const saved = try tmp.dir.readFileAlloc(std.testing.io, "config.env", a, .limited(max_file_bytes));
    for ([_][]const u8{ "0", "4097", "-1", "1.5", "invalid", "999999999999999999999999999999" }) |invalid| {
        try std.testing.expectError(error.InvalidToolLimit, set(a, std.testing.io, tmp.dir, &env, "MAX_TOOL_CALLS", invalid));
        try std.testing.expectEqualStrings("5", env.get("MAX_TOOL_CALLS").?);
        try std.testing.expectEqualStrings(saved, try tmp.dir.readFileAlloc(std.testing.io, "config.env", a, .limited(max_file_bytes)));
    }
    var fresh = std.process.Environ.Map.init(a);
    try fresh.put("OMNICODE_CONFIG", "config.env");
    try loadIntoEnv(a, std.testing.io, tmp.dir, &fresh);
    try std.testing.expectEqualStrings("5", fresh.get("MAX_TOOL_CALLS").?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.env", .data = "MAX_TOOL_CALLS=0\n" });
    try std.testing.expectError(error.InvalidToolLimit, loadIntoEnv(a, std.testing.io, tmp.dir, &fresh));
    try std.testing.expectEqualStrings("5", fresh.get("MAX_TOOL_CALLS").?);
}

test "model request pacing setting accepts disable and rejects out-of-range values" {
    try std.testing.expectEqual(@as(usize, 0), try parseMaxRequestsPerMinute("0"));
    try std.testing.expectEqual(@as(usize, 60), try parseMaxRequestsPerMinute("60"));
    try std.testing.expectEqual(@as(usize, 600), try parseMaxRequestsPerMinute("600"));
    for ([_][]const u8{ "", "-1", "601", "abc" }) |invalid| {
        try std.testing.expectError(error.InvalidRequestRate, parseMaxRequestsPerMinute(invalid));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(arena.allocator());
    try env.put("OMNICODE_CONFIG", "config.env");
    try set(arena.allocator(), std.testing.io, tmp.dir, &env, "MAX_REQUESTS_PER_MINUTE", "120");
    try std.testing.expectError(error.InvalidRequestRate, set(arena.allocator(), std.testing.io, tmp.dir, &env, "MAX_REQUESTS_PER_MINUTE", "601"));
    try std.testing.expectEqualStrings("120", env.get("MAX_REQUESTS_PER_MINUTE").?);
}
