const std = @import("std");
const core = @import("omnicode");

pub const help =
    \\omnicode [--free|--cost-max] [--verbose] [--read-only] [--plan] [--dry-run] [--json] [--session NAME] [prompt ...]  Run a task, or start a REPL without arguments.
    \\omnicode --version         Print version (v0.2.0).
    \\omnicode --skills          List project skills without an API call.
    \\omnicode --init            Initialize OMNICODE.md and .omnicode/skills/verify/SKILL.md.
    \\omnicode --providers [...] View, switch, or configure LLM providers and API keys.
    \\omnicode --setup [...]     View or configure provider API keys and settings.
    \\omnicode --secrets [...]   Manage zero-leak secrets (passwords, tokens, logins).
    \\--cost-max (default)      Optimize live OpenRouter catalog prices
    \\--session NAME            Resume and checkpoint a named one-shot task
    \\--read-only               Restrict model tools to read, glob, grep, and skill
    \\--plan                    Start in read-only planning mode
    \\--dry-run                 Preview the first proposed tool batch without executing it
    \\--json                    Emit one JSON object for a one-shot task; progress goes to stderr
    \\--free                    Only current zero-price OpenRouter tool models
    \\REPL commands:
    \\  /, /commands          Browse built-in commands and local skills
    \\  /help [topic]          Show all commands or search help by topic
    \\  /providers [...]       List, switch, or configure providers & API keys (/providers <N|name> [key])
    \\  /setup [...]           Configure provider API keys and settings (saved to config.env)
    \\  /secrets [...]         Manage zero-leak secrets (injected in bash, scrubbed from chat)
    \\  /voice [sec|file]      Record or transcribe audio via cheap OpenRouter voice models
    \\  /init [force]          Bootstrap OMNICODE.md and verify skill
    \\  /review [focus]        Run adversarial multi-agent code review
    \\  /model                 Choose a model with ↑/↓ and Enter (Esc cancels)
    \\  /model list            Show current routing and numbered list of available models
    \\  /model compare         Compare live OpenRouter price and throughput order before switching
    \\  /model <N|MODEL>       Switch to model #N or MODEL (preserves conversation)
    \\  /model PROVIDER MODEL  Switch provider and pin MODEL
    \\  /model auto|fast|strong  Select automatic routing or pin fast/strong tier
    \\  /plan [on|off]          Toggle read-only planning mode
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
    \\  /details [id|list]     Show or list recent model, Bash, and tool output
    \\  /out [call-id|list]    Show Bash output or list recent calls
    \\  Ctrl+O                Cycle recent outputs, starting at the latest
    \\  Ctrl+J                Insert a newline without sending the prompt
    \\  /tmux [status|on|off] Toggle the live Bash pane in tmux (requires ≥100 columns)
    \\  /diff                  Show bounded, redacted git status and tracked diff
    \\  /c                     Clear conversation
    \\  /q, /exit, or exit     Quit (Ctrl-D also exits)
    \\Config: PROVIDER=abliteration|anthropic|openrouter|deepseek|xai|openai|gemini|groq, MODEL, FAST_MODEL, VOICE_MODEL, MAX_TURNS, MAX_REQUESTS_PER_MINUTE
    \\Keys: OPENROUTER_API_KEY, ANTHROPIC_API_KEY, etc. (or run /setup). Searches require rg.
    \\Skills: .omnicode/skills/<name>/SKILL.md. Tools run with your permissions.
    \\
;

/// Return the interactive command section without CLI options and configuration notes.
pub fn replCommandHelp() []const u8 {
    const marker = "REPL commands:\n";
    const start = (std.mem.indexOf(u8, help, marker) orelse return help) + marker.len;
    const length = std.mem.indexOf(u8, help[start..], "\nConfig:") orelse return help[start..];
    return help[start .. start + length];
}

/// Return help lines containing a case-insensitive topic. The caller owns the result.
pub fn searchHelp(a: std.mem.Allocator, topic: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        if (!containsIgnoreCase(line, topic)) continue;
        try output.writer.writeAll(line);
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

test "help search finds case-insensitive topics and returns empty for misses" {
    const a = std.testing.allocator;
    const tmux = try searchHelp(a, "TMUX");
    defer a.free(tmux);
    try std.testing.expect(std.mem.indexOf(u8, tmux, "/tmux [status|on|off]") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmux, "Ctrl+O") == null);

    const missing = try searchHelp(a, "no-such-help-topic");
    defer a.free(missing);
    try std.testing.expectEqualStrings("", missing);
}

pub const Options = struct {
    first: usize,
    mode: @FieldType(core.Route, "mode"),
    prompt_only: bool,
    read_only: bool,
    plan_mode: bool,
    dry_run: bool,
    json_output: bool,
    session_name: ?[]const u8,
    verbose: bool,

    pub fn parse(args: []const []const u8) !Options {
        var verbose = false;
        var first: usize = 1;
        var mode: @FieldType(core.Route, "mode") = .cost_max;
        var policy_set = false;
        var prompt_only = false;
        var read_only = false;
        var plan_mode = false;
        var dry_run = false;
        var json_output = false;
        var session_name: ?[]const u8 = null;
        while (first < args.len) : (first += 1) {
            const arg = args[first];
            if (std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--read-only")) {
                read_only = true;
            } else if (std.mem.eql(u8, arg, "--plan")) {
                plan_mode = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                json_output = true;
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
        return .{ .first = first, .mode = mode, .prompt_only = prompt_only, .read_only = read_only, .plan_mode = plan_mode, .dry_run = dry_run, .json_output = json_output, .session_name = session_name, .verbose = verbose };
    }
};
