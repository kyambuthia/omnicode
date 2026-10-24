const std = @import("std");
const core = @import("omnicode");
const help =
    \\omnicode [--free|--cost-max] [--verbose] [prompt ...]       Run a task, or start a REPL without arguments.
    \\omnicode --skills          List project skills without an API call.
    \\--cost-max (default)      Optimize live OpenRouter catalog prices
    \\--free                    Only current zero-price OpenRouter tool models
    \\REPL commands:
    \\  /help                  Show this help
    \\  /model                 Show the current routing mode
    \\  /model auto            Select fast/strong models automatically
    \\  /model PROVIDER MODEL  Pin a model (clears conversation)
    \\  /skills, /skill NAME   List or load project instructions
    \\  /verbose on|off        Show full output for future tool calls
    \\  /status inline|title|off  Status line: provider, model, directory, local time
    \\  /usage                 Show cumulative usage (survives /c and model changes)
    \\  /context               Show conversation message and byte budget
    \\  /compact [focus]       Summarize older context on the fast model
    \\  /details               Show last tool result (up to 64 KiB)
    \\  /c                     Clear conversation
    \\  /q or exit             Quit (Ctrl-D also exits)
    \\Config: PROVIDER=anthropic|openrouter, MODEL, FAST_MODEL, API_URL, MODELS_URL, OMNICODE_STATUS
    \\Keys: ANTHROPIC_API_KEY or OPENROUTER_API_KEY. Searches require rg.
    \\Skills: .omnicode/skills/<name>/SKILL.md. Tools run with your permissions.
    \\
