const std = @import("std");
const Io = std.Io;

// The handler only updates a lock-free byte. Normal I/O cancellation performs
// cleanup outside the signal handler, including command process-group cleanup.
var pending = std.atomic.Value(u8).init(0);

fn receive(sig: std.posix.SIG) callconv(.c) void {
    _ = pending.cmpxchgStrong(0, @intCast(@backingInt(sig)), .monotonic, .monotonic);
}

fn wait(io: Io) Io.Cancelable!u8 {
    while (true) {
        const sig = pending.load(.monotonic);
        if (sig != 0) return sig;
        try Io.sleep(io, Io.Duration.fromMilliseconds(25), .awake);
    }
}

/// Application entry point only: handlers are process-wide. Linux release
/// binaries translate SIGINT/SIGTERM into cancellation before exiting.
pub fn run(io: Io, comptime function: anytype, args: anytype) anyerror!@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
    if (@import("builtin").os.tag != .linux) return @call(.auto, function, args);
    pending.store(0, .monotonic);
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = receive },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_int);
    defer std.posix.sigaction(.INT, &old_int, null);
    std.posix.sigaction(.TERM, &action, &old_term);
    defer std.posix.sigaction(.TERM, &old_term, null);

    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Event = union(enum) { done: Result, signal: Io.Cancelable!u8 };
    var buffer: [2]Event = undefined;
    var select = Io.Select(Event).init(io, &buffer);
    // Wait for cancelled work to release resources before restoring handlers.
    defer select.cancelDiscard();
    try select.concurrent(.done, function, args);
    try select.concurrent(.signal, wait, .{io});
    return switch (try select.await()) {
        .done => |result| result,
        .signal => |result| if (try result == @backingInt(std.posix.SIG.INT)) error.Interrupted else error.Terminated,
    };
}
