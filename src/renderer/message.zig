const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const configpkg = @import("../config.zig");
const font = @import("../font/root.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
pub const Message = union(enum) {
    crash,
    focus: bool,
    visible: bool,
    reset_cursor_blink,
    font_grid: struct {
        grid: *font.SharedGrid,
        set: *font.SharedGridSet,
        new_key: font.SharedGridSet.Key,
        old_key: font.SharedGridSet.Key,
    },
    resize: renderer.Size,
    change_config: struct {
        alloc: Allocator,
        thread: *renderer.Thread.DerivedConfig,
        impl: *renderer.Renderer.DerivedConfig,
    },
    search_viewport_matches: SearchMatches,
    search_selected_match: ?SearchMatch,
    inspector: bool,
    macos_display_id: u32,
    presentation_health: renderer.Health,
    pub const SearchMatches = struct {
        arena: ArenaAllocator,
        matches: []const terminal.highlight.Flattened,
    };
    pub const SearchMatch = struct {
        arena: ArenaAllocator,
        match: terminal.highlight.Flattened,
    };
    pub fn initChangeConfig(alloc: Allocator, config: *const configpkg.Config) !Message {
        const thread_ptr = try alloc.create(renderer.Thread.DerivedConfig);
        errdefer alloc.destroy(thread_ptr);
        const config_ptr = try alloc.create(renderer.Renderer.DerivedConfig);
        errdefer alloc.destroy(config_ptr);
        thread_ptr.* = renderer.Thread.DerivedConfig.init(config);
        config_ptr.* = try renderer.Renderer.DerivedConfig.init(alloc, config);
        errdefer config_ptr.deinit();
        return .{
            .change_config = .{
                .alloc = alloc,
                .thread = thread_ptr,
                .impl = config_ptr,
            },
        };
    }
    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.impl.deinit();
                v.alloc.destroy(v.impl);
                v.alloc.destroy(v.thread);
            },
            else => {},
        }
    }
};
