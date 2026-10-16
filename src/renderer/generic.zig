const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const wuffs = @import("wuffs");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/root.zig");
const inputpkg = @import("../input.zig");
const os = @import("../os/root.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const cellpkg = @import("cell.zig");
const noMinContrast = cellpkg.noMinContrast;
const constraintWidth = cellpkg.constraintWidth;
const isCovering = cellpkg.isCovering;
const rowNeverExtendBg = @import("row.zig").neverExtendBg;
const Overlay = @import("Overlay.zig");
const imagepkg = @import("image.zig");
const ImageState = imagepkg.State;
const shadertoy = @import("shadertoy.zig");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;
const compat_file = @import("../lib/compat/file.zig");
const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;
const FileType = @import("../file_type.zig").FileType;
const macos = switch (builtin.os.tag) {
    .macos => @import("macos"),
    else => void,
};
const DisplayLink = switch (builtin.os.tag) {
    .macos => @import("DisplayLink.zig"),
    else => void,
};
const log = std.log.scoped(.generic_renderer);
pub fn Renderer(comptime GraphicsAPI: type) type {
    return struct {
        const Self = @This();
        pub const API = GraphicsAPI;
        pub const ExportedFrame = if (@hasDecl(GraphicsAPI, "ExportedFrame")) GraphicsAPI.ExportedFrame else void;
        pub const custom_shader_y_is_down = GraphicsAPI.custom_shader_y_is_down;
        const Target = GraphicsAPI.Target;
        const Buffer = GraphicsAPI.Buffer;
        const Sampler = GraphicsAPI.Sampler;
        const Texture = GraphicsAPI.Texture;
        const RenderPass = GraphicsAPI.RenderPass;
        const shaderpkg = GraphicsAPI.shaders;
        const Shaders = shaderpkg.Shaders;
        alloc: std.mem.Allocator,
        draw_mutex: std.Io.Mutex = .init,
        config: DerivedConfig,
        surface_mailbox: apprt.surface.Mailbox,
        latest_frame: LatestFrame = .{},
        grid_metrics: font.Metrics,
        size: renderer.Size,
        focused: bool,
        visible: bool,
        custom_shader_focused_changed: bool = false,
        scrollbar: terminal.Scrollbar,
        scrollbar_dirty: bool,
        last_bottom_node: ?usize,
        last_bottom_y: terminal.size.CellCountInt,
        search_matches: ?renderer.Message.SearchMatches,
        search_selected_match: ?renderer.Message.SearchMatch,
        search_matches_dirty: bool,
        cells: cellpkg.Contents,
        cells_rebuilt: bool = false,
        uniforms: shaderpkg.Uniforms,
        custom_shader_uniforms: shadertoy.Uniforms,
        first_frame_time: ?std.Io.Timestamp = null,
        last_frame_time: ?std.Io.Timestamp = null,
        font_grid: *font.SharedGrid,
        font_shaper: font.Shaper,
        font_shaper_cache: font.ShaperCache,
        images: ImageState = .empty,
        bg_image: ?imagepkg.Image = null,
        bg_image_changed: bool = true,
        bg_image_buffer: shaderpkg.BgImage,
        bg_image_buffer_modified: usize = 0,
        api: GraphicsAPI,
        display_link: if (DisplayLink != void) ?*DisplayLink else void =
            if (DisplayLink != void) null else {},
        health: std.atomic.Value(Health) = .{ .raw = .healthy },
        presentation_health: std.atomic.Value(Health) = .{ .raw = .healthy },
        display_realized: bool = true,
        swap_chain: ?SwapChain,
        target_config_modified: usize = 0,
        reinitialize_shaders: bool = false,
        has_custom_shaders: bool = false,
        shaders: Shaders,
        terminal_state: terminal.RenderState = .empty,
        terminal_state_frame_count: usize = 0,
        overlay: ?Overlay = null,
        kitty_animation_clock: ?std.Io.Timestamp = null,
        kitty_animation_next_ms: ?u64 = null,
        const HighlightTag = enum(u8) {
            search_match,
            search_match_selected,
        };
        const SwapChain = struct {
            const buf_count = GraphicsAPI.swap_chain_count;
            frames: [buf_count]FrameState,
            frame_index: std.math.IntFittingRange(0, buf_count) = 0,
            frame_sema: std.Io.Semaphore = .{ .permits = buf_count },
            pub fn init(api: GraphicsAPI, custom_shaders: bool) !SwapChain {
                var result: SwapChain = .{ .frames = undefined };
                for (&result.frames) |*frame| {
                    frame.* = try FrameState.init(api, custom_shaders);
                }
                return result;
            }
            pub fn deinit(self: *SwapChain) void {
                for (0..buf_count) |_| self.frame_sema.waitUncancelable(
                    global.io(),
                );
                for (&self.frames) |*frame| frame.deinit();
            }
            pub fn nextFrame(self: *SwapChain) *FrameState {
                self.frame_sema.waitUncancelable(global.io());
                self.frame_index = (self.frame_index + 1) % buf_count;
                return &self.frames[self.frame_index];
            }
            pub fn releaseFrame(self: *SwapChain) void {
                self.frame_sema.post(global.io());
            }
        };
        const FrameState = struct {
            uniforms: UniformBuffer,
            cells: CellTextBuffer,
            cells_bg: CellBgBuffer,
            grayscale: Texture,
            grayscale_modified: usize = 0,
            color: Texture,
            color_modified: usize = 0,
            target: Target,
            target_config_modified: usize = 0,
            bg_image_buffer: BgImageBuffer,
            bg_image_buffer_modified: usize = 0,
            custom_shader_state: ?CustomShaderState = null,
            const UniformBuffer = Buffer(shaderpkg.Uniforms);
            const CellBgBuffer = Buffer(shaderpkg.CellBg);
            const CellTextBuffer = Buffer(shaderpkg.CellText);
            const BgImageBuffer = Buffer(shaderpkg.BgImage);
            pub fn init(api: GraphicsAPI, custom_shaders: bool) !FrameState {
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();
                var cells = try CellTextBuffer.init(api.fgBufferOptions(), 1);
                errdefer cells.deinit();
                var cells_bg = try CellBgBuffer.init(api.bgBufferOptions(), 1);
                errdefer cells_bg.deinit();
                var bg_image_buffer = try BgImageBuffer.init(
                    api.bgImageBufferOptions(),
                    1,
                );
                errdefer bg_image_buffer.deinit();
                const grayscale = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .grayscale,
                });
                errdefer grayscale.deinit();
                const color = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .bgra,
                });
                errdefer color.deinit();
                var custom_shader_state =
                    if (custom_shaders)
                        try CustomShaderState.init(api)
                    else
                        null;
                errdefer if (custom_shader_state) |*state| state.deinit();
                const target = try api.initTarget(1, 1);
                return .{
                    .uniforms = uniforms,
                    .cells = cells,
                    .cells_bg = cells_bg,
                    .bg_image_buffer = bg_image_buffer,
                    .grayscale = grayscale,
                    .color = color,
                    .target = target,
                    .custom_shader_state = custom_shader_state,
                };
            }
            pub fn deinit(self: *FrameState) void {
                self.target.deinit();
                self.uniforms.deinit();
                self.cells.deinit();
                self.cells_bg.deinit();
                self.grayscale.deinit();
                self.color.deinit();
                self.bg_image_buffer.deinit();
                if (self.custom_shader_state) |*state| state.deinit();
            }
            pub fn resize(
                self: *FrameState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                if (self.custom_shader_state) |*state| {
                    try state.resize(api, width, height);
                }
                const target = try api.initTarget(width, height);
                self.target.deinit();
                self.target = target;
            }
        };
        const CustomShaderState = struct {
            front_texture: Texture,
            back_texture: Texture,
            sampler: Sampler,
            uniforms: UniformBuffer,
            const UniformBuffer = Buffer(shadertoy.Uniforms);
            pub fn swap(self: *CustomShaderState) void {
                std.mem.swap(Texture, &self.front_texture, &self.back_texture);
            }
            pub fn init(api: GraphicsAPI) !CustomShaderState {
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer back_texture.deinit();
                const sampler = try Sampler.init(api.samplerOptions());
                errdefer sampler.deinit();
                return .{
                    .front_texture = front_texture,
                    .back_texture = back_texture,
                    .sampler = sampler,
                    .uniforms = uniforms,
                };
            }
            pub fn deinit(self: *CustomShaderState) void {
                self.front_texture.deinit();
                self.back_texture.deinit();
                self.sampler.deinit();
                self.uniforms.deinit();
            }
            pub fn resize(
                self: *CustomShaderState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer back_texture.deinit();
                self.front_texture.deinit();
                self.back_texture.deinit();
                self.front_texture = front_texture;
                self.back_texture = back_texture;
            }
        };
        pub const DerivedConfig = struct {
            arena: ArenaAllocator,
            font_thicken: bool,
            font_thicken_strength: u8,
            font_features: std.ArrayListUnmanaged([:0]const u8),
            font_styles: font.CodepointResolver.StyleStatus,
            font_shaping_break: configpkg.FontShapingBreak,
            cursor_color: ?configpkg.Config.TerminalColor,
            cursor_opacity: f64,
            cursor_text: ?configpkg.Config.TerminalColor,
            background: terminal.color.RGB,
            background_opacity: f64,
            background_opacity_cells: bool,
            foreground: terminal.color.RGB,
            selection_background: ?configpkg.Config.TerminalColor,
            selection_foreground: ?configpkg.Config.TerminalColor,
            search_background: configpkg.Config.TerminalColor,
            search_foreground: configpkg.Config.TerminalColor,
            search_selected_background: configpkg.Config.TerminalColor,
            search_selected_foreground: configpkg.Config.TerminalColor,
            bold_color: ?terminal.Style.BoldColor,
            faint_opacity: u8,
            min_contrast: f32,
            padding_color: configpkg.WindowPaddingColor,
            custom_shaders: configpkg.RepeatablePath,
            bg_image: ?configpkg.Path,
            bg_image_opacity: f32,
            bg_image_position: configpkg.BackgroundImagePosition,
            bg_image_fit: configpkg.BackgroundImageFit,
            bg_image_repeat: bool,
            links: link.Set,
            vsync: bool,
            colorspace: configpkg.Config.WindowColorspace,
            blending: configpkg.Config.AlphaBlending,
            background_blur: configpkg.Config.BackgroundBlur,
            scroll_to_bottom_on_output: bool,
            custom_shader_animation: configpkg.CustomShaderAnimation,
            pub fn init(
                alloc_gpa: Allocator,
                config: *const configpkg.Config,
            ) !DerivedConfig {
                var arena = ArenaAllocator.init(alloc_gpa);
                errdefer arena.deinit();
                const alloc = arena.allocator();
                const custom_shaders = try config.@"custom-shader".clone(alloc);
                const bg_image =
                    if (config.@"background-image") |bg|
                        try bg.clone(alloc)
                    else
                        null;
                const font_features = try config.@"font-feature".clone(alloc);
                var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
                font_styles.set(.bold, config.@"font-style-bold" != .false);
                font_styles.set(.italic, config.@"font-style-italic" != .false);
                font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);
                const links = try link.Set.fromConfig(
                    alloc,
                    config.link.links.items,
                );
                return .{
                    .background_opacity = @max(0, @min(1, config.@"background-opacity")),
                    .background_opacity_cells = config.@"background-opacity-cells",
                    .font_thicken = config.@"font-thicken",
                    .font_thicken_strength = config.@"font-thicken-strength",
                    .font_features = font_features.list,
                    .font_styles = font_styles,
                    .font_shaping_break = config.@"font-shaping-break",
                    .cursor_color = config.@"cursor-color",
                    .cursor_text = config.@"cursor-text",
                    .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),
                    .background = config.background.toTerminalRGB(),
                    .foreground = config.foreground.toTerminalRGB(),
                    .bold_color = if (config.@"bold-color") |b| b.toTerminal() else null,
                    .faint_opacity = @intFromFloat(@ceil(config.@"faint-opacity" * 255)),
                    .min_contrast = @floatCast(config.@"minimum-contrast"),
                    .padding_color = config.@"window-padding-color",
                    .selection_background = config.@"selection-background",
                    .selection_foreground = config.@"selection-foreground",
                    .search_background = config.@"search-background",
                    .search_foreground = config.@"search-foreground",
                    .search_selected_background = config.@"search-selected-background",
                    .search_selected_foreground = config.@"search-selected-foreground",
                    .custom_shaders = custom_shaders,
                    .bg_image = bg_image,
                    .bg_image_opacity = config.@"background-image-opacity",
                    .bg_image_position = config.@"background-image-position",
                    .bg_image_fit = config.@"background-image-fit",
                    .bg_image_repeat = config.@"background-image-repeat",
                    .links = links,
                    .vsync = config.@"window-vsync",
                    .colorspace = config.@"window-colorspace",
                    .blending = config.@"alpha-blending",
                    .background_blur = config.@"background-blur",
                    .scroll_to_bottom_on_output = config.@"scroll-to-bottom".output,
                    .custom_shader_animation = config.@"custom-shader-animation",
                    .arena = arena,
                };
            }
            pub fn deinit(self: *DerivedConfig) void {
                const alloc = self.arena.allocator();
                self.links.deinit(alloc);
                self.arena.deinit();
            }
        };
        pub fn init(alloc: Allocator, options: renderer.Options) !Self {
            var api = try GraphicsAPI.init(
                alloc,
                options.device,
                options,
            );
            errdefer api.deinit();
            const has_custom_shaders = options.config.custom_shaders.value.items.len > 0;
            var font_shaper = try font.Shaper.init(alloc, .{
                .features = options.config.font_features.items,
            });
            errdefer font_shaper.deinit();
            const font_critical: struct {
                metrics: font.Metrics,
            } = font_critical: {
                const grid: *font.SharedGrid = options.font_grid;
                grid.lock.lockSharedUncancelable(global.io());
                defer grid.lock.unlockShared(global.io());
                break :font_critical .{
                    .metrics = grid.metrics,
                };
            };
            var result: Self = .{
                .alloc = alloc,
                .config = options.config,
                .surface_mailbox = options.surface_mailbox,
                .grid_metrics = font_critical.metrics,
                .size = options.size,
                .focused = true,
                .visible = true,
                .scrollbar = .zero,
                .scrollbar_dirty = false,
                .last_bottom_node = null,
                .last_bottom_y = 0,
                .search_matches = null,
                .search_selected_match = null,
                .search_matches_dirty = false,
                .cells = .{},
                .uniforms = .{
                    .projection_matrix = undefined,
                    .cell_size = undefined,
                    .grid_size = undefined,
                    .grid_padding = undefined,
                    .screen_size = undefined,
                    .padding_extend = .{},
                    .min_contrast = options.config.min_contrast,
                    .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
                    .cursor_color = undefined,
                    .bg_color = .{
                        options.config.background.r,
                        options.config.background.g,
                        options.config.background.b,
                        @intFromFloat(@round(options.config.background_opacity * 255.0)),
                    },
                    .bools = .{
                        .cursor_wide = false,
                        .use_display_p3 = options.config.colorspace == .@"display-p3",
                        .use_linear_blending = options.config.blending.isLinear(),
                        .use_linear_correction = options.config.blending == .@"linear-corrected",
                    },
                },
                .custom_shader_uniforms = .{
                    .resolution = .{ 0, 0, 1 },
                    .time = 0,
                    .time_delta = 0,
                    .frame_rate = 60,
                    .frame = 0,
                    .channel_time = @splat(@splat(0)),
                    .channel_resolution = @splat(@splat(0)),
                    .mouse = @splat(0),
                    .date = @splat(0),
                    .sample_rate = 0,
                    .current_cursor = @splat(0),
                    .previous_cursor = @splat(0),
                    .current_cursor_color = @splat(0),
                    .previous_cursor_color = @splat(0),
                    .current_cursor_style = 0,
                    .previous_cursor_style = 0,
                    .cursor_visible = 0,
                    .cursor_change_time = 0,
                    .time_focus = 0,
                    .focus = 1,
                    .palette = @splat(@splat(0)),
                    .background_color = @splat(0),
                    .foreground_color = @splat(0),
                    .cursor_color = @splat(0),
                    .cursor_text = @splat(0),
                    .selection_background_color = @splat(0),
                    .selection_foreground_color = @splat(0),
                },
                .bg_image_buffer = undefined,
                .font_grid = options.font_grid,
                .font_shaper = font_shaper,
                .font_shaper_cache = font.ShaperCache.init(),
                .api = api,
                .swap_chain = null,
                .has_custom_shaders = has_custom_shaders,
                .reinitialize_shaders = true,
                .shaders = .uninit,
            };
            result.updateFontGridUniforms();
            result.updateScreenSizeUniforms();
            result.updateBgImageBuffer();
            try result.prepBackgroundImage();
            return result;
        }
        pub fn deinit(self: *Self) void {
            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
            if (self.search_selected_match) |*m| m.arena.deinit();
            if (self.search_matches) |*m| m.arena.deinit();
            self.latest_frame.deinit(global.io());
            if (DisplayLink != void) {
                if (self.display_link) |display_link| {
                    display_link.close();
                    self.display_link = null;
                }
            }
            self.cells.deinit(self.alloc);
            self.font_shaper.deinit();
            self.font_shaper_cache.deinit(self.alloc);
            self.config.deinit();
            self.api.deinit();
            self.* = undefined;
        }
        fn initShaders(self: *Self) !void {
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
                arena_alloc,
                self.config.custom_shaders,
                GraphicsAPI.custom_shader_target,
            ) catch |err| err: {
                log.warn("error loading custom shaders err={}", .{err});
                break :err &.{};
            };
            const has_custom_shaders = custom_shaders.len > 0;
            var shaders = try self.api.initShaders(
                self.alloc,
                custom_shaders,
            );
            errdefer shaders.deinit(self.alloc);
            self.shaders = shaders;
            self.has_custom_shaders = has_custom_shaders;
        }
        pub fn threadEnter(self: *Self, surface: *apprt.Surface) !void {
            if (@hasDecl(GraphicsAPI, "threadEnter")) {
                try self.api.threadEnter(surface);
            }
        }
        pub fn threadExit(self: *Self) void {
            {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());
                self.display_realized = false;
                self.releaseGpuResources();
                self.images.deinit(self.alloc);
                self.images = .empty;
                if (self.bg_image) |img| {
                    img.deinit(self.alloc);
                    self.bg_image = null;
                }
            }
            if (@hasDecl(GraphicsAPI, "threadExit")) {
                self.api.threadExit();
            }
        }
        pub fn loopEnter(self: *Self, thr: *renderer.Thread) !void {
            if (@hasDecl(GraphicsAPI, "loopEnter")) {
                self.api.loopEnter();
            }
            if (comptime DisplayLink == void) return;
            self.syncDisplayLink(null, &thr.draw_now);
        }
        pub fn loopExit(self: *Self) void {
            if (@hasDecl(GraphicsAPI, "loopExit")) {
                self.api.loopExit();
            }
            if (comptime DisplayLink == void) return;
            const display_link = self.display_link orelse return;
            display_link.setRunning(false);
        }
        pub fn displayRealized(self: *Self) !void {
            if (@hasDecl(GraphicsAPI, "displayRealized")) {
                self.api.displayRealized();
            }
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            self.display_realized = true;
            self.reinitialize_shaders = true;
            self.target_config_modified = 1;
        }
        pub fn displayUnrealized(self: *Self) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            self.display_realized = false;
        }
        const LatestFrame = struct {
            const Self = @This();
            mutex: std.Io.Mutex = .init,
            latest: ?ExportedFrame = null,
            pub fn push(self: *LatestFrame, io: std.Io, value: ExportedFrame) void {
                if (comptime ExportedFrame == void) return;
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (self.latest) |*old| old.deinit();
                self.latest = value;
            }
            pub fn take(self: *LatestFrame, io: std.Io) ?ExportedFrame {
                if (comptime ExportedFrame == void) return null;
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                const result = self.latest orelse return null;
                self.latest = null;
                return result;
            }
            pub fn deinit(self: *LatestFrame, io: std.Io) void {
                if (comptime ExportedFrame == void) return;
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (self.latest) |*v| v.deinit();
                self.latest = null;
            }
        };
        pub fn pushFrame(self: *Self, frame: ExportedFrame) void {
            return self.latest_frame.push(global.io(), frame);
        }
        pub fn takeFrame(self: *Self) ?ExportedFrame {
            return self.latest_frame.take(global.io());
        }
        fn displayLinkCallback(
            _: *macos.video.DisplayLink,
            ud: ?*xev.Async,
        ) void {
            const draw_now = ud orelse return;
            draw_now.notify() catch |err| {
                log.err("error notifying draw_now err={}", .{err});
            };
        }
        pub inline fn markDirty(self: *Self) void {
            self.terminal_state.dirty = .full;
        }
        pub fn setMacOSDisplayID(
            self: *Self,
            id: u32,
            draw_now: *xev.Async,
        ) !void {
            if (comptime DisplayLink == void) return;
            self.syncDisplayLink(id, draw_now);
        }
        pub const draw_interval_ms: u64 = 8;
        pub const AnimationWake = struct {
            delay_ms: u64,
            kind: Kind,
            pub const Kind = enum {
                draw,
                update,
            };
        };
        pub fn animationWake(self: *const Self) ?AnimationWake {
            const shader_delay: ?u64 = shader: {
                if (!self.has_custom_shaders) break :shader null;
                break :shader switch (self.config.custom_shader_animation) {
                    .false => null,
                    .always => draw_interval_ms,
                    .true => if (self.focused) draw_interval_ms else null,
                };
            };
            const kitty_delay: ?u64 = kitty: {
                const next = self.kitty_animation_next_ms orelse break :kitty null;
                const base = self.kitty_animation_clock orelse break :kitty null;
                const now: std.Io.Timestamp = .now(global.io(), .awake);
                const now_ms: u64 = @intCast(@divTrunc(
                    base.durationTo(now).nanoseconds,
                    std.time.ns_per_ms,
                ));
                break :kitty @max(next -| now_ms, draw_interval_ms);
            };
            if (kitty_delay) |k| {
                if (shader_delay == null or k <= shader_delay.?) {
                    return .{ .delay_ms = k, .kind = .update };
                }
            }
            if (shader_delay) |s| return .{ .delay_ms = s, .kind = .draw };
            return null;
        }
        pub fn hasVsync(self: *const Self) bool {
            if (comptime DisplayLink == void) return false;
            const display_link = self.display_link orelse return false;
            return display_link.isRunning();
        }
        pub fn setFocus(self: *Self, focus: bool) !void {
            assert(self.focused != focus);
            self.focused = focus;
            self.custom_shader_focused_changed = true;
            self.syncDisplayLink(null, null);
        }
        pub fn setPresentationHealth(self: *Self, health: Health) void {
            self.presentation_health.store(health, .seq_cst);
        }
        pub fn presentationHealth(self: *Self) Health {
            return self.presentation_health.load(.seq_cst);
        }
        pub fn setVisible(self: *Self, visible: bool) void {
            self.visible = visible;
            self.syncDisplayLink(null, null);
            if (!visible) {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());
                self.releaseGpuResources();
            }
        }
        pub fn releaseGpuResources(self: *Self) void {
            if (self.swap_chain) |*sc| {
                sc.deinit();
                self.swap_chain = null;
            }
            if (!self.display_realized) {
                self.shaders.deinit(self.alloc);
            }
        }
        fn syncDisplayLink(
            self: *Self,
            display_id: ?u32,
            draw_now: ?*xev.Async,
        ) void {
            if (comptime DisplayLink == void) return;
            const display_link = self.display_link orelse display_link: {
                if (!self.config.vsync) return;
                const callback = draw_now orelse return;
                const result = DisplayLink.create(
                    self.alloc,
                    xev.Async,
                    &displayLinkCallback,
                    callback,
                ) catch |err| {
                    log.warn("error creating display link; using fallback rendering err={}", .{err});
                    return;
                };
                self.display_link = result;
                log.info("created display link", .{});
                break :display_link result;
            };
            if (display_id) |id| display_link.setDisplay(id);
            const should_run =
                self.visible and
                (self.cells_rebuilt or self.animationWake() != null);
            display_link.setRunning(should_run);
        }
        pub fn setFontGrid(self: *Self, grid: *font.SharedGrid) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            self.font_grid = grid;
            if (self.swap_chain) |*sc| for (&sc.frames) |*frame| {
                frame.grayscale_modified = 0;
                frame.color_modified = 0;
            };
            const metrics = grid.metrics;
            self.grid_metrics = metrics;
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;
            self.size.cell = .{
                .width = metrics.cell_width,
                .height = metrics.cell_height,
            };
            self.updateFontGridUniforms();
            self.markDirty();
        }
        fn updateFontGridUniforms(self: *Self) void {
            self.uniforms.cell_size = .{
                @floatFromInt(self.grid_metrics.cell_width),
                @floatFromInt(self.grid_metrics.cell_height),
            };
        }
        pub fn updateFrame(
            self: *Self,
            state: *renderer.State,
            cursor_blink_visible: bool,
        ) Allocator.Error!void {
            defer self.font_shaper.endFrame();
            const max_terminal_state_frame_count = 100_000;
            if (self.terminal_state_frame_count >= max_terminal_state_frame_count) {
                self.terminal_state.deinit(self.alloc);
                self.terminal_state = .empty;
                self.terminal_state_frame_count = 0;
            }
            self.terminal_state_frame_count += 1;
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            const Critical = struct {
                links: terminal.RenderState.CellSet,
                mouse: renderer.State.Mouse,
                preedit: ?renderer.State.Preedit,
                scrollbar: terminal.Scrollbar,
                overlay_features: []const Overlay.Feature,
            };
            var critical: Critical = critical: {
                state.lockDemand(global.io());
                defer state.unlockDemand(global.io());
                if (state.terminal.modes.get(.synchronized_output)) {
                    log.debug("synchronized output started, skipping render", .{});
                    return;
                }
                if (self.config.scroll_to_bottom_on_output) scroll: {
                    const br = state.terminal.screens.active.pages.getBottomRight(.screen) orelse break :scroll;
                    if (self.last_bottom_node == @intFromPtr(br.node) and
                        self.last_bottom_y == br.y) break :scroll;
                    self.last_bottom_node = @intFromPtr(br.node);
                    self.last_bottom_y = br.y;
                    state.terminal.scrollViewport(.bottom);
                }
                try self.terminal_state.beginUpdate(
                    self.alloc,
                    state.terminal,
                );
                if (self.terminal_state.dirty != .false) {
                    state.terminal.flags.search_viewport_dirty = true;
                }
                const scrollbar = state.terminal.screens.active.pages.scrollbar();
                const preedit: ?renderer.State.Preedit = preedit: {
                    const p = state.preedit orelse break :preedit null;
                    break :preedit try p.clone(arena_alloc);
                };
                self.kitty_animation_next_ms = next: {
                    const storage = &state.terminal.screens.active.kitty_images;
                    if (storage.images.count() == 0) break :next null;
                    const now: std.Io.Timestamp = .now(global.io(), .awake);
                    const base = self.kitty_animation_clock orelse base: {
                        self.kitty_animation_clock = now;
                        break :base now;
                    };
                    const now_ms: u64 = @intCast(@divTrunc(
                        base.durationTo(now).nanoseconds,
                        std.time.ns_per_ms,
                    ));
                    const delay = storage.animationTick(
                        global.io(),
                        now_ms,
                    ) orelse break :next null;
                    break :next now_ms + delay;
                };
                if (self.images.kittyRequiresUpdate(state.terminal)) {
                    self.draw_mutex.lockUncancelable(global.io());
                    defer self.draw_mutex.unlock(global.io());
                    self.images.kittyUpdate(
                        self.alloc,
                        state.terminal,
                        .{
                            .width = self.grid_metrics.cell_width,
                            .height = self.grid_metrics.cell_height,
                        },
                    );
                }
                const links: terminal.RenderState.CellSet = osc8: {
                    const vp = state.mouse.point orelse break :osc8 .empty;
                    if (!state.mouse.mods.equal(inputpkg.ctrlOrSuper(.{})))
                        break :osc8 .empty;
                    break :osc8 self.terminal_state.linkCells(
                        arena_alloc,
                        vp,
                    ) catch |err| {
                        log.warn("error searching for OSC8 links err={}", .{err});
                        break :osc8 .empty;
                    };
                };
                const overlay_features: []const Overlay.Feature = overlay: {
                    const insp = state.inspector orelse break :overlay &.{};
                    const renderer_info = insp.rendererInfo();
                    break :overlay renderer_info.overlayFeatures(
                        arena_alloc,
                    ) catch &.{};
                };
                break :critical .{
                    .links = links,
                    .mouse = state.mouse,
                    .preedit = preedit,
                    .scrollbar = scrollbar,
                    .overlay_features = overlay_features,
                };
            };
            self.terminal_state.endUpdate();
            self.config.links.renderCellMap(
                arena_alloc,
                &critical.links,
                &self.terminal_state,
                state.mouse.point,
                state.mouse.mods,
            ) catch |err| {
                log.warn("error searching for regex links err={}", .{err});
            };
            if (self.search_matches_dirty or self.terminal_state.dirty != .false) {
                self.search_matches_dirty = false;
                const row_data = self.terminal_state.row_data.slice();
                var any_dirty: bool = false;
                for (
                    row_data.items(.highlights),
                    row_data.items(.dirty),
                ) |*highlights, *dirty| {
                    if (highlights.items.len > 0) {
                        highlights.clearRetainingCapacity();
                        dirty.* = true;
                        any_dirty = true;
                    }
                }
                if (any_dirty and self.terminal_state.dirty == .false) {
                    self.terminal_state.dirty = .partial;
                }
                if (self.search_selected_match) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match_selected),
                        &.{m.match},
                    ) catch |err| {
                        log.warn("error updating search selected highlight err={}", .{err});
                    };
                }
                if (self.search_matches) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match),
                        m.matches,
                    ) catch |err| {
                        log.warn("error updating search highlights err={}", .{err});
                    };
                }
            }
            errdefer comptime unreachable;
            defer self.terminal_state.dirty = .false;
            self.rebuildOverlay(
                critical.overlay_features,
            ) catch |err| {
                log.warn(
                    "error rebuilding overlay surface err={}",
                    .{err},
                );
            };
            {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());
                self.rebuildCells(
                    critical.preedit,
                    renderer.cursorStyle(&self.terminal_state, .{
                        .preedit = critical.preedit != null,
                        .focused = self.focused,
                        .blink_visible = cursor_blink_visible,
                    }),
                    &critical.links,
                ) catch |err| {
                    comptime assert(@TypeOf(err) == error{OutOfMemory});
                    log.warn("error rebuilding GPU cells err={}", .{err});
                };
                if (!self.scrollbar.eql(critical.scrollbar)) {
                    self.scrollbar = critical.scrollbar;
                    self.scrollbar_dirty = true;
                }
                self.uniforms.bg_color = .{
                    self.terminal_state.colors.background.r,
                    self.terminal_state.colors.background.g,
                    self.terminal_state.colors.background.b,
                    @intFromFloat(@round(self.config.background_opacity * 255.0)),
                };
                if (comptime builtin.os.tag == .macos) switch (self.config.background_blur) {
                    .@"macos-glass-regular",
                    .@"macos-glass-clear",
                    => self.uniforms.bg_color[3] = 0,
                    else => {},
                };
                self.images.overlayUpdate(
                    self.alloc,
                    self.overlay,
                ) catch |err| {
                    log.warn("error updating overlay images err={}", .{err});
                };
                self.updateCustomShaderUniformsFromState();
            }
            self.syncDisplayLink(null, null);
        }
        pub fn drawFrame(
            self: *Self,
            sync: bool,
        ) !void {
            const sync_display_link = locked: {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());
                break :locked try self.drawFrameLocked(sync);
            };
            if (sync_display_link) self.syncDisplayLink(null, null);
        }
        fn drawFrameLocked(
            self: *Self,
            sync: bool,
        ) !bool {
            defer if (self.scrollbar_dirty) {
                if (self.surface_mailbox.push(.{
                    .scrollbar = self.scrollbar,
                }, .instant) > 0) self.scrollbar_dirty = false;
            };
            self.api.drawFrameStart();
            defer self.api.drawFrameEnd();
            const surface_size = try self.api.surfaceSize();
            if (surface_size.width == 0 or surface_size.height == 0) return false;
            if (!self.display_realized) return false;
            const swap_chain: *SwapChain, const swap_chain_rebuilt: bool =
                if (self.swap_chain) |*sc| .{ sc, false } else rebuild: {
                    self.swap_chain = try SwapChain.init(
                        self.api,
                        self.has_custom_shaders,
                    );
                    break :rebuild .{ &self.swap_chain.?, true };
                };
            const size_changed =
                self.size.screen.width != surface_size.width or
                self.size.screen.height != surface_size.height;
            const needs_redraw =
                size_changed or
                swap_chain_rebuilt or
                self.cells_rebuilt or
                self.animationWake() != null or
                sync;
            if (!needs_redraw) {
                return true;
            }
            self.cells_rebuilt = false;
            const frame = swap_chain.nextFrame();
            errdefer swap_chain.releaseFrame();
            if (self.reinitialize_shaders) {
                self.reinitialize_shaders = false;
                self.shaders.deinit(self.alloc);
                try self.initShaders();
            }
            assert(!self.shaders.defunct);
            if (self.has_custom_shaders) {
                if (frame.custom_shader_state == null) {
                    frame.custom_shader_state = try .init(self.api);
                    try frame.custom_shader_state.?.resize(
                        self.api,
                        surface_size.width,
                        surface_size.height,
                    );
                }
            } else if (frame.custom_shader_state) |*state| {
                state.deinit();
                frame.custom_shader_state = null;
            }
            if (size_changed) {
                self.size.screen = .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
                self.updateScreenSizeUniforms();
            }
            if (frame.target.width != self.size.screen.width or
                frame.target.height != self.size.screen.height or
                frame.target_config_modified != self.target_config_modified)
            {
                try frame.resize(
                    self.api,
                    self.size.screen.width,
                    self.size.screen.height,
                );
                frame.target_config_modified = self.target_config_modified;
            }
            _ = self.images.upload(self.alloc, &self.api);
            try self.uploadBackgroundImage();
            try self.updateCustomShaderUniformsForFrame();
            try frame.uniforms.sync(&.{self.uniforms});
            try frame.cells_bg.sync(self.cells.bg_cells);
            const fg_count = try frame.cells.syncFromArrayLists(self.cells.fg_rows);
            if (frame.bg_image_buffer_modified != self.bg_image_buffer_modified) {
                try frame.bg_image_buffer.sync(&.{self.bg_image_buffer});
                frame.bg_image_buffer_modified = self.bg_image_buffer_modified;
            }
            texture: {
                const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                if (modified <= frame.grayscale_modified) break :texture;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_grayscale, &frame.grayscale);
            }
            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);
                if (modified <= frame.color_modified) break :texture;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_color, &frame.color);
            }
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            defer frame_ctx.complete(sync);
            {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = if (frame.custom_shader_state) |state|
                        .{ .texture = state.back_texture }
                    else
                        .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                defer pass.complete();
                if (self.bg_image) |img| switch (img) {
                    .ready => |texture| pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_image,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{frame.bg_image_buffer.buffer},
                        .textures = &.{texture},
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    }),
                    else => {},
                } else {
                    pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_color,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{ null, frame.cells_bg.buffer },
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_bg,
                );
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_bg,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{ null, frame.cells_bg.buffer },
                    .draw = .{ .type = .triangle, .vertex_count = 3 },
                });
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_text,
                );
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_text,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{
                        frame.cells.buffer,
                        frame.cells_bg.buffer,
                    },
                    .textures = &.{
                        frame.grayscale,
                        frame.color,
                    },
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                        .instance_count = fg_count,
                    },
                });
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_above_text,
                );
                if (self.overlay != null) self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .overlay,
                );
            }
            if (frame.custom_shader_state) |*state| {
                try state.uniforms.sync(&.{self.custom_shader_uniforms});
                for (self.shaders.post_pipelines, 0..) |pipeline, i| {
                    defer state.swap();
                    var pass = frame_ctx.renderPass(&.{.{
                        .target = if (i < self.shaders.post_pipelines.len - 1)
                            .{ .texture = state.front_texture }
                        else
                            .{ .target = frame.target },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();
                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.back_texture},
                        .samplers = &.{state.sampler},
                        .draw = .{
                            .type = .triangle,
                            .vertex_count = 3,
                        },
                    });
                }
            }
            return false;
        }
        pub fn frameCompleted(
            self: *Self,
            health: Health,
        ) void {
            if (self.health.load(.seq_cst) != health) {
                self.health.store(health, .seq_cst);
                _ = self.surface_mailbox.push(.{
                    .renderer_health = health,
                }, .{ .forever = {} });
            }
            self.swap_chain.?.releaseFrame();
        }
        fn prepBackgroundImage(self: *Self) !void {
            if (self.config.bg_image) |p| load_background: {
                const path = switch (p) {
                    .required, .optional => |slice| slice,
                };
                var file = std.Io.Dir.openFileAbsolute(
                    global.io(),
                    path,
                    .{},
                ) catch |err| {
                    log.warn(
                        "error opening background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer file.close(global.io());
                const contents = compat_file.readToEndAlloc(
                    file,
                    self.alloc,
                    std.math.maxInt(u32),
                ) catch |err| {
                    log.warn(
                        "error reading background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer self.alloc.free(contents);
                const file_type = switch (FileType.detect(contents)) {
                    .unknown => FileType.guessFromExtension(
                        std.fs.path.extension(path),
                    ),
                    else => |t| t,
                };
                const image_data = switch (file_type) {
                    .png => try wuffs.png.decode(self.alloc, contents),
                    .jpeg => try wuffs.jpeg.decode(self.alloc, contents),
                    .unknown => {
                        log.warn(
                            "Cannot determine file type for background image file \"{s}\"!",
                            .{path},
                        );
                        break :load_background;
                    },
                    else => |f| {
                        log.warn(
                            "Unsupported file type {} for background image file \"{s}\"!",
                            .{ f, path },
                        );
                        break :load_background;
                    },
                };
                const image: imagepkg.Image = .{
                    .pending = .{
                        .width = image_data.width,
                        .height = image_data.height,
                        .pixel_format = .rgba,
                        .data = image_data.data.ptr,
                    },
                };
                if (self.bg_image) |*img| {
                    img.markForReplace(self.alloc, image);
                } else {
                    self.bg_image = image;
                }
            } else {
                if (self.bg_image) |*img| img.markForUnload();
            }
        }
        fn uploadBackgroundImage(self: *Self) !void {
            if (self.bg_image) |*bg| {
                if (bg.isUnloading()) {
                    bg.deinit(self.alloc);
                    self.bg_image = null;
                    return;
                }
                if (bg.isPending()) try bg.upload(self.alloc, &self.api);
            }
        }
        pub fn changeConfig(self: *Self, config: *DerivedConfig) !void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            {
                var font_shaper = try font.Shaper.init(self.alloc, .{
                    .features = config.font_features.items,
                });
                errdefer font_shaper.deinit();
                self.font_shaper.deinit();
                self.font_shaper = font_shaper;
            }
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;
            self.uniforms.min_contrast = config.min_contrast;
            self.uniforms.bools.use_display_p3 = config.colorspace == .@"display-p3";
            self.uniforms.bools.use_linear_blending = config.blending.isLinear();
            self.uniforms.bools.use_linear_correction = config.blending == .@"linear-corrected";
            const bg_image_config_changed =
                self.config.bg_image_fit != config.bg_image_fit or
                self.config.bg_image_position != config.bg_image_position or
                self.config.bg_image_repeat != config.bg_image_repeat or
                self.config.bg_image_opacity != config.bg_image_opacity;
            const bg_image_changed =
                if (self.config.bg_image) |old|
                    if (config.bg_image) |new|
                        !old.equal(new)
                    else
                        true
                else
                    config.bg_image != null;
            const old_blending = self.config.blending;
            const custom_shaders_changed = !self.config.custom_shaders.equal(config.custom_shaders);
            self.config.deinit();
            self.config = config.*;
            if (bg_image_changed) try self.prepBackgroundImage();
            if (bg_image_config_changed) self.updateBgImageBuffer();
            self.markDirty();
            const blending_changed = old_blending != config.blending;
            if (blending_changed) {
                self.api.blending = config.blending;
                self.reinitialize_shaders = true;
                self.target_config_modified +%= 1;
            }
            if (custom_shaders_changed) {
                self.reinitialize_shaders = true;
            }
        }
        pub fn setScreenSize(
            self: *Self,
            size: renderer.Size,
        ) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            self.size = size;
            self.updateScreenSizeUniforms();
            if (@hasDecl(GraphicsAPI, "setViewport")) {
                self.api.setViewport(self.size.screen.width, self.size.screen.height);
            }
            log.debug("screen size size={}", .{size});
        }
        fn updateScreenSizeUniforms(self: *Self) void {
            const terminal_size = self.size.terminal();
            const blank: renderer.Padding = self.size.screen.blankPadding(
                self.size.padding,
                .{
                    .columns = self.cells.size.columns,
                    .rows = self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);
            self.uniforms.projection_matrix = math.ortho2d(
                -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                @floatFromInt(terminal_size.width + self.size.padding.right),
                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            );
            self.uniforms.grid_padding = .{
                @floatFromInt(blank.top),
                @floatFromInt(blank.right),
                @floatFromInt(blank.bottom),
                @floatFromInt(blank.left),
            };
            self.uniforms.screen_size = .{
                @floatFromInt(self.size.screen.width),
                @floatFromInt(self.size.screen.height),
            };
        }
        fn updateBgImageBuffer(self: *Self) void {
            self.bg_image_buffer = .{
                .opacity = self.config.bg_image_opacity,
                .info = .{
                    .position = switch (self.config.bg_image_position) {
                        .@"top-left" => .tl,
                        .@"top-center" => .tc,
                        .@"top-right" => .tr,
                        .@"center-left" => .ml,
                        .@"center-center", .center => .mc,
                        .@"center-right" => .mr,
                        .@"bottom-left" => .bl,
                        .@"bottom-center" => .bc,
                        .@"bottom-right" => .br,
                    },
                    .fit = switch (self.config.bg_image_fit) {
                        .contain => .contain,
                        .cover => .cover,
                        .stretch => .stretch,
                        .none => .none,
                    },
                    .repeat = self.config.bg_image_repeat,
                },
            };
            self.bg_image_buffer_modified +%= 1;
        }
        fn updateCustomShaderUniformsFromState(self: *Self) void {
            if (!self.has_custom_shaders) return;
            if (self.terminal_state.dirty == .false) return;
            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const colors: *const terminal.RenderState.Colors = &self.terminal_state.colors;
            for (colors.palette, 0..) |color, i| {
                uniforms.palette[i] = .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    1.0,
                };
            }
            uniforms.background_color = .{
                @as(f32, @floatFromInt(colors.background.r)) / 255.0,
                @as(f32, @floatFromInt(colors.background.g)) / 255.0,
                @as(f32, @floatFromInt(colors.background.b)) / 255.0,
                1.0,
            };
            uniforms.foreground_color = .{
                @as(f32, @floatFromInt(colors.foreground.r)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.g)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.b)) / 255.0,
                1.0,
            };
            if (colors.cursor) |cursor_color| {
                uniforms.cursor_color = .{
                    @as(f32, @floatFromInt(cursor_color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.b)) / 255.0,
                    1.0,
                };
            }
            if (self.config.cursor_text) |cursor_text| {
                uniforms.cursor_text = .{
                    @as(f32, @floatFromInt(cursor_text.color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.b)) / 255.0,
                    1.0,
                };
            }
            if (self.config.selection_background) |selection_bg| {
                uniforms.selection_background_color = .{
                    @as(f32, @floatFromInt(selection_bg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.b)) / 255.0,
                    1.0,
                };
            }
            if (self.config.selection_foreground) |selection_fg| {
                uniforms.selection_foreground_color = .{
                    @as(f32, @floatFromInt(selection_fg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.b)) / 255.0,
                    1.0,
                };
            }
            uniforms.cursor_visible = @intFromBool(self.terminal_state.cursor.visible);
            const cursor_style: renderer.CursorStyle = .fromTerminal(self.terminal_state.cursor.visual_style);
            uniforms.previous_cursor_style = uniforms.current_cursor_style;
            uniforms.current_cursor_style = @as(i32, @intFromEnum(cursor_style));
        }
        fn updateCustomShaderUniformsForFrame(self: *Self) !void {
            if (!self.has_custom_shaders) return;
            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            defer self.last_frame_time = now;
            const first_frame_time = self.first_frame_time orelse t: {
                self.first_frame_time = now;
                break :t now;
            };
            const last_frame_time = self.last_frame_time orelse now;
            const since_ns: f32 = @floatFromInt(first_frame_time.durationTo(now).nanoseconds);
            uniforms.time = since_ns / std.time.ns_per_s;
            const delta_ns: f32 = @floatFromInt(last_frame_time.durationTo(now).nanoseconds);
            uniforms.time_delta = delta_ns / std.time.ns_per_s;
            uniforms.frame += 1;
            const screen = self.size.screen;
            const padding = self.size.padding;
            const cell = self.size.cell;
            uniforms.resolution = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
            };
            uniforms.channel_resolution[0] = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
                0,
            };
            if (self.cells.getCursorGlyph()) |cursor| {
                const cursor_width: f32 = @floatFromInt(cursor.glyph_size[0]);
                const cursor_height: f32 = @floatFromInt(cursor.glyph_size[1]);
                var pixel_x: f32 = @floatFromInt(
                    cursor.grid_pos[0] * cell.width + padding.left,
                );
                var pixel_y: f32 = @floatFromInt(
                    cursor.grid_pos[1] * cell.height + padding.top,
                );
                if (!GraphicsAPI.custom_shader_y_is_down) {
                    pixel_y = @as(f32, @floatFromInt(screen.height)) - pixel_y;
                }
                pixel_x += @floatFromInt(cursor.bearings[0]);
                if (GraphicsAPI.custom_shader_y_is_down) {
                    pixel_y += @floatFromInt(cell.height);
                    pixel_y -= @floatFromInt(cursor.bearings[1]);
                    pixel_y += @floatFromInt(cursor.glyph_size[1]);
                } else {
                    pixel_y -= @floatFromInt(cell.height);
                    pixel_y += @floatFromInt(cursor.bearings[1]);
                }
                const new_cursor: [4]f32 = .{
                    pixel_x,
                    pixel_y,
                    cursor_width,
                    cursor_height,
                };
                const cursor_color: [4]f32 = .{
                    @as(f32, @floatFromInt(cursor.color[0])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[1])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[2])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[3])) / 255.0,
                };
                const cursor_changed: bool =
                    !std.meta.eql(new_cursor, uniforms.current_cursor) or
                    !std.meta.eql(cursor_color, uniforms.current_cursor_color);
                if (cursor_changed) {
                    uniforms.previous_cursor = uniforms.current_cursor;
                    uniforms.previous_cursor_color = uniforms.current_cursor_color;
                    uniforms.current_cursor = new_cursor;
                    uniforms.current_cursor_color = cursor_color;
                    uniforms.cursor_change_time = uniforms.time;
                }
            }
            uniforms.focus = @intFromBool(self.focused);
            if (self.custom_shader_focused_changed and self.focused) {
                uniforms.time_focus = uniforms.time;
                self.custom_shader_focused_changed = false;
            }
        }
        fn rebuildOverlay(
            self: *Self,
            features: []const Overlay.Feature,
        ) Overlay.InitError!void {
            const alloc = self.alloc;
            if (features.len == 0) {
                if (self.overlay) |*old| {
                    old.deinit(alloc);
                    self.overlay = null;
                }
                return;
            }
            const overlay: *Overlay = overlay: {
                if (self.overlay) |*v| existing: {
                    const width: u32 = @intCast(v.surface.getWidth());
                    const height: u32 = @intCast(v.surface.getHeight());
                    const term_size = self.size.terminal();
                    if (width != term_size.width or
                        height != term_size.height) break :existing;
                    if (v.cell_size.width != self.size.cell.width or
                        v.cell_size.height != self.size.cell.height) break :existing;
                    v.reset();
                    break :overlay v;
                }
                if (self.overlay) |*v| {
                    v.deinit(alloc);
                    self.overlay = null;
                }
                assert(self.overlay == null);
                const new: Overlay = try .init(alloc, self.size);
                self.overlay = new;
                break :overlay &self.overlay.?;
            };
            overlay.applyFeatures(
                alloc,
                &self.terminal_state,
                features,
            );
        }
        const PreeditRange = struct {
            y: terminal.size.CellCountInt,
            x: [2]terminal.size.CellCountInt,
            cp_offset: usize,
        };
        fn rebuildCells(
            self: *Self,
            preedit: ?renderer.State.Preedit,
            cursor_style_: ?renderer.CursorStyle,
            links: *const terminal.RenderState.CellSet,
        ) Allocator.Error!void {
            const state: *terminal.RenderState = &self.terminal_state;
            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;
            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
                new_size.columns = state.cols;
                try self.cells.resize(self.alloc, new_size);
                self.uniforms.grid_size = .{ new_size.columns, new_size.rows };
            }
            const rebuild = state.dirty == .full or grid_size_diff;
            if (rebuild) {
                self.cells.reset();
                switch (self.config.padding_color) {
                    .background => {},
                    .extend, .@"extend-always" => {
                        self.uniforms.padding_extend = .{
                            .up = true,
                            .down = true,
                            .left = true,
                            .right = true,
                        };
                    },
                }
            }
            errdefer comptime unreachable;
            const row_data = state.row_data.slice();
            const row_raws = row_data.items(.raw);
            const row_cells = row_data.items(.cells);
            const row_dirty = row_data.items(.dirty);
            const row_selection = row_data.items(.selection);
            const row_highlights = row_data.items(.highlights);
            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );
            const preedit_range: ?PreeditRange = if (preedit) |preedit_v| preedit: {
                const cursor_vp = state.cursor.viewport orelse
                    break :preedit null;
                if (!rebuild and !row_dirty[cursor_vp.y]) break :preedit null;
                const range = preedit_v.range(
                    cursor_vp.x,
                    state.cols - 1,
                );
                break :preedit .{
                    .y = @intCast(cursor_vp.y),
                    .x = .{ range.start, range.end },
                    .cp_offset = range.cp_offset,
                };
            } else null;
            for (
                0..,
                row_raws[0..row_len],
                row_cells[0..row_len],
                row_dirty[0..row_len],
                row_selection[0..row_len],
                row_highlights[0..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
                const y: terminal.size.CellCountInt = @intCast(y_usize);
                if (!rebuild) {
                    if (!dirty.*) continue;
                    self.cells.clear(y);
                }
                dirty.* = false;
                self.rebuildRow(
                    y,
                    row,
                    cells,
                    preedit_range,
                    selection,
                    highlights,
                    links,
                ) catch |err| {
                    log.warn("error building row y={} err={}", .{ y, err });
                    self.cells.clear(y);
                };
            }
            cursor: {
                self.cells.setCursor(null, null);
                self.uniforms.cursor_pos = .{
                    std.math.maxInt(u16),
                    std.math.maxInt(u16),
                };
                const cursor_vp = state.cursor.viewport orelse break :cursor;
                const cursor_style: terminal.Style = cursor_style: {
                    const cells = state.row_data.items(.cells);
                    const cell = cells[cursor_vp.y].get(cursor_vp.x);
                    break :cursor_style if (cell.raw.hasStyling())
                        cell.style
                    else
                        .{};
                };
                if (preedit != null) break :cursor;
                const style = cursor_style_ orelse break :cursor;
                const cursor_color = cursor_color: {
                    if (state.colors.cursor) |v| break :cursor_color v;
                    if (self.config.cursor_color) |v| switch (v) {
                        .color => |color| break :cursor_color color.toTerminalRGB(),
                        inline .@"cell-foreground",
                        .@"cell-background",
                        => |_, tag| {
                            const fg_style = cursor_style.fg(.{
                                .default = state.colors.foreground,
                                .palette = &state.colors.palette,
                                .bold = self.config.bold_color,
                            });
                            const bg_style = cursor_style.bg(
                                &state.cursor.cell,
                                &state.colors.palette,
                            ) orelse state.colors.background;
                            break :cursor_color switch (tag) {
                                .color => unreachable,
                                .@"cell-foreground" => if (cursor_style.flags.inverse)
                                    bg_style
                                else
                                    fg_style,
                                .@"cell-background" => if (cursor_style.flags.inverse)
                                    fg_style
                                else
                                    bg_style,
                            };
                        },
                    };
                    break :cursor_color state.colors.foreground;
                };
                self.addCursor(
                    &state.cursor,
                    style,
                    cursor_color,
                );
                if (style == .block) {
                    const wide = state.cursor.cell.wide;
                    self.uniforms.cursor_pos = .{
                        switch (wide) {
                            .narrow, .spacer_head, .wide => cursor_vp.x,
                            .spacer_tail => cursor_vp.x -| 1,
                        },
                        @intCast(cursor_vp.y),
                    };
                    self.uniforms.bools.cursor_wide = switch (wide) {
                        .narrow, .spacer_head => false,
                        .wide, .spacer_tail => true,
                    };
                    const uniform_color = if (self.config.cursor_text) |txt| blk: {
                        if (txt == .color) {
                            break :blk txt.color.toTerminalRGB();
                        }
                        const fg_style = cursor_style.fg(.{
                            .default = state.colors.foreground,
                            .palette = &state.colors.palette,
                            .bold = self.config.bold_color,
                        });
                        const bg_style = cursor_style.bg(
                            &state.cursor.cell,
                            &state.colors.palette,
                        ) orelse state.colors.background;
                        break :blk switch (txt) {
                            .@"cell-foreground" => if (cursor_style.flags.inverse)
                                bg_style
                            else
                                fg_style,
                            .@"cell-background" => if (cursor_style.flags.inverse)
                                fg_style
                            else
                                bg_style,
                            else => unreachable,
                        };
                    } else state.colors.background;
                    self.uniforms.cursor_color = .{
                        uniform_color.r,
                        uniform_color.g,
                        uniform_color.b,
                        255,
                    };
                }
            }
            if (preedit) |preedit_v| preedit: {
                const range = preedit_range orelse break :preedit;
                var x = range.x[0];
                for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                    self.addPreeditCell(
                        cp,
                        .{ .x = x, .y = range.y },
                        state.colors.foreground,
                    ) catch |err| {
                        log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                            x,
                            range.y,
                            err,
                        });
                    };
                    x += if (cp.wide) 2 else 1;
                }
            }
            self.cells_rebuilt = true;
        }
        fn rebuildRow(
            self: *Self,
            y: terminal.size.CellCountInt,
            row: terminal.page.Row,
            cells: *std.MultiArrayList(terminal.RenderState.Cell),
            preedit_range: ?PreeditRange,
            selection: ?[2]terminal.size.CellCountInt,
            highlights: *const std.ArrayList(terminal.RenderState.Highlight),
            links: *const terminal.RenderState.CellSet,
        ) !void {
            const state = &self.terminal_state;
            const cells_slice = cells.slice();
            const cells_len = @min(cells_slice.len, self.cells.size.columns);
            const cells_raw = cells_slice.items(.raw);
            const cells_style = cells_slice.items(.style);
            switch (self.config.padding_color) {
                .background, .@"extend-always" => {},
                .extend => if (y == 0) {
                    self.uniforms.padding_extend.up = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                } else if (y == self.cells.size.rows - 1) {
                    self.uniforms.padding_extend.down = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                },
            }
            var run_iter_opts: font.shape.RunOptions = .{
                .grid = self.font_grid,
                .cells = cells_slice,
                .selection = if (selection) |s| s else null,
                .cursor_x = cursor_x: {
                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y != y) break :cursor_x null;
                    break :cursor_x vp.x;
                },
            };
            run_iter_opts.applyBreakConfig(self.config.font_shaping_break);
            var run_iter = self.font_shaper.runIterator(run_iter_opts);
            var shaper_run: ?font.shape.TextRun = try run_iter.next(self.alloc);
            var shaper_cells: ?[]const font.shape.Cell = null;
            var shaper_cells_i: usize = 0;
            for (
                0..,
                cells_raw[0..cells_len],
                cells_style[0..cells_len],
            ) |x, *cell, *managed_style| {
                if (preedit_range) |range| preedit: {
                    if (range.y != y) break :preedit;
                    if (x < range.x[0]) break :preedit;
                    if (x <= range.x[1]) continue;
                    if (x != range.x[1] + 1) break :preedit;
                    while (shaper_run) |run| {
                        if (run.offset + run.cells > x) break;
                        shaper_run = try run_iter.next(self.alloc);
                        shaper_cells = null;
                        shaper_cells_i = 0;
                    }
                    const run = shaper_run orelse break :preedit;
                    shaper_cells = shaper_cells orelse
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            const new_cells = try self.font_shaper.shape(run);
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };
                            break :cache new_cells;
                        };
                    const shaper_cells_unwrapped = shaper_cells.?;
                    while (run.offset + shaper_cells_unwrapped[shaper_cells_i].x < x) {
                        shaper_cells_i += 1;
                    }
                }
                const wide = cell.wide;
                const style: terminal.Style = if (cell.hasStyling())
                    managed_style.*
                else
                    .{};
                const selected: enum {
                    false,
                    selection,
                    search,
                    search_selected,
                } = selected: {
                    const x_compare = if (wide == .spacer_tail)
                        x -| 1
                    else
                        x;
                    if (selection) |sel| {
                        if (x_compare >= sel[0] and
                            x_compare <= sel[1]) break :selected .selection;
                    }
                    for (highlights.items) |hl| {
                        if (x_compare >= hl.range[0] and
                            x_compare <= hl.range[1])
                        {
                            const tag: HighlightTag = @enumFromInt(hl.tag);
                            break :selected switch (tag) {
                                .search_match => .search,
                                .search_match_selected => .search_selected,
                            };
                        }
                    }
                    break :selected .false;
                };
                const bg_style = style.bg(
                    cell,
                    &state.colors.palette,
                );
                const fg_style = style.fg(.{
                    .default = state.colors.foreground,
                    .palette = &state.colors.palette,
                    .bold = self.config.bold_color,
                });
                const bg = switch (selected) {
                    .selection => if (self.config.selection_background) |v| switch (v) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    } else state.colors.foreground,
                    .search => switch (self.config.search_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },
                    .search_selected => switch (self.config.search_selected_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },
                    .false => if (style.flags.inverse != isCovering(cell.codepoint()))
                        fg_style
                    else
                        bg_style,
                };
                const fg = fg: {
                    const final_bg = bg_style orelse state.colors.background;
                    break :fg switch (selected) {
                        .selection => if (self.config.selection_foreground) |v| switch (v) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        } else state.colors.background,
                        .search => switch (self.config.search_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },
                        .search_selected => switch (self.config.search_selected_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },
                        .false => if (style.flags.inverse)
                            final_bg
                        else
                            fg_style,
                    };
                };
                const alpha: u8 = if (style.flags.faint) self.config.faint_opacity else 255;
                {
                    const rgb = bg orelse state.colors.background;
                    const bg_alpha: u8 = bg_alpha: {
                        const default: u8 = 255;
                        if (selected != .false) break :bg_alpha default;
                        if (style.flags.inverse) break :bg_alpha default;
                        if (self.config.background_opacity_cells and bg_style != null) {
                            var opacity: f64 = @floatFromInt(default);
                            opacity *= self.config.background_opacity;
                            break :bg_alpha @intFromFloat(opacity);
                        }
                        if (bg_style != null) break :bg_alpha default;
                        break :bg_alpha 0;
                    };
                    self.cells.bgCell(y, x).* = .{
                        rgb.r, rgb.g, rgb.b, bg_alpha,
                    };
                }
                if (style.flags.invisible) {
                    continue;
                }
                const underline: terminal.Attribute.Underline = underline: {
                    if (links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    })) {
                        break :underline if (style.flags.underline == .single)
                            .double
                        else
                            .single;
                    }
                    break :underline style.flags.underline;
                };
                if (underline != .none) self.addUnderline(
                    @intCast(x),
                    @intCast(y),
                    underline,
                    style.underlineColor(&state.colors.palette) orelse fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding underline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
                if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                    log.warn(
                        "error adding overline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
                if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                    shaper_run = try run_iter.next(self.alloc);
                    shaper_cells = null;
                    shaper_cells_i = 0;
                }
                if (shaper_run) |run| glyphs: {
                    shaper_cells = shaper_cells orelse
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            const new_cells = try self.font_shaper.shape(run);
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };
                            break :cache new_cells;
                        };
                    const shaped_cells = shaper_cells orelse break :glyphs;
                    if (shaped_cells.len == 0) break :glyphs;
                    assert(run.offset + shaped_cells[shaper_cells_i].x >= x);
                    while (shaper_cells_i < shaped_cells.len and
                        run.offset + shaped_cells[shaper_cells_i].x == x) : ({
                        shaper_cells_i += 1;
                    }) {
                        self.addGlyph(
                            @intCast(x),
                            @intCast(y),
                            state.cols,
                            cells_raw,
                            shaped_cells[shaper_cells_i],
                            shaper_run.?,
                            fg,
                            alpha,
                        ) catch |err| {
                            log.warn(
                                "error adding glyph to cell, will be invalid x={} y={}, err={}",
                                .{ x, y, err },
                            );
                        };
                    }
                }
                if (style.flags.strikethrough) self.addStrikethrough(
                    @intCast(x),
                    @intCast(y),
                    fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
            }
        }
        fn addUnderline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            style: terminal.Attribute.Underline,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const sprite: font.Sprite = switch (style) {
                .none => unreachable,
                .single => .underline,
                .double => .underline_double,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
                .curly => .underline_curly,
            };
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(sprite),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );
            try self.cells.add(self.alloc, .underline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }
        fn addOverline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.overline),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );
            try self.cells.add(self.alloc, .overline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }
        fn addStrikethrough(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.strikethrough),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );
            try self.cells.add(self.alloc, .strikethrough, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }
        fn addGlyph(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            cols: usize,
            cell_raws: []const terminal.page.Cell,
            shaper_cell: font.shape.Cell,
            shaper_run: font.shape.TextRun,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const cell = cell_raws[x];
            const cp = cell.codepoint();
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                shaper_run.font_index,
                shaper_cell.glyph_index,
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                    .cell_width = cell.gridWidth(),
                    .constraint = getConstraint(cp) orelse
                        if (cellpkg.isSymbol(cp)) .{
                            .size = .fit,
                        } else .none,
                    .constraint_width = constraintWidth(
                        cell_raws,
                        x,
                        cols,
                    ),
                },
            );
            if (render.glyph.width == 0 or render.glyph.height == 0) {
                return;
            }
            try self.cells.add(self.alloc, .text, .{
                .atlas = switch (render.presentation) {
                    .emoji => .color,
                    .text => .grayscale,
                },
                .bools = .{ .no_min_contrast = noMinContrast(cp) },
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x + shaper_cell.x_offset),
                    @intCast(render.glyph.offset_y + shaper_cell.y_offset),
                },
            });
        }
        fn addCursor(
            self: *Self,
            cursor_state: *const terminal.RenderState.Cursor,
            cursor_style: renderer.CursorStyle,
            cursor_color: terminal.color.RGB,
        ) void {
            const cursor_vp = cursor_state.viewport orelse return;
            const wide, const x = cell: {
                if (!cursor_vp.wide_tail) break :cell .{
                    cursor_state.cell.wide == .wide,
                    cursor_vp.x,
                };
                break :cell .{ true, cursor_vp.x - 1 };
            };
            const alpha: u8 = if (!self.focused) 255 else alpha: {
                const alpha = 255 * self.config.cursor_opacity;
                break :alpha @intFromFloat(@ceil(alpha));
            };
            const render = switch (cursor_style) {
                .block,
                .block_hollow,
                .bar,
                .underline,
                => render: {
                    const sprite: font.Sprite = switch (cursor_style) {
                        .block => .cursor_rect,
                        .block_hollow => .cursor_hollow_rect,
                        .bar => .cursor_bar,
                        .underline => .cursor_underline,
                        .lock => unreachable,
                    };
                    break :render self.font_grid.renderGlyph(
                        self.alloc,
                        font.sprite_index,
                        @intFromEnum(sprite),
                        .{
                            .cell_width = if (wide) 2 else 1,
                            .grid_metrics = self.grid_metrics,
                        },
                    ) catch |err| {
                        log.warn("error rendering cursor glyph err={}", .{err});
                        return;
                    };
                },
                .lock => self.font_grid.renderCodepoint(
                    self.alloc,
                    0xF023,
                    .regular,
                    .text,
                    .{
                        .cell_width = if (wide) 2 else 1,
                        .grid_metrics = self.grid_metrics,
                    },
                ) catch |err| {
                    log.warn("error rendering cursor glyph err={}", .{err});
                    return;
                } orelse {
                    log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
                    return;
                },
            };
            self.cells.setCursor(.{
                .atlas = .grayscale,
                .bools = .{ .is_cursor_glyph = true },
                .grid_pos = .{ x, cursor_vp.y },
                .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            }, cursor_style);
        }
        fn addPreeditCell(
            self: *Self,
            cp: renderer.State.Preedit.Codepoint,
            coord: terminal.Coordinate,
            screen_fg: terminal.color.RGB,
        ) !void {
            const render_ = self.font_grid.renderCodepoint(
                self.alloc,
                @intCast(cp.codepoint),
                .regular,
                .text,
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                },
            ) catch |err| {
                log.warn("error rendering preedit glyph err={}", .{err});
                return;
            };
            const render = render_ orelse {
                log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
                return;
            };
            try self.cells.add(self.alloc, .text, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
                .color = .{ screen_fg.r, screen_fg.g, screen_fg.b, 255 },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
            try self.addUnderline(@intCast(coord.x), @intCast(coord.y), .single, screen_fg, 255);
            if (cp.wide and coord.x < self.cells.size.columns - 1) {
                try self.addUnderline(@intCast(coord.x + 1), @intCast(coord.y), .single, screen_fg, 255);
            }
        }
        fn syncAtlasTexture(
            self: *const Self,
            atlas: *const font.Atlas,
            texture: *Texture,
        ) !void {
            if (atlas.size > texture.width) {
                texture.*.deinit();
                texture.* = try self.api.initAtlasTexture(atlas);
            }
            try texture.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
        }
    };
}
