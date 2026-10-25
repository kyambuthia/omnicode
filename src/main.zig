const std = @import("std");
const core = @import("omnicode");
const help =
    \\omnicode [--free|--cost-max] [--verbose] [--read-only] [--session NAME] [prompt ...]       Run a task, or start a REPL without arguments.
    \\omnicode --version         Print version (v0.2.0).
    \\omnicode --skills          List project skills without an API call.
    \\omnicode --init            Initialize OMNICODE.md and .omnicode/skills/verify/SKILL.md.
    \\omnicode --providers [...] View, switch, or configure LLM providers and API keys.
    \\omnicode --setup [...]     View or configure provider API keys and settings.
    \\omnicode --secrets [...]   Manage zero-leak secrets (passwords, tokens, logins).
    \\--cost-max (default)      Optimize live OpenRouter catalog prices
    \\--session NAME            Resume and checkpoint a named one-shot task
    \\--read-only               Restrict model tools to read, glob, grep, and skill
    \\--free                    Only current zero-price OpenRouter tool models
    \\REPL commands:
    \\  /help                  Show this help
    \\  /providers [...]       List, switch, or configure providers & API keys (/providers <N|name> [key])
    \\  /setup [...]           Configure provider API keys and settings (saved to config.env)
    \\  /secrets [...]         Manage zero-leak secrets (injected in bash, scrubbed from chat)
    \\  /voice [sec|file]      Record or transcribe audio via cheap OpenRouter voice models
    \\  /init [force]          Bootstrap OMNICODE.md and verify skill
    \\  /review [focus]        Run adversarial multi-agent code review
    \\  /model [list]          Show current routing and numbered list of available models
    \\  /model <N|MODEL>       Switch to model #N or MODEL (preserves conversation)
    \\  /model PROVIDER MODEL  Switch provider and pin MODEL
    \\  /model auto|fast|strong  Select automatic routing or pin fast/strong tier
    \\  /skills, /skill NAME   List or load project instructions
    \\  /verbose on|off        Show full output for future tool calls
    \\  /status inline|pinned|title|off  Status line: provider, model, directory, local time
    \\  /usage                 Show cumulative usage (survives /c and model changes)
    \\  /context               Show conversation message and byte budget
    \\  /compact [focus]       Summarize older context on the fast model
    \\  /todo                  Show current session checklist
    \\  /save [name]           Save session under .omnicode/sessions/ (default: latest)
    \\  /resume [name]         Resume saved session (default: latest)
    \\  /details               Show last tool result (up to 64 KiB)
    \\  /c                     Clear conversation
    \\  /q, /exit, or exit     Quit (Ctrl-D also exits)
    \\Config: PROVIDER=abliteration|anthropic|openrouter|deepseek|xai|openai|gemini|groq, MODEL, FAST_MODEL, VOICE_MODEL, MAX_TURNS
    \\Keys: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, etc. (or run /setup). Searches require rg.
    \\Skills: .omnicode/skills/<name>/SKILL.md. Tools run with your permissions.
    \\
