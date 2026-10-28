const std = @import("std");
const j = @import("json.zig");
const Io = std.Io;
const TmuxFeed = @import("tmux.zig").Feed;
pub const limit = 64 * 1024;
const byte_read_limit = 60 * 1024;
pub const Result = struct {
    text: []const u8,
    is_error: bool = false,
    /// True when the caller owns a mutable text allocation it may wipe after consuming.
    owned_text: bool = false,
};

/// Reject unadvertised fields before a tool can read or mutate project state.
pub fn validateFields(args: j.Value, allowed: []const []const u8) !void {
    if (args != .object) return error.ExpectedObject;
    var fields = args.object.iterator();
    while (fields.next()) |field| {
        for (allowed) |key| {
            if (std.mem.eql(u8, field.key_ptr.*, key)) break;
        } else return error.UnknownArgument;
    }
}

fn validateToolFields(name: []const u8, args: j.Value) !void {
    const allowed: []const []const u8 = if (std.mem.eql(u8, name, "read"))
        &.{ "path", "offset", "limit", "byte_offset", "byte_limit" }
    else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep"))
        &.{ "pat", "path" }
    else if (std.mem.eql(u8, name, "skill"))
        &.{"name"}
    else if (std.mem.eql(u8, name, "write"))
        &.{ "path", "content" }
    else if (std.mem.eql(u8, name, "edit"))
        &.{ "path", "old", "new", "all" }
    else if (std.mem.eql(u8, name, "bash"))
        &.{ "cmd", "command", "timeout_ms" }
    else if (std.mem.eql(u8, name, "todo"))
        &.{"items"}
    else
        return error.UnknownTool;
    try validateFields(args, allowed);
}

const explore_tools =
    \\{"name":"read","description":"Read numbered lines with zero-based offset, or use byte_offset/byte_limit for long lines. Byte windows use redacted UTF-8 offsets and align to whole characters. Do not mix line and byte options. Max 1 MiB file","input_schema":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"},"byte_offset":{"type":"integer","minimum":0},"byte_limit":{"type":"integer","minimum":1,"maximum":61440}},"required":["path"]}},
    \\{"name":"glob","description":"Find files using ripgrep glob rules; respects ignore files","input_schema":{"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"}},"required":["pat"]}},
    \\{"name":"grep","description":"Search regex with ripgrep; respects ignore files","input_schema":{"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"}},"required":["pat"]}},
    \\{"name":"skill","description":"Load instructions for an advertised skill by name","input_schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}
;

const edit_tools = explore_tools ++ ",\n" ++
    \\{"name":"write","description":"Create or overwrite a file; creates missing parent directories","input_schema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
    \\{"name":"edit","description":"Replace exact nonempty text; must be unique including overlaps unless all=true (replaces non-overlapping matches)","input_schema":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"},"all":{"type":"boolean"}},"required":["path","old","new"]}},
    \\{"name":"bash","description":"Run a POSIX sh command; invoke bash explicitly for Bash syntax. Output is already bounded: run verification commands directly so pipelines do not mask their exit status. Default 30s deadline, timeout_ms may request 1-300000ms","input_schema":{"type":"object","properties":{"cmd":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1,"maximum":300000}},"required":["cmd"]}},
    \\{"name":"todo","description":"Read or replace the session checklist that survives context compaction","input_schema":{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"task":{"type":"string"},"done":{"type":"boolean"}},"required":["task","done"]}}}}}
;

const parent_tools = edit_tools ++ ",\n" ++
    \\{"name":"task","description":"Delegate a self-contained investigation or sub-task to a subagent; returns only a final report","input_schema":{"type":"object","properties":{"prompt":{"type":"string"},"mode":{"type":"string","enum":["explore","edit"]},"tier":{"type":"string","enum":["fast","strong"]}},"required":["prompt"]}},
    \\{"name":"review","description":"Run adversarial multi-agent code review (Correctness/Security critic + Anti-Slop/Simplicity critic) on current changes; returns findings and OVERALL VERDICT: PASS|FAIL","input_schema":{"type":"object","properties":{"focus":{"type":"string"}}}}
;

pub const explore_schema = "[\n" ++ explore_tools ++ "\n]";
pub const edit_schema = "[\n" ++ edit_tools ++ "\n]";
pub const schema = "[\n" ++ parent_tools ++ "\n]";

pub const Todo = struct {
    text: [4096]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Todo) []const u8 {
        return self.text[0..self.len];
    }

    pub fn clear(self: *Todo) void {
        std.crypto.secureZero(u8, self.text[0..]);
        self.len = 0;
    }

    pub fn pending(self: *const Todo) usize {
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, self.slice(), '\n');
        while (lines.next()) |line| {
            var digits: usize = 0;
            while (digits < line.len and std.ascii.isDigit(line[digits])) : (digits += 1) {}
            if (digits > 0 and std.mem.startsWith(u8, line[digits..], ". [ ] ")) count += 1;
        }
        return count;
    }

    pub fn update(self: *Todo, args: j.Value) ![]const u8 {
        if (args != .object) return error.ExpectedObject;
        const list = args.object.get("items") orelse return if (self.len == 0) "(empty todo list)" else self.slice();
        if (list != .array or list.array.items.len > 64) return error.InvalidTodoList;
        var next: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, next[0..]);
        var w = Io.Writer.fixed(&next);
        for (list.array.items, 0..) |item, idx| {
            try validateFields(item, &.{ "task", "done" });
            const task = try j.str(item, "task");
            if (task.len == 0 or std.mem.indexOfScalar(u8, task, '\n') != null) return error.InvalidTodoItem;
            const done_val = try j.get(item, "done");
            if (done_val != .bool) return error.ExpectedBoolean;
            w.print("{d}. [{s}] {s}\n", .{ idx + 1, if (done_val.bool) "x" else " ", task }) catch return error.StreamTooLong;
        }
        self.clear();
        @memcpy(self.text[0..w.end], next[0..w.end]);
        self.len = w.end;
        return if (self.len == 0) "(empty todo list)" else self.slice();
    }
};

