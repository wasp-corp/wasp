const std = @import("std");
const build_config = @import("../build_config.zig");
const terminal = @import("../terminal/main.zig");
pub const ContentScale = struct {
    x: f32,
    y: f32,
};
pub const SurfaceSize = struct {
    width: u32,
    height: u32,
    pub fn eql(self: *const SurfaceSize, other: *const SurfaceSize) bool {
        return self.width == other.width and self.height == other.height;
    }
};
pub const CursorPos = struct {
    x: f32,
    y: f32,
};
pub const IMEPos = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};
pub const Clipboard = enum(Backing) {
    standard = 0,
    selection = 1,
    primary = 2,
    const Backing = switch (build_config.app_runtime) {
        .gtk => c_int,
        else => u2,
    };
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            Clipboard,
            .{ .name = "WaspApprtClipboard" },
        ),
        .none => void,
    };
};
pub const ClipboardContent = struct {
    mime: [:0]const u8,
    data: [:0]const u8,
};
pub const ClipboardRequestType = enum(u8) {
    paste,
    osc_52_read,
    osc_52_write,
    kitty_read,
    kitty_write,
    list,
};
pub const ClipboardReadResult = enum(c_int) {
    started = 0,
    unavailable = 1,
    unsupported = 2,
};
pub const ClipboardRequest = union(ClipboardRequestType) {
    paste: Clipboard,
    osc_52_read: Clipboard,
    osc_52_write: Clipboard,
    kitty_read: *KittyRead,
    kitty_write: *KittyWrite,
    list: Clipboard,
    pub const KittyRead = struct {
        arena: std.heap.ArenaAllocator,
        location: Clipboard,
        mimes: []const [:0]const u8,
        list: bool,
        id: []const u8,
        pw: []const u8,
        name: [:0]const u8,
        granted: bool,
        terminator: terminal.osc.Terminator,
        pub fn destroy(self: *KittyRead) void {
            var arena = self.arena;
            arena.deinit();
        }
    };
    pub const KittyWrite = struct {
        arena: std.heap.ArenaAllocator,
        location: Clipboard,
        contents: []const ClipboardContent,
        id: []const u8,
        pw: []const u8,
        name: [:0]const u8,
        granted: bool,
        terminator: terminal.osc.Terminator,
        pub fn destroy(self: *KittyWrite) void {
            var arena = self.arena;
            arena.deinit();
        }
    };
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            ClipboardRequest,
            .{ .name = "WaspClipboardRequest" },
        ),
        .none => void,
    };
};
pub const ColorScheme = enum(u2) {
    light = 0,
    dark = 1,
};
pub const Selection = struct {
    tl_x_px: f64,
    tl_y_px: f64,
    offset_start: u32,
    offset_len: u32,
};