;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const out = &output.interface;
    var ui = core.Ui.init(out, init.io, init.environ_map);
    var details: core.Details = .{};
    ui.details = &details;
    var usage: core.Usage = .{};
    ui.usage = &usage;
    var first: usize = 1;
    var mode: @FieldType(core.Route, "mode") = .cost_max;
    var policy_set = false;
    var prompt_only = false;
    while (first < args.len) : (first += 1) {
        const arg = args[first];
        if (std.mem.eql(u8, arg, "--verbose")) {
            ui.verbose = true;
        } else if (std.mem.eql(u8, arg, "--free") or std.mem.eql(u8, arg, "--cost-max")) {
            const selected: @TypeOf(mode) = if (std.mem.eql(u8, arg, "--free")) .free else .cost_max;
            if (policy_set and selected != mode) return error.ConflictingOptions;
            mode = selected;
            policy_set = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            prompt_only = true;
            first += 1;
            break;
        } else if (std.mem.startsWith(u8, arg, "--") and !std.mem.eql(u8, arg, "--help") and !std.mem.eql(u8, arg, "--skills")) {
            return error.UnknownOption;
        } else break;
    }
    if (!prompt_only and args.len > first and (std.mem.eql(u8, args[first], "--help") or std.mem.eql(u8, args[first], "-h"))) {
        try out.writeAll(help);
        return out.flush();
    }
    const context: core.Context = .{ .a = a, .io = init.io, .dir = .cwd() };
    if (!prompt_only and args.len == first + 1 and std.mem.eql(u8, args[first], "--skills")) {
        const skills = try context.skills();
        try ui.skills(skills);
        return out.flush();
    }
    var route = try core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null);
    route.mode = mode;
    var automatic = true;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd() }, init.environ_map, route);
    if (args.len > first) {
        agent.respond(try std.mem.join(a, " ", args[first..]), ui) catch |err| {
            try ui.errorMessage(err);
            try out.flush();
            return err;
        };
        return;
    }
    const cwd = try std.process.currentPathAlloc(init.io, a);
    try ui.banner(@tagName(route.provider), cwd);
    var status: core.Status = .{ .clock = core.Clock.load(a, init.io, init.environ_map) };
    if (init.environ_map.get("OMNICODE_STATUS")) |name| status.mode = core.Status.parseMode(name) orelse return error.InvalidStatusMode;
    ui.status = &status;
    const dir = try core.shortenHome(a, cwd, init.environ_map.get("HOME") orelse "");
    if (status.mode == .title) try ui.titleStack(true);
    defer if (status.mode == .title) ui.titleStack(false) catch {};
    var input_buffer: [16 * 1024]u8 = undefined;
    var input = std.Io.File.Reader.init(.stdin(), init.io, &input_buffer);
    var composer: core.Input = .{};
    while (true) {
        if (ui.interactive) ui.width = core.terminalWidth(init.environ_map);
        var label: [256]u8 = undefined;
        const policy = if (route.provider == .anthropic) "auto" else if (mode == .free) "auto (free)" else "auto (cost-max)";
        const model_label = if (!automatic) route.model else if (status.lastModel().len == 0) policy else std.fmt.bufPrint(&label, "{s} → {s}", .{ policy, status.lastModel() }) catch policy;
        var ctx_buf: [32]u8 = undefined;
        const ctx_label = if (agent.history.items.len == 0) "" else std.fmt.bufPrint(&ctx_buf, "{d}m", .{agent.history.items.len}) catch "";
        try ui.statusBar(@tagName(route.provider), model_label, dir, ctx_label);
        try ui.prompt();
        const value = composer.read(init.io, ui, &input.interface) catch |err| {
            if (err == error.InputCancelled) continue;
            if (err != error.InputTooLong) return err;
            try ui.errorMessage(err);
            continue;
        };
        const line = std.mem.trim(u8, value orelse break, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/q") or std.mem.eql(u8, line, "exit")) break;
        if (std.mem.eql(u8, line, "/usage")) {
            try ui.usageSummary(usage, "Session");
            continue;
        }
        if (std.mem.eql(u8, line, "/context")) {
            const bytes = agent.historyBytes();
            const msgs = agent.history.items.len;
            const pct = @max((msgs * 100) / core.Agent.max_messages, (bytes * 100) / core.Agent.max_bytes);
            var note_buf: [160]u8 = undefined;
            try ui.note(std.fmt.bufPrint(&note_buf, "Context · {d}/{d} messages · {d}/{d} bytes ({d}% of limit)", .{
                msgs, core.Agent.max_messages, bytes, core.Agent.max_bytes, pct,
            }) catch "Context status");
            continue;
        }
        if (std.mem.eql(u8, line, "/compact") or std.mem.startsWith(u8, line, "/compact ")) {
            if (agent.history.items.len == 0) {
                try ui.note("Nothing to compact.");
                continue;
            }
            const focus = if (line.len > 9) std.mem.trim(u8, line[9..], " \t") else "";
            agent.compact(ui, null, if (focus.len > 0) focus else null) catch |err| {
                try ui.errorMessage(err);
                continue;
            };
            var fresh = std.heap.ArenaAllocator.init(init.gpa);
            agent.reallocate(fresh.allocator()) catch {
                fresh.deinit();
                continue;
            };
            arena.deinit();
            arena = fresh;
            continue;
        }
        if (std.mem.eql(u8, line, "/details")) {
            try ui.showDetails();
            continue;
        }
        if (std.mem.eql(u8, line, "/skills")) {
            const skills = try agent.context.skills();
            try ui.skills(skills);
            continue;
        }
        if (std.mem.eql(u8, line, "/help")) {
            try out.writeAll(help);
            continue;
        }
        if (std.mem.eql(u8, line, "/model")) {
            try ui.note(if (mode == .free) "--free: live zero-price tool models only; paid overrides are rejected." else "--cost-max (default): optimize live catalog prices within the ranked candidate pool.");
            if (automatic and route.provider == .openrouter) {
                try ui.note("Automatic model selection refreshes from OpenRouter before each turn.");
            } else {
                try ui.route(@tagName(route.provider), route.model);
                if (automatic) try ui.route("fast", route.forTask(init.environ_map, "lookup").model);
            }
            continue;
        }
        if (std.mem.eql(u8, line, "/status") or std.mem.startsWith(u8, line, "/status ")) {
            const selected = if (line.len > 8) core.Status.parseMode(std.mem.trim(u8, line[8..], " ")) else null;
            const next = selected orelse {
                try out.print("usage: /status inline|title|off (current: {s})\n", .{core.Status.modeName(status.mode)});
                continue;
            };
            if (status.mode == .title and next != .title) try ui.titleStack(false);
            if (status.mode != .title and next == .title) try ui.titleStack(true);
            status.mode = next;
            try ui.note(if (ui.interactive) "Status line updated." else "Status line applies to interactive terminals only.");
            continue;
        }
        if (std.mem.startsWith(u8, line, "/verbose")) {
            if (std.mem.eql(u8, line, "/verbose on")) ui.verbose = true else if (std.mem.eql(u8, line, "/verbose off")) ui.verbose = false else {
                try out.writeAll("usage: /verbose on|off\n");
                continue;
            }
            try ui.note(if (ui.verbose) "Full tool output enabled for future calls." else "Compact tool output enabled.");
            continue;
        }
        if (std.mem.startsWith(u8, line, "/model ")) {
            var parts = std.mem.tokenizeScalar(u8, line[7..], ' ');
            const provider = parts.next() orelse continue;
            if (std.mem.eql(u8, provider, "auto") and parts.next() == null) {
                route = try core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null);
                automatic = true;
            } else {
                const model = parts.next() orelse {
                    try out.writeAll("usage: /model auto | /model PROVIDER MODEL\n");
                    continue;
                };
                if (parts.next() != null) {
                    try out.writeAll("too many model arguments\n");
                    continue;
                }
                if (mode == .free and !std.mem.eql(u8, provider, "openrouter")) {
                    try ui.note("--free requires OpenRouter; provider switch rejected.");
                    continue;
                }
                route = core.Route.init(init.environ_map, provider, try a.dupe(u8, model)) catch |err| {
                    try out.print("error: {s}\n", .{@errorName(err)});
                    continue;
                };
                automatic = false;
            }
        } else if (std.mem.startsWith(u8, line, "/skill ")) {
            const body = agent.context.loadSkill(line[7..]) catch |err| {
                try out.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            try agent.history.append(arena.allocator(), .{ .role = "user", .content = .{ .string = body } });
            try out.writeAll("Skill loaded for this conversation.\n");
            continue;
        } else if (!std.mem.eql(u8, line, "/c")) {
            if (line[0] == '/') {
                try out.writeAll("Unknown command. Use /help for available commands.\n");
                continue;
            }
            agent.respond(line, ui) catch |err| {
                try ui.errorMessage(err);
                var fresh = std.heap.ArenaAllocator.init(init.gpa);
                if (agent.retainCompletedWork(fresh.allocator()) catch false) {
                    if (agent.reallocate(fresh.allocator())) |_| {
                        arena.deinit();
                        arena = fresh;
                        try out.writeAll("  completed work retained in summary. Inspect tool effects before retrying.\n");
                        continue;
                    } else |_| {}
                }
                fresh.deinit();
                try out.writeAll("  conversation cleared. Inspect completed tool effects before retrying.\n");
                agent.history.clearRetainingCapacity();
                // Reinitialize below so failed tool turns cannot poison later messages.
            };
            // Keep complete history after successful turns; reset after errors.
            if (agent.history.items.len != 0 and agent.history.items.len <= core.Agent.max_messages) continue;
        }
        _ = arena.reset(.free_all);
        route.mode = mode;
        agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd() }, init.environ_map, route);
        agent.automatic = automatic;
        try out.writeAll("Conversation cleared.\n");
    }
}
