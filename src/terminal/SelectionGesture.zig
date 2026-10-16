const SelectionGesture = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Selection = @import("Selection.zig");
const Terminal = @import("Terminal.zig");
const point = @import("point.zig");
const freestanding_wasm = builtin.target.cpu.arch == .wasm32 and
    builtin.target.os.tag == .freestanding;
left_click_pin: ?*Pin,
left_click_screen: ScreenSet.Key,
left_click_screen_generation: usize,
left_click_count: u3,
left_click_time: ?std.Io.Timestamp,
left_click_behavior: Behavior,
left_click_xpos: f64,
left_click_ypos: f64,
left_click_dragged: bool,
left_drag_autoscroll: Autoscroll,
pub const Autoscroll = lib.Enum(lib.target, &.{
    "none",
    "up",
    "down",
});
pub const Behavior = lib.Enum(lib.target, &.{
    "cell",
    "word",
    "line",
    "output",
});
pub const default_behaviors: [3]Behavior = .{ .cell, .word, .line };
const autoscroll_buffer: f64 = 1;
pub const init: SelectionGesture = .{
    .left_click_pin = null,
    .left_click_count = 0,
    .left_click_time = null,
    .left_click_behavior = .cell,
    .left_click_screen = .primary,
    .left_click_screen_generation = 0,
    .left_click_xpos = 0,
    .left_click_ypos = 0,
    .left_click_dragged = false,
    .left_drag_autoscroll = .none,
};
pub fn deinit(self: *SelectionGesture, t: *Terminal) void {
    const pin = self.left_click_pin orelse return;
    if (t.screens.generation(self.left_click_screen) != self.left_click_screen_generation) return;
    const screen = t.screens.get(self.left_click_screen) orelse return;
    screen.pages.untrackPin(pin);
}
pub fn reset(self: *SelectionGesture, t: *Terminal) void {
    self.left_click_count = 0;
    self.left_click_time = null;
    self.left_click_behavior = .cell;
    self.left_click_dragged = false;
    self.left_drag_autoscroll = .none;
    self.untrackPin(t);
}
pub fn validatedLeftClickPin(
    self: *const SelectionGesture,
    screens: *const ScreenSet,
) ?*Pin {
    const pin = self.left_click_pin orelse return null;
    if (self.left_click_screen != screens.active_key) return null;
    if (screens.generation(self.left_click_screen) != self.left_click_screen_generation) return null;
    _ = screens.get(self.left_click_screen) orelse return null;
    return pin;
}
pub const Press = struct {
    time: ?std.Io.Timestamp,
    pin: Pin,
    xpos: f64,
    ypos: f64,
    max_distance: f64,
    repeat_interval: u64,
    word_boundary_codepoints: []const u21,
    behaviors: *const [3]Behavior = &default_behaviors,
};
pub fn press(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) Allocator.Error!?Selection {
    if (self.left_click_count > 0) {
        if (self.pressRepeat(t, p)) {
            return self.pressSelection(t.screens.active, p);
        } else |err| switch (err) {
            error.PressRequiresReset => {},
        }
    }
    try self.pressInitial(t, p);
    return self.pressSelection(t.screens.active, p);
}
pub const Drag = struct {
    pin: Pin,
    xpos: f64,
    ypos: f64,
    rectangle: bool,
    word_boundary_codepoints: []const u21,
    geometry: Geometry,
    pub const Geometry = struct {
        columns: u32,
        cell_width: u32,
        padding_left: u32,
        screen_height: u32,
    };
};
pub fn drag(
    self: *SelectionGesture,
    t: *Terminal,
    d: Drag,
) ?Selection {
    if (self.left_click_count == 0) {
        assert(self.left_drag_autoscroll == .none);
        return null;
    }
    const click_pin = self.validatedLeftClickPin(&t.screens) orelse return null;
    if (!d.pin.eql(click_pin.*)) self.left_click_dragged = true;
    const max_y: f64 = @floatFromInt(d.geometry.screen_height);
    self.left_drag_autoscroll = if (d.ypos <= autoscroll_buffer)
        .up
    else if (d.ypos > max_y - autoscroll_buffer)
        .down
    else
        .none;
    const selection = switch (self.left_click_behavior) {
        .cell => dragSelection(
            click_pin.*,
            d.pin,
            pixelFromFloat(self.left_click_xpos),
            pixelFromFloat(d.xpos),
            d.rectangle,
            d.geometry,
        ),
        .word => dragSelectionWord(
            t.screens.active,
            click_pin.*,
            d.pin,
            d.word_boundary_codepoints,
        ),
        .line => dragSelectionLine(
            t.screens.active,
            click_pin.*,
            d.pin,
        ),
        .output => dragSelectionOutput(
            t.screens.active,
            click_pin.*,
            d.pin,
        ),
    };
    if (self.left_click_behavior == .cell and selection != null) {
        self.left_click_dragged = true;
    }
    return selection;
}
pub const AutoscrollTick = struct {
    viewport: point.Coordinate,
    xpos: f64,
    ypos: f64,
    rectangle: bool,
    word_boundary_codepoints: []const u21,
    geometry: Drag.Geometry,
};
pub fn autoscrollTick(
    self: *SelectionGesture,
    t: *Terminal,
    tick: AutoscrollTick,
) ?Selection {
    if (self.left_click_count == 0) {
        assert(self.left_drag_autoscroll == .none);
        return null;
    }
    const delta: isize = switch (self.left_drag_autoscroll) {
        .none => return null,
        .up => -1,
        .down => 1,
    };
    _ = self.validatedLeftClickPin(&t.screens) orelse {
        self.reset(t);
        return null;
    };
    t.scrollViewport(.{ .delta = delta });
    const pin = t.screens.active.pages.pin(.{ .viewport = tick.viewport }) orelse return null;
    return self.drag(t, .{
        .pin = pin,
        .xpos = tick.xpos,
        .ypos = tick.ypos,
        .rectangle = tick.rectangle,
        .word_boundary_codepoints = tick.word_boundary_codepoints,
        .geometry = tick.geometry,
    });
}
pub const DeepPress = struct {
    word_boundary_codepoints: []const u21,
};
pub fn deepPress(
    self: *SelectionGesture,
    t: *Terminal,
    p: DeepPress,
) ?Selection {
    const click_pin = self.validatedLeftClickPin(&t.screens) orelse return null;
    const sel = t.screens.active.selectWord(
        click_pin.*,
        p.word_boundary_codepoints,
    );
    self.left_click_count = 0;
    self.left_click_time = null;
    self.left_click_behavior = .cell;
    self.left_click_dragged = true;
    self.left_drag_autoscroll = .none;
    self.untrackPin(t);
    return sel;
}
pub const Release = struct {
    pin: ?Pin,
};
pub fn release(
    self: *SelectionGesture,
    t: *Terminal,
    r: Release,
) void {
    if (self.left_click_count == 0) {
        assert(self.left_drag_autoscroll == .none);
        return;
    }
    if (r.pin) |release_pin| {
        if (self.validatedLeftClickPin(&t.screens)) |click_pin| {
            if (!release_pin.eql(click_pin.*)) self.left_click_dragged = true;
        } else {
            self.left_click_dragged = true;
        }
    } else {
        self.left_click_dragged = true;
    }
    self.left_drag_autoscroll = .none;
}
fn pressInitial(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) Allocator.Error!void {
    if (self.left_click_pin) |pin| {
        if (comptime std.debug.runtime_safety) {
            assert(self.left_click_screen == t.screens.active_key);
            assert(self.left_click_screen_generation == t.screens.generation(t.screens.active_key));
        }
        pin.* = p.pin;
    } else {
        const screens: *const ScreenSet = &t.screens;
        self.left_click_pin = try screens.active.pages.trackPin(p.pin);
        errdefer comptime unreachable;
        self.left_click_screen = screens.active_key;
        self.left_click_screen_generation = screens.generation(screens.active_key);
    }
    errdefer comptime unreachable;
    self.left_click_count = 1;
    self.left_click_behavior = p.behaviors[0];
    self.left_click_xpos = p.xpos;
    self.left_click_ypos = p.ypos;
    self.left_click_time = p.time;
    self.left_click_dragged = false;
    self.left_drag_autoscroll = .none;
}
fn pressRepeat(
    self: *SelectionGesture,
    t: *Terminal,
    p: Press,
) error{PressRequiresReset}!void {
    errdefer {
        self.left_click_count = 0;
        self.left_click_behavior = .cell;
        self.untrackPin(t);
    }
    const time = p.time orelse return error.PressRequiresReset;
    {
        const prev_time = self.left_click_time orelse return error.PressRequiresReset;
        const since = timeSince(time, prev_time) orelse
            return error.PressRequiresReset;
        if (since > p.repeat_interval) return error.PressRequiresReset;
    }
    const distance = @sqrt(
        std.math.pow(f64, p.xpos - self.left_click_xpos, 2) +
            std.math.pow(f64, p.ypos - self.left_click_ypos, 2),
    );
    if (distance > p.max_distance) return error.PressRequiresReset;
    const screens: *const ScreenSet = &t.screens;
    if (self.left_click_screen != screens.active_key or
        screens.generation(self.left_click_screen) !=
            self.left_click_screen_generation)
    {
        return error.PressRequiresReset;
    }
    self.left_click_time = time;
    self.left_click_dragged = false;
    self.left_drag_autoscroll = .none;
    self.left_click_count = @min(
        self.left_click_count + 1,
        3, 
    );
    self.left_click_behavior = p.behaviors[self.left_click_count - 1];
}
fn timeSince(time: std.Io.Timestamp, prev_time: std.Io.Timestamp) ?u64 {
    const delta = prev_time.durationTo(time).toNanoseconds();
    if (delta < 0) return null;
    return @as(u64, @intCast(@min(delta, std.math.maxInt(u64))));
}
fn pixelFromFloat(value: f64) u32 {
    if (std.math.isNan(value) or value <= 0) return 0;
    const max: f64 = @floatFromInt(std.math.maxInt(u32));
    if (value >= max) return std.math.maxInt(u32);
    return @intFromFloat(value);
}
fn pressSelection(
    self: *const SelectionGesture,
    screen: *Screen,
    p: Press,
) ?Selection {
    return switch (self.left_click_behavior) {
        .cell => null,
        .word => screen.selectWord(p.pin, p.word_boundary_codepoints),
        .line => screen.selectLine(.{ .pin = p.pin }),
        .output => screen.selectOutput(p.pin),
    };
}
fn dragSelection(
    click_pin: Pin,
    drag_pin: Pin,
    click_x: u32,
    drag_x: u32,
    rectangle_selection: bool,
    geometry: Drag.Geometry,
) ?Selection {
    if (geometry.columns == 0 or geometry.cell_width == 0) return null;
    const threshold_point: u32 = @intFromFloat(@round(
        @as(f64, @floatFromInt(geometry.cell_width)) * 0.6,
    ));
    const pixel_span = std.math.mul(
        u32,
        geometry.columns,
        geometry.cell_width,
    ) catch std.math.maxInt(u32);
    const max_x = pixel_span - 1;
    const drag_x_frac = @min(max_x, drag_x -| geometry.padding_left) % geometry.cell_width;
    const click_x_frac = @min(max_x, click_x -| geometry.padding_left) % geometry.cell_width;
    const same_pin = drag_pin.eql(click_pin);
    const end_before_start = ebs: {
        if (same_pin) {
            break :ebs drag_x_frac < click_x_frac;
        }
        if (rectangle_selection) {
            break :ebs switch (std.math.order(drag_pin.x, click_pin.x)) {
                .eq => drag_x_frac < click_x_frac,
                .lt => true,
                .gt => false,
            };
        }
        break :ebs drag_pin.before(click_pin);
    };
    const include_click_cell = if (end_before_start)
        click_x_frac >= threshold_point
    else
        click_x_frac < threshold_point;
    const include_drag_cell = if (end_before_start)
        drag_x_frac < threshold_point
    else
        drag_x_frac >= threshold_point;
    const start_pin =
        if (include_click_cell)
            click_pin
        else if (end_before_start)
            if (rectangle_selection)
                click_pin.leftClamp(1)
            else
                click_pin.leftWrap(1) orelse click_pin
        else if (rectangle_selection)
            click_pin.rightClamp(1)
        else
            click_pin.rightWrap(1) orelse click_pin;
    const end_pin =
        if (include_drag_cell)
            drag_pin
        else if (end_before_start)
            if (rectangle_selection)
                drag_pin.rightClamp(1)
            else
                drag_pin.rightWrap(1) orelse drag_pin
        else if (rectangle_selection)
            drag_pin.leftClamp(1)
        else
            drag_pin.leftWrap(1) orelse drag_pin;
    if ((!include_click_cell and same_pin) or
        (!include_click_cell and rectangle_selection and click_pin.x == drag_pin.x) or
        (!include_click_cell and end_pin.eql(click_pin)) or
        (!include_click_cell and rectangle_selection and end_pin.x == click_pin.x) or
        (!include_drag_cell and start_pin.eql(drag_pin)) or
        (!include_drag_cell and rectangle_selection and start_pin.x == drag_pin.x))
    {
        return null;
    }
    return .init(
        start_pin,
        end_pin,
        rectangle_selection,
    );
}
fn dragSelectionWord(
    screen: *Screen,
    click_pin: Pin,
    drag_pin: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    const word_start = screen.selectWordBetween(
        click_pin,
        drag_pin,
        boundary_codepoints,
    ) orelse return null;
    const word_current = screen.selectWordBetween(
        drag_pin,
        click_pin,
        boundary_codepoints,
    ) orelse return null;
    return if (drag_pin.before(click_pin))
        .init(
            word_current.start(),
            word_start.end(),
            false,
        )
    else
        .init(
            word_start.start(),
            word_current.end(),
            false,
        );
}
fn dragSelectionLine(
    screen: *Screen,
    click_pin: Pin,
    drag_pin: Pin,
) ?Selection {
    const line = screen.selectLine(.{ .pin = drag_pin }) orelse return null;
    const sel_ = screen.selectLine(.{ .pin = click_pin }) orelse
        screen.selectLine(.{ .pin = click_pin, .whitespace = null });
    var sel = sel_ orelse return null;
    if (drag_pin.before(click_pin)) {
        sel.startPtr().* = line.start();
    } else {
        sel.endPtr().* = line.end();
    }
    return sel;
}
fn dragSelectionOutput(
    screen: *Screen,
    click_pin: Pin,
    drag_pin: Pin,
) ?Selection {
    var sel = screen.selectOutput(click_pin) orelse return null;
    const current = screen.selectOutput(drag_pin) orelse return sel;
    if (drag_pin.before(click_pin)) {
        sel.startPtr().* = current.start();
    } else {
        sel.endPtr().* = current.end();
    }
    return sel;
}
fn untrackPin(self: *SelectionGesture, t: *Terminal) void {
    const pin = self.left_click_pin orelse return;
    self.left_click_pin = null;
    const screens: *const ScreenSet = &t.screens;
    if (screens.generation(self.left_click_screen) != self.left_click_screen_generation) return;
    const screen = screens.get(self.left_click_screen) orelse return;
    screen.pages.untrackPin(pin);
}
fn testPress(t: *Terminal, x: u16, y: u32, time: ?std.Io.Timestamp) Press {
    return .{
        .time = time,
        .pin = t.screens.active.pages.pin(.{ .active = .{
            .x = x,
            .y = y,
        } }).?,
        .xpos = @floatFromInt(x),
        .ypos = @floatFromInt(y),
        .max_distance = 1,
        .repeat_interval = std.math.maxInt(u64),
        .word_boundary_codepoints = &.{},
    };
}
fn testDrag(t: *Terminal, x: u16, y: u32, xpos: f64, ypos: f64) Drag {
    return .{
        .pin = t.screens.active.pages.pin(.{ .active = .{
            .x = x,
            .y = y,
        } }).?,
        .xpos = xpos,
        .ypos = ypos,
        .rectangle = false,
        .word_boundary_codepoints = &.{},
        .geometry = .{
            .columns = 5,
            .cell_width = 10,
            .padding_left = 0,
            .screen_height = 100,
        },
    };
}
fn testAutoscrollTick(
    viewport: point.Coordinate,
    xpos: f64,
    ypos: f64,
) AutoscrollTick {
    return .{
        .viewport = viewport,
        .xpos = xpos,
        .ypos = ypos,
        .rectangle = false,
        .word_boundary_codepoints = &.{},
        .geometry = .{
            .columns = 5,
            .cell_width = 10,
            .padding_left = 0,
            .screen_height = 100,
        },
    };
}
fn testPin(t: *Terminal, x: u16, y: u32) Pin {
    return t.screens.active.pages.pin(.{ .active = .{
        .x = x,
        .y = y,
    } }).?;
}
fn testDragSelection(
    click_x: f64,
    click_y: u32,
    drag_x: f64,
    drag_y: u32,
    start_x: u16,
    start_y: u32,
    end_x: u16,
    end_y: u32,
    rect: bool,
) !void {
    assert(@import("builtin").is_test);
    const geometry: Drag.Geometry = .{
        .columns = 10,
        .cell_width = 10,
        .padding_left = 5,
        .screen_height = 110,
    };
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    const click_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(click_x)), .y = click_y },
    }) orelse unreachable;
    const drag_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(drag_x)), .y = drag_y },
    }) orelse unreachable;
    const cell_width_f64: f64 = @floatFromInt(geometry.cell_width);
    const click_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(click_x * cell_width_f64))) +
        geometry.padding_left;
    const drag_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(drag_x * cell_width_f64))) +
        geometry.padding_left;
    const start_pin = screen.pages.pin(.{
        .viewport = .{ .x = start_x, .y = start_y },
    }) orelse unreachable;
    const end_pin = screen.pages.pin(.{
        .viewport = .{ .x = end_x, .y = end_y },
    }) orelse unreachable;
    try testing.expectEqualDeep(Selection{
        .bounds = .{ .untracked = .{
            .start = start_pin,
            .end = end_pin,
        } },
        .rectangle = rect,
    }, dragSelection(
        click_pin,
        drag_pin,
        click_x_pos,
        drag_x_pos,
        rect,
        geometry,
    ));
}
fn testDragSelectionIsNull(
    click_x: f64,
    click_y: u32,
    drag_x: f64,
    drag_y: u32,
    rect: bool,
) !void {
    assert(@import("builtin").is_test);
    const geometry: Drag.Geometry = .{
        .columns = 10,
        .cell_width = 10,
        .padding_left = 5,
        .screen_height = 110,
    };
    var screen = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer screen.deinit();
    const click_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(click_x)), .y = click_y },
    }) orelse unreachable;
    const drag_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(drag_x)), .y = drag_y },
    }) orelse unreachable;
    const cell_width_f64: f64 = @floatFromInt(geometry.cell_width);
    const click_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(click_x * cell_width_f64))) +
        geometry.padding_left;
    const drag_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(drag_x * cell_width_f64))) +
        geometry.padding_left;
    try testing.expectEqual(
        null,
        dragSelection(
            click_pin,
            drag_pin,
            click_x_pos,
            drag_x_pos,
            rect,
            geometry,
        ),
    );
}
test "SelectionGesture drag selection logic" {
    try testDragSelection(
        3.0, 3, 
        3.9, 3, 
        3, 3, 
        3, 3, 
        false, 
    );
    try testDragSelection(
        3.0, 3, 
        5.9, 3, 
        3, 3, 
        5, 3, 
        false, 
    );
    try testDragSelection(
        3.0, 3, 
        5.0, 3, 
        3, 3, 
        4, 3, 
        false, 
    );
    try testDragSelection(
        3.9, 3, 
        5.9, 3, 
        4, 3, 
        5, 3, 
        false, 
    );
    try testDragSelection(
        3.9, 3, 
        5.0, 3, 
        4, 3, 
        4, 3, 
        false, 
    );
    try testDragSelectionIsNull(
        3.0, 3, 
        3.1, 3, 
        false, 
    );
    try testDragSelectionIsNull(
        3.8, 3, 
        3.9, 3, 
        false, 
    );
    try testDragSelectionIsNull(
        3.9, 3, 
        4.0, 3, 
        false, 
    );
    try testDragSelection(
        3.9, 3, 
        3.0, 3, 
        3, 3, 
        3, 3, 
        false, 
    );
    try testDragSelection(
        5.9, 3, 
        3.0, 3, 
        5, 3, 
        3, 3, 
        false, 
    );
    try testDragSelection(
        5.9, 3, 
        3.9, 3, 
        5, 3, 
        4, 3, 
        false, 
    );
    try testDragSelection(
        5.0, 3, 
        3.0, 3, 
        4, 3, 
        3, 3, 
        false, 
    );
    try testDragSelection(
        5.0, 3, 
        3.9, 3, 
        4, 3, 
        4, 3, 
        false, 
    );
    try testDragSelectionIsNull(
        3.1, 3, 
        3.0, 3, 
        false, 
    );
    try testDragSelectionIsNull(
        3.9, 3, 
        3.8, 3, 
        false, 
    );
    try testDragSelectionIsNull(
        4.0, 3, 
        3.9, 3, 
        false, 
    );
    try testDragSelection(
        9.9, 2, 
        0.0, 4, 
        0, 3, 
        9, 3, 
        false, 
    );
    try testDragSelection(
        0.0, 4, 
        9.9, 2, 
        9, 3, 
        0, 3, 
        false, 
    );
}
test "SelectionGesture rectangle drag selection logic" {
    try testDragSelection(
        3.0, 2, 
        3.9, 4, 
        3, 2, 
        3, 4, 
        true, 
    );
    try testDragSelection(
        3.0, 2, 
        5.9, 4, 
        3, 2, 
        5, 4, 
        true, 
    );
    try testDragSelection(
        3.0, 2, 
        5.0, 4, 
        3, 2, 
        4, 4, 
        true, 
    );
    try testDragSelection(
        3.9, 2, 
        5.9, 4, 
        4, 2, 
        5, 4, 
        true, 
    );
    try testDragSelection(
        3.9, 2, 
        5.0, 4, 
        4, 2, 
        4, 4, 
        true, 
    );
    try testDragSelectionIsNull(
        3.0, 2, 
        3.1, 4, 
        true, 
    );
    try testDragSelectionIsNull(
        3.8, 2, 
        3.9, 4, 
        true, 
    );
    try testDragSelectionIsNull(
        3.9, 2, 
        4.0, 4, 
        true, 
    );
    try testDragSelection(
        3.9, 2, 
        3.0, 4, 
        3, 2, 
        3, 4, 
        true, 
    );
    try testDragSelection(
        5.9, 2, 
        3.0, 4, 
        5, 2, 
        3, 4, 
        true, 
    );
    try testDragSelection(
        5.9, 2, 
        3.9, 4, 
        5, 2, 
        4, 4, 
        true, 
    );
    try testDragSelection(
        5.0, 2, 
        3.0, 4, 
        4, 2, 
        3, 4, 
        true, 
    );
    try testDragSelection(
        5.0, 2, 
        3.9, 4, 
        4, 2, 
        4, 4, 
        true, 
    );
    try testDragSelectionIsNull(
        3.1, 2, 
        3.0, 4, 
        true, 
    );
    try testDragSelectionIsNull(
        3.9, 2, 
        3.8, 4, 
        true, 
    );
    try testDragSelectionIsNull(
        4.0, 2, 
        3.9, 4, 
        true, 
    );
    try testDragSelection(
        9.9, 2, 
        0.0, 4, 
        9, 2, 
        0, 4, 
        true, 
    );
    try testDragSelection(
        0.0, 4, 
        9.9, 2, 
        0, 4, 
        9, 2, 
        true, 
    );
}
test "SelectionGesture press records initial click" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 1, 2, time));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(time, gesture.left_click_time.?);
    try testing.expectEqual(@as(f64, 1), gesture.left_click_xpos);
    try testing.expectEqual(@as(f64, 2), gesture.left_click_ypos);
    try testing.expectEqual(false, gesture.left_click_dragged);
}
test "SelectionGesture press returns standard click selections" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta\none two");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    var event = testPress(&t, 1, 0, time);
    event.word_boundary_codepoints = &.{ ' ' };
    try testing.expectEqual(null, try gesture.press(&t, event));
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 4, 0),
        false,
    ), (try gesture.press(&t, event)).?);
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), (try gesture.press(&t, event)).?);
}
test "SelectionGesture press behaviors choose press and drag behavior" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta\none two\nthree four");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    var event = testPress(&t, 1, 0, time);
    event.behaviors = &.{ .cell, .line, .word };
    event.word_boundary_codepoints = &.{ ' ' };
    _ = try gesture.press(&t, event);
    try testing.expectEqual(.cell, gesture.left_click_behavior);
    const double_click = (try gesture.press(&t, event)).?;
    try testing.expectEqual(.line, gesture.left_click_behavior);
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), double_click);
    const line_drag = gesture.drag(&t, testDrag(&t, 2, 2, 20, 50)).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 2),
        false,
    ), line_drag);
}
test "SelectionGesture output behavior selects and drags semantic output" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 6 });
    defer t.deinit(testing.allocator);
    const screen = t.screens.active;
    screen.cursorSetSemanticContent(.output);
    try screen.testWriteString("out1\n");
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("$ ");
    screen.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try screen.testWriteString("cmd\n");
    screen.cursorSetSemanticContent(.output);
    try screen.testWriteString("out2");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var event = testPress(&t, 1, 0, std.Io.Timestamp.now(testing.io, .awake));
    event.behaviors = &.{ .output, .word, .line };
    const press_selection = (try gesture.press(&t, event)).?;
    try testing.expectEqual(.output, gesture.left_click_behavior);
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 3, 0),
        false,
    ), press_selection);
    const output_drag = gesture.drag(&t, testDrag(&t, 1, 2, 10, 50)).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 3, 2),
        false,
    ), output_drag);
}
test "SelectionGesture drag returns selection and records autoscroll" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    const sel = gesture.drag(&t, testDrag(&t, 3, 1, 39, 50)).?;
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expectEqual(true, gesture.left_click_dragged);
    try testing.expectEqualDeep(Selection.init(
        t.screens.active.pages.pin(.{ .active = .{ .x = 1, .y = 1 } }).?,
        t.screens.active.pages.pin(.{ .active = .{ .x = 3, .y = 1 } }).?,
        false,
    ), sel);
    _ = gesture.drag(&t, testDrag(&t, 3, 1, 39, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    _ = gesture.drag(&t, testDrag(&t, 3, 1, 39, 100));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
}
test "SelectionGesture drag clamps unrepresentable positions" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    const positive = gesture.drag(
        &t,
        testDrag(&t, 1, 1, std.math.inf(f64), 50),
    ).?;
    try testing.expect((testPin(&t, 1, 1)).eql(positive.start()));
    try testing.expect((testPin(&t, 1, 1)).eql(positive.end()));
    try testing.expectEqual(null, gesture.drag(
        &t,
        testDrag(&t, 1, 1, std.math.nan(f64), 50),
    ));
}
test "SelectionGesture drag saturates overflowing geometry" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    var drag_event = testDrag(&t, 1, 1, 10, 50);
    drag_event.geometry.columns = std.math.maxInt(u32);
    drag_event.geometry.cell_width = std.math.maxInt(u32);
    try testing.expectEqual(null, gesture.drag(&t, drag_event));
}
test "SelectionGesture drag rejects empty geometry" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    var drag_event = testDrag(&t, 1, 1, 10, 50);
    drag_event.geometry.columns = 0;
    drag_event.geometry.cell_width = 0;
    try testing.expectEqual(null, gesture.drag(&t, drag_event));
}
test "SelectionGesture release clears autoscroll and records drag" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    try testing.expectEqual(false, gesture.left_click_dragged);
    _ = gesture.drag(&t, testDrag(&t, 1, 1, 10, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    try testing.expectEqual(false, gesture.left_click_dragged);
    gesture.release(&t, .{
        .pin = testPin(&t, 2, 1),
    });
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expectEqual(true, gesture.left_click_dragged);
}
test "SelectionGesture release with invalidated click records drag" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    try testing.expectEqual(false, gesture.left_click_dragged);
    _ = try t.screens.getInit(testing.io, testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    gesture.release(&t, .{ .pin = testPin(&t, 1, 1) });
    try testing.expectEqual(true, gesture.left_click_dragged);
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
}
test "SelectionGesture same-cell threshold selection records drag" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    try testing.expectEqual(false, gesture.left_click_dragged);
    const sel = gesture.drag(&t, testDrag(&t, 1, 1, 19, 50)).?;
    try testing.expectEqual(true, gesture.left_click_dragged);
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 1, 1),
        testPin(&t, 1, 1),
        false,
    ), sel);
}
test "SelectionGesture drag without press returns null" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    try testing.expectEqual(null, gesture.drag(&t, testDrag(&t, 1, 1, 10, 50)));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
}
test "SelectionGesture drag autoscroll edge boundaries" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1.1));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 99));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 99.1));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
}
test "SelectionGesture autoscroll tick scrolls and continues drag" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    _ = gesture.drag(&t, testDrag(&t, 3, 1, 39, 100));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
    const sel = gesture.autoscrollTick(&t, testAutoscrollTick(.{ .x = 3, .y = 2 }, 39, 100)).?;
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
    try testing.expectEqual(true, gesture.left_click_dragged);
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 1, 1),
        testPin(&t, 3, 2),
        false,
    ), sel);
}
test "SelectionGesture autoscroll tick resolves drag pin after scrolling" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer t.deinit(testing.allocator);
    try t.printString("1111\n2222\n3333\n4444\n5555");
    t.scrollViewport(.{ .delta = -2 });
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    _ = gesture.drag(&t, testDrag(&t, 3, 2, 39, 100));
    try testing.expectEqual(.down, gesture.left_drag_autoscroll);
    const viewport: point.Coordinate = .{ .x = 3, .y = 2 };
    const pre_scroll_pin = t.screens.active.pages.pin(.{ .viewport = viewport }).?;
    const sel = gesture.autoscrollTick(&t, testAutoscrollTick(viewport, 39, 100)).?;
    const post_scroll_pin = t.screens.active.pages.pin(.{ .viewport = viewport }).?;
    try testing.expect(!pre_scroll_pin.eql(post_scroll_pin));
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 1, 1),
        post_scroll_pin,
        false,
    ), sel);
}
test "SelectionGesture autoscroll tick stops with invalidated click" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    _ = try t.screens.getInit(testing.io, testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    try testing.expectEqual(null, gesture.autoscrollTick(&t, testAutoscrollTick(.{ .x = 2, .y = 1 }, 20, 1)));
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expectEqual(@as(u3, 0), gesture.left_click_count);
}
test "SelectionGesture deep press selects word and consumes drag" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 0, std.Io.Timestamp.now(testing.io, .awake)));
    _ = gesture.drag(&t, testDrag(&t, 1, 0, 10, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    const sel = gesture.deepPress(&t, .{
        .word_boundary_codepoints = &.{ ' ' },
    }).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 4, 0),
        false,
    ), sel);
    try testing.expectEqual(@as(u3, 0), gesture.left_click_count);
    try testing.expectEqual(@as(?std.Io.Timestamp, null), gesture.left_click_time);
    try testing.expectEqual(true, gesture.left_click_dragged);
    try testing.expectEqual(.none, gesture.left_drag_autoscroll);
    try testing.expect(gesture.left_click_pin == null);
    try testing.expectEqual(null, gesture.drag(&t, testDrag(&t, 7, 0, 70, 50)));
    gesture.release(&t, .{ .pin = testPin(&t, 7, 0) });
    try testing.expectEqual(true, gesture.left_click_dragged);
}
test "SelectionGesture drag with invalidated click returns null" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var press_event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    press_event.xpos = 10;
    _ = try gesture.press(&t, press_event);
    _ = gesture.drag(&t, testDrag(&t, 2, 1, 20, 1));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
    _ = try t.screens.getInit(testing.io, testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    try testing.expectEqual(null, gesture.drag(&t, testDrag(&t, 2, 1, 20, 50)));
    try testing.expectEqual(.up, gesture.left_drag_autoscroll);
}
test "SelectionGesture double-click drag selects by word" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta gamma");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    var drag_event = testDrag(&t, 7, 0, 70, 50);
    drag_event.word_boundary_codepoints = &.{ ' ' };
    const sel = gesture.drag(&t, drag_event).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), sel);
}
test "SelectionGesture double-click drag selects by word backwards" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta gamma");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 7, 0, time));
    _ = try gesture.press(&t, testPress(&t, 7, 0, time));
    var drag_event = testDrag(&t, 1, 0, 10, 50);
    drag_event.word_boundary_codepoints = &.{ ' ' };
    const sel = gesture.drag(&t, drag_event).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), sel);
}
test "SelectionGesture double-click drag on empty cell selects nearest word" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    var drag_event = testDrag(&t, 15, 0, 150, 50);
    drag_event.word_boundary_codepoints = &.{ ' ' };
    const sel = gesture.drag(&t, drag_event).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 0),
        false,
    ), sel);
}
test "SelectionGesture triple-click drag selects by line" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta\none two\nthree four");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    _ = try gesture.press(&t, testPress(&t, 1, 0, time));
    const sel = gesture.drag(&t, testDrag(&t, 2, 2, 20, 50)).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 2),
        false,
    ), sel);
}
test "SelectionGesture triple-click drag selects by line backwards" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("alpha beta\none two\nthree four");
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 2, 2, time));
    _ = try gesture.press(&t, testPress(&t, 2, 2, time));
    _ = try gesture.press(&t, testPress(&t, 2, 2, time));
    const sel = gesture.drag(&t, testDrag(&t, 1, 0, 10, 50)).?;
    try testing.expectEqualDeep(Selection.init(
        testPin(&t, 0, 0),
        testPin(&t, 9, 2),
        false,
    ), sel);
}
test "SelectionGesture repeat increments click count" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 1, 1, time));
    _ = try gesture.press(&t, testPress(&t, 1, 1, time));
    try testing.expectEqual(@as(u3, 2), gesture.left_click_count);
}
test "SelectionGesture repeat clamps at triple click" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    for (0..4) |_| _ = try gesture.press(&t, testPress(&t, 1, 1, time));
    try testing.expectEqual(@as(u3, 3), gesture.left_click_count);
}
test "SelectionGesture null initial time stays single click" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 1, null));
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expect(gesture.left_click_time != null);
}
test "SelectionGesture null repeat time stays single click" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    _ = try gesture.press(&t, testPress(&t, 1, 1, null));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(@as(?std.Io.Timestamp, null), gesture.left_click_time);
}
test "SelectionGesture distant press resets click count" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, testPress(&t, 1, 1, time));
    _ = try gesture.press(&t, testPress(&t, 4, 1, time));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(@as(f64, 4), gesture.left_click_xpos);
}
test "SelectionGesture expired repeat resets click count" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    var event = testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake));
    event.repeat_interval = 0;
    _ = try gesture.press(&t, event);
    try std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    event.time = std.Io.Timestamp.now(testing.io, .awake);
    _ = try gesture.press(&t, event);
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
}
test "SelectionGesture backwards repeat time resets click count" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const now: std.Io.Timestamp = .now(testing.io, .awake);
    const earlier = now.addDuration(.fromSeconds(1));
    const later = now.addDuration(.fromSeconds(2));
    _ = try gesture.press(&t, testPress(&t, 1, 1, later));
    _ = try gesture.press(&t, testPress(&t, 1, 1, earlier));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqualDeep(earlier, gesture.left_click_time.?);
}
test "SelectionGesture screen switch resets click count" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    const time = std.Io.Timestamp.now(testing.io, .awake);
    const primary_tracked = t.screens.active.pages.countTrackedPins();
    _ = try gesture.press(&t, testPress(&t, 1, 1, time));
    _ = try t.screens.getInit(testing.io, testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    _ = try gesture.press(&t, testPress(&t, 1, 1, time));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(.alternate, gesture.left_click_screen);
    try testing.expectEqual(primary_tracked, t.screens.get(.primary).?.pages.countTrackedPins());
}
test "SelectionGesture removed screen resets without untracking stale pin" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    defer gesture.deinit(&t);
    _ = try t.screens.getInit(testing.io, testing.allocator, .alternate, .{
        .cols = t.cols,
        .rows = t.rows,
    });
    t.screens.switchTo(.alternate);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    t.screens.switchTo(.primary);
    t.screens.remove(testing.allocator, .alternate);
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    try testing.expectEqual(@as(u3, 1), gesture.left_click_count);
    try testing.expectEqual(.primary, gesture.left_click_screen);
}
test "SelectionGesture deinit untracks pin" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    var gesture: SelectionGesture = .init;
    const tracked = t.screens.active.pages.countTrackedPins();
    _ = try gesture.press(&t, testPress(&t, 1, 1, std.Io.Timestamp.now(testing.io, .awake)));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
    gesture.deinit(&t);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
