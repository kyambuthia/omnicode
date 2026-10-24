const std = @import("std");
const Io = std.Io;
const router = @import("router.zig");
const status = @import("status.zig");

pub const max_secrets = 64;
pub const max_name_len = 64;
pub const max_val_len = 512;

pub fn validSecretName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

pub fn secretsPath(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("OMNICODE_SECRETS")) |p| if (p.len > 0) return a.dupe(u8, p);
    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) return std.fmt.allocPrint(a, "{s}/omnicode/secrets.env", .{xdg});
    if (env.get("HOME")) |home| if (home.len > 0) return std.fmt.allocPrint(a, "{s}/.config/omnicode/secrets.env", .{home});
    return a.dupe(u8, ".omnicode/secrets.env");
}

pub const Secrets = struct {
    names: [max_secrets][max_name_len]u8 = undefined,
    name_lens: [max_secrets]usize = @splat(0),
    vals: [max_secrets][max_val_len]u8 = undefined,
    val_lens: [max_secrets]usize = @splat(0),
    count: usize = 0,

    pub fn nameAt(self: *const Secrets, idx: usize) []const u8 {
        return self.names[idx][0..self.name_lens[idx]];
    }

    pub fn valAt(self: *const Secrets, idx: usize) []const u8 {
        return self.vals[idx][0..self.val_lens[idx]];
    }

    pub fn setMemory(self: *Secrets, name: []const u8, value: []const u8) !void {
        if (!validSecretName(name)) return error.InvalidSecretName;
        if (value.len == 0 or value.len > max_val_len or std.mem.indexOfAny(u8, value, "\r\n") != null)
            return error.InvalidSecretValue;
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.nameAt(i), name)) {
                @memcpy(self.vals[i][0..value.len], value);
                self.val_lens[i] = value.len;
                return;
            }
        }
        if (self.count >= max_secrets) return error.TooManySecrets;
        const idx = self.count;
        @memcpy(self.names[idx][0..name.len], name);
        self.name_lens[idx] = name.len;
        @memcpy(self.vals[idx][0..value.len], value);
        self.val_lens[idx] = value.len;
        self.count += 1;
    }

    pub fn unsetMemory(self: *Secrets, name: []const u8) bool {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.nameAt(i), name)) {
                const last = self.count - 1;
                if (i != last) {
                    self.names[i] = self.names[last];
                    self.name_lens[i] = self.name_lens[last];
                    self.vals[i] = self.vals[last];
                    self.val_lens[i] = self.val_lens[last];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn load(self: *Secrets, a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map) !void {
        const path = try secretsPath(a, env);
        const text = dir.readFileAlloc(io, path, a, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        _ = try self.parseLines(text);
    }

    pub fn save(self: *const Secrets, a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *const std.process.Environ.Map) !void {
        const path = try secretsPath(a, env);
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) try dir.createDirPath(io, parent);
        }
        var out: Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("# Omnicode secrets vault (0600, managed by /secrets)\n");
        for (0..self.count) |i| {
            try out.writer.print("{s}={s}\n", .{ self.nameAt(i), self.valAt(i) });
        }
        const data = try out.toOwnedSlice();
        const file = try dir.createFile(io, path, .{ .truncate = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    }

    pub fn parseLines(self: *Secrets, text: []const u8) !usize {
        var added: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line[7..], " \t");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[0..eq], " \t");
            var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
                val = val[1 .. val.len - 1];
            }
            if (!validSecretName(name) or val.len == 0) continue;
            try self.setMemory(name, val);
            added += 1;
        }
        return added;
    }

    /// Populate a child environment map with all stored secrets for subprocess execution.
    pub fn injectEnv(self: *const Secrets, env: *std.process.Environ.Map) !void {
        for (0..self.count) |i| {
            try env.put(self.nameAt(i), self.valAt(i));
        }
    }

    /// Return comma-separated secret names (values omitted) for the system prompt.
    pub fn namesList(self: *const Secrets, a: std.mem.Allocator) ![]const u8 {
        if (self.count == 0) return "";
        var out: Io.Writer.Allocating = .init(a);
        for (0..self.count) |i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(self.nameAt(i));
        }
        return out.toOwnedSlice();
    }

    /// Scrub any occurrence of stored secrets or configured provider API keys from `text`.
    pub fn scrub(self: *const Secrets, a: std.mem.Allocator, text: []const u8, env: ?*const std.process.Environ.Map) ![]const u8 {
        var current = text;
        for (0..self.count) |i| {
            const val = self.valAt(i);
            if (val.len < 4) continue;
            if (std.mem.indexOf(u8, current, val) != null) {
                const tag = try std.fmt.allocPrint(a, "[REDACTED:{s}]", .{self.nameAt(i)});
                current = try std.mem.replaceOwned(u8, a, current, val, tag);
            }
        }
        if (env) |m| {
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
                const key_name = p.envKey();
                if (m.get(key_name)) |val| {
                    if (val.len >= 6 and std.mem.indexOf(u8, current, val) != null) {
                        const tag = try std.fmt.allocPrint(a, "[REDACTED:{s}]", .{key_name});
                        current = try std.mem.replaceOwned(u8, a, current, val, tag);
                    }
                }
            }
        }
        return current;
    }

    pub fn statusReport(self: *const Secrets, a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
        const raw_path = try secretsPath(a, env);
        const path = try status.shortenHome(a, raw_path, env.get("HOME") orelse "");
        var out: Io.Writer.Allocating = .init(a);
        try out.writer.print("Secrets vault: {s} (values hidden from chat & LLM)\n", .{path});
        if (self.count == 0) {
            try out.writer.writeAll("  (no custom secrets stored)\n");
        } else {
            for (0..self.count) |i| {
                try out.writer.print("  {s:<20} [REDACTED · {d} chars]\n", .{ self.nameAt(i), self.valAt(i).len });
            }
        }
        try out.writer.writeAll(
            \\Usage:
            \\  /secrets set <NAME> <VALUE>   Store secret (injected as $NAME in bash; scrubbed from output)
            \\  /secrets unset <NAME>         Remove a stored secret
            \\  /secrets load <file.env>      Import secrets from a .env file without printing values
            \\
        );
        return out.toOwnedSlice();
    }

    pub fn execute(self: *Secrets, a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, rest: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, rest, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return self.statusReport(a, env);
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const sub = parts.next() orelse return self.statusReport(a, env);
        if (std.mem.eql(u8, sub, "unset") or std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "delete")) {
            const name = parts.next() orelse return error.InvalidSecretsCommand;
            if (parts.next() != null) return error.InvalidSecretsCommand;
            if (!self.unsetMemory(name)) return error.SecretNotFound;
            _ = env.swapRemove(name);
            try self.save(a, io, dir, env);
            return std.fmt.allocPrint(a, "Removed secret {s}.", .{name});
        }
        if (std.mem.eql(u8, sub, "load")) {
            const file_path = std.mem.trim(u8, parts.rest(), " \t");
            if (file_path.len == 0) return error.InvalidSecretsCommand;
            const text = try dir.readFileAlloc(io, file_path, a, .limited(64 * 1024));
            const count = try self.parseLines(text);
            try self.injectEnv(@constCast(env));
            try self.save(a, io, dir, env);
            return std.fmt.allocPrint(a, "Loaded {d} secret(s) from {s} (values hidden).", .{ count, file_path });
        }
        const name = if (std.mem.eql(u8, sub, "set") or std.mem.eql(u8, sub, "add"))
            parts.next() orelse return error.InvalidSecretsCommand
        else
            sub;
        const val = std.mem.trim(u8, parts.rest(), " \t");
        if (val.len == 0) return error.InvalidSecretsCommand;
        try self.setMemory(name, val);
        try @constCast(env).put(name, self.valAt(self.count - 1));
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.nameAt(i), name)) {
                try @constCast(env).put(self.nameAt(i), self.valAt(i));
                break;
            }
        }
        try self.save(a, io, dir, env);
        return std.fmt.allocPrint(a, "Stored secret {s} ([REDACTED · {d} chars]).", .{ name, val.len });
    }
};

