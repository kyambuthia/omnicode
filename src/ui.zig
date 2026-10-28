const std = @import("std");
const j = @import("json.zig");
const Io = std.Io;
const Usage = @import("usage.zig").Usage;
const status_line = @import("status.zig");
const TmuxFeed = @import("tmux.zig").Feed;

/// The latest tool result plus a small recent Bash-output ring, all bounded independently of history.
pub const Details = struct {
    pub const output_count = 4;
    pub const command_limit = 2048;

    pub const Output = struct {
        id: usize = 0,
        bytes: [64 * 1024]u8 = undefined,
        len: usize = 0,
        present: bool = false,
        truncated: bool = false,
        command: [command_limit]u8 = undefined,
        command_len: usize = 0,
        command_truncated: bool = false,
        failed: bool = false,
        elapsed_ms: u64 = 0,
    };

    bytes: [64 * 1024]u8 = undefined,
    len: usize = 0,
    present: bool = false,
    truncated: bool = false,
    outputs: [output_count]Output = [_]Output{ .{}, .{}, .{}, .{} },
    next_output_id: usize = 1,
    latest_output_id: usize = 0,

    pub fn beginOutput(self: *Details) usize {
        const id = self.next_output_id;
        self.next_output_id +%= 1;
        if (self.next_output_id == 0) self.next_output_id = 1;
        return id;
    }

    pub fn saveOutput(self: *Details, id: usize, text: []const u8) void {
        if (id == 0) return;
        const output = &self.outputs[id % output_count];
        std.crypto.secureZero(u8, output.bytes[0..]);
        std.crypto.secureZero(u8, output.command[0..]);
        output.id = id;
        output.len = @min(text.len, output.bytes.len);
        while (output.len > 0 and !std.unicode.utf8ValidateSlice(text[0..output.len])) output.len -= 1;
        @memcpy(output.bytes[0..output.len], text[0..output.len]);
        output.present = true;
        output.truncated = output.len < text.len;
        output.command_len = 0;
        output.command_truncated = false;
        output.failed = false;
        output.elapsed_ms = 0;
        self.latest_output_id = id;
    }

    pub fn saveOutputCommand(self: *Details, id: usize, text: []const u8) void {
        if (id == 0) return;
        const output = &self.outputs[id % output_count];
        if (!output.present or output.id != id) return;
        std.crypto.secureZero(u8, output.command[0..]);
        output.command_len = @min(text.len, output.command.len);
        while (output.command_len > 0 and !std.unicode.utf8ValidateSlice(text[0..output.command_len])) output.command_len -= 1;
        @memcpy(output.command[0..output.command_len], text[0..output.command_len]);
        output.command_truncated = output.command_len < text.len;
    }

    pub fn finishOutput(self: *Details, id: usize, failed: bool, elapsed_ms: u64) void {
        if (id == 0) return;
        const output = &self.outputs[id % output_count];
        if (!output.present or output.id != id) return;
        output.failed = failed;
        output.elapsed_ms = elapsed_ms;
    }

    pub fn findOutput(self: *const Details, id: usize) ?*const Output {
        for (&self.outputs) |*output| {
            if (output.present and output.id == id) return output;
        }
        return null;
    }

    pub fn latestOutput(self: *const Details) ?*const Output {
        if (self.latest_output_id == 0) return null;
        return self.findOutput(self.latest_output_id);
    }

    pub fn save(self: *Details, text: []const u8) void {
        std.crypto.secureZero(u8, self.bytes[0..]);
        self.len = @min(text.len, self.bytes.len);
        while (self.len > 0 and !std.unicode.utf8ValidateSlice(text[0..self.len])) self.len -= 1;
        @memcpy(self.bytes[0..self.len], text[0..self.len]);
        self.present = true;
        self.truncated = self.len < text.len;
    }

    pub fn clear(self: *Details) void {
        std.crypto.secureZero(u8, self.bytes[0..]);
        self.len = 0;
        self.present = false;
        self.truncated = false;
        self.latest_output_id = 0;
        for (&self.outputs) |*output| {
            std.crypto.secureZero(u8, output.bytes[0..]);
            std.crypto.secureZero(u8, output.command[0..]);
            output.id = 0;
            output.len = 0;
            output.present = false;
            output.truncated = false;
            output.command_len = 0;
            output.command_truncated = false;
            output.failed = false;
            output.elapsed_ms = 0;
        }
    }
};