pub const Context = struct {
    a: j.Allocator,
    io: Io,
    dir: Io.Dir,
    skills_path: []const u8 = ".omnicode/skills",
    read_only: bool = false,
    todo: ?*Todo = null,
    secrets: ?*@import("secrets.zig").Secrets = null,
    env: ?*const std.process.Environ.Map = null,
    output_feed: ?*TmuxFeed = null,

    pub fn readFile(c: Context, path: []const u8) ![]const u8 {
        // Zig 0.17 rejects when the limit is reached; one probe byte makes
        // the advertised 1 MiB maximum inclusive.
        return @import("storage.zig").readRegular(c.io, c.dir, path, c.a, .limited(1024 * 1024 + 1));
    }

    pub fn run(c: Context, name: []const u8, args: j.Value) ![]const u8 {
        return (try c.runResult(name, args)).text;
    }

    pub fn runResult(c: Context, name: []const u8, args: j.Value) !Result {
        try c.checkToolAllowed(name);
        try validateToolFields(name, args);
        // Reads redact the complete file before formatting or slicing.
        if (std.mem.eql(u8, name, "read")) return .{ .text = try c.readTool(args), .owned_text = true };
        // Commands redact before applying their output cap.
        if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep"))
            return c.runCommandTool(name, args);
        if (std.mem.eql(u8, name, "todo")) {
            const todo = c.todo orelse {
                const raw = "(todo unavailable)";
                const scrubbed = try c.scrub(raw);
                return .{ .text = scrubbed, .owned_text = scrubbed.ptr != raw.ptr };
            };
            const raw = try c.a.dupe(u8, try todo.update(args));
            errdefer std.crypto.secureZero(u8, @constCast(raw));
            const scrubbed = try c.scrub(raw);
            if (scrubbed.ptr != raw.ptr) {
                std.crypto.secureZero(u8, @constCast(raw));
                return .{ .text = scrubbed, .owned_text = true };
            }
            return .{ .text = raw, .owned_text = true };
        }
        if (std.mem.eql(u8, name, "skill")) {
            const raw = try c.loadSkill(try j.str(args, "name"));
            defer std.crypto.secureZero(u8, @constCast(raw));
            const scrubbed = try c.scrub(raw);
            defer {
                if (scrubbed.ptr != raw.ptr) std.crypto.secureZero(u8, @constCast(scrubbed));
            }
            return .{ .text = try c.a.dupe(u8, scrubbed), .owned_text = true };
        }
        const raw = try c.runRaw(name, args);
        const scrubbed = try c.scrub(raw);
        return .{ .text = scrubbed, .owned_text = scrubbed.ptr != raw.ptr };
    }

    pub fn scrub(c: Context, text: []const u8) ![]const u8 {
        if (c.secrets) |secrets| return secrets.scrub(c.a, text, c.env);
        return text;
    }

    pub fn checkToolAllowed(c: Context, name: []const u8) !void {
        if (!c.read_only) return;
        for ([_][]const u8{ "read", "glob", "grep", "skill" }) |allowed| {
            if (std.mem.eql(u8, name, allowed)) return;
        }
        return error.ReadOnlyMode;
    }

    fn runRaw(c: Context, name: []const u8, args: j.Value) ![]const u8 {
        if (std.mem.eql(u8, name, "todo")) {
            const t = c.todo orelse return "(todo unavailable)";
            return c.a.dupe(u8, try t.update(args));
        }
        if (std.mem.eql(u8, name, "write")) {
            const content = try j.str(args, "content");
            if (content.len > 1024 * 1024) return error.StreamTooLong;
            const path = try j.str(args, "path");
            try @import("storage.zig").validatePath(path);
            if (std.fs.path.dirname(path)) |parent| try c.dir.createDirPath(c.io, parent);
            try @import("storage.zig").writeRegular(c.io, c.dir, path, content);
            return "ok";
        }
        if (std.mem.eql(u8, name, "edit")) {
            const path = try j.str(args, "path");
            const text = try c.readFile(path);
            defer std.crypto.secureZero(u8, @constCast(text));
            const old = try j.str(args, "old");
            const new = try j.str(args, "new");
            if (old.len == 0) return error.EmptyMatch;
            const count = std.mem.count(u8, text, old);
            if (count == 0) return error.MatchNotFound;
            const all = if (args.object.get("all")) |v| if (v == .bool) v.bool else return error.ExpectedBoolean else false;
            if (!all) {
                const first = std.mem.indexOf(u8, text, old).?;
                // count/replaceOwned count non-overlapping matches. Uniqueness
                // must also reject alternatives that start inside the first match.
                if (std.mem.indexOf(u8, text[first + 1 ..], old) != null) return error.AmbiguousMatch;
            }
            const size = std.math.add(usize, text.len - count * old.len, try std.math.mul(usize, count, new.len)) catch return error.StreamTooLong;
            if (size > 1024 * 1024) return error.StreamTooLong;
            const replacement = try std.mem.replaceOwned(u8, c.a, text, old, new);
            defer std.crypto.secureZero(u8, replacement);
            try @import("storage.zig").writeRegular(c.io, c.dir, path, replacement);
            return "ok";
        }
        return error.UnknownTool;
    }

    fn readTool(c: Context, args: j.Value) ![]const u8 {
        const path = try j.str(args, "path");
        const bytes = args.object.contains("byte_offset") or args.object.contains("byte_limit");
        if (bytes and (args.object.contains("offset") or args.object.contains("limit"))) return error.ConflictingArguments;
        const offset = try j.number(args, if (bytes) "byte_offset" else "offset", 0);
        const count = try j.number(args, if (bytes) "byte_limit" else "limit", if (bytes) 4096 else 200);
        if (bytes and (count == 0 or count > byte_read_limit)) return error.InvalidReadLimit;
        const raw = try c.readFile(path);
        defer std.crypto.secureZero(u8, @constCast(raw));
        const text = try c.scrub(raw);
        defer {
            if (text.ptr != raw.ptr) std.crypto.secureZero(u8, @constCast(text));
        }
        if (bytes) {
            if (!std.unicode.utf8ValidateSlice(text)) return error.NonUtf8Output;
            if (offset > text.len) return error.InvalidReadOffset;
            var start = offset;
            while (start > 0 and start < text.len and text[start] & 0xc0 == 0x80) start -= 1;
            var end = @min(text.len, start + count);
            while (end < text.len and text[end] & 0xc0 == 0x80) end += 1;
            const next = if (end < text.len)
                try std.fmt.allocPrint(c.a, "[next byte_offset={d}]", .{end})
            else
                "[end of file]";
            return std.fmt.allocPrint(c.a, "[UTF-8 bytes {d}..{d} of {d}; offsets after redaction]\n{s}\n{s}\n", .{ start, end, text.len, text[start..end], next });
        }
        const truncated = "[truncated; use offset, or byte_offset/byte_limit for long lines]\n";
        var out: Io.Writer.Allocating = .init(c.a);
        defer {
            std.crypto.secureZero(u8, out.written());
            out.deinit();
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (line.len == 0 and lines.peek() == null) break;
            if (n < offset) continue;
            if (n - offset >= count or out.writer.end + line.len + 32 + truncated.len > limit) {
                try out.writer.writeAll(truncated);
                break;
            }
            try out.writer.print("{d}| {s}\n", .{ n + 1, line });
        }
        return out.toOwnedSlice();
    }

    fn runCommandTool(c: Context, name: []const u8, args: j.Value) !Result {
        if (std.mem.eql(u8, name, "bash")) {
            const timeout = try j.number(args, "timeout_ms", 30_000);
            if (timeout == 0 or timeout > 300_000) return error.InvalidTimeout;
            return c.commandResult(&.{ "sh", "-c", try j.aliasedString(args, "cmd", "command") }, false, @intCast(timeout), true);
        }
        const path = try j.optional(args, "path", ".");
        if (std.mem.eql(u8, name, "glob")) return c.commandResult(&.{
            "rg",             "--no-config",   "--files",
            "--glob",         "!.git",         "--glob",
            "!.venv",         "--glob",        "!venv",
            "--glob",         "!node_modules", "--glob",
            "!__pycache__",   "--glob",        "!.zig-cache",
            "--glob",         "!zig-out",      "--glob",
            "!target",        "--glob",        "!dist",
            "--glob",         "!.cache",       "--glob",
            "!.pytest_cache", "--glob",        try j.str(args, "pat"),
            "--",             path,
        }, true, 30_000, false);
        if (std.mem.eql(u8, name, "grep")) return c.commandResult(&.{
            "rg",             "--no-config",   "--color=never",
            "-n",             "-m",            "50",
            "--glob",         "!.git",         "--glob",
            "!.venv",         "--glob",        "!venv",
            "--glob",         "!node_modules", "--glob",
            "!__pycache__",   "--glob",        "!.zig-cache",
            "--glob",         "!zig-out",      "--glob",
            "!target",        "--glob",        "!dist",
            "--glob",         "!.cache",       "--glob",
            "!.pytest_cache", "--",            try j.str(args, "pat"),
            path,
        }, true, 30_000, false);
        return error.UnknownTool;
    }

    pub fn command(c: Context, argv: []const []const u8, search: bool, milliseconds: i64) ![]const u8 {
        return (try c.commandResult(argv, search, milliseconds, false)).text;
    }

    fn commandResult(c: Context, argv: []const []const u8, search: bool, milliseconds: i64, live_bash: bool) !Result {
        for (argv) |arg| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommandArgument;
        }
        var live_output: ?LiveBashOutput = null;
        if (live_bash) if (c.output_feed) |feed| {
            if (feed.active and canStreamLiveOutput(c)) {
                live_output = LiveBashOutput.init(c, feed) catch null;
            }
        };
        defer if (live_output) |*live| live.deinit();
        const observer: ?@import("command.zig").OutputObserver = if (live_output) |*live| live.observer() else null;
        const result = try @import("deadline.zig").run(c.io, @import("command.zig").runObserved, .{ c.a, c.io, std.process.RunOptions{
            .argv = argv,
            .cwd = .{ .dir = c.dir },
            .environ_map = c.env,
            .stdout_limit = .limited(4 * limit),
            .stderr_limit = .limited(4 * limit),
        }, observer }, milliseconds);
        defer std.crypto.secureZero(u8, @constCast(result.stdout));
        defer std.crypto.secureZero(u8, @constCast(result.stderr));
        if (search and result.term == .exited and result.term.exited == 1) {
            const raw = "none";
            const scrubbed = try c.scrub(raw);
            return .{ .text = scrubbed, .owned_text = scrubbed.ptr != raw.ptr };
        }
        const full = if (!result.term.success())
            try std.fmt.allocPrint(c.a, "error: {f}\n{s}{s}", .{ result.term, result.stdout, result.stderr })
        else
            try std.fmt.allocPrint(c.a, "{s}{s}", .{ result.stdout, result.stderr });
        defer std.crypto.secureZero(u8, @constCast(full));
        const scrubbed = try c.scrub(full);
        defer {
            if (scrubbed.ptr != full.ptr) std.crypto.secureZero(u8, @constCast(scrubbed));
        }
        const capped = try capCommandOutput(c.a, scrubbed);
        defer if (scrubbed.len > limit and std.unicode.utf8ValidateSlice(scrubbed)) std.crypto.secureZero(u8, @constCast(capped));
        return .{ .text = try c.a.dupe(u8, capped), .is_error = !result.term.success(), .owned_text = true };
    }

    pub fn loadSkill(c: Context, name: []const u8) ![]const u8 {
        if (!validName(name)) return error.InvalidSkillName;
        const path = try std.fmt.allocPrint(c.a, "{s}/{s}/SKILL.md", .{ c.skills_path, name });
        const text = try c.readFile(path);
        if (text.len > limit) {
            std.crypto.secureZero(u8, @constCast(text));
            return error.StreamTooLong;
        }
        return text;
    }

    pub fn skills(c: Context) ![]const u8 {
        const dir = c.dir.openDir(c.io, c.skills_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return "",
            else => return err,
        };
        defer dir.close(c.io);
        var out: Io.Writer.Allocating = .init(c.a);
        defer {
            std.crypto.secureZero(u8, out.written());
            out.deinit();
        }
        var it = dir.iterate();
        while (try it.next(c.io)) |entry| {
            if (entry.kind != .directory or !validName(entry.name)) continue;
            const text = c.loadSkill(entry.name) catch |err| switch (err) {
                error.Canceled => return err,
                else => continue,
            };
            defer std.crypto.secureZero(u8, @constCast(text));
            var description: []const u8 = "Local instructions";
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "description:")) {
                    description = std.mem.trim(u8, line[12..], " \t\r\"'");
                    break;
                }
            }
            const raw_description = description;
            const safe_description = try c.scrub(raw_description);
            defer {
                if (safe_description.ptr != raw_description.ptr)
                    std.crypto.secureZero(u8, @constCast(safe_description));
            }
            description = safe_description;
            var description_len = @min(description.len, 240);
            while (description_len > 0 and !std.unicode.utf8ValidateSlice(description[0..description_len])) description_len -= 1;
            if (out.writer.end + entry.name.len + description_len + 8 > limit) return error.TooManySkills;
            try out.writer.print("- {s}: {s}\n", .{ entry.name, description[0..description_len] });
        }
        return out.toOwnedSlice();
    }

    pub fn projectInstructions(c: Context) ![]const u8 {
        return @import("storage.zig").readRegular(c.io, c.dir, "OMNICODE.md", c.a, .limited(limit)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }

    fn hasFile(c: Context, path: []const u8) !bool {
        const metadata = c.dir.statFile(c.io, path, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => return false,
        };
        return metadata.kind == .file;
    }

    pub fn initProject(c: Context, force: bool) ![]const u8 {
        if (!force) {
            if (c.dir.statFile(c.io, "OMNICODE.md", .{ .follow_symlinks = false })) |_| {
                return error.AlreadyInitialized;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
        const commands = if (try c.hasFile("build.zig"))
            "- Build: `zig build`\n- Test: `zig build test`\n- Format check: `zig fmt --check src`"
        else if (try c.hasFile("Cargo.toml"))
            "- Build: `cargo build`\n- Test: `cargo test`\n- Format check: `cargo fmt --check`"
        else if (try c.hasFile("package.json"))
            "- Build: `npm run build`\n- Test: `npm test`"
        else if (try c.hasFile("pyproject.toml") or try c.hasFile("pytest.ini"))
            "- Test: `pytest`"
        else if (try c.hasFile("go.mod"))
            "- Build: `go build ./...`\n- Test: `go test ./...`"
        else if (try c.hasFile("Makefile"))
            "- Build: `make`\n- Test: `make test`"
        else
            "- Add project build, test, and lint commands here.";
        const doc = try std.fmt.allocPrint(c.a,
            \\# OMNICODE.md
            \\
            \\## Verification Commands
            \\{s}
            \\
            \\## Coding & Anti-Slop Guidelines
            \\- Read target files before editing; match existing naming, error handling, and formatting.
            \\- Prefer small, direct changes over speculative abstractions, wrappers, or dead code.
            \\- Do not add comments that merely restate what the code does.
            \\- Run the verification commands and the `review` tool on non-trivial changes before finishing.
            \\
        , .{commands});
        const skill_path = try std.fmt.allocPrint(c.a, "{s}/verify", .{c.skills_path});
        const skill_file = try std.fmt.allocPrint(c.a, "{s}/verify/SKILL.md", .{c.skills_path});
        if (force) {
            try @import("storage.zig").checkWriteTarget(c.io, c.dir, "OMNICODE.md");
            try @import("storage.zig").checkWriteTarget(c.io, c.dir, skill_file);
        }
        try c.dir.createDirPath(c.io, skill_path);
        // Prepare directories before publishing the instruction file, so an
        // invalid skills directory does not leave OMNICODE.md half-initialized.
        if (force) {
            try @import("storage.zig").writeRegular(c.io, c.dir, "OMNICODE.md", doc);
        } else if (!try @import("storage.zig").createNew(c.io, c.dir, "OMNICODE.md", doc)) {
            return error.AlreadyInitialized;
        }
        const verify_skill =
            \\---
            \\name: verify
            \\description: Run build, test, and adversarial review checks before finishing
            \\---
            \\1. Run the verification commands in `OMNICODE.md`.
            \\2. Run the `review` tool to audit changes with the correctness and anti-slop critics.
            \\3. Fix any reported issues before concluding.
            \\
        ;
        if (force) {
            try @import("storage.zig").writeRegular(c.io, c.dir, skill_file, verify_skill);
        } else {
            if (!try @import("storage.zig").createNew(c.io, c.dir, skill_file, verify_skill))
                return "Initialized OMNICODE.md; preserved the existing verification skill.";
        }
        return "Initialized OMNICODE.md and .omnicode/skills/verify/SKILL.md.";
    }

    pub fn collectDiff(c: Context) ![]const u8 {
        const raw = c.command(&.{ "sh", "-c", "git status --short 2>/dev/null; printf '\\n---\\n'; git diff HEAD 2>/dev/null || git diff 2>/dev/null" }, false, 15_000) catch
            return c.a.dupe(u8, "(git diff unavailable; use glob/read to inspect files)");
        if (std.mem.startsWith(u8, raw, "error:")) {
            std.crypto.secureZero(u8, @constCast(raw));
            return c.a.dupe(u8, "(not a git repository; use glob/read to inspect files)");
        }
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "---")) {
            std.crypto.secureZero(u8, @constCast(raw));
            return c.a.dupe(u8, "(working tree clean; inspect recent files with glob/read)");
        }
        var max = @min(raw.len, limit / 2);
        while (max > 0 and !std.unicode.utf8ValidateSlice(raw[0..max])) max -= 1;
        if (max < raw.len) {
            const prefix = c.a.dupe(u8, raw[0..max]) catch |err| {
                std.crypto.secureZero(u8, @constCast(raw));
                return err;
            };
            std.crypto.secureZero(u8, @constCast(raw));
            return prefix;
        }
        return raw;
    }
};

