const std = @import("std");
const j = @import("json.zig");
const Io = std.Io;

/// Last tool result only: replacement bounds memory independently of conversation history.
pub const Details = struct {
    bytes: [64 * 1024]u8 = undefined,
    len: usize = 0,
    present: bool = false,
    truncated: bool = false,

    fn save(self: *Details, text: []const u8) void {
        self.len = @min(text.len, self.bytes.len);
        while (self.len > 0 and !std.unicode.utf8ValidateSlice(text[0..self.len])) self.len -= 1;
        @memcpy(self.bytes[0..self.len], text[0..self.len]);
        self.present = true;
        self.truncated = self.len < text.len;
    }
};

/// An append-only transcript: keep native terminal scrolling and copy/paste.
pub const Ui = struct {
    out: *Io.Writer,
    io: Io,
    color: bool = false,
    interactive: bool = false,
    verbose: bool = false,
    width: usize = 80,
    details: ?*Details = null,

    pub fn init(out: *Io.Writer, io: Io, env: *const std.process.Environ.Map) Ui {
        const tty = Io.File.stdout().isTty(io) catch false;
        const dumb = std.mem.eql(u8, env.get("TERM") orelse "", "dumb");
        return .{
            .out = out,
            .io = io,
            .interactive = tty and !dumb and env.get("NO_COLOR") == null,
            .color = tty and !dumb and env.get("NO_COLOR") == null,
            .width = std.math.clamp(std.fmt.parseInt(usize, env.get("COLUMNS") orelse "80", 10) catch 80, 40, 160),
        };
    }

    fn style(ui: Ui, code: []const u8) !void {
        if (ui.color) try ui.out.writeAll(code);
    }

    // Never let model/file/command text emit terminal controls; truncate on UTF-8 boundaries.
    fn safe(ui: Ui, value: []const u8, max: usize) !void {
        const view = std.unicode.Utf8View.init(value) catch {
            try ui.out.writeAll("[non-UTF-8 text]");
            return;
        };
        var it = view.iterator();
        var n: usize = 0;
        while (it.nextCodepointSlice()) |bytes| {
            const cp = try std.unicode.utf8Decode(bytes);
            if (n >= max) {
                try ui.out.writeAll("...");
                break;
            }
            if (cp < 32 or (cp >= 127 and cp <= 159)) {
                try ui.out.writeByte(if (cp == '\t' or cp == '\n' or cp == '\r') ' ' else '?');
            } else try ui.out.writeAll(bytes);
            n += 1;
        }
    }

    pub fn banner(ui: Ui, provider: []const u8, cwd: []const u8) !void {
        try ui.style("\x1b[1m");
        try ui.out.writeAll("\n  omnicode\n");
        try ui.style("\x1b[0m");
        try ui.out.writeAll("  ");
        try ui.safe(cwd, ui.width - 4);
        try ui.out.writeAll("\n  ");
        try ui.safe(provider, 30);
        try ui.out.writeAll(" · automatic task routing\n\n  /help commands  /model routing  /skills instructions\n\n");
    }

    pub fn prompt(ui: Ui) !void {
        try ui.style("\x1b[1m");
        try ui.out.writeAll("› ");
        try ui.style("\x1b[0m");
        try ui.out.flush();
    }

    pub fn note(ui: Ui, text: []const u8) !void {
        try ui.style("\x1b[2m");
        try ui.out.writeAll("  ");
        try ui.safe(text, ui.width - 4);
        try ui.style("\x1b[0m");
        try ui.out.writeByte('\n');
    }

    pub fn route(ui: Ui, provider: []const u8, model: []const u8) !void {
        try ui.style("\x1b[2m");
        try ui.out.writeAll("\n[");
        try ui.safe(provider, 24);
        try ui.out.writeAll(" / ");
        try ui.safe(model, 120);
        try ui.out.writeAll("]\n");
        try ui.style("\x1b[0m");
        try ui.out.flush();
    }

    /// Only this task writes to the terminal; the worker owns network/tool I/O.
    pub fn work(ui: Ui, label: []const u8, comptime function: anytype, args: anytype) anyerror!@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
        if (!ui.interactive) {
            if (!std.mem.eql(u8, label, "Running tool...")) try ui.note(label);
            try ui.out.flush();
            return @call(.auto, function, args);
        }
        const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
        const Event = union(enum) { done: Result, tick: Io.Cancelable!void };
        var buffer: [2]Event = undefined;
        var select = Io.Select(Event).init(ui.io, &buffer);
        defer select.cancelDiscard();
        defer {
            ui.out.writeAll("\r\x1b[2K") catch {};
            ui.out.flush() catch {};
        }
        try select.concurrent(.done, function, args);
        const start = Io.Clock.awake.now(ui.io);
        var frame: usize = 0;
        while (true) : (frame += 1) {
            try ui.out.print("\r\x1b[2K  {c} {s} · {d}s", .{ "|/-\\"[frame % 4], label, start.durationTo(Io.Clock.awake.now(ui.io)).toSeconds() });
            try ui.out.flush();
            try select.concurrent(.tick, Io.sleep, .{ ui.io, Io.Duration.fromMilliseconds(100), .awake });
            switch (try select.await()) {
                .done => |result| return result,
                .tick => |result| try result,
            }
        }
    }

    pub fn skills(ui: Ui, text: []const u8) !void {
        var list = ui;
        list.verbose = true;
        try list.preview(if (text.len == 0) "No skills yet. Add .omnicode/skills/<name>/SKILL.md" else text, "");
    }

    pub fn message(ui: Ui, text: []const u8) !void {
        try ui.style("\x1b[1m");
        try ui.out.writeAll("\n● Assistant\n");
        try ui.style("\x1b[0m");
        var lines = std.mem.splitScalar(u8, text, '\n');
        var fence: usize = 0;
        while (lines.next()) |line| {
            try ui.out.writeAll("  ");
            var body = line;
            var ticks: usize = 0;
            while (ticks < line.len and line[ticks] == '`') : (ticks += 1) {}
            if (ticks >= 3 and (fence == 0 or (ticks >= fence and std.mem.trim(u8, line[ticks..], " \t").len == 0))) {
                fence = if (fence == 0) ticks else 0;
                try ui.style("\x1b[2m");
            } else if (fence == 0) {
                var hashes: usize = 0;
                while (hashes < line.len and line[hashes] == '#') : (hashes += 1) {}
                if (hashes > 0 and hashes <= 6 and hashes < line.len and line[hashes] == ' ') {
                    try ui.style("\x1b[1m");
                    if (ui.color) body = line[hashes + 1 ..];
                }
            }
            try ui.safe(body, std.math.maxInt(usize));
            try ui.style("\x1b[0m");
            try ui.out.writeByte('\n');
        }
    }

    pub fn preview(ui: Ui, text: []const u8, prefix: []const u8) !void {
        const trimmed = std.mem.trimEnd(u8, text, "\n");
        if (trimmed.len == 0) {
            try ui.out.writeAll("    (empty)\n");
            return;
        }
        const count = std.mem.count(u8, trimmed, "\n") + 1;
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (!ui.verbose and count > 5 and n >= 3 and n < count - 2) {
                if (n == 3) try ui.out.print("    ... {d} lines hidden (/details or /verbose on)\n", .{count - 5});
                continue;
            }
            try ui.out.writeAll("    ");
            try ui.out.writeAll(prefix);
            try ui.safe(line, if (ui.verbose) std.math.maxInt(usize) else ui.width - 10);
            try ui.out.writeByte('\n');
        }
    }

    pub fn toolStart(ui: Ui, name: []const u8, args: j.Value) !void {
        const key = if (std.mem.eql(u8, name, "bash")) "cmd" else if (std.mem.eql(u8, name, "skill")) "name" else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep")) "pat" else "path";
        try ui.style("\x1b[1m");
        try ui.out.writeAll("• ");
        try ui.safe(name, 24);
        try ui.style("\x1b[0m");
        try ui.out.writeAll("  ");
        try ui.safe(j.str(args, key) catch "(invalid arguments)", ui.width - 16);
        if (std.mem.eql(u8, key, "pat")) {
            try ui.out.writeAll(" in ");
            try ui.safe(j.optional(args, "path", ".") catch "?", 40);
        }
        try ui.out.writeByte('\n');
        try ui.out.flush();
    }

    pub fn toolEnd(ui: Ui, name: []const u8, args: j.Value, result: []const u8, failed: bool, start: Io.Timestamp) !void {
        if (ui.details) |details| details.save(result);
        try ui.style(if (failed) "\x1b[31m" else "\x1b[2m");
        try ui.out.print("  {s} · ", .{if (failed) "✗ Failed" else "✓ Done"});
        try ui.elapsed(start);
        try ui.out.writeByte('\n');
        try ui.style("\x1b[0m");
        if (!failed and std.mem.eql(u8, name, "edit")) {
            try ui.style("\x1b[31m");
            try ui.preview(try j.str(args, "old"), "- ");
            try ui.style("\x1b[32m");
            try ui.preview(try j.str(args, "new"), "+ ");
            try ui.style("\x1b[0m");
        } else if (!failed and std.mem.eql(u8, name, "write")) {
            try ui.out.print("    {d} bytes written\n", .{(try j.str(args, "content")).len});
        } else try ui.preview(result, "");
        try ui.out.flush();
    }

    pub fn showDetails(ui: Ui) !void {
        const details = ui.details orelse return ui.note("No retained tool output.");
        if (!details.present) return ui.note("No retained tool output.");
        try ui.note("Last tool result (replaced by the next tool call):");
        var full = ui;
        full.verbose = true;
        try full.preview(details.bytes[0..details.len], "");
        if (details.truncated) try ui.note("Result exceeds 64 KiB; retained prefix only.");
    }

    pub fn elapsed(ui: Ui, start: Io.Timestamp) !void {
        const ms = start.durationTo(Io.Clock.awake.now(ui.io)).toMilliseconds();
        if (ms < 1000) try ui.out.print("{d}ms", .{ms}) else try ui.out.print("{d}.{d}s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100) });
    }

    pub fn errorMessage(ui: Ui, err: anyerror) !void {
        try ui.style("\x1b[31m");
        try ui.out.print("\n✗ {s}\n", .{@errorName(err)});
        try ui.style("\x1b[0m");
        const hint = switch (err) {
            error.MissingApiKey => "Set OPENROUTER_API_KEY or ANTHROPIC_API_KEY for your selected provider.",
            error.Timeout => "The operation timed out. Check connectivity or narrow the task.",
            error.HistoryLimit, error.TurnLimit => "Conversation limit reached. Start a smaller task.",
            error.IncompleteResponse => "Model response was incomplete; no tools in that response were run.",
            else => "Use /help for commands and check your provider/model configuration.",
        };
        try ui.out.print("  {s}\n", .{hint});
    }
};

