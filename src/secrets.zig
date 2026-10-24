const std = @import("std");
const Io = std.Io;
const router = @import("router.zig");
const status = @import("status.zig");

pub const max_secrets = 64;
pub const max_name_len = 64;
pub const max_val_len = 512;
// A full vault can expand sixfold when JSON escapes control bytes.
pub const max_file_bytes = 256 * 1024;
const vault_version_prefix = "# Omnicode secrets vault v";
const vault_header = "# Omnicode secrets vault v2 (0600, JSON values; managed by /secrets)";

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
        if (value.len == 0 or value.len > max_val_len or std.mem.indexOfAny(u8, value, "\x00\r\n") != null)
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
        const text = dir.readFileAlloc(io, path, a, .limited(max_file_bytes)) catch |err| switch (err) {
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
        try out.writer.writeAll(vault_header ++ "\n");
        for (0..self.count) |i| {
            try out.writer.print("{s}=", .{self.nameAt(i)});
            try std.json.Stringify.value(self.valAt(i), .{}, &out.writer);
            try out.writer.writeByte('\n');
        }
        const data = try out.toOwnedSlice();
        try @import("storage.zig").writePrivate(io, dir, path, data);
    }

    pub fn parseLines(self: *Secrets, text: []const u8) !usize {
        var next = self.*;
        const added = try next.parseLinesInto(text);
        self.* = next;
        return added;
    }

    fn parseLinesInto(self: *Secrets, text: []const u8) !usize {
        var json_values = false;
        var headers = std.mem.splitScalar(u8, text, '\n');
        while (headers.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, vault_version_prefix)) {
                if (!std.mem.eql(u8, line, vault_header)) return error.InvalidSecretFile;
                json_values = true;
            }
        }
        var added: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line[7..], " \t");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSecretFile;
            const name = std.mem.trim(u8, line[0..eq], " \t");
            var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (!validSecretName(name)) return error.InvalidSecretName;
            if (json_values) {
                const decoded = std.json.parseFromSlice([]const u8, std.heap.page_allocator, val, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidSecretFile,
                };
                defer decoded.deinit();
                try self.setMemory(name, decoded.value);
                added += 1;
                continue;
            }
            if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
                val = val[1 .. val.len - 1];
            }
            if (val.len == 0) continue;
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
        const Candidate = struct { name: []const u8, value: []const u8 };
        var candidates: [max_secrets + 8]Candidate = undefined;
        var count: usize = 0;
        for (0..self.count) |i| {
            if (self.valAt(i).len < 4 or std.mem.indexOf(u8, text, self.valAt(i)) == null) continue;
            candidates[count] = .{ .name = self.nameAt(i), .value = self.valAt(i) };
            count += 1;
        }
        if (env) |m| {
            inline for (.{ router.Provider.abliteration, router.Provider.openrouter, router.Provider.anthropic, router.Provider.deepseek, router.Provider.xai, router.Provider.openai, router.Provider.gemini, router.Provider.groq }) |p| {
                if (m.get(p.envKey())) |value| {
                    if (value.len >= 6 and std.mem.indexOf(u8, text, value) != null) {
                        candidates[count] = .{ .name = p.envKey(), .value = value };
                        count += 1;
                    }
                }
            }
        }
        if (count == 0) return text;
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var pos: usize = 0;
        while (pos < text.len) {
            var match_len: usize = 0;
            var match_name: []const u8 = "";
            for (candidates[0..count]) |candidate| {
                const val = candidate.value;
                if (val.len > match_len and val[0] == text[pos] and std.mem.startsWith(u8, text[pos..], val)) {
                    match_len = val.len;
                    match_name = candidate.name;
                }
            }
            if (match_len > 0) {
                try out.writer.print("[REDACTED:{s}]", .{match_name});
                pos += match_len;
            } else {
                try out.writer.writeByte(text[pos]);
                pos += 1;
            }
        }
        return out.toOwnedSlice();
    }

    /// Scrub an owned JSON tree without touching structural keys or serialized escapes.
    /// Iterative traversal keeps deeply nested tool arguments off the call stack.
    pub fn scrubJson(self: *const Secrets, a: std.mem.Allocator, root: *@import("json.zig").Value, env: ?*const std.process.Environ.Map) !void {
        var pending: std.ArrayList(*@import("json.zig").Value) = .empty;
        defer pending.deinit(a);
        try pending.append(a, root);
        while (pending.pop()) |value| {
            switch (value.*) {
                .string => |text| value.* = .{ .string = try self.scrub(a, text, env) },
                .array => |*array| for (array.items) |*item| {
                    try pending.append(a, item);
                },
                .object => |*object| for (object.values()) |*item| {
                    try pending.append(a, item);
                },
                else => {},
            }
        }
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

    /// Prepare all environment allocations before saving, then commit without failure.
    fn commit(self: *Secrets, next: *const Secrets, a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, removed: ?[]const u8) !void {
        var pending = std.process.Environ.Map.init(env.allocator);
        defer pending.deinit();
        for (0..next.count) |i| {
            const name = next.nameAt(i);
            const value = next.valAt(i);
            if (env.get(name)) |old| {
                if (std.mem.eql(u8, old, value)) continue;
            }
            try pending.put(name, value);
        }
        try env.array_hash_map.ensureUnusedCapacity(env.allocator, pending.count());
        try next.save(a, io, dir, env);
        for (pending.keys(), pending.values()) |key, value| {
            // Capacity and owned strings were prepared before the filesystem commit.
            env.putMove(@constCast(key), @constCast(value)) catch unreachable;
        }
        pending.array_hash_map.clearRetainingCapacity();
        if (removed) |name| _ = env.swapRemove(name);
        self.* = next.*;
    }

    pub fn execute(self: *Secrets, a: std.mem.Allocator, io: Io, dir: Io.Dir, env: *std.process.Environ.Map, rest: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, rest, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return self.statusReport(a, env);
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const sub = parts.next() orelse return self.statusReport(a, env);
        if (std.mem.eql(u8, sub, "unset") or std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "delete")) {
            const name = parts.next() orelse return error.InvalidSecretsCommand;
            if (parts.next() != null) return error.InvalidSecretsCommand;
            var next = self.*;
            if (!next.unsetMemory(name)) return error.SecretNotFound;
            const message = try std.fmt.allocPrint(a, "Removed secret {s}.", .{name});
            try self.commit(&next, a, io, dir, env, name);
            return message;
        }
        if (std.mem.eql(u8, sub, "load")) {
            const file_path = std.mem.trim(u8, parts.rest(), " \t");
            if (file_path.len == 0) return error.InvalidSecretsCommand;
            try @import("storage.zig").validatePath(file_path);
            const text = try dir.readFileAlloc(io, file_path, a, .limited(max_file_bytes));
            var next = self.*;
            const count = try next.parseLines(text);
            const message = try std.fmt.allocPrint(a, "Loaded {d} secret(s) from {s} (values hidden).", .{ count, file_path });
            try self.commit(&next, a, io, dir, env, null);
            return message;
        }
        const name = if (std.mem.eql(u8, sub, "set") or std.mem.eql(u8, sub, "add"))
            parts.next() orelse return error.InvalidSecretsCommand
        else
            sub;
        const val = std.mem.trim(u8, parts.rest(), " \t");
        if (val.len == 0) return error.InvalidSecretsCommand;
        var next = self.*;
        try next.setMemory(name, val);
        const message = try std.fmt.allocPrint(a, "Stored secret {s} ([REDACTED · {d} chars]).", .{ name, val.len });
        try self.commit(&next, a, io, dir, env, null);
        return message;
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

test "redaction prefers longest original value and never rewrites generated tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var secrets: Secrets = .{};
    try secrets.setMemory("SHORT", "prefix");
    try secrets.setMemory("LONG", "prefix-private-suffix");
    try secrets.setMemory("TAG", "REDACTED");
    var env = std.process.Environ.Map.init(a);
    try env.put("OPENAI_API_KEY", "prefix-provider-key");
    try std.testing.expectEqualStrings(
        "[REDACTED:LONG] [REDACTED:OPENAI_API_KEY] [REDACTED:SHORT] [REDACTED:TAG]",
        try secrets.scrub(a, "prefix-private-suffix prefix-provider-key prefix REDACTED", &env),
    );
    try std.testing.expectEqualStrings("[REDACTED:LONG][REDACTED:LONG]", try secrets.scrub(a, "prefix-private-suffixprefix-private-suffix", null));
    try std.testing.expectEqualStrings("ordinary text", try secrets.scrub(a, "ordinary text", null));
    try std.testing.expectEqualStrings("", try secrets.scrub(a, "", null));
}