const LiveBashOutput = struct {
    context: Context,
    feed: *TmuxFeed,
    lines: [2][]u8,
    line_lens: [2]usize = .{ 0, 0 },
    finished: [2]bool = .{ false, false },
    failed: bool = false,

    fn init(context: Context, feed: *TmuxFeed) !LiveBashOutput {
        const capacity = 4 * limit;
        const stdout_line = try std.heap.page_allocator.alloc(u8, capacity);
        errdefer std.heap.page_allocator.free(stdout_line);
        const stderr_line = try std.heap.page_allocator.alloc(u8, capacity);
        return .{ .context = context, .feed = feed, .lines = .{ stdout_line, stderr_line } };
    }

    fn deinit(live: *LiveBashOutput) void {
        for (live.lines) |line| {
            std.crypto.secureZero(u8, line);
            std.heap.page_allocator.free(line);
        }
    }

    fn observer(live: *LiveBashOutput) @import("command.zig").OutputObserver {
        return .{ .context = live, .on_bytes = onBytes, .on_finish = onFinish };
    }

    fn onBytes(context: *anyopaque, stream: usize, bytes: []const u8) void {
        const live: *LiveBashOutput = @ptrCast(@alignCast(context));
        live.receive(stream, bytes) catch {
            live.failed = true;
        };
    }

    fn receive(live: *LiveBashOutput, stream: usize, bytes: []const u8) !void {
        if (live.failed or !live.feed.active or stream >= live.lines.len) return;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const newline = std.mem.indexOfScalar(u8, bytes[offset..], '\n');
            const count = if (newline) |index| index + 1 else bytes.len - offset;
            const current_len = live.line_lens[stream];
            if (count > live.lines[stream].len - current_len) return error.LiveLineTooLong;
            @memcpy(live.lines[stream][current_len .. current_len + count], bytes[offset .. offset + count]);
            live.line_lens[stream] += count;
            offset += count;
            if (newline != null) try live.emitLine(stream);
        }
    }

    fn emitLine(live: *LiveBashOutput, stream: usize) !void {
        const raw = live.lines[stream][0..live.line_lens[stream]];
        defer {
            std.crypto.secureZero(u8, raw);
            live.line_lens[stream] = 0;
        }
        const safe = if (live.context.secrets) |secrets|
            try secrets.scrub(std.heap.page_allocator, raw, live.context.env)
        else
            raw;
        defer if (safe.ptr != raw.ptr) {
            std.crypto.secureZero(u8, @constCast(safe));
            std.heap.page_allocator.free(@constCast(safe));
        };
        try live.feed.writeLiveLine(safe);
    }

    fn onFinish(context: *anyopaque, stream: usize, complete: bool) void {
        const live: *LiveBashOutput = @ptrCast(@alignCast(context));
        if (stream >= live.lines.len or live.finished[stream]) return;
        live.finished[stream] = true;
        if (complete and live.line_lens[stream] > 0 and !live.failed) {
            live.emitLine(stream) catch {
                live.failed = true;
            };
        } else if (!complete) {
            std.crypto.secureZero(u8, live.lines[stream][0..live.line_lens[stream]]);
            live.line_lens[stream] = 0;
            live.failed = true;
        }
        if (live.finished[0] and live.finished[1]) {
            live.feed.markStreamComplete(live.feed.current_call_id, !live.failed and complete);
        }
    }
};

