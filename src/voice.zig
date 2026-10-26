const std = @import("std");
const j = @import("json.zig");
const tools = @import("tools.zig");
const Route = @import("router.zig").Route;
const Catalog = @import("catalog.zig").Catalog;
const Usage = @import("usage.zig").Usage;
const Ui = @import("ui.zig").Ui;

pub const max_audio_bytes = 4 * 1024 * 1024;
pub const default_voice_model = "google/gemini-2.0-flash-lite-001";

pub fn audioFormat(path: []const u8) []const u8 {
    if (endsWithIgnoreCase(path, ".mp3")) return "mp3";
    if (endsWithIgnoreCase(path, ".ogg")) return "ogg";
    if (endsWithIgnoreCase(path, ".flac")) return "flac";
    if (endsWithIgnoreCase(path, ".m4a")) return "m4a";
    return "wav";
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn hasAudioExtension(path: []const u8) bool {
    for ([_][]const u8{ ".wav", ".mp3", ".ogg", ".flac", ".m4a" }) |extension|
        if (endsWithIgnoreCase(path, extension)) return true;
    return false;
}

fn hasExtension(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.mem.lastIndexOfScalar(u8, name, '.') != null;
}

fn isOpenRouterUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host orelse return false;
    return std.ascii.eqlIgnoreCase(switch (host) {
        .raw, .percent_encoded => |value| value,
    }, "openrouter.ai");
}

/// Record mono 16 kHz WAV audio into `.omnicode/voice.wav` using `$OMNICODE_VOICE_CMD`, `arecord`, `rec`, or `ffmpeg`.
pub fn recordAudio(c: tools.Context, env: *const std.process.Environ.Map, seconds: usize) ![]const u8 {
    const secs = std.math.clamp(seconds, 1, 30);
    try c.dir.createDirPath(c.io, ".omnicode");
    const out_path = ".omnicode/voice.wav";
    c.dir.deleteFile(c.io, out_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const cmd = if (env.get("OMNICODE_VOICE_CMD")) |custom|
        try std.fmt.allocPrint(c.a, "export OMNICODE_VOICE_OUT={s} OMNICODE_VOICE_SECONDS={d}; {s}", .{ out_path, secs, custom })
    else
        try std.fmt.allocPrint(
            c.a,
            "arecord -q -f S16_LE -r 16000 -c 1 -d {d} {s} 2>/dev/null || " ++
                "rec -q -r 16000 -c 1 -b 16 {s} trim 0 {d} 2>/dev/null || " ++
                "ffmpeg -y -loglevel error -f alsa -i default -t {d} -ar 16000 -ac 1 {s} 2>/dev/null",
            .{ secs, out_path, out_path, secs, secs, out_path },
        );
    const res = try c.command(&.{ "sh", "-c", cmd }, false, @intCast((secs + 15) * 1000));
    if (std.mem.startsWith(u8, res, "error:")) return error.VoiceRecordFailed;
    return out_path;
}

pub fn extractTranscript(response: j.Value) ![]const u8 {
    if (response != .object) return error.InvalidResponse;
    // OpenRouter / OpenAI Chat Completions response shape: choices[0].message.content
    if (response.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const msg = try j.get(choices.array.items[0], "message");
            if (msg == .object) {
                if (msg.object.get("content")) |content| {
                    if (content == .string) {
                        const t = std.mem.trim(u8, content.string, " \t\r\n");
                        if (t.len > 0) return t;
                    }
                }
            }
        }
    }
    // Messages response shape: content[0].text
    if (response.object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |block| {
                const kind = j.str(block, "type") catch continue;
                if (std.mem.eql(u8, kind, "text")) {
                    const t = std.mem.trim(u8, try j.str(block, "text"), " \t\r\n");
                    if (t.len > 0) return t;
                }
            }
        }
    }
    return error.EmptyTranscript;
}

fn sendVoiceRequest(a: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8, key: []const u8, anthropic_auth: bool) !j.Value {
    const auth_value = if (anthropic_auth) key else try std.fmt.allocPrint(a, "Bearer {s}", .{key});
    defer {
        if (!anthropic_auth) std.crypto.secureZero(u8, @constCast(auth_value));
    }
    const auth: std.http.Header = .{
        .name = if (anthropic_auth) "x-api-key" else "Authorization",
        .value = auth_value,
    };
    return @import("http.zig").fetch(a, io, url, body, &.{ auth, .{ .name = "anthropic-version", .value = "2023-06-01" } }, 2 * 1024 * 1024, 60_000);
}

