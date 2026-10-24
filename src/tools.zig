const std = @import("std");
const j = @import("json.zig");
const Io = std.Io;
pub const limit = 64 * 1024;

const explore_tools =
    \\{"name":"read","description":"Read numbered lines, zero-based offset; max 1 MiB file","input_schema":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}},
    \\{"name":"glob","description":"Find files using ripgrep glob rules; respects ignore files","input_schema":{"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"}},"required":["pat"]}},
    \\{"name":"grep","description":"Search regex with ripgrep; respects ignore files","input_schema":{"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"}},"required":["pat"]}},
    \\{"name":"skill","description":"Load instructions for an advertised skill by name","input_schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}
;

const edit_tools = explore_tools ++ ",\n" ++
    \\{"name":"write","description":"Create or overwrite a file","input_schema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
    \\{"name":"edit","description":"Replace exact nonempty text; must be unique unless all=true","input_schema":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"},"all":{"type":"boolean"}},"required":["path","old","new"]}},
    \\{"name":"bash","description":"Run shell command; 30s deadline, 64 KiB per output stream","input_schema":{"type":"object","properties":{"cmd":{"type":"string"}},"required":["cmd"]}},
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

    pub fn update(self: *Todo, args: j.Value) ![]const u8 {
        if (args != .object) return error.ExpectedObject;
        const list = args.object.get("items") orelse return if (self.len == 0) "(empty todo list)" else self.slice();
        if (list != .array or list.array.items.len > 64) return error.InvalidTodoList;
        var w = Io.Writer.fixed(&self.text);
        for (list.array.items, 0..) |item, idx| {
            const task = try j.str(item, "task");
            if (task.len == 0 or std.mem.indexOfScalar(u8, task, '\n') != null) return error.InvalidTodoItem;
            const done_val = try j.get(item, "done");
            if (done_val != .bool) return error.ExpectedBoolean;
            w.print("{d}. [{s}] {s}\n", .{ idx + 1, if (done_val.bool) "x" else " ", task }) catch return error.StreamTooLong;
        }
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

    pub fn readFile(c: Context, path: []const u8) ![]const u8 {
        return c.dir.readFileAlloc(c.io, path, c.a, .limited(1024 * 1024));
    }

    pub fn run(c: Context, name: []const u8, args: j.Value) ![]const u8 {
        const out = try c.runRaw(name, args);
        if (c.secrets) |s| return s.scrub(c.a, out, c.env);
        return out;
    }

    fn runRaw(c: Context, name: []const u8, args: j.Value) ![]const u8 {
        if (c.read_only and (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "todo")))
            return error.ReadOnlySubagent;
        if (std.mem.eql(u8, name, "todo")) {
            const t = c.todo orelse return "(todo unavailable)";
            return c.a.dupe(u8, try t.update(args));
        }
        if (std.mem.eql(u8, name, "skill")) return c.loadSkill(try j.str(args, "name"));
        if (std.mem.eql(u8, name, "write")) {
            const content = try j.str(args, "content");
            if (content.len > 1024 * 1024) return error.StreamTooLong;
            try c.dir.writeFile(c.io, .{ .sub_path = try j.str(args, "path"), .data = content });
            return "ok";
        }
        if (std.mem.eql(u8, name, "read")) {
            const text = try c.readFile(try j.str(args, "path"));
            const offset = try j.number(args, "offset", 0);
            const count = try j.number(args, "limit", 200);
            var out: Io.Writer.Allocating = .init(c.a);
            var lines = std.mem.splitScalar(u8, text, '\n');
            var n: usize = 0;
            while (lines.next()) |line| : (n += 1) {
                if (line.len == 0 and lines.peek() == null) break;
                if (n < offset) continue;
                if (n - offset >= count or out.writer.end + line.len + 32 > limit) {
                    try out.writer.writeAll("[truncated; use offset]\n");
                    break;
                }
                try out.writer.print("{d}| {s}\n", .{ n + 1, line });
            }
            return out.toOwnedSlice();
        }
        if (std.mem.eql(u8, name, "edit")) {
            const path = try j.str(args, "path");
            const text = try c.readFile(path);
            const old = try j.str(args, "old");
            const new = try j.str(args, "new");
            if (old.len == 0) return error.EmptyMatch;
            const count = std.mem.count(u8, text, old);
            if (count == 0) return error.MatchNotFound;
            const all = if (args.object.get("all")) |v| if (v == .bool) v.bool else return error.ExpectedBoolean else false;
            if (count > 1 and !all) return error.AmbiguousMatch;
            const size = std.math.add(usize, text.len - count * old.len, try std.math.mul(usize, count, new.len)) catch return error.StreamTooLong;
            if (size > 1024 * 1024) return error.StreamTooLong;
            const replacement = try std.mem.replaceOwned(u8, c.a, text, old, new);
            try c.dir.writeFile(c.io, .{ .sub_path = path, .data = replacement });
            return "ok";
        }
        if (std.mem.eql(u8, name, "bash")) return c.command(&.{ "sh", "-c", try j.str(args, "cmd") }, false, 30_000);
        const path = try j.optional(args, "path", ".");
        if (std.mem.eql(u8, name, "glob")) return c.command(&.{
            "rg",           "--no-config",          "--files",
            "--glob",       "!.git",                "--glob",
            "!.venv",       "--glob",               "!venv",
            "--glob",       "!node_modules",        "--glob",
            "!__pycache__", "--glob",               "!.zig-cache",
            "--glob",       try j.str(args, "pat"), "--",
            path,
        }, true, 30_000);
        if (std.mem.eql(u8, name, "grep")) return c.command(&.{
            "rg",           "--no-config",          "--color=never",
            "-n",           "-m",                   "50",
            "--glob",       "!.git",                "--glob",
            "!.venv",       "--glob",               "!venv",
            "--glob",       "!node_modules",        "--glob",
            "!__pycache__", "--glob",               "!.zig-cache",
            "--",           try j.str(args, "pat"), path,
        }, true, 30_000);
        return error.UnknownTool;
    }

    pub fn command(c: Context, argv: []const []const u8, search: bool, milliseconds: i64) ![]const u8 {
        const result = try @import("deadline.zig").run(c.io, std.process.run, .{ c.a, c.io, std.process.RunOptions{
            .argv = argv,
            .cwd = .{ .dir = c.dir },
            .environ_map = c.env,
            .stdout_limit = .limited(limit),
            .stderr_limit = .limited(limit),
        } }, milliseconds);
        if (search and result.term == .exited and result.term.exited == 1) return "none";
        if (!result.term.success()) return std.fmt.allocPrint(c.a, "error: {f}\n{s}{s}", .{ result.term, result.stdout, result.stderr });
        return std.fmt.allocPrint(c.a, "{s}{s}", .{ result.stdout, result.stderr });
    }

    pub fn loadSkill(c: Context, name: []const u8) ![]const u8 {
        if (!validName(name)) return error.InvalidSkillName;
        const path = try std.fmt.allocPrint(c.a, "{s}/{s}/SKILL.md", .{ c.skills_path, name });
        const text = try c.readFile(path);
        if (text.len > limit) return error.StreamTooLong;
        return text;
    }

    pub fn skills(c: Context) ![]const u8 {
        const dir = c.dir.openDir(c.io, c.skills_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return "",
            else => return err,
        };
        defer dir.close(c.io);
        var out: Io.Writer.Allocating = .init(c.a);
        var it = dir.iterate();
        while (try it.next(c.io)) |entry| {
            if (entry.kind != .directory or !validName(entry.name)) continue;
            const text = c.loadSkill(entry.name) catch continue;
            var description: []const u8 = "Local instructions";
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "description:")) {
                    description = std.mem.trim(u8, line[12..], " \t\r\"'");
                    break;
                }
            }
            if (out.writer.end + entry.name.len + @min(description.len, 240) + 8 > limit) return error.TooManySkills;
            try out.writer.print("- {s}: {s}\n", .{ entry.name, description[0..@min(description.len, 240)] });
        }
        return out.toOwnedSlice();
    }

    pub fn projectInstructions(c: Context) ![]const u8 {
        return c.dir.readFileAlloc(c.io, "OMNICODE.md", c.a, .limited(limit)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }

    fn hasFile(c: Context, path: []const u8) bool {
        _ = c.dir.readFileAlloc(c.io, path, c.a, .limited(limit)) catch return false;
        return true;
    }

    pub fn initProject(c: Context, force: bool) ![]const u8 {
        if (!force and c.hasFile("OMNICODE.md")) return error.AlreadyInitialized;
        const commands = if (c.hasFile("build.zig"))
            "- Build: `zig build`\n- Test: `zig build test`\n- Format check: `zig fmt --check src`"
        else if (c.hasFile("Cargo.toml"))
            "- Build: `cargo build`\n- Test: `cargo test`\n- Format check: `cargo fmt --check`"
        else if (c.hasFile("package.json"))
            "- Build: `npm run build`\n- Test: `npm test`"
        else if (c.hasFile("pyproject.toml") or c.hasFile("pytest.ini"))
            "- Test: `pytest`"
        else if (c.hasFile("go.mod"))
            "- Build: `go build ./...`\n- Test: `go test ./...`"
        else if (c.hasFile("Makefile"))
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
        try c.dir.writeFile(c.io, .{ .sub_path = "OMNICODE.md", .data = doc });
        const skill_path = try std.fmt.allocPrint(c.a, "{s}/verify", .{c.skills_path});
        const skill_file = try std.fmt.allocPrint(c.a, "{s}/verify/SKILL.md", .{c.skills_path});
        try c.dir.createDirPath(c.io, skill_path);
        if (force or !c.hasFile(skill_file)) {
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
            try c.dir.writeFile(c.io, .{ .sub_path = skill_file, .data = verify_skill });
        }
        return "Initialized OMNICODE.md and .omnicode/skills/verify/SKILL.md.";
    }

    pub fn collectDiff(c: Context) ![]const u8 {
        const raw = c.command(&.{ "sh", "-c", "git status --short 2>/dev/null; printf '\\n---\\n'; git diff HEAD 2>/dev/null || git diff 2>/dev/null" }, false, 15_000) catch
            return "(git diff unavailable; use glob/read to inspect files)";
        if (std.mem.startsWith(u8, raw, "error:")) return "(not a git repository; use glob/read to inspect files)";
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "---")) return "(working tree clean; inspect recent files with glob/read)";
        var max = @min(raw.len, limit / 2);
        while (max > 0 and !std.unicode.utf8ValidateSlice(raw[0..max])) max -= 1;
        return raw[0..max];
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