fn canStreamLiveOutput(context: Context) bool {
    const env = context.env orelse return true;
    inline for (.{
        "AN_ABLE_KEY",
        "ANTHROPIC_API_KEY",
        "OPENROUTER_API_KEY",
        "DEEPSEEK_API_KEY",
        "XAI_API_KEY",
        "OPENAI_API_KEY",
        "GEMINI_API_KEY",
        "GROQ_API_KEY",
    }) |name| {
        if (env.get(name)) |value| if (std.mem.indexOfAny(u8, value, "\r\n") != null) return false;
    }
    return true;
}

pub fn capCommandOutput(a: j.Allocator, full: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(full))
        return "Command output contained non-UTF-8 bytes and was omitted.";
    if (full.len <= limit) return full;
    const marker = "\n...[truncated middle; narrow command or filter output]...\n";
    var head: usize = (limit * 2) / 3;
    while (head > 0 and !std.unicode.utf8ValidateSlice(full[0..head])) head -= 1;
    var tail_start = full.len - (limit - head - marker.len);
    while (tail_start < full.len and !std.unicode.utf8ValidateSlice(full[tail_start..])) tail_start += 1;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ full[0..head], marker, full[tail_start..] });
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

test "unknown tool fields are rejected before a command runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    const args = try j.parse(a, "{\"cmd\":\"touch marker\",\"unexpected\":true}");
    try std.testing.expectError(error.UnknownArgument, c.run("bash", args));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "marker", .{}));
    try std.testing.expectError(error.ExpectedObject, c.run("read", .null));

    var todo: Todo = .{};
    const malformed = try j.parse(a, "{\"items\":[{\"task\":\"valid\",\"done\":true},{\"task\":\"invalid\",\"done\":false,\"unexpected\":1}]}");
    try std.testing.expectError(error.UnknownArgument, todo.update(malformed));
    try std.testing.expectEqual(@as(usize, 0), todo.len);
}

