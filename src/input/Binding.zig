const Binding = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const build_config = @import("../build_config.zig");
const uucode = @import("uucode");
const EntryFormatter = @import("../config/formatter.zig").EntryFormatter;
const deepEqual = @import("../datastruct/comparison.zig").deepEqual;
const key = @import("key.zig");
const key_mods = @import("key_mods.zig");
const KeyEvent = key.KeyEvent;
trigger: Trigger,
action: Action,
flags: Flags = .{},
pub const Error = error{
    InvalidFormat,
    InvalidAction,
};
pub const Flags = packed struct {
    consumed: bool = true,
    all: bool = false,
    global: bool = false,
    performable: bool = false,
    pub const C = u8;
    pub fn cval(self: Flags) C {
        const Backing = @typeInfo(Flags).@"struct".backing_integer.?;
        return @as(Backing, @bitCast(self));
    }
    test "cval" {
        const testing = std.testing;
        try testing.expectEqual(@as(u8, 0b0001), (Flags{}).cval());
        try testing.expectEqual(@as(u8, 0b0000), (Flags{ .consumed = false }).cval());
        try testing.expectEqual(@as(u8, 0b0011), (Flags{ .all = true }).cval());
        try testing.expectEqual(@as(u8, 0b0101), (Flags{ .global = true }).cval());
        try testing.expectEqual(@as(u8, 0b1001), (Flags{ .performable = true }).cval());
        try testing.expectEqual(@as(u8, 0b1111), (Flags{ .consumed = true, .all = true, .global = true, .performable = true }).cval());
    }
};
pub const Parser = struct {
    trigger_it: SequenceIterator,
    action: Action,
    flags: Flags = .{},
    chain: bool,
    pub const Elem = union(enum) {
        leader: Trigger,
        binding: Binding,
        chain: Action,
    };
    pub fn init(raw_input: []const u8) Error!Parser {
        const flags, const start_idx = try parseFlags(raw_input);
        const input = raw_input[start_idx..];
        const eql_idx: usize = eql: {
            var offset: usize = 0;
            while (std.mem.indexOfScalar(
                u8,
                input[offset..],
                '=',
            )) |offset_idx| {
                const idx = offset + offset_idx;
                if (idx < input.len - 1 and
                    (input[idx + 1] == '+' or
                        input[idx + 1] == '='))
                {
                    offset += offset_idx + 1;
                    continue;
                }
                break :eql idx;
            }
            return Error.InvalidFormat;
        };
        const chain = std.mem.eql(u8, input[0..eql_idx], "chain");
        if (chain and start_idx > 0) return Error.InvalidFormat;
        return .{
            .trigger_it = .{
                .input = if (chain) "a" else input[0..eql_idx],
            },
            .action = try .parse(input[eql_idx + 1 ..]),
            .flags = flags,
            .chain = chain,
        };
    }
    fn parseFlags(raw_input: []const u8) Error!struct { Flags, usize } {
        var flags: Flags = .{};
        var start_idx: usize = 0;
        var input: []const u8 = raw_input;
        while (true) {
            const idx = std.mem.indexOf(u8, input, ":") orelse break;
            const prefix = input[0..idx];
            if (std.mem.eql(u8, prefix, "all")) {
                if (flags.all) return Error.InvalidFormat;
                flags.all = true;
            } else if (std.mem.eql(u8, prefix, "global")) {
                if (flags.global) return Error.InvalidFormat;
                flags.global = true;
            } else if (std.mem.eql(u8, prefix, "unconsumed")) {
                if (!flags.consumed) return Error.InvalidFormat;
                flags.consumed = false;
            } else if (std.mem.eql(u8, prefix, "performable")) {
                if (flags.performable) return Error.InvalidFormat;
                flags.performable = true;
            } else {
                break;
            }
            start_idx += idx + 1;
            input = input[idx + 1 ..];
        }
        return .{ flags, start_idx };
    }
    pub fn next(self: *Parser) Error!?Elem {
        const trigger = (try self.trigger_it.next()) orelse return null;
        if (!self.trigger_it.done()) {
            if (self.flags.global or self.flags.all) return error.InvalidFormat;
            return .{ .leader = trigger };
        }
        if (self.chain) return .{ .chain = self.action };
        return .{ .binding = .{
            .trigger = trigger,
            .action = self.action,
            .flags = self.flags,
        } };
    }
    pub fn reset(self: *Parser) void {
        self.trigger_it.i = 0;
    }
};
const SequenceIterator = struct {
    input: []const u8,
    i: usize = 0,
    pub fn next(self: *SequenceIterator) Error!?Trigger {
        if (self.done()) return null;
        const rem = self.input[self.i..];
        const idx = std.mem.indexOf(u8, rem, ">") orelse rem.len;
        defer self.i += idx + 1;
        return try .parse(rem[0..idx]);
    }
    pub fn done(self: *const SequenceIterator) bool {
        return self.i > self.input.len;
    }
};
fn parseSingle(raw_input: []const u8) (Error || error{
    UnexpectedChain,
    UnexpectedSequence,
})!Binding {
    var p = try Parser.init(raw_input);
    const elem = (try p.next()) orelse return Error.InvalidFormat;
    return switch (elem) {
        .leader => error.UnexpectedSequence,
        .binding => elem.binding,
        .chain => error.UnexpectedChain,
    };
}
pub fn lessThan(_: void, lhs: Binding, rhs: Binding) bool {
    const lhs_count: usize = blk: {
        var count: usize = 0;
        if (lhs.trigger.mods.super) count += 1;
        if (lhs.trigger.mods.ctrl) count += 1;
        if (lhs.trigger.mods.shift) count += 1;
        if (lhs.trigger.mods.alt) count += 1;
        break :blk count;
    };
    const rhs_count: usize = blk: {
        var count: usize = 0;
        if (rhs.trigger.mods.super) count += 1;
        if (rhs.trigger.mods.ctrl) count += 1;
        if (rhs.trigger.mods.shift) count += 1;
        if (rhs.trigger.mods.alt) count += 1;
        break :blk count;
    };
    if (lhs_count != rhs_count)
        return lhs_count > rhs_count;
    if (lhs.trigger.mods.int() != rhs.trigger.mods.int())
        return lhs.trigger.mods.int() > rhs.trigger.mods.int();
    const lhs_key: c_int = blk: {
        switch (lhs.trigger.key) {
            .physical => break :blk @intFromEnum(lhs.trigger.key.physical),
            .unicode => break :blk @intCast(lhs.trigger.key.unicode),
        }
    };
    const rhs_key: c_int = blk: {
        switch (rhs.trigger.key) {
            .physical => break :blk @intFromEnum(rhs.trigger.key.physical),
            .unicode => break :blk @intCast(rhs.trigger.key.unicode),
        }
    };
    return lhs_key < rhs_key;
}
pub const Action = union(enum) {
    ignore,
    unbind,
    csi: []const u8,
    esc: []const u8,
    text: []const u8,
    cursor_key: CursorKey,
    reset,
    copy_to_clipboard: CopyToClipboard,
    paste_from_clipboard,
    paste_from_selection,
    copy_url_to_clipboard,
    copy_title_to_clipboard,
    increase_font_size: f32,
    decrease_font_size: f32,
    reset_font_size,
    set_font_size: f32,
    search: []const u8,
    search_selection,
    navigate_search: NavigateSearch,
    start_search,
    end_search,
    clear_screen,
    select_all,
    scroll_to_top,
    scroll_to_bottom,
    scroll_to_selection,
    scroll_to_row: usize,
    scroll_page_up,
    scroll_page_down,
    scroll_page_fractional: f32,
    scroll_page_lines: i16,
    adjust_selection: AdjustSelection,
    jump_to_prompt: i16,
    write_scrollback_file: WriteScreen,
    write_screen_file: WriteScreen,
    write_selection_file: WriteScreen,
    new_window,
    new_tab,
    previous_tab,
    next_tab,
    last_tab,
    goto_tab: usize,
    move_tab: isize,
    move_tab_to_new_window,
    toggle_tab_overview,
    prompt_surface_title,
    prompt_tab_title,
    prompt_window_title,
    set_surface_title: []const u8,
    set_tab_title: []const u8,
    set_window_title: []const u8,
    new_split: SplitDirection,
    goto_split: SplitFocusDirection,
    goto_window: GotoWindow,
    toggle_split_zoom,
    toggle_readonly,
    resize_split: SplitResizeParameter,
    equalize_splits,
    reset_window_size,
    inspector: InspectorMode,
    show_gtk_inspector,
    show_on_screen_keyboard,
    open_config: OpenConfig,
    reload_config,
    close_surface,
    close_tab: CloseTabMode,
    close_window,
    close_all_windows,
    toggle_maximize,
    toggle_fullscreen,
    toggle_window_decorations,
    toggle_window_float_on_top,
    toggle_secure_input,
    toggle_mouse_reporting,
    toggle_command_palette,
    toggle_quick_terminal,
    toggle_visibility,
    toggle_background_opacity,
    check_for_updates,
    undo,
    redo,
    end_key_sequence,
    activate_key_table: []const u8,
    activate_key_table_once: []const u8,
    deactivate_key_table,
    deactivate_all_key_tables,
    quit,
    crash: CrashThread,
    pub const Key = @typeInfo(Action).@"union".tag_type.?;
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            Action,
            .{ .name = "WaspBindingAction" },
        ),
        .none => void,
    };
    pub const CrashThread = enum {
        main,
        io,
        render,
    };
    pub const CursorKey = struct {
        normal: []const u8,
        application: []const u8,
        pub fn clone(
            self: CursorKey,
            alloc: Allocator,
        ) Allocator.Error!CursorKey {
            return .{
                .normal = try alloc.dupe(u8, self.normal),
                .application = try alloc.dupe(u8, self.application),
            };
        }
        pub fn format(
            self: CursorKey,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            _ = self;
            _ = writer;
            @panic("formatting not supported");
        }
    };
    pub const NavigateSearch = enum {
        previous,
        next,
    };
    pub const AdjustSelection = enum {
        left,
        right,
        up,
        down,
        page_up,
        page_down,
        home,
        end,
        beginning_of_line,
        end_of_line,
    };
    pub const SplitDirection = enum {
        right,
        down,
        left,
        up,
        auto,
        pub const default: SplitDirection = .auto;
    };
    pub const SplitFocusDirection = enum {
        previous,
        next,
        up,
        left,
        down,
        right,
        pub fn parse(input: []const u8) !SplitFocusDirection {
            return std.meta.stringToEnum(SplitFocusDirection, input) orelse {
                if (std.mem.eql(u8, input, "top")) {
                    return .up;
                } else if (std.mem.eql(u8, input, "bottom")) {
                    return .down;
                } else {
                    return Error.InvalidFormat;
                }
            };
        }
        test "parse" {
            const testing = std.testing;
            try testing.expectEqual(.previous, try SplitFocusDirection.parse("previous"));
            try testing.expectEqual(.next, try SplitFocusDirection.parse("next"));
            try testing.expectEqual(.up, try SplitFocusDirection.parse("up"));
            try testing.expectEqual(.left, try SplitFocusDirection.parse("left"));
            try testing.expectEqual(.down, try SplitFocusDirection.parse("down"));
            try testing.expectEqual(.right, try SplitFocusDirection.parse("right"));
            try testing.expectEqual(.up, try SplitFocusDirection.parse("top"));
            try testing.expectEqual(.down, try SplitFocusDirection.parse("bottom"));
            try testing.expectError(error.InvalidFormat, SplitFocusDirection.parse(""));
            try testing.expectError(error.InvalidFormat, SplitFocusDirection.parse("green"));
        }
    };
    pub const SplitResizeDirection = enum {
        up,
        down,
        left,
        right,
    };
    pub const GotoWindow = enum {
        previous,
        next,
    };
    pub const SplitResizeParameter = struct {
        SplitResizeDirection,
        u16,
    };
    pub const CopyToClipboard = enum {
        plain,
        vt,
        html,
        mixed,
        pub const default: CopyToClipboard = .mixed;
    };
    pub const WriteScreen = struct {
        action: WriteScreen.Action,
        emit: WriteScreen.Format,
        pub const copy: WriteScreen = .{ .action = .copy, .emit = .plain };
        pub const paste: WriteScreen = .{ .action = .paste, .emit = .plain };
        pub const open: WriteScreen = .{ .action = .open, .emit = .plain };
        pub const Action = enum {
            copy,
            paste,
            open,
        };
        pub const Format = enum {
            plain,
            vt,
            html,
        };
        pub fn parse(param: []const u8) !WriteScreen {
            const idx = std.mem.indexOfScalar(u8, param, ',') orelse return .{
                .action = try Binding.Action.parseEnum(
                    WriteScreen.Action,
                    param,
                ),
                .emit = .plain,
            };
            return .{
                .action = try Binding.Action.parseEnum(
                    WriteScreen.Action,
                    param[0..idx],
                ),
                .emit = try Binding.Action.parseEnum(
                    WriteScreen.Format,
                    param[idx + 1 ..],
                ),
            };
        }
        pub fn clone(
            self: WriteScreen,
            alloc: Allocator,
        ) Allocator.Error!WriteScreen {
            _ = alloc;
            return self;
        }
        pub fn format(self: WriteScreen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{t},{t}", .{
                self.action,
                self.emit,
            });
        }
    };
    pub const InspectorMode = enum {
        toggle,
        show,
        hide,
    };
    pub const CloseTabMode = enum {
        this,
        other,
        right,
        pub const default: CloseTabMode = .this;
    };
    pub const OpenConfig = enum {
        os_open,
        new_window,
        pub const default: OpenConfig = .os_open;
    };
    fn parseEnum(comptime T: type, value: []const u8) !T {
        return std.meta.stringToEnum(T, value) orelse return Error.InvalidFormat;
    }
    fn parseInt(comptime T: type, value: []const u8) !T {
        return std.fmt.parseInt(T, value, 10) catch return Error.InvalidFormat;
    }
    fn parseFloat(comptime T: type, value: []const u8) !T {
        return std.fmt.parseFloat(T, value) catch return Error.InvalidFormat;
    }
    fn parseParameter(
        comptime field: std.builtin.Type.UnionField,
        param: []const u8,
    ) !field.type {
        const field_info = @typeInfo(field.type);
        if (field_info == .@"struct" or
            field_info == .@"union" or
            field_info == .@"enum")
        {
            if (@hasDecl(field.type, "parse") and
                @typeInfo(@TypeOf(field.type.parse)) == .@"fn")
            {
                return try field.type.parse(param);
            }
        }
        return switch (field_info) {
            .@"enum" => try parseEnum(field.type, param),
            .int => try parseInt(field.type, param),
            .float => try parseFloat(field.type, param),
            .@"struct" => |info| blk: {
                comptime assert(info.is_tuple);
                var it = std.mem.splitAny(u8, param, ",");
                var value: field.type = undefined;
                inline for (info.fields) |field_| {
                    const next = it.next() orelse return Error.InvalidFormat;
                    @field(value, field_.name) = switch (@typeInfo(field_.type)) {
                        .@"enum" => try parseEnum(field_.type, next),
                        .int => try parseInt(field_.type, next),
                        .float => try parseFloat(field_.type, next),
                        else => unreachable,
                    };
                }
                if (it.next() != null) return Error.InvalidFormat;
                break :blk value;
            },
            else => unreachable,
        };
    }
    pub fn parse(input: []const u8) !Action {
        const colonIdx = std.mem.indexOf(u8, input, ":");
        const action = input[0..(colonIdx orelse input.len)];
        if (action.len == 0) return Error.InvalidFormat;
        const actionInfo = @typeInfo(Action).@"union";
        inline for (actionInfo.fields) |field| {
            if (std.mem.eql(u8, action, field.name)) {
                switch (field.type) {
                    void => {
                        if (colonIdx != null) return Error.InvalidFormat;
                        return @unionInit(Action, field.name, {});
                    },
                    []const u8 => {
                        const idx = colonIdx orelse return Error.InvalidFormat;
                        const param = input[idx + 1 ..];
                        return @unionInit(Action, field.name, param);
                    },
                    Action.CursorKey => return Error.InvalidAction,
                    else => {
                        const idx = colonIdx orelse {
                            switch (@typeInfo(field.type)) {
                                .@"struct",
                                .@"union",
                                .@"enum",
                                => if (@hasDecl(field.type, "default")) {
                                    return @unionInit(
                                        Action,
                                        field.name,
                                        @field(field.type, "default"),
                                    );
                                },
                                else => {},
                            }
                            return Error.InvalidFormat;
                        };
                        const param = input[idx + 1 ..];
                        return @unionInit(
                            Action,
                            field.name,
                            try parseParameter(field, param),
                        );
                    },
                }
            }
        }
        return Error.InvalidAction;
    }
    pub const Scope = enum {
        app,
        surface,
    };
    pub fn scope(self: Action) Scope {
        return switch (self) {
            .ignore,
            .unbind,
            => .app,
            .open_config,
            .reload_config,
            .close_all_windows,
            .quit,
            .toggle_quick_terminal,
            .toggle_visibility,
            .check_for_updates,
            .show_gtk_inspector,
            => .app,
            .new_window,
            .undo,
            .redo,
            => .app,
            .csi,
            .esc,
            .text,
            .cursor_key,
            .search,
            .navigate_search,
            .search_selection,
            .start_search,
            .end_search,
            .reset,
            .copy_to_clipboard,
            .copy_url_to_clipboard,
            .copy_title_to_clipboard,
            .paste_from_clipboard,
            .paste_from_selection,
            .increase_font_size,
            .decrease_font_size,
            .reset_font_size,
            .set_font_size,
            .prompt_surface_title,
            .prompt_tab_title,
            .prompt_window_title,
            .set_surface_title,
            .set_tab_title,
            .set_window_title,
            .clear_screen,
            .select_all,
            .scroll_to_top,
            .scroll_to_bottom,
            .scroll_to_selection,
            .scroll_to_row,
            .scroll_page_up,
            .scroll_page_down,
            .scroll_page_fractional,
            .scroll_page_lines,
            .adjust_selection,
            .jump_to_prompt,
            .write_scrollback_file,
            .write_screen_file,
            .write_selection_file,
            .close_surface,
            .close_tab,
            .close_window,
            .toggle_maximize,
            .toggle_fullscreen,
            .toggle_window_decorations,
            .toggle_window_float_on_top,
            .toggle_secure_input,
            .toggle_mouse_reporting,
            .toggle_command_palette,
            .toggle_background_opacity,
            .show_on_screen_keyboard,
            .reset_window_size,
            .activate_key_table,
            .activate_key_table_once,
            .deactivate_key_table,
            .deactivate_all_key_tables,
            .end_key_sequence,
            .crash,
            => .surface,
            .new_tab,
            .previous_tab,
            .next_tab,
            .last_tab,
            .goto_tab,
            .move_tab,
            .move_tab_to_new_window,
            .toggle_tab_overview,
            .new_split,
            .goto_split,
            .goto_window,
            .toggle_split_zoom,
            .toggle_readonly,
            .resize_split,
            .equalize_splits,
            .inspector,
            => .surface,
        };
    }
    pub fn Scoped(comptime s: Scope) type {
        @setEvalBranchQuota(100_000);
        const all_fields = @typeInfo(Action).@"union".fields;
        var i: comptime_int = 0;
        var names: [all_fields.len][]const u8 = undefined;
        var types: [all_fields.len]type = undefined;
        var attrs: [all_fields.len]std.builtin.Type.UnionField.Attributes = undefined;
        var raw_values: [all_fields.len]comptime_int = undefined;
        for (all_fields) |field| {
            const action = @unionInit(Action, field.name, undefined);
            if (action.scope() == s) {
                names[i] = field.name;
                types[i] = field.type;
                attrs[i] = .{ .@"align" = field.alignment };
                raw_values[i] = i;
                i += 1;
            }
        }
        const TagInt = std.math.IntFittingRange(0, i);
        var values: [i]TagInt = undefined;
        for (raw_values[0..i], &values) |raw, *v| v.* = raw;
        return @Union(
            .auto,
            @Enum(TagInt, .exhaustive, names[0..i], &values),
            names[0..i],
            types[0..i],
            attrs[0..i],
        );
    }
    pub fn scoped(self: Action, comptime s: Scope) ?Scoped(s) {
        switch (self) {
            inline else => |v, tag| {
                if (comptime @unionInit(
                    Action,
                    @tagName(tag),
                    undefined,
                ).scope() != s) return null;
                return @unionInit(
                    Scoped(s),
                    @tagName(tag),
                    v,
                );
            },
        }
    }
    pub fn format(
        self: Action,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            inline else => |value| {
                try writer.print("{s}", .{@tagName(self)});
                if (@TypeOf(value) != void) {
                    try writer.writeAll(":");
                    try formatValue(writer, value);
                }
            },
        }
    }
    fn formatValue(
        writer: *std.Io.Writer,
        value: anytype,
    ) !void {
        const Value = @TypeOf(value);
        const value_info = @typeInfo(Value);
        switch (Value) {
            void => {},
            []const u8 => try writer.print("{s}", .{value}),
            else => switch (value_info) {
                .@"enum" => try writer.print("{t}", .{value}),
                .float => try writer.print("{d}", .{value}),
                .int => try writer.print("{d}", .{value}),
                .@"struct" => |info| format: {
                    if (@hasDecl(Value, "format")) {
                        try value.format(writer);
                        break :format;
                    }
                    if (!info.is_tuple) {
                        @compileError("unhandled struct type: " ++ @typeName(Value));
                    } else {
                        inline for (info.fields, 0..) |field, i| {
                            try formatValue(writer, @field(value, field.name));
                            if (i + 1 < info.fields.len) try writer.writeAll(",");
                        }
                    }
                },
                else => @compileError("unhandled type: " ++ @typeName(Value)),
            },
        }
    }
    pub fn clone(self: Action, alloc: Allocator) Allocator.Error!Action {
        return switch (self) {
            inline else => |value, tag| @unionInit(
                Action,
                @tagName(tag),
                try cloneValue(alloc, value),
            ),
        };
    }
    fn cloneValue(
        alloc: Allocator,
        value: anytype,
    ) Allocator.Error!@TypeOf(value) {
        return switch (@typeInfo(@TypeOf(value))) {
            .void,
            .int,
            .float,
            .@"enum",
            => value,
            .pointer => |info| slice: {
                comptime assert(info.size == .slice);
                break :slice try alloc.dupe(
                    info.child,
                    value,
                );
            },
            .@"struct" => |info| if (info.is_tuple)
                value
            else
                try value.clone(alloc),
            else => {
                @compileLog(@TypeOf(value));
                @compileError("unexpected type");
            },
        };
    }
    pub fn hash(self: Action) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashIncremental(&hasher);
        return hasher.final();
    }
    fn hashIncremental(self: Action, hasher: anytype) void {
        const Tag = @typeInfo(Action).@"union".tag_type.?;
        std.hash.autoHash(hasher, @as(Tag, self));
        switch (self) {
            inline else => |field| {
                const FieldType = @TypeOf(field);
                switch (FieldType) {
                    void => {},
                    f32 => std.hash.autoHash(
                        hasher,
                        @as(u32, @bitCast(field)),
                    ),
                    f64 => std.hash.autoHash(
                        hasher,
                        @as(u64, @bitCast(field)),
                    ),
                    else => std.hash.autoHashStrat(
                        hasher,
                        field,
                        .DeepRecursive,
                    ),
                }
            },
        }
    }
    pub fn equal(self: Action, other: Action) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            inline else => |field_self, tag| {
                const field_other = @field(other, @tagName(tag));
                return deepEqual(
                    @TypeOf(field_self),
                    field_self,
                    field_other,
                );
            },
        };
    }
    const bindingSetEqual = equal;
};
pub const Trigger = struct {
    key: Trigger.Key = .{ .physical = .unidentified },
    mods: key.Mods = .{},
    pub const Key = union(C.Tag) {
        physical: key.Key,
        unicode: u21,
        catch_all,
    };
    pub const C = extern struct {
        tag: Tag = .physical,
        key: C.Key = .{ .physical = .unidentified },
        mods: key.Mods = .{},
        pub const Tag = enum(c_int) {
            physical,
            unicode,
            catch_all,
        };
        pub const Key = extern union {
            physical: key.Key,
            unicode: u32,
        };
    };
    pub fn parse(input: []const u8) !Trigger {
        if (input.len == 0) return Error.InvalidFormat;
        var result: Trigger = .{};
        var rem: []const u8 = input;
        loop: while (rem.len > 0) {
            const idx = std.mem.indexOfScalar(u8, rem, '+') orelse rem.len;
            const part = rem[0..idx];
            rem = if (idx >= rem.len) "" else rem[idx + 1 ..];
            const modsInfo = @typeInfo(key.Mods).@"struct";
            inline for (modsInfo.fields) |field| {
                if (field.type == bool) {
                    if (std.mem.eql(u8, part, field.name)) {
                        if (@field(result.mods, field.name)) return Error.InvalidFormat;
                        @field(result.mods, field.name) = true;
                        continue :loop;
                    }
                }
            }
            inline for (key_mods.alias) |pair| {
                if (std.mem.eql(u8, part, pair[0])) {
                    const field = @tagName(pair[1]);
                    if (@field(result.mods, field)) return Error.InvalidFormat;
                    @field(result.mods, field) = true;
                    continue :loop;
                }
            }
            if (!result.isKeyUnset()) return Error.InvalidFormat;
            if (part.len == 0) {
                result.key = .{ .unicode = '+' };
                continue :loop;
            }
            const keysInfo = @typeInfo(key.Key).@"enum";
            inline for (keysInfo.fields) |field| {
                if (!std.mem.eql(u8, field.name, "unidentified")) {
                    if (std.mem.eql(u8, part, field.name)) {
                        const keyval = @field(key.Key, field.name);
                        result.key = .{ .physical = keyval };
                        continue :loop;
                    }
                }
            }
            if (result.isKeyUnset()) unicode: {
                const view = std.unicode.Utf8View.init(part) catch break :unicode;
                var it = view.iterator();
                const cp = it.nextCodepoint() orelse break :unicode;
                if (it.nextCodepoint() != null) break :unicode;
                result.key = .{ .unicode = cp };
                continue :loop;
            }
            if (key.Key.fromW3C(part)) |w3c_key| {
                result.key = .{ .physical = w3c_key };
                continue :loop;
            }
            if (std.mem.eql(u8, part, "catch_all")) {
                result.key = .catch_all;
                continue :loop;
            }
            if (backwards_compatible_keys.get(part)) |old_key| {
                result.key = old_key;
                continue :loop;
            }
            return Error.InvalidFormat;
        }
        return result;
    }
    const backwards_compatible_keys = std.StaticStringMap(Key).initComptime(.{
        .{ "zero", Key{ .unicode = '0' } },
        .{ "one", Key{ .unicode = '1' } },
        .{ "two", Key{ .unicode = '2' } },
        .{ "three", Key{ .unicode = '3' } },
        .{ "four", Key{ .unicode = '4' } },
        .{ "five", Key{ .unicode = '5' } },
        .{ "six", Key{ .unicode = '6' } },
        .{ "seven", Key{ .unicode = '7' } },
        .{ "eight", Key{ .unicode = '8' } },
        .{ "nine", Key{ .unicode = '9' } },
        .{ "plus", Key{ .unicode = '+' } },
        .{ "apostrophe", Key{ .unicode = '\'' } },
        .{ "grave_accent", Key{ .physical = .backquote } },
        .{ "left_bracket", Key{ .physical = .bracket_left } },
        .{ "right_bracket", Key{ .physical = .bracket_right } },
        .{ "up", Key{ .physical = .arrow_up } },
        .{ "down", Key{ .physical = .arrow_down } },
        .{ "left", Key{ .physical = .arrow_left } },
        .{ "right", Key{ .physical = .arrow_right } },
        .{ "kp_0", Key{ .physical = .numpad_0 } },
        .{ "kp_1", Key{ .physical = .numpad_1 } },
        .{ "kp_2", Key{ .physical = .numpad_2 } },
        .{ "kp_3", Key{ .physical = .numpad_3 } },
        .{ "kp_4", Key{ .physical = .numpad_4 } },
        .{ "kp_5", Key{ .physical = .numpad_5 } },
        .{ "kp_6", Key{ .physical = .numpad_6 } },
        .{ "kp_7", Key{ .physical = .numpad_7 } },
        .{ "kp_8", Key{ .physical = .numpad_8 } },
        .{ "kp_9", Key{ .physical = .numpad_9 } },
        .{ "kp_add", Key{ .physical = .numpad_add } },
        .{ "kp_subtract", Key{ .physical = .numpad_subtract } },
        .{ "kp_multiply", Key{ .physical = .numpad_multiply } },
        .{ "kp_divide", Key{ .physical = .numpad_divide } },
        .{ "kp_decimal", Key{ .physical = .numpad_decimal } },
        .{ "kp_enter", Key{ .physical = .numpad_enter } },
        .{ "kp_equal", Key{ .physical = .numpad_equal } },
        .{ "kp_separator", Key{ .physical = .numpad_separator } },
        .{ "kp_left", Key{ .physical = .numpad_left } },
        .{ "kp_right", Key{ .physical = .numpad_right } },
        .{ "kp_up", Key{ .physical = .numpad_up } },
        .{ "kp_down", Key{ .physical = .numpad_down } },
        .{ "kp_page_up", Key{ .physical = .numpad_page_up } },
        .{ "kp_page_down", Key{ .physical = .numpad_page_down } },
        .{ "kp_home", Key{ .physical = .numpad_home } },
        .{ "kp_end", Key{ .physical = .numpad_end } },
        .{ "kp_insert", Key{ .physical = .numpad_insert } },
        .{ "kp_delete", Key{ .physical = .numpad_delete } },
        .{ "kp_begin", Key{ .physical = .numpad_begin } },
        .{ "left_shift", Key{ .physical = .shift_left } },
        .{ "right_shift", Key{ .physical = .shift_right } },
        .{ "left_control", Key{ .physical = .control_left } },
        .{ "right_control", Key{ .physical = .control_right } },
        .{ "left_alt", Key{ .physical = .alt_left } },
        .{ "right_alt", Key{ .physical = .alt_right } },
        .{ "left_super", Key{ .physical = .meta_left } },
        .{ "right_super", Key{ .physical = .meta_right } },
        .{ "physical:zero", Key{ .physical = .digit_0 } },
        .{ "physical:one", Key{ .physical = .digit_1 } },
        .{ "physical:two", Key{ .physical = .digit_2 } },
        .{ "physical:three", Key{ .physical = .digit_3 } },
        .{ "physical:four", Key{ .physical = .digit_4 } },
        .{ "physical:five", Key{ .physical = .digit_5 } },
        .{ "physical:six", Key{ .physical = .digit_6 } },
        .{ "physical:seven", Key{ .physical = .digit_7 } },
        .{ "physical:eight", Key{ .physical = .digit_8 } },
        .{ "physical:nine", Key{ .physical = .digit_9 } },
        .{ "physical:apostrophe", Key{ .physical = .quote } },
        .{ "physical:grave_accent", Key{ .physical = .backquote } },
        .{ "physical:left_bracket", Key{ .physical = .bracket_left } },
        .{ "physical:right_bracket", Key{ .physical = .bracket_right } },
        .{ "physical:up", Key{ .physical = .arrow_up } },
        .{ "physical:down", Key{ .physical = .arrow_down } },
        .{ "physical:left", Key{ .physical = .arrow_left } },
        .{ "physical:right", Key{ .physical = .arrow_right } },
        .{ "physical:kp_0", Key{ .physical = .numpad_0 } },
        .{ "physical:kp_1", Key{ .physical = .numpad_1 } },
        .{ "physical:kp_2", Key{ .physical = .numpad_2 } },
        .{ "physical:kp_3", Key{ .physical = .numpad_3 } },
        .{ "physical:kp_4", Key{ .physical = .numpad_4 } },
        .{ "physical:kp_5", Key{ .physical = .numpad_5 } },
        .{ "physical:kp_6", Key{ .physical = .numpad_6 } },
        .{ "physical:kp_7", Key{ .physical = .numpad_7 } },
        .{ "physical:kp_8", Key{ .physical = .numpad_8 } },
        .{ "physical:kp_9", Key{ .physical = .numpad_9 } },
        .{ "physical:kp_add", Key{ .physical = .numpad_add } },
        .{ "physical:kp_subtract", Key{ .physical = .numpad_subtract } },
        .{ "physical:kp_multiply", Key{ .physical = .numpad_multiply } },
        .{ "physical:kp_divide", Key{ .physical = .numpad_divide } },
        .{ "physical:kp_decimal", Key{ .physical = .numpad_decimal } },
        .{ "physical:kp_enter", Key{ .physical = .numpad_enter } },
        .{ "physical:kp_equal", Key{ .physical = .numpad_equal } },
        .{ "physical:kp_separator", Key{ .physical = .numpad_separator } },
        .{ "physical:kp_left", Key{ .physical = .numpad_left } },
        .{ "physical:kp_right", Key{ .physical = .numpad_right } },
        .{ "physical:kp_up", Key{ .physical = .numpad_up } },
        .{ "physical:kp_down", Key{ .physical = .numpad_down } },
        .{ "physical:kp_page_up", Key{ .physical = .numpad_page_up } },
        .{ "physical:kp_page_down", Key{ .physical = .numpad_page_down } },
        .{ "physical:kp_home", Key{ .physical = .numpad_home } },
        .{ "physical:kp_end", Key{ .physical = .numpad_end } },
        .{ "physical:kp_insert", Key{ .physical = .numpad_insert } },
        .{ "physical:kp_delete", Key{ .physical = .numpad_delete } },
        .{ "physical:kp_begin", Key{ .physical = .numpad_begin } },
        .{ "physical:left_shift", Key{ .physical = .shift_left } },
        .{ "physical:right_shift", Key{ .physical = .shift_right } },
        .{ "physical:left_control", Key{ .physical = .control_left } },
        .{ "physical:right_control", Key{ .physical = .control_right } },
        .{ "physical:left_alt", Key{ .physical = .alt_left } },
        .{ "physical:right_alt", Key{ .physical = .alt_right } },
        .{ "physical:left_super", Key{ .physical = .meta_left } },
        .{ "physical:right_super", Key{ .physical = .meta_right } },
    });
    pub fn isKeyUnset(self: Trigger) bool {
        return switch (self.key) {
            .physical => |v| v == .unidentified,
            .unicode, .catch_all => false,
        };
    }
    pub fn hash(self: Trigger) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashIncremental(&hasher);
        return hasher.final();
    }
    fn hashIncremental(self: Trigger, hasher: anytype) void {
        std.hash.autoHash(hasher, std.meta.activeTag(self.key));
        switch (self.key) {
            .physical => |v| std.hash.autoHash(hasher, v),
            .unicode => |cp| std.hash.autoHash(
                hasher,
                foldedCodepoint(cp),
            ),
            .catch_all => {},
        }
        std.hash.autoHash(hasher, self.mods.binding());
    }
    fn foldedCodepoint(cp: u21) [3]u21 {
        if (uucode.ascii.isAlphabetic(cp)) {
            return .{ uucode.ascii.toLower(cp), 0, 0 };
        }
        var buffer: [1]u21 = undefined;
        const slice = uucode.get(.case_folding_full, cp).with(&buffer, cp);
        var array: [3]u21 = [_]u21{0} ** 3;
        @memcpy(array[0..slice.len], slice);
        return array;
    }
    pub fn equal(self: Trigger, other: Trigger) bool {
        if (self.mods != other.mods) return false;
        const self_tag = std.meta.activeTag(self.key);
        const other_tag = std.meta.activeTag(other.key);
        if (self_tag != other_tag) return false;
        return switch (self.key) {
            .physical => |v| v == other.key.physical,
            .unicode => |v| v == other.key.unicode,
            .catch_all => true,
        };
    }
    pub fn foldedEqual(self: Trigger, other: Trigger) bool {
        if (self.mods != other.mods) return false;
        const self_tag = std.meta.activeTag(self.key);
        const other_tag = std.meta.activeTag(other.key);
        if (self_tag != other_tag) return false;
        return switch (self.key) {
            .physical => |v| v == other.key.physical,
            .unicode => |v| deepEqual(
                [3]u21,
                foldedCodepoint(v),
                foldedCodepoint(other.key.unicode),
            ),
            .catch_all => true,
        };
    }
    const bindingSetEqual = foldedEqual;
    pub fn cval(self: Trigger) C {
        return .{
            .tag = self.key,
            .key = switch (self.key) {
                .physical => |v| .{ .physical = v },
                .unicode => |v| .{ .unicode = @intCast(v) },
                .catch_all => undefined,
            },
            .mods = self.mods,
        };
    }
    pub fn format(
        self: Trigger,
        writer: *std.Io.Writer,
    ) !void {
        if (self.mods.super) try writer.writeAll("super+");
        if (self.mods.ctrl) try writer.writeAll("ctrl+");
        if (self.mods.alt) try writer.writeAll("alt+");
        if (self.mods.shift) try writer.writeAll("shift+");
        switch (self.key) {
            .physical => |k| try writer.print("{t}", .{k}),
            .unicode => |c| try writer.print("{u}", .{c}),
            .catch_all => try writer.writeAll("catch_all"),
        }
    }
};
pub const Set = struct {
    const HashMap = std.ArrayHashMapUnmanaged(
        Trigger,
        Value,
        Context(Trigger),
        true,
    );
    const ReverseMap = std.ArrayHashMapUnmanaged(
        Action,
        Trigger,
        Context(Action),
        true,
    );
    bindings: HashMap = .{},
    reverse: ReverseMap = .{},
    chain_parent: ?ChainParent = null,
    const ChainParent = struct {
        key_ptr: *Trigger,
        value_ptr: *Value,
        set: *Set,
    };
    pub const Value = union(enum) {
        leader: *Set,
        leaf: Leaf,
        leaf_chained: LeafChained,
        pub fn format(
            self: Value,
            writer: *std.Io.Writer,
        ) !void {
            switch (self) {
                .leader => |set| {
                    var iter = set.bindings.iterator();
                    while (iter.next()) |binding| {
                        try writer.print(
                            ">{s}{s}",
                            .{ binding.key_ptr.*, binding.value_ptr.* },
                        );
                    }
                },
                .leaf => |leaf| {
                    try writer.print("={s}", .{leaf.action});
                },
            }
        }
        pub fn formatEntries(
            self: Value,
            buffer: *std.Io.Writer,
            formatter: EntryFormatter,
        ) !void {
            switch (self) {
                .leader => |set| {
                    const pos = buffer.end;
                    var iter = set.bindings.iterator();
                    while (iter.next()) |binding| {
                        buffer.end = pos;
                        buffer.print(">{f}", .{binding.key_ptr.*}) catch return error.OutOfMemory;
                        try binding.value_ptr.*.formatEntries(buffer, formatter);
                    }
                },
                .leaf => |leaf| {
                    buffer.print("={f}", .{leaf.action}) catch return error.OutOfMemory;
                    try formatter.formatEntry([]const u8, buffer.buffer[0..buffer.end]);
                },
                .leaf_chained => |leaf| {
                    const pos = buffer.end;
                    for (leaf.actions.items, 0..) |action, i| {
                        if (i == 0) {
                            buffer.print("={f}", .{action}) catch return error.OutOfMemory;
                        } else {
                            buffer.end = 0;
                            buffer.print("chain={f}", .{action}) catch return error.OutOfMemory;
                        }
                        try formatter.formatEntry([]const u8, buffer.buffer[0..buffer.end]);
                        buffer.end = pos;
                    }
                },
            }
        }
    };
    pub const Leaf = struct {
        action: Action,
        flags: Flags,
        pub fn clone(
            self: Leaf,
            alloc: Allocator,
        ) Allocator.Error!Leaf {
            return .{
                .action = try self.action.clone(alloc),
                .flags = self.flags,
            };
        }
        pub fn hash(self: Leaf) u64 {
            var hasher = std.hash.Wyhash.init(0);
            self.action.hash(&hasher);
            std.hash.autoHash(&hasher, self.flags);
            return hasher.final();
        }
        pub fn generic(self: *const Leaf) GenericLeaf {
            return .{
                .flags = self.flags,
                .actions = .{ .single = .{self.action} },
            };
        }
    };
    pub const LeafChained = struct {
        actions: std.ArrayList(Action),
        flags: Flags,
        pub fn clone(
            self: LeafChained,
            alloc: Allocator,
        ) Allocator.Error!LeafChained {
            var cloned_actions = try self.actions.clone(alloc);
            errdefer cloned_actions.deinit(alloc);
            for (cloned_actions.items) |*action| {
                action.* = try action.clone(alloc);
            }
            return .{
                .actions = cloned_actions,
                .flags = self.flags,
            };
        }
        pub fn deinit(self: *LeafChained, alloc: Allocator) void {
            self.actions.deinit(alloc);
        }
        pub fn generic(self: *const LeafChained) GenericLeaf {
            return .{
                .flags = self.flags,
                .actions = .{ .many = self.actions.items },
            };
        }
    };
    pub const GenericLeaf = struct {
        flags: Flags,
        actions: union(enum) {
            single: [1]Action,
            many: []const Action,
        },
        pub fn actionsSlice(self: *const GenericLeaf) []const Action {
            return switch (self.actions) {
                .single => |*arr| arr,
                .many => |slice| slice,
            };
        }
    };
    pub const Entry = HashMap.Entry;
    pub fn deinit(self: *Set, alloc: Allocator) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| switch (entry.value_ptr.*) {
            .leader => |s| {
                s.deinit(alloc);
                alloc.destroy(s);
            },
            .leaf_chained => |*l| l.deinit(alloc),
            .leaf => {},
        };
        self.bindings.deinit(alloc);
        self.reverse.deinit(alloc);
        self.* = undefined;
    }
    pub fn parseAndPut(
        self: *Set,
        alloc: Allocator,
        input: []const u8,
    ) (Allocator.Error || Error)!void {
        var it = try Parser.init(input);
        while (try it.next()) |_| {}
        it.reset();
        const updated_set_ = self.parseAndPutRecurse(
            self,
            alloc,
            &it,
        ) catch |err| err: {
            switch (err) {
                error.SequenceUnbind => break :err null,
                error.UnexpectedEndOfInput => return error.InvalidFormat,
                error.NoChainParent => return error.InvalidFormat,
                error.InvalidChainAction => return error.InvalidFormat,
                error.OutOfMemory => return error.OutOfMemory,
            }
            unreachable;
        };
        if (updated_set_) |updated_set| {
            assert(updated_set.chain_parent != null);
            if (updated_set != self) self.chain_parent = updated_set.chain_parent;
            assert(self.chain_parent != null);
        } else {
            self.chain_parent = null;
        }
    }
    const ParseAndPutRecurseError = Allocator.Error || error{
        SequenceUnbind,
        NoChainParent,
        UnexpectedEndOfInput,
        InvalidChainAction,
    };
    fn parseAndPutRecurse(
        root: *Set,
        set: *Set,
        alloc: Allocator,
        it: *Parser,
    ) ParseAndPutRecurseError!?*Set {
        const elem = (it.next() catch unreachable) orelse
            return error.UnexpectedEndOfInput;
        switch (elem) {
            .leader => |t| {
                const old: ?Value = if (set.get(t)) |entry|
                    entry.value_ptr.*
                else
                    null;
                if (old) |entry| switch (entry) {
                    .leader => |s| return root.parseAndPutRecurse(
                        s,
                        alloc,
                        it,
                    ) catch |err| switch (err) {
                        error.SequenceUnbind => if (s.bindings.count() == 0) {
                            set.remove(alloc, t);
                            return error.SequenceUnbind;
                        } else null,
                        error.NoChainParent,
                        error.UnexpectedEndOfInput,
                        error.InvalidChainAction,
                        error.OutOfMemory,
                        => err,
                    },
                    .leaf, .leaf_chained => {
                        set.remove(alloc, t);
                    },
                };
                const next = try alloc.create(Set);
                errdefer alloc.destroy(next);
                next.* = .{};
                errdefer next.deinit(alloc);
                try set.bindings.put(alloc, t, .{ .leader = next });
                return root.parseAndPutRecurse(next, alloc, it) catch |err| switch (err) {
                    error.SequenceUnbind => {
                        set.remove(alloc, t);
                        if (old) |entry| switch (entry) {
                            .leader => unreachable,
                            .leaf => |leaf| set.putFlags(
                                alloc,
                                t,
                                leaf.action,
                                leaf.flags,
                            ) catch {},
                            .leaf_chained => |leaf| chain: {
                                set.putFlags(
                                    alloc,
                                    t,
                                    leaf.actions.items[0],
                                    leaf.flags,
                                ) catch break :chain;
                                for (leaf.actions.items[1..]) |action| {
                                    set.appendChain(
                                        alloc,
                                        action,
                                    ) catch {
                                        set.remove(alloc, t);
                                        break :chain;
                                    };
                                }
                            },
                        };
                        return null;
                    },
                    error.NoChainParent,
                    error.UnexpectedEndOfInput,
                    error.InvalidChainAction,
                    error.OutOfMemory,
                    => return err,
                };
            },
            .binding => |b| switch (b.action) {
                .unbind => {
                    set.remove(alloc, b.trigger);
                    return error.SequenceUnbind;
                },
                else => {
                    try set.putFlags(
                        alloc,
                        b.trigger,
                        b.action,
                        b.flags,
                    );
                    return set;
                },
            },
            .chain => |action| {
                assert(set == root);
                if (action == .unbind) return error.InvalidChainAction;
                try set.appendChain(alloc, action);
                return set;
            },
        }
    }
    pub fn put(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
    ) Allocator.Error!void {
        try self.putFlags(alloc, t, action, .{});
    }
    pub fn putFlags(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
        flags: Flags,
    ) Allocator.Error!void {
        assert(action != .unbind);
        const track_reverse: bool = !flags.performable;
        self.chain_parent = null;
        const gop = try self.bindings.getOrPut(alloc, t);
        self.chain_parent = .{
            .key_ptr = gop.key_ptr,
            .value_ptr = gop.value_ptr,
            .set = self,
        };
        errdefer {
            self.chain_parent = null;
        }
        if (gop.found_existing) switch (gop.value_ptr.*) {
            .leader => |s| {
                s.deinit(alloc);
                alloc.destroy(s);
            },
            .leaf => if (track_reverse) {
                const t_hash = t.hash();
                for (0.., self.reverse.values()) |i, *value| {
                    if (t_hash == value.hash()) {
                        self.reverse.swapRemoveAt(i);
                        break;
                    }
                }
            },
            .leaf_chained => |*l| {
                l.deinit(alloc);
            },
        };
        gop.value_ptr.* = .{ .leaf = .{
            .action = action,
            .flags = flags,
        } };
        errdefer _ = self.bindings.swapRemove(t);
        if (track_reverse) try self.reverse.put(alloc, action, t);
        errdefer if (track_reverse) self.reverse.remove(action);
        assert(self.chain_parent != null);
        assert(self.chain_parent.?.key_ptr == gop.key_ptr);
        assert(self.chain_parent.?.value_ptr == gop.value_ptr);
        assert(self.chain_parent.?.value_ptr.* == .leaf);
    }
    pub fn appendChain(
        self: *Set,
        alloc: Allocator,
        action: Action,
    ) (Allocator.Error || error{NoChainParent})!void {
        assert(action != .unbind);
        const parent = self.chain_parent orelse return error.NoChainParent;
        switch (parent.value_ptr.*) {
            .leader => unreachable,
            .leaf_chained => |*leaf| try leaf.actions.append(
                alloc,
                action,
            ),
            .leaf => |leaf| {
                var actions: std.ArrayList(Action) = .empty;
                try actions.ensureTotalCapacity(alloc, 2);
                errdefer actions.deinit(alloc);
                actions.appendAssumeCapacity(leaf.action);
                actions.appendAssumeCapacity(action);
                parent.value_ptr.* = .{ .leaf_chained = .{
                    .actions = actions,
                    .flags = leaf.flags,
                } };
                parent.set.fixupReverseForAction(
                    leaf.action,
                    parent.key_ptr.*,
                );
            },
        }
    }
    pub fn get(self: Set, t: Trigger) ?Entry {
        return self.bindings.getEntry(t);
    }
    pub fn getTrigger(self: Set, a: Action) ?Trigger {
        return self.reverse.get(a);
    }
    pub fn getEvent(self: *const Set, event: KeyEvent) ?Entry {
        var trigger: Trigger = .{
            .mods = event.mods.binding(),
            .key = .{ .physical = event.key },
        };
        if (self.get(trigger)) |v| return v;
        if (event.utf8.len > 0) unicode: {
            const view = std.unicode.Utf8View.init(event.utf8) catch break :unicode;
            var it = view.iterator();
            const cp = it.nextCodepoint() orelse break :unicode;
            if (it.nextCodepoint() != null) break :unicode;
            trigger.key = .{ .unicode = cp };
            if (self.get(trigger)) |v| return v;
        }
        if (event.unshifted_codepoint > 0) {
            trigger.key = .{ .unicode = event.unshifted_codepoint };
            if (self.get(trigger)) |v| return v;
        }
        trigger.key = .catch_all;
        if (self.get(trigger)) |v| return v;
        if (!trigger.mods.empty()) {
            trigger.mods = .{};
            if (self.get(trigger)) |v| return v;
        }
        return null;
    }
    pub fn remove(self: *Set, alloc: Allocator, t: Trigger) void {
        self.removeExact(alloc, t);
    }
    fn removeExact(self: *Set, alloc: Allocator, t: Trigger) void {
        self.chain_parent = null;
        var entry = self.bindings.get(t) orelse return;
        _ = self.bindings.swapRemove(t);
        switch (entry) {
            .leader => |s| {
                s.deinit(alloc);
                alloc.destroy(s);
            },
            .leaf => |leaf| self.fixupReverseForAction(
                leaf.action,
                t,
            ),
            .leaf_chained => |*l| {
                l.deinit(alloc);
            },
        }
    }
    fn fixupReverseForAction(
        self: *Set,
        action: Action,
        old: Trigger,
    ) void {
        const entry = self.reverse.getEntry(action) orelse return;
        if (!entry.value_ptr.equal(old)) return;
        const action_hash = action.hash();
        var it = self.bindings.iterator();
        while (it.next()) |it_entry| {
            switch (it_entry.value_ptr.*) {
                .leader, .leaf_chained => {},
                .leaf => |leaf_search| {
                    if (leaf_search.action.hash() == action_hash) {
                        entry.value_ptr.* = it_entry.key_ptr.*;
                        return;
                    }
                },
            }
        }
        _ = self.reverse.swapRemove(action);
    }
    pub fn clone(self: *const Set, alloc: Allocator) !Set {
        var result: Set = .{
            .bindings = try self.bindings.clone(alloc),
            .reverse = try self.reverse.clone(alloc),
        };
        {
            var it = result.bindings.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.*) {
                .leaf => |*s| s.* = try s.clone(alloc),
                .leaf_chained => |*s| s.* = try s.clone(alloc),
                .leader => |*s| {
                    const ptr = try alloc.create(Set);
                    errdefer alloc.destroy(ptr);
                    ptr.* = try s.*.clone(alloc);
                    errdefer ptr.deinit(alloc);
                    s.* = ptr;
                },
            };
        }
        for (result.reverse.keys()) |*action| {
            action.* = try action.clone(alloc);
        }
        return result;
    }
    fn Context(comptime KeyType: type) type {
        return struct {
            pub fn hash(ctx: @This(), k: KeyType) u32 {
                _ = ctx;
                return @truncate(k.hash());
            }
            pub fn eql(
                ctx: @This(),
                a: KeyType,
                b: KeyType,
                b_index: usize,
            ) bool {
                _ = ctx;
                _ = b_index;
                return a.bindingSetEqual(b);
            }
        };
    }
};
test "parse: triggers" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = 'a' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("a=ignore"),
    );
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("ctrl+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true, .ctrl = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+ctrl+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("a+shift=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+key_a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'ö' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+ö=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .consumed = false },
    }, try parseSingle("unconsumed:shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .consumed = false },
    }, try parseSingle("unconsumed:key_a+shift=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .performable = true },
    }, try parseSingle("performable:shift+a=ignore"));
    try testing.expectError(Error.InvalidFormat, parseSingle("foo=ignore"));
    try testing.expectError(Error.InvalidFormat, parseSingle("shift+shift+a=ignore"));
    try testing.expectError(Error.InvalidFormat, parseSingle("a+b=ignore"));
}
test "parse: w3c key names" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .physical = .key_a } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("KeyA=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parseSingle("Keya=ignore"));
}
test "parse: catch_all" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .catch_all },
            .action = .{ .ignore = {} },
        },
        try parseSingle("catch_all=ignore"),
    );
    try testing.expectEqual(
        Binding{
            .trigger = .{
                .mods = .{ .ctrl = true },
                .key = .catch_all,
            },
            .action = .{ .ignore = {} },
        },
        try parseSingle("ctrl+catch_all=ignore"),
    );
}
test "parse: plus sign" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = '+' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("+=ignore"),
    );
    try testing.expectEqual(
        Binding{
            .trigger = .{
                .key = .{ .unicode = '+' },
                .mods = .{ .ctrl = true },
            },
            .action = .{ .ignore = {} },
        },
        try parseSingle("ctrl++=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parseSingle("++=ignore"));
}
test "parse: equals sign" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = '=' } },
            .action = .ignore,
        },
        try parseSingle("==ignore"),
    );
    try testing.expectEqual(
        Binding{
            .trigger = .{
                .key = .{ .unicode = '=' },
                .mods = .{ .ctrl = true },
            },
            .action = .ignore,
        },
        try parseSingle("ctrl+==ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parseSingle("=ignore"));
}
test "parse: text action equals sign" {
    const testing = std.testing;
    {
        const binding = try parseSingle("==text:=");
        try testing.expectEqual(Trigger{ .key = .{ .unicode = '=' } }, binding.trigger);
        try testing.expectEqualStrings("=", binding.action.text);
    }
    {
        const binding = try parseSingle("==text:=hello");
        try testing.expectEqual(Trigger{ .key = .{ .unicode = '=' } }, binding.trigger);
        try testing.expectEqualStrings("=hello", binding.action.text);
    }
    {
        const binding = try parseSingle("ctrl+==text:=hello");
        try testing.expectEqual(Trigger{
            .key = .{ .unicode = '=' },
            .mods = .{ .ctrl = true },
        }, binding.trigger);
        try testing.expectEqualStrings("=hello", binding.action.text);
    }
    {
        const binding = try parseSingle("=+ctrl=text:=hello");
        try testing.expectEqual(Trigger{
            .key = .{ .unicode = '=' },
            .mods = .{ .ctrl = true },
        }, binding.trigger);
        try testing.expectEqualStrings("=hello", binding.action.text);
    }
}
test "parse: backwards compatibility with <= 1.1.x" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = '0' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("zero=ignore"),
    );
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .physical = .digit_0 } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("physical:zero=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parseSingle("zero+one=ignore"));
    for (
        Trigger.backwards_compatible_keys.keys(),
        Trigger.backwards_compatible_keys.values(),
    ) |k, v| {
        var buf: [128]u8 = undefined;
        try testing.expectEqual(
            Binding{
                .trigger = .{ .key = v },
                .action = .{ .ignore = {} },
            },
            try parseSingle(try std.fmt.bufPrint(&buf, "{s}=ignore", .{k})),
        );
    }
}
test "parse: global triggers" {
    const testing = std.testing;
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .global = true },
    }, try parseSingle("global:shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .global = true },
    }, try parseSingle("global:key_a+shift=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{
            .global = true,
            .consumed = false,
        },
    }, try parseSingle("unconsumed:global:a+shift=ignore"));
    {
        var p = try Parser.init("global:a>b=ignore");
        try testing.expectError(Error.InvalidFormat, p.next());
    }
}
test "parse: all triggers" {
    const testing = std.testing;
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .all = true },
    }, try parseSingle("all:shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .all = true },
    }, try parseSingle("all:key_a+shift=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{
            .all = true,
            .consumed = false,
        },
    }, try parseSingle("unconsumed:all:a+shift=ignore"));
    {
        var p = try Parser.init("all:a>b=ignore");
        try testing.expectError(Error.InvalidFormat, p.next());
    }
}
test "Trigger: equal" {
    const testing = std.testing;
    {
        const t1: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        const t2: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        try testing.expect(t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        const t2: Trigger = .{ .key = .{ .physical = .arrow_down }, .mods = .{ .ctrl = true } };
        try testing.expect(!t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        const t2: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .shift = true } };
        try testing.expect(!t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        const t2: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        try testing.expect(t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        const t2: Trigger = .{ .key = .{ .unicode = 'b' }, .mods = .{} };
        try testing.expect(!t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        const t2: Trigger = .{ .key = .{ .physical = .key_a }, .mods = .{} };
        try testing.expect(!t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .catch_all, .mods = .{} };
        const t2: Trigger = .{ .key = .catch_all, .mods = .{} };
        try testing.expect(t1.equal(t2));
    }
    {
        const t1: Trigger = .{ .key = .catch_all, .mods = .{} };
        const t2: Trigger = .{ .key = .catch_all, .mods = .{ .alt = true } };
        try testing.expect(!t1.equal(t2));
    }
}
test "parse: modifier aliases" {
    const testing = std.testing;
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .super = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("cmd+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .super = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("command+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .alt = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("opt+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .alt = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("option+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("control+a=ignore"));
}
test "parse: action invalid" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidAction, parseSingle("a=nopenopenope"));
}
test "parse: action no parameters" {
    const testing = std.testing;
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = 'a' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("a=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parseSingle("a=ignore:A"));
}
test "parse: action with string" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=csi:A");
        try testing.expect(binding.action == .csi);
        try testing.expectEqualStrings("A", binding.action.csi);
    }
    {
        const binding = try parseSingle("a=esc:A");
        try testing.expect(binding.action == .esc);
        try testing.expectEqualStrings("A", binding.action.esc);
    }
    {
        const binding = try parseSingle("a=set_surface_title:surface");
        try testing.expect(binding.action == .set_surface_title);
        try testing.expectEqualStrings("surface", binding.action.set_surface_title);
    }
    {
        const binding = try parseSingle("a=set_tab_title:tab");
        try testing.expect(binding.action == .set_tab_title);
        try testing.expectEqualStrings("tab", binding.action.set_tab_title);
    }
}
test "parse: action with enum" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=new_split:right");
        try testing.expect(binding.action == .new_split);
        try testing.expectEqual(Action.SplitDirection.right, binding.action.new_split);
    }
}
test "parse: action with enum with default" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=new_split");
        try testing.expect(binding.action == .new_split);
        try testing.expectEqual(Action.SplitDirection.auto, binding.action.new_split);
    }
}
test "parse: action with int" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=jump_to_prompt:-1");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, -1), binding.action.jump_to_prompt);
    }
    {
        const binding = try parseSingle("a=jump_to_prompt:10");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, 10), binding.action.jump_to_prompt);
    }
}
test "parse: action with float" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=scroll_page_fractional:-0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, -0.5), binding.action.scroll_page_fractional);
    }
    {
        const binding = try parseSingle("a=scroll_page_fractional:+0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, 0.5), binding.action.scroll_page_fractional);
    }
}
test "parse: action with a tuple" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=resize_split:up,10");
        try testing.expect(binding.action == .resize_split);
        try testing.expectEqual(Action.SplitResizeDirection.up, binding.action.resize_split[0]);
        try testing.expectEqual(@as(u16, 10), binding.action.resize_split[1]);
    }
    try testing.expectError(Error.InvalidFormat, parseSingle("a=resize_split:up"));
    try testing.expectError(Error.InvalidFormat, parseSingle("a=resize_split:up,10,12"));
    try testing.expectError(Error.InvalidFormat, parseSingle("a=resize_split:up,four"));
}
test "parse: chain" {
    const testing = std.testing;
    {
        var p = try Parser.init("chain=new_tab");
        try testing.expectEqual(Parser.Elem{
            .chain = .new_tab,
        }, try p.next());
        try testing.expect(try p.next() == null);
    }
    try testing.expectError(error.InvalidFormat, Parser.init("global:chain=ignore"));
    {
        var p = try Parser.init("a>chain=ignore");
        _ = try p.next();
        try testing.expectError(error.InvalidFormat, p.next());
    }
}
test "sequence iterator" {
    const testing = std.testing;
    {
        var it: SequenceIterator = .{ .input = "a" };
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'a' } }, (try it.next()).?);
        try testing.expect(try it.next() == null);
    }
    {
        var it: SequenceIterator = .{ .input = "a>b" };
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'a' } }, (try it.next()).?);
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'b' } }, (try it.next()).?);
        try testing.expect(try it.next() == null);
    }
    {
        var it: SequenceIterator = .{ .input = "" };
        try testing.expectError(Error.InvalidFormat, it.next());
    }
    {
        var it: SequenceIterator = .{ .input = ">a" };
        try testing.expectError(Error.InvalidFormat, it.next());
    }
    {
        var it: SequenceIterator = .{ .input = "a>" };
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'a' } }, (try it.next()).?);
        try testing.expectError(Error.InvalidFormat, it.next());
    }
}
test "parse: sequences" {
    const testing = std.testing;
    {
        var p = try Parser.init("ctrl+a=ignore");
        try testing.expectEqual(Parser.Elem{ .binding = .{
            .trigger = .{
                .mods = .{ .ctrl = true },
                .key = .{ .unicode = 'a' },
            },
            .action = .{ .ignore = {} },
        } }, (try p.next()).?);
        try testing.expect(try p.next() == null);
    }
    {
        var p = try Parser.init("a>b=ignore");
        try testing.expectEqual(Parser.Elem{ .leader = .{
            .key = .{ .unicode = 'a' },
        } }, (try p.next()).?);
        try testing.expectEqual(Parser.Elem{ .binding = .{
            .trigger = .{
                .key = .{ .unicode = 'b' },
            },
            .action = .{ .ignore = {} },
        } }, (try p.next()).?);
        try testing.expect(try p.next() == null);
    }
}
test "set: parseAndPut typical binding" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    {
        const action = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
        try testing.expectEqual(Flags{}, action.flags);
    }
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }
}
test "set: parseAndPut unconsumed binding" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "unconsumed:a=new_window");
    {
        const trigger: Trigger = .{ .key = .{ .unicode = 'a' } };
        const action = s.get(trigger).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
        try testing.expectEqual(Flags{ .consumed = false }, action.flags);
    }
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }
}
test "set: parseAndPut removed binding" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "a=unbind");
    {
        const trigger: Trigger = .{ .key = .{ .unicode = 'a' } };
        try testing.expect(s.get(trigger) == null);
    }
    try testing.expect(s.getTrigger(.{ .new_window = {} }) == null);
    try testing.expect(s.chain_parent == null);
}
test "set: put sets chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }
    try testing.expect(s.chain_parent.?.value_ptr.* == .leaf);
}
test "set: putFlags sets chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .new_window = {} },
        .{ .consumed = false },
    );
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }
    try testing.expect(s.chain_parent.?.value_ptr.* == .leaf);
    try testing.expect(!s.chain_parent.?.value_ptr.*.leaf.flags.consumed);
}
test "set: sequence sets chain_parent to final leaf" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("b", buf.written());
    }
    try testing.expect(s.chain_parent.?.value_ptr.* == .leaf);
    try testing.expect(s.chain_parent.?.value_ptr.*.leaf.action == .new_window);
}
test "set: multiple leaves under leader updates chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("b", buf.written());
    }
    try s.parseAndPut(alloc, "a>c=new_tab");
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("c", buf.written());
    }
    try testing.expect(s.chain_parent.?.value_ptr.*.leaf.action == .new_tab);
}
test "set: sequence unbind clears chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try testing.expect(s.chain_parent != null);
    try s.parseAndPut(alloc, "a>b=unbind");
    try testing.expect(s.chain_parent == null);
}
test "set: sequence unbind with remaining leaves clears chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "a>c=new_tab");
    try s.parseAndPut(alloc, "a>b=unbind");
    try testing.expect(s.chain_parent == null);
    const a_entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(a_entry.value_ptr.* == .leader);
    const inner_set = a_entry.value_ptr.*.leader;
    try testing.expect(inner_set.get(.{ .key = .{ .unicode = 'c' } }) != null);
}
test "set: direct remove clears chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.chain_parent != null);
    s.remove(alloc, .{ .key = .{ .unicode = 'a' } });
    try testing.expect(s.chain_parent == null);
}
test "set: invalid format preserves chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    const before_key = s.chain_parent.?.key_ptr;
    const before_value = s.chain_parent.?.value_ptr;
    try testing.expectError(error.InvalidAction, s.parseAndPut(alloc, "a=invalid_action_xyz"));
    try testing.expect(s.chain_parent != null);
    try testing.expect(s.chain_parent.?.key_ptr == before_key);
    try testing.expect(s.chain_parent.?.value_ptr == before_value);
}
test "set: clone produces null chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try testing.expect(s.chain_parent != null);
    var cloned = try s.clone(alloc);
    defer cloned.deinit(alloc);
    try testing.expect(cloned.chain_parent == null);
    try testing.expect(cloned.get(.{ .key = .{ .unicode = 'a' } }) != null);
}
test "set: clone with leaf_chained" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    try testing.expectEqual(@as(usize, 2), entry.value_ptr.leaf_chained.actions.items.len);
    var cloned = try s.clone(alloc);
    defer cloned.deinit(alloc);
    const cloned_entry = cloned.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(cloned_entry.value_ptr.* == .leaf_chained);
    try testing.expectEqual(@as(usize, 2), cloned_entry.value_ptr.leaf_chained.actions.items.len);
    try testing.expect(cloned_entry.value_ptr.leaf_chained.actions.items[0] == .new_window);
    try testing.expect(cloned_entry.value_ptr.leaf_chained.actions.items[1] == .new_tab);
}
test "set: clone with leaf_chained containing allocated data" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var s: Set = .{};
    try s.parseAndPut(alloc, "a=text:hello");
    try s.parseAndPut(alloc, "chain=text:world");
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    const cloned = try s.clone(alloc);
    const cloned_entry = cloned.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(cloned_entry.value_ptr.* == .leaf_chained);
    try testing.expectEqualStrings("hello", cloned_entry.value_ptr.leaf_chained.actions.items[0].text);
    try testing.expectEqualStrings("world", cloned_entry.value_ptr.leaf_chained.actions.items[1].text);
    try testing.expect(entry.value_ptr.leaf_chained.actions.items[0].text.ptr !=
        cloned_entry.value_ptr.leaf_chained.actions.items[0].text.ptr);
}
test "set: parseAndPut sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}
test "set: parseAndPut sequence with two actions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "a>c=new_tab");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'c' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_tab);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}
test "set: parseAndPut overwrite sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_tab");
    try s.parseAndPut(alloc, "a>b=new_window");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}
