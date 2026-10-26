const std = @import("std");
const Io = std.Io;
const Ui = @import("ui.zig").Ui;
const ModelMenu = @import("catalog.zig").ModelMenu;
const config = @import("config.zig");

/// Select a displayed model with arrow keys. Null means the user canceled.
pub fn pickModel(io: Io, ui: Ui, menu: *const ModelMenu, current: usize) !?usize {
    if (menu.count == 0 or !ui.interactive or !(Io.File.stdin().isTty(io) catch false)) return null;
    const original = try std.posix.tcgetattr(0);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.iflag.ICRNL = false;
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .NOW, raw);
    defer std.posix.tcsetattr(0, .NOW, original) catch {};
    var selected = if (current >= 1 and current <= menu.count) current else 1;
    var escape: u8 = 0;
    try drawModelChoice(ui, menu, selected);
    while (true) {
        if (escape != 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN }};
            if (try std.posix.poll(&fds, 100) == 0) {
                try ui.out.writeAll("\r\x1b[2KModel selection canceled.\n");
                return null;
            }
        }
        var byte: [1]u8 = undefined;
        if (try Io.File.stdin().readStreaming(io, &.{&byte}) == 0) return null;
        const c = byte[0];
        if (escape == 1) {
            if (c == '[' or c == 'O') {
                escape = 2;
                continue;
            }
            escape = 0;
            try ui.out.writeAll("\r\x1b[2KModel selection canceled.\n");
            return null;
        }
        if (escape == 2) {
            escape = 0;
            if (c == 'A') selected = if (selected == 1) menu.count else selected - 1 else if (c == 'B') selected = if (selected == menu.count) 1 else selected + 1;
            try drawModelChoice(ui, menu, selected);
            continue;
        }
        switch (c) {
            27 => escape = 1,
            3, 4 => {
                try ui.out.writeAll("\r\x1b[2KModel selection canceled.\n");
                return null;
            },
            '\r', '\n' => {
                try ui.out.writeAll("\r\x1b[2K");
                try ui.out.flush();
                return selected;
            },
            else => {},
        }
    }
}

fn drawModelChoice(ui: Ui, menu: *const ModelMenu, selected: usize) !void {
    const choice = menu.get(selected).?;
    try ui.out.print("\r\x1b[2K↑/↓ choose · Enter select · Esc cancel: {d}/{d} {s}/", .{
        selected, menu.count, @tagName(choice.provider),
    });
    try ui.safe(choice.model, 120);
    try ui.out.flush();
}

