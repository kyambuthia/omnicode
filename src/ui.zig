const std = @import("std");
const j = @import("json.zig");
const Io = std.Io;
const Usage = @import("usage.zig").Usage;
const status_line = @import("status.zig");

pub const Tab = enum(u8) { chat, activity, changes, plan };

const FeedLine = struct {
    bytes: [384]u8 = undefined,
    len: usize = 0,
};

fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

const Feed = struct {
    lines: [96]FeedLine = undefined,
    start: usize = 0,
    count: usize = 0,
    scroll: usize = 0,
    unread: usize = 0,

    fn clear(self: *Feed) void {
        self.start = 0;
        self.count = 0;
        self.scroll = 0;
        self.unread = 0;
    }

    fn append(self: *Feed, line: []const u8) void {
        var index: usize = undefined;
        if (self.count < self.lines.len) {
            index = (self.start + self.count) % self.lines.len;
            self.count += 1;
        } else {
            index = self.start;
            self.start = (self.start + 1) % self.lines.len;
        }
        const target = &self.lines[index];
        target.len = @min(line.len, target.bytes.len);
        while (target.len > 0 and !std.unicode.utf8ValidateSlice(line[0..target.len])) target.len -= 1;
        @memcpy(target.bytes[0..target.len], line[0..target.len]);
        self.scroll = 0;
    }

    fn get(self: *const Feed, index: usize) *const FeedLine {
        return &self.lines[(self.start + index) % self.lines.len];
    }
};

