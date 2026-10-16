const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Config = @import("config.zig").Config;
const log = std.log.scoped(.gtk_wasp_command_palette);
pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspCommandPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
    };
    pub const signals = struct {
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const input.Binding.Action},
                void,
            );
        };
    };
    const Private = struct {
        config: ?*Config = null,
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        view: *gtk.ListView,
        model: *gtk.SingleSelection,
        source: *gio.ListStore,
        pub var offset: c_int = 0;
    };
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.source.removeAll();
        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        const priv = self.private();
        const config = priv.config orelse {
            log.warn("command palette does not have a config!", .{});
            return;
        };
        priv.source.removeAll();
        const alloc = Application.default().allocator();
        var commands: std.ArrayList(*Command) = .empty;
        defer {
            for (commands.items) |cmd| cmd.unref();
            commands.deinit(alloc);
        }
        self.collectJumpCommands(config, &commands) catch |err| {
            log.warn("failed to collect jump commands: {}", .{err});
        };
        self.collectRegularCommands(config, &commands, alloc);
        std.mem.sort(*Command, commands.items, {}, struct {
            fn lessThan(_: void, a: *Command, b: *Command) bool {
                return compareCommands(a, b);
            }
        }.lessThan);
        for (commands.items) |cmd| {
            const cmd_ref = cmd.as(gobject.Object);
            priv.source.append(cmd_ref);
        }
    }
    fn collectRegularCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
        alloc: std.mem.Allocator,
    ) void {
        _ = self;
        const cfg = config.get();
        for (cfg.@"command-palette-entry".value.items) |command| {
            if (!isActionSupportedOnGtk(command.action)) continue;
            const cmd = Command.new(config, command) catch |err| {
                log.warn("failed to create command: {}", .{err});
                continue;
            };
            errdefer cmd.unref();
            commands.append(alloc, cmd) catch |err| {
                log.warn("failed to add command to list: {}", .{err});
                continue;
            };
        }
    }
    fn isActionSupportedOnGtk(action: input.Binding.Action) bool {
        return switch (action) {
            .close_all_windows,
            .toggle_secure_input,
            .check_for_updates,
            .redo,
            .undo,
            .reset_window_size,
            .toggle_window_float_on_top,
            => false,
            else => true,
        };
    }
    fn collectJumpCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
    ) !void {
        _ = self;
        const app = Application.default();
        const alloc = app.allocator();
        const core_app = app.core();
        for (core_app.surfaces.items) |apprt_surface| {
            const surface = apprt_surface.gobj();
            const cmd = Command.newJump(config, surface);
            errdefer cmd.unref();
            try commands.append(alloc, cmd);
        }
    }
    fn compareCommands(a: *Command, b: *Command) bool {
        const a_title = a.propGetTitle() orelse return false;
        const b_title = b.propGetTitle() orelse return true;
        for (0..@min(a_title.len, b_title.len)) |i| {
            const a_char = if (a_title[i] == ':') '\t' else a_title[i];
            const b_char = if (b_title[i] == ':') '\t' else b_title[i];
            const a_lower = std.ascii.toLower(a_char);
            const b_lower = std.ascii.toLower(b_char);
            if (a_lower != b_lower) {
                return a_lower < b_lower;
            }
        }
        if (a_title.len != b_title.len) {
            return a_title.len < b_title.len;
        }
        const a_sort_key = switch (a.private().data) {
            .regular => return false,
            .jump => |*ja| ja.sort_key,
        };
        const b_sort_key = switch (b.private().data) {
            .regular => return false,
            .jump => |*jb| jb.sort_key,
        };
        return a_sort_key < b_sort_key;
    }
    fn close(self: *CommandPalette) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }
    fn dialogClosed(_: *adw.Dialog, self: *CommandPalette) callconv(.c) void {
        self.unref();
    }
    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        self.close();
    }
    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        const priv = self.private();
        self.activated(priv.model.getSelected());
    }
    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }
    pub fn toggle(self: *CommandPalette, window: *Window) void {
        const priv = self.private();
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
    }
    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();
        self.close();
        const cmd = gobject.ext.cast(Command, object_ orelse return) orelse return;
        if (cmd.isJump()) {
            const surface = cmd.getJumpSurface() orelse return;
            defer surface.unref();
            surface.present();
            return;
        }
        const action = cmd.getAction() orelse return;
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Command);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-palette",
                }),
            );
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });
            signals.trigger.impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
