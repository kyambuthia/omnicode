const std = @import("std");
const Io = std.Io;
const Ui = @import("ui.zig").Ui;

/// A bounded append/backspace composer with up/down history. Raw mode belongs only to this read call.
pub const Input = struct {
    bytes: [16 * 1024]u8 = undefined,
    history: [32][1024]u8 = undefined,
    lengths: [32]usize = @splat(0),
    count: usize = 0,

    pub fn record(self: *Input, entry: []const u8) void {
        if (entry.len == 0 or std.mem.indexOfScalar(u8, entry, '\n') != null) return;
        if (std.mem.startsWith(u8, entry, "/secrets") or std.mem.startsWith(u8, entry, "/setup")) return;
        if (self.count > 0) {
            const prev = (self.count - 1) % self.history.len;
            if (std.mem.eql(u8, self.history[prev][0..self.lengths[prev]], entry)) return;
        }
        const slot = self.count % self.history.len;
        const len = @min(entry.len, self.history[slot].len);
        @memcpy(self.history[slot][0..len], entry[0..len]);
        self.lengths[slot] = len;
        self.count += 1;
    }

    pub fn getHistory(self: *const Input, index: usize) []const u8 {
        const slot = index % self.history.len;
        return self.history[slot][0..self.lengths[slot]];
    }

    pub fn read(self: *Input, io: Io, ui: Ui, plain: *Io.Reader) !?[]const u8 {
        if (!ui.interactive or !(Io.File.stdin().isTty(io) catch false))
            return plain.takeDelimiter('\n');
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
            var byte: [1]u8 = undefined;
            const count = Io.File.stdin().readStreaming(io, &.{&byte}) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            if (count == 0) return null;
            const c = byte[0];
            if (!paste and c == 3) {
                try ui.out.writeAll("^C\n");
                return error.InputCancelled;
            }
            if (pending != 0 or c == 27) {
                if (pending < sequence.len) {
                    sequence[pending] = c;
                    pending += 1;
                } else {
                    pending = sequence.len + 1;
                }
                if (pending == 1 or (pending == 2 and c == '[')) continue;
                if (c == '[' or (c >= 0x20 and c <= 0x3f)) continue;
                const escape = if (pending <= sequence.len) sequence[0..pending] else "";
                if (std.mem.eql(u8, escape, "\x1b[200~")) paste = true;
                if (std.mem.eql(u8, escape, "\x1b[201~")) paste = false;
                if (!paste and std.mem.indexOfScalar(u8, self.bytes[0..n], '\n') == null and
                    (std.mem.eql(u8, escape, "\x1b[A") or std.mem.eql(u8, escape, "\x1b[B")))
                {
                    const oldest = self.count -| self.history.len;
                    if (std.mem.eql(u8, escape, "\x1b[A") and cursor > oldest) {
                        cursor -= 1;
                    } else if (std.mem.eql(u8, escape, "\x1b[B") and cursor < self.count) {
                        cursor += 1;
                    }
                    const item = if (cursor < self.count) self.getHistory(cursor) else "";
                    @memcpy(self.bytes[0..item.len], item);
                    n = item.len;
                    try ui.out.writeAll("\r\x1b[2K");
                    try ui.prompt();
                    try ui.out.writeAll(item);
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
                try ui.out.writeByte(value);
            }
            try ui.out.flush();
        }
    }
};

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
