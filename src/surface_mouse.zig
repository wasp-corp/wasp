const SurfaceMouse = @This();
const std = @import("std");
const builtin = @import("builtin");
const input = @import("input.zig");
const terminal = @import("terminal/main.zig");
const MouseShape = terminal.MouseShape;
physical_key: input.Key,
mouse_event: terminal.MouseEvent,
mouse_shape: MouseShape,
mods: input.Mods,
over_link: bool,
hidden: bool,
pub fn keyToMouseShape(self: SurfaceMouse) ?MouseShape {
    if (!eligibleMouseShapeKeyEvent(self.physical_key)) return null;
    if (self.over_link or self.hidden) {
        return null;
    }
    switch (self.mouse_event != .none) {
        true => {
            if (isMouseModeOverrideState(self.mods) and isRectangleSelectState(self.mods)) {
                return .crosshair;
            } else if (isMouseModeOverrideState(self.mods)) {
                return .text;
            }
        },
        false => {
            if (isRectangleSelectState(self.mods)) {
                return .crosshair;
            } else if (isMouseModeOverrideState(self.mods)) {
                return .text;
            }
        },
    }
    return self.mouse_shape;
}
fn eligibleMouseShapeKeyEvent(physical_key: input.Key) bool {
    return physical_key.ctrlOrSuper() or
        physical_key.leftOrRightShift() or
        physical_key.leftOrRightAlt();
}
fn isMouseModeOverrideState(mods: input.Mods) bool {
    return mods.shift;
}
pub fn isRectangleSelectState(mods: input.Mods) bool {
    return if (comptime builtin.target.os.tag.isDarwin())
        mods.alt
    else
        mods.ctrlOrSuper() and mods.alt;
}
test "keyToMouseShape" {
    const testing = std.testing;
    {
        const m: SurfaceMouse = .{
            .physical_key = .unidentified,
            .mouse_event = .none,
            .mouse_shape = .progress,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };
        const got = m.keyToMouseShape();
        try testing.expect(got == null);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .none,
            .mouse_shape = .progress,
            .mods = .{},
            .over_link = true,
            .hidden = false,
        };
        const got = m.keyToMouseShape();
        try testing.expect(got == null);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .none,
            .mouse_shape = .progress,
            .mods = .{},
            .over_link = true,
            .hidden = true,
        };
        const got = m.keyToMouseShape();
        try testing.expect(got == null);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .x10,
            .mouse_shape = .default,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .default;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .default,
            .mods = .{ .ctrl = true, .super = true, .alt = true, .shift = true },
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .x10,
            .mouse_shape = .default,
            .mods = .{ .shift = true },
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .text;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .crosshair,
            .mods = .{ .shift = true },
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .text;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .crosshair,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .text,
            .mods = .{ .ctrl = true, .super = true, .alt = true, .shift = true },
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .none,
            .mouse_shape = .text,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .text;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .none,
            .mouse_shape = .text,
            .mods = .{ .ctrl = true, .super = true, .alt = true },
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
    {
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .none,
            .mouse_shape = .crosshair,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };
        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
}
