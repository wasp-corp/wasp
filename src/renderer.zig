const build_config = @import("build_config.zig");
const cursor = @import("renderer/cursor.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const shadertoy = @import("renderer/shadertoy.zig");
pub const Backend = @import("renderer/backend.zig").Backend;
pub const GenericRenderer = @import("renderer/generic.zig").Renderer;
pub const Metal = @import("renderer/Metal.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const Options = @import("renderer/Options.zig");
pub const Overlay = @import("renderer/Overlay.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const CursorStyle = cursor.Style;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;
pub const lib = @import("lib/main.zig");
pub const Renderer = GenericRenderer(GraphicsAPI);
const GraphicsAPI = switch (build_config.renderer) {
    .metal => Metal,
    .opengl => OpenGL,
};
pub const Device = GraphicsAPI.Device;
pub const Health = enum(c_int) {
    healthy,
    unhealthy,
    test "wasp.h Health" {
        try lib.checkWaspHEnum(Health, "WASP_RENDERER_HEALTH_");
    }
};
test {
    _ = Renderer;
    _ = cursor;
    _ = message;
    _ = shadertoy;
    _ = size;
    _ = Thread;
    _ = State;
}