test "failed vault commands preserve live secrets and environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_SECRETS", "blocked");
    try env.put("TOKEN", "old-token");
    try tmp.dir.createDir(io, "blocked", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "import.env", .data = "NEW_TOKEN=new-value\n" });
    var secrets: Secrets = .{};
    try secrets.setMemory("TOKEN", "old-token");
    for ([_][]const u8{ "set TOKEN new-token", "set NEW_TOKEN new-value", "unset TOKEN", "load import.env" }) |command| {
        if (secrets.execute(a, io, tmp.dir, &env, command)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
        try std.testing.expectEqual(1, secrets.count);
        try std.testing.expectEqualStrings("old-token", secrets.valAt(0));
        try std.testing.expectEqualStrings("old-token", env.get("TOKEN").?);
        try std.testing.expect(env.get("NEW_TOKEN") == null);
    }
    // Parsing must not partially apply an import when a later value is invalid.
    try env.put("OMNICODE_SECRETS", "working.env");
    const oversized: [max_val_len + 1]u8 = @splat('x');
    const invalid = try std.fmt.allocPrint(a, "NEW_TOKEN=new-value\nTOO_LONG={s}\n", .{&oversized});
    try tmp.dir.writeFile(io, .{ .sub_path = "import.env", .data = invalid });
    try std.testing.expectError(error.InvalidSecretValue, secrets.execute(a, io, tmp.dir, &env, "load import.env"));
    try std.testing.expectEqual(1, secrets.count);
    try std.testing.expect(env.get("NEW_TOKEN") == null);
    _ = try secrets.execute(a, io, tmp.dir, &env, "set TOKEN new-token");
    try std.testing.expectEqualStrings("new-token", env.get("TOKEN").?);
    _ = try secrets.execute(a, io, tmp.dir, &env, "unset TOKEN");
    try std.testing.expectEqual(0, secrets.count);
    try std.testing.expect(env.get("TOKEN") == null);
}

