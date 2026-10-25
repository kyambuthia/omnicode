const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

/// Share one limiter across the parent agent, its children, and REPL turns.
pub const RequestLimiter = struct {
    mutex: Io.Mutex = .init,
    last_started: ?Io.Timestamp = null,

    /// Pace model request starts. The awake clock and sleep remain cancelable.
    pub fn wait(self: *RequestLimiter, io: Io, env: *const std.process.Environ.Map) !void {
        const rate = if (env.get("MAX_REQUESTS_PER_MINUTE")) |value|
            try config.parseMaxRequestsPerMinute(value)
        else
            config.default_max_requests_per_minute;
        if (rate == 0) return;
        const interval_ms: i64 = @intCast((60_000 + rate - 1) / rate);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.last_started) |last| {
            const elapsed = last.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
            if (elapsed < interval_ms) {
                try Io.sleep(io, Io.Duration.fromMilliseconds(interval_ms - @max(elapsed, 0)), .awake);
            }
        }
        self.last_started = Io.Clock.awake.now(io);
    }
};
