const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("lib.zig");
const compat_testing = @import("../lib/compat/testing.zig");
pub const Event = lib.Enum(lib.target, &.{
    "none",
    "x10",
    "normal",
    "button",
    "any",
});
pub fn eventSendsMotion(event: Event) bool {
    return event == .button or event == .any;
}
pub const Format = lib.Enum(lib.target, &.{
    "x10",
    "utf8",
    "sgr",
    "urxvt",
    "sgr_pixels",
});
pub const Shape = enum(c_int) {
    default,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    all_scroll,
    col_resize,
    row_resize,
    n_resize,
    e_resize,
    s_resize,
    w_resize,
    ne_resize,
    nw_resize,
    se_resize,
    sw_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    zoom_in,
    zoom_out,
    pub fn fromString(v: []const u8) ?Shape {
        return string_map.get(v);
    }
    pub const getGObjectType = gtk: {
        switch (build_options.artifact) {
            .wasp => {},
            .lib => break :gtk void,
        }
        break :gtk switch (@import("../build_config.zig").app_runtime) {
            .gtk => @import("gobject").ext.defineEnum(
                Shape,
                .{ .name = "WaspMouseShape" },
            ),
            .none => void,
        };
    };
    test "wasp.h MouseShape" {
        if (comptime build_options.artifact == .lib) return error.SkipZigTest;
        try lib.checkWaspHEnum(Shape, "WASP_MOUSE_SHAPE_");
    }
};
const string_map = std.StaticStringMap(Shape).initComptime(.{
    .{ "default", .default },
    .{ "context-menu", .context_menu },
    .{ "help", .help },
    .{ "pointer", .pointer },
    .{ "progress", .progress },
    .{ "wait", .wait },
    .{ "cell", .cell },
    .{ "crosshair", .crosshair },
    .{ "text", .text },
    .{ "vertical-text", .vertical_text },
    .{ "alias", .alias },
    .{ "copy", .copy },
    .{ "move", .move },
    .{ "no-drop", .no_drop },
    .{ "not-allowed", .not_allowed },
    .{ "grab", .grab },
    .{ "grabbing", .grabbing },
    .{ "all-scroll", .all_scroll },
    .{ "col-resize", .col_resize },
    .{ "row-resize", .row_resize },
    .{ "n-resize", .n_resize },
    .{ "e-resize", .e_resize },
    .{ "s-resize", .s_resize },
    .{ "w-resize", .w_resize },
    .{ "ne-resize", .ne_resize },
    .{ "nw-resize", .nw_resize },
    .{ "se-resize", .se_resize },
    .{ "sw-resize", .sw_resize },
    .{ "ew-resize", .ew_resize },
    .{ "ns-resize", .ns_resize },
    .{ "nesw-resize", .nesw_resize },
    .{ "nwse-resize", .nwse_resize },
    .{ "zoom-in", .zoom_in },
    .{ "zoom-out", .zoom_out },
    .{ "left_ptr", .default },
    .{ "question_arrow", .help },
    .{ "hand", .pointer },
    .{ "left_ptr_watch", .progress },
    .{ "watch", .wait },
    .{ "cross", .crosshair },
    .{ "xterm", .text },
    .{ "dnd-link", .alias },
    .{ "dnd-copy", .copy },
    .{ "dnd-move", .move },
    .{ "dnd-no-drop", .no_drop },
    .{ "crossed_circle", .not_allowed },
    .{ "hand1", .grab },
    .{ "right_side", .e_resize },
    .{ "top_side", .n_resize },
    .{ "top_right_corner", .ne_resize },
    .{ "top_left_corner", .nw_resize },
    .{ "bottom_side", .s_resize },
    .{ "bottom_right_corner", .se_resize },
    .{ "bottom_left_corner", .sw_resize },
    .{ "left_side", .w_resize },
    .{ "fleur", .all_scroll },
});
test "cursor shape from string" {
    const testing = std.testing;
    try testing.expectEqual(Shape.default, Shape.fromString("default").?);
}
test {
    _ = compat_testing.refAllDeclsRecursive(@This());
}
