const std = @import("std");
const Io = std.Io;

// Race the entire operation, including waiting after its output pipes close.
pub fn run(io: Io, comptime function: anytype, args: anytype, milliseconds: i64) anyerror!@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Event = union(enum) { done: Result, timer: Io.Cancelable!void };
    var buffer: [2]Event = undefined;
    var select = Io.Select(Event).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.done, function, args);
    try select.concurrent(.timer, Io.sleep, .{ io, Io.Duration.fromMilliseconds(milliseconds), .awake });
    return switch (try select.await()) {
        .done => |result| result,
        .timer => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
    };
}
