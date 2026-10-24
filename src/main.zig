const std = @import("std");
const core = @import("omnicode");

pub fn main(init: std.process.Init) !void {
    const route = try core.Route.init(init.environ_map, null, null);
    std.debug.print("omnicode | {s} | {s}\nAgent loop under construction.\n", .{ @tagName(route.provider), route.model });
}
