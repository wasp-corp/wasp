const std = @import("std");
const build_config = @import("../build_config.zig");
const assert = @import("../quirks.zig").inlineAssert;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreSurface = @import("../Surface.zig");
const lib = @import("../lib/main.zig");
const compat_testing = @import("../lib/compat/testing.zig");
pub const Target = union(Key) {
    app,
    surface: *CoreSurface,
    pub const Key = enum(c_int) {
        app,
        surface,
        test "wasp.h Target.Key" {
            try lib.checkWaspHEnum(Key, "WASP_TARGET_");
        }
    };
    pub const CValue = extern union {
        app: void,
        surface: *apprt.Surface,
    };
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .app => .{ .app = {} },
                .surface => |v| .{ .surface = v.rt_surface },
            },
        };
    }
};
pub const Action = union(Key) {
    quit,
    new_window,
    new_tab,
    close_tab: CloseTabMode,
    new_split: SplitDirection,
    close_all_windows,
    toggle_maximize,
    toggle_fullscreen: Fullscreen,
    toggle_tab_overview,
    toggle_window_decorations,
    toggle_quick_terminal,
    toggle_command_palette,
    toggle_visibility,
    toggle_background_opacity,
    move_tab: MoveTab,
    goto_tab: GotoTab,
    goto_split: GotoSplit,
    goto_window: GotoWindow,
    resize_split: ResizeSplit,
    equalize_splits,
    toggle_split_zoom,
    present_terminal,
    size_limit: SizeLimit,
    reset_window_size,
    initial_size: InitialSize,
    cell_size: CellSize,
    scrollbar: terminal.Scrollbar,
    render,
    inspector: Inspector,
    show_gtk_inspector,
    render_inspector,
    export_terminal_io: ExportTerminalIO,
    desktop_notification: DesktopNotification,
    set_title: SetTitle,
    set_tab_title: SetTitle,
    set_window_title: SetTitle,
    prompt_title: PromptTitle,
    pwd: Pwd,
    mouse_shape: terminal.MouseShape,
    mouse_visibility: MouseVisibility,
    mouse_over_link: MouseOverLink,
    renderer_health: renderer.Health,
    open_config: OpenConfig,
    quit_timer: QuitTimer,
    float_window: FloatWindow,
    secure_input: SecureInput,
    key_sequence: KeySequence,
    key_table: KeyTable,
    color_change: ColorChange,
    reload_config: ReloadConfig,
    config_change: ConfigChange,
    close_window,
    ring_bell,
    selection_changed,
    undo,
    redo,
    check_for_updates,
    open_url: OpenUrl,
    show_child_exited: apprt.surface.Message.ChildExited,
    progress_report: terminal.osc.Command.ProgressReport,
    show_on_screen_keyboard,
    command_finished: CommandFinished,
    start_search: StartSearch,
    end_search,
    search_total: SearchTotal,
    search_selected: SearchSelected,
    readonly: Readonly,
    copy_title_to_clipboard,
    move_tab_to_new_window,
    resize_window: ResizeWindow,
    pub const Key = enum(c_int) {
        quit,
        new_window,
        new_tab,
        close_tab,
        new_split,
        close_all_windows,
        toggle_maximize,
        toggle_fullscreen,
        toggle_tab_overview,
        toggle_window_decorations,
        toggle_quick_terminal,
        toggle_command_palette,
        toggle_visibility,
        toggle_background_opacity,
        move_tab,
        goto_tab,
        goto_split,
        goto_window,
        resize_split,
        equalize_splits,
        toggle_split_zoom,
        present_terminal,
        size_limit,
        reset_window_size,
        initial_size,
        cell_size,
        scrollbar,
        render,
        inspector,
        show_gtk_inspector,
        render_inspector,
        export_terminal_io,
        desktop_notification,
        set_title,
        set_tab_title,
        set_window_title,
        prompt_title,
        pwd,
        mouse_shape,
        mouse_visibility,
        mouse_over_link,
        renderer_health,
        open_config,
        quit_timer,
        float_window,
        secure_input,
        key_sequence,
        key_table,
        color_change,
        reload_config,
        config_change,
        close_window,
        ring_bell,
        selection_changed,
        undo,
        redo,
        check_for_updates,
        open_url,
        show_child_exited,
        progress_report,
        show_on_screen_keyboard,
        command_finished,
        start_search,
        end_search,
        search_total,
        search_selected,
        readonly,
        copy_title_to_clipboard,
        move_tab_to_new_window,
        resize_window,
        test "wasp.h Action.Key" {
            try lib.checkWaspHEnum(Key, "WASP_ACTION_");
        }
    };
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var names: [key_fields.len][]const u8 = undefined;
        var types: [key_fields.len]type = undefined;
        var attrs: [key_fields.len]std.builtin.Type.UnionField.Attributes = undefined;
        for (key_fields, &names, &types, &attrs) |field, *name, *ty, *attr| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };
            name.* = field.name;
            ty.* = Type;
            attr.* = .{ .@"align" = @alignOf(Type) };
        }
        break :cvalue @Union(.@"extern", null, &names, &types, &attrs);
    };
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };
    comptime {
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 24,
            8 => 24,
            else => unreachable,
        });
    }
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }
        unreachable;
    }
    pub fn cval(self: Action) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval() else v,
            ),
        };
        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};