test "set: parseAndPut overwrite leader" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_tab");
    try s.parseAndPut(alloc, "a>b=new_window");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}
test "set: parseAndPut unbind sequence unbinds leader" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "a>b=unbind");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        try testing.expect(current.get(t) == null);
    }
}
test "set: parseAndPut unbind sequence unbinds leader if not set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=unbind");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        try testing.expect(current.get(t) == null);
    }
}
test "set: parseAndPut sequence preserves reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "ctrl+a>b=new_window");
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}
test "set: put overwrites sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "ctrl+a>b=new_window");
    try s.put(alloc, .{
        .mods = .{ .ctrl = true },
        .key = .{ .unicode = 'a' },
    }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}
test "set: maintains reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
    try s.put(alloc, .{ .key = .{ .unicode = 'b' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'b');
    }
    s.remove(alloc, .{ .key = .{ .unicode = 'b' } });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}
test "set: performable is not part of reverse mappings" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'b' } },
        .{ .new_window = {} },
        .{ .performable = true },
    );
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
    s.remove(alloc, .{ .key = .{ .unicode = 'b' } });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}
test "set: overriding a mapping updates reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_tab = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} });
        try testing.expect(trigger == null);
    }
}
test "set: consumed state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.* == .leaf);
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf.flags.consumed);
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .new_window = {} },
        .{ .consumed = false },
    );
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.* == .leaf);
    try testing.expect(!s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf.flags.consumed);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.* == .leaf);
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf.flags.consumed);
}
test "set: parseAndPut chain" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    {
        const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
        try testing.expect(entry == .leaf_chained);
        const chained = entry.leaf_chained;
        try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
        try testing.expect(chained.actions.items[0] == .new_window);
        try testing.expect(chained.actions.items[1] == .new_tab);
    }
    {
        try testing.expect(s.getTrigger(.{ .new_window = {} }) == null);
    }
}
test "set: parseAndPut chain without parent is error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try testing.expectError(error.InvalidFormat, s.parseAndPut(alloc, "chain=new_tab"));
}
test "set: parseAndPut chain multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    try s.parseAndPut(alloc, "chain=close_surface");
    {
        const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
        try testing.expect(entry == .leaf_chained);
        const chained = entry.leaf_chained;
        try testing.expectEqual(@as(usize, 3), chained.actions.items.len);
        try testing.expect(chained.actions.items[0] == .new_window);
        try testing.expect(chained.actions.items[1] == .new_tab);
        try testing.expect(chained.actions.items[2] == .close_surface);
    }
}
test "set: parseAndPut chain preserves flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "unconsumed:a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    {
        const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
        try testing.expect(entry == .leaf_chained);
        const chained = entry.leaf_chained;
        try testing.expect(!chained.flags.consumed);
        try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    }
}
test "set: parseAndPut chain after unbind is error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "a=unbind");
    try testing.expectError(error.InvalidFormat, s.parseAndPut(alloc, "chain=new_tab"));
}
test "set: parseAndPut chain on sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    const a_entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
    try testing.expect(a_entry == .leader);
    const inner_set = a_entry.leader;
    const b_entry = inner_set.get(.{ .key = .{ .unicode = 'b' } }).?.value_ptr.*;
    try testing.expect(b_entry == .leaf_chained);
    const chained = b_entry.leaf_chained;
    try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
}
test "set: parseAndPut chain with unbind is error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try testing.expectError(error.InvalidFormat, s.parseAndPut(alloc, "chain=unbind"));
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
    try testing.expect(entry == .leaf);
    try testing.expect(entry.leaf.action == .new_window);
}
test "set: getEvent physical" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "ctrl+quote=new_window");
    {
        const action = s.getEvent(.{
            .key = .quote,
            .mods = .{ .ctrl = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "'",
            .unshifted_codepoint = '\'',
        });
        try testing.expect(action == null);
    }
}
test "set: getEvent codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "ctrl+'=new_window");
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = '\'',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "'",
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
        });
        try testing.expect(action == null);
    }
}
test "set: getEvent codepoint case folding" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "ctrl+A=new_window");
    {
        const action = s.getEvent(.{
            .key = .key_j,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = 'a',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = 'A',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
    {
        const action = s.getEvent(.{
            .key = .key_j,
            .mods = .{ .ctrl = true },
        });
        try testing.expect(action == null);
    }
}
test "set: getEvent catch_all fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "catch_all=ignore");
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{},
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }
    try s.parseAndPut(alloc, "ctrl+b=new_window");
    {
        const action = s.getEvent(.{
            .key = .key_b,
            .mods = .{ .ctrl = true },
            .unshifted_codepoint = 'b',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
}
test "set: getEvent catch_all with modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "ctrl+catch_all=close_surface");
    try s.parseAndPut(alloc, "catch_all=ignore");
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .close_surface);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{},
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .alt = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }
}
test "Action: clone" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var a: Action = .ignore;
        const b = try a.clone(alloc);
        try testing.expect(b == .ignore);
    }
    {
        var a: Action = .{ .text = "foo" };
        const b = try a.clone(alloc);
        try testing.expect(b == .text);
    }
}
test "parse: increase_font_size" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=increase_font_size:1.5");
        try testing.expect(binding.action == .increase_font_size);
        try testing.expectEqual(1.5, binding.action.increase_font_size);
    }
}
test "parse: decrease_font_size" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=decrease_font_size:2.5");
        try testing.expect(binding.action == .decrease_font_size);
        try testing.expectEqual(2.5, binding.action.decrease_font_size);
    }
}
test "parse: reset_font_size" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=reset_font_size");
        try testing.expect(binding.action == .reset_font_size);
    }
}
test "parse: set_font_size" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=set_font_size:13.5");
        try testing.expect(binding.action == .set_font_size);
        try testing.expectEqual(13.5, binding.action.set_font_size);
    }
}
test "parse: copy to clipboard default" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=copy_to_clipboard");
        try testing.expect(binding.action == .copy_to_clipboard);
        try testing.expectEqual(Action.CopyToClipboard.mixed, binding.action.copy_to_clipboard);
    }
}
test "parse: copy to clipboard explicit" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=copy_to_clipboard:html");
        try testing.expect(binding.action == .copy_to_clipboard);
        try testing.expectEqual(Action.CopyToClipboard.html, binding.action.copy_to_clipboard);
    }
}
test "parse: write screen file no format" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=write_screen_file:copy");
        try testing.expect(binding.action == .write_screen_file);
        try testing.expectEqual(Action.WriteScreen.copy, binding.action.write_screen_file);
    }
}
test "parse: write screen file format" {
    const testing = std.testing;
    {
        const binding = try parseSingle("a=write_screen_file:copy,html");
        try testing.expect(binding.action == .write_screen_file);
        try testing.expectEqual(Action.WriteScreen{
            .action = .copy,
            .emit = .html,
        }, binding.action.write_screen_file);
    }
}
test "parse: write screen file format as string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        const binding = try parseSingle("a=write_screen_file:copy,html");
        try binding.action.format(&buf.writer);
        try testing.expectEqualStrings("write_screen_file:copy,html", buf.written());
    }
}
test "parse: write screen file invalid" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:",
    ));
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:,",
    ));
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:copy,",
    ));
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:copy,html,extra",
    ));
}
test "action: format" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const a: Action = .{ .text = "👻Wasp'\"" };
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try a.format(&buf.writer);
    const b = try Binding.Action.parse(buf.written());
    try testing.expect(a.equal(b));
}
test "action: format set title" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const a: Action = .{ .set_tab_title = "foo bar" };
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try a.format(&buf.writer);
    try testing.expectEqualStrings("set_tab_title:foo bar", buf.written());
}
test "set: appendChain with no parent returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try testing.expectError(error.NoChainParent, s.appendChain(alloc, .{ .new_tab = {} }));
}
test "set: appendChain after put converts to leaf_chained" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try s.appendChain(alloc, .{ .new_tab = {} });
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    const chained = entry.value_ptr.*.leaf_chained;
    try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
}
test "set: appendChain after putFlags preserves flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .new_window = {} },
        .{ .consumed = false },
    );
    try s.appendChain(alloc, .{ .new_tab = {} });
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    const chained = entry.value_ptr.*.leaf_chained;
    try testing.expect(!chained.flags.consumed);
    try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
}
test "set: appendChain multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try s.appendChain(alloc, .{ .new_tab = {} });
    try s.appendChain(alloc, .{ .close_surface = {} });
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    const chained = entry.value_ptr.*.leaf_chained;
    try testing.expectEqual(@as(usize, 3), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
    try testing.expect(chained.actions.items[2] == .close_surface);
}
test "set: appendChain removes reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.getTrigger(.{ .new_window = {} }) != null);
    try s.appendChain(alloc, .{ .new_tab = {} });
    try testing.expect(s.getTrigger(.{ .new_window = {} }) == null);
}
test "set: appendChain with performable does not affect reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'b' } }, .{ .new_window = {} });
    try testing.expect(s.getTrigger(.{ .new_window = {} }) != null);
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .close_surface = {} },
        .{ .performable = true },
    );
    try testing.expect(s.getTrigger(.{ .close_surface = {} }) == null);
    try s.appendChain(alloc, .{ .new_tab = {} });
    try testing.expect(s.getTrigger(.{ .new_window = {} }) != null);
}
test "set: appendChain restores next valid reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try s.put(alloc, .{ .key = .{ .unicode = 'b' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'b');
    }
    try s.appendChain(alloc, .{ .new_tab = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}
test "set: formatEntries leaf_chained" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const formatterpkg = @import("../config/formatter.zig");
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try entry.key_ptr.format(&writer);
    try entry.value_ptr.formatEntries(&writer, formatterpkg.entryFormatter("keybind", &output.writer));
    const expected =
        \\keybind = a=new_window
        \\keybind = chain=new_tab
        \\
    ;
    try testing.expectEqualStrings(expected, output.written());
}
test "set: formatEntries leaf_chained multiple chains" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const formatterpkg = @import("../config/formatter.zig");
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "ctrl+a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    try s.parseAndPut(alloc, "chain=close_surface");
    const entry = s.get(.{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    try testing.expectEqual(@as(usize, 3), entry.value_ptr.leaf_chained.actions.items.len);
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try entry.key_ptr.format(&writer);
    try entry.value_ptr.formatEntries(&writer, formatterpkg.entryFormatter("keybind", &output.writer));
    const expected =
        \\keybind = ctrl+a=new_window
        \\keybind = chain=new_tab
        \\keybind = chain=close_surface
        \\
    ;
    try testing.expectEqualStrings(expected, output.written());
}
test "set: formatEntries leaf_chained with text action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const formatterpkg = @import("../config/formatter.zig");
    var s: Set = .{};
    defer s.deinit(alloc);
    try s.parseAndPut(alloc, "a=text:hello");
    try s.parseAndPut(alloc, "chain=text:world");
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try entry.key_ptr.format(&writer);
    try entry.value_ptr.formatEntries(&writer, formatterpkg.entryFormatter("keybind", &output.writer));
    const expected =
        \\keybind = a=text:hello
        \\keybind = chain=text:world
        \\
    ;
    try testing.expectEqualStrings(expected, output.written());
}
