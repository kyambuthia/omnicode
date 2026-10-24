const std = @import("std");
const j = @import("json.zig");
const Io = std.Io;
pub const limit = 64 * 1024;

pub const schema =
    \\[
    \\{"name":"read","description":"Read numbered lines, zero-based offset; max 1 MiB file","input_schema":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}},
    \\{"name":"write","description":"Create or overwrite a file","input_schema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},
    \\{"name":"edit","description":"Replace exact nonempty text; must be unique unless all=true","input_schema":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"},"all":{"type":"boolean"}},"required":["path","old","new"]}},
    \\{"name":"glob","description":"Find files using ripgrep glob rules; respects ignore files","input_schema":{"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"}},"required":["pat"]}},
    \\{"name":"grep","description":"Search regex with ripgrep; respects ignore files","input_schema":{"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"}},"required":["pat"]}},
    \\{"name":"bash","description":"Run shell command; 30s deadline, 64 KiB per output stream","input_schema":{"type":"object","properties":{"cmd":{"type":"string"}},"required":["cmd"]}},
    \\{"name":"skill","description":"Load instructions for an advertised skill by name","input_schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}
    \\]
;

pub const Context = struct {
    a: j.Allocator,
    io: Io,
    dir: Io.Dir = .cwd(),
    skills_path: []const u8 = ".omnicode/skills",

    pub fn readFile(c: Context, path: []const u8) ![]const u8 {
        return c.dir.readFileAlloc(c.io, path, c.a, .limited(1024 * 1024));
    }

    pub fn run(c: Context, name: []const u8, args: j.Value) ![]const u8 {
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
                if (n < offset) continue;
                if (n - offset >= count or out.writer.end + line.len + 32 > limit) break;
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
        if (std.mem.eql(u8, name, "glob")) return c.command(&.{ "rg", "--no-config", "--files", "--glob", try j.str(args, "pat"), "--", path }, true, 30_000);
        if (std.mem.eql(u8, name, "grep")) return c.command(&.{ "rg", "--no-config", "--color=never", "-n", "-m", "50", "--", try j.str(args, "pat"), path }, true, 30_000);
        return error.UnknownTool;
    }

    pub fn command(c: Context, argv: []const []const u8, search: bool, milliseconds: i64) ![]const u8 {
        const result = try @import("deadline.zig").run(c.io, std.process.run, .{ c.a, c.io, std.process.RunOptions{
            .argv = argv,
            .cwd = .{ .dir = c.dir },
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
};

fn validName(name: []const u8) bool {
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
    try std.testing.expectEqualStrings("2| two\n", read);
    const edit = try j.parse(c.a, "{\"path\":\"a\",\"old\":\"one\",\"new\":\"three\"}");
    try std.testing.expectError(error.AmbiguousMatch, c.run("edit", edit));
    _ = try c.run("edit", try j.parse(c.a, "{\"path\":\"a\",\"old\":\"one\",\"new\":\"three\",\"all\":true}"));
    try std.testing.expectEqualStrings("three\ntwo\nthree", try c.readFile("a"));
    try std.testing.expectError(error.EmptyMatch, c.run("edit", try j.parse(c.a, "{\"path\":\"a\",\"old\":\"\",\"new\":\"x\"}")));
    try std.testing.expectError(error.ExpectedNaturalNumber, c.run("read", try j.parse(c.a, "{\"path\":\"a\",\"offset\":-1}")));
    try std.testing.expectError(error.FileNotFound, c.run("read", try j.parse(c.a, "{\"path\":\"missing\"}")));
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
}

test "commands bound runtime/output and report search misses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io };
    try std.testing.expectEqualStrings("ok", try c.command(&.{ "sh", "-c", "printf ok" }, false, 1000));
    try std.testing.expectEqualStrings("none", try c.command(&.{ "sh", "-c", "exit 1" }, true, 1000));
    try std.testing.expectError(error.Timeout, c.command(&.{ "sh", "-c", "exec sleep 2" }, false, 30));
    try std.testing.expectError(error.Timeout, c.command(&.{ "sh", "-c", "exec sleep 2 >/dev/null 2>&1" }, false, 30));
    const failure = try c.command(&.{ "sh", "-c", "echo diagnostic >&2; exit 7" }, false, 1000);
    try std.testing.expect(std.mem.startsWith(u8, failure, "error:"));
    try std.testing.expect(std.mem.indexOf(u8, failure, "diagnostic") != null);
    try std.testing.expectError(error.StreamTooLong, c.command(&.{ "sh", "-c", "yes output" }, false, 1000));
}