/// A bounded append/backspace composer with up/down history. Raw mode belongs only to this read call.
pub const Input = struct {
    bytes: [16 * 1024]u8 = undefined,
    history: [32][1024]u8 = undefined,
    lengths: [32]usize = @splat(0),
    count: usize = 0,
    empty_interrupt: bool = false,

    pub fn record(self: *Input, entry: []const u8) void {
        if (entry.len == 0 or entry.len > self.history[0].len or
            std.mem.indexOfScalar(u8, entry, '\n') != null or !std.unicode.utf8ValidateSlice(entry)) return;
        if (std.mem.startsWith(u8, entry, "/secrets") or std.mem.startsWith(u8, entry, "/setup") or std.mem.startsWith(u8, entry, "/provider")) return;
        if (self.count > 0) {
            const prev = (self.count - 1) % self.history.len;
            if (std.mem.eql(u8, self.history[prev][0..self.lengths[prev]], entry)) return;
        }
        const slot = self.count % self.history.len;
        const len = entry.len;
        @memcpy(self.history[slot][0..len], entry[0..len]);
        self.lengths[slot] = len;
        self.count += 1;
    }

    /// Redact complete entries before applying the fixed history capacity.
    pub fn redactHistory(self: *Input, secrets: *const @import("secrets.zig").Secrets, env: *const std.process.Environ.Map) !void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        for (0..@min(self.count, self.history.len)) |slot| {
            const clean = try secrets.scrub(scratch.allocator(), self.history[slot][0..self.lengths[slot]], env);
            if (clean.len > self.history[slot].len) {
                self.lengths[slot] = 0;
                continue;
            }
            if (clean.ptr != self.history[slot][0..].ptr)
                @memcpy(self.history[slot][0..clean.len], clean);
            self.lengths[slot] = clean.len;
        }
    }

    pub fn getHistory(self: *const Input, index: usize) []const u8 {
        const slot = index % self.history.len;
        return self.history[slot][0..self.lengths[slot]];
    }

    // Consume the entire rejected line so the next command remains readable.
    fn readPlain(self: *Input, reader: *Io.Reader) !?[]const u8 {
        var n: usize = 0;
        var overflow = false;
        while (true) {
            const byte = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (overflow) return error.InputTooLong;
                    return if (n == 0) null else self.bytes[0..n];
                },
                else => return err,
            };
            if (byte == '\n') {
                if (overflow) return error.InputTooLong;
                return self.bytes[0..n];
            }
            if (n == self.bytes.len) {
                overflow = true;
            } else {
                self.bytes[n] = byte;
                n += 1;
            }
        }
    }

    pub fn read(self: *Input, io: Io, ui: Ui, plain: *Io.Reader) !?[]const u8 {
        if (!ui.interactive or !(Io.File.stdin().isTty(io) catch false))
            return self.readPlain(plain);
        const original = try std.posix.tcgetattr(0);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@backingInt(std.posix.V.MIN)] = 1;
        raw.cc[@backingInt(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(0, .NOW, raw);
        defer std.posix.tcsetattr(0, .NOW, original) catch {};
        defer {
            ui.out.writeAll("\x1b[?2004l") catch {};
            ui.out.flush() catch {};
        }
        try ui.out.writeAll("\x1b[?2004h");
        try ui.out.flush();
        var n: usize = 0;
        var paste = false;
        var carriage_return = false;
        var overflow = false;
        var sequence: [8]u8 = undefined;
        var pending: usize = 0;
        var cursor = self.count;
        while (true) {
            if (pending != 0) {
                var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN }};
                if (try std.posix.poll(&fds, 100) == 0) {
                    pending = 0;
                    continue;
                }
            }
            var byte: [1]u8 = undefined;
            const count = Io.File.stdin().readStreaming(io, &.{&byte}) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            if (count == 0) return null;
            const c = byte[0];
            if (!paste and c == 3) {
                if (n == 0 and self.empty_interrupt) {
                    self.empty_interrupt = false;
                    try ui.out.writeAll("^C\n");
                    return null;
                }
                if (n == 0) {
                    self.empty_interrupt = true;
                    try ui.out.writeAll("^C (press Ctrl-C again, Ctrl-D, or /exit to quit)\n");
                } else {
                    self.empty_interrupt = false;
                    try ui.out.writeAll("^C\n");
                }
                return error.InputCancelled;
            }
            self.empty_interrupt = false;
            if (pending != 0 or c == 27) {
                if (pending < sequence.len) {
                    sequence[pending] = c;
                    pending += 1;
                } else {
                    pending = sequence.len + 1;
                }
                if (pending == 1 or (pending == 2 and (c == '[' or c == 'O'))) continue;
                if (c == '[' or (c >= 0x20 and c <= 0x3f)) continue;
                const escape = if (pending <= sequence.len) sequence[0..pending] else "";
                if (std.mem.eql(u8, escape, "\x1b[200~")) paste = true;
                if (std.mem.eql(u8, escape, "\x1b[201~")) paste = false;
                const up = std.mem.eql(u8, escape, "\x1b[A") or std.mem.eql(u8, escape, "\x1bOA");
                const down = std.mem.eql(u8, escape, "\x1b[B") or std.mem.eql(u8, escape, "\x1bOB");
                if (!paste and std.mem.indexOfScalar(u8, self.bytes[0..n], '\n') == null and (up or down)) {
                    if (ui.secrets) |secrets| if (ui.env) |env| try self.redactHistory(secrets, env);
                    const oldest = self.count -| self.history.len;
                    if (up and cursor > oldest) {
                        cursor -= 1;
                    } else if (down and cursor < self.count) {
                        cursor += 1;
                    }
                    const item = if (cursor < self.count) self.getHistory(cursor) else "";
                    @memcpy(self.bytes[0..item.len], item);
                    n = item.len;
                    try ui.out.writeAll("\r\x1b[2K");
                    try ui.prompt();
                    try ui.safe(item, std.math.maxInt(usize));
                    try ui.out.flush();
                }
                pending = 0;
                continue;
            }
            if (!paste and c == 4 and n == 0) return null;
            if (!paste and (c == '\r' or c == '\n')) {
                try ui.out.writeByte('\n');
                if (overflow) return error.InputTooLong;
                self.record(std.mem.trim(u8, self.bytes[0..n], " \t\r"));
                return self.bytes[0..n];
            }
            if (!paste and (c == 127 or c == 8)) {
                if (n == 0 or self.bytes[n - 1] == '\n') continue;
                n -= 1;
                while (n > 0 and self.bytes[n] & 0xc0 == 0x80) n -= 1;
                try ui.out.writeAll("\x08 \x08");
            } else if (c >= 32 or (paste and (c == '\n' or c == '\r' or c == '\t'))) {
                if (paste and c == '\n' and carriage_return) {
                    carriage_return = false;
                    continue;
                }
                carriage_return = c == '\r';
                if (n == self.bytes.len) {
                    overflow = true;
                    continue;
                }
                const value: u8 = if (c == '\r') '\n' else c;
                self.bytes[n] = value;
                n += 1;
                const masked = masksCurrentArgument(self.bytes[0..n]);
                if (!masked) {
                    try ui.out.writeByte(value);
                } else if ((value & 0xc0) != 0x80) {
                    try ui.out.writeByte('*');
                }
            }
            try ui.out.flush();
        }
    }
};

