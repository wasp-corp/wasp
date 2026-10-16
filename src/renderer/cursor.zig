const std = @import("std");
const terminal = @import("../terminal/main.zig");
pub const Style = enum {
    block,
    block_hollow,
    bar,
    underline,
    lock,
    pub fn fromTerminal(term: terminal.CursorStyle) Style {
        return switch (term) {
            .bar => .bar,
            .block => .block,
            .block_hollow => .block_hollow,
            .underline => .underline,
        };
    }
};
pub const StyleOptions = struct {
    preedit: bool = false,
    focused: bool = false,
    blink_visible: bool = false,
};
pub fn style(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) ?Style {
    if (state.cursor.viewport == null) return null;
    if (opts.preedit) return .block;
    if (state.cursor.password_input) return .lock;
    if (!state.cursor.visible) return null;
    if (!opts.focused) return .block_hollow;
    if (state.cursor.blinking and !opts.blink_visible) return null;
    return .fromTerminal(state.cursor.visual_style);
}
test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term: terminal.Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = false }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = false }) == null);
}
test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == .block_hollow);
}
test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == null);
}
test "cursor: always block with preedit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == .block);
    for (0..100) |_| try term.index();
    term.scrollViewport(.{ .top = {} });
    try state.update(alloc, &term);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == null);
}