;

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
    var first: usize = 1;
    var mode: @FieldType(core.Route, "mode") = .cost_max;
    var policy_set = false;
    var prompt_only = false;
    var read_only = false;
    var session_name: ?[]const u8 = null;
    while (first < args.len) : (first += 1) {
        const arg = args[first];
        if (std.mem.eql(u8, arg, "--verbose")) {
            ui.verbose = true;
        } else if (std.mem.eql(u8, arg, "--read-only")) {
            read_only = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            if (session_name != null) return error.ConflictingOptions;
            first += 1;
            if (first == args.len) return error.MissingSessionName;
            session_name = args[first];
        } else if (std.mem.eql(u8, arg, "--free") or std.mem.eql(u8, arg, "--cost-max")) {
            const selected: @TypeOf(mode) = if (std.mem.eql(u8, arg, "--free")) .free else .cost_max;
            if (policy_set and selected != mode) return error.ConflictingOptions;
            mode = selected;
            policy_set = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            prompt_only = true;
            first += 1;
            break;
        } else if (std.mem.startsWith(u8, arg, "--") and !std.mem.eql(u8, arg, "--help") and !std.mem.eql(u8, arg, "--version") and !std.mem.eql(u8, arg, "--skills") and !std.mem.eql(u8, arg, "--init") and !std.mem.eql(u8, arg, "--providers") and !std.mem.eql(u8, arg, "--setup") and !std.mem.eql(u8, arg, "--secrets")) {
            return error.UnknownOption;
        } else break;
    }
    if (!prompt_only and args.len > first and (std.mem.eql(u8, args[first], "--version") or std.mem.eql(u8, args[first], "-V"))) {
        try out.writeAll("omnicode " ++ core.version ++ "\n");
        return out.flush();
    }
    if (!prompt_only and args.len > first and (std.mem.eql(u8, args[first], "--help") or std.mem.eql(u8, args[first], "-h"))) {
        try out.writeAll(help);
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
    var automatic = true;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var todo: core.Todo = .{};
    var menu: core.ModelMenu = .{};
    var agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd(), .todo = &todo, .secrets = &secrets, .read_only = read_only }, init.environ_map, route);
    if (session_name) |name| {
        agent.loadSession(name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        agent.checkpoint_name = name;
    }
    if (args.len > first) {
        agent.respond(try std.mem.join(a, " ", args[first..]), ui) catch |err| {
            if (err == error.Canceled) return err;
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
    defer {
        if (status.mode == .title) ui.titleStack(false) catch {};
        if (status.mode == .pinned) ui.resetScrollRegion() catch {};
    }
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
            if (err == error.Canceled) return err;
            if (err == error.InputCancelled) continue;
            if (err != error.InputTooLong) return err;
            try ui.errorMessage(err);
            continue;
        };
        const line = std.mem.trim(u8, value orelse break, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/q") or std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "exit")) break;
        if (std.mem.eql(u8, line, "/usage")) {
            try ui.usageSummary(usage, "Session");
            continue;
        }
        if (std.mem.eql(u8, line, "/context")) {
            const bytes = agent.historyBytes();
            const msgs = agent.history.items.len;
            const tok_pct = if (agent.context_length > 0) (agent.last_input_tokens * 100) / agent.context_length else 0;
            const pct = @max(@max((msgs * 100) / core.Agent.max_messages, (bytes * 100) / core.Agent.max_bytes), tok_pct);
            var note_buf: [200]u8 = undefined;
            try ui.note(std.fmt.bufPrint(&note_buf, "Context · {d}/{d} messages · {d}/{d} bytes · {d}/{d} tokens ({d}% of limit)", .{
                msgs, core.Agent.max_messages, bytes, core.Agent.max_bytes, agent.last_input_tokens, agent.context_length, pct,
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
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            agent.resetArena(&arena) catch {};
            continue;
        }
        if (std.mem.eql(u8, line, "/details")) {
            try ui.showDetails();
            continue;
        }
        if (std.mem.eql(u8, line, "/todo")) {
            try ui.preview(if (todo.len == 0) "(empty todo list)" else todo.slice(), "");
            continue;
        }
        if (std.mem.eql(u8, line, "/save") or std.mem.startsWith(u8, line, "/save ")) {
            const raw = if (line.len > 6) std.mem.trim(u8, line[6..], " \t") else "";
            const name = if (raw.len > 0) raw else "latest";
            agent.saveSession(name) catch |err| {
                if (err == error.Canceled) return err;
                try out.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            try ui.note("Session saved.");
            continue;
        }
        if (std.mem.eql(u8, line, "/resume") or std.mem.startsWith(u8, line, "/resume ")) {
            const raw = if (line.len > 8) std.mem.trim(u8, line[8..], " \t") else "";
            const name = if (raw.len > 0) raw else "latest";
            agent.loadSession(name) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            agent.resetArena(&arena) catch {};
            try agent.refreshSystem();
            try ui.note("Session resumed.");
            continue;
        }
        if (std.mem.eql(u8, line, "/skills")) {
            const skills = try agent.context.skills();
            try ui.skills(skills);
            continue;
        }
        if (std.mem.eql(u8, line, "/providers") or std.mem.startsWith(u8, line, "/providers ") or
            std.mem.eql(u8, line, "/provider") or std.mem.startsWith(u8, line, "/provider "))
        {
            const prefix_len: usize = if (std.mem.startsWith(u8, line, "/providers")) 10 else 9;
            const rest = if (line.len > prefix_len) std.mem.trim(u8, line[prefix_len..], " \t") else "";
            try redactRetained(&agent, &composer, &secrets, ui);
            const msg = core.config.executeProviders(a, init.io, .cwd(), init.environ_map, route.provider, rest) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            if (rest.len > 0 and !std.mem.eql(u8, rest, "list")) {
                if (mode == .free and !std.mem.eql(u8, init.environ_map.get("PROVIDER") orelse "openrouter", "openrouter")) {
                    try core.config.set(a, init.io, .cwd(), init.environ_map, "PROVIDER", "openrouter");
                    try ui.note("--free requires OpenRouter; provider switch rejected.");
                } else if (core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null)) |updated| {
                    route = updated;
                    route.mode = mode;
                    automatic = true;
                    agent.route = route;
                    agent.automatic = true;
                    status.setModel(route.model);
                } else |_| {}
            }
            var full = ui;
            full.verbose = true;
            try full.preview(msg, "");
            continue;
        }
        if (std.mem.eql(u8, line, "/setup") or std.mem.startsWith(u8, line, "/setup ")) {
            const rest = if (line.len > 7) std.mem.trim(u8, line[7..], " \t") else "";
            try redactRetained(&agent, &composer, &secrets, ui);
            const msg = core.config.execute(a, init.io, .cwd(), init.environ_map, rest) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            if (automatic) {
                if (core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null)) |updated| {
                    route = updated;
                    route.mode = mode;
                    agent.route = route;
                } else |_| {}
            } else {
                route.key = init.environ_map.get(route.provider.envKey()) orelse route.key;
                agent.route = route;
            }
            var full = ui;
            full.verbose = true;
            try full.preview(msg, "");
            continue;
        }
        if (std.mem.eql(u8, line, "/secrets") or std.mem.startsWith(u8, line, "/secrets ")) {
            const rest = if (line.len > 9) std.mem.trim(u8, line[9..], " \t") else "";
            try redactRetained(&agent, &composer, &secrets, ui);
            const msg = secrets.execute(a, init.io, .cwd(), init.environ_map, rest) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            try agent.refreshSystem();
            var full = ui;
            full.verbose = true;
            try full.preview(msg, "");
            continue;
        }
        if (std.mem.eql(u8, line, "/init") or std.mem.startsWith(u8, line, "/init ")) {
            const arg = if (line.len > 6) std.mem.trim(u8, line[6..], " \t") else "";
            if (arg.len > 0 and !std.mem.eql(u8, arg, "force")) {
                try out.writeAll("usage: /init [force]\n");
                continue;
            }
            const msg = agent.context.initProject(std.mem.eql(u8, arg, "force")) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            try agent.refreshSystem();
            try ui.note(msg);
            continue;
        }
        if (std.mem.eql(u8, line, "/review") or std.mem.startsWith(u8, line, "/review ")) {
            const focus = if (line.len > 8) std.mem.trim(u8, line[8..], " \t") else "";
            var rev_usage: core.Usage = .{};
            const report = agent.runReviewFocus(focus, ui, &rev_usage) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            try ui.retainDetails(report);
            var full = ui;
            full.verbose = true;
            try full.preview(report, "");
            try agent.history.append(arena.allocator(), .{
                .role = "user",
                .content = .{ .string = try std.fmt.allocPrint(arena.allocator(), "[Adversarial Review]\n{s}", .{report}) },
            });
            continue;
        }
        if (std.mem.eql(u8, line, "/help")) {
            try out.writeAll(help);
            continue;
        }
        if (std.mem.eql(u8, line, "/version")) {
            try ui.note("omnicode " ++ core.version);
            continue;
        }
        if (std.mem.eql(u8, line, "/model") or std.mem.eql(u8, line, "/model list")) {
            try ui.note(if (mode == .free) "--free: live zero-price tool models only; paid overrides are rejected." else "--cost-max (default): optimize live catalog prices within the ranked candidate pool.");
            if (automatic and route.provider == .openrouter) {
                try ui.note("Automatic model selection refreshes from OpenRouter before each turn.");
            } else {
                try ui.route(@tagName(route.provider), route.model);
                if (automatic) try ui.route("fast", route.forTask(init.environ_map, "lookup").model);
            }
            const list = try menu.populateAndFormat(a, init.io, init.environ_map, route, std.mem.eql(u8, line, "/model list"));
            var full = ui;
            full.verbose = true;
            try full.preview(list, "");
            continue;
        }
        if (std.mem.eql(u8, line, "/status") or std.mem.startsWith(u8, line, "/status ")) {
            const selected = if (line.len > 8) core.Status.parseMode(std.mem.trim(u8, line[8..], " ")) else null;
            const next = selected orelse {
                try out.print("usage: /status inline|pinned|title|off (current: {s})\n", .{core.Status.modeName(status.mode)});
                continue;
            };
            if (status.mode == .title and next != .title) try ui.titleStack(false);
            if (status.mode == .pinned and next != .pinned) try ui.resetScrollRegion();
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
            const first_tok = parts.next() orelse continue;
            const second_tok = parts.next();
            if (parts.next() != null) {
                try out.writeAll("too many model arguments\n");
                continue;
            }
            if (std.mem.eql(u8, first_tok, "auto") and second_tok == null) {
                route = try core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null);
                route.mode = mode;
                automatic = true;
                agent.route = route;
                agent.automatic = true;
                status.model_len = 0;
                try ui.note("Switched to automatic fast/strong model routing.");
                continue;
            }
            if (std.mem.eql(u8, first_tok, "fast") or std.mem.eql(u8, first_tok, "strong")) {
                const is_strong = std.mem.eql(u8, first_tok, "strong");
                if (second_tok) |custom| {
                    try init.environ_map.put(if (is_strong) "MODEL" else "FAST_MODEL", try a.dupe(u8, custom));
                }
                const target = route.forTask(init.environ_map, if (is_strong) "implement" else "lookup").model;
                route.model = try a.dupe(u8, target);
                automatic = false;
                agent.route = route;
                agent.automatic = false;
                status.setModel(route.model);
                try ui.route(@tagName(route.provider), route.model);
                continue;
            }
            var target_provider: []const u8 = @tagName(route.provider);
            var target_model: []const u8 = first_tok;
            if (second_tok) |m| {
                target_provider = first_tok;
                target_model = m;
            } else if (std.fmt.parseInt(usize, first_tok, 10) catch null) |num| {
                if (menu.count == 0) _ = try menu.populateAndFormat(a, init.io, init.environ_map, route, false);
                const choice = menu.get(num) orelse {
                    try out.writeAll("Invalid model number. Run /model to list available models.\n");
                    continue;
                };
                target_provider = @tagName(choice.provider);
                target_model = choice.model;
            } else if (std.meta.stringToEnum(core.Provider, first_tok) != null) {
                try out.writeAll("usage: /model [list] | /model <number> | /model auto | /model [PROVIDER] MODEL\n");
                continue;
            } else {
                const inferred = core.Provider.infer(first_tok, if (mode == .free) .openrouter else route.provider);
                target_provider = @tagName(inferred);
            }
            if (mode == .free and !std.mem.eql(u8, target_provider, "openrouter")) {
                try ui.note("--free requires OpenRouter; provider switch rejected.");
                continue;
            }
            route = core.Route.init(init.environ_map, target_provider, try a.dupe(u8, target_model)) catch |err| {
                try out.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            route.mode = mode;
            automatic = false;
            agent.route = route;
            agent.automatic = false;
            status.setModel(route.model);
            try ui.route(@tagName(route.provider), route.model);
            continue;
        } else if (std.mem.startsWith(u8, line, "/skill ")) {
            const body = agent.context.loadSkill(line[7..]) catch |err| {
                if (err == error.Canceled) return err;
                try out.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
            try agent.history.append(arena.allocator(), .{ .role = "user", .content = .{ .string = body } });
            try out.writeAll("Skill loaded for this conversation.\n");
            continue;
        } else if (!std.mem.eql(u8, line, "/c")) {
            var active_prompt = line;
            if (std.mem.eql(u8, line, "/voice") or std.mem.startsWith(u8, line, "/voice ")) {
                const varg = if (line.len > 7) std.mem.trim(u8, line[7..], " \t") else "";
                if (std.mem.eql(u8, varg, "model") or std.mem.startsWith(u8, varg, "model ")) {
                    const mval = if (varg.len > 6) std.mem.trim(u8, varg[6..], " \t") else "";
                    if (mval.len == 0) {
                        const cur = init.environ_map.get("VOICE_MODEL") orelse "auto (cheapest OpenRouter audio model)";
                        try ui.note(try std.fmt.allocPrint(a, "Voice model: {s}", .{cur}));
                    } else {
                        core.config.set(a, init.io, .cwd(), init.environ_map, "VOICE_MODEL", mval) catch |err| {
                            if (err == error.Canceled) return err;
                            try ui.errorMessage(err);
                            continue;
                        };
                        try ui.note(try std.fmt.allocPrint(a, "Saved VOICE_MODEL = {s}", .{mval}));
                    }
                    continue;
                }
                const audio_path = blk: {
                    if (varg.len == 0 or std.mem.eql(u8, varg, "record") or std.mem.startsWith(u8, varg, "record ")) {
                        const sec_str = if (std.mem.startsWith(u8, varg, "record")) std.mem.trim(u8, varg[6..], " \t") else "";
                        const secs = if (sec_str.len == 0) 5 else std.fmt.parseInt(usize, sec_str, 10) catch {
                            try out.writeAll("usage: /voice [seconds|file.wav] | /voice record [seconds] | /voice model [MODEL]\n");
                            continue;
                        };
                        break :blk core.voice.recordAudio(agent.context, init.environ_map, secs) catch |err| {
                            if (err == error.Canceled) return err;
                            try ui.errorMessage(err);
                            continue;
                        };
                    }
                    if (std.fmt.parseInt(usize, varg, 10)) |secs| {
                        break :blk core.voice.recordAudio(agent.context, init.environ_map, secs) catch |err| {
                            if (err == error.Canceled) return err;
                            try ui.errorMessage(err);
                            continue;
                        };
                    } else |_| {
                        break :blk varg;
                    }
                };
                const transcript = core.voice.transcribeFile(agent.context, init.environ_map, route, audio_path, ui) catch |err| {
                    if (err == error.Canceled) return err;
                    try ui.errorMessage(err);
                    continue;
                };
                try ui.note(try std.fmt.allocPrint(a, "Voice: {s}", .{transcript}));
                active_prompt = transcript;
            } else if (line[0] == '/') {
                try out.writeAll("Unknown command. Use /help for available commands.\n");
                continue;
            }
            agent.respond(active_prompt, ui) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                if (agent.retainCompletedWork(arena.allocator()) catch false) {
                    if (agent.resetArena(&arena)) |_| {
                        try out.writeAll("  completed work retained in summary. Inspect tool effects, then enter continue to resume.\n");
                        continue;
                    } else |_| {}
                }
                try out.writeAll("  conversation cleared. Inspect completed tool effects before retrying.\n");
                agent.history.clearRetainingCapacity();
                // Reinitialize below so failed tool turns cannot poison later messages.
            };
            // Keep complete history after successful turns; reset after errors.
            if (agent.history.items.len != 0 and agent.history.items.len <= core.Agent.max_messages) continue;
        }
        _ = arena.reset(.free_all);
        todo.len = 0;
        route.mode = mode;
        agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd(), .todo = &todo, .secrets = &secrets, .read_only = read_only }, init.environ_map, route);
        agent.automatic = automatic;
        try out.writeAll("Conversation cleared.\n");
    }
}

// Run before any command that can replace or remove credentials.
fn redactRetained(agent: *core.Agent, composer: *core.Input, secrets: *const core.Secrets, ui: core.Ui) !void {
    try agent.redactHistory();
    try composer.redactHistory(secrets, agent.env);
    if (ui.details) |retained| if (retained.present) {
        const truncated = retained.truncated;
        const snapshot = try agent.context.a.dupe(u8, retained.bytes[0..retained.len]);
        try ui.retainDetails(snapshot);
        retained.truncated = retained.truncated or truncated;
    };
}
