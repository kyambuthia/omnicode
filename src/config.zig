const std = @import("std");
const Io = std.Io;
const router = @import("router.zig");
const status = @import("status.zig");

pub const allowed_keys = [_][]const u8{
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
    const file = try dir.createFile(io, path, .{ .truncate = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

pub fn set(a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, key: []const u8, value: []const u8) !void {
    if (!isAllowedKey(key)) return error.InvalidConfigKey;
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidConfigValue;
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
}
