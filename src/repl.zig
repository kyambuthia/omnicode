const std = @import("std");
const core = @import("omnicode");
const cli = @import("cli.zig");

pub fn run(init: std.process.Init, a: std.mem.Allocator, initial_ui: core.Ui, secrets: *core.Secrets, mode: @FieldType(core.Route, "mode"), read_only: bool, initial_plan_mode: bool, dry_run: bool, initial_route: core.Route) !void {
    var ui = initial_ui;
    const out = ui.out;
    const usage = ui.usage.?;
    var route = initial_route;
    var automatic = true;
    var plan_mode = initial_plan_mode;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var todo: core.Todo = .{};
    var limiter: core.RequestLimiter = .{};
    var menu: core.ModelMenu = .{};
    var agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd(), .todo = &todo, .secrets = secrets, .read_only = read_only }, init.environ_map, route);
    if (plan_mode) try agent.setPlanMode(true);
    agent.dry_run = dry_run;
    agent.rate_limiter = &limiter;
    const cwd = try std.process.currentPathAlloc(init.io, a);
    try ui.banner(@tagName(route.provider), cwd);
    var status: core.Status = .{ .clock = core.Clock.load(a, init.io, init.environ_map) };
    if (init.environ_map.get("OMNICODE_STATUS")) |name| status.mode = core.Status.parseMode(name) orelse return error.InvalidStatusMode;
    ui.status = &status;
    if (plan_mode) try ui.note("Plan mode active. Use /plan off to allow edits and commands.");
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
        var voice_prompt: ?[]const u8 = null;
        defer if (voice_prompt) |prompt_text| std.crypto.secureZero(u8, @constCast(prompt_text));
        if (ui.interactive) ui.width = core.terminalWidth(init.environ_map);
        var label: [256]u8 = undefined;
        const policy = if (route.provider == .anthropic) "auto" else if (mode == .free) "auto (free)" else "auto (cost-max)";
        const model_label = if (!automatic) route.model else if (status.lastModel().len == 0) policy else std.fmt.bufPrint(&label, "{s} → {s}", .{ policy, status.lastModel() }) catch policy;
        var ctx_buf: [32]u8 = undefined;
        const ctx_label = if (agent.history.items.len == 0) "" else std.fmt.bufPrint(&ctx_buf, "{d}m", .{agent.history.items.len}) catch "";
        try ui.statusBar(@tagName(route.provider), model_label, dir, ctx_label);
        try ui.prompt();
        const value = composer.read(init.io, ui, &input.interface) catch |err| {
            if (err == error.Canceled) {
                composer.clearCurrent();
                return err;
            }
            if (err == error.InputCancelled) {
                composer.clearCurrent();
                continue;
            }
            if (err != error.InputTooLong) {
                composer.clearCurrent();
                return err;
            }
            composer.clearCurrent();
            try ui.errorMessage(err);
            continue;
        };
        const raw_line = value orelse {
            composer.clearCurrent();
            break;
        };
        defer composer.clearCurrent();
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/q") or std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "exit")) break;
        if (std.mem.eql(u8, line, "/usage")) {
            try ui.usageSummary(usage.*, "Session");
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
            try agent.resetArena(&arena);
            continue;
        }
        if (std.mem.eql(u8, line, "/details")) {
            try ui.showDetails();
            continue;
        }
        if (std.mem.eql(u8, line, "/out") or std.mem.startsWith(u8, line, "/out ")) {
            const raw = if (line.len > 5) std.mem.trim(u8, line[5..], " \t") else "";
            const id_text = if (std.mem.startsWith(u8, raw, "#")) raw[1..] else raw;
            const id = std.fmt.parseInt(usize, id_text, 10) catch {
                try ui.note("usage: /out <call-id> (for example: /out 3)");
                continue;
            };
            try ui.showOutput(id);
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
        if (std.mem.eql(u8, line, "/export") or std.mem.startsWith(u8, line, "/export ")) {
            const raw = if (line.len > 8) std.mem.trim(u8, line[8..], " \t") else "";
            const name = if (raw.len > 0) raw else "latest";
            const path = agent.exportMarkdown(name) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            try ui.note(try std.fmt.allocPrint(a, "Exported session to {s}", .{path}));
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
            try agent.resetArena(&arena);
            try agent.refreshSystem();
            try ui.note("Session resumed.");
            continue;
        }
        if (std.mem.eql(u8, line, "/skills")) {
            const skills = try agent.context.skills();
            defer std.crypto.secureZero(u8, @constCast(skills));
            try ui.skills(skills);
            continue;
        }
        if (std.mem.eql(u8, line, "/providers") or std.mem.startsWith(u8, line, "/providers ") or
            std.mem.eql(u8, line, "/provider") or std.mem.startsWith(u8, line, "/provider "))
        {
            const prefix_len: usize = if (std.mem.startsWith(u8, line, "/providers")) 10 else 9;
            const rest = if (line.len > prefix_len) std.mem.trim(u8, line[prefix_len..], " \t") else "";
            try redactRetained(&agent, &composer, secrets, ui);
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
            try redactRetained(&agent, &composer, secrets, ui);
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
                refreshRouteEnvironment(&route, init.environ_map);
                agent.route = route;
            }
            var full = ui;
            full.verbose = true;
            try full.preview(msg, "");
            continue;
        }
        if (std.mem.eql(u8, line, "/secrets") or std.mem.startsWith(u8, line, "/secrets ")) {
            const rest = if (line.len > 9) std.mem.trim(u8, line[9..], " \t") else "";
            try redactRetained(&agent, &composer, secrets, ui);
            const msg = secrets.execute(a, init.io, .cwd(), init.environ_map, rest) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            defer std.crypto.secureZero(u8, @constCast(msg));
            try agent.refreshSystem();
            if (automatic) {
                if (core.Route.init(init.environ_map, if (mode == .free) "openrouter" else null, null)) |updated| {
                    route = updated;
                    route.mode = mode;
                } else |_| {
                    refreshRouteEnvironment(&route, init.environ_map);
                }
            } else {
                refreshRouteEnvironment(&route, init.environ_map);
            }
            agent.route = route;
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
            defer std.crypto.secureZero(u8, @constCast(report));
            try ui.retainDetails(report);
            var full = ui;
            full.verbose = true;
            try full.preview(report, "");
            try agent.history.append(arena.allocator(), .{
                .role = "user",
                .content = .{ .string = try std.fmt.allocPrint(arena.allocator(), "[Adversarial Review]\n{s}", .{report}) },
                .owns_text = true,
            });
            continue;
        }
        if (std.mem.eql(u8, line, "/help")) {
            try out.writeAll(cli.help);
            continue;
        }
        if (std.mem.eql(u8, line, "/version")) {
            try ui.note("omnicode " ++ core.version);
            continue;
        }
        if (std.mem.eql(u8, line, "/model compare")) {
            const comparison = menu.compare(a, init.io, init.environ_map, route) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                continue;
            };
            var full = ui;
            full.verbose = true;
            try full.preview(comparison, "");
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
            if (std.mem.eql(u8, line, "/model")) {
                var current: usize = 0;
                if (!automatic) for (1..menu.count + 1) |number| {
                    const choice = menu.get(number).?;
                    if (choice.provider == route.provider and std.mem.eql(u8, choice.model, route.model)) {
                        current = number;
                        break;
                    }
                };
                if (try core.pickModel(init.io, ui, &menu, current)) |number| {
                    const choice = menu.get(number).?;
                    if (mode == .free and choice.provider != .openrouter) {
                        try ui.note("--free requires OpenRouter; provider switch rejected.");
                        continue;
                    }
                    route = core.Route.init(init.environ_map, @tagName(choice.provider), try a.dupe(u8, choice.model)) catch |err| {
                        try out.print("error: {s}\n", .{@errorName(err)});
                        continue;
                    };
                    route.mode = mode;
                    automatic = false;
                    agent.route = route;
                    agent.automatic = false;
                    status.setModel(route.model);
                    try ui.route(@tagName(route.provider), route.model);
                }
            }
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
        if (std.mem.eql(u8, line, "/plan") or std.mem.startsWith(u8, line, "/plan ")) {
            const arg = if (line.len > 5) std.mem.trim(u8, line[5..], " \t") else "on";
            const enabled = if (std.mem.eql(u8, arg, "on")) true else if (std.mem.eql(u8, arg, "off")) false else {
                try ui.note("usage: /plan [on|off]");
                continue;
            };
            if (enabled == plan_mode) {
                try ui.note(if (enabled) "Plan mode is already active." else if (read_only) "Plan mode is off; --read-only still prevents edits and commands." else "Plan mode is already off.");
                continue;
            }
            agent.setPlanMode(enabled) catch |err| {
                try ui.errorMessage(err);
                continue;
            };
            try agent.resetArena(&arena);
            plan_mode = enabled;
            try ui.note(if (enabled) "Plan mode enabled. Only read, glob, grep, and skill tools are available." else if (read_only) "Plan mode disabled; --read-only still prevents edits and commands." else "Plan mode disabled. Edits and commands are available.");
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
            defer std.crypto.secureZero(u8, @constCast(body));
            const safe_body = try agent.context.scrub(body);
            defer if (safe_body.ptr != body.ptr) std.crypto.secureZero(u8, @constCast(safe_body));
            const retained_body = try arena.allocator().dupe(u8, safe_body);
            errdefer std.crypto.secureZero(u8, @constCast(retained_body));
            try agent.history.append(arena.allocator(), .{ .role = "user", .content = .{ .string = retained_body }, .owns_text = true });
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
                voice_prompt = transcript;
                var note_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer note_scratch.deinit();
                const note = try std.fmt.allocPrint(note_scratch.allocator(), "Voice: {s}", .{transcript});
                defer std.crypto.secureZero(u8, note);
                try ui.note(note);
                active_prompt = transcript;
            } else if (line[0] == '/') {
                try out.writeAll("Unknown command. Use /help for available commands.\n");
                continue;
            }
            agent.respond(active_prompt, ui) catch |err| {
                if (err == error.Canceled) return err;
                try ui.errorMessage(err);
                if (agent.retainCompletedWork(arena.allocator()) catch false) {
                    try agent.resetArena(&arena);
                    try out.writeAll("  completed work retained in summary. Inspect tool effects, then enter continue to resume.\n");
                    continue;
                }
                try out.writeAll("  conversation cleared. Inspect completed tool effects before retrying.\n");
                agent.clearHistory();
                // Reinitialize below so failed tool turns cannot poison later messages.
            };
            // Keep complete history after successful turns; reset after errors.
            if (agent.history.items.len != 0 and agent.history.items.len <= core.Agent.max_messages) continue;
        }
        if (std.mem.eql(u8, line, "/c")) {
            if (ui.details) |details| details.clear();
        }
        agent.clearHistory();
        agent.clearPreviewedContent();
        _ = arena.reset(.free_all);
        todo.clear();
        route.mode = mode;
        agent = try core.Agent.init(.{ .a = arena.allocator(), .io = init.io, .dir = .cwd(), .todo = &todo, .secrets = secrets, .read_only = read_only }, init.environ_map, route);
        if (plan_mode) try agent.setPlanMode(true);
        agent.automatic = automatic;
        agent.dry_run = dry_run;
        agent.rate_limiter = &limiter;
        try out.writeAll("Conversation cleared.\n");
    }
}

fn refreshRouteEnvironment(route: *core.Route, env: *const std.process.Environ.Map) void {
    route.key = env.get(route.provider.envKey()) orelse "";
    route.url = env.get("API_URL") orelse route.provider.defaultUrl();
}

// Run before any command that can replace or remove credentials.
fn redactRetained(agent: *core.Agent, composer: *core.Input, secrets: *const core.Secrets, ui: core.Ui) !void {
    try agent.redactHistory();
    try composer.redactHistory(secrets, agent.env);
    if (ui.details) |retained| if (retained.present) {
        const truncated = retained.truncated;
        const snapshot = try agent.context.a.dupe(u8, retained.bytes[0..retained.len]);
        defer std.crypto.secureZero(u8, snapshot);
        try ui.retainDetails(snapshot);
        retained.truncated = retained.truncated or truncated;
    };
    if (ui.details) |retained| for (&retained.outputs) |*output| {
        if (!output.present) continue;
        const id = output.id;
        const truncated = output.truncated;
        const snapshot = try agent.context.a.dupe(u8, output.bytes[0..output.len]);
        defer std.crypto.secureZero(u8, snapshot);
        try ui.retainOutput(id, snapshot);
        output.truncated = output.truncated or truncated;
    };
}