test "previews keep head and tail, preserve UTF-8, and neutralize terminal escapes" {
    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    const ui: Ui = .{ .out = &writer, .io = std.testing.io, .width = 40 };
    try ui.preview("first\n2\n3\n4\n5\n6\nlast", "");
    try ui.preview("雪\x1b[2J\rhidden", "");
    try ui.safe("é😊", 1);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "2 lines hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 27) == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.endsWith(u8, text, "é..."));
}

test "details bound memory, truncate UTF-8 safely, and evict the previous result" {
    var details: Details = .{};
    var text: [64 * 1024 + 3]u8 = undefined;
    @memset(&text, 'x');
    @memcpy(text[65535..65538], "雪");
    details.save(&text);
    try std.testing.expectEqual(65535, details.len);
    try std.testing.expect(details.truncated);
    details.save("replacement");
    try std.testing.expectEqualStrings("replacement", details.bytes[0..details.len]);
    try std.testing.expect(!details.truncated);
}

test "Markdown headings respect fences and plain output preserves the source" {
    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    var ui: Ui = .{ .out = &writer, .io = std.testing.io, .color = true };
    const source = "# Title\n```zig\n# literal\n```\n## Next";
    try ui.message(source);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[1mTitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "  # literal") != null);
    writer.end = 0;
    ui.color = false;
    try ui.message(source);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "  # Title\n") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, writer.buffered(), 27) == null);
}
