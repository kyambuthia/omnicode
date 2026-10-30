const std = @import("std");
const Io = std.Io;
const Ui = @import("ui.zig").Ui;
const ModelMenu = @import("catalog.zig").ModelMenu;
const Provider = @import("router.zig").Provider;
const status_line = @import("status.zig");

fn redrawInput(ui: Ui, bytes: []const u8) !void {
    if (ui.workspace != null) {
        try ui.prompt();
        try ui.out.writeAll(bytes);
    } else {
        try ui.out.writeAll("\r\x1b[2K");
        try ui.prompt();
        try ui.out.writeAll(bytes);
    }
    try ui.out.flush();
}

/// Open a searchable, scrollable model picker. Null means the user canceled.
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

    var alternate_screen = ui.workspace == null;
    if (alternate_screen) try ui.out.writeAll("\x1b[?1049h\x1b[?25h");
    defer {
        if (alternate_screen) {
            ui.out.writeAll("\x1b[?1049l") catch {};
            ui.out.flush() catch {};
        } else if (ui.workspace != null) {
            ui.redrawWorkspace() catch {};
        }
    }

    var query: [128]u8 = undefined;
    var query_len: usize = 0;
    var providers: [ModelMenu.max_items]Provider = undefined;
    const provider_count = collectProviders(menu, &providers);
    var active_tab = initialTab(menu, providers[0..provider_count], current);
    var tab_scroll: usize = 0;
    var filtered: [ModelMenu.max_items]usize = undefined;
    var filtered_count = collectMatches(menu, providers[0..provider_count], active_tab, "", &filtered);
    var selected = selectedCurrent(filtered[0..filtered_count], current) orelse 0;
    var scroll_top: usize = 0;
    var escape: u8 = 0;
    var csi_parameter: u8 = 0;
    const width = ui.width;
    const detected_rows = status_line.terminalRows();
    const rows = if (detected_rows == 0) 24 else detected_rows;
    const max_visible = maxVisibleRows(rows);
    const panel_width = @min(width -| 2, 78);
    const tab_width = panel_width - 2;
    keepTabVisible(providers[0..provider_count], active_tab, &tab_scroll, tab_width);
    keepSelectionVisible(selected, &scroll_top, max_visible);

    try ui.out.writeAll("\x1b[2J");
    try drawModelMenu(ui, menu, providers[0..provider_count], active_tab, tab_scroll, filtered[0..filtered_count], selected, scroll_top, query[0..query_len], current, width, rows, max_visible);
    while (true) {
        if (escape != 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN }};
            if (try std.posix.poll(&fds, 100) == 0) {
                if (escape == 1) {
                    try finishModelPicker(ui, &alternate_screen, true);
                    return null;
                }
                escape = 0;
                csi_parameter = 0;
                continue;
            }
        }
        var byte: [1]u8 = undefined;
        if (try Io.File.stdin().readStreaming(io, &.{&byte}) == 0) {
            try finishModelPicker(ui, &alternate_screen, true);
            return null;
        }
        const c = byte[0];
        if (escape == 1) {
            if (c == '[' or c == 'O') {
                escape = 2;
                csi_parameter = 0;
                continue;
            }
            escape = 0;
            try finishModelPicker(ui, &alternate_screen, true);
            return null;
        }
        if (escape == 2) {
            if (c >= 0x40 and c <= 0x7e) {
                escape = 0;
                switch (c) {
                    'A' => if (filtered_count > 0 and selected > 0) {
                        selected -= 1;
                    },
                    'B' => if (filtered_count > 0 and selected + 1 < filtered_count) {
                        selected += 1;
                    },
                    'H' => selected = 0,
                    'F' => if (filtered_count > 0) {
                        selected = filtered_count - 1;
                    },
                    'C' => active_tab = nextTab(active_tab, provider_count + 1, true),
                    'D' => active_tab = nextTab(active_tab, provider_count + 1, false),
                    'Z' => active_tab = nextTab(active_tab, provider_count + 1, false),
                    '~' => switch (csi_parameter) {
                        '1' => selected = 0,
                        '4' => if (filtered_count > 0) {
                            selected = filtered_count - 1;
                        },
                        '5' => selected = selected -| max_visible,
                        '6' => selected = @min(selected + max_visible, filtered_count -| 1),
                        else => {},
                    },
                    else => {},
                }
                csi_parameter = 0;
                if (c == 'C' or c == 'D' or c == 'Z') {
                    filtered_count = collectMatches(menu, providers[0..provider_count], active_tab, query[0..query_len], &filtered);
                    selected = selectedCurrent(filtered[0..filtered_count], current) orelse 0;
                    scroll_top = 0;
                    keepTabVisible(providers[0..provider_count], active_tab, &tab_scroll, tab_width);
                }
                keepSelectionVisible(selected, &scroll_top, max_visible);
                try drawModelMenu(ui, menu, providers[0..provider_count], active_tab, tab_scroll, filtered[0..filtered_count], selected, scroll_top, query[0..query_len], current, width, rows, max_visible);
            } else if (c >= '0' and c <= '9' and csi_parameter == 0) {
                csi_parameter = c;
            }
            continue;
        }
        switch (c) {
            27 => escape = 1,
            3, 4 => {
                try finishModelPicker(ui, &alternate_screen, true);
                return null;
            },
            '\t' => {
                active_tab = nextTab(active_tab, provider_count + 1, true);
                filtered_count = collectMatches(menu, providers[0..provider_count], active_tab, query[0..query_len], &filtered);
                selected = selectedCurrent(filtered[0..filtered_count], current) orelse 0;
                scroll_top = 0;
                keepTabVisible(providers[0..provider_count], active_tab, &tab_scroll, tab_width);
            },
            '\r', '\n' => {
                if (filtered_count > 0) {
                    const choice = filtered[selected];
                    try finishModelPicker(ui, &alternate_screen, false);
                    return choice + 1;
                }
            },
            8, 127 => if (query_len > 0) {
                query_len -= 1;
                filtered_count = collectMatches(menu, providers[0..provider_count], active_tab, query[0..query_len], &filtered);
                selected = selectedCurrent(filtered[0..filtered_count], current) orelse 0;
                scroll_top = 0;
            },
            21 => {
                query_len = 0;
                filtered_count = collectMatches(menu, providers[0..provider_count], active_tab, "", &filtered);
                selected = selectedCurrent(filtered[0..filtered_count], current) orelse 0;
                scroll_top = 0;
            },
            else => if (c >= 0x20 and c <= 0x7e and query_len < query.len) {
                query[query_len] = c;
                query_len += 1;
                filtered_count = collectMatches(menu, providers[0..provider_count], active_tab, query[0..query_len], &filtered);
                selected = 0;
                scroll_top = 0;
            },
        }
        keepSelectionVisible(selected, &scroll_top, max_visible);
        try drawModelMenu(ui, menu, providers[0..provider_count], active_tab, tab_scroll, filtered[0..filtered_count], selected, scroll_top, query[0..query_len], current, width, rows, max_visible);
    }
}