/// Bounded, in-memory terminal workspace. Each view keeps its latest 96 lines.
pub const Workspace = struct {
    feeds: [4]Feed = .{ .{}, .{}, .{}, .{} },
    active: Tab = .chat,
    provider: [48]u8 = @splat(0),
    provider_len: usize = 0,
    model: [128]u8 = @splat(0),
    model_len: usize = 0,
    dir: [96]u8 = @splat(0),
    dir_len: usize = 0,
    context: [32]u8 = @splat(0),
    context_len: usize = 0,
    time: [16]u8 = @splat(0),
    time_len: usize = 0,
    progress: [128]u8 = @splat(0),
    progress_len: usize = 0,
    status_visible: bool = true,
    entered: bool = false,

    fn feed(self: *Workspace, tab: Tab) *Feed {
        return &self.feeds[@backingInt(tab)];
    }

    fn feedConst(self: *const Workspace, tab: Tab) *const Feed {
        return &self.feeds[@backingInt(tab)];
    }

    fn appendSegment(self: *Workspace, tab: Tab, line: []const u8) void {
        var clean: [384]u8 = undefined;
        var used: usize = 0;
        const view = std.unicode.Utf8View.init(line) catch {
            self.feed(tab).append("[non-UTF-8 text]");
            return;
        };
        var iter = view.iterator();
        while (iter.nextCodepointSlice()) |bytes| {
            if (used + bytes.len > clean.len) break;
            const cp = std.unicode.utf8Decode(bytes) catch '?';
            if (cp < 32 or (cp >= 127 and cp <= 159)) {
                clean[used] = if (cp == '\t') ' ' else '?';
                used += 1;
            } else {
                @memcpy(clean[used..][0..bytes.len], bytes);
                used += bytes.len;
            }
        }
        self.feed(tab).append(clean[0..used]);
    }

    fn append(self: *Workspace, tab: Tab, text: []const u8, width: usize) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var added: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) {
                self.appendSegment(tab, line);
                added += 1;
                continue;
            }
            var start: usize = 0;
            while (start < line.len) {
                const view = std.unicode.Utf8View.init(line[start..]) catch {
                    self.feed(tab).append("[non-UTF-8 text]");
                    added += 1;
                    break;
                };
                var iter = view.iterator();
                var columns: usize = 0;
                var end = start;
                var last_space: ?usize = null;
                while (iter.nextCodepointSlice()) |bytes| {
                    if (columns == @max(width, 1)) break;
                    const cp = std.unicode.utf8Decode(bytes) catch '?';
                    if (cp == ' ') last_space = end;
                    end += bytes.len;
                    columns += 1;
                }
                if (end < line.len) if (last_space) |space| {
                    if (space > start) end = space;
                };
                self.appendSegment(tab, line[start..end]);
                added += 1;
                start = end;
                while (start < line.len and line[start] == ' ') start += 1;
            }
        }
        if (tab != self.active) self.feed(tab).unread +|= added;
    }

    fn replace(self: *Workspace, tab: Tab, text: []const u8, width: usize) void {
        self.feed(tab).clear();
        self.append(tab, text, width);
    }

    fn copyField(dest: []u8, value: []const u8) usize {
        const len = @min(dest.len, value.len);
        var bounded = len;
        while (bounded > 0 and !std.unicode.utf8ValidateSlice(value[0..bounded])) bounded -= 1;
        @memcpy(dest[0..bounded], value[0..bounded]);
        return bounded;
    }

    fn label(tab: Tab) []const u8 {
        return switch (tab) {
            .chat => "Chat",
            .activity => "Activity",
            .changes => "Changes",
            .plan => "Plan",
        };
    }

    pub fn enter(self: *Workspace, ui: Ui) !void {
        if (self.entered) return;
        self.entered = true;
        try ui.out.writeAll("\x1b[?1049h\x1b[?25h");
        try self.render(ui);
    }

    pub fn leave(self: *Workspace, ui: Ui) !void {
        if (!self.entered) return;
        self.entered = false;
        try ui.out.writeAll("\x1b[?25h\x1b[?1049l");
        try ui.out.flush();
    }

    fn moveTab(self: *Workspace, forward: bool) void {
        const count = 4;
        const current = @backingInt(self.active);
        const next = if (forward) (current + 1) % count else (current + count - 1) % count;
        self.active = @fromBackingInt(@intCast(next));
        self.feed(self.active).unread = 0;
        self.feed(self.active).scroll = 0;
    }

    fn scrollBy(self: *Workspace, delta: isize) void {
        const active = self.feed(self.active);
        const rows = self.rowCount();
        const max_scroll = active.count -| (rows - 4);
        if (delta > 0) active.scroll = @min(active.scroll + @as(usize, @intCast(delta)), max_scroll);
        if (delta < 0) active.scroll -|= @intCast(-delta);
    }

    fn rowCount(_: *const Workspace) usize {
        const detected = status_line.terminalRows();
        return if (detected < 8) 24 else detected;
    }

    fn renderFooter(self: *Workspace, ui: Ui) !void {
        if (!self.entered) return;
        const rows = self.rowCount();
        try ui.out.print("\x1b[{d};1H\x1b[2m", .{rows - 1});
        var status_buffer: [512]u8 = undefined;
        var status_writer = Io.Writer.fixed(&status_buffer);
        if (self.status_visible and self.provider_len > 0) {
            try status_writer.writeAll(self.provider[0..self.provider_len]);
            if (self.model_len > 0) try status_writer.print(" / {s}", .{self.model[0..self.model_len]});
            if (self.dir_len > 0) try status_writer.print(" · {s}", .{self.dir[0..self.dir_len]});
            if (self.context_len > 0) try status_writer.print(" · {s}", .{self.context[0..self.context_len]});
            if (self.time_len > 0) try status_writer.print(" · {s}", .{self.time[0..self.time_len]});
        }
        if (self.progress_len > 0) {
            if (status_writer.end > 0) try status_writer.writeAll(" · ");
            try status_writer.writeAll(self.progress[0..self.progress_len]);
        }
        try ui.safe(status_writer.buffered(), ui.width -| 2);
        try ui.out.writeAll("\x1b[0m\x1b[K");
        try ui.out.print("\x1b[{d};1H\x1b[1m› \x1b[0m\x1b[K\x1b[?25h", .{rows});
        try ui.out.flush();
    }

    pub fn render(self: *Workspace, ui: Ui) !void {
        if (!self.entered) return;
        const rows = self.rowCount();
        const body_rows = rows - 4;
        const current_feed = self.feedConst(self.active);
        const end = current_feed.count -| current_feed.scroll;
        const start = end -| body_rows;
        try ui.out.writeAll("\x1b[H\x1b[2J");
        for ([_]Tab{ .chat, .activity, .changes, .plan }) |tab| {
            const selected = tab == self.active;
            if (selected) try ui.style("\x1b[30;46m") else try ui.style("\x1b[2m");
            try ui.out.writeByte(' ');
            try ui.out.writeAll(label(tab));
            if (self.feedConst(tab).unread > 0) try ui.out.print(" +{d}", .{self.feedConst(tab).unread});
            try ui.out.writeByte(' ');
            try ui.style("\x1b[0m");
        }
        try ui.out.writeAll("\x1b[K\n");
        try ui.style("\x1b[2m");
        for (0..@min(ui.width, 72)) |_| try ui.out.writeAll("─");
        try ui.out.writeAll("\x1b[0m\x1b[K\n");
        if (current_feed.count == 0) {
            const empty = switch (self.active) {
                .chat => "Start a conversation. Type a request and press Enter.",
                .activity => "Tool calls, routing, and session events will appear here.",
                .changes => "Agent write and edit operations will appear here.",
                .plan => "The current task checklist will appear here.",
            };
            try ui.out.writeAll("  ");
            try ui.safe(empty, ui.width -| 4);
            try ui.out.writeByte('\n');
            for (1..body_rows) |_| try ui.out.writeAll("\x1b[K\n");
        } else {
            for (0..body_rows) |row| {
                const logical = start + row;
                if (logical < end) {
                    try ui.out.writeAll("  ");
                    try ui.safe(current_feed.get(logical).bytes[0..current_feed.get(logical).len], ui.width -| 4);
                }
                try ui.out.writeAll("\x1b[K\n");
            }
        }
        try self.renderFooter(ui);
    }
};

