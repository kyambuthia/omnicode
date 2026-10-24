const std = @import("std");
const j = @import("json.zig");
const router = @import("router.zig");
const Route = router.Route;
const Provider = router.Provider;
const Price = @import("pricing.zig").Price;

pub const Catalog = struct {
    models: []const j.Value,

    pub fn load(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Catalog {
        // Public metadata: never attach the inference key to a configurable catalog URL.
        const value = try @import("http.zig").fetch(a, io, env.get("MODELS_URL") orelse
            "https://openrouter.ai/api/v1/models?supported_parameters=tools&sort=agentic-high-to-low", null, &.{}, 8 * 1024 * 1024, 15_000);
        return parse(value);
    }

    pub fn parse(value: j.Value) !Catalog {
        const data = try j.get(value, "data");
        if (data != .array) return error.InvalidCatalog;
        return .{ .models = data.array.items };
    }

    pub fn select(self: Catalog, base: Route, requested: ?[]const u8, development: bool) !Route {
        var best: ?Route = null;
        var score = std.math.inf(f64);
        var candidates: usize = 0;
        for (self.models) |model| {
            const id = j.str(model, "id") catch continue;
            if (requested) |name| if (!std.mem.eql(u8, id, name)) continue;
            const price = Price.parse(j.get(model, "pricing") catch continue) orelse continue;
            if (base.mode == .free and !price.free) {
                if (requested != null) return error.PaidModelInFreeMode;
                continue;
            }
            if (!contains(model, "supported_parameters", "tools") or
                !contains(j.get(model, "architecture") catch .null, "output_modalities", "text") or
                (j.number(model, "context_length", 0) catch 0) < 32768) continue;
            const top = j.get(model, "top_provider") catch .null;
            if ((j.number(top, "max_completion_tokens", 8192) catch 8192) < 8192) continue;
            // Exclude routers and batch/other variants; :free is a concrete zero-price variant.
            if (std.mem.startsWith(u8, id, "openrouter/") or std.mem.startsWith(u8, id, "~") or
                (std.mem.indexOfScalar(u8, id, ':') != null and !std.mem.endsWith(u8, id, ":free"))) continue;
            candidates += 1;
            if (base.mode == .cost_max and requested == null and candidates > @as(usize, if (development) 16 else 32)) break;
            const cost = price.request + 1000 * (price.input + price.output * @as(f64, if (development) 3 else 1));
            if (cost < score) {
                var route = base;
                route.model = id;
                route.price = price;
                route.context_length = j.number(model, "context_length", 32768) catch 32768;
                best = route;
                score = cost;
            }
        }
        return best orelse if (base.mode == .free) error.NoFreeModels else error.ModelUnavailable;
    }

    /// Pick the cheapest model in the catalog that accepts audio input and emits text output.
    pub fn selectVoice(self: Catalog, mode: @FieldType(Route, "mode"), requested: ?[]const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var score = std.math.inf(f64);
        for (self.models) |model| {
            const id = j.str(model, "id") catch continue;
            if (requested) |name| if (!std.mem.eql(u8, id, name)) continue;
            const price = Price.parse(j.get(model, "pricing") catch continue) orelse continue;
            if (mode == .free and !price.free) continue;
            const arch = j.get(model, "architecture") catch .null;
            if (!contains(arch, "input_modalities", "audio") or !contains(arch, "output_modalities", "text")) continue;
            if (std.mem.startsWith(u8, id, "openrouter/") or std.mem.startsWith(u8, id, "~")) continue;
            const cost = price.request + 1000 * (price.input + price.output);
            if (cost < score) {
                best = id;
                score = cost;
            }
        }
        return best;
    }
};

pub const ModelMenu = struct {
    pub const max_items = 32;
    providers: [max_items]Provider = undefined,
    models: [max_items][160]u8 = undefined,
    model_lens: [max_items]usize = @splat(0),
    count: usize = 0,

    pub fn add(self: *ModelMenu, provider: Provider, model_id: []const u8) ?usize {
        if (model_id.len == 0 or model_id.len > 160 or std.mem.eql(u8, model_id, "auto")) return null;
        for (0..self.count) |i| {
            if (self.providers[i] == provider and std.mem.eql(u8, self.models[i][0..self.model_lens[i]], model_id)) return null;
        }
        if (self.count >= max_items) return null;
        const idx = self.count;
        self.providers[idx] = provider;
        @memcpy(self.models[idx][0..model_id.len], model_id);
        self.model_lens[idx] = model_id.len;
        self.count += 1;
        return self.count;
    }

    pub fn get(self: *const ModelMenu, one_based: usize) ?struct { provider: Provider, model: []const u8 } {
        if (one_based == 0 or one_based > self.count) return null;
        const idx = one_based - 1;
        return .{ .provider = self.providers[idx], .model = self.models[idx][0..self.model_lens[idx]] };
    }

    pub fn populateAndFormat(
        self: *ModelMenu,
        a: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        route: Route,
        fetch_catalog: bool,
    ) ![]const u8 {
        self.count = 0;
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("Available models:\n");
        if (env.get("MODEL")) |m| {
            if (self.add(route.provider, m)) |idx| {
                const active = std.mem.eql(u8, route.model, m);
                try out.writer.print("  [{d:>2}]{s} {s:<12} {s} (configured strong)\n", .{ idx, if (active) "*" else " ", @tagName(route.provider), m });
            }
        }
        if (env.get("FAST_MODEL")) |m| {
            if (self.add(route.provider, m)) |idx| {
                const active = std.mem.eql(u8, route.model, m);
                try out.writer.print("  [{d:>2}]{s} {s:<12} {s} (configured fast)\n", .{ idx, if (active) "*" else " ", @tagName(route.provider), m });
            }
        }
        if (route.provider == .openrouter or fetch_catalog) {
            if (Catalog.load(a, io, env)) |cat| {
                var shown: usize = 0;
                for (cat.models) |model| {
                    if (shown >= 10) break;
                    const id = j.str(model, "id") catch continue;
                    const price = Price.parse(j.get(model, "pricing") catch continue) orelse continue;
                    if (route.mode == .free and !price.free) continue;
                    if (!contains(model, "supported_parameters", "tools") or
                        !contains(j.get(model, "architecture") catch .null, "output_modalities", "text")) continue;
                    const ctx = j.number(model, "context_length", 0) catch 0;
                    if (ctx < 32768) continue;
                    const top = j.get(model, "top_provider") catch .null;
                    if ((j.number(top, "max_completion_tokens", 8192) catch 8192) < 8192) continue;
                    if (std.mem.startsWith(u8, id, "openrouter/") or std.mem.startsWith(u8, id, "~") or
                        (std.mem.indexOfScalar(u8, id, ':') != null and !std.mem.endsWith(u8, id, ":free"))) continue;
                    if (self.add(.openrouter, id)) |idx| {
                        const active = route.provider == .openrouter and std.mem.eql(u8, route.model, id);
                        if (price.free) {
                            try out.writer.print("  [{d:>2}]{s} openrouter   {s:<34} · {d}k ctx · free\n", .{ idx, if (active) "*" else " ", id, ctx / 1024 });
                        } else {
                            try out.writer.print("  [{d:>2}]{s} openrouter   {s:<34} · {d}k ctx · ${d:.2}/${d:.2} per 1M\n", .{
                                idx, if (active) "*" else " ", id, ctx / 1024, price.input * 1_000_000, price.output * 1_000_000,
                            });
                        }
                        shown += 1;
                    }
                }
            } else |_| {}
        }
        if (route.mode != .free) {
            const presets = [_]struct { p: Provider, m: []const u8, tier: []const u8 }{
                .{ .p = .anthropic, .m = "claude-haiku-4-5", .tier = "fast" },
                .{ .p = .anthropic, .m = "claude-sonnet-4-5", .tier = "strong" },
                .{ .p = .deepseek, .m = "deepseek-chat", .tier = "fast" },
                .{ .p = .deepseek, .m = "deepseek-reasoner", .tier = "strong" },
                .{ .p = .xai, .m = "grok-3-mini", .tier = "fast" },
                .{ .p = .xai, .m = "grok-4", .tier = "strong" },
                .{ .p = .openai, .m = "gpt-4.1-mini", .tier = "fast" },
                .{ .p = .openai, .m = "gpt-4.1", .tier = "strong" },
                .{ .p = .gemini, .m = "gemini-2.5-flash", .tier = "fast" },
                .{ .p = .gemini, .m = "gemini-2.5-pro", .tier = "strong" },
                .{ .p = .groq, .m = "llama-3.3-70b-versatile", .tier = "fast/strong" },
                .{ .p = .abliteration, .m = "abliterated-model", .tier = "fast" },
                .{ .p = .abliteration, .m = "abliterated-model-large-flash", .tier = "strong" },
            };
            for (presets) |item| {
                if (self.add(item.p, item.m)) |idx| {
                    const active = route.provider == item.p and std.mem.eql(u8, route.model, item.m);
                    const has_key = if (env.get(item.p.envKey())) |v| v.len > 0 else false;
                    try out.writer.print("  [{d:>2}]{s} {s:<12} {s:<30} · {s}{s}\n", .{
                        idx,
                        if (active) "*" else " ",
                        @tagName(item.p),
                        item.m,
                        item.tier,
                        if (has_key) " · key ready" else "",
                    });
                }
            }
        }
        try out.writer.writeAll("Switch: /model <number> | /model <MODEL> | /model <PROVIDER> <MODEL> | /model fast|strong|auto\n");
        return out.toOwnedSlice();
    }
};

fn contains(value: j.Value, key: []const u8, needle: []const u8) bool {
    const list = j.get(value, key) catch return false;
    if (list != .array) return false;
    for (list.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

test "catalog chooses live prices and rejects paid, malformed, and incapable free candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var base = try Route.init(&env, "openrouter", null);
    const catalog = try Catalog.parse(try j.parse(a,
        \\{"data":[
        \\{"id":"bad/free","pricing":{"prompt":"NaN","completion":"0"}},
        \\{"id":"paid/model","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":65536,"supported_parameters":["tools"],"architecture":{"output_modalities":["text"]}},
        \\{"id":"cheaper/model","pricing":{"prompt":"0.0000001","completion":"0.0000002"},"context_length":65536,"supported_parameters":["tools"],"architecture":{"output_modalities":["text"]}},
        \\{"id":"fee/free","pricing":{"prompt":"0","completion":"0","request":"0.01"},"context_length":65536,"supported_parameters":["tools"],"architecture":{"output_modalities":["text"]}},
        \\{"id":"no-tools/free","pricing":{"prompt":"0","completion":"0"},"context_length":65536,"architecture":{"output_modalities":["text"]}},
        \\{"id":"available/model:free","pricing":{"prompt":"0","completion":"0"},"context_length":65536,"supported_parameters":["tools"],"architecture":{"output_modalities":["text"]}}]}
    ));
    try std.testing.expectEqualStrings("available/model:free", (try catalog.select(base, null, true)).model);
    try std.testing.expectEqualStrings("cheaper/model", (try catalog.select(base, "cheaper/model", true)).model);
    base.mode = .free;
    try std.testing.expectError(error.PaidModelInFreeMode, catalog.select(base, "paid/model", false));
    try std.testing.expectError(error.NoFreeModels, catalog.select(base, "no-tools/free", false));
    try std.testing.expect((try catalog.select(base, null, false)).price.?.free);
    try std.testing.expectError(error.InvalidCatalog, Catalog.parse(try j.parse(a, "{\"data\":{}}")));
}

test "cost mode bounds the ranked pool while free mode searches the whole catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var base = try Route.init(&env, "openrouter", null);
    var models: std.ArrayList(j.Value) = .empty;
    for (0..33) |i| {
        const rate: f64 = if (i == 32) 0 else if (i == 16) 0.0000001 else 0.000001;
        try models.append(a, try j.parse(a, try j.encode(a, .{
            .id = try std.fmt.allocPrint(a, "model/{d}", .{i}),
            .pricing = .{ .prompt = rate, .completion = rate },
            .context_length = 65536,
            .supported_parameters = &.{"tools"},
            .architecture = .{ .output_modalities = &.{"text"} },
        })));
    }
    const catalog: Catalog = .{ .models = models.items };
    try std.testing.expectEqualStrings("model/0", (try catalog.select(base, null, true)).model);
    try std.testing.expectEqualStrings("model/16", (try catalog.select(base, null, false)).model);
    base.mode = .free;
    try std.testing.expectEqualStrings("model/32", (try catalog.select(base, null, false)).model);
    const voice_cat = try Catalog.parse(try j.parse(a,
        \\{"data":[
        \\{"id":"expensive/audio","pricing":{"prompt":"0.00001","completion":"0.00002"},"architecture":{"input_modalities":["text","audio"],"output_modalities":["text"]}},
        \\{"id":"cheap/audio","pricing":{"prompt":"0.0000001","completion":"0.0000002"},"architecture":{"input_modalities":["text","audio"],"output_modalities":["text"]}}]}
    ));
    try std.testing.expectEqualStrings("cheap/audio", voice_cat.selectVoice(.cost_max, null).?);
}
