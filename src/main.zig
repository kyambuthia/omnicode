const std = @import("std");
const core = @import("omnicode");
const help =
    \\omnicode [--verbose] [prompt ...]       Run a task, or start a REPL without arguments.
    \\omnicode --skills          List project skills without an API call.
    \\REPL commands:
    \\  /help                  Show this help
    \\  /model                 Show the current routing mode
    \\  /model auto            Select fast/strong models automatically
    \\  /model PROVIDER MODEL  Pin a model (clears conversation)
    \\  /skills, /skill NAME   List or load project instructions
    \\  /verbose on|off        Show full output for future tool calls
    \\  /details               Show last tool result (up to 64 KiB)
    \\  /c                     Clear conversation
    \\  /q or exit             Quit (Ctrl-D also exits)
    \\Config: PROVIDER=anthropic|openrouter, MODEL, FAST_MODEL, API_URL
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
    var first: usize = 1;
    if (args.len > first and std.mem.eql(u8, args[first], "--verbose")) {
        ui.verbose = true;
        first += 1;
    }
    if (args.len > first and (std.mem.eql(u8, args[first], "--help") or std.mem.eql(u8, args[first], "-h"))) {
        try out.writeAll(help);
        return out.flush();
    }
    const context: core.Context = .{ .a = a, .io = init.io };
    if (args.len == first + 1 and std.mem.eql(u8, args[first], "--skills")) {
        const skills = try context.skills();
        try ui.skills(skills);
        return out.flush();
    }
    var route = try core.Route.init(init.environ_map, null, null);
    var automatic = true;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io }, init.environ_map, route);
    if (args.len > first) {
        agent.respond(try std.mem.join(a, " ", args[first..]), ui) catch |err| {
            try ui.errorMessage(err);
            try out.flush();
            return err;
        };
        return;
    }
    try ui.banner(@tagName(route.provider), try std.process.currentPathAlloc(init.io, a));
    var input_buffer: [16 * 1024]u8 = undefined;
    var input = std.Io.File.Reader.init(.stdin(), init.io, &input_buffer);
    while (true) {
        try ui.prompt();
        const line = std.mem.trim(u8, (try input.interface.takeDelimiter('\n')) orelse break, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/q") or std.mem.eql(u8, line, "exit")) break;
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
            try ui.note(if (automatic) "Automatic routing: fast for lookups, strong for development." else "Pinned model (automatic routing disabled).");
            try ui.route(@tagName(route.provider), route.model);
            if (automatic) try ui.route("fast", route.forTask(init.environ_map, "lookup").model);
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
                route = try core.Route.init(init.environ_map, null, null);
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
                try out.writeAll("  conversation cleared. Inspect completed tool effects before retrying.\n");
                agent.history.clearRetainingCapacity();
                // Reinitialize below so failed tool turns cannot poison later messages.
            };
            // Keep complete history after successful turns; reset after errors.
            if (agent.history.items.len != 0 and agent.history.items.len <= 128) continue;
        }
        _ = arena.reset(.free_all);
        agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io }, init.environ_map, route);
        agent.automatic = automatic;
        try out.writeAll("Conversation cleared.\n");
    }
}
