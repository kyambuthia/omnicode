const std = @import("std");
const core = @import("omnicode");

pub const help =
    \\omnicode [--free|--cost-max] [--verbose] [--read-only] [--dry-run] [--session NAME] [prompt ...]  Run a task, or start a REPL without arguments.
    \\omnicode --version         Print version (v0.2.0).
    \\omnicode --skills          List project skills without an API call.
    \\omnicode --init            Initialize OMNICODE.md and .omnicode/skills/verify/SKILL.md.
    \\omnicode --providers [...] View, switch, or configure LLM providers and API keys.
    \\omnicode --setup [...]     View or configure provider API keys and settings.
    \\omnicode --secrets [...]   Manage zero-leak secrets (passwords, tokens, logins).
    \\--cost-max (default)      Optimize live OpenRouter catalog prices
    \\--session NAME            Resume and checkpoint a named one-shot task
    \\--read-only               Restrict model tools to read, glob, grep, and skill
    \\--dry-run                 Preview the first proposed tool batch without executing it
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
    \\  /model compare         Compare live OpenRouter price and throughput order before switching
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
    \\  /export [name]         Export redacted Markdown under .omnicode/exports/ (default: latest)
    \\  /resume [name]         Resume saved session (default: latest)
    \\  /details               Show last tool result (up to 64 KiB)
    \\  /c                     Clear conversation
    \\  /q, /exit, or exit     Quit (Ctrl-D also exits)
    \\Config: PROVIDER=abliteration|anthropic|openrouter|deepseek|xai|openai|gemini|groq, MODEL, FAST_MODEL, VOICE_MODEL, MAX_TURNS
    \\Keys: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, etc. (or run /setup). Searches require rg.
    \\Skills: .omnicode/skills/<name>/SKILL.md. Tools run with your permissions.
    \\
;

pub const Options = struct {
    first: usize,
    mode: @FieldType(core.Route, "mode"),
    prompt_only: bool,
    read_only: bool,
    dry_run: bool,
    session_name: ?[]const u8,
    verbose: bool,

    pub fn parse(args: []const []const u8) !Options {
        var verbose = false;
        var first: usize = 1;
        var mode: @FieldType(core.Route, "mode") = .cost_max;
        var policy_set = false;
        var prompt_only = false;
        var read_only = false;
        var dry_run = false;
        var session_name: ?[]const u8 = null;
        while (first < args.len) : (first += 1) {
            const arg = args[first];
            if (std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--read-only")) {
                read_only = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
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
        return .{ .first = first, .mode = mode, .prompt_only = prompt_only, .read_only = read_only, .dry_run = dry_run, .session_name = session_name, .verbose = verbose };
    }
};
