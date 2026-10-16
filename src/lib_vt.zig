const lib = @This();
const std = @import("std");
const builtin = @import("builtin");
const stderr = @import("os/stderr.zig");
const terminal = @import("terminal/main.zig");
pub const sys = terminal.sys;
pub const StdIo = @import("lib/StdIo.zig");
pub const apc = terminal.apc;
pub const clipboard = terminal.clipboard;
pub const dcs = terminal.dcs;
pub const osc = terminal.osc;
pub const point = terminal.point;
pub const color = terminal.color;
pub const xt_checksum = terminal.xt_checksum;
pub const device_attributes = terminal.device_attributes;
pub const device_status = terminal.device_status;
pub const formatter = terminal.formatter;
pub const highlight = terminal.highlight;
pub const kitty = terminal.kitty;
pub const modes = terminal.modes;
pub const page = terminal.page;
pub const parse_table = terminal.parse_table;
pub const search = terminal.search;
pub const sgr = terminal.sgr;
pub const size = terminal.size;
pub const snapshot = terminal.snapshot;
pub const x11_color = terminal.x11_color;
pub const Charset = terminal.Charset;
pub const CharsetSlot = terminal.CharsetSlot;
pub const CharsetActiveSlot = terminal.CharsetActiveSlot;
pub const Cell = page.Cell;
pub const Coordinate = point.Coordinate;
pub const CSI = Parser.Action.CSI;
pub const DCS = Parser.Action.DCS;
pub const MouseShape = terminal.MouseShape;
pub const Page = page.Page;
pub const PageList = terminal.PageList;
pub const Parser = terminal.Parser;
pub const Pin = PageList.Pin;
pub const Point = point.Point;
pub const RenderState = terminal.RenderState;
pub const Screen = terminal.Screen;
pub const ScreenSet = terminal.ScreenSet;
pub const Selection = terminal.Selection;
pub const SelectionGesture = terminal.SelectionGesture;
pub const size_report = terminal.size_report;
pub const SizeReportStyle = terminal.SizeReportStyle;
pub const StringMap = terminal.StringMap;
pub const Style = terminal.Style;
pub const Terminal = terminal.Terminal;
pub const TerminalStream = terminal.TerminalStream;
pub const Stream = terminal.Stream;
pub const StreamAction = terminal.StreamAction;
pub const SemanticPrompt = terminal.SemanticPrompt;
pub const UnknownSequence = terminal.UnknownSequence;
pub const Paste = terminal.Paste;
pub const PasteSource = terminal.PasteSource;
pub const PasteError = terminal.PasteError;
pub const Cursor = Screen.Cursor;
pub const CursorStyle = Screen.CursorStyle;
pub const CursorStyleReq = terminal.CursorStyle;
pub const DeviceAttributeReq = terminal.DeviceAttributeReq;
pub const Mode = modes.Mode;
pub const ModePacked = modes.ModePacked;
pub const ModifyKeyFormat = terminal.ModifyKeyFormat;
pub const ProtectedMode = terminal.ProtectedMode;
pub const StatusLineType = terminal.StatusLineType;
pub const StatusDisplay = terminal.StatusDisplay;
pub const EraseDisplay = terminal.EraseDisplay;
pub const EraseLine = terminal.EraseLine;
pub const TabClear = terminal.TabClear;
pub const Attribute = terminal.Attribute;
pub const input = struct {
    const focus = terminal.focus;
    const paste = @import("input/paste.zig");
    const key = @import("input/key.zig");
    const key_encode = @import("input/key_encode.zig");
    const mouse_encode = @import("input/mouse_encode.zig");
    pub const max_focus_encode_size = focus.max_encode_size;
    pub const FocusEvent = focus.Event;
    pub const encodeFocus = focus.encode;
    pub const PasteError = paste.Error;
    pub const PasteOptions = paste.Options;
    pub const max_paste_frame_size = paste.max_frame_size;
    pub const isSafePaste = paste.isSafe;
    pub const isSafePasteWith = paste.isSafeWith;
    pub const encodePaste = paste.encode;
    pub const encodePasteWriter = paste.encodeWriter;
    pub const Key = key.Key;
    pub const KeyAction = key.Action;
    pub const KeyEvent = key.KeyEvent;
    pub const KeyMods = key.Mods;
    pub const KeyEncodeOptions = key_encode.Options;
    pub const encodeKey = key_encode.encode;
    pub const MouseAction = @import("input/mouse.zig").Action;
    pub const MouseButton = @import("input/mouse.zig").Button;
    pub const MouseEncodeOptions = mouse_encode.Options;
    pub const MouseEncodeEvent = mouse_encode.Event;
    pub const encodeMouse = mouse_encode.encode;
};
pub const unicode = struct {
    const unicode_pkg = @import("unicode/root.zig");
    pub const codepointWidth = unicode_pkg.codepointWidth;
    pub const graphemeWidth = unicode_pkg.graphemeWidth;
};
var msvc_fltused: c_int = 1;
comptime {
    if (@import("root") == lib) {
        if (builtin.os.tag == .windows and
            builtin.abi == .msvc and
            builtin.link_mode == .static)
        {
            @export(
                &msvc_fltused,
                .{ .name = "_fltused" },
            );
        }
        _ = @import("quirks_memset.zig");
        const c = terminal.c_api;
        const features = terminal.options;
        if (features.input_encode) {
            @export(&c.key_event_new, .{ .name = "wasp_key_event_new" });
            @export(&c.key_event_free, .{ .name = "wasp_key_event_free" });
            @export(&c.key_event_set_action, .{ .name = "wasp_key_event_set_action" });
            @export(&c.key_event_get_action, .{ .name = "wasp_key_event_get_action" });
            @export(&c.key_event_set_key, .{ .name = "wasp_key_event_set_key" });
            @export(&c.key_event_get_key, .{ .name = "wasp_key_event_get_key" });
            @export(&c.key_event_set_mods, .{ .name = "wasp_key_event_set_mods" });
            @export(&c.key_event_get_mods, .{ .name = "wasp_key_event_get_mods" });
            @export(&c.key_event_set_consumed_mods, .{ .name = "wasp_key_event_set_consumed_mods" });
            @export(&c.key_event_get_consumed_mods, .{ .name = "wasp_key_event_get_consumed_mods" });
            @export(&c.key_event_set_composing, .{ .name = "wasp_key_event_set_composing" });
            @export(&c.key_event_get_composing, .{ .name = "wasp_key_event_get_composing" });
            @export(&c.key_event_set_utf8, .{ .name = "wasp_key_event_set_utf8" });
            @export(&c.key_event_get_utf8, .{ .name = "wasp_key_event_get_utf8" });
            @export(&c.key_event_set_unshifted_codepoint, .{ .name = "wasp_key_event_set_unshifted_codepoint" });
            @export(&c.key_event_get_unshifted_codepoint, .{ .name = "wasp_key_event_get_unshifted_codepoint" });
            @export(&c.key_encoder_new, .{ .name = "wasp_key_encoder_new" });
            @export(&c.key_encoder_free, .{ .name = "wasp_key_encoder_free" });
            @export(&c.key_encoder_setopt, .{ .name = "wasp_key_encoder_setopt" });
            @export(&c.key_encoder_setopt_from_terminal, .{ .name = "wasp_key_encoder_setopt_from_terminal" });
            @export(&c.key_encoder_encode, .{ .name = "wasp_key_encoder_encode" });
            @export(&c.focus_encode, .{ .name = "wasp_focus_encode" });
            @export(&c.paste_is_safe, .{ .name = "wasp_paste_is_safe" });
            @export(&c.paste_encode, .{ .name = "wasp_paste_encode" });
            @export(&c.terminal_paste, .{ .name = "wasp_terminal_paste" });
            @export(&c.mouse_event_new, .{ .name = "wasp_mouse_event_new" });
            @export(&c.mouse_event_free, .{ .name = "wasp_mouse_event_free" });
            @export(&c.mouse_event_set_action, .{ .name = "wasp_mouse_event_set_action" });
            @export(&c.mouse_event_get_action, .{ .name = "wasp_mouse_event_get_action" });
            @export(&c.mouse_event_set_button, .{ .name = "wasp_mouse_event_set_button" });
            @export(&c.mouse_event_clear_button, .{ .name = "wasp_mouse_event_clear_button" });
            @export(&c.mouse_event_get_button, .{ .name = "wasp_mouse_event_get_button" });
            @export(&c.mouse_event_set_mods, .{ .name = "wasp_mouse_event_set_mods" });
            @export(&c.mouse_event_get_mods, .{ .name = "wasp_mouse_event_get_mods" });
            @export(&c.mouse_event_set_position, .{ .name = "wasp_mouse_event_set_position" });
            @export(&c.mouse_event_get_position, .{ .name = "wasp_mouse_event_get_position" });
            @export(&c.mouse_encoder_new, .{ .name = "wasp_mouse_encoder_new" });
            @export(&c.mouse_encoder_free, .{ .name = "wasp_mouse_encoder_free" });
            @export(&c.mouse_encoder_setopt, .{ .name = "wasp_mouse_encoder_setopt" });
            @export(&c.mouse_encoder_setopt_from_terminal, .{ .name = "wasp_mouse_encoder_setopt_from_terminal" });
            @export(&c.mouse_encoder_reset, .{ .name = "wasp_mouse_encoder_reset" });
            @export(&c.mouse_encoder_encode, .{ .name = "wasp_mouse_encoder_encode" });
        }
        @export(&c.osc_new, .{ .name = "wasp_osc_new" });
        @export(&c.osc_free, .{ .name = "wasp_osc_free" });
        @export(&c.osc_next, .{ .name = "wasp_osc_next" });
        @export(&c.osc_reset, .{ .name = "wasp_osc_reset" });
        @export(&c.osc_end, .{ .name = "wasp_osc_end" });
        @export(&c.osc_set, .{ .name = "wasp_osc_set" });
        @export(&c.osc_command_type, .{ .name = "wasp_osc_command_type" });
        @export(&c.osc_command_data, .{ .name = "wasp_osc_command_data" });
        @export(&c.color_scheme_report_encode, .{ .name = "wasp_color_scheme_report_encode" });
        @export(&c.mode_report_encode, .{ .name = "wasp_mode_report_encode" });
        @export(&c.unicode_codepoint_width, .{ .name = "wasp_unicode_codepoint_width" });
        @export(&c.unicode_grapheme_width, .{ .name = "wasp_unicode_grapheme_width" });
        @export(&c.size_report_encode, .{ .name = "wasp_size_report_encode" });
        @export(&c.style_default, .{ .name = "wasp_style_default" });
        @export(&c.style_is_default, .{ .name = "wasp_style_is_default" });
        @export(&c.sys_log_stderr, .{ .name = "wasp_sys_log_stderr" });
        @export(&c.sys_set, .{ .name = "wasp_sys_set" });
        if (features.grid_introspection) {
            @export(&c.cell_get, .{ .name = "wasp_cell_get" });
            @export(&c.cell_get_multi, .{ .name = "wasp_cell_get_multi" });
            @export(&c.row_get, .{ .name = "wasp_row_get" });
            @export(&c.row_get_multi, .{ .name = "wasp_row_get_multi" });
        }
        if (features.color) {
            @export(&c.color_rgb_get, .{ .name = "wasp_color_rgb_get" });
            @export(&c.color_contrast, .{ .name = "wasp_color_contrast" });
            @export(&c.color_luminance, .{ .name = "wasp_color_luminance" });
            @export(&c.color_parse, .{ .name = "wasp_color_parse" });
            @export(&c.color_parse_palette_entry, .{ .name = "wasp_color_parse_palette_entry" });
            @export(&c.color_parse_x11, .{ .name = "wasp_color_parse_x11" });
            @export(&c.color_palette_default, .{ .name = "wasp_color_palette_default" });
            @export(&c.color_palette_generate, .{ .name = "wasp_color_palette_generate" });
            @export(&c.color_perceived_luminance, .{ .name = "wasp_color_perceived_luminance" });
            @export(&c.color_x11_name_count, .{ .name = "wasp_color_x11_name_count" });
            @export(&c.color_x11_names, .{ .name = "wasp_color_x11_names" });
        }
        @export(&c.sgr_new, .{ .name = "wasp_sgr_new" });
        @export(&c.sgr_free, .{ .name = "wasp_sgr_free" });
        @export(&c.sgr_reset, .{ .name = "wasp_sgr_reset" });
        @export(&c.sgr_set_params, .{ .name = "wasp_sgr_set_params" });
        @export(&c.sgr_next, .{ .name = "wasp_sgr_next" });
        @export(&c.sgr_unknown_full, .{ .name = "wasp_sgr_unknown_full" });
        @export(&c.sgr_unknown_partial, .{ .name = "wasp_sgr_unknown_partial" });
        @export(&c.sgr_attribute_tag, .{ .name = "wasp_sgr_attribute_tag" });
        @export(&c.sgr_attribute_value, .{ .name = "wasp_sgr_attribute_value" });
        if (features.formatter) {
            @export(&c.formatter_terminal_new, .{ .name = "wasp_formatter_terminal_new" });
            @export(&c.formatter_format, .{ .name = "wasp_formatter_format" });
            @export(&c.formatter_format_buf, .{ .name = "wasp_formatter_format_buf" });
            @export(&c.formatter_format_alloc, .{ .name = "wasp_formatter_format_alloc" });
            @export(&c.formatter_free, .{ .name = "wasp_formatter_free" });
        }
        if (features.formatter and features.selection) {
            @export(&c.terminal_selection_format_buf, .{ .name = "wasp_terminal_selection_format_buf" });
            @export(&c.terminal_selection_format_alloc, .{ .name = "wasp_terminal_selection_format_alloc" });
        }
        if (features.render_state) {
            @export(&c.render_state_new, .{ .name = "wasp_render_state_new" });
            @export(&c.render_state_update, .{ .name = "wasp_render_state_update" });
            @export(&c.render_state_begin_update, .{ .name = "wasp_render_state_begin_update" });
            @export(&c.render_state_end_update, .{ .name = "wasp_render_state_end_update" });
            @export(&c.render_state_clean, .{ .name = "wasp_render_state_clean" });
            @export(&c.render_state_get, .{ .name = "wasp_render_state_get" });
            @export(&c.render_state_get_multi, .{ .name = "wasp_render_state_get_multi" });
            @export(&c.render_state_set, .{ .name = "wasp_render_state_set" });
            @export(&c.render_state_row_iterator_new, .{ .name = "wasp_render_state_row_iterator_new" });
            @export(&c.render_state_row_iterator_next, .{ .name = "wasp_render_state_row_iterator_next" });
            @export(&c.render_state_row_iterator_next_dirty, .{ .name = "wasp_render_state_row_iterator_next_dirty" });
            @export(&c.render_state_row_get, .{ .name = "wasp_render_state_row_get" });
            @export(&c.render_state_row_get_multi, .{ .name = "wasp_render_state_row_get_multi" });
            @export(&c.render_state_row_set, .{ .name = "wasp_render_state_row_set" });
            @export(&c.render_state_row_iterator_free, .{ .name = "wasp_render_state_row_iterator_free" });
            @export(&c.render_state_row_cells_new, .{ .name = "wasp_render_state_row_cells_new" });
            @export(&c.render_state_row_cells_next, .{ .name = "wasp_render_state_row_cells_next" });
            @export(&c.render_state_row_cells_select, .{ .name = "wasp_render_state_row_cells_select" });
            @export(&c.render_state_row_cells_get, .{ .name = "wasp_render_state_row_cells_get" });
            @export(&c.render_state_row_cells_get_multi, .{ .name = "wasp_render_state_row_cells_get_multi" });
            @export(&c.render_state_row_cells_free, .{ .name = "wasp_render_state_row_cells_free" });
            @export(&c.render_state_free, .{ .name = "wasp_render_state_free" });
        }
        @export(&c.terminal_new, .{ .name = "wasp_terminal_new" });
        @export(&c.terminal_free, .{ .name = "wasp_terminal_free" });
        @export(&c.terminal_reset, .{ .name = "wasp_terminal_reset" });
        @export(&c.terminal_resize, .{ .name = "wasp_terminal_resize" });
        @export(&c.terminal_set, .{ .name = "wasp_terminal_set" });
        @export(&c.terminal_vt_write, .{ .name = "wasp_terminal_vt_write" });
        @export(&c.terminal_vt_write_until_ground, .{ .name = "wasp_terminal_vt_write_until_ground" });
        @export(&c.terminal_scroll_viewport, .{ .name = "wasp_terminal_scroll_viewport" });
        @export(&c.terminal_compression_activity, .{ .name = "wasp_terminal_compression_activity" });
        @export(&c.terminal_compress, .{ .name = "wasp_terminal_compress" });
        @export(&c.terminal_get, .{ .name = "wasp_terminal_get" });
        @export(&c.terminal_get_multi, .{ .name = "wasp_terminal_get_multi" });
        @export(&c.terminal_continuation_write, .{ .name = "wasp_terminal_continuation_write" });
        @export(&c.terminal_continuation_buf, .{ .name = "wasp_terminal_continuation_buf" });
        @export(&c.terminal_continuation_alloc, .{ .name = "wasp_terminal_continuation_alloc" });
        if (features.selection) {
            @export(&c.terminal_select_word, .{ .name = "wasp_terminal_select_word" });
            @export(&c.terminal_select_word_between, .{ .name = "wasp_terminal_select_word_between" });
            @export(&c.terminal_select_line, .{ .name = "wasp_terminal_select_line" });
            @export(&c.terminal_select_all, .{ .name = "wasp_terminal_select_all" });
            @export(&c.terminal_select_output, .{ .name = "wasp_terminal_select_output" });
            @export(&c.terminal_selection_adjust, .{ .name = "wasp_terminal_selection_adjust" });
            @export(&c.terminal_selection_order, .{ .name = "wasp_terminal_selection_order" });
            @export(&c.terminal_selection_ordered, .{ .name = "wasp_terminal_selection_ordered" });
            @export(&c.terminal_selection_contains, .{ .name = "wasp_terminal_selection_contains" });
            @export(&c.terminal_selection_equal, .{ .name = "wasp_terminal_selection_equal" });
            @export(&c.selection_gesture_new, .{ .name = "wasp_selection_gesture_new" });
            @export(&c.selection_gesture_free, .{ .name = "wasp_selection_gesture_free" });
            @export(&c.selection_gesture_reset, .{ .name = "wasp_selection_gesture_reset" });
            @export(&c.selection_gesture_event, .{ .name = "wasp_selection_gesture_event" });
            @export(&c.selection_gesture_get, .{ .name = "wasp_selection_gesture_get" });
            @export(&c.selection_gesture_get_multi, .{ .name = "wasp_selection_gesture_get_multi" });
            @export(&c.selection_gesture_event_new, .{ .name = "wasp_selection_gesture_event_new" });
            @export(&c.selection_gesture_event_free, .{ .name = "wasp_selection_gesture_event_free" });
            @export(&c.selection_gesture_event_set, .{ .name = "wasp_selection_gesture_event_set" });
        }
        if (features.search) {
            @export(&c.search_new, .{ .name = "wasp_search_new" });
            @export(&c.search_free, .{ .name = "wasp_search_free" });
            @export(&c.search_tick, .{ .name = "wasp_search_tick" });
            @export(&c.search_feed, .{ .name = "wasp_search_feed" });
            @export(&c.search_run, .{ .name = "wasp_search_run" });
            @export(&c.search_set, .{ .name = "wasp_search_set" });
            @export(&c.search_get, .{ .name = "wasp_search_get" });
            @export(&c.search_get_multi, .{ .name = "wasp_search_get_multi" });
        }
        if (features.grid_introspection or features.selection) {
            @export(&c.terminal_grid_ref, .{ .name = "wasp_terminal_grid_ref" });
            @export(&c.terminal_point_from_grid_ref, .{ .name = "wasp_terminal_point_from_grid_ref" });
        }
        if (features.grid_introspection) {
            @export(&c.terminal_grid_ref_track, .{ .name = "wasp_terminal_grid_ref_track" });
        }
        if (features.snapshot) {
            @export(&c.snapshot_encode, .{ .name = "wasp_snapshot_encode" });
            @export(&c.snapshot_encode_buf, .{ .name = "wasp_snapshot_encode_buf" });
            @export(&c.snapshot_encode_alloc, .{ .name = "wasp_snapshot_encode_alloc" });
            @export(&c.snapshot_decoder_new, .{ .name = "wasp_snapshot_decoder_new" });
            @export(&c.snapshot_decoder_new_buf, .{ .name = "wasp_snapshot_decoder_new_buf" });
            @export(&c.snapshot_decoder_free, .{ .name = "wasp_snapshot_decoder_free" });
            @export(&c.snapshot_decoder_set, .{ .name = "wasp_snapshot_decoder_set" });
            @export(&c.snapshot_decoder_get, .{ .name = "wasp_snapshot_decoder_get" });
            @export(&c.snapshot_decoder_get_multi, .{ .name = "wasp_snapshot_decoder_get_multi" });
            @export(&c.snapshot_decoder_ready, .{ .name = "wasp_snapshot_decoder_ready" });
            @export(&c.snapshot_decoder_next, .{ .name = "wasp_snapshot_decoder_next" });
            @export(&c.snapshot_decoder_decode, .{ .name = "wasp_snapshot_decoder_decode" });
        }
        if (features.kitty_graphics) {
            @export(&c.kitty_graphics_get, .{ .name = "wasp_kitty_graphics_get" });
            @export(&c.kitty_graphics_image, .{ .name = "wasp_kitty_graphics_image" });
            @export(&c.kitty_graphics_image_get, .{ .name = "wasp_kitty_graphics_image_get" });
            @export(&c.kitty_graphics_image_get_multi, .{ .name = "wasp_kitty_graphics_image_get_multi" });
            @export(&c.kitty_graphics_placement_iterator_new, .{ .name = "wasp_kitty_graphics_placement_iterator_new" });
            @export(&c.kitty_graphics_placement_iterator_free, .{ .name = "wasp_kitty_graphics_placement_iterator_free" });
            @export(&c.kitty_graphics_placement_iterator_set, .{ .name = "wasp_kitty_graphics_placement_iterator_set" });
            @export(&c.kitty_graphics_placement_next, .{ .name = "wasp_kitty_graphics_placement_next" });
            @export(&c.kitty_graphics_placement_get, .{ .name = "wasp_kitty_graphics_placement_get" });
            @export(&c.kitty_graphics_placement_get_multi, .{ .name = "wasp_kitty_graphics_placement_get_multi" });
            @export(&c.kitty_graphics_placement_rect, .{ .name = "wasp_kitty_graphics_placement_rect" });
            @export(&c.kitty_graphics_placement_pixel_size, .{ .name = "wasp_kitty_graphics_placement_pixel_size" });
            @export(&c.kitty_graphics_placement_grid_size, .{ .name = "wasp_kitty_graphics_placement_grid_size" });
            @export(&c.kitty_graphics_placement_viewport_pos, .{ .name = "wasp_kitty_graphics_placement_viewport_pos" });
            @export(&c.kitty_graphics_placement_source_rect, .{ .name = "wasp_kitty_graphics_placement_source_rect" });
            @export(&c.kitty_graphics_placement_render_info, .{ .name = "wasp_kitty_graphics_placement_render_info" });
        }
        if (features.grid_introspection) {
            @export(&c.grid_ref_cell, .{ .name = "wasp_grid_ref_cell" });
            @export(&c.grid_ref_row, .{ .name = "wasp_grid_ref_row" });
            @export(&c.grid_ref_graphemes, .{ .name = "wasp_grid_ref_graphemes" });
            @export(&c.grid_ref_hyperlink_uri, .{ .name = "wasp_grid_ref_hyperlink_uri" });
            @export(&c.grid_ref_style, .{ .name = "wasp_grid_ref_style" });
            @export(&c.tracked_grid_ref_free, .{ .name = "wasp_tracked_grid_ref_free" });
            @export(&c.tracked_grid_ref_has_value, .{ .name = "wasp_tracked_grid_ref_has_value" });
            @export(&c.tracked_grid_ref_point, .{ .name = "wasp_tracked_grid_ref_point" });
            @export(&c.tracked_grid_ref_set, .{ .name = "wasp_tracked_grid_ref_set" });
        }
        if (features.grid_introspection and features.snapshot) {
            @export(&c.tracked_grid_ref_snapshot, .{ .name = "wasp_tracked_grid_ref_snapshot" });
        }
        @export(&c.build_info, .{ .name = "wasp_build_info" });
        @export(&c.type_json, .{ .name = "wasp_type_json" });
        @export(&c.alloc_alloc, .{ .name = "wasp_alloc" });
        @export(&c.alloc_free, .{ .name = "wasp_free" });
        if (builtin.target.cpu.arch.isWasm()) {
            const alloc = @import("lib/allocator/wasm.zig");
            @export(&alloc.allocBytes, .{ .name = "wasp_wasm_alloc" });
            @export(&alloc.freeBytes, .{ .name = "wasp_wasm_free" });
            @export(&alloc.allocOpaque, .{ .name = "wasp_wasm_alloc_opaque" });
            @export(&alloc.freeOpaque, .{ .name = "wasp_wasm_free_opaque" });
            @export(&alloc.takeOpaque, .{ .name = "wasp_wasm_take_opaque" });
        }
    }
}
pub const std_options: std.Options = opts: {
    var options: std.Options = .{};
    if (native_freestanding) {
        options.page_size_min = 16;
        options.page_size_max = 16;
        options.allow_stack_tracing = false;
    }
    if (builtin.target.cpu.arch.isWasm()) {
        if (builtin.mode == .Debug) {
            options.log_level = .debug;
            options.logFn = @import("os/wasm/log.zig").log;
        } else {
            options.log_level = .err;
            options.logFn = @import("os/wasm/log.zig").noop;
        }
    } else if (terminal.options.c_abi) {
        options.logFn = @import("terminal/c/sys.zig").logFn;
    }
    if (builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .macos) {
        options.allow_stack_tracing = false;
    }
    break :opts options;
};
const native_freestanding = builtin.target.os.tag == .freestanding and
    !builtin.target.cpu.arch.isWasm();