fn finishModelPicker(ui: Ui, alternate_screen: *bool, canceled: bool) !void {
    if (alternate_screen.*) {
        try ui.out.writeAll("\x1b[?1049l");
        alternate_screen.* = false;
    }
    if (ui.workspace != null) {
        if (canceled) try ui.output("Model selection canceled.");
        try ui.redrawWorkspace();
    } else if (canceled) try ui.out.writeAll("\nModel selection canceled.\n");
    try ui.out.flush();
}

fn collectProviders(menu: *const ModelMenu, providers: *[ModelMenu.max_items]Provider) usize {
    var count: usize = 0;
    for (0..menu.count) |idx| {
        const provider = menu.get(idx + 1).?.provider;
        var found = false;
        for (providers[0..count]) |existing| {
            if (existing == provider) {
                found = true;
                break;
            }
        }
        if (!found) {
            providers[count] = provider;
            count += 1;
        }
    }
    return count;
}

fn initialTab(menu: *const ModelMenu, providers: []const Provider, current: usize) usize {
    if (current == 0) return 0;
    const active = menu.get(current) orelse return 0;
    for (providers, 0..) |provider, idx| {
        if (provider == active.provider) return idx + 1;
    }
    return 0;
}

fn nextTab(active: usize, count: usize, forward: bool) usize {
    if (count == 0) return 0;
    if (forward) return if (active + 1 == count) 0 else active + 1;
    return if (active == 0) count - 1 else active - 1;
}

