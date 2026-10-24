pub const version = "0.2.0";
pub const Usage = @import("usage.zig").Usage;
pub const Input = @import("input.zig").Input;
pub const Details = @import("ui.zig").Details;
pub const Ui = @import("ui.zig").Ui;
pub const Agent = @import("agent.zig").Agent;
pub const Context = @import("tools.zig").Context;
pub const Todo = @import("tools.zig").Todo;
pub const Status = @import("status.zig").Status;
pub const Clock = @import("status.zig").Clock;
pub const shortenHome = @import("status.zig").shortenHome;
pub const terminalWidth = @import("status.zig").terminalWidth;
pub const Route = @import("router.zig").Route;
pub const Provider = @import("router.zig").Provider;
pub const ModelMenu = @import("catalog.zig").ModelMenu;
pub const config = @import("config.zig");
pub const voice = @import("voice.zig");
pub const Secrets = @import("secrets.zig").Secrets;

test {
    _ = @import("router.zig");
    _ = @import("catalog.zig");
    _ = @import("tools.zig");
    _ = @import("agent.zig");
    _ = @import("ui.zig");
    _ = @import("usage.zig");
    _ = @import("status.zig");
    _ = @import("input.zig");
    _ = @import("config.zig");
    _ = @import("voice.zig");
    _ = @import("secrets.zig");
}