const Token = struct { start: usize, end: usize };

fn nextToken(line: []const u8, cursor: *usize) ?Token {
    while (cursor.* < line.len and (line[cursor.*] == ' ' or line[cursor.*] == '\t')) cursor.* += 1;
    if (cursor.* == line.len) return null;
    const start = cursor.*;
    while (cursor.* < line.len and line[cursor.*] != ' ' and line[cursor.*] != '\t') cursor.* += 1;
    return .{ .start = start, .end = cursor.* };
}

fn tokenEquals(line: []const u8, token: Token, value: []const u8) bool {
    return std.mem.eql(u8, line[token.start..token.end], value);
}

fn afterToken(line: []const u8, end: usize) ?usize {
    if (end == line.len or (line[end] != ' ' and line[end] != '\t')) return null;
    var start = end;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    return start;
}

fn masksCurrentArgument(line: []const u8) bool {
    var cursor: usize = 0;
    const command = nextToken(line, &cursor) orelse return false;
    const is_setup = tokenEquals(line, command, "/setup");
    const is_providers = tokenEquals(line, command, "/providers") or tokenEquals(line, command, "/provider");
    const is_secrets = tokenEquals(line, command, "/secrets");
    if (!is_setup and !is_providers and !is_secrets) return false;
    const action = nextToken(line, &cursor) orelse return false;

    if (is_secrets) {
        if (!tokenEquals(line, action, "set")) return false;
        const name = nextToken(line, &cursor) orelse return false;
        const value_start = afterToken(line, name.end) orelse return false;
        return line.len > value_start;
    }

    if (is_setup and tokenEquals(line, action, "set")) {
        const key = nextToken(line, &cursor) orelse return false;
        if (!isSecretKey(line, key)) return false;
        const value_start = afterToken(line, key.end) orelse return false;
        return line.len > value_start;
    }

    if (tokenEquals(line, action, "unset") or tokenEquals(line, action, "clear") or
        tokenEquals(line, action, "remove") or tokenEquals(line, action, "list") or
        (is_providers and tokenEquals(line, action, "url"))) return false;
    if (is_providers and (tokenEquals(line, action, "use") or tokenEquals(line, action, "select") or tokenEquals(line, action, "set"))) {
        const provider = nextToken(line, &cursor) orelse return false;
        if (config.resolveProvider(line[provider.start..provider.end]) == null) return false;
        const value_start = afterToken(line, provider.end) orelse return false;
        return line.len > value_start;
    }

    if (is_providers and config.resolveProvider(line[action.start..action.end]) == null) return false;
    if (is_setup and !isSecretKey(line, action)) return false;
    const value_start = afterToken(line, action.end) orelse return false;
    return line.len > value_start;
}

