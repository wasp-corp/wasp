const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const Action = @import("wasp.zig").Action;
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const vaxis = @import("vaxis");
const framedata = @import("framedata").compressed;
const vxfw = vaxis.vxfw;
pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};
const Boo = struct {
    frame: u8,
    framerate: u32,
    buffer: [frame_width * frame_height]vaxis.Cell = undefined,
    wasp_style: vaxis.Style,
    outline_style: vaxis.Style,
    const frame_width = 100;
    const frame_height = 41;
    fn widget(self: *Boo) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Boo.typeErasedEventHandler,
            .drawFn = Boo.typeErasedDrawFn,
        };
    }
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Boo = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init,
            .tick,
            => {
                self.updateFrame();
                ctx.redraw = true;
                return ctx.tick(self.framerate, self.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.escape, .{}))
                {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Boo = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        if (max.width < frame_width or max.height < frame_height) {
            const text: vxfw.Text = .{ .text = "Screen must be at least 100w x 41h" };
            const center: vxfw.Center = .{ .child = text.widget() };
            return center.draw(ctx);
        }
        const offset_y = (max.height - frame_height) / 2;
        const offset_x = (max.width - frame_width) / 2;
        const child: vxfw.Surface = .{
            .size = .{ .width = @intCast(frame_width), .height = @intCast(frame_height) },
            .widget = self.widget(),
            .buffer = &self.buffer,
            .children = &.{},
        };
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = @intCast(offset_y), .col = @intCast(offset_x) },
            .surface = child,
        };
        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
    fn updateFrame(self: *Boo) void {
        const frame = frames[self.frame];
        const State = enum {
            normal,
            span,
            in_tag,
            in_closing_tag,
        };
        var cell_idx: usize = 0;
        var line_iter = std.mem.splitScalar(u8, frame, '\n');
        while (line_iter.next()) |line| {
            var state: State = .normal;
            var style = self.wasp_style;
            var cp_iter: std.unicode.Utf8Iterator = .{ .bytes = line, .i = 0 };
            while (cp_iter.nextCodepointSlice()) |char| {
                switch (state) {
                    .normal => if (std.mem.eql(u8, "<", char)) {
                        state = .in_tag;
                        style = self.outline_style;
                        continue;
                    },
                    .span => if (std.mem.eql(u8, "<", char)) {
                        state = .in_tag;
                        style = self.wasp_style;
                        continue;
                    },
                    .in_tag => {
                        if (std.mem.eql(u8, "/", char))
                            state = .in_closing_tag
                        else if (std.mem.eql(u8, ">", char))
                            state = .span;
                        continue;
                    },
                    .in_closing_tag => {
                        if (std.mem.eql(u8, ">", char)) state = .normal;
                        continue;
                    },
                }
                self.buffer[cell_idx] = .{
                    .char = .{
                        .grapheme = char,
                        .width = 1,
                    },
                    .style = style,
                };
                cell_idx += 1;
            }
        }
        std.debug.assert(cell_idx == self.buffer.len);
        self.frame += 1;
        if (self.frame == frames.len) self.frame = 0;
    }
};
pub fn run(gpa: Allocator) !u8 {
    var env_map = try global.environMap();
    defer env_map.deinit();
    switch (builtin.os.tag) {
        .windows, .macos, .linux, .freebsd => {},
        else => return 1,
    }
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(gpa, global.args());
        defer iter.deinit();
        try args.parse(Options, gpa, &opts, &iter);
    }
    try decompressFrames(gpa);
    defer {
        gpa.free(frames);
        gpa.free(decompressed_data);
    }
    var app = try vxfw.App.init(global.io(), gpa, &env_map, &.{});
    defer app.deinit();
    var boo: Boo = undefined;
    boo.frame = 0;
    boo.framerate = 1000 / 30;
    boo.wasp_style = .{};
    boo.outline_style = .{ .fg = .{ .index = 4 } };
    @memset(&boo.buffer, .{});
    try app.run(boo.widget(), .{});
    return 0;
}
var decompressed_data: []const u8 = undefined;
var frames: []const []const u8 = undefined;
fn decompressFrames(gpa: Allocator) !void {
    var src: std.Io.Reader = .fixed(framedata);
    var decompress: std.compress.flate.Decompress = .init(&src, .raw, &.{});
    var out: std.Io.Writer.Allocating = .init(gpa);
    _ = try decompress.reader.streamRemaining(&out.writer);
    decompressed_data = try out.toOwnedSlice();
    var frame_list: std.ArrayList([]const u8) = try .initCapacity(gpa, 235);
    var frame_iter = std.mem.splitScalar(u8, decompressed_data, '\x01');
    while (frame_iter.next()) |frame| {
        try frame_list.append(gpa, frame);
    }
    frames = try frame_list.toOwnedSlice(gpa);
}
