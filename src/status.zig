const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Status line state shared by the REPL and the agent; it never affects model input.
pub const Status = struct {
    mode: Mode = .inline_line,
    clock: Clock = .{},
    home: []const u8 = "",
    model_bytes: [160]u8 = undefined,
    model_len: usize = 0,

    pub const Mode = enum { inline_line, pinned, title, off };

    pub fn parseMode(name: []const u8) ?Mode {
        if (std.mem.eql(u8, name, "inline")) return .inline_line;
        if (std.mem.eql(u8, name, "pinned")) return .pinned;
        if (std.mem.eql(u8, name, "title")) return .title;
        if (std.mem.eql(u8, name, "off")) return .off;
        return null;
    }

    pub fn modeName(mode: Mode) []const u8 {
        return switch (mode) {
            .inline_line => "inline",
            .pinned => "pinned",
            .title => "title",
            .off => "off",
        };
    }

    /// Record the model actually selected for the latest turn (bounded copy).
    pub fn setModel(self: *Status, model: []const u8) void {
        var len = @min(model.len, self.model_bytes.len);
        while (len > 0 and !std.unicode.utf8ValidateSlice(model[0..len])) len -= 1;
        @memcpy(self.model_bytes[0..len], model[0..len]);
        self.model_len = len;
    }

    pub fn lastModel(self: *const Status) []const u8 {
        return self.model_bytes[0..self.model_len];
    }
};

/// Local wall-clock formatting from TZif data; UTC is labeled when no zone is available.
pub const Clock = struct {
    offsets: []const Change = &.{},
    fixed: ?i32 = null,

    const Change = struct { at: i64, offset: i32 };

    pub fn load(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) Clock {
        var name = env.get("TZ") orelse "/etc/localtime";
        if (name.len > 0 and name[0] == ':') name = name[1..];
        if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return .{};
        const path = if (name[0] == '/') name else std.fmt.allocPrint(a, "/usr/share/zoneinfo/{s}", .{name}) catch return .{};
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(512 * 1024)) catch return .{};
        return parse(a, bytes) catch .{};
    }

    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Clock {
        var reader: Io.Reader = .fixed(bytes);
        var tz = try std.tz.Tz.parse(a, &reader);
        defer tz.deinit();
        if (tz.timetypes.len == 0) return error.Malformed;
        if (tz.transitions.len == 0) return .{ .fixed = tz.timetypes[0].offset };
        const changes = try a.alloc(Change, tz.transitions.len);
        for (tz.transitions, changes) |t, *c| c.* = .{ .at = t.ts, .offset = t.timetype.offset };
        return .{ .offsets = changes, .fixed = tz.timetypes[0].offset };
    }

    pub fn offsetAt(self: Clock, seconds: i64) ?i32 {
        var offset = self.fixed orelse return null;
        for (self.offsets) |change| {
            if (change.at > seconds) break;
            offset = change.offset;
        }
        return offset;
    }

    /// "HH:MM", or "HH:MM UTC" when local time is unknown.
    pub fn format(self: Clock, seconds: i64, buffer: *[16]u8) []const u8 {
        const offset = self.offsetAt(seconds);
        const local = seconds + (offset orelse 0);
        const minutes: u64 = @intCast(@mod(@divFloor(local, 60), 24 * 60));
        return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}{s}", .{
            minutes / 60, minutes % 60, if (offset == null) " UTC" else "",
        }) catch unreachable;
    }
};

/// Terminal columns from the TTY, then COLUMNS, then 80; clamped like other previews.
pub fn terminalWidth(env: *const std.process.Environ.Map) usize {
    if (builtin.os.tag == .linux) {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.os.linux.ioctl(1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
        if (std.os.linux.errno(rc) == .SUCCESS and size.col > 0) return std.math.clamp(size.col, 40, 160);
    }
    return std.math.clamp(std.fmt.parseInt(usize, env.get("COLUMNS") orelse "80", 10) catch 80, 40, 160);
}

/// Terminal rows from the TTY; returns 0 when unavailable or smaller than the 10-row minimum.
pub fn terminalRows() usize {
    if (builtin.os.tag == .linux) {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.os.linux.ioctl(1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
        if (std.os.linux.errno(rc) == .SUCCESS and size.row >= 10) return size.row;
    }
    return 0;
}

pub const Fields = struct {
    provider: []const u8,
    model: []const u8,
    dir: []const u8,
    context: []const u8 = "",
    time: []const u8,
};

/// Fit fields into `width` columns: shrink directory, then model, then drop context, time, directory.
pub fn render(out: *Io.Writer, width: usize, fields: Fields) !void {
    const sep = 3; // " · "
    const p = columns(fields.provider);
    var m = columns(fields.model);
    var d = columns(fields.dir);
    var c = columns(fields.context);
    var t = columns(fields.time);
    const budget = width -| 2; // leading space plus one spare column to avoid auto-wrap
    const total = struct {
        fn f(pp: usize, mm: usize, dd: usize, cc: usize, tt: usize) usize {
            return pp + sep + mm + (if (dd > 0) sep + dd else 0) + (if (cc > 0) sep + cc else 0) + (if (tt > 0) sep + tt else 0);
        }
    }.f;
    if (total(p, m, d, c, t) > budget) d = @min(d, @max(12, budget -| total(p, m, 0, c, t) -| sep));
    if (total(p, m, d, c, t) > budget) m = @min(m, @max(16, budget -| total(p, 0, d, c, t)));
    if (total(p, m, d, c, t) > budget) c = 0;
    if (total(p, m, d, c, t) > budget) t = 0;
    if (total(p, m, d, c, t) > budget) d = 0;
    if (total(p, m, d, c, t) > budget) m = budget -| (p + sep);
    try out.writeByte(' ');
    try fit(out, fields.provider, p, .end);
    try out.writeAll(" · ");
    try fit(out, fields.model, m, .end);
    if (d > 0) {
        try out.writeAll(" · ");
        try fit(out, fields.dir, d, .middle);
    }
    if (c > 0) {
        try out.writeAll(" · ");
        try fit(out, fields.context, c, .end);
    }
    if (t > 0) {
        try out.writeAll(" · ");
        try fit(out, fields.time, t, .end);
    }
}

/// Replace the home prefix with "~" for display.
pub fn shortenHome(a: std.mem.Allocator, dir: []const u8, home: []const u8) ![]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, dir, home)) return dir;
    const rest = dir[home.len..];
    if (rest.len != 0 and rest[0] != '/') return dir;
    return std.fmt.allocPrint(a, "~{s}", .{rest});
}