pub const SplitDirection = enum(c_int) {
    right,
    down,
    left,
    up,
    test "wasp.h SplitDirection" {
        try lib.checkWaspHEnum(SplitDirection, "WASP_SPLIT_DIRECTION_");
    }
};
pub const GotoSplit = enum(c_int) {
    previous,
    next,
    up,
    left,
    down,
    right,
    test "wasp.h GotoSplit" {
        try lib.checkWaspHEnum(GotoSplit, "WASP_GOTO_SPLIT_");
    }
};
pub const GotoWindow = enum(c_int) {
    previous,
    next,
    test "wasp.h GotoWindow" {
        try lib.checkWaspHEnum(GotoWindow, "WASP_GOTO_WINDOW_");
    }
};
pub const ResizeSplit = extern struct {
    amount: u16,
    direction: Direction,
    pub const Direction = enum(c_int) {
        up,
        down,
        left,
        right,
        test "wasp.h ResizeSplit.Direction" {
            try lib.checkWaspHEnum(Direction, "WASP_RESIZE_SPLIT_");
        }
    };
};
pub const MoveTab = extern struct {
    amount: isize,
};
pub const GotoTab = enum(c_int) {
    previous = -1,
    next = -2,
    last = -3,
    _,
};
pub const Fullscreen = enum(c_int) {
    native,
    macos_non_native,
    macos_non_native_visible_menu,
    macos_non_native_padded_notch,
    test "wasp.h Fullscreen" {
        try lib.checkWaspHEnum(Fullscreen, "WASP_FULLSCREEN_");
    }
};
pub const FloatWindow = enum(c_int) {
    on,
    off,
    toggle,
    test "wasp.h FloatWindow" {
        try lib.checkWaspHEnum(FloatWindow, "WASP_FLOAT_WINDOW_");
    }
};
pub const SecureInput = enum(c_int) {
    on,
    off,
    toggle,
    test "wasp.h SecureInput" {
        try lib.checkWaspHEnum(SecureInput, "WASP_SECURE_INPUT_");
    }
};
pub const Inspector = enum(c_int) {
    toggle,
    show,
    hide,
    test "wasp.h Inspector" {
        try lib.checkWaspHEnum(Inspector, "WASP_INSPECTOR_");
    }
};
pub const ExportTerminalIO = struct {
    contents: []const u8,
    pub const C = extern struct {
        contents: [*]const u8,
        len: usize,
    };
    pub fn cval(self: ExportTerminalIO) C {
        return .{
            .contents = self.contents.ptr,
            .len = self.contents.len,
        };
    }
    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            "{s}{{ contents: {d} bytes }}",
            .{ @typeName(@This()), value.contents.len },
        );
    }
};
pub const QuitTimer = enum(c_int) {
    start,
    stop,
    test "wasp.h QuitTimer" {
        try lib.checkWaspHEnum(QuitTimer, "WASP_QUIT_TIMER_");
    }
};
pub const Readonly = enum(c_int) {
    off,
    on,
    test "wasp.h Readonly" {
        try lib.checkWaspHEnum(Readonly, "WASP_READONLY_");
    }
};
pub const MouseVisibility = enum(c_int) {
    visible,
    hidden,
    test "wasp.h MouseVisibility" {
        try lib.checkWaspHEnum(MouseVisibility, "WASP_MOUSE_");
    }
};
pub const PromptTitle = enum(c_int) {
    surface,
    tab,
    window,
    test "wasp.h PromptTitle" {
        try lib.checkWaspHEnum(PromptTitle, "WASP_PROMPT_TITLE_");
    }
};
pub const MouseOverLink = struct {
    url: [:0]const u8,
    pub const C = extern struct {
        url: [*]const u8,
        len: usize,
    };
    pub fn cval(self: MouseOverLink) C {
        return .{
            .url = self.url.ptr,
            .len = self.url.len,
        };
    }
};
pub const SizeLimit = extern struct {
    min_width: u32,
    min_height: u32,
    max_width: u32,
    max_height: u32,
};
pub const InitialSize = extern struct {
    width: u32,
    height: u32,
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            InitialSize,
            .{ .name = "WaspApprtInitialSize" },
        ),
        .none => void,
    };
};
pub const ResizeWindow = extern struct {
    width: u32,
    height: u32,
};
pub const CellSize = extern struct {
    width: u32,
    height: u32,
};
pub const SetTitle = struct {
    title: [:0]const u8,
    pub const C = extern struct {
        title: [*:0]const u8,
    };
    pub fn cval(self: SetTitle) C {
        return .{
            .title = self.title.ptr,
        };
    }
    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.title });
    }
};
pub const Pwd = struct {
    pwd: [:0]const u8,
    pub const C = extern struct {
        pwd: [*:0]const u8,
    };
    pub fn cval(self: Pwd) C {
        return .{
            .pwd = self.pwd.ptr,
        };
    }
    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.pwd });
    }
};
pub const DesktopNotification = struct {
    title: [:0]const u8,
    body: [:0]const u8,
    pub const C = extern struct {
        title: [*:0]const u8,
        body: [*:0]const u8,
    };
    pub fn cval(self: DesktopNotification) C {
        return .{
            .title = self.title.ptr,
            .body = self.body.ptr,
        };
    }
    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ title: {s}, body: {s} }}", .{
            @typeName(@This()),
            value.title,
            value.body,
        });
    }
};
pub const KeySequence = union(enum) {
    trigger: input.Trigger,
    end,
    pub const C = extern struct {
        active: bool,
        trigger: input.Trigger.C,
    };
    pub fn cval(self: KeySequence) C {
        return switch (self) {
            .trigger => |t| .{ .active = true, .trigger = t.cval() },
            .end => .{ .active = false, .trigger = .{} },
        };
    }
};
pub const KeyTable = union(enum) {
    activate: []const u8,
    deactivate,
    deactivate_all,
    pub const Tag = enum(c_int) {
        activate,
        deactivate,
        deactivate_all,
    };
    pub const CValue = extern union {
        activate: extern struct {
            name: [*]const u8,
            len: usize,
        },
    };
    pub const C = extern struct {
        tag: Tag,
        value: CValue,
    };
    pub fn cval(self: KeyTable) C {
        return switch (self) {
            .activate => |name| .{
                .tag = .activate,
                .value = .{ .activate = .{ .name = name.ptr, .len = name.len } },
            },
            .deactivate => .{
                .tag = .deactivate,
                .value = undefined,
            },
            .deactivate_all => .{
                .tag = .deactivate_all,
                .value = undefined,
            },
        };
    }
};
pub const ColorChange = extern struct {
    kind: ColorKind,
    r: u8,
    g: u8,
    b: u8,
};
pub const ColorKind = enum(c_int) {
    foreground = -1,
    background = -2,
    cursor = -3,
    _,
};
pub const ReloadConfig = extern struct {
    soft: bool = false,
};
pub const ConfigChange = struct {
    config: *const configpkg.Config,
    pub const C = extern struct {
        config: *const configpkg.Config,
    };
    pub fn cval(self: ConfigChange) C {
        return .{
            .config = self.config,
        };
    }
};
pub const OpenUrl = struct {
    kind: Kind,
    url: []const u8,
    pub const Kind = enum(c_int) {
        unknown,
        text,
        html,
        osc8,
        test "wasp.h OpenUrl.Kind" {
            try lib.checkWaspHEnum(Kind, "WASP_ACTION_OPEN_URL_KIND_");
        }
    };
    pub const C = extern struct {
        kind: Kind,
        url: [*]const u8,
        len: usize,
    };
    pub fn cval(self: OpenUrl) C {
        return .{
            .kind = self.kind,
            .url = self.url.ptr,
            .len = self.url.len,
        };
    }
};
pub const CloseTabMode = enum(c_int) {
    this,
    other,
    right,
    test "wasp.h CloseTabMode" {
        try lib.checkWaspHEnum(CloseTabMode, "WASP_ACTION_CLOSE_TAB_MODE_");
    }
};
pub const CommandFinished = struct {
    exit_code: ?u8,
    duration: configpkg.Config.Duration,
    pub const C = extern struct {
        exit_code: i16,
        duration: u64,
    };
    pub fn cval(self: CommandFinished) C {
        return .{
            .exit_code = self.exit_code orelse -1,
            .duration = self.duration.duration,
        };
    }
};
pub const StartSearch = struct {
    needle: [:0]const u8,
    pub const C = extern struct {
        needle: [*:0]const u8,
    };
    pub fn cval(self: StartSearch) C {
        return .{
            .needle = self.needle.ptr,
        };
    }
};
pub const SearchTotal = struct {
    total: ?usize,
    pub const C = extern struct {
        total: isize,
    };
    pub fn cval(self: SearchTotal) C {
        return .{
            .total = if (self.total) |t| @intCast(t) else -1,
        };
    }
};
pub const SearchSelected = struct {
    selected: ?usize,
    pub const C = extern struct {
        selected: isize,
    };
    pub fn cval(self: SearchSelected) C {
        return .{
            .selected = if (self.selected) |s| @intCast(s) else -1,
        };
    }
};
pub const OpenConfig = enum(c_int) {
    os_open,
    new_window,
    test "wasp.h OpenConfig" {
        try lib.checkWaspHEnum(OpenConfig, "WASP_ACTION_OPEN_CONFIG_");
    }
};
test {
    _ = compat_testing.refAllDeclsRecursive(@This());
}