test "fuzz tool input validation and checklist updates" {
    try std.testing.fuzz({}, fuzzToolInputs, .{ .corpus = &.{
        "\x0c\x00\x00\x00{\"items\":[]}",
        "\x0c\x00\x00\x00{\"path\":\"x\"}",
    } });
}

fn fuzzToolInputs(_: void, smith: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    const len = smith.slice(&bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = j.parse(a, bytes[0..len]) catch return;
    _ = validateToolFields("read", args) catch {};
    var todo: Todo = .{};
    _ = todo.update(args) catch {
        try std.testing.expectEqual(@as(usize, 0), todo.len);
        return;
    };
    try std.testing.expect(todo.len <= todo.text.len);
}

test "file tools modify real files and reject ambiguous or invalid edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    _ = try c.run("write", try j.parse(c.a, "{\"path\":\"a\",\"content\":\"one\\ntwo\\none\"}"));
    _ = try c.run("write", try j.parse(c.a, "{\"path\":\"nested/tests/new.txt\",\"content\":\"created\"}"));
    try std.testing.expectEqualStrings("created", try c.readFile("nested/tests/new.txt"));
    const read = try c.run("read", try j.parse(c.a, "{\"path\":\"a\",\"offset\":1,\"limit\":1}"));
    try std.testing.expect(std.mem.startsWith(u8, read, "2| two\n"));
    try std.testing.expect(std.mem.indexOf(u8, read, "truncated") != null);
    const edit = try j.parse(c.a, "{\"path\":\"a\",\"old\":\"one\",\"new\":\"three\"}");
    try std.testing.expectError(error.AmbiguousMatch, c.run("edit", edit));
    _ = try c.run("edit", try j.parse(c.a, "{\"path\":\"a\",\"old\":\"one\",\"new\":\"three\",\"all\":true}"));
    try std.testing.expectEqualStrings("three\ntwo\nthree", try c.readFile("a"));
    var ro = c;
    ro.read_only = true;
    try std.testing.expectError(error.ReadOnlyMode, ro.run("write", try j.parse(c.a, "{\"path\":\"b\",\"content\":\"x\"}")));
    try std.testing.expectError(error.ReadOnlyMode, ro.run("edit", edit));
    try std.testing.expectError(error.ReadOnlyMode, ro.run("bash", try j.parse(c.a, "{\"cmd\":\"true\"}")));
    var todo: Todo = .{};
    var with_todo = c;
    with_todo.todo = &todo;
    try std.testing.expectEqualStrings("(empty todo list)", try with_todo.run("todo", try j.parse(c.a, "{}")));
    const list = try with_todo.run("todo", try j.parse(c.a, "{\"items\":[{\"task\":\"step one\",\"done\":true},{\"task\":\"step two\",\"done\":false}]}"));
    try std.testing.expectEqualStrings("1. [x] step one\n2. [ ] step two\n", list);
    _ = try ro.run("read", try j.parse(c.a, "{\"path\":\"a\"}"));
    try std.testing.expectError(error.EmptyMatch, c.run("edit", try j.parse(c.a, "{\"path\":\"a\",\"old\":\"\",\"new\":\"x\"}")));
    try std.testing.expectError(error.ExpectedNaturalNumber, c.run("read", try j.parse(c.a, "{\"path\":\"a\",\"offset\":-1}")));
    try std.testing.expectError(error.FileNotFound, c.run("read", try j.parse(c.a, "{\"path\":\"missing\"}")));
    inline for (.{ .{ "", "" }, .{ "one\n", "1| one\n" }, .{ "\n", "1| \n" }, .{ "one\n\n", "1| one\n2| \n" } }) |example| {
        try c.dir.writeFile(c.io, .{ .sub_path = "a", .data = example[0] });
        try std.testing.expectEqualStrings(example[1], try c.run("read", try j.parse(c.a, "{\"path\":\"a\"}")));
    }
}

