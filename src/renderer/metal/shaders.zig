const std = @import("std");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const objc = @import("objc");
const math = @import("../../math.zig");
const global = @import("../../global.zig");
const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const log = std.log.scoped(.metal);
const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = "cell_text_vertex",
            .fragment_fn = "cell_text_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = "image_vertex",
            .fragment_fn = "image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = "bg_image_vertex",
            .fragment_fn = "bg_image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: []const u8,
    fragment_fn: []const u8,
    step_fn: mtl.MTLVertexStepFunction = .per_vertex,
    blending_enabled: bool,
    fn initPipeline(
        self: PipelineDescription,
        device: objc.Object,
        library: objc.Object,
        pixel_format: mtl.MTLPixelFormat,
    ) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .device = device,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .vertex_library = library,
            .fragment_library = library,
            .step_fn = self.step_fn,
            .attachments = &.{.{
                .pixel_format = pixel_format,
                .blending_enabled = self.blending_enabled,
            }},
        });
    }
};
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;
    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;
    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};
pub const Shaders = struct {
    library: objc.Object,
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,
    pub const uninit: Shaders = .{
        .library = undefined,
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };
    pub fn init(
        alloc: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});
        var pipelines: PipelineCollection = undefined;
        var initialized_pipelines: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };
        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(
                device,
                library,
                pixel_format,
            );
            initialized_pipelines += 1;
        }
        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            device,
            library,
            post_shaders,
            pixel_format,
        ) catch |err| err: {
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };
        return .{
            .library = library,
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }
    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
        self.library.msgSend(void, objc.sel("release"), .{});
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};
pub const Uniforms = extern struct {
    projection_matrix: math.Mat align(16),
    screen_size: [2]f32 align(8),
    cell_size: [2]f32 align(8),
    grid_size: [2]u16 align(4),
    grid_padding: [4]f32 align(16),
    padding_extend: PaddingExtend align(1),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),
    bools: extern struct {
        cursor_wide: bool align(1),
        use_display_p3: bool align(1),
        use_linear_blending: bool align(1),
        use_linear_correction: bool align(1) = false,
    },
    const PaddingExtend = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u4 = 0,
    };
};
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},
    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
    test {
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};
pub const CellBg = [4]u8;
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),
    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,
        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };
        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
fn initLibrary(device: objc.Object) !objc.Object {
    const start: std.Io.Timestamp = .now(global.io(), .awake);
    const data = try macos.dispatch.Data.create(
        @embedFile("wasp_metallib"),
        macos.dispatch.queue.getMain(),
        macos.dispatch.Data.DESTRUCTOR_DEFAULT,
    );
    defer data.release();
    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithData:error:"),
        .{
            data,
            &err,
        },
    );
    try checkError(err);
    log.debug("shader library loaded time={}us", .{start.untilNow(global.io(), .awake).toMicroseconds()});
    return library;
}
fn initPostPipelines(
    alloc: Allocator,
    device: objc.Object,
    library: objc.Object,
    shaders: []const [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) ![]const Pipeline {
    if (shaders.len == 0) return &.{};
    var i: usize = 0;
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(
            device,
            library,
            source,
            pixel_format,
        );
        i += 1;
    }
    return pipelines;
}
fn initPostPipeline(
    device: objc.Object,
    library: objc.Object,
    data: [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) !Pipeline {
    const post_library = library: {
        const source = try macos.foundation.String.createWithBytes(
            data,
            .utf8,
            false,
        );
        defer source.release();
        var err: ?*anyopaque = null;
        const post_library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithSource:options:error:"),
            .{ source, @as(?*anyopaque, null), &err },
        );
        try checkError(err);
        errdefer post_library.msgSend(void, objc.sel("release"), .{});
        break :library post_library;
    };
    defer post_library.msgSend(void, objc.sel("release"), .{});
    return try Pipeline.init(null, .{
        .device = device,
        .vertex_fn = "full_screen_vertex",
        .fragment_fn = "main0",
        .vertex_library = library,
        .fragment_library = post_library,
        .attachments = &.{
            .{
                .pixel_format = pixel_format,
                .blending_enabled = false,
            },
        },
    });
}
fn checkError(err_: ?*anyopaque) !void {
    const nserr = objc.Object.fromId(err_ orelse return);
    const str = @as(
        *macos.foundation.String,
        @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
    );
    log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
    return error.MetalFailed;
}