test "file tools modify real files and reject ambiguous or invalid edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    _ = try c.run("write", try j.parse(c.a, "{\"path\":\"a\",\"content\":\"one\\ntwo\\none\"}"));
    const read = try c.run("read", try j.parse(c.a, "{\"path\":\"a\",\"offset\":1,\"limit\":1}"));
    try std.testing.expect(std.mem.startsWith(u8, read, "2| two\n"));
    try std.testing.expect(std.mem.indexOf(u8, read, "truncated") != null);
    const edit = try j.parse(c.a, "{\"path\":\"a\",\"old\":\"one\",\"new\":\"three\"}");
    try std.testing.expectError(error.AmbiguousMatch, c.run("edit", edit));
    _ = try c.run("edit", try j.parse(c.a, "{\"path\":\"a\",\"old\":\"one\",\"new\":\"three\",\"all\":true}"));
    try std.testing.expectEqualStrings("three\ntwo\nthree", try c.readFile("a"));
    var ro = c;
    ro.read_only = true;
    try std.testing.expectError(error.ReadOnlySubagent, ro.run("write", try j.parse(c.a, "{\"path\":\"b\",\"content\":\"x\"}")));
    try std.testing.expectError(error.ReadOnlySubagent, ro.run("edit", edit));
    try std.testing.expectError(error.ReadOnlySubagent, ro.run("bash", try j.parse(c.a, "{\"cmd\":\"true\"}")));
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
}
