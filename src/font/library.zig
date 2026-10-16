const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("main.zig").options;
const freetype = @import("freetype");
const font = @import("main.zig");
pub const Library = switch (options.backend) {
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    => FreetypeLibrary,
    .coretext,
    .coretext_harfbuzz,
    .coretext_noshape,
    .web_canvas,
    => NoopLibrary,
};
pub const FreetypeLibrary = struct {
    lib: freetype.Library,
    alloc: Allocator,
    mutex: *std.Io.Mutex,
    pub const InitError = freetype.Error || Allocator.Error;
    pub fn init(alloc: Allocator) InitError!Library {
        const lib = try freetype.Library.init();
        errdefer lib.deinit();
        const mutex = try alloc.create(std.Io.Mutex);
        mutex.* = .init;
        return Library{ .lib = lib, .alloc = alloc, .mutex = mutex };
    }
    pub fn deinit(self: *Library) void {
        self.alloc.destroy(self.mutex);
        self.lib.deinit();
    }
};
pub const NoopLibrary = struct {
    pub const InitError = error{};
    pub fn init(alloc: Allocator) InitError!Library {
        _ = alloc;
        return Library{};
    }
    pub fn deinit(self: *Library) void {
        _ = self;
    }
};
