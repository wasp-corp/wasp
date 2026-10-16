const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gtk = @import("gtk");
const configpkg = @import("../../../config.zig");
const CoreConfig = configpkg.Config;
const Common = @import("../class.zig").Common;
const log = std.log.scoped(.gtk_wasp_config);
pub const Config = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspConfig",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const @"diagnostics-buffer" = gobject.ext.defineProperty(
            "diagnostics-buffer",
            Self,
            ?*gtk.TextBuffer,
            .{
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    ?*gtk.TextBuffer,
                    .{
                        .getter = Self.diagnosticsBuffer,
                        .getter_transfer = .full,
                    },
                ),
            },
        );
        pub const @"has-diagnostics" = gobject.ext.defineProperty(
            "has-diagnostics",
            Self,
            bool,
            .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    bool,
                    .{
                        .getter = Self.hasDiagnostics,
                    },
                ),
            },
        );
    };
    const Private = struct {
        config: CoreConfig,
        pub var offset: c_int = 0;
    };
    pub fn new(alloc: Allocator, config: *const CoreConfig) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        priv.config = try config.clone(alloc);
        return self;
    }
    pub fn get(self: *Self) *const CoreConfig {
        return &self.private().config;
    }
    pub fn getMut(self: *Self) *CoreConfig {
        return &self.private().config;
    }
    pub fn hasDiagnostics(self: *Self) bool {
        const config = self.get();
        return !config._diagnostics.empty();
    }
    pub fn diagnosticsBuffer(self: *Self) ?*gtk.TextBuffer {
        const config = self.get();
        if (config._diagnostics.empty()) return null;
        const text_buf: *gtk.TextBuffer = .new(null);
        errdefer text_buf.unref();
        var buf: [4095:0]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        for (config._diagnostics.items()) |diag| {
            writer.end = 0;
            diag.format(&writer) catch |err| {
                log.warn(
                    "error writing diagnostic to buffer err={}",
                    .{err},
                );
                continue;
            };
            text_buf.insertAtCursor(&buf, @intCast(writer.end));
            text_buf.insertAtCursor("\n", 1);
        }
        return text_buf;
    }
    fn finalize(self: *Self) callconv(.c) void {
        self.private().config.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gobject.ext.registerProperties(class, &.{
                properties.@"diagnostics-buffer",
                properties.@"has-diagnostics",
            });
        }
    };
};
test "WaspConfig" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var config: CoreConfig = try .default(alloc);
    defer config.deinit();
    const obj: *Config = try .new(alloc, &config);
    obj.unref();
}