/// An append-only transcript: keep native terminal scrolling and copy/paste.
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
    tmux_feed: ?*TmuxFeed = null,
    secrets: ?*const @import("secrets.zig").Secrets = null,
    env: ?*const std.process.Environ.Map = null,

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

    fn styleTo(ui: Ui, out: *Io.Writer, code: []const u8) !void {
        if (ui.color) try out.writeAll(code);
    }

    // Never let model/file/command text emit terminal controls; truncate on UTF-8 boundaries.
    pub fn safe(ui: Ui, value: []const u8, max: usize) !void {
        try ui.safeTo(ui.out, value, max);
    }

    fn safeTo(ui: Ui, out: *Io.Writer, value: []const u8, max: usize) !void {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), value, ui.env) else value;
        defer if (text.ptr != value.ptr) std.crypto.secureZero(u8, @constCast(text));
        const view = std.unicode.Utf8View.init(text) catch {
            try out.writeAll("[non-UTF-8 text]");
            return;
        };
        var it = view.iterator();
        var n: usize = 0;
        while (it.nextCodepointSlice()) |bytes| {
            const cp = try std.unicode.utf8Decode(bytes);
            if (n >= max) {
                try out.writeAll("...");
                break;
            }
            if (cp < 32 or (cp >= 127 and cp <= 159)) {
                try out.writeByte(if (cp == '\t' or cp == '\n' or cp == '\r') ' ' else '?');
            } else try out.writeAll(bytes);
            n += 1;
        }
    }

    pub fn banner(ui: Ui, provider: []const u8, cwd: []const u8) !void {
        try ui.style("\x1b[1m");
        try ui.out.writeAll("\n  omnicode v" ++ @import("root.zig").version ++ "\n");
        try ui.style("\x1b[0m");
        try ui.out.writeAll("  ");
        try ui.safe(cwd, ui.width - 4);
        try ui.out.writeAll("\n  ");
        try ui.safe(provider, 30);
        try ui.out.writeAll(" · automatic task routing\n\n  / then Enter lists commands  /help topic  /model  /skills\n");
        if (ui.interactive) try ui.out.writeAll("  Ctrl+J adds a line · Enter sends\n");
        try ui.out.writeByte('\n');
        if (ui.tmux_feed) |feed| {
            if (feed.active) try ui.note("Bash streams live to tmux; Ctrl+O replays the latest result here.");
        } else if (ui.env) |env| {
            if (env.get("TMUX_PANE") != null and ui.width >= 100) try ui.note("Could not open a tmux Bash pane; Bash output will stay in the feed.");
        }
    }

    pub fn prompt(ui: Ui) !void {
        try ui.style("\x1b[1m");
        try ui.out.writeAll("› ");
        try ui.style("\x1b[0m");
        try ui.out.flush();
    }

    /// One dim line above the prompt (or the terminal title); interactive terminals only.
    pub fn statusBar(ui: Ui, provider: []const u8, model: []const u8, dir: []const u8, context: []const u8) !void {
        const s = ui.status orelse return;
        if (!ui.interactive or s.mode == .off) return;
        var time: [16]u8 = undefined;
        const fields: status_line.Fields = .{
            .provider = provider,
            .model = model,
            .dir = dir,
            .context = context,
            .time = s.clock.format(Io.Clock.real.now(ui.io).toSeconds(), &time),
        };
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

    /// The main task writes the transcript; workers own tool I/O and may stream to the isolated tmux pane.
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
        try ui.style("\x1b[1;35m");
        try ui.out.writeAll("\n◆ MODEL\n");
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
        try ui.previewLimit(text, prefix, 5, "/details or /verbose on", "");
    }

    fn previewTool(ui: Ui, text: []const u8, prefix: []const u8) !void {
        try ui.previewLimit(text, prefix, 5, "/details or /verbose on", "\x1b[36m");
    }

    fn previewLimit(ui: Ui, text: []const u8, prefix: []const u8, visible_lines: usize, expand_command: []const u8, prefix_style: []const u8) !void {
        const trimmed = std.mem.trimEnd(u8, text, "\n");
        if (trimmed.len == 0) {
            try ui.out.writeAll(ui.indent);
            try ui.out.writeAll("    ");
            try ui.style(prefix_style);
            try ui.out.writeAll(prefix);
            try ui.style("\x1b[0m");
            try ui.out.writeAll("(empty)\n");
            return;
        }
        const count = std.mem.count(u8, trimmed, "\n") + 1;
        const head = (visible_lines + 1) / 2;
        const tail = visible_lines - head;
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (!ui.verbose and count > visible_lines and n >= head and n < count - tail) {
                if (n == head) {
                    try ui.out.writeAll(ui.indent);
                    try ui.out.writeAll("    ");
                    try ui.style(prefix_style);
                    try ui.out.writeAll(prefix);
                    try ui.style("\x1b[0m");
                    try ui.out.print("... {d} lines hidden ({s})\n", .{ count - visible_lines, expand_command });
                }
                continue;
            }
            try ui.out.writeAll(ui.indent);
            try ui.out.writeAll("    ");
            try ui.style(prefix_style);
            try ui.out.writeAll(prefix);
            try ui.style("\x1b[0m");
            try ui.safe(line, if (ui.verbose) std.math.maxInt(usize) else ui.width -| (10 + ui.indent.len));
            try ui.out.writeByte('\n');
        }
    }

    pub fn toolStart(ui: Ui, name: []const u8, args: j.Value, track_output: bool) !usize {
        const key = if (std.mem.eql(u8, name, "bash")) "cmd" else if (std.mem.eql(u8, name, "task")) "prompt" else if (std.mem.eql(u8, name, "skill")) "name" else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep")) "pat" else "path";
        var call_id: usize = 0;
        if (track_output and std.mem.eql(u8, name, "bash")) {
            if (ui.details) |details| call_id = details.beginOutput();
        }
        try ui.out.writeAll(ui.indent);
        if (std.mem.eql(u8, name, "bash")) {
            const command = j.aliasedString(args, "cmd", "command") catch "(invalid arguments)";
            var in_tmux = false;
            if (track_output) if (ui.tmux_feed) |feed| {
                if (feed.active) {
                    ui.writeTmuxBashStart(feed, call_id, command) catch feed.disable();
                    in_tmux = feed.active;
                }
            };
            if (in_tmux) {
                try ui.style("\x1b[1;36m");
                if (call_id > 0) try ui.out.print("bash #{d} $ ", .{call_id}) else try ui.out.writeAll("bash $ ");
                try ui.style("\x1b[0m");
                try ui.safe(command, ui.width -| (16 + ui.indent.len));
                try ui.out.writeByte('\n');
                try ui.out.flush();
                return call_id;
            }
            try ui.style("\x1b[1;36m");
            if (call_id > 0) try ui.out.print("╭─ BASH #{d}  $ ", .{call_id}) else try ui.out.writeAll("╭─ BASH  $ ");
            try ui.style("\x1b[0m");
            try ui.safe(command, ui.width -| (12 + ui.indent.len));
            try ui.out.writeByte('\n');
            try ui.out.flush();
            return call_id;
        }
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
        return call_id;
    }

    pub fn toolEnd(ui: Ui, name: []const u8, args: j.Value, result: []const u8, failed: bool, start: Io.Timestamp, call_id: usize) !void {
        try ui.retainDetails(result);
        if (std.mem.eql(u8, name, "bash")) {
            try ui.retainOutput(call_id, result);
            try ui.retainOutputCommand(call_id, j.aliasedString(args, "cmd", "command") catch "");
            if (ui.details) |details| {
                const elapsed_ms = start.durationTo(Io.Clock.awake.now(ui.io)).toMilliseconds();
                details.finishOutput(call_id, failed, @intCast(@max(0, elapsed_ms)));
            }
            var in_tmux = false;
            if (ui.tmux_feed) |feed| {
                if (feed.active) {
                    ui.writeTmuxBashResult(feed, call_id, result, failed, start) catch feed.disable();
                    in_tmux = feed.active;
                }
            }
            if (in_tmux) {
                // Keep the main transcript useful after the command ends. The tmux pane
                // carries the live stream; a compact final preview avoids making it a
                // required place to switch to just to read the result.
                try ui.previewLimit(result, "│ ", 8, "Ctrl+O full", "\x1b[1;36m");
                try ui.out.writeAll(ui.indent);
                try ui.style(if (failed) "\x1b[31m" else "\x1b[2m");
                if (call_id > 0) {
                    try ui.out.print("╰─ {s} · ", .{if (failed) "✗ Failed" else "✓ Done"});
                    try ui.elapsed(start);
                    try ui.out.writeAll(" · Ctrl+O full");
                } else {
                    try ui.out.print("╰─ {s} · ", .{if (failed) "✗ Failed" else "✓ Done"});
                    try ui.elapsed(start);
                    try ui.out.writeAll(" · /out full");
                }
                try ui.style("\x1b[0m");
                try ui.out.writeByte('\n');
                try ui.out.flush();
                return;
            }
            const hint = if (call_id > 0 and ui.interactive) "Ctrl+O full" else "--verbose";
            try ui.previewLimit(result, "│ ", 12, hint, "\x1b[1;36m");
            try ui.out.writeAll(ui.indent);
            try ui.style(if (failed) "\x1b[31m" else "\x1b[2m");
            try ui.out.print("╰─ {s} · ", .{if (failed) "✗ Failed" else "✓ Done"});
            try ui.elapsed(start);
            try ui.style("\x1b[0m");
            try ui.out.writeByte('\n');
            try ui.out.flush();
            return;
        }
        try ui.out.writeAll(ui.indent);
        try ui.style(if (failed) "\x1b[31m" else "\x1b[36m");
        try ui.out.print("  ⎿ {s} · ", .{if (failed) "✗ Failed" else "✓ Done"});
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
        } else try ui.previewTool(result, "│ ");
        try ui.out.flush();
    }

    pub fn retainDetails(ui: Ui, text: []const u8) !void {
        const details = ui.details orelse return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const safe_text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), text, ui.env) else text;
        defer if (safe_text.ptr != text.ptr) std.crypto.secureZero(u8, @constCast(safe_text));
        // Redact before bounding the retained prefix, which could cut a secret in half.
        details.save(safe_text);
    }

    pub fn retainOutput(ui: Ui, id: usize, text: []const u8) !void {
        const details = ui.details orelse return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const safe_text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), text, ui.env) else text;
        defer if (safe_text.ptr != text.ptr) std.crypto.secureZero(u8, @constCast(safe_text));
        details.saveOutput(id, safe_text);
    }

    pub fn retainOutputCommand(ui: Ui, id: usize, text: []const u8) !void {
        if (id == 0) return;
        const details = ui.details orelse return;
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const safe_text = if (ui.secrets) |secrets| try secrets.scrub(scratch.allocator(), text, ui.env) else text;
        defer if (safe_text.ptr != text.ptr) std.crypto.secureZero(u8, @constCast(safe_text));
        details.saveOutputCommand(id, safe_text);
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

    pub fn showOutput(ui: Ui, id: usize) !void {
        const details = ui.details orelse return ui.note("No retained Bash output.");
        const output = details.findOutput(id) orelse {
            var note_buf: [128]u8 = undefined;
            try ui.note(std.fmt.bufPrint(&note_buf, "No retained Bash output for call #{d}; the most recent {d} calls are kept.", .{ id, Details.output_count }) catch "No retained Bash output for that call.");
            return;
        };
        try ui.out.print("\n╭─ BASH output #{d} · {s} · ", .{ id, if (output.failed) "✗ Failed" else "✓ Done" });
        try ui.writeElapsed(output.elapsed_ms);
        try ui.out.writeByte('\n');
        if (output.command_len > 0) {
            try ui.out.writeAll("  $ ");
            try ui.safe(output.command[0..output.command_len], std.math.maxInt(usize));
            if (output.command_truncated) try ui.out.writeAll("...");
            try ui.out.writeByte('\n');
        }
        var full = ui;
        full.verbose = true;
        try full.preview(output.bytes[0..output.len], "│ ");
        try ui.out.writeAll("╰─ end\n");
        if (output.truncated) try ui.note("Output exceeds the retained 64 KiB limit; showing the prefix.");
    }

    pub fn showLatestOutput(ui: Ui) !void {
        const details = ui.details orelse return ui.note("No retained Bash output.");
        const output = details.latestOutput() orelse return ui.note("No retained Bash output.");
        try ui.showOutput(output.id);
    }

    pub fn showOutputList(ui: Ui) !void {
        const details = ui.details orelse return ui.note("No retained Bash output.");
        if (details.latest_output_id == 0) return ui.note("No retained Bash output.");
        try ui.out.writeAll("\nRecent Bash outputs\n");
        var id = details.latest_output_id;
        var found = false;
        for (0..Details.output_count) |_| {
            if (details.findOutput(id)) |output| {
                found = true;
                try ui.out.writeAll("  #");
                try ui.out.print("{d} · ", .{output.id});
                try ui.style(if (output.failed) "\x1b[31m" else "\x1b[36m");
                try ui.out.writeAll(if (output.failed) "✗ Failed · " else "✓ Done · ");
                try ui.writeElapsed(output.elapsed_ms);
                try ui.style("\x1b[0m");
                if (output.command_len > 0) {
                    try ui.out.writeAll("  $ ");
                    try ui.safe(output.command[0..output.command_len], ui.width -| 36);
                    if (output.command_truncated) try ui.out.writeAll("...");
                }
                try ui.out.writeByte('\n');
            }
            id = if (id == 1) std.math.maxInt(usize) else id - 1;
        }
        if (!found) return ui.note("No retained Bash output.");
        try ui.out.writeAll("Use /out <id> to print the full result.\n");
    }

    pub fn elapsed(ui: Ui, start: Io.Timestamp) !void {
        const ms = start.durationTo(Io.Clock.awake.now(ui.io)).toMilliseconds();
        try ui.writeElapsed(@intCast(@max(0, ms)));
    }

    fn writeElapsed(ui: Ui, ms: u64) !void {
        if (ms < 1000) try ui.out.print("{d}ms", .{ms}) else try ui.out.print("{d}.{d}s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100) });
    }

    fn writeTmuxBashStart(ui: Ui, feed: *TmuxFeed, id: usize, command: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        var stream = feed.writer(&buffer) orelse return error.TmuxPaneClosed;
        const out = &stream.interface;
        try ui.styleTo(out, "\x1b[1;36m");
        if (id > 0) try out.print("$ [{d}] ", .{id}) else try out.writeAll("$ ");
        try ui.safeTo(out, command, std.math.maxInt(usize));
        try ui.styleTo(out, "\x1b[0m");
        try out.writeAll("\r\n");
        try out.flush();
        feed.beginCall(id);
    }

    fn writeTmuxBashResult(ui: Ui, feed: *TmuxFeed, id: usize, result: []const u8, failed: bool, start: Io.Timestamp) !void {
        var buffer: [4096]u8 = undefined;
        var stream = feed.writer(&buffer) orelse return error.TmuxPaneClosed;
        const out = &stream.interface;
        if (!feed.hasCompleteStream(id)) {
            try ui.styleTo(out, "\x1b[2m");
            if (id > 0) try out.print("  output [{d}]\r\n", .{id}) else try out.writeAll("  output\r\n");
            try ui.styleTo(out, "\x1b[0m");
            const trimmed = std.mem.trimEnd(u8, result, "\n");
            if (trimmed.len == 0) {
                try out.writeAll("  (empty)\r\n");
            } else {
                var lines = std.mem.splitScalar(u8, trimmed, '\n');
                while (lines.next()) |line| {
                    try out.writeAll("  │ ");
                    try ui.safeTo(out, line, std.math.maxInt(usize));
                    try out.writeAll("\r\n");
                }
            }
        }
        try ui.styleTo(out, if (failed) "\x1b[31m" else "\x1b[2m");
        try out.writeAll(if (failed) "  ✗ failed · " else "  ✓ done · ");
        const ms = start.durationTo(Io.Clock.awake.now(ui.io)).toMilliseconds();
        if (ms < 1000) try out.print("{d}ms", .{ms}) else try out.print("{d}.{d}s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100) });
        try ui.styleTo(out, "\x1b[0m");
        try out.writeAll("\r\n\r\n");
        try out.flush();
    }

    pub fn usageSummary(ui: Ui, usage: Usage, label: []const u8) !void {
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
        try ui.style("\x1b[31m");
        try ui.out.print("\n✗ {s}\n", .{@errorName(err)});
        try ui.style("\x1b[0m");
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
            error.MissingApiKey => "Set OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or AN_ABLE_KEY for your selected provider.",
            error.MissingVoiceApiKey => "Set OPENROUTER_API_KEY for OpenRouter, or configure VOICE_URL/API_URL and a compatible API key.",
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
            error.UnsupportedAudioFormat => "Use a WAV, MP3, OGG, FLAC, or M4A file, or provide a file without an extension to treat it as WAV.",
            error.EmptyAudio, error.EmptyTranscript => "Voice input produced no transcription.",
            error.InvalidSecretName, error.InvalidSecretValue, error.InvalidSecretsCommand => "Usage: /secrets set <NAME> <VALUE> | /secrets unset <NAME> | /secrets load <file.env>",
            error.SecretNotFound => "Secret not found in vault.",
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

test "latest Bash output follows the newest saved call and clears with details" {
    var details: Details = .{};
    details.saveOutput(1, "first");
    details.saveOutputCommand(1, "printf first");
    const first = details.latestOutput().?;
    try std.testing.expectEqualStrings("first", first.bytes[0..first.len]);
    try std.testing.expectEqualStrings("printf first", first.command[0..first.command_len]);
    details.finishOutput(1, true, 1234);
    try std.testing.expect(details.latestOutput().?.failed);
    try std.testing.expectEqual(1234, details.latestOutput().?.elapsed_ms);
    details.saveOutput(2, "second");
    details.saveOutputCommand(2, "printf second");
    details.finishOutput(2, false, 42);
    try std.testing.expectEqual(2, details.latestOutput().?.id);
    try std.testing.expectEqualStrings("printf second", details.latestOutput().?.command[0..details.latestOutput().?.command_len]);
    try std.testing.expect(!details.latestOutput().?.failed);
    try std.testing.expectEqual(42, details.latestOutput().?.elapsed_ms);
    details.clear();
    try std.testing.expect(details.latestOutput() == null);
    try std.testing.expectEqual(0, details.outputs[2 % Details.output_count].command_len);
}

test "repeated Bash output shows its redacted command" {
    var secrets: @import("secrets.zig").Secrets = .{};
    try secrets.setMemory("TOKEN", "private-token-998");
    var details: Details = .{};
    details.saveOutput(1, "done");
    details.finishOutput(1, true, 1234);
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const ui: Ui = .{ .out = &output.writer, .io = std.testing.io, .details = &details, .secrets = &secrets };

    try ui.retainOutputCommand(1, "printf private-token-998");
    try ui.showLatestOutput();

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "BASH output #1 · ✗ Failed · 1.2s") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "$ printf [REDACTED:TOKEN]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "private-token-998") == null);
}

test "Bash output list orders recent calls and shows status and commands" {
    var details: Details = .{};
    details.saveOutput(1, "first");
    details.saveOutputCommand(1, "printf first");
    details.finishOutput(1, false, 100);
    details.saveOutput(2, "second");
    details.saveOutputCommand(2, "printf second");
    details.finishOutput(2, true, 1250);
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const ui: Ui = .{ .out = &output.writer, .io = std.testing.io, .details = &details };

    try ui.showOutputList();

    const rendered = output.written();
    const newest = std.mem.indexOf(u8, rendered, "#2 · ✗ Failed · 1.2s  $ printf second").?;
    const older = std.mem.indexOf(u8, rendered, "#1 · ✓ Done · 100ms  $ printf first").?;
    try std.testing.expect(newest < older);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Use /out <id> to print the full result.") != null);
}

test "Bash feed marks output source and offers a one-step full-output replay" {
    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    var details: Details = .{};
    const ui: Ui = .{ .out = &writer, .io = std.testing.io, .color = true, .interactive = true, .details = &details };
    const call_id = details.beginOutput();

    try ui.toolEnd("bash", .null, "first\nsecond\nthird\nfourth\nfifth\nsixth\nseventh\neighth\nninth\ntenth\neleventh\ntwelfth\nthirteenth\nlast", false, Io.Clock.awake.now(std.testing.io), call_id);

    const rendered = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1;36m│ \x1b[0mfirst") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2 lines hidden (Ctrl+O full)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Ctrl+O full") != null);
}

test "model replies and tool output have explicit source labels" {
    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    const ui: Ui = .{ .out = &writer, .io = std.testing.io };
    try ui.message("model answer");
    try ui.toolEnd("read\x1b[2J", .null, "file contents", false, Io.Clock.awake.now(std.testing.io), 0);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "◆ MODEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "⎿ ✓ Done ·") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│ file contents") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 27) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BASH") == null);
}

test "tool result bodies use a cyan source rail while model prose stays plain" {
    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    const ui: Ui = .{ .out = &writer, .io = std.testing.io, .color = true };
    try ui.message("model answer");
    _ = try ui.toolStart("read", .null, false);
    try ui.toolEnd("read", .null, "file contents", false, Io.Clock.awake.now(std.testing.io), 0);

    const output = writer.buffered();
    const model = std.mem.indexOf(u8, output, "  model answer").?;
    const tool = std.mem.indexOf(u8, output, "\x1b[36m│ \x1b[0mfile contents").?;
    try std.testing.expect(model < tool);
    try std.testing.expect(std.mem.indexOf(u8, output, "• read") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "⎿ ✓ Done ·") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "⎿ read") == null);

    try ui.toolEnd("grep", .null, "", false, Io.Clock.awake.now(std.testing.io), 0);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[36m│ \x1b[0m(empty)") != null);
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