test "JSON redaction handles escaped values and preserves structure" {
    const j = @import("json.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var secrets: Secrets = .{};
    try secrets.setMemory("TOKEN", "quote\"slash\\tail");
    var value = try j.parse(a, try j.encode(a, .{
        .nested = .{ "quote\"slash\\tail", .{ .value = "before quote\"slash\\tail after", .number = 42, .flag = true } },
        .TOKEN = "unchanged",
    }));
    try secrets.scrubJson(a, &value, null);
    const nested = try j.get(value, "nested");
    try std.testing.expectEqualStrings("[REDACTED:TOKEN]", nested.array.items[0].string);
    try std.testing.expectEqualStrings("before [REDACTED:TOKEN] after", try j.str(nested.array.items[1], "value"));
    try std.testing.expectEqual(42, try j.number(nested.array.items[1], "number", 0));
    try std.testing.expect((try j.get(nested.array.items[1], "flag")).bool);
    try std.testing.expectEqualStrings("unchanged", try j.str(value, "TOKEN"));
}

test "vault parsing applies a complete file or leaves memory unchanged" {
    var secrets: Secrets = .{};
    try secrets.setMemory("EXISTING", "old-value");
    const oversized: [max_val_len + 1]u8 = @splat('x');
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invalid = try std.fmt.allocPrint(arena.allocator(), "EXISTING=new-value\nNEW_TOKEN=value\nLONG={s}\n", .{&oversized});
    try std.testing.expectError(error.InvalidSecretValue, secrets.parseLines(invalid));
    try std.testing.expectEqual(1, secrets.count);
    try std.testing.expectEqualStrings("old-value", secrets.valAt(0));
    try std.testing.expectError(error.InvalidSecretValue, secrets.parseLines("NEW_TOKEN=value\nBINARY=prefix\x00suffix\n"));
    try std.testing.expectError(error.InvalidSecretFile, secrets.parseLines("NEW_TOKEN=value\nmalformed\n"));
    try std.testing.expectError(error.InvalidSecretName, secrets.parseLines("NEW_TOKEN=value\nINVALID-NAME=value\n"));
    try std.testing.expectEqual(1, secrets.count);
    try std.testing.expectEqual(1, try secrets.parseLines("# comment\n\nEMPTY=\nexport NEW_TOKEN='new-value'\n"));
    try std.testing.expectEqual(2, secrets.count);
}

test "versioned vault preserves exact values and imports legacy files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_SECRETS", "vault.env");
    var secrets: Secrets = .{};
    const values = [_][]const u8{ "\"literal quotes\"", "'single quotes'", " leading and trailing ", "C:\\tokens\\private", "tab\there", "control\x01value", "binary\xffvalue", "utf8 café", "#hash=equals" };
    for (values, 0..) |value, i| {
        const name = try std.fmt.allocPrint(a, "TOKEN_{d}", .{i});
        try secrets.setMemory(name, value);
    }
    try secrets.save(a, io, tmp.dir, &env);
    var loaded: Secrets = .{};
    try loaded.load(a, io, tmp.dir, &env);
    try std.testing.expectEqual(values.len, loaded.count);
    for (values, 0..) |value, i| try std.testing.expectEqualStrings(value, loaded.valAt(i));
    var legacy: Secrets = .{};
    _ = try legacy.parseLines("# Omnicode secrets vault (0600, managed by /secrets)\nexport TOKEN='\"literal quotes\"'\n");
    try legacy.save(a, io, tmp.dir, &env);
    loaded = .{};
    try loaded.load(a, io, tmp.dir, &env);
    try std.testing.expectEqualStrings("\"literal quotes\"", loaded.valAt(0));
    try std.testing.expectError(error.InvalidSecretFile, loaded.parseLines(vault_header ++ "\nNEW=\"first\"\nBAD=not-json\n"));
    try std.testing.expectEqual(1, loaded.count);
    try std.testing.expectError(error.InvalidSecretFile, loaded.parseLines("# Omnicode secrets vault v99\nTOKEN=value\n"));
}

test "full vault of maximally escaped values can be saved and reloaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(a);
    try env.put("OMNICODE_SECRETS", "vault.env");
    var secrets: Secrets = .{};
    const value: [max_val_len]u8 = @splat(1);
    for (0..max_secrets) |i| {
        const name = try std.fmt.allocPrint(a, "TOKEN_{d}", .{i});
        try secrets.setMemory(name, &value);
    }
    try secrets.save(a, io, tmp.dir, &env);
    const encoded = try tmp.dir.readFileAlloc(io, "vault.env", a, .limited(max_file_bytes));
    try std.testing.expect(encoded.len > 64 * 1024);
    var loaded: Secrets = .{};
    try loaded.load(a, io, tmp.dir, &env);
    try std.testing.expectEqual(max_secrets, loaded.count);
    for (0..max_secrets) |i| try std.testing.expectEqualStrings(&value, loaded.valAt(i));
}
