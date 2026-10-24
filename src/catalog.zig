const std = @import("std");
const j = @import("json.zig");
const Route = @import("router.zig").Route;
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