fn providerTabLabel(providers: []const Provider, tab: usize) []const u8 {
    return if (tab == 0) "All" else @tagName(providers[tab - 1]);
}

fn tabsFitThrough(providers: []const Provider, start: usize, active: usize, width: usize) bool {
    const count = providers.len + 1;
    var used: usize = if (start > 0) 2 else 0;
    for (start..active + 1) |tab| {
        if (tab != start or start > 0) used += 1;
        used += providerTabLabel(providers, tab).len + 2;
    }
    if (active + 1 < count) used += 2;
    return used <= width;
}

fn keepTabVisible(providers: []const Provider, active: usize, scroll: *usize, width: usize) void {
    if (active < scroll.*) scroll.* = active;
    while (scroll.* < active and !tabsFitThrough(providers, scroll.*, active, width)) scroll.* += 1;
}

fn maxVisibleRows(rows: usize) usize {
    const overhead: usize = if (rows < 12) 11 else 12;
    return @max(rows -| overhead, 1);
}

fn collectMatches(
    menu: *const ModelMenu,
    providers: []const Provider,
    active_tab: usize,
    query: []const u8,
    filtered: *[ModelMenu.max_items]usize,
) usize {
    var count: usize = 0;
    for (0..menu.count) |idx| {
        const item = menu.get(idx + 1).?;
        if (active_tab > 0 and item.provider != providers[active_tab - 1]) continue;
        if (!matchesQuery(menu, idx, query)) continue;
        filtered[count] = idx;
        count += 1;
    }
    return count;
}