/// Last tool result only: replacement bounds memory independently of conversation history.
pub const Details = struct {
    bytes: [64 * 1024]u8 = undefined,
    len: usize = 0,
    present: bool = false,
    truncated: bool = false,

    pub fn save(self: *Details, text: []const u8) void {
        self.len = @min(text.len, self.bytes.len);
        while (self.len > 0 and !std.unicode.utf8ValidateSlice(text[0..self.len])) self.len -= 1;
        @memcpy(self.bytes[0..self.len], text[0..self.len]);
        self.present = true;
        self.truncated = self.len < text.len;
    }
};

/// Terminal workspace for interactive use and plain transcript output elsewhere.
pub const Ui = struct {
    out: *Io.Writer,
    io: Io,
    color: bool = false,
    interactive: bool = false,
    verbose: bool = false,
    indent: []const u8 = "",
    width: usize = 80,
    details: ?*Details = null,
    usage: ?*Usage = null,
    status: ?*status_line.Status = null,
    secrets: ?*const @import("secrets.zig").Secrets = null,
    env: ?*const std.process.Environ.Map = null,
    workspace: ?*Workspace = null,

    pub fn init(out: *Io.Writer, io: Io, env: *const std.process.Environ.Map) Ui {
        const tty = Io.File.stdout().isTty(io) catch false;
        const dumb = std.mem.eql(u8, env.get("TERM") orelse "", "dumb");
        return .{
            .out = out,
            .io = io,
            .env = env,
            .interactive = tty and !dumb and env.get("NO_COLOR") == null,
            .color = tty and !dumb and env.get("NO_COLOR") == null,
            .width = if (tty) status_line.terminalWidth(env) else std.math.clamp(std.fmt.parseInt(usize, env.get("COLUMNS") orelse "80", 10) catch 80, 40, 160),
        };
    }

    fn style(ui: Ui, code: []const u8) !void {
        if (ui.color) try ui.out.writeAll(code);
    }

    // Never let model/file/command text emit terminal controls; truncate on UTF-8 boundaries.
    fn safe(ui: Ui, value: []const u8, max: usize) !void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), value, ui.env) else value;
        const view = std.unicode.Utf8View.init(text) catch {
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

    /// Write text that may come from a provider or model ID without allowing terminal escapes.
    pub fn writeSafeText(ui: Ui, value: []const u8, max: usize) !void {
        try ui.safe(value, max);
    }

    fn record(ui: Ui, tab: Tab, text: []const u8) !void {
        const workspace = ui.workspace orelse return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const safe_text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), text, ui.env) else text;
        workspace.append(tab, safe_text, ui.width -| 4);
        try workspace.render(ui);
    }

    pub fn setPlan(ui: Ui, text: []const u8) !void {
        const workspace = ui.workspace orelse return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const safe_text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), text, ui.env) else text;
        workspace.replace(.plan, safe_text, ui.width -| 4);
        try workspace.render(ui);
    }

    pub fn redrawWorkspace(ui: Ui) !void {
        if (ui.workspace) |workspace| try workspace.render(ui);
    }

    pub fn output(ui: Ui, text: []const u8) !void {
        if (ui.workspace != null) return ui.record(.activity, text);
        try ui.out.writeAll(text);
    }

    pub fn outputf(ui: Ui, comptime format: []const u8, args: anytype) !void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        return ui.output(try std.fmt.allocPrint(scratch.allocator(), format, args));
    }

    pub fn workspaceTab(ui: Ui, forward: bool) !void {
        const workspace = ui.workspace orelse return;
        workspace.moveTab(forward);
        try workspace.render(ui);
    }

    pub fn workspaceSelect(ui: Ui, tab: Tab) !void {
        const workspace = ui.workspace orelse return;
        workspace.active = tab;
        workspace.feed(tab).unread = 0;
        workspace.feed(tab).scroll = 0;
        try workspace.render(ui);
    }

    pub fn workspaceScroll(ui: Ui, delta: isize) !void {
        const workspace = ui.workspace orelse return;
        workspace.scrollBy(delta);
        try workspace.render(ui);
    }

    pub fn userPrompt(ui: Ui, text: []const u8) !void {
        if (ui.workspace != null) {
            var buffer: [16 * 1024 + 5]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "You: {s}", .{text}) catch text;
            try ui.record(.chat, line);
        }
    }

    pub fn banner(ui: Ui, provider: []const u8, cwd: []const u8) !void {
        if (ui.workspace) |workspace| {
            workspace.provider_len = Workspace.copyField(&workspace.provider, provider);
            workspace.dir_len = Workspace.copyField(&workspace.dir, cwd);
            try ui.record(.chat, "Omnicode · interactive workspace\nType a request to start. Tab switches views; PgUp/PgDn scroll.");
            try ui.record(.activity, "Session started · automatic task routing");
            return;
        }
        try ui.style("\x1b[1m");
        try ui.out.writeAll("\n  omnicode v" ++ @import("root.zig").version ++ "\n");
        try ui.style("\x1b[0m");
        try ui.out.writeAll("  ");
        try ui.safe(cwd, ui.width - 4);
        try ui.out.writeAll("\n  ");
        try ui.safe(provider, 30);
        try ui.out.writeAll(" · automatic task routing\n\n  /help commands  /model routing  /skills instructions\n\n");
    }

    pub fn prompt(ui: Ui) !void {
        if (ui.workspace != null) return ui.redrawWorkspace();
        try ui.style("\x1b[1m");
        try ui.out.writeAll("› ");
        try ui.style("\x1b[0m");
        try ui.out.flush();
    }

    /// One dim line above the prompt (or the terminal title); interactive terminals only.
    pub fn statusBar(ui: Ui, provider: []const u8, model: []const u8, dir: []const u8, context: []const u8) !void {
        const s = ui.status orelse return;
        var time: [16]u8 = undefined;
        const fields: status_line.Fields = .{
            .provider = provider,
            .model = model,
            .dir = dir,
            .context = context,
            .time = s.clock.format(Io.Clock.real.now(ui.io).toSeconds(), &time),
        };
        if (ui.workspace) |workspace| {
            workspace.provider_len = Workspace.copyField(&workspace.provider, provider);
            workspace.model_len = Workspace.copyField(&workspace.model, model);
            workspace.dir_len = Workspace.copyField(&workspace.dir, dir);
            workspace.context_len = Workspace.copyField(&workspace.context, context);
            workspace.time_len = Workspace.copyField(&workspace.time, fields.time);
            workspace.status_visible = s.mode != .off and s.mode != .title;
            if (s.mode == .title) {
                try ui.out.writeAll("\x1b]0;omnicode ·");
                try status_line.render(ui.out, 200, fields);
                try ui.out.writeAll("\x07");
            }
            return;
        }
        if (!ui.interactive or s.mode == .off) return;
        if (s.mode == .title) {
            try ui.out.writeAll("\x1b]0;omnicode ·");
            try status_line.render(ui.out, 200, fields);
            try ui.out.writeAll("\x07");
            return;
        }
        if (s.mode == .pinned) {
            const rows = status_line.terminalRows();
            if (rows >= 10) {
                try ui.out.print("\x1b7\x1b[1;{d}r\x1b[{d};1H\x1b[2K\x1b[2m", .{ rows - 1, rows });
                try status_line.render(ui.out, ui.width, fields);
                try ui.out.writeAll("\x1b[0m\x1b8\x1b[A\n");
                return;
            }
        }
        try ui.style("\x1b[2m");
        try status_line.render(ui.out, ui.width, fields);
        try ui.style("\x1b[0m");
        try ui.out.writeByte('\n');
    }

    /// Reset DECSTBM scroll region and clear the pinned bar row on exit or mode switch.
    pub fn resetScrollRegion(ui: Ui) !void {
        if (!ui.interactive) return;
        const rows = status_line.terminalRows();
        if (rows >= 10) {
            try ui.out.print("\x1b7\x1b[r\x1b[{d};1H\x1b[2K\x1b8", .{rows});
        } else {
            try ui.out.writeAll("\x1b[r");
        }
        try ui.out.flush();
    }

    /// Save/restore the terminal title around title mode (xterm title stack).
    pub fn titleStack(ui: Ui, push: bool) !void {
        if (!ui.interactive) return;
        try ui.out.writeAll(if (push) "\x1b[22;0t" else "\x1b[23;0t");
        try ui.out.flush();
    }

    pub fn note(ui: Ui, text: []const u8) !void {
        if (ui.workspace != null) return ui.record(.activity, text);
        try ui.style("\x1b[2m");
        try ui.out.writeAll("  ");
        try ui.safe(text, ui.width - 4);
        try ui.style("\x1b[0m");
        try ui.out.writeByte('\n');
    }

    pub fn route(ui: Ui, provider: []const u8, model: []const u8) !void {
        if (ui.workspace != null) {
            var buffer: [256]u8 = undefined;
            return ui.record(.activity, try std.fmt.bufPrint(&buffer, "Model · {s} / {s}", .{
                utf8Prefix(provider, 32),
                utf8Prefix(model, 180),
            }));
        }
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
        if (ui.workspace) |workspace| {
            workspace.progress_len = Workspace.copyField(&workspace.progress, label);
            try workspace.renderFooter(ui);
        }
        defer {
            if (ui.workspace) |workspace| {
                workspace.progress_len = 0;
                workspace.renderFooter(ui) catch {};
            } else {
                ui.out.writeAll("\r\x1b[2K") catch {};
                ui.out.flush() catch {};
            }
        }
        try select.concurrent(.done, function, args);
        const start = Io.Clock.awake.now(ui.io);
        var frame: usize = 0;
        while (true) : (frame += 1) {
            if (ui.workspace) |workspace| {
                var progress: [128]u8 = undefined;
                const progress_text = std.fmt.bufPrint(&progress, "{c} {s} · {d}s", .{ "|/-\\"[frame % 4], label, start.durationTo(Io.Clock.awake.now(ui.io)).toSeconds() }) catch label;
                workspace.progress_len = Workspace.copyField(&workspace.progress, progress_text);
                try workspace.renderFooter(ui);
            } else {
                try ui.out.print("\r\x1b[2K  {c} {s} · {d}s", .{ "|/-\\"[frame % 4], label, start.durationTo(Io.Clock.awake.now(ui.io)).toSeconds() });
                try ui.out.flush();
            }
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
        if (ui.workspace != null) {
            var buffer: [16 * 1024]u8 = undefined;
            const body = std.fmt.bufPrint(&buffer, "Assistant:\n{s}", .{text}) catch text;
            return ui.record(.chat, body);
        }
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
        if (ui.workspace != null) {
            if (prefix.len == 0) return ui.record(.activity, text);
            var buffer: [16 * 1024]u8 = undefined;
            const body = std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, text }) catch text;
            return ui.record(.activity, body);
        }
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
                if (n == 3) try ui.out.print("{s}    ... {d} lines hidden (/details or /verbose on)\n", .{ ui.indent, count - 5 });
                continue;
            }
            try ui.out.writeAll(ui.indent);
            try ui.out.writeAll("    ");
            try ui.out.writeAll(prefix);
            try ui.safe(line, if (ui.verbose) std.math.maxInt(usize) else ui.width -| (10 + ui.indent.len));
            try ui.out.writeByte('\n');
        }
    }

    pub fn toolStart(ui: Ui, name: []const u8, args: j.Value) !void {
        if (ui.workspace != null) {
            const key = if (std.mem.eql(u8, name, "bash")) "cmd" else if (std.mem.eql(u8, name, "task")) "prompt" else if (std.mem.eql(u8, name, "skill")) "name" else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep")) "pat" else "path";
            var buffer: [768]u8 = undefined;
            var writer = Io.Writer.fixed(&buffer);
            try writer.print("Running {s}", .{name});
            if (std.mem.eql(u8, name, "todo")) {
                try writer.writeAll(" · checklist");
            } else if (std.mem.eql(u8, name, "review")) {
                try writer.print(" · {s}", .{utf8Prefix(j.optional(args, "focus", "working tree") catch "working tree", 512)});
            } else {
                const detail = if (std.mem.eql(u8, name, "bash")) j.aliasedString(args, "cmd", "command") else j.str(args, key);
                try writer.print(" · {s}", .{utf8Prefix(detail catch "(invalid arguments)", 512)});
                if (std.mem.eql(u8, key, "pat")) try writer.print(" in {s}", .{utf8Prefix(j.optional(args, "path", ".") catch ".", 128)});
            }
            return ui.record(.activity, writer.buffered());
        }
        const key = if (std.mem.eql(u8, name, "bash")) "cmd" else if (std.mem.eql(u8, name, "task")) "prompt" else if (std.mem.eql(u8, name, "skill")) "name" else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep")) "pat" else "path";
        try ui.out.writeAll(ui.indent);
        try ui.style("\x1b[1m");
        try ui.out.writeAll("• ");
        try ui.safe(name, 24);
        try ui.style("\x1b[0m");
        try ui.out.writeAll("  ");
        if (std.mem.eql(u8, name, "todo")) {
            try ui.out.writeAll("checklist");
        } else if (std.mem.eql(u8, name, "review")) {
            const focus = j.optional(args, "focus", "") catch "";
            try ui.safe(if (focus.len > 0) focus else "working tree", ui.width -| (16 + ui.indent.len));
        } else {
            const detail = if (std.mem.eql(u8, name, "bash")) j.aliasedString(args, "cmd", "command") else j.str(args, key);
            try ui.safe(detail catch "(invalid arguments)", ui.width -| (16 + ui.indent.len));
        }
        if (std.mem.eql(u8, key, "pat")) {
            try ui.out.writeAll(" in ");
            try ui.safe(j.optional(args, "path", ".") catch "?", 40);
        } else if (std.mem.eql(u8, name, "task")) {
            try ui.out.writeAll(" (");
            try ui.safe(j.optional(args, "mode", "explore") catch "explore", 12);
            try ui.out.writeByte(')');
        }
        try ui.out.writeByte('\n');
        try ui.out.flush();
    }

    pub fn toolEnd(ui: Ui, name: []const u8, args: j.Value, result: []const u8, failed: bool, start: Io.Timestamp) !void {
        try ui.retainDetails(result);
        if (ui.workspace != null) {
            const ms = start.durationTo(Io.Clock.awake.now(ui.io)).toMilliseconds();
            var buffer: [256]u8 = undefined;
            const summary = std.fmt.bufPrint(&buffer, "{s} {s} · {d}{s}", .{
                if (failed) "Failed:" else "Done:",
                name,
                if (ms < 1000) ms else @divTrunc(ms, 1000),
                if (ms < 1000) "ms" else "s",
            }) catch name;
            try ui.record(.activity, summary);
            if (std.mem.eql(u8, name, "todo")) try ui.setPlan(result);
            if (!failed and (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit"))) {
                const path = utf8Prefix(try j.str(args, "path"), 320);
                var change: [512]u8 = undefined;
                const description = if (std.mem.eql(u8, name, "write"))
                    try std.fmt.bufPrint(&change, "Created or replaced {s} · {d} bytes", .{ path, (try j.str(args, "content")).len })
                else
                    try std.fmt.bufPrint(&change, "Edited {s} · {d} removed, {d} added lines", .{
                        path,
                        lineCount(try j.str(args, "old")),
                        lineCount(try j.str(args, "new")),
                    });
                try ui.record(.changes, description);
            }
            return;
        }
        try ui.out.writeAll(ui.indent);
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
            try ui.out.print("{s}    {d} bytes written\n", .{ ui.indent, (try j.str(args, "content")).len });
        } else try ui.preview(result, "");
        try ui.out.flush();
    }

    fn lineCount(text: []const u8) usize {
        if (text.len == 0) return 0;
        return std.mem.count(u8, text, "\n") + @intFromBool(text[text.len - 1] != '\n');
    }

    pub fn retainDetails(ui: Ui, text: []const u8) !void {
        const details = ui.details orelse return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const safe_text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), text, ui.env) else text;
        // Redact before bounding the retained prefix, which could cut a secret in half.
        details.save(safe_text);
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

    pub fn turnComplete(ui: Ui, start: Io.Timestamp, tool_calls: usize) !void {
        if (ui.workspace != null) {
            const ms = start.durationTo(Io.Clock.awake.now(ui.io)).toMilliseconds();
            var duration_buffer: [32]u8 = undefined;
            var summary_buffer: [128]u8 = undefined;
            const duration = if (ms < 1000)
                try std.fmt.bufPrint(&duration_buffer, "{d}ms", .{ms})
            else
                try std.fmt.bufPrint(&duration_buffer, "{d}.{d}s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100) });
            return ui.record(.activity, try std.fmt.bufPrint(&summary_buffer, "Completed · {s} · {d} tool call(s)", .{ duration, tool_calls }));
        }
        try ui.out.writeAll("\n  Completed · ");
        try ui.elapsed(start);
        try ui.out.print(" · {d} tool {s}\n\n", .{ tool_calls, if (tool_calls == 1) "call" else "calls" });
    }

    pub fn usageSummary(ui: Ui, usage: Usage, label: []const u8) !void {
        if (ui.workspace != null) {
            var buffer: [512]u8 = undefined;
            var writer = Io.Writer.fixed(&buffer);
            try writer.print("{s} usage · {d} in · {d} out · {d} cache read · {d} cache write", .{ label, usage.input, usage.output, usage.read, usage.write });
            if (usage.requests > usage.unknown_cost) try writer.print(" · cost {d:.8} {s}", .{ usage.usd, if (usage.estimated > 0) "estimated" else "reported" });
            if (usage.unknown_cost > 0) try writer.print(" · cost unavailable for {d} response(s)", .{usage.unknown_cost});
            if (usage.missing > 0) try writer.print(" · token usage unavailable for {d} response(s)", .{usage.missing});
            if (usage.compactions > 0) try writer.print(" · {d} compaction(s)", .{usage.compactions});
            try writer.print(" · {d} response(s)", .{usage.requests});
            return ui.record(.activity, writer.buffered());
        }
        try ui.style("\x1b[2m");
        try ui.out.print("  {s} usage · {d} in · {d} out · {d} cache read · {d} cache write", .{ label, usage.input, usage.output, usage.read, usage.write });
        if (usage.requests > usage.unknown_cost) try ui.out.print(" · ${d:.8} {s}", .{ usage.usd, if (usage.estimated > 0) "estimated" else "reported" });
        if (usage.unknown_cost > 0 and usage.requests > usage.unknown_cost) try ui.out.writeAll(" subtotal");
        if (usage.unknown_cost > 0) try ui.out.print(" · cost unavailable for {d} response(s)", .{usage.unknown_cost});
        if (usage.missing > 0) try ui.out.print(" · token usage unavailable for {d} response(s)", .{usage.missing});
        if (usage.compactions > 0) try ui.out.print(" · {d} compaction(s)", .{usage.compactions});
        try ui.out.print(" · {d} response(s)", .{usage.requests});
        try ui.style("\x1b[0m");
        try ui.out.writeByte('\n');
        try ui.out.flush();
    }

    pub fn errorMessage(ui: Ui, err: anyerror) !void {
        const hint = switch (err) {
            error.InvalidSession => "Saved session is malformed or unsupported; the current conversation and checklist were kept.",
            error.InsecureEndpoint => "Use HTTPS, or HTTP with a literal loopback address (127.0.0.1 or [::1]) for local testing.",
            error.InvalidEndpoint => "Use a complete HTTP(S) endpoint URL without embedded credentials, fragments, or whitespace.",
            error.InvalidHttpHeader => "An API credential or request header contains invalid characters. Check the selected provider key and environment variables.",
            error.ApiAuthenticationFailed => "API authentication failed (HTTP 401). Check the selected provider key with /providers or /setup.",
            error.ApiAccessDenied => "API access denied (HTTP 403). Check provider permissions and model access.",
            error.ApiRateLimited => "API rate limit reached (HTTP 429). Wait before retrying and check provider limits.",
            error.ApiServerError => "The API returned a server error (HTTP 5xx). Check provider availability before retrying.",
            error.ApiError => "The API rejected the request. Check the HTTP status, endpoint, and model settings.",
            error.InvalidResponseBody => "The API returned an unreadable response body. Check the endpoint and provider availability.",
            error.InvalidJsonResponse => "The API returned invalid JSON. Check the endpoint and provider availability.",
            error.MissingApiKey => "No API key is available for the selected provider. Use /providers setup, or export that provider's API key and restart Omnicode.",
            error.NoFreeModels => "No eligible free tool models in the current catalog; no paid request was sent.",
            error.PaidModelInFreeMode => "Configured model is not verified free. Clear MODEL/FAST_MODEL or choose a free model.",
            error.ModelUnavailable => "No eligible model in the live catalog. Check model overrides and MODELS_URL.",
            error.InvalidCatalog => "Invalid model catalog; inference was blocked.",
            error.FreeRequiresOpenRouter => "--free requires OpenRouter.",
            error.NotRegularFile => "Choose a regular file. Pipes, devices, sockets, and directories cannot be used as project files.",
            error.InvalidPath => "File paths cannot contain NUL bytes. Remove the embedded NUL and retry.",
            error.Timeout => "The operation timed out. Check connectivity or narrow the task.",
            error.HistoryLimit => "Conversation size limit reached. Use /compact or start a smaller task.",
            error.ToolLimit => "Shared tool-call budget reached for this request, including delegated work. Inspect completed effects and resume, or use /setup set MAX_TOOL_CALLS 512 (default 256; range 1-4096).",
            error.InvalidToolLimit => "MAX_TOOL_CALLS must be an integer from 1 to 4096 (default 256). Correct it in the environment or saved configuration; in an active REPL use /setup set MAX_TOOL_CALLS 512 or /setup unset MAX_TOOL_CALLS.",
            error.InvalidRequestRate => "MAX_REQUESTS_PER_MINUTE must be an integer from 0 to 600 (default 60; 0 disables pacing). Correct it in the environment or saved configuration.",
            error.TurnLimit => "Model-call budget reached for this request. Inspect completed tool effects, then enter continue to resume. For longer tasks: /setup set MAX_TURNS 64 (default 32; range 1-256).",
            error.InvalidTurnLimit => "MAX_TURNS must be an integer from 1 to 256 (default 32). Use /setup set MAX_TURNS 64 or /setup unset MAX_TURNS.",
            error.IncompleteResponse => "Model response was incomplete; no tools in that response were run.",
            error.AlreadyInitialized => "OMNICODE.md already exists. Use /init force to overwrite.",
            error.InvalidConfigKey, error.InvalidSetupCommand => "Usage: /setup <provider> <key> | /setup set <KEY> <VALUE> | /setup unset <KEY>",
            error.InvalidProvidersCommand => "Usage: /providers [list] | /providers <N|provider> [api_key] | /providers url <url|default> | /providers unset <provider>",
            error.VoiceRecordFailed => "Audio recording failed. Install arecord/sox/ffmpeg, set OMNICODE_VOICE_CMD, or pass /voice <file.wav>.",
            error.EmptyAudio, error.EmptyTranscript => "Voice input produced no transcription.",
            error.InvalidSecretName, error.InvalidSecretValue, error.InvalidSecretsCommand => "Usage: /secrets set <NAME> <VALUE> | /secrets unset <NAME> | /secrets load <file.env>",
            error.SecretNotFound => "Secret not found in vault.",
            else => "Use /help for commands and check your provider/model configuration.",
        };
        if (ui.workspace != null) {
            var buffer: [1024]u8 = undefined;
            const detail = std.fmt.bufPrint(&buffer, "{s} · {s}", .{ @errorName(err), hint }) catch @errorName(err);
            return ui.record(.activity, detail);
        }
        try ui.style("\x1b[31m");
        try ui.out.print("\n✗ {s}\n", .{@errorName(err)});
        try ui.style("\x1b[0m");
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

test "details redact secrets before truncating retained output" {
    var secrets: @import("secrets.zig").Secrets = .{};
    try secrets.setMemory("TOKEN", "private-token-998");
    var details: Details = .{};
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var ui: Ui = .{ .out = &output.writer, .io = std.testing.io, .details = &details, .secrets = &secrets };
    var text: [65550]u8 = @splat('x');
    const prefix = 65530;
    @memcpy(text[prefix..][0.."private-token-998".len], "private-token-998");
    try ui.retainDetails(&text);
    try std.testing.expect(details.truncated);
    try std.testing.expect(std.mem.indexOf(u8, details.bytes[0..details.len], "privat") == null);
    try ui.message("private-token-998");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "private-token-998") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "[REDACTED:TOKEN]") != null);
}
