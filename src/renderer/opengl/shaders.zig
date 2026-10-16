const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const math = @import("../../math.zig");
const Pipeline = @import("Pipeline.zig");
const log = std.log.scoped(.opengl);
const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/bg_color.f.glsl"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/cell_bg.f.glsl"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = loadShaderCode("../shaders/glsl/cell_text.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/cell_text.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = loadShaderCode("../shaders/glsl/image.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/image.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = loadShaderCode("../shaders/glsl/bg_image.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/bg_image.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,
    fn initPipeline(self: PipelineDescription) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
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
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,
    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };
    pub fn init(
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;
        var initialized_pipelines: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };
        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline();
            initialized_pipelines += 1;
        }
        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            post_shaders,
        ) catch |err| err: {
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };
        return .{
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
    padding_extend: PaddingExtend align(4),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),
    bools: Bools align(4),
    const Bools = packed struct(u32) {
        cursor_wide: bool,
        use_display_p3: bool,
        use_linear_blending: bool,
        use_linear_correction: bool = false,
        _padding: u28 = 0,
    };
    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
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
};
pub const CellBg = [4]u8;
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
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
fn initPostPipelines(
    alloc: Allocator,
    shaders: []const [:0]const u8,
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
        pipelines[i] = try initPostPipeline(source);
        i += 1;
    }
    return pipelines;
}
fn initPostPipeline(data: [:0]const u8) !Pipeline {
    return try Pipeline.init(null, .{
        .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
        .fragment_fn = data,
    });
}
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
}
fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint(
                "{s}{s}{s}",
                .{
                    contents[0..i],
                    @embedFile(basedir ++ "/" ++ contents[start..end]),
                    processIncludes(contents[end + 1 ..], basedir),
                },
            );
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}
