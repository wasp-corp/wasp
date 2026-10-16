pub const options = @import("terminal_options");
pub const Active = @import("search/active.zig").ActiveSearch;
pub const PageList = @import("search/pagelist.zig").PageListSearch;
pub const Screen = @import("search/screen.zig").ScreenSearch;
pub const Terminal = @import("search/terminal.zig").TerminalSearch;
pub const Viewport = @import("search/viewport.zig").ViewportSearch;
pub const Thread = switch (options.artifact) {
    .wasp => @import("search/Thread.zig"),
    .lib => void,
};
test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("search/sliding_window.zig");
}
