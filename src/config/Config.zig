const Config = @This();
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global = @import("../global.zig");
const deepEqual = @import("../datastruct/comparison.zig").deepEqual;
const fontpkg = @import("../font/root.zig");
const inputpkg = @import("../input.zig");
const internal_os = @import("../os/root.zig");
const cli = @import("../cli.zig");
const conditional = @import("conditional.zig");
const Conditional = conditional.Conditional;
const file_load = @import("file_load.zig");
const formatterpkg = @import("formatter.zig");
const themepkg = @import("theme.zig");
const url = @import("url.zig");
pub const Key = @import("key.zig").Key;
const MetricModifier = fontpkg.Metrics.Modifier;
const help_strings = @import("help_strings");
pub const Command = @import("command.zig").Command;
const RepeatableReadableIO = @import("io.zig").RepeatableReadableIO;
const RepeatableStringMap = @import("RepeatableStringMap.zig");
pub const Path = @import("path.zig").Path;
pub const RepeatablePath = @import("path.zig").RepeatablePath;
const ClipboardCodepointMap = @import("ClipboardCodepointMap.zig");
const KeyRemapSet = @import("../input/key_mods.zig").RemapSet;
pub const WindowPaddingBalance = @import("../renderer/size.zig").PaddingBalance;
const string = @import("string.zig");
const Limit = @import("limit.zig").Limit;
const terminal = struct {
    const CursorStyle = @import("../terminal/cursor.zig").Style;
    const color = @import("../terminal/color.zig");
    const selection_codepoints = @import("../terminal/selection_codepoints.zig");
    const style = @import("../terminal/style.zig");
};
const log = std.log.scoped(.config);
const c = @import("posix_c");
pub const compatibility = std.StaticStringMap(
    cli.CompatibilityHandler(Config),
).initComptime(&.{
    .{ "background-blur-radius", cli.compatibilityRenamed(Config, "background-blur") },
    .{ "adw-toolbar-style", cli.compatibilityRenamed(Config, "gtk-toolbar-style") },
    .{ "gtk-tabs-location", compatGtkTabsLocation },
    .{ "cursor-invert-fg-bg", compatCursorInvertFgBg },
    .{ "selection-invert-fg-bg", compatSelectionInvertFgBg },
    .{ "bold-is-bright", compatBoldIsBright },
    .{ "gtk-single-instance", compatGtkSingleInstance },
    .{ "macos-dock-drop-behavior", compatMacOSDockDropBehavior },
    .{ "scrollback-limit", cli.compatibilityRenamed(Config, "scrollback-limit-bytes") },
    .{ "copy-on-select", compatCopyOnSelect },
});
language: ?[:0]const u8 = null,
@"font-family": RepeatableString = .{},
@"font-family-bold": RepeatableString = .{},
@"font-family-italic": RepeatableString = .{},
@"font-family-bold-italic": RepeatableString = .{},
@"font-style": FontStyle = .{ .default = {} },
@"font-style-bold": FontStyle = .{ .default = {} },
@"font-style-italic": FontStyle = .{ .default = {} },
@"font-style-bold-italic": FontStyle = .{ .default = {} },
@"font-synthetic-style": FontSyntheticStyle = .{},
@"font-feature": RepeatableString = .{},
@"font-size": f32 = switch (builtin.os.tag) {
    .macos => 13,
    else => 12,
},
@"font-variation": RepeatableFontVariation = .{},
@"font-variation-bold": RepeatableFontVariation = .{},
@"font-variation-italic": RepeatableFontVariation = .{},
@"font-variation-bold-italic": RepeatableFontVariation = .{},
@"font-codepoint-map": RepeatableCodepointMap = .{},
@"clipboard-codepoint-map": RepeatableClipboardCodepointMap = .{},
@"font-thicken": bool = false,
@"font-thicken-strength": u8 = 255,
@"font-shaping-break": FontShapingBreak = .{},
@"alpha-blending": AlphaBlending =
    if (builtin.os.tag == .macos)
        .native
    else
        .@"linear-corrected",
@"adjust-cell-width": ?MetricModifier = null,
@"adjust-cell-height": ?MetricModifier = null,
@"adjust-font-baseline": ?MetricModifier = null,
@"adjust-underline-position": ?MetricModifier = null,
@"adjust-underline-thickness": ?MetricModifier = null,
@"adjust-strikethrough-position": ?MetricModifier = null,
@"adjust-strikethrough-thickness": ?MetricModifier = null,
@"adjust-overline-position": ?MetricModifier = null,
@"adjust-overline-thickness": ?MetricModifier = null,
@"adjust-cursor-thickness": ?MetricModifier = null,
@"adjust-cursor-height": ?MetricModifier = null,
@"adjust-box-thickness": ?MetricModifier = null,
@"adjust-icon-height": ?MetricModifier = null,
@"grapheme-width-method": GraphemeWidthMethod = .unicode,
@"freetype-load-flags": FreetypeLoadFlags = .{},
theme: ?Theme = null,
background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 },
foreground: Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
@"background-image": ?Path = null,
@"background-image-opacity": f32 = 1.0,
@"background-image-position": BackgroundImagePosition = .center,
@"background-image-fit": BackgroundImageFit = .contain,
@"background-image-repeat": bool = false,
@"selection-foreground": ?TerminalColor = null,
@"selection-background": ?TerminalColor = null,
@"selection-clear-on-typing": bool = true,
@"selection-clear-on-copy": bool = false,
@"selection-word-chars": SelectionWordChars = .{},
@"minimum-contrast": f64 = 1,
palette: Palette = .{},
@"palette-generate": bool = false,
@"palette-harmonious": bool = false,
@"cursor-color": ?TerminalColor = null,
@"cursor-opacity": f64 = 1.0,
@"cursor-style": terminal.CursorStyle = .block,
@"cursor-style-blink": ?bool = null,
@"cursor-text": ?TerminalColor = null,
@"cursor-click-to-move": bool = true,
@"mouse-hide-while-typing": bool = false,
@"scroll-to-bottom": ScrollToBottom = .default,
@"mouse-shift-capture": MouseShiftCapture = .false,
@"mouse-reporting": bool = true,
@"mouse-scroll-multiplier": MouseScrollMultiplier = .default,
@"background-opacity": f64 = 1.0,
@"background-opacity-cells": bool = false,
@"background-blur": BackgroundBlur = .false,
@"unfocused-split-opacity": f64 = 0.7,
@"unfocused-split-fill": ?Color = null,
@"split-divider-color": ?Color = null,
@"split-preserve-zoom": SplitPreserveZoom = .{},
@"search-foreground": TerminalColor = .{ .color = .{ .r = 0, .g = 0, .b = 0 } },
@"search-background": TerminalColor = .{ .color = .{ .r = 0xFF, .g = 0xE0, .b = 0x82 } },
@"search-selected-foreground": TerminalColor = .{ .color = .{ .r = 0, .g = 0, .b = 0 } },
@"search-selected-background": TerminalColor = .{ .color = .{ .r = 0xF2, .g = 0xA5, .b = 0x7E } },
command: ?Command = null,
@"initial-command": ?Command = null,
@"notify-on-command-finish": NotifyOnCommandFinish = .never,
@"notify-on-command-finish-action": NotifyOnCommandFinishAction = .{
    .bell = true,
    .notify = false,
},
@"notify-on-command-finish-after": Duration = .{ .duration = 5 * std.time.ns_per_s },
env: RepeatableStringMap = .{},
input: RepeatableReadableIO = .{},
@"wait-after-command": bool = false,
@"abnormal-command-exit-runtime": u32 = 250,
@"scrollback-limit-bytes": Limit(usize, 50_000_000) = .default,
@"scrollback-limit-lines": Limit(usize, std.math.maxInt(usize)) = .default,
@"scrollback-compression": bool = true,
scrollbar: Scrollbar = .system,
link: RepeatableLink = .{},
@"link-url": bool = true,
@"link-osc8": bool = true,
@"link-previews": LinkPreviews = .true,
maximize: bool = false,
fullscreen: Fullscreen = .false,
title: ?[:0]const u8 = null,
class: ?[:0]const u8 = null,
@"x11-instance-name": ?[:0]const u8 = null,
@"working-directory": ?WorkingDirectory = null,
keybind: Keybinds = .{},
@"key-remap": KeyRemapSet = .empty,
@"window-padding-x": WindowPadding = .{ .top_left = 2, .bottom_right = 2 },
@"window-padding-y": WindowPadding = .{ .top_left = 2, .bottom_right = 2 },
@"window-padding-balance": WindowPaddingBalance = .false,
@"window-padding-color": WindowPaddingColor = .background,
@"window-vsync": bool = true,
@"window-inherit-working-directory": bool = true,
@"tab-inherit-working-directory": bool = true,
@"split-inherit-working-directory": bool = true,
@"window-inherit-font-size": bool = true,
@"window-decoration": WindowDecoration = .auto,
@"window-title-font-family": ?[:0]const u8 = null,
@"window-subtitle": WindowSubtitle = .false,
@"window-theme": WindowTheme = .auto,
@"window-colorspace": WindowColorspace = .srgb,
@"window-height": u32 = 0,
@"window-width": u32 = 0,
@"window-position-x": ?i16 = null,
@"window-position-y": ?i16 = null,
@"window-save-state": WindowSaveState = .default,
@"window-step-resize": bool = false,
@"window-new-tab-position": WindowNewTabPosition = .current,
@"window-show-tab-bar": WindowShowTabBar = .auto,
@"window-titlebar-background": ?Color = null,
@"window-titlebar-foreground": ?Color = null,
@"drag-handle": DragHandle = .auto,
@"resize-overlay": ResizeOverlay = .@"after-first",
@"resize-overlay-position": ResizeOverlayPosition = .center,
@"resize-overlay-duration": Duration = .{ .duration = 750 * std.time.ns_per_ms },
@"focus-follows-mouse": bool = false,
@"clipboard-read": ClipboardAccess = .ask,
@"clipboard-write": ClipboardAccess = .allow,
@"clipboard-write-limit-bytes": Limit(usize, 64 * 1024 * 1024) = .default,
@"clipboard-trim-trailing-spaces": bool = true,
@"clipboard-paste-protection": bool = true,
@"clipboard-paste-bracketed-safe": bool = true,
@"title-report": bool = false,
@"image-storage-limit": u32 = 320 * 1000 * 1000,
@"copy-on-select": CopyOnSelect = switch (builtin.os.tag) {
    .linux => .primary,
    else => .none,
},
@"right-click-action": RightClickAction = .@"context-menu",
@"middle-click-action": MiddleClickAction = .@"primary-paste",
@"click-repeat-interval": u32 = 0,
@"config-file": RepeatablePath = .{},
@"config-default-files": bool = true,
@"confirm-close-surface": ConfirmCloseSurface = .true,
@"quit-after-last-window-closed": bool = builtin.os.tag == .linux,
@"quit-after-last-window-closed-delay": ?Duration = null,
@"initial-window": bool = true,
@"undo-timeout": Duration = .{ .duration = 5 * std.time.ns_per_s },
@"quick-terminal-position": QuickTerminalPosition = .top,
@"quick-terminal-size": QuickTerminalSize = .{},
@"gtk-quick-terminal-layer": QuickTerminalLayer = .top,
@"gtk-quick-terminal-namespace": [:0]const u8 = "wasp-quick-terminal",
@"quick-terminal-screen": QuickTerminalScreen = .main,
@"quick-terminal-animation-duration": f64 = 0.2,
@"quick-terminal-autohide": bool = switch (builtin.os.tag) {
    .linux => false,
    .macos => true,
    else => false,
},
@"quick-terminal-space-behavior": QuickTerminalSpaceBehavior = .move,
@"quick-terminal-keyboard-interactivity": QuickTerminalKeyboardInteractivity = .@"on-demand",
@"shell-integration": ShellIntegration = .detect,
@"shell-integration-features": ShellIntegrationFeatures = .{},
@"command-palette-entry": RepeatableCommand = .{},
@"osc-color-report-format": OSCColorReportFormat = .@"16-bit",
@"vt-kam-allowed": bool = false,
@"vt-window-resize-allowed": bool = false,
@"vt-xt-checksum-report": bool = false,
@"vt-xt-checksum-extension": XtChecksumExtension = .{},
@"custom-shader": RepeatablePath = .{},
@"custom-shader-animation": CustomShaderAnimation = .true,
@"bell-features": BellFeatures = .{},
@"bell-audio-path": ?Path = null,
@"bell-audio-volume": f64 = 0.5,
@"app-notifications": AppNotifications = .{},
@"macos-non-native-fullscreen": NonNativeFullscreen = .false,
@"macos-window-buttons": MacWindowButtons = .visible,
@"macos-titlebar-style": MacTitlebarStyle = .transparent,
@"macos-titlebar-proxy-icon": MacTitlebarProxyIcon = .visible,
@"macos-dock-drop-behavior": MacOSDockDropBehavior = .@"new-tab",
@"macos-option-as-alt": ?inputpkg.OptionAsAlt = null,
@"macos-window-shadow": bool = true,
@"macos-hidden": MacHidden = .never,
@"macos-auto-secure-input": bool = true,
@"macos-secure-input-indication": bool = true,
@"macos-applescript": bool = true,
@"macos-icon": MacAppIcon = .official,
@"macos-custom-icon": ?[:0]const u8 = null,
@"macos-icon-frame": MacAppIconFrame = .aluminum,
@"macos-icon-ghost-color": ?Color = null,
@"macos-icon-screen-color": ?ColorList = null,
@"macos-shortcuts": MacShortcuts = .ask,
@"linux-cgroup": LinuxCgroup = if (builtin.os.tag == .linux)
    .@"single-instance"
else
    .never,