test "skills advertise metadata, load body, and reject traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try std.testing.expectEqualStrings("", try c.skills());
    try tmp.dir.createDirPath(c.io, ".omnicode/skills/check");
    const body = "---\nname: check\ndescription: Verify the build\n---\nRun zig build test.\n";
    try tmp.dir.writeFile(c.io, .{ .sub_path = ".omnicode/skills/check/SKILL.md", .data = body });
    try std.testing.expectEqualStrings("- check: Verify the build\n", try c.skills());
    try std.testing.expectEqualStrings(body, try c.loadSkill("check"));
    try std.testing.expectError(error.InvalidSkillName, c.loadSkill("../escape"));
    try std.testing.expectError(error.InvalidSkillName, c.loadSkill(""));
    try std.testing.expectEqualStrings("", try c.projectInstructions());
    try tmp.dir.writeFile(c.io, .{ .sub_path = "build.zig", .data = "// zig" });
    _ = try c.initProject(false);
    try std.testing.expectError(error.AlreadyInitialized, c.initProject(false));
    const instructions = try c.projectInstructions();
    try std.testing.expect(std.mem.indexOf(u8, instructions, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, try c.skills(), "- verify:") != null);
    _ = try c.initProject(true);
}

test "commands bound runtime/output and report search misses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .cwd() };
    try std.testing.expectEqualStrings("ok", try c.command(&.{ "sh", "-c", "printf ok" }, false, 1000));
    try std.testing.expectEqualStrings("none", try c.command(&.{ "sh", "-c", "exit 1" }, true, 1000));
    try std.testing.expectError(error.Timeout, c.command(&.{ "sh", "-c", "exec sleep 2" }, false, 30));
    try std.testing.expectError(error.Timeout, c.command(&.{ "sh", "-c", "exec sleep 2 >/dev/null 2>&1" }, false, 30));
    const failure = try c.command(&.{ "sh", "-c", "echo diagnostic >&2; exit 7" }, false, 1000);
    try std.testing.expect(std.mem.startsWith(u8, failure, "error:"));
    try std.testing.expect(std.mem.indexOf(u8, failure, "diagnostic") != null);
    try std.testing.expectError(error.StreamTooLong, c.command(&.{ "sh", "-c", "yes output" }, false, 1000));
    var big = try arena.allocator().alloc(u8, limit + 4096);
    @memset(big, 'a');
    @memcpy(big[0..5], "HEAD:");
    @memcpy(big[big.len - 5 ..], ":TAIL");
    const capped = try capCommandOutput(arena.allocator(), big);
    try std.testing.expect(capped.len <= limit);
    try std.testing.expect(std.mem.startsWith(u8, capped, "HEAD:"));
    try std.testing.expect(std.mem.endsWith(u8, capped, ":TAIL"));
    try std.testing.expect(std.mem.indexOf(u8, capped, "[truncated middle") != null);
}

test "rejected checklist replacements preserve completed and pending items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var todo: Todo = .{};
    _ = try todo.update(try j.parse(a, "{\"items\":[{\"task\":\"keep completed work\",\"done\":true},{\"task\":\"keep pending work\",\"done\":false}]}"));
    const original = try a.dupe(u8, todo.slice());
    try std.testing.expectError(error.InvalidTodoItem, todo.update(try j.parse(a, "{\"items\":[{\"task\":\"overwrite\",\"done\":false},{\"task\":\"\",\"done\":false}]}")));
    try std.testing.expectEqualStrings(original, todo.slice());
    const oversized: [4096]u8 = @splat('x');
    const overflow = try j.parse(a, try j.encode(a, .{ .items = .{ .{ .task = "overwrite", .done = false }, .{ .task = &oversized, .done = false } } }));
    try std.testing.expectError(error.StreamTooLong, todo.update(overflow));
    try std.testing.expectEqualStrings(original, todo.slice());
    _ = try todo.update(try j.parse(a, "{\"items\":[]}"));
    try std.testing.expectEqual(0, todo.len);
}

