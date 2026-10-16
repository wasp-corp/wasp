const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const c_abi = @import("../../lib/c_abi.zig");
const color = @import("../color.zig");
const clipboard = @import("../clipboard.zig");
const device_status = @import("../device_status.zig");
const focus_pkg = @import("../focus.zig");
const formatter_pkg = @import("../formatter.zig");
const modes_pkg = @import("../modes.zig");
const mouse_pkg = @import("../mouse.zig");
const page = @import("../page.zig");
const point = @import("../point.zig");
const Selection = @import("../Selection.zig");
const sgr = @import("../sgr.zig");
const input_config = @import("../../input/config.zig");
const input_key = @import("../../input/key.zig");
const input_mouse = @import("../../input/mouse.zig");
const build_info = @import("build_info.zig");
const cell = @import("cell.zig");
const color_c = @import("color.zig");
const formatter = @import("formatter.zig");
const grid_ref = @import("grid_ref.zig");
const io = @import("io.zig");
const key_encode = @import("key_encode.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const mouse_encode = @import("mouse_encode.zig");
const mouse_event = @import("mouse_event.zig");
const osc = @import("osc.zig");
const paste = @import("paste.zig");
const render = @import("render.zig");
const result = @import("result.zig");
const row = @import("row.zig");
const search = @import("search.zig");
const selection = @import("selection.zig");
const selection_gesture = @import("selection_gesture.zig");
const size_report = @import("size_report.zig");
const snapshot = @import("snapshot.zig");
const style = @import("style.zig");
const sys = @import("sys.zig");
const terminal = @import("terminal.zig");
pub const SurfacePosition = extern struct {
    x: f64,
    y: f64,
};
pub const Codepoints = extern struct {
    ptr: ?[*]const u32 = null,
    len: usize = 0,
};
const TypeDecl = struct {
    name: []const u8,
    T: type,
    kind: Kind,
    prefix: []const u8 = "",
    sentinel_suffix: []const u8 = "MAX_VALUE",
    alias_type: []const u8 = "",
    tagged_union: ?TaggedUnion = null,
    union_field_names_T: ?type = null,
    const Kind = enum {
        @"struct",
        @"union",
        @"enum",
        @"packed",
        alias,
        @"opaque",
    };
    const TaggedUnion = struct {
        tag_field: []const u8,
        value_field: []const u8,
        arm_source: ArmSource,
        const ArmSource = enum {
            fields,
            generated,
        };
    };
    fn initStruct(comptime name: []const u8, comptime T: type) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"struct" };
    }
    fn initTaggedStruct(
        comptime name: []const u8,
        comptime T: type,
        comptime tag_field: []const u8,
        comptime value_field: []const u8,
        comptime arm_source: TaggedUnion.ArmSource,
    ) TypeDecl {
        return .{
            .name = name,
            .T = T,
            .kind = .@"struct",
            .tagged_union = .{
                .tag_field = tag_field,
                .value_field = value_field,
                .arm_source = arm_source,
            },
        };
    }
    fn initUnion(
        comptime name: []const u8,
        comptime T: type,
        comptime field_names_T: ?type,
    ) TypeDecl {
        return .{
            .name = name,
            .T = T,
            .kind = .@"union",
            .union_field_names_T = field_names_T,
        };
    }
    fn initEnum(
        comptime name: []const u8,
        comptime T: type,
        comptime prefix: []const u8,
    ) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"enum", .prefix = prefix };
    }
    fn initEnumSentinel(
        comptime name: []const u8,
        comptime T: type,
        comptime prefix: []const u8,
        comptime sentinel_suffix: []const u8,
    ) TypeDecl {
        return .{
            .name = name,
            .T = T,
            .kind = .@"enum",
            .prefix = prefix,
            .sentinel_suffix = sentinel_suffix,
        };
    }
    fn initPacked(comptime name: []const u8, comptime T: type) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"packed" };
    }
    fn initAlias(
        comptime name: []const u8,
        comptime T: type,
        comptime alias_type: []const u8,
    ) TypeDecl {
        return .{ .name = name, .T = T, .kind = .alias, .alias_type = alias_type };
    }
    fn initOpaque(comptime name: []const u8) TypeDecl {
        return .{ .name = name, .T = *anyopaque, .kind = .@"opaque" };
    }
};
const type_decls = [_]TypeDecl{
    .initStruct("WaspAllocator", lib.alloc.Allocator),
    .initStruct("WaspAllocatorVtable", lib.alloc.VTable),
    .initStruct("WaspBuffer", lib.Buffer),
    .initStruct("WaspCellsView", cell.CellsView),
    .initStruct("WaspClipboardContent", terminal.ClipboardContent),
    .initStruct("WaspClipboardRead", terminal.ClipboardRead),
    .initStruct("WaspClipboardReadReply", terminal.ClipboardReadReply),
    .initStruct("WaspClipboardWrite", terminal.ClipboardWrite),
    .initStruct("WaspClipboardWriteReply", terminal.ClipboardWriteReply),
    .initStruct("WaspCodepoints", Codepoints),
    .initStruct("WaspColorPaletteMask", color_c.PaletteMask),
    .initStruct("WaspColorRgb", color.RGB.C),
    .initStruct("WaspColorX11Entry", color_c.X11Entry),
    .initStruct("WaspDeviceAttributes", terminal.DeviceAttributes),
    .initStruct("WaspDeviceAttributesPrimary", terminal.DeviceAttributes.Primary),
    .initStruct("WaspDeviceAttributesSecondary", terminal.DeviceAttributes.Secondary),
    .initStruct("WaspDeviceAttributesTertiary", terminal.DeviceAttributes.Tertiary),
    .initStruct("WaspFormatterScreenExtra", formatter.ScreenOptions.Extra),
    .initStruct("WaspFormatterTerminalExtra", formatter.TerminalOptions.Extra),
    .initStruct("WaspFormatterTerminalOptions", formatter.TerminalOptions),
    .initStruct("WaspGridRef", grid_ref.CGridRef),
    .initStruct("WaspKittyGraphicsPlacementRenderInfo", kitty_graphics.PlacementRenderInfo),
    .initStruct("WaspMimeReader", io.MimeReader),
    .initStruct("WaspMouseEncoderSize", mouse_encode.Size),
    .initStruct("WaspMousePosition", mouse_event.Position),
    .initStruct("WaspPaste", paste.Request),
    .initTaggedStruct("WaspPoint", point.Point.C, "tag", "value", .generated),
    .initStruct("WaspPointCoordinate", point.Coordinate),
    .initUnion("WaspPointValue", point.Point.CValue, point.Point.C),
    .initStruct("WaspReader", io.Reader),
    .initStruct("WaspRenderStateColors", render.Colors),
    .initStruct("WaspRenderStateCursor", render.Cursor),
    .initStruct("WaspRenderStateOverscan", render.Overscan),
    .initStruct("WaspRenderStateRowId", render.RowId),
    .initStruct("WaspRenderStateRowSelection", render.RowSelection),
    .initStruct("WaspSelection", selection.CSelection),
    .initStruct("WaspSelectionBuffer", selection.CSelectionBuffer),
    .initStruct("WaspSelectionGestureBehaviors", selection_gesture.Behaviors),
    .initStruct("WaspSelectionGestureGeometry", selection_gesture.Geometry),
    .initTaggedStruct("WaspSgrAttribute", sgr.Attribute.C, "tag", "value", .generated),
    .initStruct("WaspSgrUnknown", sgr.Attribute.Unknown.C),
    .initUnion("WaspSgrAttributeValue", sgr.Attribute.CValue, sgr.Attribute.C),
    .initStruct("WaspSizeReportSize", size_report.Size),
    .initStruct("WaspString", lib.String),
    .initStruct("WaspSurfacePosition", SurfacePosition),
    .initStruct("WaspStyle", style.Style),
    .initTaggedStruct("WaspStyleColor", style.Color, "tag", "value", .fields),
    .initUnion("WaspStyleColorValue", style.ColorValue, null),
    .initStruct("WaspSysImage", sys.Image),
    .initStruct("WaspTerminalDesktopNotification", terminal.DesktopNotification),
    .initStruct("WaspTerminalMemoryUsage", terminal.TerminalMemoryUsage),
    .initStruct("WaspTerminalModeConfig", terminal.ModeConfig),
    .initStruct("WaspTerminalProgramStatus", terminal.ProgramStatus),
    .initStruct("WaspTerminalProgressReport", terminal.ProgressReport),
    .initTaggedStruct("WaspTerminalResizeWindow", terminal.ResizeWindow.C, "tag", "value", .generated),
    .initStruct("WaspTerminalResizeWindowGrid", terminal.ResizeWindowGrid),
    .initUnion(
        "WaspTerminalResizeWindowValue",
        terminal.ResizeWindow.CValue,
        terminal.ResizeWindow.C,
    ),
    .initStruct("WaspTerminalScrollbar", terminal.TerminalScrollbar),
    .initStruct("WaspTerminalSemanticPrompt", terminal.SemanticPrompt),
    .initTaggedStruct("WaspTerminalScrollViewport", terminal.ScrollViewport, "tag", "value", .generated),
    .initUnion(
        "WaspTerminalScrollViewportValue",
        terminal.ZigTerminal.ScrollViewport.CValue,
        terminal.ZigTerminal.ScrollViewport.C,
    ),
    .initStruct("WaspTerminalSelectLineOptions", selection.SelectLineOptions),
    .initStruct("WaspTerminalSelectWordBetweenOptions", selection.SelectWordBetweenOptions),
    .initStruct("WaspTerminalSelectWordOptions", selection.SelectWordOptions),
    .initStruct("WaspTerminalSelectionFormatOptions", selection.FormatOptions),
    .initTaggedStruct("WaspTerminalUnknownSequence", terminal.UnknownSequence.C, "tag", "value", .generated),
    .initStruct("WaspTerminalUnknownOscSequence", terminal.UnknownOscSequence),
    .initStruct("WaspTerminalUnknownStringSequence", terminal.UnknownStringSequence),
    .initUnion(
        "WaspTerminalUnknownSequenceValue",
        terminal.UnknownSequence.CValue,
        terminal.UnknownSequence.C,
    ),
    .initStruct("WaspWriter", io.Writer),
    .initEnumSentinel("WaspResult", result.Result, "WASP_", "RESULT_MAX_VALUE"),
    .initEnum("WaspBuildInfo", build_info.BuildInfo, "WASP_BUILD_INFO_"),
    .initEnumSentinel("WaspOptimizeMode", build_info.OptimizeMode, "WASP_OPTIMIZE_", "MODE_MAX_VALUE"),
    .initEnumSentinel("WaspCellContentTag", cell.ContentTag, "WASP_CELL_CONTENT_", "TAG_MAX_VALUE"),
    .initEnum("WaspCellData", cell.CellData, "WASP_CELL_DATA_"),
    .initEnum("WaspCellSemanticContent", cell.SemanticContent, "WASP_CELL_SEMANTIC_"),
    .initEnum("WaspCellWide", cell.Wide, "WASP_CELL_WIDE_"),
    .initEnum("WaspClipboardLocation", clipboard.Location, "WASP_CLIPBOARD_LOCATION_"),
    .initEnum("WaspClipboardReadResult", clipboard.Read.Status, "WASP_CLIPBOARD_READ_RESULT_"),
    .initEnum("WaspClipboardWriteResult", clipboard.Write.Status, "WASP_CLIPBOARD_WRITE_RESULT_"),
    .initEnum("WaspColorScheme", device_status.ColorScheme, "WASP_COLOR_SCHEME_"),
    .initEnum("WaspFocusEvent", focus_pkg.Event, "WASP_FOCUS_"),
    .initEnum("WaspFormatterFormat", formatter_pkg.Format, "WASP_FORMATTER_FORMAT_"),
    .initEnum("WaspKey", input_key.Key, "WASP_KEY_"),
    .initEnum("WaspKeyAction", input_key.Action, "WASP_KEY_ACTION_"),
    .initEnum("WaspKeyEncoderOption", key_encode.Option, "WASP_KEY_ENCODER_OPT_"),
    .initEnum("WaspKittyGraphicsData", kitty_graphics.Data, "WASP_KITTY_GRAPHICS_DATA_"),
    .initEnum("WaspKittyGraphicsImageData", kitty_graphics.ImageData, "WASP_KITTY_IMAGE_DATA_"),
    .initEnum("WaspKittyGraphicsPlacementData", kitty_graphics.PlacementData, "WASP_KITTY_GRAPHICS_PLACEMENT_DATA_"),
    .initEnum("WaspKittyGraphicsPlacementIteratorOption", kitty_graphics.PlacementIteratorOption, "WASP_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_"),
    .initEnum("WaspKittyImageCompression", kitty_graphics.ImageCompression, "WASP_KITTY_IMAGE_COMPRESSION_"),
    .initEnum("WaspKittyImageFormat", kitty_graphics.ImageFormat, "WASP_KITTY_IMAGE_FORMAT_"),
    .initEnum("WaspKittyPlacementLayer", kitty_graphics.PlacementLayer, "WASP_KITTY_PLACEMENT_LAYER_"),
    .initEnum("WaspModeReportState", modes_pkg.Report.State, "WASP_MODE_REPORT_"),
    .initEnum("WaspMouseAction", input_mouse.Action, "WASP_MOUSE_ACTION_"),
    .initEnum("WaspMouseButton", input_mouse.Button, "WASP_MOUSE_BUTTON_"),
    .initEnum("WaspMouseEncoderOption", mouse_encode.Option, "WASP_MOUSE_ENCODER_OPT_"),
    .initEnum("WaspMouseFormat", mouse_pkg.Format, "WASP_MOUSE_FORMAT_"),
    .initEnum("WaspMouseShape", mouse_pkg.Shape, "WASP_MOUSE_SHAPE_"),
    .initEnum("WaspMouseTrackingMode", mouse_pkg.Event, "WASP_MOUSE_TRACKING_"),
    .initEnum("WaspOptionAsAlt", input_config.OptionAsAlt, "WASP_OPTION_AS_ALT_"),
    .initEnum("WaspOscCommandData", osc.CommandData, "WASP_OSC_DATA_"),
    .initEnum("WaspOscOption", osc.Option, "WASP_OSC_OPT_"),
    .initEnum("WaspOscTerminator", osc.Terminator, "WASP_OSC_TERMINATOR_"),
    .initEnumSentinel(
        "WaspOscCommandType",
        osc.CommandType,
        "WASP_OSC_COMMAND_",
        "TYPE_MAX_VALUE",
    ),
    .initEnum("WaspPasteSource", paste.Source, "WASP_PASTE_SOURCE_"),
    .initEnum("WaspPointTag", point.Tag, "WASP_POINT_TAG_"),
    .initEnum("WaspProgramStatusKind", terminal.ProgramStatusKind, "WASP_PROGRAM_STATUS_KIND_"),
    .initEnum("WaspProgramStatusState", terminal.ProgramStatusState, "WASP_PROGRAM_STATUS_STATE_"),
    .initEnum("WaspRenderStateCursorVisualStyle", render.CursorVisualStyle, "WASP_RENDER_STATE_CURSOR_VISUAL_STYLE_"),
    .initEnum("WaspRenderStateData", render.Data, "WASP_RENDER_STATE_DATA_"),
    .initEnum("WaspRenderStateDirty", render.Dirty, "WASP_RENDER_STATE_DIRTY_"),
    .initEnum("WaspRenderStateOption", render.SetOption, "WASP_RENDER_STATE_OPTION_"),
    .initEnum("WaspRenderStateRowCellsData", render.RowCellsData, "WASP_RENDER_STATE_ROW_CELLS_DATA_"),
    .initEnum("WaspRenderStateRowData", render.RowData, "WASP_RENDER_STATE_ROW_DATA_"),
    .initEnum("WaspRenderStateRowOption", render.RowOption, "WASP_RENDER_STATE_ROW_OPTION_"),
    .initEnum("WaspRowData", row.RowData, "WASP_ROW_DATA_"),
    .initEnum("WaspRowSemanticPrompt", row.SemanticPrompt, "WASP_ROW_SEMANTIC_"),
    .initEnum("WaspSearchData", search.Data, "WASP_SEARCH_DATA_"),
    .initEnum("WaspSearchOption", search.Option, "WASP_SEARCH_OPT_"),
    .initEnum("WaspSearchScroll", search.Scroll, "WASP_SEARCH_SCROLL_"),
    .initEnum("WaspSearchStatus", search.Status, "WASP_SEARCH_STATUS_"),
    .initEnum("WaspSelectionAdjust", Selection.Adjustment, "WASP_SELECTION_ADJUST_"),
    .initEnum("WaspSelectionGestureAutoscroll", selection_gesture.Autoscroll, "WASP_SELECTION_GESTURE_AUTOSCROLL_"),
    .initEnum("WaspSelectionGestureBehavior", selection_gesture.Behavior, "WASP_SELECTION_GESTURE_BEHAVIOR_"),
    .initEnum("WaspSelectionGestureData", selection_gesture.Data, "WASP_SELECTION_GESTURE_DATA_"),
    .initEnum("WaspSelectionGestureEventOption", selection_gesture.EventOption, "WASP_SELECTION_GESTURE_EVENT_OPT_"),
    .initEnum("WaspSelectionGestureEventType", selection_gesture.EventType, "WASP_SELECTION_GESTURE_EVENT_TYPE_"),
    .initEnum("WaspSelectionOrder", Selection.Order, "WASP_SELECTION_ORDER_"),
    .initEnum("WaspSemanticPromptKind", terminal.SemanticPromptKind, "WASP_SEMANTIC_PROMPT_"),
    .initEnum("WaspSemanticPromptPromptKind", terminal.SemanticPromptPromptKind, "WASP_SEMANTIC_PROMPT_PROMPT_"),
    .initEnum("WaspSgrAttributeTag", sgr.Attribute.Tag, "WASP_SGR_ATTR_"),
    .initEnum("WaspSgrUnderline", sgr.Attribute.Underline, "WASP_SGR_UNDERLINE_"),
    .initEnumSentinel("WaspSizeReportStyle", size_report.Style, "WASP_SIZE_REPORT_", "STYLE_MAX_VALUE"),
    .initEnum("WaspSnapshotDecoderData", snapshot.DecoderData, "WASP_SNAPSHOT_DECODER_DATA_"),
    .initEnum("WaspSnapshotDecoderOption", snapshot.DecoderOption, "WASP_SNAPSHOT_DECODER_OPT_"),
    .initEnumSentinel("WaspStyleColorTag", style.ColorTag, "WASP_STYLE_COLOR_", "TAG_MAX_VALUE"),
    .initEnum("WaspSysLogLevel", sys.LogLevel, "WASP_SYS_LOG_LEVEL_"),
    .initEnum("WaspSysOption", sys.Option, "WASP_SYS_OPT_"),
    .initEnum("WaspTerminalCompressionMode", terminal.CompressionMode, "WASP_TERMINAL_COMPRESSION_MODE_"),
    .initEnum("WaspTerminalCompressionResult", terminal.CompressionResult, "WASP_TERMINAL_COMPRESSION_RESULT_"),
    .initEnum("WaspTerminalCursorStyle", terminal.TerminalCursorStyle, "WASP_TERMINAL_CURSOR_STYLE_"),
    .initEnum("WaspTerminalData", terminal.TerminalData, "WASP_TERMINAL_DATA_"),
    .initEnum("WaspTerminalOption", terminal.Option, "WASP_TERMINAL_OPT_"),
    .initEnum("WaspTerminalProgressState", terminal.ProgressState, "WASP_TERMINAL_PROGRESS_STATE_"),
    .initEnum("WaspTerminalScreen", terminal.TerminalScreen, "WASP_TERMINAL_SCREEN_"),
    .initEnum("WaspTerminalResizeWindowTag", terminal.ResizeWindow.Tag, "WASP_TERMINAL_RESIZE_WINDOW_"),
    .initEnum("WaspTerminalScrollViewportTag", terminal.ZigTerminal.ScrollViewport.Tag, "WASP_SCROLL_VIEWPORT_"),
    .initEnum("WaspTerminalUnknownSequenceTag", terminal.UnknownSequence.Tag, "WASP_TERMINAL_UNKNOWN_SEQUENCE_"),
    .initPacked("WaspCell", page.Cell.CLayout),
    .initAlias("WaspColorPaletteIndex", u8, "u8"),
    .initAlias("WaspKittyKeyFlags", u8, "u8"),
    .initAlias("WaspMode", u16, "u16"),
    .initAlias("WaspMods", u16, "u16"),
    .initAlias("WaspRow", u64, "u64"),
    .initAlias("WaspStyleId", u16, "u16"),
    .initOpaque("WaspFormatter"),
    .initOpaque("WaspKeyEncoder"),
    .initOpaque("WaspKeyEvent"),
    .initOpaque("WaspKittyGraphics"),
    .initOpaque("WaspKittyGraphicsImage"),
    .initOpaque("WaspKittyGraphicsPlacementIterator"),
    .initOpaque("WaspMouseEncoder"),
    .initOpaque("WaspMouseEvent"),
    .initOpaque("WaspOscCommand"),
    .initOpaque("WaspOscParser"),
    .initOpaque("WaspRenderState"),
    .initOpaque("WaspRenderStateRowCells"),
    .initOpaque("WaspRenderStateRowIterator"),
    .initOpaque("WaspSearch"),
    .initOpaque("WaspSelectionGesture"),
    .initOpaque("WaspSelectionGestureEvent"),
    .initOpaque("WaspSgrParser"),
    .initOpaque("WaspSnapshotDecoder"),
    .initOpaque("WaspTerminal"),
    .initOpaque("WaspTrackedGridRef"),
};
comptime {
    @setEvalBranchQuota(100_000);
    for (type_decls, 0..) |decl, i| {
        for (type_decls[0..i]) |previous| {
            if (std.mem.eql(u8, decl.name, previous.name))
                @compileError("duplicate public ABI type: " ++ decl.name);
        }
    }
}
pub const json: [:0]const u8 = json: {
    @setEvalBranchQuota(1_000_000);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    Json.writeAll(&counter.writer) catch unreachable;
    var buf: [counter.count:0]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    Json.writeAll(&writer) catch unreachable;
    const final = buf;
    break :json final[0..writer.end :0];
};
pub fn get_json() callconv(lib.calling_conv) [*:0]const u8 {
    return json.ptr;
}
const Json = struct {
    fn writeAll(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var jws: std.json.Stringify = .{ .writer = writer };
        try jws.beginObject();
        try jws.objectField("schema");
        try jws.write(1);
        try jws.objectField("abi");
        try jws.beginObject();
        try jws.objectField("target");
        try jws.write(@tagName(builtin.target.cpu.arch));
        try jws.objectField("os");
        try jws.write(@tagName(builtin.target.os.tag));
        try jws.objectField("environment");
        try jws.write(@tagName(builtin.target.abi));
        try jws.objectField("pointer_size");
        try jws.write(@sizeOf(*anyopaque));
        try jws.objectField("usize_size");
        try jws.write(@sizeOf(usize));
        try jws.objectField("max_alignment");
        try jws.write(c_abi.max_alignment);
        try jws.objectField("endian");
        try jws.write(@tagName(builtin.target.cpu.arch.endian()));
        try jws.endObject();
        try jws.objectField("library_version");
        try jws.write(build_options.version_string);
        try jws.objectField("commit");
        if (build_options.version_build) |commit| try jws.write(commit) else try jws.write(null);
        try jws.objectField("dirty");
        try jws.write(null);
        try jws.objectField("types");
        try jws.beginObject();
        inline for (type_decls) |decl| {
            try jws.objectField(decl.name);
            try writeType(decl, &jws);
        }
        try jws.endObject();
        try jws.endObject();
    }
    fn writeType(comptime decl: TypeDecl, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        try jws.beginObject();
        try jws.objectField("kind");
        try jws.write(@tagName(decl.kind));
        switch (decl.kind) {
            .@"struct", .@"union" => {
                try writeSizeAlign(decl.T, jws);
                try jws.objectField("fields");
                try jws.beginObject();
                if (decl.union_field_names_T != null) {
                    try writeMappedUnionFields(decl, jws);
                } else {
                    const fields = switch (decl.kind) {
                        .@"struct" => @typeInfo(decl.T).@"struct".fields,
                        .@"union" => @typeInfo(decl.T).@"union".fields,
                        else => unreachable,
                    };
                    inline for (fields) |field| {
                        try writeField(
                            decl,
                            field.name,
                            field.type,
                            if (decl.kind == .@"union") 0 else @offsetOf(decl.T, field.name),
                            jws,
                        );
                    }
                }
                try jws.endObject();
            },
            .@"enum" => {
                try writeSizeAlign(c_int, jws);
                try jws.objectField("underlying");
                try jws.write("i32");
                try jws.objectField("prefix");
                try jws.write(decl.prefix);
                try jws.objectField("values");
                try jws.beginObject();
                inline for (@typeInfo(decl.T).@"enum".fields) |field| {
                    try writeEnumObjectField(decl.name, field.name, jws);
                    try jws.write(field.value);
                }
                try jws.objectField(decl.sentinel_suffix);
                try jws.write(std.math.maxInt(c_int));
                try jws.endObject();
            },
            .@"packed" => try writePackedType(decl.T, jws),
            .alias => {
                try writeSizeAlign(decl.T, jws);
                try jws.objectField("type");
                try jws.write(decl.alias_type);
            },
            .@"opaque" => try writeSizeAlign(*anyopaque, jws),
        }
        try jws.endObject();
    }
    fn writePackedType(
        comptime Layout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try writeSizeAlign(Layout.Zig, jws);
        try jws.objectField("underlying");
        try jws.write(publicTypeName(Layout.Backing));
        try jws.objectField("bits");
        try jws.beginObject();
        try writePackedBits(Layout, jws);
        try jws.endObject();
    }
    fn writePackedBits(
        comptime Layout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        inline for (@typeInfo(Layout.Zig).@"struct".fields) |field| {
            const field_tag = @field(Layout.Field, field.name);
            const name = comptime Layout.fieldName(field_tag) orelse continue;
            const options = Layout.fieldOptions(field_tag);
            try jws.objectField(name);
            try jws.beginObject();
            try jws.objectField("lsb");
            try jws.write(Layout.bitOffset(field_tag));
            try jws.objectField("width");
            try jws.write(Layout.bitWidth(field_tag));
            switch (options.encoding) {
                .scalar => {
                    try jws.objectField("type");
                    try jws.write(options.type_name orelse publicTypeName(field.type));
                },
                .@"packed" => |Nested| {
                    try jws.objectField("kind");
                    try jws.write("packed");
                    try jws.objectField("bits");
                    try jws.beginObject();
                    try writePackedBits(Nested, jws);
                    try jws.endObject();
                },
                .tagged_union => |UnionLayout| try writePackedTaggedUnion(Layout, UnionLayout, jws),
            }
            try jws.endObject();
        }
    }
    fn writePackedTaggedUnion(
        comptime Layout: type,
        comptime UnionLayout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.objectField("kind");
        try jws.write("union");
        try jws.objectField("tag");
        try jws.write(Layout.fieldName(UnionLayout.tag_field).?);
        try jws.objectField("arms");
        try jws.beginObject();
        const tag_options = Layout.fieldOptions(UnionLayout.tag_field);
        const tag_type_name = tag_options.type_name orelse publicTypeName(UnionLayout.Tag);
        inline for (@typeInfo(UnionLayout.Tag).@"enum".fields) |tag| {
            try writeEnumObjectField(tag_type_name, tag.name, jws);
            const arm = UnionLayout.arm(@field(UnionLayout.Tag, tag.name)) orelse {
                try jws.write(null);
                continue;
            };
            switch (arm) {
                inline else => |ArmLayout| try writePackedArm(ArmLayout, jws),
            }
        }
        try jws.endObject();
    }
    fn writePackedArm(
        comptime Layout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.beginObject();
        try jws.objectField("kind");
        try jws.write("packed");
        try jws.objectField("width");
        try jws.write(@bitSizeOf(Layout.Zig));
        try jws.objectField("bits");
        try jws.beginObject();
        try writePackedBits(Layout, jws);
        try jws.endObject();
        try jws.endObject();
    }
    fn writeField(
        comptime decl: TypeDecl,
        comptime name: []const u8,
        comptime T: type,
        comptime offset: usize,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.objectField(name);
        try jws.beginObject();
        try jws.objectField("offset");
        try jws.write(offset);
        try jws.objectField("size");
        try jws.write(@sizeOf(T));
        try writeFieldType(decl.name, name, T, jws);
        if (decl.tagged_union) |tagged| {
            if (std.mem.eql(u8, name, tagged.value_field)) {
                try jws.objectField("tag");
                try jws.write(tagged.tag_field);
                try writeTaggedArms(decl, tagged, jws);
            }
        }
        try jws.endObject();
    }
    fn writeMappedUnionFields(
        comptime decl: TypeDecl,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const FieldNames = decl.union_field_names_T.?;
        const Tag = @FieldType(FieldNames, "tag");
        const tag_fields = @typeInfo(Tag).@"enum".fields;
        inline for (tag_fields, 0..) |field, i| {
            const name = comptime FieldNames.cFieldRename(@field(Tag, field.name)) orelse continue;
            if (comptime mappedUnionFieldIsDuplicate(decl, i, name)) continue;
            try writeField(decl, name, @FieldType(decl.T, field.name), 0, jws);
        }
        if (@hasField(decl.T, "_padding"))
            try writeField(decl, "_padding", @FieldType(decl.T, "_padding"), 0, jws);
    }
    fn mappedUnionFieldIsDuplicate(
        comptime decl: TypeDecl,
        comptime index: usize,
        comptime name: []const u8,
    ) bool {
        const FieldNames = decl.union_field_names_T.?;
        const Tag = @FieldType(FieldNames, "tag");
        const tag_fields = @typeInfo(Tag).@"enum".fields;
        const T = @FieldType(decl.T, tag_fields[index].name);
        inline for (tag_fields[0..index]) |previous| {
            const previous_name = FieldNames.cFieldRename(@field(Tag, previous.name)) orelse continue;
            if (std.mem.eql(u8, previous_name, name)) {
                if (@FieldType(decl.T, previous.name) != T)
                    @compileError("tagged union metadata maps different field types to " ++ name);
                return true;
            }
        }
        return false;
    }
    fn writeSizeAlign(comptime T: type, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        try jws.objectField("size");
        try jws.write(@sizeOf(T));
        try jws.objectField("align");
        try jws.write(@alignOf(T));
    }
    fn writeFieldType(
        comptime owner: []const u8,
        comptime field_name: []const u8,
        comptime T: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        if (comptime std.mem.eql(u8, owner, "WaspCellsView") and
            std.mem.eql(u8, field_name, "ptr"))
        {
            try writePointerTypeNamed(T, true, "WaspCell", jws);
            return;
        }
        if (comptime std.mem.eql(u8, owner, "WaspGridRef") and
            std.mem.eql(u8, field_name, "node"))
        {
            try writePointerTypeNamed(T, true, "opaque", jws);
            return;
        }
        if (comptime fieldTypeOverride(owner, field_name)) |name| {
            try jws.objectField("type");
            try jws.write(name);
            return;
        }
        switch (@typeInfo(T)) {
            .array => |info| {
                try jws.objectField("type");
                try jws.write("array");
                try jws.objectField("elem");
                try jws.write(publicTypeName(info.child));
                try jws.objectField("count");
                try jws.write(info.len);
            },
            .optional => |info| try writePointerType(info.child, true, jws),
            .pointer => try writePointerType(T, false, jws),
            else => {
                try jws.objectField("type");
                try jws.write(publicTypeName(T));
            },
        }
    }
    fn writePointerType(
        comptime T: type,
        comptime nullable: bool,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const info = @typeInfo(T).pointer;
        try jws.objectField("type");
        try jws.write("pointer");
        try jws.objectField("elem");
        try jws.write(publicTypeName(info.child));
        try jws.objectField("const");
        try jws.write(info.is_const);
        if (nullable) {
            try jws.objectField("nullable");
            try jws.write(true);
        }
    }
    fn writePointerTypeNamed(
        comptime T: type,
        comptime nullable: bool,
        comptime elem: []const u8,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const pointer_type = switch (@typeInfo(T)) {
            .optional => |info| info.child,
            .pointer => T,
            else => unreachable,
        };
        const info = @typeInfo(pointer_type).pointer;
        try jws.objectField("type");
        try jws.write("pointer");
        try jws.objectField("elem");
        try jws.write(elem);
        try jws.objectField("const");
        try jws.write(info.is_const);
        if (nullable) {
            try jws.objectField("nullable");
            try jws.write(true);
        }
    }
    fn fieldTypeOverride(comptime owner: []const u8, comptime field_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, field_name, "value")) {
            if (std.mem.eql(u8, owner, "WaspPoint")) return "WaspPointValue";
            if (std.mem.eql(u8, owner, "WaspSgrAttribute")) return "WaspSgrAttributeValue";
            if (std.mem.eql(u8, owner, "WaspStyleColor")) return "WaspStyleColorValue";
            if (std.mem.eql(u8, owner, "WaspTerminalResizeWindow")) return "WaspTerminalResizeWindowValue";
            if (std.mem.eql(u8, owner, "WaspTerminalScrollViewport")) return "WaspTerminalScrollViewportValue";
            if (std.mem.eql(u8, owner, "WaspTerminalUnknownSequence")) return "WaspTerminalUnknownSequenceValue";
        }
        if (std.mem.eql(u8, owner, "WaspStyleColorValue") and std.mem.eql(u8, field_name, "palette"))
            return "WaspColorPaletteIndex";
        if (std.mem.eql(u8, owner, "WaspSgrAttributeValue")) {
            if (std.mem.eql(u8, field_name, "underline")) return "WaspSgrUnderline";
            if (std.mem.endsWith(u8, field_name, "_8") or std.mem.endsWith(u8, field_name, "_256"))
                return "WaspColorPaletteIndex";
        }
        if (std.mem.eql(u8, owner, "WaspTerminalModeConfig") and std.mem.eql(u8, field_name, "mode"))
            return "WaspMode";
        return null;
    }
    fn writeTaggedArms(
        comptime decl: TypeDecl,
        comptime tagged: TypeDecl.TaggedUnion,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const Tag = @FieldType(decl.T, tagged.tag_field);
        try jws.objectField("arms");
        try jws.beginObject();
        inline for (@typeInfo(Tag).@"enum".fields) |field| {
            try writeEnumObjectField(publicTypeName(Tag), field.name, jws);
            if (comptime taggedArm(decl, field.name)) |arm| try jws.write(arm) else try jws.write(null);
        }
        try jws.endObject();
    }
    fn taggedArm(comptime decl: TypeDecl, comptime tag_name: []const u8) ?[]const u8 {
        const tagged = decl.tagged_union.?;
        const Tag = @FieldType(decl.T, tagged.tag_field);
        if (tagged.arm_source == .generated)
            return decl.T.cFieldRename(@field(Tag, tag_name));
        const Value = @FieldType(decl.T, tagged.value_field);
        if (!@hasField(Value, tag_name)) return null;
        return if (@sizeOf(@FieldType(Value, tag_name)) == 0) null else tag_name;
    }
    fn publicTypeName(comptime T: type) []const u8 {
        inline for (type_decls) |decl| switch (decl.kind) {
            .@"struct", .@"union", .@"enum" => if (T == decl.T) return decl.name,
            .@"packed", .alias, .@"opaque" => {},
        };
        return switch (@typeInfo(T)) {
            .bool => "bool",
            .float => |info| switch (info.bits) {
                32 => "f32",
                64 => "f64",
                else => "opaque",
            },
            .int => |info| intName(info.signedness, info.bits),
            .comptime_int => "comptime_int",
            .void => "void",
            .@"opaque" => "opaque",
            .@"fn" => "function",
            .@"enum" => "enum",
            .@"struct" => "struct",
            .@"union" => "union",
            else => "opaque",
        };
    }
    fn intName(comptime signedness: std.builtin.Signedness, comptime bits: u16) []const u8 {
        return switch (signedness) {
            .signed => switch (bits) {
                8 => "i8",
                16 => "i16",
                32 => "i32",
                64 => "i64",
                else => std.fmt.comptimePrint("i{d}", .{bits}),
            },
            .unsigned => switch (bits) {
                8 => "u8",
                16 => "u16",
                32 => "u32",
                64 => "u64",
                else => std.fmt.comptimePrint("u{d}", .{bits}),
            },
        };
    }
    fn writeUpperObjectField(comptime name: []const u8, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        var upper: [name.len]u8 = undefined;
        for (name, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        try jws.objectField(&upper);
    }
    fn writeEnumObjectField(
        comptime enum_name: []const u8,
        comptime zig_name: []const u8,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        if (std.mem.eql(u8, enum_name, "WaspKey") and std.mem.startsWith(u8, zig_name, "key_"))
            return writeUpperObjectField(zig_name["key_".len..], jws);
        if (std.mem.eql(u8, enum_name, "WaspSgrAttributeTag")) {
            if (std.mem.eql(u8, zig_name, "256_underline_color")) return jws.objectField("UNDERLINE_COLOR_256");
            if (std.mem.eql(u8, zig_name, "8_bg")) return jws.objectField("BG_8");
            if (std.mem.eql(u8, zig_name, "8_fg")) return jws.objectField("FG_8");
            if (std.mem.eql(u8, zig_name, "8_bright_bg")) return jws.objectField("BRIGHT_BG_8");
            if (std.mem.eql(u8, zig_name, "8_bright_fg")) return jws.objectField("BRIGHT_FG_8");
            if (std.mem.eql(u8, zig_name, "256_bg")) return jws.objectField("BG_256");
            if (std.mem.eql(u8, zig_name, "256_fg")) return jws.objectField("FG_256");
        }
        if (std.mem.eql(u8, enum_name, "WaspTerminalOption") and std.mem.eql(u8, zig_name, "size_cb"))
            return jws.objectField("SIZE");
        return writeUpperObjectField(zig_name, jws);
    }
    fn isBuiltinType(name: []const u8) bool {
        const builtins = [_][]const u8{
            "array", "bool",   "f32",     "f64", "function", "i8",  "i16", "i32",
            "i64",   "opaque", "pointer", "u8",  "u16",      "u32", "u64", "void",
        };
        for (builtins) |builtin_name| {
            if (std.mem.eql(u8, name, builtin_name)) return true;
        }
        if (name.len > 1 and (name[0] == 'i' or name[0] == 'u') and
            name[1] >= '1' and name[1] <= '9')
        {
            for (name[2..]) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
        return false;
    }
};
test "manifest parses and is versioned" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema").?.integer);
    try std.testing.expect(root.contains("abi"));
    try std.testing.expectEqual(
        @as(i64, c_abi.max_alignment),
        root.get("abi").?.object.get("max_alignment").?.integer,
    );
    try std.testing.expect(root.contains("library_version"));
    const manifest_types = root.get("types").?.object;
    try std.testing.expectEqual(type_decls.len, manifest_types.count());
    inline for (type_decls) |decl| try std.testing.expect(manifest_types.contains(decl.name));
    const cursor_fields = manifest_types.get("WaspRenderStateCursor").?.object
        .get("fields").?.object;
    try std.testing.expect(cursor_fields.contains("size"));
    try std.testing.expect(cursor_fields.contains("viewport_has_value"));
    try std.testing.expect(cursor_fields.contains("viewport_x"));
    try std.testing.expect(cursor_fields.contains("viewport_y"));
    try std.testing.expect(cursor_fields.contains("wide_tail"));
    try std.testing.expect(cursor_fields.contains("visible"));
    try std.testing.expect(cursor_fields.contains("blinking"));
    try std.testing.expect(cursor_fields.contains("password_input"));
    try std.testing.expect(cursor_fields.contains("visual_style"));
}
test "manifest describes enums, arrays, and tagged unions" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const data = manifest_types.get("WaspRenderStateData").?.object;
    try std.testing.expectEqualStrings("enum", data.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intFromEnum(render.Data.dirty)), data.get("values").?.object.get("DIRTY").?.integer);
    const colors = manifest_types.get("WaspRenderStateColors").?.object;
    const palette = colors.get("fields").?.object.get("palette").?.object;
    try std.testing.expectEqualStrings("array", palette.get("type").?.string);
    try std.testing.expectEqualStrings("WaspColorRgb", palette.get("elem").?.string);
    try std.testing.expectEqual(@as(i64, 256), palette.get("count").?.integer);
    const style_color = manifest_types.get("WaspStyleColor").?.object;
    const value = style_color.get("fields").?.object.get("value").?.object;
    try std.testing.expectEqualStrings("WaspStyleColorValue", value.get("type").?.string);
    try std.testing.expectEqualStrings("tag", value.get("tag").?.string);
    try std.testing.expectEqualStrings("palette", value.get("arms").?.object.get("PALETTE").?.string);
    try std.testing.expect(value.get("arms").?.object.get("NONE").? == .null);
}
test "manifest describes render state overscan types" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const overscan = manifest_types.get("WaspRenderStateOverscan").?.object;
    try std.testing.expectEqual(@as(i64, 4), overscan.get("size").?.integer);
    const overscan_fields = overscan.get("fields").?.object;
    try std.testing.expectEqual(@as(i64, 0), overscan_fields.get("above").?.object.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 2), overscan_fields.get("below").?.object.get("offset").?.integer);
    const row_id = manifest_types.get("WaspRenderStateRowId").?.object;
    try std.testing.expectEqual(@as(i64, 16), row_id.get("size").?.integer);
    const bits = row_id.get("fields").?.object.get("bits").?.object;
    try std.testing.expectEqual(@as(i64, 0), bits.get("offset").?.integer);
    try std.testing.expectEqualStrings("array", bits.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), bits.get("count").?.integer);
    const data_values = manifest_types.get("WaspRenderStateData").?.object
        .get("values").?.object;
    try std.testing.expectEqual(@as(i64, 20), data_values.get("OVERSCAN").?.integer);
    try std.testing.expectEqual(@as(i64, 21), data_values.get("OVERSCAN_REQUEST").?.integer);
    const row_data_values = manifest_types.get("WaspRenderStateRowData").?.object
        .get("values").?.object;
    try std.testing.expectEqual(@as(i64, 6), row_data_values.get("VIEWPORT_Y").?.integer);
    try std.testing.expectEqual(@as(i64, 7), row_data_values.get("ID").?.integer);
    const option_values = manifest_types.get("WaspRenderStateOption").?.object
        .get("values").?.object;
    try std.testing.expectEqual(@as(i64, 1), option_values.get("OVERSCAN").?.integer);
}
test "manifest describes the complete packed cell layout" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const descriptor = manifest_types.get("WaspCell").?.object;
    try std.testing.expectEqualStrings("packed", descriptor.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @sizeOf(page.Cell.CLayout.Zig)), descriptor.get("size").?.integer);
    try std.testing.expectEqualStrings("u64", descriptor.get("underlying").?.string);
    const bits = descriptor.get("bits").?.object;
    inline for (@typeInfo(page.Cell.CLayout.Zig).@"struct".fields) |field| {
        const field_tag = @field(page.Cell.CLayout.Field, field.name);
        const name = comptime page.Cell.CLayout.fieldName(field_tag);
        if (name) |public_name| {
            const bit = bits.get(public_name).?.object;
            try std.testing.expectEqual(
                @as(i64, @intCast(@bitOffsetOf(page.Cell.CLayout.Zig, field.name))),
                bit.get("lsb").?.integer,
            );
            try std.testing.expectEqual(
                @as(i64, @intCast(@bitSizeOf(field.type))),
                bit.get("width").?.integer,
            );
        } else {
            try std.testing.expect(!bits.contains(field.name));
        }
    }
    const content = bits.get("content").?.object;
    try std.testing.expectEqualStrings("union", content.get("kind").?.string);
    try std.testing.expectEqualStrings("content_tag", content.get("tag").?.string);
    const arms = content.get("arms").?.object;
    const Content = @FieldType(page.Cell.CLayout.Zig, "content");
    const Codepoint = @FieldType(Content, "codepoint");
    const codepoint = arms.get("CODEPOINT").?.object;
    const grapheme = arms.get("CODEPOINT_GRAPHEME").?.object;
    try expectPackedArmField(codepoint, "codepoint", Codepoint, "data", "u21");
    try expectPackedArmField(grapheme, "codepoint", Codepoint, "data", "u21");
    try expectPackedArmField(
        arms.get("BG_COLOR_PALETTE").?.object,
        "index",
        @FieldType(Content, "color_palette"),
        "data",
        "WaspColorPaletteIndex",
    );
    const rgb = arms.get("BG_COLOR_RGB").?.object;
    const Rgb = @FieldType(Content, "color_rgb");
    inline for (@typeInfo(Rgb).@"struct".fields) |field|
        try expectPackedArmField(rgb, field.name, Rgb, field.name, "u8");
}
test "manifest packed cell layouts decode real values" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const cell_bits = manifest_types.get("WaspCell").?.object.get("bits").?.object;
    var codepoint = page.Cell.CLayout.Zig.init('A');
    try expectDecodedCellContent(manifest_types, cell_bits, @bitCast(codepoint), "codepoint", 'A');
    codepoint.content_tag = .codepoint_grapheme;
    try expectDecodedCellContent(manifest_types, cell_bits, @bitCast(codepoint), "codepoint", 'A');
    var palette: page.Cell.CLayout.Zig = @bitCast(@as(u64, 0));
    palette.content_tag = .bg_color_palette;
    palette.content = .{ .color_palette = .{ .data = 173 } };
    try expectDecodedCellContent(manifest_types, cell_bits, @bitCast(palette), "index", 173);
    var rgb: page.Cell.CLayout.Zig = @bitCast(@as(u64, 0));
    rgb.content_tag = .bg_color_rgb;
    rgb.content = .{ .color_rgb = .{ .r = 0x12, .g = 0x34, .b = 0x56 } };
    const rgb_arm = activeCellContentArm(manifest_types, cell_bits, @bitCast(rgb));
    const content = extractManifestBits(@bitCast(rgb), cell_bits.get("content").?.object);
    try std.testing.expectEqual(@as(u64, 0x12), extractManifestBits(content, rgb_arm.get("bits").?.object.get("r").?.object));
    try std.testing.expectEqual(@as(u64, 0x34), extractManifestBits(content, rgb_arm.get("bits").?.object.get("g").?.object));
    try std.testing.expectEqual(@as(u64, 0x56), extractManifestBits(content, rgb_arm.get("bits").?.object.get("b").?.object));
}
test "manifest uses public enum names" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const cell_content = manifest_types.get("WaspCellContentTag").?.object.get("values").?.object;
    try std.testing.expect(cell_content.contains("TAG_MAX_VALUE"));
    try std.testing.expect(!cell_content.contains("MAX_VALUE"));
    const sgr_values = manifest_types.get("WaspSgrAttributeTag").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 9), sgr_values.get("UNDERLINE_COLOR_256").?.integer);
    try std.testing.expectEqual(@as(i64, 23), sgr_values.get("BG_8").?.integer);
    try std.testing.expect(!sgr_values.contains("256_UNDERLINE_COLOR"));
    const sgr_arms = manifest_types.get("WaspSgrAttribute").?.object
        .get("fields").?.object.get("value").?.object.get("arms").?.object;
    try std.testing.expectEqualStrings("underline_color_256", sgr_arms.get("UNDERLINE_COLOR_256").?.string);
    try std.testing.expectEqualStrings("bg_8", sgr_arms.get("BG_8").?.string);
    const terminal_values = manifest_types.get("WaspTerminalOption").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 6), terminal_values.get("SIZE").?.integer);
    try std.testing.expect(!terminal_values.contains("SIZE_CB"));
    try std.testing.expectEqual(@as(i64, 42), terminal_values.get("SEMANTIC_PROMPT").?.integer);
    try std.testing.expectEqual(@as(i64, 43), terminal_values.get("RESET").?.integer);
    const semantic_prompt_values = manifest_types.get("WaspSemanticPromptKind").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 0), semantic_prompt_values.get("INVALID").?.integer);
    try std.testing.expectEqual(@as(i64, 4), semantic_prompt_values.get("COMMAND_END").?.integer);
    const prompt_kind_values = manifest_types.get("WaspSemanticPromptPromptKind").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 3), prompt_kind_values.get("SECONDARY").?.integer);
    const osc_values = manifest_types.get("WaspOscCommandType").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 22), osc_values.get("KITTY_TEXT_SIZING").?.integer);
    try std.testing.expectEqual(@as(i64, 23), osc_values.get("KITTY_CLIPBOARD_PROTOCOL").?.integer);
    try std.testing.expectEqual(@as(i64, 24), osc_values.get("KITTY_DND_PROTOCOL").?.integer);
    try std.testing.expectEqual(@as(i64, 25), osc_values.get("HIERARCHICAL_CONTEXT").?.integer);
    try std.testing.expectEqual(@as(i64, 26), osc_values.get("KITTY_DESKTOP_NOTIFICATION").?.integer);
    try std.testing.expect(osc_values.contains("TYPE_MAX_VALUE"));
    try std.testing.expect(!osc_values.contains("MAX_VALUE"));
    const mouse_shape_values = manifest_types.get("WaspMouseShape").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 8), mouse_shape_values.get("TEXT").?.integer);
    try std.testing.expectEqual(@as(i64, 33), mouse_shape_values.get("ZOOM_OUT").?.integer);
    try std.testing.expect(mouse_shape_values.contains("MAX_VALUE"));
    const terminal_data_values = manifest_types.get("WaspTerminalData").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 41), terminal_data_values.get("MOUSE_SHAPE").?.integer);
    const key_values = manifest_types.get("WaspKey").?.object.get("values").?.object;
    try std.testing.expect(key_values.contains("A"));
    try std.testing.expect(!key_values.contains("KEY_A"));
    const mode_values = manifest_types.get("WaspModeReportState").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 0), mode_values.get("NOT_RECOGNIZED").?.integer);
    try std.testing.expectEqual(@as(i64, 4), mode_values.get("PERMANENTLY_RESET").?.integer);
}
test "manifest named references resolve" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    var type_iterator = manifest_types.iterator();
    while (type_iterator.next()) |type_entry| {
        const descriptor = type_entry.value_ptr.object;
        if (descriptor.get("bits")) |bits_value| {
            try expectManifestBitsValid(
                manifest_types,
                bits_value.object,
                @intCast(descriptor.get("size").?.integer * 8),
            );
        }
        const fields_value = descriptor.get("fields") orelse continue;
        var field_iterator = fields_value.object.iterator();
        while (field_iterator.next()) |field_entry| {
            const field = field_entry.value_ptr.object;
            const field_type = field.get("type").?.string;
            if (!Json.isBuiltinType(field_type))
                try std.testing.expect(manifest_types.contains(field_type));
            if (field.get("elem")) |elem_value| {
                const elem = elem_value.string;
                if (!Json.isBuiltinType(elem))
                    try std.testing.expect(manifest_types.contains(elem));
            }
            if (field.get("arms")) |arms_value| {
                const union_descriptor = manifest_types.get(field_type).?.object;
                const union_fields = union_descriptor.get("fields").?.object;
                const tag_field_name = field.get("tag").?.string;
                const tag_type_name = fields_value.object.get(tag_field_name).?.object.get("type").?.string;
                const tag_values = manifest_types.get(tag_type_name).?.object.get("values").?.object;
                var arm_iterator = arms_value.object.iterator();
                while (arm_iterator.next()) |arm_entry| {
                    try std.testing.expect(tag_values.contains(arm_entry.key_ptr.*));
                    if (arm_entry.value_ptr.* == .null) continue;
                    try std.testing.expect(union_fields.contains(arm_entry.value_ptr.string));
                }
            }
        }
    }
}
fn expectPackedArmField(
    arm: std.json.ObjectMap,
    manifest_name: []const u8,
    comptime T: type,
    comptime zig_name: []const u8,
    expected_type: []const u8,
) !void {
    try std.testing.expectEqualStrings("packed", arm.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @bitSizeOf(T)), arm.get("width").?.integer);
    const bit = arm.get("bits").?.object.get(manifest_name).?.object;
    try std.testing.expectEqual(@as(i64, @bitOffsetOf(T, zig_name)), bit.get("lsb").?.integer);
    try std.testing.expectEqual(@as(i64, @bitSizeOf(@FieldType(T, zig_name))), bit.get("width").?.integer);
    try std.testing.expectEqualStrings(expected_type, bit.get("type").?.string);
}
fn extractManifestBits(value: u64, bit: std.json.ObjectMap) u64 {
    const lsb: u6 = @intCast(bit.get("lsb").?.integer);
    const width: u7 = @intCast(bit.get("width").?.integer);
    const mask = if (width == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(width)) - 1;
    return (value >> lsb) & mask;
}
fn activeCellContentArm(
    manifest_types: std.json.ObjectMap,
    cell_bits: std.json.ObjectMap,
    raw: u64,
) std.json.ObjectMap {
    const content_tag = cell_bits.get("content_tag").?.object;
    const value = extractManifestBits(raw, content_tag);
    const enum_values = manifest_types.get(content_tag.get("type").?.string).?.object
        .get("values").?.object;
    var iterator = enum_values.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.integer == value)
            return cell_bits.get("content").?.object.get("arms").?.object
                .get(entry.key_ptr.*).?.object;
    }
    unreachable;
}
fn expectDecodedCellContent(
    manifest_types: std.json.ObjectMap,
    cell_bits: std.json.ObjectMap,
    raw: u64,
    field_name: []const u8,
    expected: u64,
) !void {
    const arm = activeCellContentArm(manifest_types, cell_bits, raw);
    const content = extractManifestBits(raw, cell_bits.get("content").?.object);
    try std.testing.expectEqual(
        expected,
        extractManifestBits(content, arm.get("bits").?.object.get(field_name).?.object),
    );
}
fn expectManifestBitsValid(
    manifest_types: std.json.ObjectMap,
    bits: std.json.ObjectMap,
    container_width: usize,
) !void {
    var iterator = bits.iterator();
    while (iterator.next()) |entry| {
        const bit = entry.value_ptr.object;
        const lsb: usize = @intCast(bit.get("lsb").?.integer);
        const width: usize = @intCast(bit.get("width").?.integer);
        try std.testing.expect(lsb + width <= container_width);
        if (bit.get("type")) |type_value| {
            const type_name = type_value.string;
            try std.testing.expect(Json.isBuiltinType(type_name) or manifest_types.contains(type_name));
            continue;
        }
        const kind = bit.get("kind").?.string;
        if (std.mem.eql(u8, kind, "packed")) {
            try expectManifestBitsValid(manifest_types, bit.get("bits").?.object, width);
            continue;
        }
        try std.testing.expectEqualStrings("union", kind);
        const tag_name = bit.get("tag").?.string;
        const tag = bits.get(tag_name).?.object;
        const enum_values = manifest_types.get(tag.get("type").?.string).?.object
            .get("values").?.object;
        var arm_iterator = bit.get("arms").?.object.iterator();
        while (arm_iterator.next()) |arm_entry| {
            try std.testing.expect(enum_values.contains(arm_entry.key_ptr.*));
            if (arm_entry.value_ptr.* == .null) continue;
            const arm = arm_entry.value_ptr.object;
            const arm_width: usize = @intCast(arm.get("width").?.integer);
            try std.testing.expect(arm_width <= width);
            try expectManifestBitsValid(manifest_types, arm.get("bits").?.object, arm_width);
        }
    }
}