fn isSecretKey(line: []const u8, token: Token) bool {
    const name = config.resolveKeyName(line[token.start..token.end]) orelse return false;
    return std.mem.endsWith(u8, name, "_KEY");
}

test "input history records unique single-line entries and bounds capacity" {
    var input: Input = .{};
    input.record("first");
    input.record("first");
    input.record("multi\nline");
    input.record("/secrets set DB_PASS secret123");
    input.record("/setup openrouter sk-or-123");
    input.record("second");
    try std.testing.expectEqual(2, input.count);
    try std.testing.expectEqualStrings("first", input.getHistory(0));
    try std.testing.expectEqualStrings("second", input.getHistory(1));
}

test "history redaction survives secret removal and drops oversized replacements" {
    var secrets: @import("secrets.zig").Secrets = .{};
    try secrets.setMemory("TOKEN", "private-token-value");
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var input: Input = .{};
    input.record("remember private-token-value");
    try input.redactHistory(&secrets, &env);
    try std.testing.expect(secrets.unsetMemory("TOKEN"));
    try std.testing.expectEqualStrings("remember [REDACTED:TOKEN]", input.getHistory(0));
    try secrets.setMemory("LONG_SECRET_NAME", "aaaa");
    const full: [1024]u8 = @splat('a');
    input.record(&full);
    try input.redactHistory(&secrets, &env);
    try std.testing.expectEqualStrings("", input.getHistory(1));
}

test "plain input accepts the boundary and drains oversized lines through EOF" {
    var input: Input = .{};
    const full: [16 * 1024]u8 = @splat('x');
    var exact = Io.Reader.fixed(&full);
    try std.testing.expectEqualStrings(&full, (try input.readPlain(&exact)).?);
    try std.testing.expectEqual(null, try input.readPlain(&exact));
    const lines = full ++ "\n" ++ full ++ "x\n/help\n\n" ++ full ++ "x";
    var reader = Io.Reader.fixed(lines);
    try std.testing.expectEqualStrings(&full, (try input.readPlain(&reader)).?);
    try std.testing.expectError(error.InputTooLong, input.readPlain(&reader));
    try std.testing.expectEqualStrings("/help", (try input.readPlain(&reader)).?);
    try std.testing.expectEqualStrings("", (try input.readPlain(&reader)).?);
    try std.testing.expectError(error.InputTooLong, input.readPlain(&reader));
    try std.testing.expectEqual(null, try input.readPlain(&reader));
}

test "history stores complete UTF-8 entries without truncating prompts" {
    var input: Input = .{};
    const prefix: [1023]u8 = @splat('a');
    input.record("keep this");
    input.record(prefix ++ "é");
    try std.testing.expectEqual(1, input.count);
    try std.testing.expectEqualStrings("keep this", input.getHistory(0));
    input.record("invalid\xff");
    try std.testing.expectEqual(1, input.count);
    const exact = @as([1022]u8, @splat('a')) ++ "é";
    input.record(exact);
    try std.testing.expectEqualStrings(exact, input.getHistory(1));
    try std.testing.expect(std.unicode.utf8ValidateSlice(input.getHistory(1)));
    input.record(exact);
    try std.testing.expectEqual(2, input.count);
}