test "shell timeout overrides are validated before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    for ([_]usize{ 0, 300001 }) |timeout| {
        const args = try j.parse(c.a, try j.encode(c.a, .{ .cmd = "touch marker", .timeout_ms = timeout }));
        try std.testing.expectError(error.InvalidTimeout, c.run("bash", args));
    }
    try std.testing.expectError(error.FileNotFound, c.readFile("marker"));
    try std.testing.expectError(error.Timeout, c.run("bash", try j.parse(c.a, "{\"cmd\":\"exec sleep 1\",\"timeout_ms\":10}")));
    try std.testing.expectEqualStrings("ok", try c.run("bash", try j.parse(c.a, "{\"cmd\":\"printf ok\",\"timeout_ms\":300000}")));
}

test "commands scrub secrets before head and tail truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var secrets: @import("secrets.zig").Secrets = .{};
    try secrets.setMemory("HEAD", "head-secret-left-private");
    try secrets.setMemory("TAIL", "tail-secret-right-private");
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir, .secrets = &secrets };
    const output = try c.a.alloc(u8, limit + 4096);
    @memset(output, 'x');
    const head = (limit * 2) / 3;
    const marker_len = "\n...[truncated middle; narrow command or filter output]...\n".len;
    const tail = output.len - (limit - head - marker_len);
    @memcpy(output[head - 8 ..][0..secrets.valAt(0).len], secrets.valAt(0));
    @memcpy(output[tail - 8 ..][0..secrets.valAt(1).len], secrets.valAt(1));
    try tmp.dir.writeFile(c.io, .{ .sub_path = "output", .data = output });
    const result = try c.run("bash", try j.parse(c.a, "{\"cmd\":\"cat output\"}"));
    try std.testing.expect(result.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, result, "truncated middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "head-sec") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "right-private") == null);
    // A second pass must not rewrite generated tags when another secret matches their text.
    try secrets.setMemory("TAG", "REDACTED");
    const short = try c.run("bash", try j.parse(c.a, "{\"cmd\":\"printf head-secret-left-private\"}"));
    try std.testing.expectEqualStrings("[REDACTED:HEAD]", short);
}

test "skill descriptions redact before truncation and preserve UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var secrets: @import("secrets.zig").Secrets = .{};
    try secrets.setMemory("TOKEN", "description-secret-private");
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir, .secrets = &secrets };
    try tmp.dir.createDirPath(c.io, ".omnicode/skills/check");
    const padding: [232]u8 = @splat('x');
    const body = try std.fmt.allocPrint(c.a, "description: {s}description-secret-private\n", .{&padding});
    try tmp.dir.writeFile(c.io, .{ .sub_path = ".omnicode/skills/check/SKILL.md", .data = body });
    try std.testing.expect(std.mem.indexOf(u8, try c.skills(), "descript") == null);
    const unicode_body = try std.fmt.allocPrint(c.a, "description: {s}1234567é\n", .{&padding});
    try tmp.dir.writeFile(c.io, .{ .sub_path = ".omnicode/skills/check/SKILL.md", .data = unicode_body });
    try std.testing.expect(std.unicode.utf8ValidateSlice(try c.skills()));
}

test "unique edits reject overlapping matches without modifying files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    for ([_][]const u8{ "aaa", "ababa", "雪雪雪" }, [_][]const u8{ "aa", "aba", "雪雪" }) |original, old| {
        try tmp.dir.writeFile(c.io, .{ .sub_path = "file", .data = original });
        const args = try j.parse(c.a, try j.encode(c.a, .{ .path = "file", .old = old, .new = "x" }));
        try std.testing.expectError(error.AmbiguousMatch, c.run("edit", args));
        try std.testing.expectEqualStrings(original, try c.readFile("file"));
    }
    try tmp.dir.writeFile(c.io, .{ .sub_path = "file", .data = "aaa" });
    _ = try c.run("edit", try j.parse(c.a, "{\"path\":\"file\",\"old\":\"aa\",\"new\":\"x\",\"all\":true}"));
    try std.testing.expectEqualStrings("xa", try c.readFile("file"));
    _ = try c.run("edit", try j.parse(c.a, "{\"path\":\"file\",\"old\":\"xa\",\"new\":\"unique\"}"));
    try std.testing.expectEqualStrings("unique", try c.readFile("file"));
}

test "NUL in tool paths and command arguments is rejected before side effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "file", .data = "original" });
    for ([_][]const u8{ "read", "write", "edit" }) |tool| {
        const raw = if (std.mem.eql(u8, tool, "read"))
            try j.encode(c.a, .{ .path = "file\x00suffix" })
        else if (std.mem.eql(u8, tool, "write"))
            try j.encode(c.a, .{ .path = "file\x00suffix", .content = "overwrite" })
        else
            try j.encode(c.a, .{ .path = "file\x00suffix", .old = "original", .new = "changed" });
        const args = try j.parse(c.a, raw);
        try std.testing.expectError(error.InvalidPath, c.run(tool, args));
        try std.testing.expectEqualStrings("original", try c.readFile("file"));
    }
    const bash = try j.parse(c.a, try j.encode(c.a, .{ .cmd = "touch marker\x00; false" }));
    try std.testing.expectError(error.InvalidCommandArgument, c.run("bash", bash));
    try std.testing.expectError(error.FileNotFound, c.readFile("marker"));
    for ([_][]const u8{ "glob", "grep" }) |tool| {
        const pattern = try j.parse(c.a, try j.encode(c.a, .{ .pat = "pattern\x00suffix" }));
        try std.testing.expectError(error.InvalidCommandArgument, c.run(tool, pattern));
        const path = try j.parse(c.a, try j.encode(c.a, .{ .pat = "pattern", .path = "file\x00suffix" }));
        try std.testing.expectError(error.InvalidCommandArgument, c.run(tool, path));
    }
    // File contents are length-delimited and may legitimately contain NUL.
    _ = try c.run("write", try j.parse(c.a, try j.encode(c.a, .{ .path = "binary", .content = "a\x00b" })));
    try std.testing.expectEqualStrings("a\x00b", try c.readFile("binary"));
}