const Command = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
        pub const action_key = struct {
            pub const name = "action-key";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetActionKey,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
        pub const action = struct {
            pub const name = "action";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetAction,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetTitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetDescription,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };
    pub const Private = struct {
        config: ?*Config = null,
        arena: ArenaAllocator,
        data: CommandData,
        pub var offset: c_int = 0;
        pub const CommandData = union(enum) {
            regular: RegularData,
            jump: JumpData,
        };
        pub const RegularData = struct {
            command: input.Command,
            action: ?[:0]const u8 = null,
            action_key: ?[:0]const u8 = null,
        };
        pub const JumpData = struct {
            surface: WeakRef(Surface) = .empty,
            title: ?[:0]const u8 = null,
            description: ?[:0]const u8 = null,
            sort_key: usize,
        };
    };
    pub fn new(config: *Config, command: input.Command) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        errdefer self.unref();
        const priv = self.private();
        const cloned = try command.clone(priv.arena.allocator());
        priv.data = .{
            .regular = .{
                .command = cloned,
            },
        };
        return self;
    }
    pub fn newJump(config: *Config, surface: *Surface) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        const priv = self.private();
        priv.data = .{
            .jump = .{ .sort_key = surface.core().?.id },
        };
        priv.data.jump.surface.set(surface);
        return self;
    }
    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }
        switch (priv.data) {
            .regular => {},
            .jump => |*j| {
                j.surface.deinit();
            },
        }
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.arena.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn propGetActionKey(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
        };
        if (regular.action_key) |action_key| return action_key;
        regular.action_key = std.fmt.allocPrintSentinel(
            priv.arena.allocator(),
            "{f}",
            .{regular.command.action},
            0,
        ) catch null;
        return regular.action_key;
    }
    fn propGetAction(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
        };
        if (regular.action) |action| return action;
        const cfg = if (priv.config) |config| config.get() else return null;
        const keybinds = cfg.keybind.set;
        const alloc = priv.arena.allocator();
        regular.action = action: {
            var buf: [64]u8 = undefined;
            const trigger = keybinds.getTrigger(regular.command.action) orelse break :action null;
            const accel = (key.accelFromTrigger(&buf, trigger) catch break :action null) orelse break :action null;
            break :action alloc.dupeZ(u8, accel) catch return null;
        };
        return regular.action;
    }
    fn propGetTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        switch (priv.data) {
            .regular => |*r| return r.command.title,
            .jump => |*j| {
                if (j.title) |title| return title;
                const surface = j.surface.get() orelse return null;
                defer surface.unref();
                const alloc = priv.arena.allocator();
                const effective_title = surface.getEffectiveTitle() orelse "Untitled";
                j.title = std.fmt.allocPrintSentinel(
                    alloc,
                    "Focus: {s}",
                    .{effective_title},
                    0,
                ) catch null;
                return j.title;
            },
        }
    }
    fn propGetDescription(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        switch (priv.data) {
            .regular => |*r| return r.command.description,
            .jump => |*j| {
                if (j.description) |desc| return desc;
                const surface = j.surface.get() orelse return null;
                defer surface.unref();
                const alloc = priv.arena.allocator();
                const title = surface.getEffectiveTitle() orelse "Untitled";
                const pwd = surface.getPwd();
                if (pwd) |p| {
                    if (std.mem.indexOf(u8, title, p) == null) {
                        j.description = alloc.dupeZ(u8, p) catch null;
                    }
                }
                return j.description;
            },
        }
    }
    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();
        return switch (priv.data) {
            .regular => |*r| r.command.action,
            .jump => null,
        };
    }
    pub fn isJump(self: *Self) bool {
        const priv = self.private();
        return priv.data == .jump;
    }
    pub fn getJumpSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.data) {
            .regular => null,
            .jump => |*j| j.surface.get(),
        };
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
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.action_key.impl,
                properties.action.impl,
                properties.title.impl,
                properties.description.impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
