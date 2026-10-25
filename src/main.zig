const std = @import("std");
const core = @import("omnicode");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) void {
    @import("interrupt.zig").run(init.io, run, .{init}) catch |err| {
        if (err == error.Interrupted) std.process.exit(130);
        if (err == error.Terminated) std.process.exit(143);
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var secrets: core.Secrets = .{};
    const args = try init.minimal.args.toSlice(a);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const out = &output.interface;
    var ui = core.Ui.init(out, init.io, init.environ_map);
    ui.secrets = &secrets;
    var details: core.Details = .{};
    ui.details = &details;
    var usage: core.Usage = .{};
    ui.usage = &usage;
    const options = try cli.Options.parse(args);
    ui.verbose = options.verbose;
    const first = options.first;
    const mode = options.mode;
    const prompt_only = options.prompt_only;
    const read_only = options.read_only;
    const dry_run = options.dry_run;
    const session_name = options.session_name;
    if (!prompt_only and args.len > first and (std.mem.eql(u8, args[first], "--version") or std.mem.eql(u8, args[first], "-V"))) {
        try out.writeAll("omnicode " ++ core.version ++ "\n");
        return out.flush();
    }
    if (!prompt_only and args.len > first and (std.mem.eql(u8, args[first], "--help") or std.mem.eql(u8, args[first], "-h"))) {
        try out.writeAll(cli.help);
        return out.flush();
    }
    if (session_name) |name| {
        if (!core.validName(name)) return error.InvalidSessionName;
        if (first == args.len or (!prompt_only and std.mem.startsWith(u8, args[first], "-")))
            return error.SessionRequiresPrompt;
    }
    const setup_command = if (!prompt_only and args.len > first and std.mem.eql(u8, args[first], "--setup"))
        try std.mem.join(a, " ", args[first + 1 ..])
    else
        null;
    try core.config.loadForUpdate(a, init.io, .cwd(), init.environ_map, if (setup_command) |command| core.config.repairKey(command) else null);
    try secrets.load(a, init.io, .cwd(), init.environ_map);
    try secrets.injectEnv(init.environ_map);
    const context: core.Context = .{ .a = a, .io = init.io, .dir = .cwd(), .secrets = &secrets, .env = init.environ_map };
    if (!prompt_only and args.len == first + 1 and std.mem.eql(u8, args[first], "--skills")) {
        const skills = try context.skills();
        try ui.skills(skills);
        return out.flush();
    }
    if (!prompt_only and args.len >= first + 1 and std.mem.eql(u8, args[first], "--init")) {
        const force = args.len == first + 2 and std.mem.eql(u8, args[first + 1], "force");
        if (args.len > first + 1 and !force) return error.UnknownOption;
        const msg = try context.initProject(force);
        try ui.note(msg);
        return out.flush();
    }
    if (!prompt_only and args.len >= first + 1 and std.mem.eql(u8, args[first], "--providers")) {
        const rest = try std.mem.join(a, " ", args[first + 1 ..]);
        const msg = try core.config.executeProviders(a, init.io, .cwd(), init.environ_map, null, rest);
        var full = ui;
        full.verbose = true;
        try full.preview(msg, "");
        return out.flush();
    }
    if (setup_command != null) {
        const msg = try core.config.execute(a, init.io, .cwd(), init.environ_map, setup_command.?);
        var full = ui;
        full.verbose = true;
        try full.preview(msg, "");
        return out.flush();
    }
    if (!prompt_only and args.len >= first + 1 and std.mem.eql(u8, args[first], "--secrets")) {
        const rest = try std.mem.join(a, " ", args[first + 1 ..]);
        const msg = try secrets.execute(a, init.io, .cwd(), init.environ_map, rest);
        var full = ui;
        full.verbose = true;
        try full.preview(msg, "");
        return out.flush();
    }
    var route = try core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null);
    route.mode = mode;
    if (args.len > first) {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var todo: core.Todo = .{};
        var agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd(), .todo = &todo, .secrets = &secrets, .read_only = read_only }, init.environ_map, route);
        agent.dry_run = dry_run;
        if (session_name) |name| {
            agent.loadSession(name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            agent.checkpoint_name = name;
        }
        agent.respond(try std.mem.join(a, " ", args[first..]), ui) catch |err| {
            if (err == error.Canceled) return err;
            try ui.errorMessage(err);
            try out.flush();
            return err;
        };
        return;
    }
    try @import("repl.zig").run(init, a, ui, &secrets, mode, read_only, dry_run, route);
}