fn matchesQuery(menu: *const ModelMenu, idx: usize, query: []const u8) bool {
    var terms = std.mem.tokenizeAny(u8, query, " \t/");
    const item = menu.get(idx + 1).?;
    const provider = @tagName(item.provider);
    while (terms.next()) |term| {
        if (!containsIgnoreCase(provider, term) and !containsIgnoreCase(item.model, term)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matches = true;
        for (needle, 0..) |expected, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(expected)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn selectedCurrent(filtered: []const usize, current: usize) ?usize {
    if (current == 0) return null;
    for (filtered, 0..) |idx, position| {
        if (idx + 1 == current) return position;
    }
    return null;
}

fn keepSelectionVisible(selected: usize, scroll_top: *usize, visible: usize) void {
    if (selected < scroll_top.*) {
        scroll_top.* = selected;
    } else if (selected >= scroll_top.* + visible) {
        scroll_top.* = selected - visible + 1;
    }
}

fn drawModelMenu(
    ui: Ui,
    menu: *const ModelMenu,
    providers: []const Provider,
    active_tab: usize,
    tab_scroll: usize,
    filtered: []const usize,
    selected: usize,
    scroll_top: usize,
    query: []const u8,
    current: usize,
    width: usize,
    rows: usize,
    max_visible: usize,
) !void {
    const visible = @min(@max(filtered.len, 1), max_visible);
    const panel_width = @min(width -| 2, 78);
    const inner_width = panel_width - 2;
    const compact = rows < 12;
    const panel_height = visible + (if (compact) @as(usize, 9) else 10);
    const top = 1 + (rows -| panel_height) / 2;
    const left = 1 + (width -| panel_width) / 2;

    try ui.out.writeAll("\x1b[2J\x1b[H");
    try drawModelBorder(ui, top, left, panel_width, "┌", "┐");
    try drawModelLineStart(ui, top + 1, left);
    try ui.out.writeAll(" ");
    try ui.out.writeAll("\x1b[1mSelect provider/model · * current\x1b[0m");
    try ui.out.writeAll(" │");

    try drawProviderTabs(ui, providers, active_tab, tab_scroll, top + 2, left, inner_width);

    try drawModelLineStart(ui, top + 3, left);
    try ui.out.writeAll(" Search: ");
    const query_width = inner_width -| 25;
    try writeSafeFit(ui, query, query_width);
    try ui.out.print(" · {d} matches", .{filtered.len});
    try ui.out.writeAll(" │");
    try drawModelBorder(ui, top + 4, left, panel_width, "├", "┤");

    if (filtered.len == 0) {
        try drawModelLineStart(ui, top + 5, left);
        try ui.out.writeAll(" No matching provider/model");
        try ui.out.writeAll(" │");
    } else {
        for (0..visible) |offset| {
            const position = scroll_top + offset;
            try drawModelLineStart(ui, top + 5 + offset, left);
            if (position >= filtered.len) {
                try ui.out.writeByte(' ');
                for (0..inner_width - 1) |_| try ui.out.writeByte(' ');
            } else {
                const item_index = filtered[position];
                const item = menu.get(item_index + 1).?;
                const is_selected = position == selected;
                const is_current = item_index + 1 == current;
                if (is_selected) try ui.out.writeAll("\x1b[30;46;1m");
                try ui.out.writeAll(if (is_current) " * " else "   ");
                try ui.out.writeAll(if (is_selected) "› " else "  ");
                const provider = @tagName(item.provider);
                try ui.writeSafeText(provider, provider.len);
                try ui.out.writeByte('/');
                const model_width = inner_width -| (6 + provider.len);
                const model_limit = if (model_width > 3) model_width - 3 else model_width;
                try ui.writeSafeText(item.model, model_limit);
                const model_chars = std.unicode.utf8CountCodepoints(item.model) catch item.model.len;
                const model_drawn = if (model_chars > model_limit) @min(model_limit + 3, model_width) else model_chars;
                const used = @min(inner_width, 6 + provider.len + model_drawn);
                for (0..inner_width - used) |_| try ui.out.writeByte(' ');
                if (is_selected) try ui.out.writeAll("\x1b[0m");
            }
            try ui.out.writeAll(" │");
        }
    }

    const separator = top + 5 + visible;
    try drawModelBorder(ui, separator, left, panel_width, "├", "┤");
    try drawModelLineStart(ui, separator + 1, left);
    try writeSafeFit(ui, if (compact) "↑/↓ move · type to search" else "←/→ tabs · ↑/↓ models · PgUp/PgDn pages", inner_width -| 2);
    try ui.out.writeAll(" │");
    if (compact) {
        try drawModelLineStart(ui, separator + 2, left);
        try ui.out.print("Enter select · Esc cancel: {d}/{d}", .{ if (filtered.len == 0) 0 else filtered[selected] + 1, menu.count });
    } else {
        try drawModelLineStart(ui, separator + 2, left);
        try writeSafeFit(ui, "Type filters · Backspace edits · Ctrl-U clears", inner_width -| 2);
        try ui.out.writeAll(" │");
        try drawModelLineStart(ui, separator + 3, left);
        try ui.out.print("Enter select · Esc cancel: {d}/{d}", .{ if (filtered.len == 0) 0 else filtered[selected] + 1, menu.count });
    }
    try ui.out.writeAll(" │");
    try drawModelBorder(ui, separator + (if (compact) @as(usize, 3) else 4), left, panel_width, "└", "┘");
    try ui.out.flush();
}

fn drawProviderTabs(ui: Ui, providers: []const Provider, active: usize, scroll: usize, row: usize, left: usize, width: usize) !void {
    try drawModelLineStart(ui, row, left);
    var used: usize = 0;
    if (scroll > 0) {
        try ui.out.writeAll("‹ ");
        used = 2;
    }
    var tab = scroll;
    const count = providers.len + 1;
    while (tab < count) : (tab += 1) {
        const label = providerTabLabel(providers, tab);
        const gap: usize = if (used == 0) 0 else 1;
        const right_marker: usize = if (tab + 1 < count) 2 else 0;
        if (used + gap + label.len + 2 + right_marker > width) break;
        if (gap > 0) {
            try ui.out.writeByte(' ');
            used += gap;
        }
        if (tab == active) try ui.out.writeAll("\x1b[30;46;1m");
        try ui.out.writeByte(if (tab == active) '[' else ' ');
        try ui.writeSafeText(label, label.len);
        try ui.out.writeByte(if (tab == active) ']' else ' ');
        if (tab == active) try ui.out.writeAll("\x1b[0m");
        used += label.len + 2;
    }
    if (tab < count) {
        try ui.out.writeAll(" ›");
        used += 2;
    }
    for (used..width) |_| try ui.out.writeByte(' ');
    try ui.out.writeAll(" │");
}

fn writeSafeFit(ui: Ui, text: []const u8, width: usize) !void {
    const limit = if (width > 3) width - 3 else width;
    try ui.writeSafeText(text, limit);
}

fn drawModelLineStart(ui: Ui, row: usize, col: usize) !void {
    try ui.out.print("\x1b[{d};{d}H│", .{ row, col });
}

fn drawModelBorder(ui: Ui, row: usize, col: usize, width: usize, start: []const u8, end: []const u8) !void {
    try ui.out.print("\x1b[{d};{d}H{s}", .{ row, col, start });
    for (0..width - 2) |_| try ui.out.writeAll("─");
    try ui.out.writeAll(end);
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
                    if (ui.workspace != null) try ui.output("Exit requested (Ctrl-C).") else try ui.out.writeAll("^C\n");
                    return null;
                }
                if (n == 0) {
                    self.empty_interrupt = true;
                    if (ui.workspace != null)
                        try ui.output("Input canceled. Press Ctrl-C again, Ctrl-D, or /exit to quit.")
                    else
                        try ui.out.writeAll("^C (press Ctrl-C again, Ctrl-D, or /exit to quit)\n");
                } else {
                    self.empty_interrupt = false;
                    if (ui.workspace != null) try ui.output("Input canceled.") else try ui.out.writeAll("^C\n");
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
                const page_up = std.mem.eql(u8, escape, "\x1b[5~");
                const page_down = std.mem.eql(u8, escape, "\x1b[6~");
                const shift_tab = std.mem.eql(u8, escape, "\x1b[Z");
                if (!paste and std.mem.indexOfScalar(u8, self.bytes[0..n], '\n') == null and (up or down)) {
                    const oldest = self.count -| self.history.len;
                    if (up and cursor > oldest) {
                        cursor -= 1;
                    } else if (down and cursor < self.count) {
                        cursor += 1;
                    }
                    const item = if (cursor < self.count) self.getHistory(cursor) else "";
                    @memcpy(self.bytes[0..item.len], item);
                    n = item.len;
                    try redrawInput(ui, item);
                } else if (!paste and ui.workspace != null and (shift_tab or page_up or page_down)) {
                    if (shift_tab) try ui.workspaceTab(false) else if (page_up)
                        try ui.workspaceScroll(12)
                    else
                        try ui.workspaceScroll(-12);
                    try redrawInput(ui, self.bytes[0..n]);
                }
                pending = 0;
                continue;
            }
            if (!paste and c == 4 and n == 0) return null;
            if (!paste and (c == '\r' or c == '\n')) {
                if (ui.workspace == null) try ui.out.writeByte('\n');
                if (overflow) return error.InputTooLong;
                self.record(std.mem.trim(u8, self.bytes[0..n], " \t\r"));
                return self.bytes[0..n];
            }
            if (!paste and c == '\t' and ui.workspace != null) {
                try ui.workspaceTab(true);
                try redrawInput(ui, self.bytes[0..n]);
                continue;
            }
            if (!paste and (c == 127 or c == 8)) {
                if (n == 0 or self.bytes[n - 1] == '\n') continue;
                n -= 1;
                while (n > 0 and self.bytes[n] & 0xc0 == 0x80) n -= 1;
                if (ui.workspace != null) try redrawInput(ui, self.bytes[0..n]) else try ui.out.writeAll("\x08 \x08");
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