test "secrets vault stores 0600 file, imports .env, and scrubs values and API keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_SECRETS", "vault/secrets.env");
    try env.put("OPENROUTER_API_KEY", "sk-or-secret-token-999");

    var secrets: Secrets = .{};
    const msg = try secrets.execute(a, std.testing.io, tmp.dir, &env, "set DB_PASSWORD super-secret-pw-123");
    try std.testing.expect(std.mem.indexOf(u8, msg, "super-secret-pw-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "DB_PASSWORD") != null);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.local", .data = "export STRIPE_KEY='rk_live_abcdef12345'\n" });
    _ = try secrets.execute(a, std.testing.io, tmp.dir, &env, "load .env.local");
    try std.testing.expectEqualStrings("DB_PASSWORD, STRIPE_KEY", try secrets.namesList(a));

    const leaked = "connecting with super-secret-pw-123 and rk_live_abcdef12345 and sk-or-secret-token-999";
    const scrubbed = try secrets.scrub(a, leaked, &env);
    try std.testing.expectEqualStrings(
        "connecting with [REDACTED:DB_PASSWORD] and [REDACTED:STRIPE_KEY] and [REDACTED:OPENROUTER_API_KEY]",
        scrubbed,
    );

    var reloaded: Secrets = .{};
    try reloaded.load(a, std.testing.io, tmp.dir, &env);
    try std.testing.expectEqual(2, reloaded.count);
    _ = try reloaded.execute(a, std.testing.io, tmp.dir, &env, "unset DB_PASSWORD");
    try std.testing.expectEqual(1, reloaded.count);
}
