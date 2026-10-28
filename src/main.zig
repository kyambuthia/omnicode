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
    const args = try init.minimal.args.toSlice(a);
    const options = cli.Options.parse(args) catch |err| {
        if (jsonRequested(args)) try emitJsonError(init, a, err);
        return err;
    };
    return runParsed(init, a, args, options) catch |err| {
        if (options.json_output and !isOfflineCommand(args, options) and err != error.Canceled) try emitJsonError(init, a, err);
        return err;
    };
}

fn runParsed(init: std.process.Init, a: std.mem.Allocator, args: []const []const u8, options: cli.Options) !void {
    var secrets: core.Secrets = .{};
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const out = &output.interface;
    var progress_buffer: [4096]u8 = undefined;
    var progress_output = std.Io.File.Writer.init(.stderr(), init.io, &progress_buffer);
    var ui = core.Ui.init(if (options.json_output) &progress_output.interface else out, init.io, init.environ_map);
    if (options.json_output) {
        ui.interactive = false;
        ui.color = false;
    }
    ui.secrets = &secrets;
    var details: core.Details = .{};
    defer details.clear();
    ui.details = &details;
    var usage: core.Usage = .{};
    ui.usage = &usage;
    ui.verbose = options.verbose;
    const first = options.first;
    const mode = options.mode;
    const prompt_only = options.prompt_only;
    const read_only = options.read_only;
    const plan_mode = options.plan_mode;
    const dry_run = options.dry_run;
    const offline_command = isOfflineCommand(args, options);
    const json_output = options.json_output and !offline_command;
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
    if (options.json_output and !offline_command and (first == args.len or (!prompt_only and std.mem.startsWith(u8, args[first], "--")))) {
        return error.JsonRequiresPrompt;
    }
    const setup_command = if (!prompt_only and args.len > first and std.mem.eql(u8, args[first], "--setup"))
        try std.mem.join(a, " ", args[first + 1 ..])
    else
        null;
    defer if (setup_command) |command| std.crypto.secureZero(u8, @constCast(command));
    try core.config.loadForUpdate(a, init.io, .cwd(), init.environ_map, if (setup_command) |command| core.config.repairKey(command) else null);
    try secrets.load(a, init.io, .cwd(), init.environ_map);
    try secrets.injectEnv(init.environ_map);
    const context: core.Context = .{ .a = a, .io = init.io, .dir = .cwd(), .secrets = &secrets, .env = init.environ_map };
    if (!prompt_only and args.len == first + 1 and std.mem.eql(u8, args[first], "--skills")) {
        const skills = try context.skills();
        defer std.crypto.secureZero(u8, @constCast(skills));
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
        defer std.crypto.secureZero(u8, rest);
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
        defer std.crypto.secureZero(u8, rest);
        const msg = try secrets.execute(a, init.io, .cwd(), init.environ_map, rest);
        defer std.crypto.secureZero(u8, @constCast(msg));
        var full = ui;
        full.verbose = true;
        try full.preview(msg, "");
        return out.flush();
    }
    var route = try core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null);
    route.mode = mode;
    var tmux_feed: core.TmuxFeed = undefined;
    var tmux_feed_active = false;
    const tmux_tty = (std.Io.File.stdout().isTty(init.io) catch false) and
        !std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb");
    if (tmux_tty and !json_output and init.environ_map.get("TMUX_PANE") != null) {
        if (core.TmuxFeed.start(init.io, init.environ_map, ui.width)) |maybe_feed| {
            if (maybe_feed) |feed| {
                tmux_feed = feed;
                tmux_feed_active = true;
                ui.tmux_feed = &tmux_feed;
                ui.width = core.terminalWidth(init.environ_map);
            }
        } else |err| {
            if (err == error.Canceled) return err;
            try ui.note("Could not open a tmux Bash pane; Bash output will stay in the feed.");
        }
    }
    defer if (tmux_feed_active) tmux_feed.deinit();
    if (args.len > first) {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var todo: core.Todo = .{};
        var limiter: core.RequestLimiter = .{};
        var agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd(), .todo = &todo, .secrets = &secrets, .read_only = read_only }, init.environ_map, route);
        if (plan_mode) try agent.setPlanMode(true);
        agent.dry_run = dry_run;
        agent.rate_limiter = &limiter;
        if (session_name) |name| {
            agent.loadSession(name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            agent.checkpoint_name = name;
        }
        defer agent.clearPreviewedContent();
        const prompt = try std.mem.join(a, " ", args[first..]);
        defer std.crypto.secureZero(u8, prompt);
        if (tmux_feed_active) try ui.note("Bash output is in the tmux side pane.");
        var task_ui = ui;
        task_ui.details = null;
        agent.respond(prompt, task_ui) catch |err| {
            if (err == error.Canceled) return err;
            try ui.errorMessage(err);
            try ui.out.flush();
            return err;
        };
        if (json_output) {
            const result_text = try agent.resultText(a);
            defer std.crypto.secureZero(u8, @constCast(result_text));
            var proposed_tools: core.JsonValue = try agent.proposedTools(a);
            defer core.secureClearJson(std.heap.page_allocator, &proposed_tools) catch {};
            const encoded = try std.json.Stringify.valueAlloc(a, .{
                .ok = true,
                .text = result_text,
                .usage = usage,
                .dry_run = dry_run,
                .proposed_tools = proposed_tools,
            }, .{});
            defer std.crypto.secureZero(u8, encoded);
            try out.writeAll(encoded);
            try out.writeByte('\n');
            try out.flush();
        }
        return;
    }
    try @import("repl.zig").run(init, a, ui, &secrets, mode, read_only, plan_mode, dry_run, route);
}

fn isOfflineCommand(args: []const []const u8, options: cli.Options) bool {
    if (options.prompt_only or options.first >= args.len) return false;
    const command = args[options.first];
    return std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V") or
        std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--skills") or std.mem.eql(u8, command, "--init") or
        std.mem.eql(u8, command, "--providers") or std.mem.eql(u8, command, "--setup") or
        std.mem.eql(u8, command, "--secrets");
}

fn jsonRequested(args: []const []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn emitJsonError(init: std.process.Init, a: std.mem.Allocator, err: anyerror) !void {
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    try writeJsonError(a, &output.interface, err);
}

fn writeJsonError(a: std.mem.Allocator, out: *std.Io.Writer, err: anyerror) !void {
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .ok = false, .@"error" = @errorName(err) }, .{});
    try out.writeAll(encoded);
    try out.writeByte('\n');
    try out.flush();
}