/// Read an audio file, base64-encode it, and transcribe via a cheap OpenRouter audio model.
pub fn transcribeFile(c: tools.Context, env: *const std.process.Environ.Map, route: Route, path: []const u8, ui: Ui) ![]const u8 {
    try @import("storage.zig").validatePath(path);
    if (hasExtension(path) and !hasAudioExtension(path)) return error.UnsupportedAudioFormat;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const audio = try @import("storage.zig").readRegular(c.io, c.dir, path, sa, .limited(max_audio_bytes));
    defer std.crypto.secureZero(u8, @constCast(audio));
    if (audio.len == 0) return error.EmptyAudio;
    const encoded_len = std.base64.standard.Encoder.calcSize(audio.len);
    const encoded = try sa.alloc(u8, encoded_len);
    defer std.crypto.secureZero(u8, encoded);
    _ = std.base64.standard.Encoder.encode(encoded, audio);

    const configured_url = if (env.get("VOICE_URL")) |value|
        if (value.len > 0) value else env.get("API_URL")
    else
        env.get("API_URL");
    const custom_url = if (configured_url) |value| if (value.len > 0) value else null else null;
    const url = custom_url orelse "https://openrouter.ai/api/v1/chat/completions";
    const or_key = env.get("OPENROUTER_API_KEY") orelse "";
    const requires_openrouter_key = custom_url == null or isOpenRouterUrl(url);
    const fallback_key = if (route.key.len > 0)
        route.key
    else if (env.get("OPENAI_API_KEY")) |k|
        k
    else if (env.get("GEMINI_API_KEY")) |k|
        k
    else if (env.get("GROQ_API_KEY")) |k|
        k
    else
        "";
    const key = if (or_key.len > 0) or_key else if (!requires_openrouter_key) fallback_key else "";
    if (key.len == 0) return error.MissingVoiceApiKey;

    const pinned_voice = env.get("VOICE_MODEL");
    const voice_model = if (pinned_voice) |m|
        if (m.len > 0) m else default_voice_model
    else blk: {
        if (or_key.len > 0 or route.provider == .openrouter) {
            if (Catalog.load(sa, c.io, env)) |cat| {
                if (cat.selectVoice(route.mode, null)) |selected| break :blk selected;
            } else |_| {}
        }
        break :blk default_voice_model;
    };

    const body = try j.encode(sa, .{
        .model = voice_model,
        .max_tokens = @as(usize, 1024),
        .system = "Transcribe the spoken coding request verbatim. Output only the transcription.",
        .messages = &.{.{
            .role = "user",
            .content = &.{
                .{ .type = "text", .text = "Transcribe this spoken coding request verbatim. Output only the transcription." },
                .{ .type = "input_audio", .input_audio = .{ .data = encoded, .format = audioFormat(path) } },
            },
        }},
    });
    defer std.crypto.secureZero(u8, @constCast(body));
    const anthropic_auth = !requires_openrouter_key and or_key.len == 0 and route.provider == .anthropic;
    const response = try ui.work("Transcribing voice...", sendVoiceRequest, .{ sa, c.io, url, body, key, anthropic_auth });
    var voice_route = route;
    voice_route.model = voice_model;
    const delta = Usage.response(response, voice_route);
    if (ui.usage) |total| total.add(delta);
    const transcript = try extractTranscript(response);
    defer std.crypto.secureZero(u8, @constCast(transcript));
    const safe_transcript = try c.scrub(transcript);
    defer {
        if (safe_transcript.ptr != transcript.ptr)
            std.crypto.secureZero(u8, @constCast(safe_transcript));
    }
    return c.a.dupe(u8, safe_transcript);
}

test "voice helper detects audio formats and extracts transcripts from both API shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("wav", audioFormat("clip.wav"));
    try std.testing.expectEqualStrings("mp3", audioFormat("clip.mp3"));
    try std.testing.expectEqualStrings("ogg", audioFormat("clip.ogg"));
    const chat = try j.parse(a, "{\"choices\":[{\"message\":{\"content\":\"  fix the failing test in src/main.zig  \"}}]}");
    try std.testing.expectEqualStrings("fix the failing test in src/main.zig", try extractTranscript(chat));
    const msg = try j.parse(a, "{\"content\":[{\"type\":\"text\",\"text\":\"explain router.zig\\n\"}]}");
    try std.testing.expectEqualStrings("explain router.zig", try extractTranscript(msg));
    try std.testing.expectError(error.EmptyTranscript, extractTranscript(try j.parse(a, "{\"content\":[]}")));
}