const debug_machinery: bool = !native_freestanding and
    (builtin.is_test or switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    });
pub const panic: type = if (debug_machinery)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.FullPanic(tinyPanicImpl);
pub const DllMain = if (builtin.os.tag == .windows and
    builtin.output_mode == .Lib and
    builtin.link_mode == .dynamic)
    @import("lib/windows_dll.zig").DllMain
else {};
pub const std_options_debug_io: std.Io = if (debug_machinery)
    std.Io.Threaded.global_single_threaded.io()
else
    @compileError(
        \\The std debug Io machinery (std.debug.print, std.debug.lockStderr,
        \\std.log's default handler, ...) is disabled in libwasp-vt release
        \\builds because it costs ~110KB of binary size. Use std.log (routed
        \\through our logFn), os/stderr.zig for raw diagnostic writes, or
        \\gate the code on debug builds.
    );
fn tinyPanicImpl(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    _ = ra;
    var buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(
        &buf,
        "panic: {s}\n",
        .{msg},
    )) |line| {
        stderr.write(line);
    } else |_| {
        stderr.write("panic: ");
        stderr.write(msg);
        stderr.write("\n");
    }
    @trap();
}
test {
    @import("std").testing.log_level = std.log.Level.err;
    _ = terminal;
    _ = @import("lib/main.zig");
    @import("std").testing.refAllDecls(input);
    @import("std").testing.refAllDecls(unicode);
    if (comptime terminal.options.c_abi) {
        _ = terminal.c_api;
    }
}