test "project initialization preserves oversized files and stops before blocked skills paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const large: [limit + 1]u8 = @splat('x');
    try tmp.dir.writeFile(c.io, .{ .sub_path = "OMNICODE.md", .data = &large });
    try std.testing.expectError(error.AlreadyInitialized, c.initProject(false));
    try std.testing.expectEqualStrings(&large, try c.readFile("OMNICODE.md"));
    try tmp.dir.deleteFile(c.io, "OMNICODE.md");
    try tmp.dir.createDirPath(c.io, ".omnicode/skills/verify");
    try tmp.dir.writeFile(c.io, .{ .sub_path = ".omnicode/skills/verify/SKILL.md", .data = &large });
    _ = try c.initProject(false);
    try std.testing.expectEqualStrings(&large, try c.readFile(".omnicode/skills/verify/SKILL.md"));
    try tmp.dir.deleteFile(c.io, "OMNICODE.md");
    var blocked = c;
    blocked.skills_path = ".omnicode/skills/verify/SKILL.md";
    if (blocked.initProject(false)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectError(error.FileNotFound, c.readFile("OMNICODE.md"));
}

test "read byte windows expose long lines and align whole UTF-8 characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const text = try c.a.alloc(u8, 72000);
    @memset(text, 'x');
    @memcpy(text[70000..][0..12], "TARGET_VALUE");
    try tmp.dir.writeFile(c.io, .{ .sub_path = "long.json", .data = text });
    const lines = try c.run("read", try j.parse(c.a, "{\"path\":\"long.json\"}"));
    try std.testing.expect(std.mem.indexOf(u8, lines, "byte_offset") != null);
    const window = try c.run("read", try j.parse(c.a, "{\"path\":\"long.json\",\"byte_offset\":70000,\"byte_limit\":12}"));
    try std.testing.expect(std.mem.indexOf(u8, window, "TARGET_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, window, "next byte_offset=70012") != null);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "unicode", .data = "A東🦀Z" });
    const east = try c.run("read", try j.parse(c.a, "{\"path\":\"unicode\",\"byte_offset\":2,\"byte_limit\":1}"));
    try std.testing.expect(std.mem.indexOf(u8, east, "bytes 1..4 of 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, east, "\n東\n") != null);
    const crab = try c.run("read", try j.parse(c.a, "{\"path\":\"unicode\",\"byte_offset\":4,\"byte_limit\":1}"));
    try std.testing.expect(std.mem.indexOf(u8, crab, "bytes 4..8 of 9") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(crab));
    const eof = try c.run("read", try j.parse(c.a, "{\"path\":\"unicode\",\"byte_offset\":9}"));
    try std.testing.expect(std.mem.indexOf(u8, eof, "bytes 9..9 of 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, eof, "end of file") != null);
    const capped = try c.run("read", try j.parse(c.a, "{\"path\":\"long.json\",\"byte_limit\":61440}"));
    try std.testing.expect(capped.len <= limit);
}

test "read byte windows redact complete secrets before slicing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var secrets: @import("secrets.zig").Secrets = .{};
    try secrets.setMemory("KEY", "secret-left-private");
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir, .secrets = &secrets };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "input", .data = "aaaasecret-left-privatezzzz" });
    for ([_][]const u8{ "{\"path\":\"input\",\"byte_offset\":0,\"byte_limit\":9}", "{\"path\":\"input\",\"byte_offset\":6,\"byte_limit\":8}" }) |raw| {
        const result = try c.run("read", try j.parse(c.a, raw));
        try std.testing.expect(std.mem.indexOf(u8, result, "secre") == null);
        try std.testing.expect(std.mem.indexOf(u8, result, "cret") == null);
        try std.testing.expect(std.mem.indexOf(u8, result, "private") == null);
    }
    const full = try c.run("read", try j.parse(c.a, "{\"path\":\"input\",\"byte_limit\":100}"));
    try std.testing.expect(std.mem.indexOf(u8, full, "[REDACTED:KEY]") != null);
}

test "read byte windows validate bounds and retain file and output caps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "input", .data = "value" });
    for ([_]usize{ 0, 61441 }) |count| {
        try std.testing.expectError(error.InvalidReadLimit, c.run("read", try j.parse(c.a, try j.encode(c.a, .{ .path = "missing", .byte_limit = count }))));
    }
    try std.testing.expectError(error.ConflictingArguments, c.run("read", try j.parse(c.a, "{\"path\":\"input\",\"offset\":0,\"byte_offset\":0}")));
    try std.testing.expectError(error.InvalidReadOffset, c.run("read", try j.parse(c.a, "{\"path\":\"input\",\"byte_offset\":9223372036854775807}")));
    try std.testing.expectError(error.ExpectedNaturalNumber, c.run("read", try j.parse(c.a, "{\"path\":\"input\",\"byte_offset\":-1}")));
    try tmp.dir.writeFile(c.io, .{ .sub_path = "binary", .data = "prefix\xff" });
    try std.testing.expectError(error.NonUtf8Output, c.run("read", try j.parse(c.a, "{\"path\":\"binary\",\"byte_limit\":1}")));
    const big = try c.a.alloc(u8, 1024 * 1024 + 1);
    @memset(big, 'x');
    try tmp.dir.writeFile(c.io, .{ .sub_path = "too-big", .data = big });
    try std.testing.expectError(error.StreamTooLong, c.run("read", try j.parse(c.a, "{\"path\":\"too-big\",\"byte_limit\":1}")));
    for (big, 0..) |*b, index| b.* = if (index % 100 == 0) '\n' else 'x';
    try tmp.dir.writeFile(c.io, .{ .sub_path = "many-lines", .data = big[0 .. 1024 * 1024] });
    const lines = try c.run("read", try j.parse(c.a, "{\"path\":\"many-lines\",\"limit\":10000}"));
    try std.testing.expect(lines.len <= limit);
}

test "checklist pending count reads status rather than task text" {
    var todo: Todo = .{};
    try std.testing.expectEqual(0, todo.pending());
    const text = "1. [x] Mention [ ] in completed task\n2. [ ] pending\n12. [ ] also pending\nplain [ ] text\n";
    @memcpy(todo.text[0..text.len], text);
    todo.len = text.len;
    try std.testing.expectEqual(2, todo.pending());
}