fn columns(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Write sanitized text in at most `max` codepoints, eliding with "…" at the end or middle.
fn fit(out: *Io.Writer, text: []const u8, max: usize, where: enum { end, middle }) !void {
    if (max == 0) return;
    const n = columns(text);
    if (n <= max) return sanitized(out, text, 0, n);
    if (max == 1) return out.writeAll("…");
    switch (where) {
        .end => {
            try sanitized(out, text, 0, max - 1);
            try out.writeAll("…");
        },
        .middle => {
            const head = (max - 1) / 2;
            const tail = max - 1 - head;
            try sanitized(out, text, 0, head);
            try out.writeAll("…");
            try sanitized(out, text, n - tail, n);
        },
    }
}

fn sanitized(out: *Io.Writer, text: []const u8, from: usize, to: usize) !void {
    const view = std.unicode.Utf8View.init(text) catch {
        for (text[from..@min(to, text.len)]) |b| try out.writeByte(if (b >= 32 and b < 127) b else '?');
        return;
    };
    var it = view.iterator();
    var i: usize = 0;
    while (it.nextCodepointSlice()) |bytes| : (i += 1) {
        if (i < from) continue;
        if (i >= to) break;
        const cp = std.unicode.utf8Decode(bytes) catch '?';
        if (cp < 32 or (cp >= 127 and cp <= 159)) try out.writeByte('?') else try out.writeAll(bytes);
    }
}

test "status line fits fields in priority order and neutralizes controls" {
    var buffer: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buffer);
    const fields: Fields = .{ .provider = "openrouter", .model = "auto (cost-max) → z-ai/glm-4.6", .dir = "~/Projects/omnicode", .time = "10:25" };
    try render(&w, 120, fields);
    try std.testing.expectEqualStrings(" openrouter · auto (cost-max) → z-ai/glm-4.6 · ~/Projects/omnicode · 10:25", w.buffered());
    w.end = 0;
    try render(&w, 70, fields);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "~/Proj…") != null);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "10:25"));
    try std.testing.expect(columns(w.buffered()) <= 69);
    w.end = 0;
    try render(&w, 40, fields);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "10:25") == null);
    try std.testing.expect(columns(w.buffered()) <= 39);
    try std.testing.expect(std.unicode.utf8ValidateSlice(w.buffered()));
    w.end = 0;
    try render(&w, 80, .{ .provider = "anthropic", .model = "evil\x1b[2Jmodel", .dir = "/tmp", .time = "00:00 UTC" });
    try std.testing.expect(std.mem.indexOfScalar(u8, w.buffered(), 27) == null);
}

test "home shortening and mode names" {
    const a = std.testing.allocator;
    const short = try shortenHome(a, "/home/me/src", "/home/me");
    defer a.free(short);
    try std.testing.expectEqualStrings("~/src", short);
    try std.testing.expectEqualStrings("/home/meow", try shortenHome(a, "/home/meow", "/home/me"));
    try std.testing.expectEqual(Status.Mode.title, Status.parseMode("title").?);
    try std.testing.expect(Status.parseMode("pinned-typo") == null);
    var status: Status = .{};
    const long: [200]u8 = @splat('x');
    status.setModel(&long);
    try std.testing.expectEqual(160, status.lastModel().len);
}

test "clock uses TZif offsets and labels UTC fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [16]u8 = undefined;
    const unknown: Clock = .{};
    try std.testing.expectEqualStrings("00:01 UTC", unknown.format(60, &buffer));
    // Minimal TZif v1: one transition at t=0 to a +03:00 type, initial type +01:00.
    var data: std.ArrayList(u8) = .empty;
    const a = arena.allocator();
    try data.appendSlice(a, "TZif");
    try data.appendNTimes(a, 0, 16);
    for ([_]u32{ 0, 0, 0, 1, 2, 8 }) |count| try data.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, count)));
    try data.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(i32, 0)));
    try data.append(a, 1);
    for ([_]i32{ 3600, 10800 }, [_]u8{ 0, 4 }) |offset, name| {
        try data.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(i32, offset)));
        try data.appendSlice(a, &.{ 0, name });
    }
    try data.appendSlice(a, "ONE\x00EAT\x00");
    const clock = try Clock.parse(a, data.items);
    try std.testing.expectEqualStrings("01:00", clock.format(-3600 * 24, &buffer)[0..5]);
    try std.testing.expectEqualStrings("03:00", clock.format(0, &buffer));
    try std.testing.expectEqualStrings("13:25", clock.format(10 * 3600 + 25 * 60, &buffer));
}