@"linux-cgroup-memory-limit": ?u64 = null,
@"linux-cgroup-processes-limit": ?u64 = null,
@"linux-cgroup-hard-fail": bool = false,
@"gtk-opengl-debug": bool = builtin.mode == .Debug,
@"gtk-single-instance": GtkSingleInstance = .default,
@"gtk-titlebar": bool = true,
@"gtk-tabs-location": GtkTabsLocation = .top,
@"gtk-tabs-inverted": bool = false,
@"gtk-titlebar-hide-when-maximized": bool = false,
@"gtk-toolbar-style": GtkToolbarStyle = .raised,
@"gtk-titlebar-style": GtkTitlebarStyle = .native,
@"gtk-wide-tabs": bool = true,
@"gtk-horizontal-tab-scroll": bool = true,
@"gtk-custom-css": RepeatablePath = .{},
@"desktop-notifications": bool = true,
@"progress-style": bool = true,
@"bold-color": ?BoldColor = null,
@"faint-opacity": f64 = 0.5,
term: []const u8 = "xterm-wasp",
@"enquiry-response": []const u8 = "",
@"async-backend": AsyncBackend = .auto,
@"auto-update": ?AutoUpdate = null,
@"auto-update-channel": ?build_config.ReleaseChannel = null,
_arena: ?ArenaAllocator = null,
_diagnostics: cli.DiagnosticList = .{},
_conditional_state: conditional.State = .{},
_conditional_set: std.EnumSet(conditional.Key) = .{},
_replay_steps: std.ArrayList(Replay.Step) = .empty,
@"_xdg-terminal-exec": bool = false,
pub fn deinit(self: *Config) void {
    if (self._arena) |arena| arena.deinit();
    self.* = undefined;
}
pub fn load(alloc_gpa: Allocator) !Config {
    var result = try default(alloc_gpa);
    errdefer result.deinit();
    try result.loadDefaultFiles(alloc_gpa);
    try result.loadCliArgs(alloc_gpa);
    try result.loadRecursiveFiles(alloc_gpa);
    try result.finalize();
    return result;
}
pub fn default(alloc_gpa: Allocator) Allocator.Error!Config {
    var result: Config = .{
        ._arena = .init(alloc_gpa),
    };
    errdefer result.deinit();
    const alloc = result._arena.?.allocator();
    try result.keybind.init(alloc);
    try result.@"command-palette-entry".init(alloc);
    try result.link.links.append(alloc, .{
        .regex = url.regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
    });
    return result;
}
pub fn loadIter(
    self: *Config,
    alloc: Allocator,
    iter: anytype,
) !void {
    try cli.args.parse(Config, alloc, self, iter);
}
pub fn loadFile(self: *Config, alloc: Allocator, path: []const u8) !void {
    assert(std.fs.path.isAbsolute(path));
    var file = file_load.open(global.io(), path) catch |err| switch (err) {
        error.NotAFile => {
            log.warn(
                "config-file {s}: not reading because it is not a file",
                .{path},
            );
            return;
        },
        else => return err,
    };
    defer file.close(global.io());
    try self.loadFsFile(alloc, &file, path);
}
fn loadFsFile(self: *Config, alloc: Allocator, file: *std.Io.File, path: []const u8) !void {
    std.log.info("reading configuration file path={s}", .{path});
    var buf: [2048]u8 = undefined;
    var file_reader = file.reader(global.io(), &buf);
    const reader = &file_reader.interface;
    try self.loadReader(alloc, reader, path);
}
fn loadReader(self: *Config, alloc: Allocator, reader: *std.Io.Reader, path: []const u8) !void {
    bom: {
        const bom: []const u8 = &.{ 0xef, 0xbb, 0xbf };
        const str = reader.peek(bom.len) catch break :bom;
        if (std.mem.eql(u8, str, bom)) {
            log.info("skipping UTF-8 byte order mark", .{});
            reader.toss(bom.len);
        }
    }
    var iter: cli.args.LineIterator = .{ .r = reader, .filepath = path };
    try self.loadIter(alloc, &iter);
    try self.expandPaths(std.fs.path.dirname(path).?);
}
test "handle bom in config files" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        const data = "\xef\xbb\xbfabnormal-command-exit-runtime = 2500\n";
        var reader: std.Io.Reader = .fixed(data);
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadReader(
            alloc,
            &reader,
            "/home/wasp/.config/wasp/config.wasp",
        );
        try cfg.finalize();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqual(
            2500,
            cfg.@"abnormal-command-exit-runtime",
        );
    }
    {
        const data = "abnormal-command-exit-runtime = 2500\n";
        var reader: std.Io.Reader = .fixed(data);
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadReader(
            alloc,
            &reader,
            "/home/wasp/.config/wasp/config.wasp",
        );
        try cfg.finalize();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqual(
            2500,
            cfg.@"abnormal-command-exit-runtime",
        );
    }
}
pub const OptionalFileAction = enum { loaded, not_found, @"error" };
pub fn loadOptionalFile(
    self: *Config,
    alloc: Allocator,
    path: []const u8,
) OptionalFileAction {
    if (self.loadFile(alloc, path)) {
        return .loaded;
    } else |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => {
            std.log.warn(
                "error reading optional config file, not loading err={} path={s}",
                .{ err, path },
            );
            return .@"error";
        },
    }
}
fn writeConfigTemplate(path: []const u8) !void {
    log.info("creating template config file: path={s}", .{path});
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(global.io(), dir_path);
    }
    const file = try std.Io.Dir.createFileAbsolute(global.io(), path, .{});
    defer file.close(global.io());
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(global.io(), &buf);
    const writer = &file_writer.interface;
    try writer.print(
        @embedFile("./config-template"),
        .{ .path = path },
    );
    try writer.flush();
}
pub fn loadDefaultFiles(self: *Config, alloc: Allocator) !void {
    const legacy_xdg_path = try file_load.legacyDefaultXdgPath(alloc);
    defer alloc.free(legacy_xdg_path);
    const xdg_path = try file_load.defaultXdgPath(alloc);
    defer alloc.free(xdg_path);
    const xdg_loaded: bool = xdg_loaded: {
        const legacy_xdg_action = self.loadOptionalFile(alloc, legacy_xdg_path);
        const xdg_action = self.loadOptionalFile(alloc, xdg_path);
        if (xdg_action != .not_found and legacy_xdg_action != .not_found) {
            log.warn("both config files `{s}` and `{s}` exist.", .{ legacy_xdg_path, xdg_path });
            log.warn("loading them both in that order", .{});
            break :xdg_loaded true;
        }
        break :xdg_loaded xdg_action != .not_found or
            legacy_xdg_action != .not_found;
    };
    if (comptime builtin.os.tag == .macos) {
        const legacy_app_support_path = try file_load.legacyDefaultAppSupportPath(alloc);
        defer alloc.free(legacy_app_support_path);
        const app_support_path = try file_load.preferredAppSupportPath(alloc);
        defer alloc.free(app_support_path);
        const app_support_loaded: bool = loaded: {
            const legacy_app_support_action = self.loadOptionalFile(
                alloc,
                legacy_app_support_path,
            );
            const app_support_action: OptionalFileAction = if (!std.mem.eql(
                u8,
                legacy_app_support_path,
                app_support_path,
            )) self.loadOptionalFile(
                alloc,
                app_support_path,
            ) else .not_found;
            if (app_support_action != .not_found and legacy_app_support_action != .not_found) {
                log.warn(
                    "both config files `{s}` and `{s}` exist.",
                    .{ legacy_app_support_path, app_support_path },
                );
                log.warn("loading them both in that order", .{});
                break :loaded true;
            }
            break :loaded app_support_action != .not_found or
                legacy_app_support_action != .not_found;
        };
        if (!app_support_loaded and !xdg_loaded) {
            writeConfigTemplate(app_support_path) catch |err| {
                log.warn("error creating template config file err={}", .{err});
            };
        }
    } else {
        if (!xdg_loaded) {
            writeConfigTemplate(xdg_path) catch |err| {
                log.warn("error creating template config file err={}", .{err});
            };
        }
    }
}
pub fn loadCliArgs(self: *Config, alloc_gpa: Allocator) !void {
    switch (builtin.os.tag) {
        .windows => {},
        .linux, .freebsd => if (global.args().vector.len <= 1) return,
        else => {},
    }
    if ((comptime builtin.os.tag == .linux) or (comptime builtin.os.tag == .freebsd)) {
        if (internal_os.xdg.parseTerminalExec(global.args().vector)) |args| {
            const arena_alloc = self._arena.?.allocator();
            try self._replay_steps.append(arena_alloc, .@"-e");
            var builder: std.ArrayList([:0]const u8) = .empty;
            errdefer builder.deinit(arena_alloc);
            for (args) |arg_raw| {
                const arg = std.mem.sliceTo(arg_raw, 0);
                const copy = try arena_alloc.dupeZ(u8, arg);
                try self._replay_steps.append(arena_alloc, .{ .arg = copy });
                try builder.append(arena_alloc, copy);
            }
            self.@"_xdg-terminal-exec" = true;
            self.@"initial-command" = .{ .direct = try builder.toOwnedSlice(arena_alloc) };
            return;
        }
    }
    self.@"config-default-files" = true;
    const replay_len_start = self._replay_steps.items.len;
    const fields = &[_][]const u8{
        "font-family",
        "font-family-bold",
        "font-family-italic",
        "font-family-bold-italic",
    };
    inline for (fields) |field| @field(self, field).overwrite_next = true;
    defer {
        inline for (fields) |field| @field(self, field).overwrite_next = false;
    }
    var iter = try cli.args.argsIterator(alloc_gpa, global.args());
    defer iter.deinit();
    try self.loadIter(alloc_gpa, &iter);
    if (!self.@"config-default-files") reload: {
        const replay_len_end = self._replay_steps.items.len;
        if (replay_len_end == replay_len_start) break :reload;
        log.info("config-default-files unset, discarding configuration from default files", .{});
        var new_config = try self.cloneEmpty(alloc_gpa);
        errdefer new_config.deinit();
        var it = Replay.iterator(
            self._replay_steps.items[replay_len_start..replay_len_end],
            &new_config,
        );
        try new_config.loadIter(alloc_gpa, &it);
        self.deinit();
        self.* = new_config;
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try self.expandPaths(buf[0..try std.Io.Dir.cwd().realPathFile(
        global.io(),
        ".",
        &buf,
    )]);
}
pub fn loadRecursiveFiles(self: *Config, alloc_gpa: Allocator) !void {
    if (self.@"config-file".value.items.len == 0) return;
    const arena_alloc = self._arena.?.allocator();
    var loaded = std.StringHashMap(void).init(alloc_gpa);
    defer loaded.deinit();
    var replay_suffix: std.ArrayList(Replay.Step) = .empty;
    defer replay_suffix.deinit(alloc_gpa);
    for (self._replay_steps.items, 0..) |step, i| if (step == .@"-e") {
        try replay_suffix.appendSlice(alloc_gpa, self._replay_steps.items[i..]);
        self._replay_steps.shrinkRetainingCapacity(i);
        break;
    };
    var i: usize = 0;
    while (i < self.@"config-file".value.items.len) : (i += 1) {
        const path, const optional = switch (self.@"config-file".value.items[i]) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };
        if (path.len == 0) continue;
        assert(std.fs.path.isAbsolute(path));
        if (try loaded.fetchPut(path, {}) != null) {
            const diag: cli.Diagnostic = .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "config-file {s}: cycle detected",
                    .{path},
                    0,
                ),
            };
            try self._diagnostics.append(arena_alloc, diag);
            try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag });
            continue;
        }
        var file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch |err| {
            if (err != error.FileNotFound or !optional) {
                const diag: cli.Diagnostic = .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "error opening config-file {s}: {}",
                        .{ path, err },
                        0,
                    ),
                };
                try self._diagnostics.append(arena_alloc, diag);
                try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag });
            }
            continue;
        };
        defer file.close(global.io());
        const stat = try file.stat(global.io());
        switch (stat.kind) {
            .file => {},
            else => |kind| {
                const diag: cli.Diagnostic = .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "config-file {s}: not reading because file type is {s}",
                        .{ path, @tagName(kind) },
                        0,
                    ),
                };
                try self._diagnostics.append(arena_alloc, diag);
                try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag });
                continue;
            },
        }
        try self.loadFsFile(arena_alloc, &file, path);
    }
    if (replay_suffix.items.len > 0) {
        try self._replay_steps.appendSlice(
            arena_alloc,
            replay_suffix.items,
        );
    }
}
pub fn arenaAlloc(self: *Config) Allocator {
    return self._arena.?.allocator();
}
pub fn changeConditionalState(
    self: *const Config,
    new: conditional.State,
) !?Config {
    relevant: {
        inline for (@typeInfo(conditional.Key).@"enum".fields) |field| {
            const key: conditional.Key = @field(conditional.Key, field.name);
            if (self._conditional_set.contains(key) and !deepEqual(
                @TypeOf(@field(self._conditional_state, field.name)),
                @field(self._conditional_state, field.name),
                @field(new, field.name),
            )) {
                break :relevant;
            }
        }
        return null;
    }
    const alloc_gpa = self._arena.?.child_allocator;
    var new_config = try self.cloneEmpty(alloc_gpa);
    errdefer new_config.deinit();
    new_config._conditional_state = new;
    var it = Replay.iterator(self._replay_steps.items, &new_config);
    try new_config.loadIter(alloc_gpa, &it);
    try new_config.finalize();
    return new_config;
}
fn expandPaths(self: *Config, base: []const u8) !void {
    const arena_alloc = self._arena.?.allocator();
    try self._replay_steps.append(
        arena_alloc,
        .{ .expand = try arena_alloc.dupe(u8, base) },
    );
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        switch (field.type) {
            RepeatablePath, Path => {
                try @field(self, field.name).expand(
                    arena_alloc,
                    base,
                    &self._diagnostics,
                );
            },
            ?RepeatablePath, ?Path => {
                if (@field(self, field.name)) |*path| {
                    try path.expand(
                        arena_alloc,
                        base,
                        &self._diagnostics,
                    );
                }
            },
            else => {},
        }
    }
}
fn expandHome(path: []const u8, buf: []u8) []const u8 {
    if (!std.mem.startsWith(u8, path, "~/"))
        return path;
    var environ_map = global.environMap() catch |err| {
        log.warn("failed to get environment map for path \"{s}\": {}", .{ path, err });
        return path;
    };
    defer environ_map.deinit();
    return internal_os.expandHome(
        global.io(),
        &environ_map,
        path,
        buf,
    ) catch |err| {
        log.warn("failed to expand home directory in path \"{s}\": {}", .{ path, err });
        return path;
    };
}
fn loadTheme(self: *Config, theme: Theme) !void {
    const name: []const u8 = switch (self._conditional_state.theme) {
        .light => theme.light,
        .dark => theme.dark,
    };
    const themefile = (try themepkg.open(
        self._arena.?.allocator(),
        name,
        &self._diagnostics,
    )) orelse return;
    const path = themefile.path;
    const file = themefile.file;
    defer file.close(global.io());
    const alloc_gpa = self._arena.?.child_allocator;
    var new_config = try self.cloneEmpty(alloc_gpa);
    errdefer new_config.deinit();
    var buf: [2048]u8 = undefined;
    var file_reader = file.reader(global.io(), &buf);
    const reader = &file_reader.interface;
    var iter: cli.args.LineIterator = .{ .r = reader, .filepath = path };
    try new_config.loadIter(alloc_gpa, &iter);
    conditional: for (new_config._replay_steps.items) |*item| {
        switch (item.*) {
            .expand, .diagnostic => {},
            .@"-e" => break :conditional,
            .arg => |v| {
                const alloc_arena = new_config._arena.?.allocator();
                const conds = try alloc_arena.alloc(Conditional, 1);
                conds[0] = .{
                    .key = .theme,
                    .op = .eq,
                    .value = @tagName(self._conditional_state.theme),
                };
                item.* = .{ .conditional_arg = .{
                    .conditions = conds,
                    .arg = v,
                } };
            },
            .conditional_arg => |v| {
                const alloc_arena = new_config._arena.?.allocator();
                const conds = try alloc_arena.alloc(Conditional, v.conditions.len + 1);
                conds[0] = .{
                    .key = .theme,
                    .op = .eq,
                    .value = @tagName(self._conditional_state.theme),
                };
                @memcpy(conds[1..], v.conditions);
                item.* = .{ .conditional_arg = .{
                    .conditions = conds,
                    .arg = v.arg,
                } };
            },
        }
    }
    var slice_it = Replay.iterator(self._replay_steps.items, &new_config);
    try new_config.loadIter(alloc_gpa, &slice_it);
    self.deinit();
    self.* = new_config;
}
pub fn finalize(self: *Config) !void {
    const alloc = self._arena.?.allocator();
    if (self.theme) |*theme| {
        try theme.finalize(alloc);
        const different = !std.mem.eql(u8, theme.light, theme.dark);
        try self.loadTheme(theme.*);
        if (different) {
            if (self.@"window-theme" == .auto) self.@"window-theme" = .system;
            self._conditional_set.insert(.theme);
        }
    }
    const probable_cli = probableCliEnvironment();
    if (self.@"font-family".count() > 0) {
        const fields = &[_][]const u8{
            "font-family-bold",
            "font-family-italic",
            "font-family-bold-italic",
        };
        inline for (fields) |field| {
            if (@field(self, field).count() == 0) {
                @field(self, field) = try self.@"font-family".clone(alloc);
            }
        }
    }
    if (self.term.len == 0) {
        self.term = "xterm-wasp";
    }
    var wd: WorkingDirectory = self.@"working-directory" orelse if (probable_cli)
        .inherit
    else
        .home;
    if ((comptime !builtin.target.cpu.arch.isWasm()) and
        (comptime !builtin.is_test))
    {
        if (self.command == null or wd == .home) command: {
            if (self.command) |cmd|
                log.info("shell src=config value={}", .{cmd})
            else shell_env: {
                if (internal_os.isFlatpak()) break :shell_env;
                if (!probable_cli) break :shell_env;
                const value = global.environ().getAlloc(alloc, "SHELL") catch |err| switch (err) {
                    error.EnvironmentVariableMissing => break :shell_env,
                    else => return err,
                };
                defer alloc.free(value);
                log.info("default shell source=env value={s}", .{value});
                const copy = try alloc.dupeZ(u8, value);
                self.command = .{ .shell = copy };
                if (wd != .home) break :command;
            }
            switch (builtin.os.tag) {
                .windows => {
                    if (self.command == null) {
                        log.warn("no default shell found, will default to using cmd", .{});
                        self.command = .{ .shell = "cmd.exe" };
                    }
                    if (wd == .home) {
                        var environ_map = try global.environMap();
                        defer environ_map.deinit();
                        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        if (try internal_os.home(global.io(), &environ_map, &buf)) |home| {
                            wd = .{ .path = try alloc.dupe(u8, home) };
                        } else {
                            wd = .inherit;
                        }
                    }
                },
                else => {
                    const pw = try internal_os.passwd.get(alloc);
                    if (self.command == null) {
                        if (pw.shell) |sh| {
                            log.info("default shell src=passwd value={s}", .{sh});
                            self.command = .{ .shell = sh };
                        }
                    }
                    if (wd == .home) {
                        if (pw.home) |home| {
                            log.info("default working directory src=passwd value={s}", .{home});
                            wd = .{ .path = home };
                        } else {
                            wd = .inherit;
                        }
                    }
                    if (self.command == null) {
                        log.warn("no default shell found, will default to using sh", .{});
                    }
                },
            }
        }
    }
    try wd.finalize(alloc);
    self.@"working-directory" = wd;
    switch (build_config.app_runtime) {
        .none => {},
        .gtk => {
            switch (self.@"gtk-single-instance") {
                .true, .false => {},
                .detect => self.@"gtk-single-instance" = if (probable_cli)
                    .false
                else
                    .true,
            }
        },
    }
    if (self.@"click-repeat-interval" == 0 and
        (comptime !builtin.is_test))
    {
        self.@"click-repeat-interval" = internal_os.clickInterval() orelse 500;
    }
    self.@"mouse-scroll-multiplier".precision = @min(10_000.0, @max(0.01, self.@"mouse-scroll-multiplier".precision));
    self.@"mouse-scroll-multiplier".discrete = @min(10_000.0, @max(0.01, self.@"mouse-scroll-multiplier".discrete));
    self.@"unfocused-split-opacity" = @min(1.0, @max(0.15, self.@"unfocused-split-opacity"));
    self.@"minimum-contrast" = @min(21, @max(1, self.@"minimum-contrast"));
    if (self.@"window-width" > 0) self.@"window-width" = @max(10, self.@"window-width");
    if (self.@"window-height" > 0) self.@"window-height" = @max(4, self.@"window-height");
    if (!self.@"link-url") self.link.links.items = self.link.links.items[1..];
    if (self.@"quit-after-last-window-closed-delay") |duration| {
        if (duration.duration < 5 * std.time.ns_per_s) {
            log.warn(
                "quit-after-last-window-closed-delay is set to a very short value ({f}), which might cause problems",
                .{duration},
            );
        }
    }
    if (self.@"auto-update-channel" == null) {
        self.@"auto-update-channel" = build_config.release_channel;
    }
    self.@"faint-opacity" = std.math.clamp(self.@"faint-opacity", 0.0, 1.0);
    self.@"key-remap".finalize();
}
pub fn parseManuallyHook(
    self: *Config,
    alloc: Allocator,
    arg: []const u8,
    iter: anytype,
) !bool {
    if (std.mem.eql(u8, arg, "-e")) {
        try self._replay_steps.append(alloc, .@"-e");
        var command: std.ArrayList([:0]const u8) = .empty;
        errdefer command.deinit(alloc);
        while (iter.next()) |param| {
            const copy = try alloc.dupeZ(u8, param);
            try self._replay_steps.append(alloc, .{ .arg = copy });
            try command.append(alloc, copy);
        }
        if (command.items.len == 0) {
            try self._diagnostics.append(alloc, .{
                .location = try cli.Location.fromIter(iter, alloc),
                .message = try std.fmt.allocPrintSentinel(
                    alloc,
                    "missing command after {s}",
                    .{arg},
                    0,
                ),
            });
            return false;
        }
        self.@"initial-command" = .{ .direct = command.items };
        self.@"gtk-single-instance" = .false;
        self.@"quit-after-last-window-closed" = true;
        self.@"quit-after-last-window-closed-delay" = null;
        if (self.@"shell-integration" != .none) {
            self.@"shell-integration" = .detect;
        }
        return false;
    }
    try self._replay_steps.append(
        alloc,
        .{ .arg = try alloc.dupeZ(u8, arg) },
    );
    return true;
}
fn compatGtkTabsLocation(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "gtk-tabs-location"));
    if (std.mem.eql(u8, value orelse "", "hidden")) {
        self.@"window-show-tab-bar" = .never;
        return true;
    }
    return false;
}
fn compatGtkSingleInstance(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "gtk-single-instance"));
    if (std.mem.eql(u8, value orelse "", "desktop")) {
        self.@"gtk-single-instance" = .detect;
        return true;
    }
    return false;
}
fn compatCursorInvertFgBg(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value_: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "cursor-invert-fg-bg"));
    const set = cli.args.parseBool(value_ orelse "t") catch return false;
    if (set) {
        self.@"cursor-color" = .@"cell-foreground";
        self.@"cursor-text" = .@"cell-background";
    }
    return true;
}
fn compatSelectionInvertFgBg(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value_: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "selection-invert-fg-bg"));
    const set = cli.args.parseBool(value_ orelse "t") catch return false;
    if (set) {
        self.@"selection-foreground" = .@"cell-background";
        self.@"selection-background" = .@"cell-foreground";
    }
    return true;
}
fn compatBoldIsBright(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value_: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "bold-is-bright"));
    const isset = cli.args.parseBool(value_ orelse "t") catch return false;
    if (isset) {
        self.@"bold-color" = .bright;
    }
    return true;
}
fn compatMacOSDockDropBehavior(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "macos-dock-drop-behavior"));
    if (std.mem.eql(u8, value orelse "", "window")) {
        self.@"macos-dock-drop-behavior" = .@"new-window";
        return true;
    }
    return false;
}
fn compatCopyOnSelect(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "copy-on-select"));
    if (std.mem.eql(u8, value orelse "", "true")) {
        self.@"copy-on-select" = switch (builtin.os.tag) {
            .linux, .freebsd => .primary,
            else => .clipboard,
        };
        return true;
    }
    if (std.mem.eql(u8, value orelse "", "false")) {
        self.@"copy-on-select" = .none;
        return true;
    }
    return false;
}
pub fn addDiagnosticFmt(
    self: *Config,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const alloc = self._arena.?.allocator();
    try self._diagnostics.append(alloc, .{
        .message = try std.fmt.allocPrintSentinel(
            alloc,
            fmt,
            args,
            0,
        ),
    });
}
pub fn shallowClone(self: *const Config, alloc_gpa: Allocator) Config {
    var result = self.*;
    result._arena = .init(alloc_gpa);
    return result;
}
pub fn cloneEmpty(
    self: *const Config,
    alloc_gpa: Allocator,
) Allocator.Error!Config {
    var result = try default(alloc_gpa);
    result._conditional_state = self._conditional_state;
    return result;
}
pub fn clone(
    self: *const Config,
    alloc_gpa: Allocator,
) Allocator.Error!Config {
    var result = try self.cloneEmpty(alloc_gpa);
    errdefer result.deinit();
    const alloc_arena = result._arena.?.allocator();
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (!@hasField(Key, field.name)) continue;
        @field(result, field.name) = try cloneValue(
            alloc_arena,
            field.type,
            @field(self, field.name),
        );
    }
    result._diagnostics = try self._diagnostics.clone(alloc_arena);
    try result._replay_steps.ensureTotalCapacity(
        alloc_arena,
        self._replay_steps.items.len,
    );
    for (self._replay_steps.items) |item| {
        result._replay_steps.appendAssumeCapacity(
            try item.clone(alloc_arena),
        );
    }
    assert(result._replay_steps.items.len == self._replay_steps.items.len);
    result._conditional_set = self._conditional_set;
    return result;
}
fn cloneValue(
    alloc: Allocator,
    comptime T: type,
    src: T,
) Allocator.Error!T {
    switch (T) {
        []const u8 => return try alloc.dupe(u8, src),
        [:0]const u8 => return try alloc.dupeZ(u8, src),
        else => {},
    }
    const t = @typeInfo(T);
    if (t == .@"struct" or t == .@"enum" or t == .@"union") {
        if (@hasDecl(T, "clone")) return try src.clone(alloc);
    }
    switch (t) {
        inline .bool,
        .int,
        .float,
        .@"enum",
        .@"union",
        => return src,
        .optional => |info| return try cloneValue(
            alloc,
            info.child,
            src orelse return null,
        ),
        .@"struct" => |info| {
            assert(info.layout == .@"packed");
            return src;
        },
        else => {
            @compileLog(T);
            @compileError("unsupported field type");
        },
    }
}
pub fn changeIterator(old: *const Config, new: *const Config) ChangeIterator {
    return .{
        .old = old,
        .new = new,
    };
}
pub fn changed(self: *const Config, new: *const Config, comptime key: Key) bool {
    const field = comptime field: {
        const fields = std.meta.fields(Config);
        for (fields) |field| {
            if (@field(Key, field.name) == key) {
                break :field field;
            }
        }
        unreachable;
    };
    const old_value = @field(self, field.name);
    const new_value = @field(new, field.name);
    return !deepEqual(field.type, old_value, new_value);
}
pub const ChangeIterator = struct {
    old: *const Config,
    new: *const Config,
    i: usize = 0,
    pub fn next(self: *ChangeIterator) ?Key {
        const fields = comptime std.meta.fields(Key);
        while (self.i < fields.len) {
            switch (self.i) {
                inline 0...(fields.len - 1) => |i| {
                    const field = fields[i];
                    const key = @field(Key, field.name);
                    self.i += 1;
                    if (self.old.changed(self.new, key)) return key;
                },
                else => unreachable,
            }
        }
        return null;
    }
};
fn probableCliEnvironment() bool {
    switch (builtin.os.tag) {
        .windows => return false,
        .macos => if (internal_os.launchedFromDesktop()) return false,
        else => {},
    }
    if (global.environ().containsUnemptyConstant("TERM_PROGRAM")) return true;
    if (global.args().vector.len > 1) return true;
    return false;
}
const Replay = struct {
    const Step = union(enum) {
        arg: [:0]const u8,
        expand: []const u8,
        conditional_arg: struct {
            conditions: []const Conditional,
            arg: []const u8,
        },
        diagnostic: cli.Diagnostic,
        @"-e",
        fn clone(
            self: Step,
            alloc: Allocator,
        ) Allocator.Error!Step {
            return switch (self) {
                .@"-e" => self,
                .diagnostic => |v| .{ .diagnostic = try v.clone(alloc) },
                .arg => |v| .{ .arg = try alloc.dupeZ(u8, v) },
                .expand => |v| .{ .expand = try alloc.dupe(u8, v) },
                .conditional_arg => |v| conditional: {
                    var conds = try alloc.alloc(Conditional, v.conditions.len);
                    for (v.conditions, 0..) |cond, i| conds[i] = try cond.clone(alloc);
                    break :conditional .{ .conditional_arg = .{
                        .conditions = conds,
                        .arg = try alloc.dupe(u8, v.arg),
                    } };
                },
            };
        }
    };
    const Iterator = struct {
        const Self = @This();
        config: *Config,
        slice: []const Replay.Step,
        idx: usize = 0,
        pub fn next(self: *Self) ?[]const u8 {
            while (true) {
                if (self.idx >= self.slice.len) return null;
                defer self.idx += 1;
                switch (self.slice[self.idx]) {
                    .expand => |base| self.config.expandPaths(base) catch |err| {
                        log.warn("error expanding paths err={}", .{err});
                    },
                    .diagnostic => |diag| diag: {
                        const arena_alloc = self.config._arena.?.allocator();
                        const cloned = diag.clone(arena_alloc) catch |err| {
                            log.warn("error cloning diagnostic err={}", .{err});
                            break :diag;
                        };
                        self.config._diagnostics.append(arena_alloc, cloned) catch |err| {
                            log.warn("error appending diagnostic err={}", .{err});
                            break :diag;
                        };
                    },
                    .conditional_arg => |v| conditional: {
                        for (v.conditions) |cond| {
                            if (!self.config._conditional_state.match(cond)) {
                                break :conditional;
                            }
                        }
                        return v.arg;
                    },
                    .arg => |arg| return arg,
                    .@"-e" => return "-e",
                }
            }
        }
    };
    fn iterator(slice: []const Replay.Step, dst: *Config) Iterator {
        return .{ .slice = slice, .config = dst };
    }
};
pub const ConfirmCloseSurface = enum(c_int) {
    false,
    true,
    always,
};
pub const CustomShaderAnimation = enum(c_int) {
    false,
    true,
    always,
};
pub const NonNativeFullscreen = enum(c_int) {
    false,
    true,
    @"visible-menu",
    @"padded-notch",
};
pub const Fullscreen = enum(c_int) {
    false,
    true,
    @"non-native",
    @"non-native-visible-menu",
    @"non-native-padded-notch",
};
pub const WindowPaddingColor = enum {
    background,
    extend,
    @"extend-always",
};
pub const WindowSubtitle = enum {
    false,
    @"working-directory",
};
pub const LinkPreviews = enum {
    false,
    true,
    osc8,
};
pub const WorkingDirectory = union(enum) {
    const Self = @This();
    home,
    inherit,
    path: []const u8,
    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        var input = input_ orelse return error.ValueRequired;
        input = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (input.len == 0) return error.ValueRequired;
        if (input.len >= 2 and input[0] == '"' and input[input.len - 1] == '"') {
            input = input[1 .. input.len - 1];
        }
        if (std.mem.eql(u8, input, "home")) {
            self.* = .home;
            return;
        }
        if (std.mem.eql(u8, input, "inherit")) {
            self.* = .inherit;
            return;
        }
        self.* = .{ .path = try alloc.dupe(u8, input) };
    }
    pub fn finalize(self: *Self, alloc: Allocator) Allocator.Error!void {
        const path = switch (self.*) {
            .path => |path| path,
            else => return,
        };
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const expanded = expandHome(path, &buf);
        if (std.mem.eql(u8, expanded, path)) return;
        self.* = .{ .path = try alloc.dupe(u8, expanded) };
    }
    pub fn value(self: Self) ?[]const u8 {
        return switch (self) {
            .path => |path| path,
            .home, .inherit => null,
        };
    }
    pub fn clone(self: Self, alloc: Allocator) Allocator.Error!Self {
        return switch (self) {
            .path => |path| .{ .path = try alloc.dupe(u8, path) },
            else => self,
        };
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        switch (self) {
            .home, .inherit => try formatter.formatEntry([]const u8, @tagName(self)),
            .path => |path| try formatter.formatEntry([]const u8, path),
        }
    }
    test "WorkingDirectory parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var wd: Self = .inherit;
        try wd.parseCLI(alloc, "inherit");
        try testing.expectEqual(.inherit, wd);
        try wd.parseCLI(alloc, "home");
        try testing.expectEqual(.home, wd);
        try wd.parseCLI(alloc, "~/projects/wasp");
        try testing.expectEqualStrings("~/projects/wasp", wd.path);
        try wd.parseCLI(alloc, "\"/tmp path\"");
        try testing.expectEqualStrings("/tmp path", wd.path);
    }
    test "WorkingDirectory finalize" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var environ_map = try testing.environ.createMap(testing.allocator);
        defer environ_map.deinit();
        {
            var wd: Self = .{ .path = "~/projects/wasp" };
            try wd.finalize(alloc);
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const expected = internal_os.expandHome(
                testing.io,
                &environ_map,
                "~/projects/wasp",
                &buf,
            ) catch "~/projects/wasp";
            try testing.expectEqualStrings(expected, wd.value().?);
        }
    }
};
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    pub const C = extern struct {
        r: u8,
        g: u8,
        b: u8,
    };
    pub fn cval(self: Color) Color.C {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }
    pub fn toTerminalRGB(self: Color) terminal.color.RGB {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }
    pub fn parseCLI(input_: ?[]const u8) !Color {
        const input = input_ orelse return error.ValueRequired;
        const rgb: terminal.color.RGB = terminal.color.RGB.parse(input) catch return error.InvalidValue;
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }
    pub fn clone(self: Color, _: Allocator) error{}!Color {
        return self;
    }
    pub fn equal(self: Color, other: Color) bool {
        return std.meta.eql(self, other);
    }
    pub fn formatEntry(self: Color, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [128]u8 = undefined;
        try formatter.formatEntry(
            []const u8,
            try self.formatBuf(&buf),
        );
    }
    pub fn formatBuf(self: Color, buf: []u8) Allocator.Error![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "#{x:0>2}{x:0>2}{x:0>2}",
            .{ self.r, self.g, self.b },
        ) catch error.OutOfMemory;
    }
    test "parseCLI hex" {
        const testing = std.testing;
        try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.parseCLI("#000000"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.parseCLI("#0A0B0C"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.parseCLI("0A0B0C"));
        try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.parseCLI("FFFFFF"));
        try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.parseCLI("FFF"));
        try testing.expectEqual(Color{ .r = 51, .g = 68, .b = 85 }, try Color.parseCLI("#345"));
    }
    test "parseCLI from name" {
        try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.parseCLI("black"));
    }
    test "formatConfig" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var color: Color = .{ .r = 10, .g = 11, .b = 12 };
        try color.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = #0a0b0c\n", buf.written());
    }
    test "parseCLI with whitespace" {
        const testing = std.testing;
        try testing.expectEqual(
            Color{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
            try Color.parseCLI(" #AABBCC   "),
        );
        try testing.expectEqual(
            Color{ .r = 0, .g = 0, .b = 0 },
            try Color.parseCLI("  black "),
        );
    }
};
pub const TerminalColor = union(enum) {
    color: Color,
    @"cell-foreground",
    @"cell-background",
    pub fn parseCLI(input_: ?[]const u8) !TerminalColor {
        const input = input_ orelse return error.ValueRequired;
        if (std.mem.eql(u8, input, "cell-foreground")) return .@"cell-foreground";
        if (std.mem.eql(u8, input, "cell-background")) return .@"cell-background";
        return .{ .color = try Color.parseCLI(input) };
    }
    pub fn toTerminalRGB(self: TerminalColor) ?terminal.color.RGB {
        return switch (self) {
            .color => |v| v.toTerminalRGB(),
            .@"cell-foreground", .@"cell-background" => null,
        };
    }
    pub fn formatEntry(self: TerminalColor, formatter: formatterpkg.EntryFormatter) !void {
        switch (self) {
            .color => try self.color.formatEntry(formatter),
            .@"cell-foreground",
            .@"cell-background",
            => try formatter.formatEntry([:0]const u8, @tagName(self)),
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        try testing.expectEqual(
            TerminalColor{ .color = Color{ .r = 78, .g = 42, .b = 132 } },
            try TerminalColor.parseCLI("#4e2a84"),
        );
        try testing.expectEqual(
            TerminalColor{ .color = Color{ .r = 0, .g = 0, .b = 0 } },
            try TerminalColor.parseCLI("black"),
        );
        try testing.expectEqual(
            TerminalColor.@"cell-foreground",
            try TerminalColor.parseCLI("cell-foreground"),
        );
        try testing.expectEqual(
            TerminalColor.@"cell-background",
            try TerminalColor.parseCLI("cell-background"),
        );
        try testing.expectError(error.InvalidValue, TerminalColor.parseCLI("a"));
    }
    test "formatConfig" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var sc: TerminalColor = .@"cell-foreground";
        try sc.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try testing.expectEqualSlices(u8, "a = cell-foreground\n", buf.written());
    }
};
pub const BoldColor = union(enum) {
    color: Color,
    bright,
    pub fn toTerminal(self: BoldColor) terminal.style.Style.BoldColor {
        return switch (self) {
            .color => |col| .{ .color = col.toTerminalRGB() },
            .bright => .bright,
        };
    }
    pub fn parseCLI(input_: ?[]const u8) !BoldColor {
        const input = input_ orelse return error.ValueRequired;
        if (std.mem.eql(u8, input, "bright")) return .bright;
        return .{ .color = try Color.parseCLI(input) };
    }
    pub fn formatEntry(self: BoldColor, formatter: formatterpkg.EntryFormatter) !void {
        switch (self) {
            .color => try self.color.formatEntry(formatter),
            .bright => try formatter.formatEntry(
                [:0]const u8,
                @tagName(self),
            ),
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        try testing.expectEqual(
            BoldColor{ .color = Color{ .r = 78, .g = 42, .b = 132 } },
            try BoldColor.parseCLI("#4e2a84"),
        );
        try testing.expectEqual(
            BoldColor{ .color = Color{ .r = 0, .g = 0, .b = 0 } },
            try BoldColor.parseCLI("black"),
        );
        try testing.expectEqual(
            BoldColor.bright,
            try BoldColor.parseCLI("bright"),
        );
        try testing.expectError(error.InvalidValue, BoldColor.parseCLI("a"));
    }
    test "formatConfig" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var sc: BoldColor = .bright;
        try sc.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try testing.expectEqualSlices(u8, "a = bright\n", buf.written());
    }
};
pub const ColorList = struct {
    const Self = @This();
    colors: std.ArrayList(Color) = .empty,
    colors_c: std.ArrayList(Color.C) = .empty,
    pub const C = extern struct {
        colors: [*]Color.C,
        len: usize,
    };
    pub fn cval(self: *const Self) C {
        return .{
            .colors = self.colors_c.items.ptr,
            .len = self.colors_c.items.len,
        };
    }
    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) return error.ValueRequired;
        self.* = .{};
        var it = std.mem.tokenizeScalar(u8, input, ',');
        var count: usize = 0;
        while (it.next()) |raw| {
            count += 1;
            if (count > 64) return error.InvalidValue;
            const trimmed = std.mem.trim(u8, raw, " \t");
            const color = try Color.parseCLI(trimmed);
            try self.colors.append(alloc, color);
            try self.colors_c.append(alloc, color.cval());
        }
        if (self.colors.items.len == 0) return error.InvalidValue;
        assert(self.colors.items.len == self.colors_c.items.len);
    }
    pub fn clone(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        return .{
            .colors = try self.colors.clone(alloc),
            .colors_c = try self.colors_c.clone(alloc),
        };
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.colors.items;
        const itemsB = other.colors.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!a.equal(b)) return false;
        } else return true;
    }
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.colors.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        for (self.colors.items, 0..) |color, i| {
            var color_buf: [128]u8 = undefined;
            const color_str = try color.formatBuf(&color_buf);
            if (i != 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll(color_str) catch return error.OutOfMemory;
        }
        try formatter.formatEntry(
            []const u8,
            writer.buffered(),
        );
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p: Self = .{};
        try p.parseCLI(alloc, "black,white");
        try testing.expectEqual(2, p.colors.items.len);
        try p.parseCLI(alloc, "black, white");
        try testing.expectEqual(2, p.colors.items.len);
        try p.parseCLI(alloc, "black , white");
        try testing.expectEqual(2, p.colors.items.len);
        try p.parseCLI(alloc, " black , white ");
        try testing.expectEqual(2, p.colors.items.len);
        try testing.expectError(error.ValueRequired, p.parseCLI(alloc, null));
        try testing.expectError(error.InvalidValue, p.parseCLI(alloc, " "));
    }
    test "format" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p: Self = .{};
        try p.parseCLI(alloc, "black,white");
        try p.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = #000000,#ffffff\n", buf.written());
    }
    test "clone" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var source: Self = .{};
        try source.parseCLI(alloc, "#ff0000,#00ff00,#0000ff");
        const cloned = try source.clone(alloc);
        try testing.expect(source.equal(cloned));
        try testing.expectEqual(source.colors_c.items.len, cloned.colors_c.items.len);
        for (source.colors_c.items, cloned.colors_c.items) |src_c, clone_c| {
            try testing.expectEqual(src_c.r, clone_c.r);
            try testing.expectEqual(src_c.g, clone_c.g);
            try testing.expectEqual(src_c.b, clone_c.b);
        }
    }
};
pub const Palette = struct {
    const Self = @This();
    value: terminal.color.Palette = terminal.color.default,
    mask: terminal.color.PaletteMask = .initEmpty(),
    pub const C = extern struct {
        colors: [256]Color.C,
    };
    pub fn cval(self: Self) Palette.C {
        var result: Palette.C = undefined;
        for (self.value, 0..) |color, i| {
            result.colors[i] = Color.C{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            };
        }
        return result;
    }
    pub fn parseCLI(
        self: *Self,
        input: ?[]const u8,
    ) !void {
        const value = input orelse return error.ValueRequired;
        const entry = terminal.color.parsePaletteEntry(value) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.InvalidFormat => return error.InvalidValue,
        };
        self.value[entry.index] = entry.color;
        self.mask.set(entry.index);
    }
    pub fn clone(self: Self, _: Allocator) error{}!Self {
        return self;
    }
    pub fn equal(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [128]u8 = undefined;
        for (0.., self.value) |k, v| {
            try formatter.formatEntry(
                []const u8,
                std.fmt.bufPrint(
                    &buf,
                    "{d}=#{x:0>2}{x:0>2}{x:0>2}",
                    .{ k, v.r, v.g, v.b },
                ) catch return error.OutOfMemory,
            );
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var p: Self = .{};
        try p.parseCLI("0=#AABBCC");
        try testing.expect(p.value[0].r == 0xAA);
        try testing.expect(p.value[0].g == 0xBB);
        try testing.expect(p.value[0].b == 0xCC);
        try testing.expect(p.mask.isSet(0));
        try testing.expect(!p.mask.isSet(1));
    }
    test "parseCLI base" {
        const testing = std.testing;
        var p: Self = .{};
        try p.parseCLI("0b1=#014589");
        try p.parseCLI("0o7=#234567");
        try p.parseCLI("0xF=#ABCDEF");
        try testing.expect(p.value[0b1].r == 0x01);
        try testing.expect(p.value[0b1].g == 0x45);
        try testing.expect(p.value[0b1].b == 0x89);
        try testing.expect(p.value[0o7].r == 0x23);
        try testing.expect(p.value[0o7].g == 0x45);
        try testing.expect(p.value[0o7].b == 0x67);
        try testing.expect(p.value[0xF].r == 0xAB);
        try testing.expect(p.value[0xF].g == 0xCD);
        try testing.expect(p.value[0xF].b == 0xEF);
        try testing.expect(p.mask.isSet(0b1));
        try testing.expect(p.mask.isSet(0o7));
        try testing.expect(p.mask.isSet(0xF));
        try testing.expect(!p.mask.isSet(0));
        try testing.expect(!p.mask.isSet(2));
    }
    test "parseCLI overflow" {
        const testing = std.testing;
        var p: Self = .{};
        try testing.expectError(error.Overflow, p.parseCLI("256=#AABBCC"));
        try testing.expectEqual(@as(usize, 0), p.mask.count());
    }
    test "formatConfig" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var list: Self = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = 0=#1d1f21\n", buf.written()[0..14]);
    }
    test "parseCLI with whitespace" {
        const testing = std.testing;
        var p: Self = .{};
        try p.parseCLI("0 =  #AABBCC");
        try p.parseCLI(" 1= #DDEEFF    ");
        try p.parseCLI("  2  =  #123456 ");
        try testing.expect(p.value[0].r == 0xAA);
        try testing.expect(p.value[0].g == 0xBB);
        try testing.expect(p.value[0].b == 0xCC);
        try testing.expect(p.value[1].r == 0xDD);
        try testing.expect(p.value[1].g == 0xEE);
        try testing.expect(p.value[1].b == 0xFF);
        try testing.expect(p.value[2].r == 0x12);
        try testing.expect(p.value[2].g == 0x34);
        try testing.expect(p.value[2].b == 0x56);
        try testing.expect(p.mask.isSet(0));
        try testing.expect(p.mask.isSet(1));
        try testing.expect(p.mask.isSet(2));
        try testing.expect(!p.mask.isSet(3));
    }
};
pub const RepeatableString = struct {
    const Self = @This();
    list: std.ArrayList([:0]const u8) = .empty,
    overwrite_next: bool = false,
    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;
        if (value.len == 0) {
            self.list.clearRetainingCapacity();
            return;
        }
        if (self.overwrite_next) {
            self.list.clearRetainingCapacity();
            self.overwrite_next = false;
        }
        const copy = try alloc.dupeZ(u8, value);
        try self.list.append(alloc, copy);
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        var list = try std.ArrayListUnmanaged([:0]const u8).initCapacity(
            alloc,
            self.list.items.len,
        );
        errdefer {
            for (list.items) |item| alloc.free(item);
            list.deinit(alloc);
        }
        for (self.list.items) |item| {
            const copy = try alloc.dupeZ(u8, item);
            list.appendAssumeCapacity(copy);
        }
        return .{ .list = list };
    }
    pub fn count(self: Self) usize {
        return self.list.items.len;
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        } else return true;
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        if (self.list.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        for (self.list.items) |value| {
            try formatter.formatEntry([]const u8, value);
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "B");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);
        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.list.items.len);
    }
    test "parseCLI overwrite" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        list.overwrite_next = true;
        try list.parseCLI(alloc, "B");
        try testing.expectEqual(@as(usize, 1), list.list.items.len);
        try list.parseCLI(alloc, "C");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);
    }
    test "formatConfig empty" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var list: Self = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = \n", buf.written());
    }
    test "formatConfig single item" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A\n", buf.written());
    }
    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "B");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A\na = B\n", buf.written());
    }
};
pub const SelectionWordChars = struct {
    const Self = @This();
    codepoints: []const u21 = &terminal.selection_codepoints.default_word_boundaries,
    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;
        var list: std.ArrayList(u21) = .empty;
        defer list.deinit(alloc);
        try list.append(alloc, 0);
        var it = string.codepointIterator(value);
        while (it.next() catch return error.InvalidValue) |codepoint| {
            try list.append(alloc, codepoint);
        }
        self.codepoints = try list.toOwnedSlice(alloc);
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        const copy = try alloc.dupe(u21, self.codepoints);
        return .{ .codepoints = copy };
    }
    pub fn equal(self: Self, other: Self) bool {
        return std.mem.eql(u21, self.codepoints, other.codepoints);
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        for (self.codepoints[1..]) |codepoint| {
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
            if (pos + len > buf.len) break;
            @memcpy(buf[pos..][0..len], utf8_buf[0..len]);
            pos += len;
        }
        try formatter.formatEntry([]const u8, buf[0..pos]);
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var chars: Self = .{};
        try chars.parseCLI(alloc, " \t;,");
        try testing.expectEqual(@as(usize, 5), chars.codepoints.len);
        try testing.expectEqual(@as(u21, 0), chars.codepoints[0]);
        try testing.expectEqual(@as(u21, ' '), chars.codepoints[1]);
        try testing.expectEqual(@as(u21, '\t'), chars.codepoints[2]);
        try testing.expectEqual(@as(u21, ';'), chars.codepoints[3]);
        try testing.expectEqual(@as(u21, ','), chars.codepoints[4]);
    }
    test "parseCLI escape sequences" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var chars: Self = .{};
        try chars.parseCLI(alloc, " \\t;,");
        try testing.expectEqual(@as(usize, 5), chars.codepoints.len);
        try testing.expectEqual(@as(u21, 0), chars.codepoints[0]);
        try testing.expectEqual(@as(u21, ' '), chars.codepoints[1]);
        try testing.expectEqual(@as(u21, '\t'), chars.codepoints[2]);
        try testing.expectEqual(@as(u21, ';'), chars.codepoints[3]);
        try testing.expectEqual(@as(u21, ','), chars.codepoints[4]);
    }
    test "parseCLI backslash escape" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var chars: Self = .{};
        try chars.parseCLI(alloc, "\\\\;");
        try testing.expectEqual(@as(usize, 3), chars.codepoints.len);
        try testing.expectEqual(@as(u21, 0), chars.codepoints[0]);
        try testing.expectEqual(@as(u21, '\\'), chars.codepoints[1]);
        try testing.expectEqual(@as(u21, ';'), chars.codepoints[2]);
    }
    test "parseCLI unicode escape" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var chars: Self = .{};
        try chars.parseCLI(alloc, "\\u{2502};");
        try testing.expectEqual(@as(usize, 3), chars.codepoints.len);
        try testing.expectEqual(@as(u21, 0), chars.codepoints[0]);
        try testing.expectEqual(@as(u21, '│'), chars.codepoints[1]);
        try testing.expectEqual(@as(u21, ';'), chars.codepoints[2]);
    }
};
pub const RepeatableFontVariation = struct {
    const Self = @This();
    list: std.ArrayList(fontpkg.face.Variation) = .empty,
    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        const eql_idx = std.mem.indexOf(u8, input, "=") orelse return error.InvalidValue;
        const whitespace = " \t";
        const key = std.mem.trim(u8, input[0..eql_idx], whitespace);
        const value = std.mem.trim(u8, input[eql_idx + 1 ..], whitespace);
        if (key.len != 4) return error.InvalidValue;
        try self.list.append(alloc, .{
            .id = fontpkg.face.Variation.Id.init(@ptrCast(key.ptr)),
            .value = std.fmt.parseFloat(f64, value) catch return error.InvalidValue,
        });
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        return .{
            .list = try self.list.clone(alloc),
        };
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        } else return true;
    }
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.list.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        var buf: [128]u8 = undefined;
        for (self.list.items) |value| {
            const str = std.fmt.bufPrint(&buf, "{s}={d}", .{
                value.id.str(),
                value.value,
            }) catch return error.OutOfMemory;
            try formatter.formatEntry([]const u8, str);
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "wght=200");
        try list.parseCLI(alloc, "slnt=-15");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("wght"),
            .value = 200,
        }, list.list.items[0]);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("slnt"),
            .value = -15,
        }, list.list.items[1]);
    }
    test "parseCLI with whitespace" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "wght =200");
        try list.parseCLI(alloc, "slnt= -15");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("wght"),
            .value = 200,
        }, list.list.items[0]);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("slnt"),
            .value = -15,
        }, list.list.items[1]);
    }
    test "formatConfig single" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "wght = 200");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = wght=200\n", buf.written());
    }
};
pub fn keyEventIsBinding(
    self: *Config,
    event: inputpkg.KeyEvent,
) bool {
    switch (event.action) {
        .release => return false,
        .press, .repeat => {},
    }
    return self.keybind.set.getEvent(event) != null;
}
pub const Keybinds = struct {
    set: inputpkg.Binding.Set = .{},
    tables: std.StringArrayHashMapUnmanaged(inputpkg.Binding.Set) = .empty,
    chain_target: union(enum) {
        root,
        table: []const u8,
    } = .root,
    pub fn init(self: *Keybinds, alloc: Allocator) !void {
        self.set = .{};
        self.tables = .empty;
        self.chain_target = .root;
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = ',' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .{ .reload_config = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = ',' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .open_config = .default },
        );
        {
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .copy } },
                .{ .copy_to_clipboard = .mixed },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .paste } },
                .paste_from_clipboard,
            );
            if (!builtin.target.os.tag.isDarwin()) {
                try self.set.put(
                    alloc,
                    .{ .key = .{ .physical = .insert }, .mods = .{ .ctrl = true } },
                    .{ .copy_to_clipboard = .mixed },
                );
                try self.set.put(
                    alloc,
                    .{ .key = .{ .physical = .insert }, .mods = .{ .shift = true } },
                    .{ .paste_from_clipboard = {} },
                );
            }
            const mods: inputpkg.Mods = if (builtin.target.os.tag.isDarwin())
                .{ .super = true }
            else
                .{ .ctrl = true, .shift = true };
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'c' }, .mods = mods },
                .{ .copy_to_clipboard = .mixed },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'v' }, .mods = mods },
                .paste_from_clipboard,
                .{ .performable = true },
            );
        }
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '=' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .increase_font_size = 1 },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '+' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .increase_font_size = 1 },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '-' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .decrease_font_size = 1 },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '0' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .reset_font_size = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'j' }, .mods = .{ .shift = true, .ctrl = true, .super = true } },
            .{ .write_screen_file = .copy },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'j' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .{ .write_screen_file = .paste },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'j' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true, .alt = true }) },
            .{ .write_screen_file = .open },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_left }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .left },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_right }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .right },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_up }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .up },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_down }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .down },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .page_up },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .page_down }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .page_down },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .home }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .home },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .end }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .end },
            .{ .performable = true },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .tab }, .mods = .{ .ctrl = true, .shift = true } },
            .{ .previous_tab = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .tab }, .mods = .{ .ctrl = true } },
            .{ .next_tab = {} },
        );
        if (comptime !builtin.target.os.tag.isDarwin()) {
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'n' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .close_surface = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'q' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .quit = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .f4 }, .mods = .{ .alt = true } },
                .{ .close_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 't' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .close_tab = .this },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .previous_tab = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .next_tab = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .ctrl = true } },
                .{ .previous_tab = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .ctrl = true } },
                .{ .next_tab = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'o' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_split = .right },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'e' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_split = .down },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = '[' }, .mods = .{ .ctrl = true, .super = true } },
                .{ .goto_split = .previous },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = ']' }, .mods = .{ .ctrl = true, .super = true } },
                .{ .goto_split = .next },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .up },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .down },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .left },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .right },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .up, 10 } },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .down, 10 } },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .left, 10 } },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .right, 10 } },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .home }, .mods = .{ .shift = true } },
                .{ .scroll_to_top = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .end }, .mods = .{ .shift = true } },
                .{ .scroll_to_bottom = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true } },
                .{ .scroll_page_up = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .shift = true } },
                .{ .scroll_page_down = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .jump_to_prompt = -1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .jump_to_prompt = 1 },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .move_tab = -1 },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .move_tab = 1 },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'f' }, .mods = .{ .ctrl = true, .shift = true } },
                .start_search,
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .escape } },
                .end_search,
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'i' }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .inspector = .toggle },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'a' }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .select_all = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .insert }, .mods = .{ .shift = true } },
                .{ .paste_from_selection = {} },
            );
        }
        {
            const mods: inputpkg.Mods = if (builtin.target.os.tag.isDarwin())
                .{ .super = true }
            else
                .{ .alt = true };
            const start: u21 = '1';
            const end: u21 = '8';
            comptime var i: u21 = start;
            inline while (i <= end) : (i += 1) {
                try self.set.putFlags(
                    alloc,
                    .{
                        .key = .{ .physical = @field(
                            inputpkg.Key,
                            std.fmt.comptimePrint("digit_{u}", .{i}),
                        ) },
                        .mods = mods,
                    },
                    .{ .goto_tab = (i - start) + 1 },
                    .{
                        .performable = !builtin.target.os.tag.isDarwin(),
                    },
                );
                try self.set.putFlags(
                    alloc,
                    .{
                        .key = .{ .unicode = i },
                        .mods = mods,
                    },
                    .{ .goto_tab = (i - start) + 1 },
                    .{
                        .performable = !builtin.target.os.tag.isDarwin(),
                    },
                );
            }
            try self.set.putFlags(
                alloc,
                .{
                    .key = .{ .unicode = '9' },
                    .mods = mods,
                },
                .{ .last_tab = {} },
                .{
                    .performable = !builtin.target.os.tag.isDarwin(),
                },
            );
        }
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .enter }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .toggle_fullscreen = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .enter }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .{ .toggle_split_zoom = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'p' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .toggle_command_palette,
        );
        if (comptime builtin.target.os.tag.isDarwin()) {
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'q' }, .mods = .{ .super = true } },
                .{ .quit = {} },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'k' }, .mods = .{ .super = true } },
                .{ .clear_screen = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'a' }, .mods = .{ .super = true } },
                .{ .select_all = {} },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 't' }, .mods = .{ .super = true, .shift = true } },
                .{ .undo = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'z' }, .mods = .{ .super = true } },
                .{ .undo = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'z' }, .mods = .{ .super = true, .shift = true } },
                .{ .redo = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .home }, .mods = .{ .super = true } },
                .{ .scroll_to_top = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .end }, .mods = .{ .super = true } },
                .{ .scroll_to_bottom = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .super = true } },
                .{ .scroll_page_up = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .super = true } },
                .{ .scroll_page_down = {} },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'j' }, .mods = .{ .super = true } },
                .{ .scroll_to_selection = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .shift = true } },
                .{ .jump_to_prompt = -1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .shift = true } },
                .{ .jump_to_prompt = 1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'n' }, .mods = .{ .super = true } },
                .{ .new_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true } },
                .{ .close_surface = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true, .alt = true } },
                .{ .close_tab = .this },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true, .shift = true } },
                .{ .close_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true, .shift = true, .alt = true } },
                .{ .close_all_windows = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 't' }, .mods = .{ .super = true } },
                .{ .new_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = '[' }, .mods = .{ .super = true, .shift = true } },
                .{ .previous_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = ']' }, .mods = .{ .super = true, .shift = true } },
                .{ .next_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'd' }, .mods = .{ .super = true } },
                .{ .new_split = .right },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'd' }, .mods = .{ .super = true, .shift = true } },
                .{ .new_split = .down },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = '[' }, .mods = .{ .super = true } },
                .{ .goto_split = .previous },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = ']' }, .mods = .{ .super = true } },
                .{ .goto_split = .next },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .up },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .down },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .left },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .right },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .up, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .down, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .left, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .right, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = '=' }, .mods = .{ .super = true, .ctrl = true } },
                .{ .equalize_splits = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true } },
                .{ .jump_to_prompt = -1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true } },
                .{ .jump_to_prompt = 1 },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'f' }, .mods = .{ .super = true } },
                .start_search,
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'e' }, .mods = .{ .super = true } },
                .search_selection,
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'f' }, .mods = .{ .super = true, .shift = true } },
                .end_search,
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .escape } },
                .end_search,
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'g' }, .mods = .{ .super = true } },
                .{ .navigate_search = .next },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'g' }, .mods = .{ .super = true, .shift = true } },
                .{ .navigate_search = .previous },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'i' }, .mods = .{ .alt = true, .super = true } },
                .{ .inspector = .toggle },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'f' }, .mods = .{ .super = true, .ctrl = true } },
                .{ .toggle_fullscreen = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'v' }, .mods = .{ .super = true, .shift = true } },
                .{ .paste_from_selection = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true } },
                .{ .text = "\\x05" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true } },
                .{ .text = "\\x01" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .backspace }, .mods = .{ .super = true } },
                .{ .text = "\\x15" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .alt = true } },
                .{ .esc = "b" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .alt = true } },
                .{ .esc = "f" },
            );
        }
    }
    pub fn parseCLI(self: *Keybinds, alloc: Allocator, input: ?[]const u8) !void {
        var copy: ?[]u8 = null;
        const value = value: {
            const value = input orelse return error.ValueRequired;
            if (std.mem.indexOf(u8, value, ":") == null)
                break :value value;
            const buf = try alloc.alloc(u8, value.len);
            copy = buf;
            @memcpy(buf, value);
            break :value buf;
        };
        errdefer if (copy) |v| alloc.free(v);
        if (value.len == 0) {
            log.info("config has 'keybind =', using default keybinds", .{});
            try self.init(alloc);
            return;
        }
        if (std.mem.eql(u8, value, "clear")) {
            log.info("config has 'keybind = clear', all keybinds cleared", .{});
            self.set = .{};
            self.tables = .empty;
            self.chain_target = .root;
            return;
        }
        const eq_idx = std.mem.indexOfScalar(u8, value, '=') orelse value.len;
        if (std.mem.indexOfScalar(u8, value[0..eq_idx], '/')) |slash_idx| table: {
            const table_name = value[0..slash_idx];
            if (table_name.len == 0) break :table;
            if (std.mem.indexOfAny(
                u8,
                table_name,
                "+>",
            ) != null) break :table;
            const binding = value[slash_idx + 1 ..];
            const gop = try self.tables.getOrPut(alloc, table_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try alloc.dupe(u8, table_name);
                gop.value_ptr.* = .{};
            }
            if (binding.len == 0) {
                log.debug("config has 'keybind = {s}/', table cleared", .{table_name});
                gop.value_ptr.* = .{};
                self.chain_target = .root;
                return;
            }
            if (std.mem.startsWith(u8, binding, "chain=")) {
                return error.InvalidFormat;
            }
            try gop.value_ptr.parseAndPut(alloc, binding);
            self.chain_target = .{ .table = gop.key_ptr.* };
            return;
        }
        if (std.mem.startsWith(u8, value, "chain=")) {
            switch (self.chain_target) {
                .root => try self.set.parseAndPut(alloc, value),
                .table => |table_name| {
                    const table = self.tables.getPtr(table_name) orelse {
                        self.chain_target = .root;
                        return error.InvalidFormat;
                    };
                    try table.parseAndPut(alloc, value);
                },
            }
            return;
        }
        try self.set.parseAndPut(alloc, value);
        self.chain_target = .root;
    }
    pub fn clone(self: *const Keybinds, alloc: Allocator) Allocator.Error!Keybinds {
        var tables: std.StringArrayHashMapUnmanaged(inputpkg.Binding.Set) = .empty;
        try tables.ensureTotalCapacity(alloc, @intCast(self.tables.count()));
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            const key = try alloc.dupe(u8, entry.key_ptr.*);
            tables.putAssumeCapacity(key, try entry.value_ptr.clone(alloc));
        }
        return .{
            .set = try self.set.clone(alloc),
            .tables = tables,
        };
    }
    pub fn equal(self: Keybinds, other: Keybinds) bool {
        if (!equalSet(&self.set, &other.set)) return false;
        if (self.tables.count() != other.tables.count()) return false;
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            const other_set = other.tables.get(entry.key_ptr.*) orelse return false;
            if (!equalSet(entry.value_ptr, &other_set)) return false;
        }
        return true;
    }
    fn equalSet(
        self: *const inputpkg.Binding.Set,
        other: *const inputpkg.Binding.Set,
    ) bool {
        const self_map = &self.bindings;
        const other_map = &other.bindings;
        if (self_map.count() != other_map.count()) return false;
        var it = self_map.iterator();
        while (it.next()) |self_entry| {
            const other_entry = other_map.getEntry(self_entry.key_ptr.*) orelse
                return false;
            if (std.meta.activeTag(self_entry.value_ptr.*) !=
                std.meta.activeTag(other_entry.value_ptr.*)) return false;
            switch (self_entry.value_ptr.*) {
                .leader => if (!equalSet(
                    self_entry.value_ptr.*.leader,
                    other_entry.value_ptr.*.leader,
                )) return false,
                .leaf => {
                    const self_leaf = self_entry.value_ptr.*.leaf;
                    const other_leaf = other_entry.value_ptr.*.leaf;
                    if (!deepEqual(
                        inputpkg.Binding.Set.Leaf,
                        self_leaf,
                        other_leaf,
                    )) return false;
                },
                .leaf_chained => {
                    const self_chain = self_entry.value_ptr.*.leaf_chained;
                    const other_chain = other_entry.value_ptr.*.leaf_chained;
                    if (self_chain.flags != other_chain.flags) return false;
                    if (self_chain.actions.items.len != other_chain.actions.items.len) return false;
                    for (self_chain.actions.items, other_chain.actions.items) |a1, a2| {
                        if (!deepEqual(
                            inputpkg.Binding.Action,
                            a1,
                            a2,
                        )) return false;
                    }
                },
            }
        }
        return true;
    }
    pub fn formatEntryDocs(self: Keybinds, formatter: formatterpkg.EntryFormatter, docs: bool) !void {
        if (self.set.bindings.count() == 0 and self.tables.count() == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        var buf: [1024]u8 = undefined;
        var iter = self.set.bindings.iterator();
        while (iter.next()) |next| {
            const k = next.key_ptr.*;
            const v = next.value_ptr.*;
            if (docs) {
                try formatter.writer.writeAll("\n");
                const name = @tagName(v);
                inline for (@typeInfo(help_strings.KeybindAction).@"struct".decls) |decl| {
                    if (std.mem.eql(u8, decl.name, name)) {
                        const help = @field(help_strings.KeybindAction, decl.name);
                        try formatter.writer.writeAll("# " ++ decl.name ++ "\n");
                        var lines = std.mem.splitScalar(u8, help, '\n');
                        while (lines.next()) |line| {
                            try formatter.writer.writeAll("#   ");
                            try formatter.writer.writeAll(line);
                            try formatter.writer.writeAll("\n");
                        }
                        break;
                    }
                }
            }
            var writer: std.Io.Writer = .fixed(&buf);
            writer.print("{f}", .{k}) catch return error.OutOfMemory;
            try v.formatEntries(&writer, formatter);
        }
        var table_iter = self.tables.iterator();
        while (table_iter.next()) |table_entry| {
            const table_name = table_entry.key_ptr.*;
            const table_set = table_entry.value_ptr.*;
            var binding_iter = table_set.bindings.iterator();
            while (binding_iter.next()) |next| {
                const k = next.key_ptr.*;
                const v = next.value_ptr.*;
                var writer: std.Io.Writer = .fixed(&buf);
                writer.print("{s}/{f}", .{ table_name, k }) catch return error.OutOfMemory;
                try v.formatEntries(&writer, formatter);
            }
        }
    }
    pub fn formatEntry(self: Keybinds, formatter: formatterpkg.EntryFormatter) !void {
        try self.formatEntryDocs(formatter, false);
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var set: Keybinds = .{};
        try set.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try set.parseCLI(alloc, "shift+a=csi:hello");
    }
    test "formatConfig single" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Keybinds = .{};
        try list.parseCLI(alloc, "shift+a=csi:hello");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = shift+a=csi:hello\n", buf.written());
    }
    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Keybinds = .{};
        try list.parseCLI(alloc, "ctrl+z>1=goto_tab:1");
        try list.parseCLI(alloc, "ctrl+z>2=goto_tab:2");
        try list.formatEntry(formatterpkg.entryFormatter("keybind", &buf.writer));
        const want =
            \\keybind = ctrl+z>1=goto_tab:1
            \\keybind = ctrl+z>2=goto_tab:2
            \\
        ;
        try std.testing.expectEqualStrings(want, buf.written());
    }
    test "formatConfig multiple items nested" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Keybinds = .{};
        try list.parseCLI(alloc, "ctrl+a>ctrl+b>n=new_window");
        try list.parseCLI(alloc, "ctrl+a>ctrl+b>w=close_window");
        try list.parseCLI(alloc, "ctrl+a>ctrl+c>t=new_tab");
        try list.parseCLI(alloc, "ctrl+b>ctrl+d>a=previous_tab");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        const want =
            \\a = ctrl+a>ctrl+b>n=new_window
            \\a = ctrl+a>ctrl+b>w=close_window
            \\a = ctrl+a>ctrl+c>t=new_tab
            \\a = ctrl+b>ctrl+d>a=previous_tab
            \\
        ;
        try std.testing.expectEqualStrings(want, buf.written());
    }
    test "parseCLI table definition" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        try testing.expectEqual(1, keybinds.tables.count());
        try testing.expect(keybinds.tables.contains("foo"));
        const table = keybinds.tables.get("foo").?;
        try testing.expectEqual(1, table.bindings.count());
    }
    test "parseCLI table clear" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        try testing.expectEqual(1, keybinds.tables.get("foo").?.bindings.count());
        try keybinds.parseCLI(alloc, "foo/");
        try testing.expectEqual(0, keybinds.tables.get("foo").?.bindings.count());
    }
    test "parseCLI table multiple bindings" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        try keybinds.parseCLI(alloc, "foo/shift+b=paste_from_clipboard");
        try keybinds.parseCLI(alloc, "bar/ctrl+c=close_window");
        try testing.expectEqual(2, keybinds.tables.count());
        try testing.expectEqual(2, keybinds.tables.get("foo").?.bindings.count());
        try testing.expectEqual(1, keybinds.tables.get("bar").?.bindings.count());
    }
    test "parseCLI table does not affect root set" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try keybinds.parseCLI(alloc, "foo/shift+b=paste_from_clipboard");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(1, keybinds.tables.get("foo").?.bindings.count());
    }
    test "parseCLI table empty name is invalid" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try testing.expectError(error.InvalidFormat, keybinds.parseCLI(alloc, "/shift+a=copy_to_clipboard"));
    }
    test "parseCLI table with key sequence" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/ctrl+a>ctrl+b=new_window");
        const table = keybinds.tables.get("foo").?;
        try testing.expectEqual(1, table.bindings.count());
    }
    test "parseCLI slash in action argument is not a table" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "ctrl+a=text:/hello");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(0, keybinds.tables.count());
    }
    test "parseCLI slash as key with modifier is not a table" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "ctrl+/=text:foo");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(0, keybinds.tables.count());
    }
    test "parseCLI shift+slash as key is not a table" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "shift+/=ignore");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(0, keybinds.tables.count());
    }
    test "parseCLI bare slash as key is not a table" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "/=text:foo");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(0, keybinds.tables.count());
    }
    test "parseCLI slash in key sequence is not a table" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "ctrl+a>ctrl+/=new_window");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(0, keybinds.tables.count());
    }
    test "parseCLI table with slash in binding" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "mytable//=text:foo");
        try testing.expectEqual(0, keybinds.set.bindings.count());
        try testing.expectEqual(1, keybinds.tables.count());
        try testing.expect(keybinds.tables.contains("mytable"));
        try testing.expectEqual(1, keybinds.tables.get("mytable").?.bindings.count());
    }
    test "parseCLI table with sequence containing slash" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "mytable/a>/=new_window");
        try testing.expectEqual(0, keybinds.set.bindings.count());
        try testing.expectEqual(1, keybinds.tables.count());
        try testing.expect(keybinds.tables.contains("mytable"));
    }
    test "parseCLI chain without prior parsed binding is invalid" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try testing.expectError(
            error.InvalidFormat,
            keybinds.parseCLI(alloc, "chain=new_tab"),
        );
    }
    test "parseCLI table chain syntax is invalid" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/a=text:hello");
        try testing.expectError(
            error.InvalidFormat,
            keybinds.parseCLI(alloc, "foo/chain=deactivate_key_table"),
        );
    }
    test "parseCLI chain applies to most recent table binding" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "ctrl+n=activate_key_table:foo");
        try keybinds.parseCLI(alloc, "foo/a=text:hello");
        try keybinds.parseCLI(alloc, "chain=deactivate_key_table");
        const root_entry = keybinds.set.get(.{
            .mods = .{ .ctrl = true },
            .key = .{ .unicode = 'n' },
        }).?.value_ptr.*;
        try testing.expect(root_entry == .leaf);
        try testing.expect(root_entry.leaf.action == .activate_key_table);
        const foo_entry = keybinds.tables.get("foo").?.get(.{
            .key = .{ .unicode = 'a' },
        }).?.value_ptr.*;
        try testing.expect(foo_entry == .leaf_chained);
        try testing.expectEqual(@as(usize, 2), foo_entry.leaf_chained.actions.items.len);
        try testing.expect(foo_entry.leaf_chained.actions.items[0] == .text);
        try testing.expect(foo_entry.leaf_chained.actions.items[1] == .deactivate_key_table);
    }
    test "clone with tables" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try keybinds.parseCLI(alloc, "foo/shift+b=paste_from_clipboard");
        try keybinds.parseCLI(alloc, "bar/ctrl+c=close_window");
        const cloned = try keybinds.clone(alloc);
        try testing.expectEqual(keybinds.set.bindings.count(), cloned.set.bindings.count());
        try testing.expectEqual(keybinds.tables.count(), cloned.tables.count());
        try testing.expectEqual(
            keybinds.tables.get("foo").?.bindings.count(),
            cloned.tables.get("foo").?.bindings.count(),
        );
        try testing.expectEqual(
            keybinds.tables.get("bar").?.bindings.count(),
            cloned.tables.get("bar").?.bindings.count(),
        );
    }
    test "equal with tables" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds1: Keybinds = .{};
        try keybinds1.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        var keybinds2: Keybinds = .{};
        try keybinds2.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        try testing.expect(keybinds1.equal(keybinds2));
    }
    test "equal with tables different table count" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds1: Keybinds = .{};
        try keybinds1.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        var keybinds2: Keybinds = .{};
        try keybinds2.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        try keybinds2.parseCLI(alloc, "bar/shift+b=paste_from_clipboard");
        try testing.expect(!keybinds1.equal(keybinds2));
    }
    test "equal with tables different table names" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds1: Keybinds = .{};
        try keybinds1.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        var keybinds2: Keybinds = .{};
        try keybinds2.parseCLI(alloc, "bar/shift+a=copy_to_clipboard");
        try testing.expect(!keybinds1.equal(keybinds2));
    }
    test "equal with tables different bindings" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds1: Keybinds = .{};
        try keybinds1.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        var keybinds2: Keybinds = .{};
        try keybinds2.parseCLI(alloc, "foo/shift+b=paste_from_clipboard");
        try testing.expect(!keybinds1.equal(keybinds2));
    }
    test "formatEntry with tables" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/shift+a=csi:hello");
        try keybinds.formatEntry(formatterpkg.entryFormatter("keybind", &buf.writer));
        try testing.expectEqualStrings("keybind = foo/shift+a=csi:hello\n", buf.written());
    }
    test "formatEntry with tables and root set" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "shift+b=csi:world");
        try keybinds.parseCLI(alloc, "foo/shift+a=csi:hello");
        try keybinds.formatEntry(formatterpkg.entryFormatter("keybind", &buf.writer));
        const output = buf.written();
        try testing.expect(std.mem.indexOf(u8, output, "keybind = shift+b=csi:world\n") != null);
        try testing.expect(std.mem.indexOf(u8, output, "keybind = foo/shift+a=csi:hello\n") != null);
    }
    test "parseCLI clear clears tables" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try keybinds.parseCLI(alloc, "foo/shift+b=paste_from_clipboard");
        try keybinds.parseCLI(alloc, "bar/ctrl+c=close_window");
        try testing.expectEqual(1, keybinds.set.bindings.count());
        try testing.expectEqual(2, keybinds.tables.count());
        try keybinds.parseCLI(alloc, "clear");
        try testing.expectEqual(0, keybinds.set.bindings.count());
        try testing.expectEqual(0, keybinds.tables.count());
    }
    test "parseCLI reset clears tables" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "foo/shift+a=copy_to_clipboard");
        try keybinds.parseCLI(alloc, "bar/shift+b=paste_from_clipboard");
        try testing.expectEqual(2, keybinds.tables.count());
        try keybinds.parseCLI(alloc, "");
        try testing.expectEqual(0, keybinds.tables.count());
        try testing.expect(keybinds.set.bindings.count() > 0);
    }
};
pub const RepeatableCodepointMap = struct {
    const Self = @This();
    map: fontpkg.CodepointMap = .{},
    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        const eql_idx = std.mem.indexOf(u8, input, "=") orelse return error.InvalidValue;
        const whitespace = " \t";
        const key = std.mem.trim(u8, input[0..eql_idx], whitespace);
        const value = std.mem.trim(u8, input[eql_idx + 1 ..], whitespace);
        const valueZ = try alloc.dupeZ(u8, value);
        var p: UnicodeRangeParser = .{ .input = key };
        while (try p.next()) |range| {
            try self.map.add(alloc, .{
                .range = range,
                .descriptor = .{
                    .family = valueZ,
                    .monospace = false,
                },
            });
        }
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        return .{ .map = try self.map.clone(alloc) };
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.map.list.slice();
        const itemsB = other.map.list.slice();
        if (itemsA.len != itemsB.len) return false;
        for (0..itemsA.len) |i| {
            const a = itemsA.get(i);
            const b = itemsB.get(i);
            if (!std.meta.eql(a, b)) return false;
        } else return true;
    }
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.map.list.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        var buf: [1024]u8 = undefined;
        const ranges = self.map.list.items(.range);
        const descriptors = self.map.list.items(.descriptor);
        for (ranges, descriptors) |range, descriptor| {
            if (range[0] == range[1]) {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "U+{X:0>4}={s}",
                        .{
                            range[0],
                            descriptor.family orelse "",
                        },
                    ) catch return error.OutOfMemory,
                );
            } else {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "U+{X:0>4}-U+{X:0>4}={s}",
                        .{
                            range[0],
                            range[1],
                            descriptor.family orelse "",
                        },
                    ) catch return error.OutOfMemory,
                );
            }
        }
    }
    const UnicodeRangeParser = struct {
        input: []const u8,
        i: usize = 0,
        pub fn next(self: *UnicodeRangeParser) !?[2]u21 {
            if (self.eof()) return null;
            const start = try self.parseCodepoint();
            if (self.eof()) return .{ start, start };
            self.consumeWhitespace();
            switch (self.input[self.i]) {
                ',' => {
                    self.advance();
                    self.consumeWhitespace();
                    if (self.eof()) return error.InvalidValue;
                    return .{ start, start };
                },
                '-' => {
                    self.advance();
                    self.consumeWhitespace();
                    if (self.eof()) return error.InvalidValue;
                    const end = try self.parseCodepoint();
                    self.consumeWhitespace();
                    if (!self.eof() and self.input[self.i] != ',') return error.InvalidValue;
                    self.advance();
                    self.consumeWhitespace();
                    if (start > end) return error.InvalidValue;
                    return .{ start, end };
                },
                else => return error.InvalidValue,
            }
        }
        fn consumeWhitespace(self: *UnicodeRangeParser) void {
            while (!self.eof()) {
                switch (self.input[self.i]) {
                    ' ', '\t' => self.advance(),
                    else => return,
                }
            }
        }
        fn parseCodepoint(self: *UnicodeRangeParser) !u21 {
            if (self.input[self.i] != 'U') return error.InvalidValue;
            self.advance();
            if (self.eof()) return error.InvalidValue;
            if (self.input[self.i] != '+') return error.InvalidValue;
            self.advance();
            if (self.eof()) return error.InvalidValue;
            const start_i = self.i;
            while (true) {
                const current = self.input[self.i];
                const is_hex = (current >= '0' and current <= '9') or
                    (current >= 'A' and current <= 'F') or
                    (current >= 'a' and current <= 'f');
                if (!is_hex) break;
                self.advance();
                if (self.eof()) break;
            }
            if (start_i == self.i) return error.InvalidValue;
            return std.fmt.parseInt(u21, self.input[start_i..self.i], 16) catch
                return error.InvalidValue;
        }
        fn advance(self: *UnicodeRangeParser) void {
            self.i += 1;
        }
        fn eof(self: *const UnicodeRangeParser) bool {
            return self.i >= self.input.len;
        }
    };
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+ABCD=Comic Sans");
        try list.parseCLI(alloc, "U+0001 - U+0005=Verdana");
        try list.parseCLI(alloc, "U+0006-U+0009, U+ABCD=Courier");
        try testing.expectEqual(@as(usize, 4), list.map.list.len);
        {
            const entry = list.map.list.get(0);
            try testing.expectEqual([2]u21{ 0xABCD, 0xABCD }, entry.range);
            try testing.expectEqualStrings("Comic Sans", entry.descriptor.family.?);
        }
        {
            const entry = list.map.list.get(1);
            try testing.expectEqual([2]u21{ 1, 5 }, entry.range);
            try testing.expectEqualStrings("Verdana", entry.descriptor.family.?);
        }
        {
            const entry = list.map.list.get(2);
            try testing.expectEqual([2]u21{ 6, 9 }, entry.range);
            try testing.expectEqualStrings("Courier", entry.descriptor.family.?);
        }
        {
            const entry = list.map.list.get(3);
            try testing.expectEqual([2]u21{ 0xABCD, 0xABCD }, entry.range);
            try testing.expectEqualStrings("Courier", entry.descriptor.family.?);
        }
    }
    test "formatConfig single" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+ABCD=Comic Sans");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = U+ABCD=Comic Sans\n", buf.written());
    }
    test "formatConfig range" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+0001 - U+0005=Verdana");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = U+0001-U+0005=Verdana\n", buf.written());
    }
    test "formatConfig multiple" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+0006-U+0009, U+ABCD=Courier");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8,
            \\a = U+0006-U+0009=Courier
            \\a = U+ABCD=Courier
            \\
        , buf.written());
    }
};
pub const RepeatableClipboardCodepointMap = struct {
    const Self = @This();
    map: ClipboardCodepointMap = .{},
    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        const eql_idx = std.mem.indexOf(u8, input, "=") orelse return error.InvalidValue;
        const whitespace = " \t";
        const key = std.mem.trim(u8, input[0..eql_idx], whitespace);
        const value = std.mem.trim(u8, input[eql_idx + 1 ..], whitespace);
        const replacement: ClipboardCodepointMap.Replacement = if (std.mem.startsWith(u8, value, "U+")) blk: {
            const cp_str = value[2..];
            const cp = std.fmt.parseInt(u21, cp_str, 16) catch return error.InvalidValue;
            break :blk .{ .codepoint = cp };
        } else blk: {
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
            const value_copy = try alloc.dupe(u8, value);
            break :blk .{ .string = value_copy };
        };
        var p: UnicodeRangeParser = .{ .input = key };
        while (try p.next()) |range| {
            try self.map.add(alloc, .{
                .range = range,
                .replacement = replacement,
            });
        }
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        return .{ .map = try self.map.clone(alloc) };
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.map.list.slice();
        const itemsB = other.map.list.slice();
        if (itemsA.len != itemsB.len) return false;
        for (0..itemsA.len) |i| {
            const a = itemsA.get(i);
            const b = itemsB.get(i);
            if (!std.meta.eql(a.range, b.range)) return false;
            switch (a.replacement) {
                .codepoint => |cp_a| switch (b.replacement) {
                    .codepoint => |cp_b| if (cp_a != cp_b) return false,
                    .string => return false,
                },
                .string => |str_a| switch (b.replacement) {
                    .string => |str_b| if (!std.mem.eql(u8, str_a, str_b)) return false,
                    .codepoint => return false,
                },
            }
        }
        return true;
    }
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.map.list.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        var buf: [1024]u8 = undefined;
        var value_buf: [32]u8 = undefined;
        const ranges = self.map.list.items(.range);
        const replacements = self.map.list.items(.replacement);
        for (ranges, replacements) |range, replacement| {
            const value_str = switch (replacement) {
                .codepoint => |cp| try std.fmt.bufPrint(&value_buf, "U+{X:0>4}", .{cp}),
                .string => |s| s,
            };
            if (range[0] == range[1]) {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "U+{X:0>4}={s}",
                        .{ range[0], value_str },
                    ) catch return error.OutOfMemory,
                );
            } else {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "U+{X:0>4}-U+{X:0>4}={s}",
                        .{ range[0], range[1], value_str },
                    ) catch return error.OutOfMemory,
                );
            }
        }
    }
    const UnicodeRangeParser = RepeatableCodepointMap.UnicodeRangeParser;
    test "parseCLI codepoint replacement" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+2500=U+002D");
        try testing.expectEqual(@as(usize, 1), list.map.list.len);
        const entry = list.map.list.get(0);
        try testing.expectEqual([2]u21{ 0x2500, 0x2500 }, entry.range);
        try testing.expect(entry.replacement == .codepoint);
        try testing.expectEqual(@as(u21, 0x002D), entry.replacement.codepoint);
    }
    test "parseCLI string replacement" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+03A3=SUM");
        try testing.expectEqual(@as(usize, 1), list.map.list.len);
        const entry = list.map.list.get(0);
        try testing.expectEqual([2]u21{ 0x03A3, 0x03A3 }, entry.range);
        try testing.expect(entry.replacement == .string);
        try testing.expectEqualStrings("SUM", entry.replacement.string);
    }
    test "parseCLI range replacement" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+2500-U+2503=|");
        try testing.expectEqual(@as(usize, 1), list.map.list.len);
        const entry = list.map.list.get(0);
        try testing.expectEqual([2]u21{ 0x2500, 0x2503 }, entry.range);
        try testing.expect(entry.replacement == .string);
        try testing.expectEqualStrings("|", entry.replacement.string);
    }
    test "formatConfig codepoint" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+2500=U+002D");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = U+2500=U+002D\n", buf.written());
    }
    test "formatConfig string" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "U+03A3=SUM");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = U+03A3=SUM\n", buf.written());
    }
};
pub const FontStyle = union(enum) {
    const Self = @This();
    default: void,
    false: void,
    name: [:0]const u8,
    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;
        if (std.mem.eql(u8, value, "default")) {
            self.* = .{ .default = {} };
            return;
        }
        if (std.mem.eql(u8, value, "false")) {
            self.* = .{ .false = {} };
            return;
        }
        const nameZ = try alloc.dupeZ(u8, value);
        self.* = .{ .name = nameZ };
    }
    pub fn nameValue(self: Self) ?[:0]const u8 {
        return switch (self) {
            .default, .false => null,
            .name => self.name,
        };
    }
    pub fn clone(self: Self, alloc: Allocator) Allocator.Error!Self {
        return switch (self) {
            .default, .false => self,
            .name => |v| .{ .name = try alloc.dupeZ(u8, v) },
        };
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        switch (self) {
            .default, .false => try formatter.formatEntry(
                []const u8,
                @tagName(self),
            ),
            .name => |name| {
                try formatter.formatEntry([:0]const u8, name);
            },
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "default");
        try testing.expectEqual(Self{ .default = {} }, p);
        try p.parseCLI(alloc, "false");
        try testing.expectEqual(Self{ .false = {} }, p);
        try p.parseCLI(alloc, "bold");
        try testing.expectEqualStrings("bold", p.name);
    }
    test "formatConfig default" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "default");
        try p.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = default\n", buf.written());
    }
    test "formatConfig false" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "false");
        try p.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = false\n", buf.written());
    }
    test "formatConfig named" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "bold");
        try p.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = bold\n", buf.written());
    }
};
pub const FontSyntheticStyle = packed struct {
    bold: bool = true,
    italic: bool = true,
    @"bold-italic": bool = true,
};
pub const FontShapingBreak = packed struct {
    cursor: bool = true,
};
pub const RepeatableLink = struct {
    const Self = @This();
    links: std.ArrayList(inputpkg.Link) = .empty,
    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        _ = self;
        _ = alloc;
        _ = input_;
        return error.NotImplemented;
    }
    pub fn clone(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        var list = try std.ArrayListUnmanaged(inputpkg.Link).initCapacity(
            alloc,
            self.links.items.len,
        );
        for (self.links.items) |item| {
            const copy = try item.clone(alloc);
            list.appendAssumeCapacity(copy);
        }
        return .{ .links = list };
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.links.items;
        const itemsB = other.links.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |*a, *b| {
            if (!a.equal(b)) return false;
        } else return true;
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        _ = self;
        _ = formatter;
    }
};
pub const CopyOnSelect = enum {
    none,
    primary,
    clipboard,
    both,
};
pub const RightClickAction = enum {
    ignore,
    paste,
    copy,
    @"copy-or-paste",
    @"context-menu",
};
pub const MiddleClickAction = enum {
    @"primary-paste",
    @"clipboard-paste",
    ignore,
};
pub const ShellIntegration = enum {
    none,
    detect,
    bash,
    elvish,
    fish,
    nushell,
    zsh,
};
pub const ShellIntegrationFeatures = packed struct {
    cursor: bool = true,
    sudo: bool = false,
    title: bool = true,
    @"ssh-env": bool = false,
    @"ssh-terminfo": bool = false,
    path: bool = true,
};
pub const XtChecksumExtension = packed struct {
    negate: bool = true,
    attributes: bool = true,
    trim: bool = true,
    undrawn: bool = false,
    full: bool = false,
};
pub const SplitPreserveZoom = packed struct {
    navigation: bool = false,
};
pub const RepeatableCommand = struct {
    const Self = @This();
    value: std.ArrayListUnmanaged(inputpkg.Command) = .empty,
    value_c: std.ArrayListUnmanaged(inputpkg.Command.C) = .empty,
    pub const C = extern struct {
        commands: [*]inputpkg.Command.C,
        len: usize,
    };
    pub fn cval(self: *const Self) C {
        return .{
            .commands = self.value_c.items.ptr,
            .len = self.value_c.items.len,
        };
    }
    pub fn init(self: *Self, alloc: Allocator) !void {
        self.value = .empty;
        self.value_c = .empty;
        errdefer {
            self.value.deinit(alloc);
            self.value_c.deinit(alloc);
        }
        try self.value.ensureUnusedCapacity(alloc, inputpkg.command.defaults.len);
        try self.value_c.ensureUnusedCapacity(alloc, inputpkg.command.defaults.len);
        for (inputpkg.command.defaults) |cmd| {
            const localized = if (comptime build_config.app_runtime == .gtk)
                cmd.translated()
            else
                cmd;
            self.value.appendAssumeCapacity(localized);
            self.value_c.appendAssumeCapacity(try localized.cval(alloc));
        }
    }
    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        const input = input_ orelse "";
        if (input.len == 0) {
            log.info("config has 'command-palette-entry =', using default entries", .{});
            try self.init(alloc);
            return;
        }
        if (std.mem.eql(u8, input, "clear")) {
            log.info("config has 'command-palette-entry = clear', all command entries cleared", .{});
            self.value.clearRetainingCapacity();
            self.value_c.clearRetainingCapacity();
            return;
        }
        try self.value.ensureUnusedCapacity(alloc, 1);
        try self.value_c.ensureUnusedCapacity(alloc, 1);
        const cmd = try cli.args.parseAutoStruct(
            inputpkg.Command,
            alloc,
            input,
            null,
        );
        const cmd_c = try cmd.cval(alloc);
        self.value.appendAssumeCapacity(cmd);
        self.value_c.appendAssumeCapacity(cmd_c);
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        const value = try self.value.clone(alloc);
        for (value.items) |*item| {
            item.* = try item.clone(alloc);
        }
        var value_c: std.ArrayListUnmanaged(inputpkg.Command.C) = .empty;
        try value_c.ensureTotalCapacityPrecise(alloc, value.items.len);
        for (value.items) |item| {
            value_c.appendAssumeCapacity(try item.cval(alloc));
        }
        return .{
            .value = value,
            .value_c = value_c,
        };
    }
    pub fn equal(self: RepeatableCommand, other: RepeatableCommand) bool {
        if (self.value.items.len != other.value.items.len) return false;
        for (self.value.items, other.value.items) |a, b| {
            if (!a.equal(b)) return false;
        }
        return true;
    }
    pub fn formatEntry(
        self: RepeatableCommand,
        formatter: formatterpkg.EntryFormatter,
    ) !void {
        if (self.value.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        for (self.value.items) |item| {
            var buf: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            writer.print(
                "title:\"{f}\"",
                .{std.zig.fmtString(item.title)},
            ) catch return error.OutOfMemory;
            if (item.description.len > 0) {
                writer.print(
                    ",description:\"{f}\"",
                    .{std.zig.fmtString(item.description)},
                ) catch return error.OutOfMemory;
            }
            writer.print(",action:\"{f}\"", .{item.action}) catch return error.OutOfMemory;
            try formatter.formatEntry([]const u8, writer.buffered());
        }
    }
    test "RepeatableCommand parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Foo,action:ignore");
        try list.parseCLI(alloc, "title:Bar,description:bobr,action:text:ale bydle");
        try list.parseCLI(alloc, "title:Quux,description:boo,action:increase_font_size:2.5");
        try list.parseCLI(alloc, "title:Baz,description:Raspberry Pie,action:set_font_size:3.14");
        try testing.expectEqual(@as(usize, 4), list.value.items.len);
        try testing.expectEqual(inputpkg.Binding.Action.ignore, list.value.items[0].action);
        try testing.expectEqualStrings("Foo", list.value.items[0].title);
        try testing.expect(list.value.items[1].action == .text);
        try testing.expectEqualStrings("ale bydle", list.value.items[1].action.text);
        try testing.expectEqualStrings("Bar", list.value.items[1].title);
        try testing.expectEqualStrings("bobr", list.value.items[1].description);
        try testing.expectEqual(
            inputpkg.Binding.Action{ .increase_font_size = 2.5 },
            list.value.items[2].action,
        );
        try testing.expectEqualStrings("Quux", list.value.items[2].title);
        try testing.expectEqualStrings("boo", list.value.items[2].description);
        try testing.expectEqual(
            inputpkg.Binding.Action{ .set_font_size = 3.14 },
            list.value.items[3].action,
        );
        try testing.expectEqualStrings("Baz", list.value.items[3].title);
        try testing.expectEqualStrings("Raspberry Pie", list.value.items[3].description);
        try list.parseCLI(alloc, "clear");
        try testing.expectEqual(@as(usize, 0), list.value.items.len);
        try list.parseCLI(alloc, "");
        try testing.expectEqual(inputpkg.command.defaults.len, list.value.items.len);
    }
    test "RepeatableCommand clone rebuilds the C mirror" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Foo,description:bar,action:new_tab");
        const copy = try list.clone(alloc);
        try testing.expectEqual(list.value_c.items.len, copy.value_c.items.len);
        try testing.expect(list.value_c.items[0].title != copy.value_c.items[0].title);
        try testing.expectEqualStrings(
            std.mem.span(list.value_c.items[0].title),
            std.mem.span(copy.value_c.items[0].title),
        );
    }
    test "RepeatableCommand formatConfig empty" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var list: RepeatableCommand = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = \n", buf.written());
    }
    test "RepeatableCommand formatConfig single item" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Bobr, action:text:Bober");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = title:\"Bobr\",action:\"text:Bober\"\n", buf.written());
    }
    test "RepeatableCommand formatConfig multiple items" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Bobr, action:text:kurwa");
        try list.parseCLI(alloc, "title:Ja,   description: pierdole,  action:text:jakie bydle");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = title:\"Bobr\",action:\"text:kurwa\"\na = title:\"Ja\",description:\"pierdole\",action:\"text:jakie bydle\"\n", buf.written());
    }
    test "RepeatableCommand parseCLI commas" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            var list: RepeatableCommand = .{};
            try list.parseCLI(alloc, "title:\"Bo,br\",action:\"text:kur,wa\"");
            try testing.expectEqual(@as(usize, 1), list.value.items.len);
            const item = list.value.items[0];
            try testing.expectEqualStrings("Bo,br", item.title);
            try testing.expectEqualStrings("", item.description);
            try testing.expect(item.action == .text);
            try testing.expectEqualStrings("kur,wa", item.action.text);
        }
        {
            var list: RepeatableCommand = .{};
            try list.parseCLI(alloc, "title:\"Bo,br\",description:\"abc,def\",action:text:kurwa");
            try testing.expectEqual(@as(usize, 1), list.value.items.len);
            const item = list.value.items[0];
            try testing.expectEqualStrings("Bo,br", item.title);
            try testing.expectEqualStrings("abc,def", item.description);
            try testing.expect(item.action == .text);
            try testing.expectEqualStrings("kurwa", item.action.text);
        }
    }
    test "RepeatableCommand cval" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Foo,action:ignore");
        try list.parseCLI(alloc, "title:Bar,description:bobr,action:text:ale bydle");
        try testing.expectEqual(@as(usize, 2), list.value.items.len);
        try testing.expectEqual(@as(usize, 2), list.value_c.items.len);
        const cv = list.cval();
        try testing.expectEqual(@as(usize, 2), cv.len);
        try testing.expectEqualStrings("Foo", std.mem.sliceTo(cv.commands[0].title, 0));
        try testing.expectEqualStrings("ignore", std.mem.sliceTo(cv.commands[0].action_key, 0));
        try testing.expectEqualStrings("ignore", std.mem.sliceTo(cv.commands[0].action, 0));
        try testing.expectEqualStrings("Bar", std.mem.sliceTo(cv.commands[1].title, 0));
        try testing.expectEqualStrings("bobr", std.mem.sliceTo(cv.commands[1].description, 0));
        try testing.expectEqualStrings("text", std.mem.sliceTo(cv.commands[1].action_key, 0));
        try testing.expectEqualStrings("text:ale bydle", std.mem.sliceTo(cv.commands[1].action, 0));
    }
    test "RepeatableCommand cval cleared" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Foo,action:ignore");
        try testing.expectEqual(@as(usize, 1), list.cval().len);
        try list.parseCLI(alloc, "clear");
        try testing.expectEqual(@as(usize, 0), list.cval().len);
    }
};
pub const OSCColorReportFormat = enum {
    none,
    @"8-bit",
    @"16-bit",
};
pub const WindowTheme = enum {
    auto,
    system,
    light,
    dark,
    wasp,
};
pub const WindowColorspace = enum {
    srgb,
    @"display-p3",
};
pub const MacWindowButtons = enum {
    visible,
    hidden,
};
pub const MacTitlebarStyle = enum {
    native,
    transparent,
    tabs,
    hidden,
};
pub const MacTitlebarProxyIcon = enum {
    visible,
    hidden,
};
pub const MacHidden = enum {
    never,
    always,
};
pub const MacAppIcon = enum {
    official,
    blueprint,
    chalkboard,
    microchip,
    glass,
    holographic,
    paper,
    retro,
    xray,
    custom,
    @"custom-style",
};
pub const MacAppIconFrame = enum {
    aluminum,
    beige,
    plastic,
    chrome,
};
pub const MacShortcuts = enum {
    allow,
    deny,
    ask,
};
pub const GtkSingleInstance = enum {
    false,
    true,
    detect,
    pub const default: GtkSingleInstance = .detect;
};
pub const GtkTabsLocation = enum {
    top,
    bottom,
};
pub const GtkToolbarStyle = enum {
    flat,
    raised,
    @"raised-border",
};
pub const GtkTitlebarStyle = enum(c_int) {
    native,
    tabs,
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            GtkTitlebarStyle,
            .{ .name = "WaspGtkTitlebarStyle" },
        ),
        .none => void,
    };
};
pub const AppNotifications = packed struct {
    @"clipboard-copy": bool = true,
    @"config-reload": bool = true,
};
pub const BellFeatures = packed struct {
    system: bool = false,
    audio: bool = false,
    attention: bool = true,
    title: bool = true,
    border: bool = false,
};
pub const MouseShiftCapture = enum {
    false,
    true,
    always,
    never,
};
pub const MouseScrollMultiplier = struct {
    const Self = @This();
    precision: f64 = 1,
    discrete: f64 = 3,
    pub const default: MouseScrollMultiplier = .{};
    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        self.* = cli.args.parseAutoStruct(
            MouseScrollMultiplier,
            alloc,
            input,
            self.*,
        ) catch |err| switch (err) {
            error.InvalidValue => bare: {
                const v = std.fmt.parseFloat(
                    f64,
                    input,
                ) catch return error.InvalidValue;
                break :bare .{
                    .precision = v,
                    .discrete = v,
                };
            },
            else => return err,
        };
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        _ = alloc;
        return self.*;
    }
    pub fn equal(self: Self, other: Self) bool {
        return self.precision == other.precision and self.discrete == other.discrete;
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        writer.print(
            "precision:{d},discrete:{d}",
            .{ self.precision, self.discrete },
        ) catch return error.OutOfMemory;
        try formatter.formatEntry([]const u8, writer.buffered());
    }
    test "parse" {
        const testing = std.testing;
        const alloc = testing.allocator;
        const epsilon = 0.00001;
        var args: Self = .{ .precision = 0.1, .discrete = 3 };
        try args.parseCLI(alloc, "3");
        try testing.expectApproxEqAbs(3, args.precision, epsilon);
        try testing.expectApproxEqAbs(3, args.discrete, epsilon);
        args = .{ .precision = 0.1, .discrete = 3 };
        try args.parseCLI(alloc, "precision:1");
        try testing.expectApproxEqAbs(1, args.precision, epsilon);
        try testing.expectApproxEqAbs(3, args.discrete, epsilon);
        args = .{ .precision = 0.1, .discrete = 3 };
        try args.parseCLI(alloc, "discrete:5");
        try testing.expectApproxEqAbs(0.1, args.precision, epsilon);
        try testing.expectApproxEqAbs(5, args.discrete, epsilon);
        args = .{ .precision = 0.1, .discrete = 3 };
        try args.parseCLI(alloc, "precision:3,discrete:7");
        try testing.expectApproxEqAbs(3, args.precision, epsilon);
        try testing.expectApproxEqAbs(7, args.discrete, epsilon);
        args = .{ .precision = 0.1, .discrete = 3 };
        try args.parseCLI(alloc, "discrete:8,precision:6");
        try testing.expectApproxEqAbs(6, args.precision, epsilon);
        try testing.expectApproxEqAbs(8, args.discrete, epsilon);
        args = .default;
        try testing.expectError(error.InvalidValue, args.parseCLI(alloc, "foo:1"));
        try testing.expectError(error.InvalidValue, args.parseCLI(alloc, "precision:bar"));
        try testing.expectError(error.InvalidValue, args.parseCLI(alloc, "precision:1,discrete:3,foo:5"));
        try testing.expectError(error.InvalidValue, args.parseCLI(alloc, "precision:1,,discrete:3"));
        try testing.expectError(error.InvalidValue, args.parseCLI(alloc, ",precision:1,discrete:3"));
    }
    test "format entry MouseScrollMultiplier" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var args: Self = .{ .precision = 1.5, .discrete = 2.5 };
        try args.formatEntry(formatterpkg.entryFormatter("mouse-scroll-multiplier", &buf.writer));
        try testing.expectEqualSlices(u8, "mouse-scroll-multiplier = precision:1.5,discrete:2.5\n", buf.written());
    }
};
pub const ClipboardAccess = enum {
    allow,
    deny,
    ask,
};
pub const WindowSaveState = enum {
    default,
    never,
    always,
};
pub const WindowNewTabPosition = enum {
    current,
    end,
};
pub const MacOSDockDropBehavior = enum {
    @"new-tab",
    @"new-window",
};
pub const WindowShowTabBar = enum {
    always,
    auto,
    never,
};
pub const DragHandle = enum {
    always,
    auto,
    never,
};
pub const ResizeOverlay = enum {
    always,
    never,
    @"after-first",
};
pub const ResizeOverlayPosition = enum {
    center,
    @"top-left",
    @"top-center",
    @"top-right",
    @"bottom-left",
    @"bottom-center",
    @"bottom-right",
};
pub const QuickTerminalPosition = enum {
    top,
    bottom,
    left,
    right,
    center,
};
pub const QuickTerminalLayer = enum {
    overlay,
    top,
    bottom,
    background,
};
pub const QuickTerminalSize = struct {
    primary: ?Size = null,
    secondary: ?Size = null,
    pub const Size = union(enum) {
        percentage: f32,
        pixels: u32,
        pub fn toPixels(self: Size, parent_dimensions: u32) u32 {
            switch (self) {
                .percentage => |v| {
                    const dim: f32 = @floatFromInt(parent_dimensions);
                    return @intFromFloat(v / 100.0 * dim);
                },
                .pixels => |v| return v,
            }
        }
        pub fn parse(input: []const u8) !Size {
            if (input.len == 0) return error.ValueRequired;
            if (std.mem.endsWith(u8, input, "px")) {
                return .{
                    .pixels = std.fmt.parseInt(
                        u32,
                        input[0 .. input.len - "px".len],
                        10,
                    ) catch return error.InvalidValue,
                };
            }
            if (std.mem.endsWith(u8, input, "%")) {
                const percentage = std.fmt.parseFloat(
                    f32,
                    input[0 .. input.len - "%".len],
                ) catch return error.InvalidValue;
                if (percentage < 0) return error.InvalidValue;
                return .{ .percentage = percentage };
            }
            return error.MissingUnit;
        }
        fn format(self: Size, writer: *std.Io.Writer) !void {
            switch (self) {
                .percentage => |v| try writer.print("{d}%", .{v}),
                .pixels => |v| try writer.print("{}px", .{v}),
            }
        }
    };
    pub const Dimensions = struct {
        width: u32,
        height: u32,
    };
    pub const C = extern struct {
        primary: C.Size,
        secondary: C.Size,
        pub const Size = extern struct {
            tag: Tag,
            value: Value,
            pub const Tag = enum(c_int) { none, percentage, pixels };
            pub const Value = extern union {
                percentage: f32,
                pixels: u32,
            };
            pub const none: C.Size = .{ .tag = .none, .value = undefined };
            pub fn percentage(v: f32) C.Size {
                return .{
                    .tag = .percentage,
                    .value = .{ .percentage = v },
                };
            }
            pub fn pixels(v: u32) C.Size {
                return .{
                    .tag = .pixels,
                    .value = .{ .pixels = v },
                };
            }
        };
    };
    pub fn cval(self: QuickTerminalSize) C {
        return .{
            .primary = if (self.primary) |p| switch (p) {
                .percentage => |v| .percentage(v),
                .pixels => |v| .pixels(v),
            } else .none,
            .secondary = if (self.secondary) |s| switch (s) {
                .percentage => |v| .percentage(v),
                .pixels => |v| .pixels(v),
            } else .none,
        };
    }
    pub fn calculate(
        self: QuickTerminalSize,
        position: QuickTerminalPosition,
        dims: Dimensions,
    ) Dimensions {
        switch (position) {
            .left, .right => return .{
                .width = if (self.primary) |v| v.toPixels(dims.width) else 400,
                .height = if (self.secondary) |v| v.toPixels(dims.height) else dims.height,
            },
            .top, .bottom => return .{
                .width = if (self.secondary) |v| v.toPixels(dims.width) else dims.width,
                .height = if (self.primary) |v| v.toPixels(dims.height) else 400,
            },
            .center => if (dims.width >= dims.height) {
                return .{
                    .width = if (self.primary) |v| v.toPixels(dims.width) else 800,
                    .height = if (self.secondary) |v| v.toPixels(dims.height) else 400,
                };
            } else {
                return .{
                    .width = if (self.secondary) |v| v.toPixels(dims.width) else 400,
                    .height = if (self.primary) |v| v.toPixels(dims.height) else 800,
                };
            },
        }
    }
    pub fn parseCLI(self: *QuickTerminalSize, input: ?[]const u8) !void {
        const input_ = input orelse return error.ValueRequired;
        var it = std.mem.splitScalar(u8, input_, ',');
        const primary = std.mem.trim(
            u8,
            it.next() orelse return error.ValueRequired,
            cli.args.whitespace,
        );
        self.primary = try .parse(primary);
        self.secondary = secondary: {
            const secondary = std.mem.trim(
                u8,
                it.next() orelse break :secondary null,
                cli.args.whitespace,
            );
            break :secondary try .parse(secondary);
        };
        if (it.next()) |_| return error.TooManyArguments;
    }
    pub fn clone(self: *const QuickTerminalSize, _: Allocator) Allocator.Error!QuickTerminalSize {
        return .{
            .primary = self.primary,
            .secondary = self.secondary,
        };
    }
    pub fn formatEntry(self: QuickTerminalSize, formatter: formatterpkg.EntryFormatter) !void {
        const primary = self.primary orelse return;
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        primary.format(&writer) catch return error.OutOfMemory;
        if (self.secondary) |secondary| {
            writer.writeByte(',') catch return error.OutOfMemory;
            secondary.format(&writer) catch return error.OutOfMemory;
        }
        try formatter.formatEntry([]const u8, writer.buffered());
    }
    test "parse QuickTerminalSize" {
        const testing = std.testing;
        var v: QuickTerminalSize = undefined;
        try v.parseCLI("50%");
        try testing.expectEqual(50, v.primary.?.percentage);
        try testing.expectEqual(null, v.secondary);
        try v.parseCLI("200px");
        try testing.expectEqual(200, v.primary.?.pixels);
        try testing.expectEqual(null, v.secondary);
        try v.parseCLI("50%,200px");
        try testing.expectEqual(50, v.primary.?.percentage);
        try testing.expectEqual(200, v.secondary.?.pixels);
        try testing.expectError(error.ValueRequired, v.parseCLI(null));
        try testing.expectError(error.ValueRequired, v.parseCLI(""));
        try testing.expectError(error.ValueRequired, v.parseCLI("69px,"));
        try testing.expectError(error.TooManyArguments, v.parseCLI("69px,42%,69px"));
        try testing.expectError(error.MissingUnit, v.parseCLI("420"));
        try testing.expectError(error.MissingUnit, v.parseCLI("bobr"));
        try testing.expectError(error.InvalidValue, v.parseCLI("bobr%"));
        try testing.expectError(error.InvalidValue, v.parseCLI("-32%"));
        try testing.expectError(error.InvalidValue, v.parseCLI("-69px"));
    }
    test "calculate QuickTerminalSize" {
        const testing = std.testing;
        const dims_landscape: Dimensions = .{ .width = 2560, .height = 1600 };
        const dims_portrait: Dimensions = .{ .width = 1600, .height = 2560 };
        {
            const size: QuickTerminalSize = .{};
            try testing.expectEqual(
                Dimensions{ .width = 2560, .height = 400 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 1600 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 800, .height = 400 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 800 },
                size.calculate(.center, dims_portrait),
            );
        }
        {
            const size: QuickTerminalSize = .{ .primary = .{ .percentage = 20 } };
            try testing.expectEqual(
                Dimensions{ .width = 2560, .height = 320 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 512, .height = 1600 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 512, .height = 400 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 512 },
                size.calculate(.center, dims_portrait),
            );
        }
        {
            const size: QuickTerminalSize = .{ .primary = .{ .pixels = 600 } };
            try testing.expectEqual(
                Dimensions{ .width = 2560, .height = 600 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 600, .height = 1600 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 600, .height = 400 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 600 },
                size.calculate(.center, dims_portrait),
            );
        }
        {
            const size: QuickTerminalSize = .{
                .primary = .{ .percentage = 69 },
                .secondary = .{ .pixels = 420 },
            };
            try testing.expectEqual(
                Dimensions{ .width = 420, .height = 1104 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 1766, .height = 420 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 1766, .height = 420 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 420, .height = 1766 },
                size.calculate(.center, dims_portrait),
            );
        }
    }
};
pub const QuickTerminalScreen = enum {
    main,
    mouse,
    @"macos-menu-bar",
};
pub const QuickTerminalSpaceBehavior = enum {
    remain,
    move,
};
pub const QuickTerminalKeyboardInteractivity = enum {
    none,
    @"on-demand",
    exclusive,
};
pub const GraphemeWidthMethod = enum {
    legacy,
    unicode,
};
pub const AlphaBlending = enum {
    native,
    linear,
    @"linear-corrected",
    pub fn isLinear(self: AlphaBlending) bool {
        return switch (self) {
            .native => false,
            .linear, .@"linear-corrected" => true,
        };
    }
};
pub const BackgroundImagePosition = enum {
    @"top-left",
    @"top-center",
    @"top-right",
    @"center-left",
    @"center-center",
    @"center-right",
    @"bottom-left",
    @"bottom-center",
    @"bottom-right",
    center,
};
pub const BackgroundImageFit = enum {
    contain,
    cover,
    stretch,
    none,
};
pub const FreetypeLoadFlags = packed struct {
    hinting: bool = true,
    @"force-autohint": bool = false,
    monochrome: bool = false,
    autohint: bool = true,
    light: bool = true,
};
pub const LinuxCgroup = enum {
    never,
    always,
    @"single-instance",
};
pub const AsyncBackend = enum {
    auto,
    epoll,
    io_uring,
};
pub const AutoUpdate = enum {
    off,
    check,
    download,
};
pub const BackgroundBlur = union(enum) {
    false,
    true,
    @"macos-glass-regular",
    @"macos-glass-clear",
    radius: u8,
    pub fn parseCLI(self: *BackgroundBlur, input: ?[]const u8) !void {
        const input_ = input orelse {
            self.* = .true;
            return;
        };
        if (cli.args.parseBool(input_)) |b| {
            self.* = if (b) .true else .false;
            return;
        } else |_| {}
        if (std.meta.stringToEnum(
            std.meta.Tag(BackgroundBlur),
            input_,
        )) |v| switch (v) {
            inline else => |tag| tag: {
                const info = std.meta.fieldInfo(BackgroundBlur, tag);
                if (info.type != void) break :tag;
                self.* = @unionInit(
                    BackgroundBlur,
                    @tagName(tag),
                    {},
                );
                return;
            },
        };
        self.* = .{ .radius = std.fmt.parseInt(
            u8,
            input_,
            0,
        ) catch return error.InvalidValue };
    }
    pub fn enabled(self: BackgroundBlur) bool {
        return switch (self) {
            .false => false,
            .true => true,
            .radius => |v| v > 0,
            .@"macos-glass-regular", .@"macos-glass-clear" => true,
        };
    }
    pub fn cval(self: BackgroundBlur) i16 {
        return switch (self) {
            .false => 0,
            .true => 20,
            .radius => |v| v,
            .@"macos-glass-regular" => -1,
            .@"macos-glass-clear" => -2,
        };
    }
    pub fn formatEntry(
        self: BackgroundBlur,
        formatter: anytype,
    ) !void {
        switch (self) {
            .false => try formatter.formatEntry(bool, false),
            .true => try formatter.formatEntry(bool, true),
            .radius => |v| try formatter.formatEntry(u8, v),
            .@"macos-glass-regular" => try formatter.formatEntry([]const u8, "macos-glass-regular"),
            .@"macos-glass-clear" => try formatter.formatEntry([]const u8, "macos-glass-clear"),
        }
    }
    test "parse BackgroundBlur" {
        const testing = std.testing;
        var v: BackgroundBlur = undefined;
        try v.parseCLI(null);
        try testing.expectEqual(.true, v);
        try v.parseCLI("true");
        try testing.expectEqual(.true, v);
        try v.parseCLI("false");
        try testing.expectEqual(.false, v);
        try v.parseCLI("42");
        try testing.expectEqual(42, v.radius);
        try v.parseCLI("macos-glass-regular");
        try testing.expectEqual(.@"macos-glass-regular", v);
        try v.parseCLI("macos-glass-clear");
        try testing.expectEqual(.@"macos-glass-clear", v);
        try testing.expectError(error.InvalidValue, v.parseCLI(""));
        try testing.expectError(error.InvalidValue, v.parseCLI("aaaa"));
        try testing.expectError(error.InvalidValue, v.parseCLI("420"));
    }
};
pub const WindowDecoration = enum(c_int) {
    auto,
    client,
    server,
    none,
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            WindowDecoration,
            .{ .name = "WaspConfigWindowDecoration" },
        ),
        .none => void,
    };
    pub fn parseCLI(input_: ?[]const u8) !WindowDecoration {
        const input = input_ orelse return .auto;
        return if (cli.args.parseBool(input)) |b|
            if (b) .auto else .none
        else |_| if (std.meta.stringToEnum(WindowDecoration, input)) |v|
            v
        else
            error.InvalidValue;
    }
    test "parse WindowDecoration" {
        const testing = std.testing;
        {
            const v = try WindowDecoration.parseCLI(null);
            try testing.expectEqual(WindowDecoration.auto, v);
        }
        {
            const v = try WindowDecoration.parseCLI("true");
            try testing.expectEqual(WindowDecoration.auto, v);
        }
        {
            const v = try WindowDecoration.parseCLI("false");
            try testing.expectEqual(WindowDecoration.none, v);
        }
        {
            const v = try WindowDecoration.parseCLI("server");
            try testing.expectEqual(WindowDecoration.server, v);
        }
        {
            const v = try WindowDecoration.parseCLI("client");
            try testing.expectEqual(WindowDecoration.client, v);
        }
        {
            const v = try WindowDecoration.parseCLI("auto");
            try testing.expectEqual(WindowDecoration.auto, v);
        }
        {
            const v = try WindowDecoration.parseCLI("none");
            try testing.expectEqual(WindowDecoration.none, v);
        }
        {
            try testing.expectError(error.InvalidValue, WindowDecoration.parseCLI(""));
            try testing.expectError(error.InvalidValue, WindowDecoration.parseCLI("aaaa"));
        }
    }
};
pub const Theme = struct {
    light: []const u8,
    dark: []const u8,
    pub fn parseCLI(self: *Theme, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) return error.ValueRequired;
        const has_colon = if (comptime builtin.os.tag == .windows)
            if (std.mem.indexOf(u8, input, ":")) |idx| idx != 1 else false
        else
            std.mem.indexOf(u8, input, ":") != null;
        if (std.mem.indexOf(u8, input, ",") != null or
            std.mem.indexOf(u8, input, "=") != null or
            has_colon)
        {
            self.* = try cli.args.parseAutoStruct(
                Theme,
                alloc,
                input,
                null,
            );
            return;
        }
        const trimmed = std.mem.trim(u8, input, cli.args.whitespace);
        self.* = .{
            .light = try alloc.dupeZ(u8, trimmed),
            .dark = self.light,
        };
    }
    pub fn finalize(self: *Theme, alloc: Allocator) Allocator.Error!void {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const light = expandHome(self.light, &buf);
        if (!std.mem.eql(u8, light, self.light))
            self.light = try alloc.dupeZ(u8, light);
        const dark = expandHome(self.dark, &buf);
        if (!std.mem.eql(u8, dark, self.dark))
            self.dark = try alloc.dupeZ(u8, dark);
    }
    pub fn clone(self: *const Theme, alloc: Allocator) Allocator.Error!Theme {
        return .{
            .light = try alloc.dupeZ(u8, self.light),
            .dark = try alloc.dupeZ(u8, self.dark),
        };
    }
    pub fn formatEntry(
        self: Theme,
        formatter: anytype,
    ) !void {
        var buf: [4096]u8 = undefined;
        if (std.mem.eql(u8, self.light, self.dark)) {
            try formatter.formatEntry([]const u8, self.light);
            return;
        }
        const str = std.fmt.bufPrint(&buf, "light:{s},dark:{s}", .{
            self.light,
            self.dark,
        }) catch return error.OutOfMemory;
        try formatter.formatEntry([]const u8, str);
    }
    test "parse Theme" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            var v: Theme = undefined;
            try v.parseCLI(alloc, "foo");
            try testing.expectEqualStrings("foo", v.light);
            try testing.expectEqualStrings("foo", v.dark);
        }
        {
            var v: Theme = undefined;
            try v.parseCLI(alloc, "  foo  ");
            try testing.expectEqualStrings("foo", v.light);
            try testing.expectEqualStrings("foo", v.dark);
        }
        {
            var v: Theme = undefined;
            try v.parseCLI(alloc, " light:foo,  dark : bar  ");
            try testing.expectEqualStrings("foo", v.light);
            try testing.expectEqualStrings("bar", v.dark);
        }
        {
            var environ_map = try testing.environ.createMap(alloc);
            defer environ_map.deinit();
            var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const home = try internal_os.expandHome(
                testing.io,
                &environ_map,
                "~/",
                &home_buf,
            );
            var v: Theme = undefined;
            try v.parseCLI(alloc, "light:~/foo, dark:~/bar");
            try v.finalize(alloc);
            var expected_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&expected_buf, "{s}foo", .{home}),
                v.light,
            );
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&expected_buf, "{s}bar", .{home}),
                v.dark,
            );
        }
        var v: Theme = undefined;
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, null));
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, ""));
        try testing.expectError(error.InvalidValue, v.parseCLI(alloc, "light:foo"));
        try testing.expectError(error.InvalidValue, v.parseCLI(alloc, "dark:foo"));
    }
};
pub const Duration = struct {
    duration: u64 = 0,
    const units = [_]struct {
        name: []const u8,
        factor: u64,
    }{
        .{ .name = "y", .factor = 365 * std.time.ns_per_day },
        .{ .name = "w", .factor = std.time.ns_per_week },
        .{ .name = "d", .factor = std.time.ns_per_day },
        .{ .name = "h", .factor = std.time.ns_per_hour },
        .{ .name = "m", .factor = std.time.ns_per_min },
        .{ .name = "s", .factor = std.time.ns_per_s },
        .{ .name = "ms", .factor = std.time.ns_per_ms },
        .{ .name = "µs", .factor = std.time.ns_per_us },
        .{ .name = "us", .factor = std.time.ns_per_us },
        .{ .name = "ns", .factor = 1 },
    };
    pub fn clone(self: *const Duration, _: Allocator) error{}!Duration {
        return .{ .duration = self.duration };
    }
    pub fn equal(self: Duration, other: Duration) bool {
        return self.duration == other.duration;
    }
    pub fn round(self: Duration, to: u64) Duration {
        return .{ .duration = self.duration / to * to };
    }
    pub fn lte(self: Duration, other: Duration) bool {
        return self.duration <= other.duration;
    }
    pub fn parseCLI(input: ?[]const u8) !Duration {
        var remaining = input orelse return error.ValueRequired;
        var value: ?u64 = null;
        while (remaining.len > 0) {
            while (remaining.len > 0 and std.ascii.isWhitespace(remaining[0])) {
                remaining = remaining[1..];
            }
            if (remaining.len == 0) break;
            const number: u64 = number: {
                var prev_number: ?u64 = null;
                var prev_remaining: ?[]const u8 = null;
                for (1..remaining.len + 1) |index| {
                    prev_number = std.fmt.parseUnsigned(u64, remaining[0..index], 10) catch {
                        if (prev_remaining) |prev| remaining = prev;
                        break :number prev_number;
                    };
                    prev_remaining = remaining[index..];
                }
                if (prev_remaining) |prev| remaining = prev;
                break :number prev_number;
            } orelse return error.InvalidValue;
            if (remaining.len == 0) {
                if (number == 0) {
                    value = 0;
                    break;
                }
                return error.InvalidValue;
            }
            const factor = factor: {
                var prev_factor: ?u64 = null;
                var prev_index: ?usize = null;
                for (1..remaining.len + 1) |index| {
                    const next_factor = next: {
                        for (units) |unit| {
                            if (std.mem.eql(u8, unit.name, remaining[0..index])) {
                                break :next unit.factor;
                            }
                        }
                        break :next null;
                    };
                    if (next_factor) |next| {
                        prev_factor = next;
                        prev_index = index;
                    }
                }
                if (prev_index) |index| {
                    remaining = remaining[index..];
                }
                break :factor prev_factor;
            } orelse return error.InvalidValue;
            const diff = std.math.mul(u64, number, factor) catch std.math.maxInt(u64);
            value = (value orelse 0) +| diff;
        }
        return if (value) |v| .{ .duration = v } else error.ValueRequired;
    }
    pub fn formatEntry(self: Duration, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try self.format(&writer);
        try formatter.formatEntry([]const u8, writer.buffered());
    }
    pub fn format(
        self: Duration,
        writer: *std.Io.Writer,
    ) !void {
        var value = self.duration;
        var i: usize = 0;
        for (units) |unit| {
            if (value >= unit.factor) {
                if (i > 0) writer.writeAll(" ") catch unreachable;
                const remainder = value % unit.factor;
                const quotient = (value - remainder) / unit.factor;
                writer.print("{d}{s}", .{ quotient, unit.name }) catch unreachable;
                value = remainder;
                i += 1;
            }
        }
    }
    pub fn cval(self: Duration) usize {
        return @intCast(self.asMilliseconds());
    }
    pub fn asMilliseconds(self: Duration) c_uint {
        const ms: u64 = std.math.divTrunc(
            u64,
            self.duration,
            std.time.ns_per_ms,
        ) catch std.math.maxInt(c_uint);
        return std.math.cast(c_uint, ms) orelse std.math.maxInt(c_uint);
    }
};
pub const WindowPadding = struct {
    const Self = @This();
    top_left: u32 = 0,
    bottom_right: u32 = 0,
    pub fn clone(self: Self, _: Allocator) error{}!Self {
        return self;
    }
    pub fn equal(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }
    pub fn parseCLI(input_: ?[]const u8) !WindowPadding {
        const input = input_ orelse return error.ValueRequired;
        const whitespace = " \t";
        if (std.mem.indexOf(u8, input, ",")) |idx| {
            const input_left = std.mem.trim(u8, input[0..idx], whitespace);
            const input_right = std.mem.trim(u8, input[idx + 1 ..], whitespace);
            const left = std.fmt.parseInt(u32, input_left, 10) catch
                return error.InvalidValue;
            const right = std.fmt.parseInt(u32, input_right, 10) catch
                return error.InvalidValue;
            return .{ .top_left = left, .bottom_right = right };
        } else {
            const value = std.fmt.parseInt(
                u32,
                std.mem.trim(u8, input, whitespace),
                10,
            ) catch return error.InvalidValue;
            return .{ .top_left = value, .bottom_right = value };
        }
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [128]u8 = undefined;
        if (self.top_left == self.bottom_right) {
            try formatter.formatEntry(
                []const u8,
                std.fmt.bufPrint(
                    &buf,
                    "{}",
                    .{self.top_left},
                ) catch return error.OutOfMemory,
            );
        } else {
            try formatter.formatEntry(
                []const u8,
                std.fmt.bufPrint(
                    &buf,
                    "{},{}",
                    .{ self.top_left, self.bottom_right },
                ) catch return error.OutOfMemory,
            );
        }
    }
    test "parse WindowPadding" {
        const testing = std.testing;
        {
            const v = try WindowPadding.parseCLI("100");
            try testing.expectEqual(WindowPadding{
                .top_left = 100,
                .bottom_right = 100,
            }, v);
        }
        {
            const v = try WindowPadding.parseCLI("100,200");
            try testing.expectEqual(WindowPadding{
                .top_left = 100,
                .bottom_right = 200,
            }, v);
        }
        {
            const v = try WindowPadding.parseCLI(" 100 , 200 ");
            try testing.expectEqual(WindowPadding{
                .top_left = 100,
                .bottom_right = 200,
            }, v);
        }
        try testing.expectError(error.ValueRequired, WindowPadding.parseCLI(null));
        try testing.expectError(error.InvalidValue, WindowPadding.parseCLI(""));
        try testing.expectError(error.InvalidValue, WindowPadding.parseCLI("a"));
    }
};
pub const Scrollbar = enum {
    system,
    never,
};
pub const ScrollToBottom = packed struct {
    keystroke: bool = true,
    output: bool = false,
    pub const default: ScrollToBottom = .{};
};
pub const NotifyOnCommandFinish = enum {
    never,
    unfocused,
    always,
};
pub const NotifyOnCommandFinishAction = packed struct {
    bell: bool = true,
    notify: bool = false,
};
test "parse duration" {
    inline for (Duration.units) |unit| {
        var buf: [16]u8 = undefined;
        const t = try std.fmt.bufPrint(&buf, "0{s}", .{unit.name});
        const d = try Duration.parseCLI(t);
        try std.testing.expectEqual(@as(u64, 0), d.duration);
    }
    inline for (Duration.units) |unit| {
        var buf: [16]u8 = undefined;
        const t = try std.fmt.bufPrint(&buf, "1{s}", .{unit.name});
        const d = try Duration.parseCLI(t);
        try std.testing.expectEqual(unit.factor, d.duration);
    }
    {
        const d = try Duration.parseCLI("0");
        try std.testing.expectEqual(@as(u64, 0), d.duration);
    }
    {
        const d = try Duration.parseCLI("100ns");
        try std.testing.expectEqual(@as(u64, 100), d.duration);
    }
    {
        const d = try Duration.parseCLI("1µs");
        try std.testing.expectEqual(@as(u64, 1000), d.duration);
    }
    {
        const d = try Duration.parseCLI("1µs1ns");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }
    {
        const d = try Duration.parseCLI("1µs 1ns");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }
    {
        const d = try Duration.parseCLI(" 1µs1ns");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }
    {
        const d = try Duration.parseCLI("1µs1ns ");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }
    {
        const d = try Duration.parseCLI("30s");
        try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), d.duration);
    }
    {
        const d = try Duration.parseCLI("584y 49w 23h 34m 33s 709ms 551µs 615ns");
        try std.testing.expectEqual(std.math.maxInt(u64), d.duration);
    }
    {
        const d = try Duration.parseCLI("600y");
        try std.testing.expectEqual(std.math.maxInt(u64), d.duration);
    }
    {
        const d = try Duration.parseCLI("100ns100ns");
        try std.testing.expectEqual(@as(u64, 200), d.duration);
    }
    try std.testing.expectError(error.ValueRequired, Duration.parseCLI(null));
    try std.testing.expectError(error.ValueRequired, Duration.parseCLI(""));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("1"));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("s"));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("1x"));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("1 "));
}
test "test format" {
    inline for (Duration.units) |unit| {
        const d: Duration = .{ .duration = unit.factor };
        var actual_buf: [16]u8 = undefined;
        const actual = try std.fmt.bufPrint(&actual_buf, "{f}", .{d});
        var expected_buf: [16]u8 = undefined;
        const expected = if (!std.mem.eql(u8, unit.name, "us"))
            try std.fmt.bufPrint(&expected_buf, "1{s}", .{unit.name})
        else
            "1µs";
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}
test "test entryFormatter" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var p: Duration = .{ .duration = std.math.maxInt(u64) };
    try p.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
    try std.testing.expectEqualStrings("a = 584y 49w 23h 34m 33s 709ms 551µs 615ns\n", buf.written());
}
const TestIterator = struct {
    data: []const []const u8,
    i: usize = 0,
    pub fn next(self: *TestIterator) ?[]const u8 {
        if (self.i >= self.data.len) return null;
        const result = self.data[self.i];
        self.i += 1;
        return result;
    }
};
test "parse hook: invalid command" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();
    var it: TestIterator = .{ .data = &.{"foo"} };
    try testing.expect(try cfg.parseManuallyHook(alloc, "--command", &it));
    try testing.expect(cfg.command == null);
}
test "parse e: command only" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();
    var it: TestIterator = .{ .data = &.{"foo"} };
    try testing.expect(!try cfg.parseManuallyHook(alloc, "-e", &it));
    const cmd = cfg.@"initial-command".?;
    try testing.expect(cmd == .direct);
    try testing.expectEqual(cmd.direct.len, 1);
    try testing.expectEqualStrings(cmd.direct[0], "foo");
}
test "parse e: command and args" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();
    var it: TestIterator = .{ .data = &.{ "echo", "foo", "bar baz" } };
    try testing.expect(!try cfg.parseManuallyHook(alloc, "-e", &it));
    const cmd = cfg.@"initial-command".?;
    try testing.expect(cmd == .direct);
    try testing.expectEqual(cmd.direct.len, 3);
    try testing.expectEqualStrings(cmd.direct[0], "echo");
    try testing.expectEqualStrings(cmd.direct[1], "foo");
    try testing.expectEqualStrings(cmd.direct[2], "bar baz");
}
test "clone default" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var source = try Config.default(alloc);
    defer source.deinit();
    var dest = try source.clone(alloc);
    defer dest.deinit();
    var it = source.changeIterator(&dest);
    try testing.expectEqual(@as(?Key, null), it.next());
}
test "clone preserves conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var a = try Config.default(alloc);
    defer a.deinit();
    a._conditional_state.theme = .dark;
    try testing.expectEqual(.dark, a._conditional_state.theme);
    var dest = try a.clone(alloc);
    defer dest.deinit();
    var it = a.changeIterator(&dest);
    try testing.expectEqual(@as(?Key, null), it.next());
    try testing.expectEqual(.dark, dest._conditional_state.theme);
}
test "clone can then change conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    var buf: [4096]u8 = undefined;
    {
        var file = try td.dir.createFile(testing.io, "theme_light", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_light"));
        try writer.end();
    }
    {
        var file = try td.dir.createFile(testing.io, "theme_dark", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_dark"));
        try writer.end();
    }
    var light_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const light = light_buf[0..try td.dir.realPathFile(testing.io, "theme_light", &light_buf)];
    var dark_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dark = dark_buf[0..try td.dir.realPathFile(testing.io, "theme_dark", &dark_buf)];
    var cfg_light = try Config.default(alloc);
    defer cfg_light.deinit();
    var it: TestIterator = .{ .data = &.{
        try std.fmt.allocPrint(
            alloc_arena,
            "--theme=light:{s},dark:{s}",
            .{ light, dark },
        ),
    } };
    try cfg_light.loadIter(alloc, &it);
    try cfg_light.finalize();
    var cfg_dark = (try cfg_light.changeConditionalState(.{ .theme = .dark })).?;
    defer cfg_dark.deinit();
    try testing.expectEqual(Color{
        .r = 0xEE,
        .g = 0xEE,
        .b = 0xEE,
    }, cfg_dark.background);
    var cfg_clone = try cfg_dark.clone(alloc);
    defer cfg_clone.deinit();
    try testing.expectEqual(Color{
        .r = 0xEE,
        .g = 0xEE,
        .b = 0xEE,
    }, cfg_clone.background);
    var cfg_light2 = (try cfg_clone.changeConditionalState(.{ .theme = .light })).?;
    defer cfg_light2.deinit();
    try testing.expectEqual(Color{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
    }, cfg_light2.background);
}
test "clone preserves conditional set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--theme=light:foo,dark:bar",
        "--window-theme=auto",
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();
    var clone1 = try cfg.clone(alloc);
    defer clone1.deinit();
    try testing.expect(clone1._conditional_set.contains(.theme));
}
test "working-directory expands tilde" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--working-directory=~/projects/wasp",
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const expected = internal_os.expandHome(
        io,
        &environ_map,
        "~/projects/wasp",
        &buf,
    ) catch "~/projects/wasp";
    try testing.expectEqualStrings(expected, cfg.@"working-directory".?.value().?);
}
test "changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var source = try Config.default(alloc);
    defer source.deinit();
    var dest = try source.clone(alloc);
    defer dest.deinit();
    dest.@"font-thicken" = true;
    try testing.expect(source.changed(&dest, .@"font-thicken"));
    try testing.expect(!source.changed(&dest, .@"font-size"));
}
test "changeConditionalState ignores irrelevant changes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=foo",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expect(try cfg.changeConditionalState(
            .{ .theme = .dark },
        ) == null);
    }
}
test "changeConditionalState applies relevant changes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=light:foo,dark:bar",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        var cfg2 = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer cfg2.deinit();
        try testing.expect(cfg2._conditional_set.contains(.theme));
    }
}
test "theme loading" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    var buf: [4096]u8 = undefined;
    {
        var file = try td.dir.createFile(testing.io, "theme", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_simple"));
        try writer.end();
    }
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try td.dir.realPathFile(testing.io, "theme", &path_buf)];
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        try std.fmt.allocPrint(alloc_arena, "--theme={s}", .{path}),
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();
    try testing.expectEqual(Color{
        .r = 0x12,
        .g = 0x3A,
        .b = 0xBC,
    }, cfg.background);
    try testing.expect(!cfg._conditional_set.contains(.theme));
}
test "theme loading preserves conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    var buf: [4096]u8 = undefined;
    {
        var file = try td.dir.createFile(testing.io, "theme", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_simple"));
        try writer.end();
    }
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try td.dir.realPathFile(testing.io, "theme", &path_buf)];
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg._conditional_state = .{ .theme = .dark };
    var it: TestIterator = .{ .data = &.{
        try std.fmt.allocPrint(alloc_arena, "--theme={s}", .{path}),
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();
    try testing.expect(cfg._conditional_state.theme == .dark);
}
test "theme priority is lower than config" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    var buf: [4096]u8 = undefined;
    {
        var file = try td.dir.createFile(testing.io, "theme", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_simple"));
        try writer.end();
    }
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try td.dir.realPathFile(testing.io, "theme", &path_buf)];
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--background=#ABCDEF",
        try std.fmt.allocPrint(alloc_arena, "--theme={s}", .{path}),
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();
    try testing.expectEqual(Color{
        .r = 0xAB,
        .g = 0xCD,
        .b = 0xEF,
    }, cfg.background);
}
test "theme loading correct light/dark" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    var buf: [4096]u8 = undefined;
    {
        var file = try td.dir.createFile(testing.io, "theme_light", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_light"));
        try writer.end();
    }
    {
        var file = try td.dir.createFile(testing.io, "theme_dark", .{});
        defer file.close(testing.io);
        var writer = file.writer(testing.io, &buf);
        try writer.interface.writeAll(@embedFile("testdata/theme_dark"));
        try writer.end();
    }
    var light_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const light = light_buf[0..try td.dir.realPathFile(testing.io, "theme_light", &light_buf)];
    var dark_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dark = dark_buf[0..try td.dir.realPathFile(testing.io, "theme_dark", &dark_buf)];
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            try std.fmt.allocPrint(
                alloc_arena,
                "--theme=light:{s},dark:{s}",
                .{ light, dark },
            ),
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqual(Color{
            .r = 0xFF,
            .g = 0xFF,
            .b = 0xFF,
        }, cfg.background);
    }
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        cfg._conditional_state = .{ .theme = .dark };
        var it: TestIterator = .{ .data = &.{
            try std.fmt.allocPrint(
                alloc_arena,
                "--theme=light:{s},dark:{s}",
                .{ light, dark },
            ),
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqual(Color{
            .r = 0xEE,
            .g = 0xEE,
            .b = 0xEE,
        }, cfg.background);
    }
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            try std.fmt.allocPrint(
                alloc_arena,
                "--theme=light:{s},dark:{s}",
                .{ light, dark },
            ),
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        var new = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer new.deinit();
        try testing.expectEqual(Color{
            .r = 0xEE,
            .g = 0xEE,
            .b = 0xEE,
        }, new.background);
    }
}
test "theme specifying light/dark changes window-theme from auto" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=light:foo,dark:bar",
            "--window-theme=auto",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expect(cfg.@"window-theme" == .system);
    }
}
test "theme specifying light/dark sets theme usage in conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=light:foo,dark:bar",
            "--window-theme=auto",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expect(cfg.@"window-theme" == .system);
        try testing.expect(cfg._conditional_set.contains(.theme));
    }
}
test "scrollback limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try testing.expectEqual(
        @as(usize, 50_000_000),
        cfg.@"scrollback-limit-bytes".value,
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        cfg.@"scrollback-limit-lines".value,
    );
    var it: TestIterator = .{ .data = &.{
        "--scrollback-limit-bytes=1234",
        "--scrollback-limit-lines=567",
    } };
    try cfg.loadIter(alloc, &it);
    try testing.expectEqual(
        @as(usize, 1234),
        cfg.@"scrollback-limit-bytes".value,
    );
    try testing.expectEqual(
        @as(usize, 567),
        cfg.@"scrollback-limit-lines".value,
    );
    var unlimited_it: TestIterator = .{ .data = &.{
        "--scrollback-limit-bytes=unlimited",
        "--scrollback-limit-lines=unlimited",
    } };
    try cfg.loadIter(alloc, &unlimited_it);
    try testing.expectEqual(
        std.math.maxInt(usize),
        cfg.@"scrollback-limit-bytes".value,
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        cfg.@"scrollback-limit-lines".value,
    );
    var reset_it: TestIterator = .{ .data = &.{
        "--scrollback-limit-bytes=",
        "--scrollback-limit-lines=",
    } };
    try cfg.loadIter(alloc, &reset_it);
    try testing.expectEqual(
        @as(usize, 50_000_000),
        cfg.@"scrollback-limit-bytes".value,
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        cfg.@"scrollback-limit-lines".value,
    );
}
test "clipboard write limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try testing.expectEqual(
        @as(usize, 64 * 1024 * 1024),
        cfg.@"clipboard-write-limit-bytes".value,
    );
    var it: TestIterator = .{ .data = &.{
        "--clipboard-write-limit-bytes=1234",
    } };
    try cfg.loadIter(alloc, &it);
    try testing.expectEqual(
        @as(usize, 1234),
        cfg.@"clipboard-write-limit-bytes".value,
    );
    var unlimited_it: TestIterator = .{ .data = &.{
        "--clipboard-write-limit-bytes=unlimited",
    } };
    try cfg.loadIter(alloc, &unlimited_it);
    try testing.expectEqual(
        std.math.maxInt(usize),
        cfg.@"clipboard-write-limit-bytes".value,
    );
}
test "compatibility: scrollback-limit renamed to bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--scrollback-limit=1234",
    } };
    try cfg.loadIter(alloc, &it);
    try testing.expectEqual(
        @as(usize, 1234),
        cfg.@"scrollback-limit-bytes".value,
    );
    var unlimited_it: TestIterator = .{ .data = &.{
        "--scrollback-limit=unlimited",
    } };
    try cfg.loadIter(alloc, &unlimited_it);
    try testing.expectEqual(
        std.math.maxInt(usize),
        cfg.@"scrollback-limit-bytes".value,
    );
}
test "compatibility: gtk-single-instance desktop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--gtk-single-instance=desktop",
        } };
        try cfg.loadIter(alloc, &it);
        try testing.expectEqual(
            GtkSingleInstance.detect,
            cfg.@"gtk-single-instance",
        );
    }
}
test "compatibility: removed cursor-invert-fg-bg" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--cursor-invert-fg-bg",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqual(
            TerminalColor.@"cell-foreground",
            cfg.@"cursor-color",
        );
        try testing.expectEqual(
            TerminalColor.@"cell-background",
            cfg.@"cursor-text",
        );
    }
}
test "compatibility: removed selection-invert-fg-bg" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--selection-invert-fg-bg",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqual(
            TerminalColor.@"cell-background",
            cfg.@"selection-foreground",
        );
        try testing.expectEqual(
            TerminalColor.@"cell-foreground",
            cfg.@"selection-background",
        );
    }
}
test "compatibility: removed bold-is-bright" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--bold-is-bright",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqual(
            BoldColor.bright,
            cfg.@"bold-color",
        );
    }
}
test "compatibility: window new-window" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--macos-dock-drop-behavior=window",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqual(
            MacOSDockDropBehavior.@"new-window",
            cfg.@"macos-dock-drop-behavior",
        );
    }
}
