const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const simd = @import("../../simd/root.zig");
const lib = @import("../lib.zig");
const log = std.log.scoped(.kitty_gfx);
const KV = struct {
    values: [52]u32 = undefined,
    present: u64 = 0,
    fn index(key: u8) ?u6 {
        return switch (key) {
            'a'...'z' => @intCast(key - 'a'),
            'A'...'Z' => @intCast(26 + key - 'A'),
            else => null,
        };
    }
    fn get(self: *const KV, key: u8) ?u32 {
        const idx = index(key) orelse return null;
        if (self.present & (@as(u64, 1) << idx) == 0) return null;
        return self.values[idx];
    }
    fn put(self: *KV, key: u8, value: u32) void {
        const idx = index(key) orelse return;
        self.values[idx] = value;
        self.present |= @as(u64, 1) << idx;
    }
};
pub const Parser = struct {
    alloc: Allocator,
    kv: KV,
    kv_temp: [11]u8,
    kv_temp_len: u4,
    kv_current: u8,
    data: std.ArrayList(u8),
    max_bytes: usize,
    state: State,
    const State = enum {
        control_key,
        control_key_ignore,
        control_value,
        control_value_ignore,
        data,
    };
    pub fn init(alloc: Allocator, max_bytes: usize) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .data = .empty,
            .kv = .{},
            .kv_temp_len = 0,
            .kv_current = 0,
            .max_bytes = max_bytes,
            .state = .control_key,
            .kv_temp = undefined,
        };
        if (std.valgrind.runningOnValgrind() > 0) {
            result.kv_temp = undefined;
        }
        return result;
    }
    pub fn deinit(self: *Parser) void {
        self.data.deinit(self.alloc);
    }
    pub fn parseString(alloc: Allocator, data: []const u8) !Command {
        var parser = init(alloc, 1024 * 1024);
        defer parser.deinit();
        for (data) |c| try parser.feed(c);
        return try parser.complete(alloc);
    }
    pub fn feed(self: *Parser, c: u8) !void {
        switch (self.state) {
            .control_key => switch (c) {
                '=' => if (self.kv_temp_len != 1) {
                    self.state = .control_value_ignore;
                    self.kv_temp_len = 0;
                } else {
                    self.kv_current = self.kv_temp[0];
                    self.kv_temp_len = 0;
                    self.state = .control_value;
                },
                ';' => self.state = .data,
                else => try self.accumulateValue(c, .control_key_ignore),
            },
            .control_key_ignore => switch (c) {
                '=' => self.state = .control_value_ignore,
                else => {},
            },
            .control_value => switch (c) {
                ',' => try self.finishValue(.control_key),
                ';' => try self.finishValue(.data),
                else => try self.accumulateValue(c, .control_value_ignore),
            },
            .control_value_ignore => switch (c) {
                ',' => self.state = .control_key_ignore,
                ';' => self.state = .data,
                else => {},
            },
            .data => {
                if (self.data.items.len >= self.max_bytes) return error.OutOfMemory;
                try self.data.append(self.alloc, c);
            },
        }
    }
    pub fn feedSlice(self: *Parser, bytes: []const u8) !void {
        var rem = bytes;
        while (rem.len > 0) {
            if (self.state == .data) {
                if (self.data.items.len + rem.len > self.max_bytes) {
                    return error.OutOfMemory;
                }
                try self.data.appendSlice(self.alloc, rem);
                return;
            }
            try self.feed(rem[0]);
            rem = rem[1..];
        }
    }
    pub fn complete(self: *Parser, alloc: Allocator) !Command {
        switch (self.state) {
            .control_key, .control_key_ignore => return error.InvalidFormat,
            .control_value => try self.finishValue(.data),
            .control_value_ignore => {},
            .data => {},
        }
        const action: u8 = action: {
            const value = self.kv.get('a') orelse break :action 't';
            const c = std.math.cast(u8, value) orelse return error.InvalidFormat;
            break :action c;
        };
        const control: Command.Control = switch (action) {
            'q' => .{ .query = try .parse(self.kv) },
            't' => .{ .transmit = try .parse(self.kv) },
            'T' => .{ .transmit_and_display = .{
                .transmission = try .parse(self.kv),
                .display = try .parse(self.kv),
            } },
            'p' => .{ .display = try .parse(self.kv) },
            'd' => .{ .delete = try .parse(self.kv) },
            'f' => .{ .transmit_animation_frame = try .parse(self.kv) },
            'a' => .{ .control_animation = .parse(self.kv) },
            'c' => .{ .compose_animation = .parse(self.kv) },
            else => return error.InvalidFormat,
        };
        const quiet: Command.Quiet = if (self.kv.get('q')) |v| quiet: {
            break :quiet switch (v) {
                0 => .no,
                1 => .ok,
                else => .failures,
            };
        } else .no;
        return .{
            .control = control,
            .quiet = quiet,
            .data = try self.decodeData(alloc),
        };
    }
    fn decodeData(self: *Parser, alloc: Allocator) ![]const u8 {
        if (self.data.items.len == 0) {
            return "";
        }
        const max_len = simd.base64.maxLen(self.data.items);
        assert(max_len <= self.data.items.len);
        const decoded = simd.base64.decode(
            self.data.items,
            self.data.items[0..max_len],
        ) catch |err| {
            log.warn("failed to decode base64 payload data: {}", .{err});
            return error.InvalidData;
        };
        assert(decoded.len <= max_len);
        self.data.items.len = decoded.len;
        return try self.data.toOwnedSlice(alloc);
    }
    fn accumulateValue(self: *Parser, c: u8, overflow_state: State) !void {
        const idx = self.kv_temp_len;
        self.kv_temp_len += 1;
        if (self.kv_temp_len > self.kv_temp.len) {
            self.state = overflow_state;
            self.kv_temp_len = 0;
            return;
        }
        self.kv_temp[idx] = c;
    }
    fn finishValue(self: *Parser, next_state: State) !void {
        self.state = next_state;
        if (self.kv_temp_len == 1) {
            const c = self.kv_temp[0];
            if (c < '0' or c > '9') {
                self.kv.put(self.kv_current, @intCast(c));
                self.kv_temp_len = 0;
                return;
            }
        }
        const v: u32 = switch (self.kv_current) {
            'z', 'H', 'V' => @bitCast(try std.fmt.parseInt(i32, self.kv_temp[0..self.kv_temp_len], 10)),
            else => try std.fmt.parseInt(u32, self.kv_temp[0..self.kv_temp_len], 10),
        };
        self.kv.put(self.kv_current, v);
        self.kv_temp_len = 0;
    }
};
pub const Response = struct {
    id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    frame: u32 = 0,
    message: []const u8 = "OK",
    pub fn encode(self: Response, writer: *std.Io.Writer) !void {
        if (self.id == 0 and self.image_number == 0) return;
        var prior: bool = false;
        try writer.writeAll("\x1b_G");
        if (self.id > 0) {
            prior = true;
            try writer.print("i={}", .{self.id});
        }
        if (self.image_number > 0) {
            if (prior) try writer.writeByte(',') else prior = true;
            try writer.print("I={}", .{self.image_number});
        }
        if (self.placement_id > 0) {
            if (prior) try writer.writeByte(',') else prior = true;
            try writer.print("p={}", .{self.placement_id});
        }
        if (self.frame > 0) {
            if (prior) try writer.writeByte(',') else prior = true;
            try writer.print("r={}", .{self.frame});
        }
        try writer.writeByte(';');
        try writer.writeAll(self.message);
        try writer.writeAll("\x1b\\");
    }
    pub fn ok(self: Response) bool {
        return std.mem.eql(u8, self.message, "OK");
    }
    pub fn empty(self: Response) bool {
        return self.id == 0 and self.image_number == 0;
    }
};
pub const Command = struct {
    control: Control,
    quiet: Quiet = .no,
    data: []const u8 = "",
    pub const Action = enum {
        query,
        transmit,
        transmit_and_display,
        display,
        delete,
        transmit_animation_frame,
        control_animation,
        compose_animation,
    };
    pub const Quiet = enum {
        no,
        ok,
        failures,
    };
    pub const Control = union(Action) {
        query: Transmission,
        transmit: Transmission,
        transmit_and_display: struct {
            transmission: Transmission,
            display: Display,
        },
        display: Display,
        delete: Delete,
        transmit_animation_frame: AnimationFrameLoading,
        control_animation: AnimationControl,
        compose_animation: AnimationFrameComposition,
        pub const Identifiers = struct {
            image_id: u32 = 0,
            image_number: u32 = 0,
            placement_id: u32 = 0,
        };
        pub fn identifiers(self: Control) Identifiers {
            return switch (self) {
                .query, .transmit => |t| .{
                    .image_id = t.image_id,
                    .image_number = t.image_number,
                    .placement_id = t.placement_id,
                },
                .transmit_and_display => |t| .{
                    .image_id = t.transmission.image_id,
                    .image_number = t.transmission.image_number,
                    .placement_id = t.transmission.placement_id,
                },
                .display => |d| .{
                    .image_id = d.image_id,
                    .image_number = d.image_number,
                    .placement_id = d.placement_id,
                },
                .delete => |d| .{
                    .image_id = d.image_id,
                    .image_number = d.image_number,
                    .placement_id = d.placement_id,
                },
                .transmit_animation_frame => |f| .{
                    .image_id = f.transmission.image_id,
                    .image_number = f.transmission.image_number,
                    .placement_id = f.transmission.placement_id,
                },
                .control_animation => |a| .{
                    .image_id = a.image_id,
                    .image_number = a.image_number,
                    .placement_id = a.placement_id,
                },
                .compose_animation => |c| .{
                    .image_id = c.image_id,
                    .image_number = c.image_number,
                    .placement_id = c.placement_id,
                },
            };
        }
    };
    pub fn toOwnedData(self: *Command) []const u8 {
        const result = self.data;
        self.data = "";
        return result;
    }
    pub fn transmission(self: Command) ?Transmission {
        return switch (self.control) {
            .query => |t| t,
            .transmit => |t| t,
            .transmit_and_display => |t| t.transmission,
            .transmit_animation_frame => |f| f.transmission,
            else => null,
        };
    }
    pub fn display(self: Command) ?Display {
        return switch (self.control) {
            .display => |d| d,
            .transmit_and_display => |t| t.display,
            else => null,
        };
    }
    pub fn deinit(self: Command, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }
};
pub const Transmission = struct {
    format: Format = .rgba,
    format_unknown: bool = false,
    medium: Medium = .direct,
    width: u32 = 0,
    height: u32 = 0,
    size: u32 = 0,
    offset: u32 = 0,
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    compression: Compression = .none,
    more_chunks: bool = false,
    usage: Usage = .default,
    pub const Format = lib.Enum(lib.target, &.{
        "rgb",
        "rgba",
        "png",
        "gray_alpha",
        "gray",
    });
    pub const Medium = lib.Enum(lib.target, &.{
        "direct",
        "file",
        "temporary_file",
        "shared_memory",
    });
    pub const Compression = lib.Enum(lib.target, &.{
        "none",
        "zlib_deflate",
    });
    pub const Usage = packed struct(u32) {
        transient: bool = false,
        _padding: u31 = 0,
        pub const default: Usage = .{};
    };
    pub fn formatBpp(format: Format) u8 {
        return switch (format) {
            .gray => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
            .png => unreachable,
        };
    }
    fn parse(kv: KV) !Transmission {
        var result: Transmission = .{};
        if (kv.get('f')) |v| {
            result.format = switch (v) {
                24 => .rgb,
                0, 32 => .rgba,
                100 => .png,
                else => unknown: {
                    result.format_unknown = true;
                    break :unknown .rgba;
                },
            };
        }
        if (kv.get('t')) |v| {
            const c = std.math.cast(u8, v) orelse return error.InvalidFormat;
            result.medium = switch (c) {
                'd' => .direct,
                'f' => .file,
                't' => .temporary_file,
                's' => .shared_memory,
                else => return error.InvalidFormat,
            };
        }
        if (kv.get('s')) |v| {
            result.width = v;
        }
        if (kv.get('v')) |v| {
            result.height = v;
        }
        if (kv.get('S')) |v| {
            result.size = v;
        }
        if (kv.get('O')) |v| {
            result.offset = v;
        }
        if (kv.get('i')) |v| {
            result.image_id = v;
        }
        if (kv.get('I')) |v| {
            result.image_number = v;
        }
        if (kv.get('p')) |v| {
            result.placement_id = v;
        }
        if (kv.get('o')) |v| {
            const c = std.math.cast(u8, v) orelse return error.InvalidFormat;
            result.compression = switch (c) {
                'z' => .zlib_deflate,
                else => return error.InvalidFormat,
            };
        }
        if (result.medium == .direct) {
            if (kv.get('m')) |v| {
                result.more_chunks = v > 0;
            }
        }
        if (kv.get('N')) |v| {
            result.usage = @bitCast(v);
        }
        return result;
    }
};
pub const Display = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    x_offset: u32 = 0,
    y_offset: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    cursor_movement: CursorMovement = .after,
    virtual_placement: bool = false,
    parent_id: u32 = 0,
    parent_placement_id: u32 = 0,
    horizontal_offset: i32 = 0,
    vertical_offset: i32 = 0,
    z: i32 = 0,
    pub const CursorMovement = enum {
        after,
        none,
    };
    fn parse(kv: KV) !Display {
        var result: Display = .{};
        if (kv.get('i')) |v| {
            result.image_id = v;
        }
        if (kv.get('I')) |v| {
            result.image_number = v;
        }
        if (kv.get('p')) |v| {
            result.placement_id = v;
        }
        if (kv.get('x')) |v| {
            result.x = v;
        }
        if (kv.get('y')) |v| {
            result.y = v;
        }
        if (kv.get('w')) |v| {
            result.width = v;
        }
        if (kv.get('h')) |v| {
            result.height = v;
        }
        if (kv.get('X')) |v| {
            result.x_offset = v;
        }
        if (kv.get('Y')) |v| {
            result.y_offset = v;
        }
        if (kv.get('c')) |v| {
            result.columns = v;
        }
        if (kv.get('r')) |v| {
            result.rows = v;
        }
        if (kv.get('C')) |v| {
            result.cursor_movement = if (v == 1) .none else .after;
        }
        if (kv.get('U')) |v| {
            result.virtual_placement = v != 0;
        }
        if (kv.get('z')) |v| {
            result.z = @bitCast(v);
        }
        if (kv.get('P')) |v| {
            result.parent_id = v;
        }
        if (kv.get('Q')) |v| {
            result.parent_placement_id = v;
        }
        if (kv.get('H')) |v| {
            result.horizontal_offset = @bitCast(v);
        }
        if (kv.get('V')) |v| {
            result.vertical_offset = @bitCast(v);
        }
        return result;
    }
};
pub const AnimationFrameLoading = struct {
    transmission: Transmission = .{},
    x: u32 = 0,
    y: u32 = 0,
    create_frame: u32 = 0,
    edit_frame: u32 = 0,
    gap_ms: i32 = 0,
    composition_mode: CompositionMode = .alpha_blend,
    background: Background = .{},
    pub const Background = packed struct(u32) {
        a: u8 = 0,
        b: u8 = 0,
        g: u8 = 0,
        r: u8 = 0,
    };
    fn parse(kv: KV) error{InvalidFormat}!AnimationFrameLoading {
        var result: AnimationFrameLoading = .{
            .transmission = try .parse(kv),
        };
        if (kv.get('x')) |v| {
            result.x = v;
        }
        if (kv.get('y')) |v| {
            result.y = v;
        }
        if (kv.get('c')) |v| {
            result.create_frame = v;
        }
        if (kv.get('r')) |v| {
            result.edit_frame = v;
        }
        if (kv.get('z')) |v| {
            result.gap_ms = @bitCast(v);
        }
        if (kv.get('X')) |v| {
            result.composition_mode = if (v == 1) .overwrite else .alpha_blend;
        }
        if (kv.get('Y')) |v| {
            result.background = @bitCast(v);
        }
        return result;
    }
};
pub const AnimationFrameComposition = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    dest_frame: u32 = 0,
    source_frame: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    left_edge: u32 = 0,
    top_edge: u32 = 0,
    composition_mode: CompositionMode = .alpha_blend,
    fn parse(kv: KV) AnimationFrameComposition {
        var result: AnimationFrameComposition = .{};
        if (kv.get('i')) |v| {
            result.image_id = v;
        }
        if (kv.get('I')) |v| {
            result.image_number = v;
        }
        if (kv.get('p')) |v| {
            result.placement_id = v;
        }
        if (kv.get('c')) |v| {
            result.dest_frame = v;
        }
        if (kv.get('r')) |v| {
            result.source_frame = v;
        }
        if (kv.get('x')) |v| {
            result.x = v;
        }
        if (kv.get('y')) |v| {
            result.y = v;
        }
        if (kv.get('w')) |v| {
            result.width = v;
        }
        if (kv.get('h')) |v| {
            result.height = v;
        }
        if (kv.get('X')) |v| {
            result.left_edge = v;
        }
        if (kv.get('Y')) |v| {
            result.top_edge = v;
        }
        if (kv.get('C')) |v| {
            result.composition_mode = if (v == 0) .alpha_blend else .overwrite;
        }
        return result;
    }
};
pub const AnimationControl = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    action: AnimationAction = .invalid,
    frame: u32 = 0,
    gap_ms: i32 = 0,
    current_frame: u32 = 0,
    loops: u32 = 0,
    pub const AnimationAction = enum {
        invalid,
        stop,
        run_wait,
        run,
    };
    fn parse(kv: KV) AnimationControl {
        var result: AnimationControl = .{};
        if (kv.get('i')) |v| {
            result.image_id = v;
        }
        if (kv.get('I')) |v| {
            result.image_number = v;
        }
        if (kv.get('p')) |v| {
            result.placement_id = v;
        }
        if (kv.get('s')) |v| {
            result.action = switch (v) {
                1 => .stop,
                2 => .run_wait,
                3 => .run,
                else => .invalid,
            };
        }
        if (kv.get('r')) |v| {
            result.frame = v;
        }
        if (kv.get('z')) |v| {
            result.gap_ms = @bitCast(v);
        }
        if (kv.get('c')) |v| {
            result.current_frame = v;
        }
        if (kv.get('v')) |v| {
            result.loops = v;
        }
        return result;
    }
};
pub const Delete = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    action: Action,
    fn parse(kv: KV) !Delete {
        return .{
            .image_id = kv.get('i') orelse 0,
            .image_number = kv.get('I') orelse 0,
            .placement_id = kv.get('p') orelse 0,
            .action = try .parse(kv),
        };
    }
    pub const Action = union(enum) {
        all: bool,
        id: struct {
            delete: bool = false,
            image_id: u32 = 0,
            placement_id: u32 = 0,
        },
        newest: struct {
            delete: bool = false,
            image_number: u32 = 0,
            placement_id: u32 = 0,
        },
        intersect_cursor: bool,
        animation_frames: AnimationFrames,
        intersect_cell: struct {
            delete: bool = false,
            x: u32 = 0,
            y: u32 = 0,
        },
        intersect_cell_z: struct {
            delete: bool = false,
            x: u32 = 0,
            y: u32 = 0,
            z: i32 = 0,
        },
        range: struct {
            delete: bool = false,
            first: u32 = 0,
            last: u32 = 0,
        },
        column: struct {
            delete: bool = false,
            x: u32 = 0,
        },
        row: struct {
            delete: bool = false,
            y: u32 = 0,
        },
        z: struct {
            delete: bool = false,
            z: i32 = 0,
        },
        pub const AnimationFrames = struct {
            delete: bool = false,
            image_id: u32 = 0,
            image_number: u32 = 0,
            frame: u32 = 0,
        };
        fn parse(kv: KV) error{InvalidFormat}!Action {
            const what: u8 = what: {
                const value = kv.get('d') orelse break :what 'a';
                const c = std.math.cast(u8, value) orelse return error.InvalidFormat;
                break :what c;
            };
            return switch (what) {
                'a', 'A' => .{ .all = what == 'A' },
                'i', 'I' => blk: {
                    var result: Action = .{ .id = .{ .delete = what == 'I' } };
                    if (kv.get('i')) |v| {
                        result.id.image_id = v;
                    }
                    if (kv.get('p')) |v| {
                        result.id.placement_id = v;
                    }
                    break :blk result;
                },
                'n', 'N' => blk: {
                    var result: Action = .{ .newest = .{ .delete = what == 'N' } };
                    if (kv.get('I')) |v| {
                        result.newest.image_number = v;
                    }
                    if (kv.get('p')) |v| {
                        result.newest.placement_id = v;
                    }
                    break :blk result;
                },
                'c', 'C' => .{ .intersect_cursor = what == 'C' },
                'f', 'F' => blk: {
                    var result: Action = .{ .animation_frames = .{ .delete = what == 'F' } };
                    if (kv.get('i')) |v| {
                        result.animation_frames.image_id = v;
                    }
                    if (kv.get('I')) |v| {
                        result.animation_frames.image_number = v;
                    }
                    if (kv.get('r')) |v| {
                        result.animation_frames.frame = v;
                    }
                    break :blk result;
                },
                'p', 'P' => blk: {
                    var result: Action = .{ .intersect_cell = .{ .delete = what == 'P' } };
                    if (kv.get('x')) |v| {
                        result.intersect_cell.x = v;
                    }
                    if (kv.get('y')) |v| {
                        result.intersect_cell.y = v;
                    }
                    break :blk result;
                },
                'q', 'Q' => blk: {
                    var result: Action = .{ .intersect_cell_z = .{ .delete = what == 'Q' } };
                    if (kv.get('x')) |v| {
                        result.intersect_cell_z.x = v;
                    }
                    if (kv.get('y')) |v| {
                        result.intersect_cell_z.y = v;
                    }
                    if (kv.get('z')) |v| {
                        result.intersect_cell_z.z = @bitCast(v);
                    }
                    break :blk result;
                },
                'r', 'R' => blk: {
                    var result: Action = .{ .range = .{ .delete = what == 'R' } };
                    if (kv.get('x')) |v| {
                        result.range.first = v;
                    }
                    if (kv.get('y')) |v| {
                        result.range.last = v;
                    }
                    break :blk result;
                },
                'x', 'X' => blk: {
                    var result: Action = .{ .column = .{ .delete = what == 'X' } };
                    if (kv.get('x')) |v| {
                        result.column.x = v;
                    }
                    break :blk result;
                },
                'y', 'Y' => blk: {
                    var result: Action = .{ .row = .{ .delete = what == 'Y' } };
                    if (kv.get('y')) |v| {
                        result.row.y = v;
                    }
                    break :blk result;
                },
                'z', 'Z' => blk: {
                    var result: Action = .{ .z = .{ .delete = what == 'Z' } };
                    if (kv.get('z')) |v| {
                        result.z.z = @bitCast(v);
                    }
                    break :blk result;
                },
                else => return error.InvalidFormat,
            };
        }
    };
};
pub const CompositionMode = enum {
    alpha_blend,
    overwrite,
};
test "transmission command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "f=24,s=10,v=20";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
    try testing.expectEqual(false, v.usage.transient);
}
test "transmission command with transient hint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "f=24,s=10,v=20,N=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
    try testing.expectEqual(true, v.usage.transient);
}
test "feedSlice matches per-byte feed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "f=24,s=10,v=20;aGVsbG8gd29ybGQ=";
    var p1 = Parser.init(alloc, 1024 * 1024);
    defer p1.deinit();
    for (input) |c| try p1.feed(c);
    const c1 = try p1.complete(alloc);
    defer c1.deinit(alloc);
    var p2 = Parser.init(alloc, 1024 * 1024);
    defer p2.deinit();
    try p2.feedSlice(input);
    const c2 = try p2.complete(alloc);
    defer c2.deinit(alloc);
    try testing.expect(c1.control == .transmit);
    try testing.expect(c2.control == .transmit);
    try testing.expectEqualStrings(c1.data, c2.data);
}
test "feedSlice across slice boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    try p.feedSlice("f=24,s=10");
    try p.feedSlice(",v=20;aGVsbG8g");
    try p.feedSlice("d29ybGQ=");
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    try testing.expectEqualStrings("hello world", command.data);
}
test "feedSlice respects max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 4);
    defer p.deinit();
    try p.feedSlice("f=24;ab");
    try testing.expectError(error.OutOfMemory, p.feedSlice("cde"));
}
test "transmission ignores 'm' if medium is not direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=t,t=t,m=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Medium.temporary_file, v.medium);
    try testing.expect(!v.more_chunks);
}
test "transmission respects 'm' if medium is direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=t,t=d,m=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Medium.direct, v.medium);
    try testing.expect(v.more_chunks);
}
test "query command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "i=31,s=1,v=1,a=q,t=d,f=24;QUFBQQ";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .query);
    const v = command.control.query;
    try testing.expectEqual(Transmission.Medium.direct, v.medium);
    try testing.expectEqual(@as(u32, 1), v.width);
    try testing.expectEqual(@as(u32, 1), v.height);
    try testing.expectEqual(@as(u32, 31), v.image_id);
    try testing.expectEqualStrings("AAAA", command.data);
}
test "display command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=p,U=1,i=31,c=80,r=120";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .display);
    const v = command.control.display;
    try testing.expectEqual(@as(u32, 80), v.columns);
    try testing.expectEqual(@as(u32, 120), v.rows);
    try testing.expectEqual(@as(u32, 31), v.image_id);
}
test "delete command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=p,x=3,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .intersect_cell);
    const dv = v.intersect_cell;
    try testing.expect(!dv.delete);
    try testing.expectEqual(@as(u32, 3), dv.x);
    try testing.expectEqual(@as(u32, 4), dv.y);
}
test "no control data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = ";QUFBQQ";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    try testing.expectEqualStrings("AAAA", command.data);
}
test "ignore unknown keys (long)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "f=24,s=10,v=20,hello=world";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
}
test "ignore unknown keys (non-letter)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "f=24,s=10,v=20,!=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
}
test "ignore very long values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "f=24,s=10,v=2000000000000000000000000000000000000000";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 0), v.height);
}
test "ensure very large negative values don't get skipped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=p,i=1,z=-2000000000";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .display);
    const v = command.control.display;
    try testing.expectEqual(1, v.image_id);
    try testing.expectEqual(-2000000000, v.z);
}
test "ensure proper overflow error for u32" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=p,i=10000000000";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.Overflow, p.complete(alloc));
}
test "ensure proper overflow error for i32" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=p,i=1,z=-9999999999";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.Overflow, p.complete(alloc));
}
test "all i32 values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var p = Parser.init(alloc, 1024 * 1024);
        defer p.deinit();
        const input = "a=p,i=1,z=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete(alloc);
        defer command.deinit(alloc);
        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.z);
    }
    {
        var p = Parser.init(alloc, 1024 * 1024);
        defer p.deinit();
        const input = "a=p,i=1,H=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete(alloc);
        defer command.deinit(alloc);
        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.horizontal_offset);
    }
    {
        var p = Parser.init(alloc, 1024 * 1024);
        defer p.deinit();
        const input = "a=p,i=1,V=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete(alloc);
        defer command.deinit(alloc);
        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.vertical_offset);
    }
}
test "response: encode nothing without ID or image number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var r: Response = .{};
    try r.encode(&writer);
    try testing.expectEqualStrings("", writer.buffered());
}
test "response: encode with only image id" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var r: Response = .{ .id = 4 };
    try r.encode(&writer);
    try testing.expectEqualStrings("\x1b_Gi=4;OK\x1b\\", writer.buffered());
}
test "response: encode with only image number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var r: Response = .{ .image_number = 4 };
    try r.encode(&writer);
    try testing.expectEqualStrings("\x1b_GI=4;OK\x1b\\", writer.buffered());
}
test "response: encode with image ID and number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var r: Response = .{ .id = 12, .image_number = 4 };
    try r.encode(&writer);
    try testing.expectEqualStrings("\x1b_Gi=12,I=4;OK\x1b\\", writer.buffered());
}
test "delete range command 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=r,x=3,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(!range.delete);
    try testing.expectEqual(@as(u32, 3), range.first);
    try testing.expectEqual(@as(u32, 4), range.last);
}
test "delete range command 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=R,x=5,y=11";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 11), range.last);
}
test "delete range command 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=R,x=5,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 4), range.last);
}
test "delete range command 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=R,x=5";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 0), range.last);
}
test "delete range command 5" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=R,y=5";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 0), range.first);
    try testing.expectEqual(@as(u32, 5), range.last);
}
test "delete range command 6" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();
    const input = "a=d,d=r";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);
    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(!range.delete);
    try testing.expectEqual(@as(u32, 0), range.first);
    try testing.expectEqual(@as(u32, 0), range.last);
}
test "unknown format value is deferred to execution" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=t,f=42,i=31,s=1,v=1");
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    try testing.expect(command.control.transmit.format_unknown);
    try testing.expectEqual(@as(u32, 31), command.control.transmit.image_id);
}
test "zero format value is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=t,f=0,i=31,s=1,v=1");
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expect(!v.format_unknown);
    try testing.expectEqual(Transmission.Format.rgba, v.format);
}
test "known format values are not unknown" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for ([_]struct { []const u8, Transmission.Format }{
        .{ "f=24", .rgb },
        .{ "f=32", .rgba },
        .{ "f=100", .png },
    }) |entry| {
        const command = try Parser.parseString(alloc, entry[0]);
        defer command.deinit(alloc);
        const v = command.control.transmit;
        try testing.expect(!v.format_unknown);
        try testing.expectEqual(entry[1], v.format);
    }
}
test "quiet value above two suppresses all responses" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=t,q=3,i=31,s=1,v=1");
    defer command.deinit(alloc);
    try testing.expectEqual(Command.Quiet.failures, command.quiet);
}
test "cursor movement value above one moves the cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=p,i=31,C=2");
    defer command.deinit(alloc);
    try testing.expect(command.control == .display);
    try testing.expectEqual(
        Display.CursorMovement.after,
        command.control.display.cursor_movement,
    );
}
test "virtual placement value above one is virtual" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=p,i=31,U=2");
    defer command.deinit(alloc);
    try testing.expect(command.control == .display);
    try testing.expect(command.control.display.virtual_placement);
}
test "animation frame composition value above one alpha blends" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=f,i=31,X=2");
    defer command.deinit(alloc);
    try testing.expect(command.control == .transmit_animation_frame);
    try testing.expectEqual(
        CompositionMode.alpha_blend,
        command.control.transmit_animation_frame.composition_mode,
    );
}
test "animation compose value above one overwrites" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=c,i=31,C=2");
    defer command.deinit(alloc);
    try testing.expect(command.control == .compose_animation);
    try testing.expectEqual(
        CompositionMode.overwrite,
        command.control.compose_animation.composition_mode,
    );
}
test "animation control action above three is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const command = try Parser.parseString(alloc, "a=a,i=31,s=4");
    defer command.deinit(alloc);
    try testing.expect(command.control == .control_animation);
    try testing.expectEqual(
        AnimationControl.AnimationAction.invalid,
        command.control.control_animation.action,
    );
}
test "unknown flag key values still fail parsing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for ([_][]const u8{
        "a=z,i=31",
        "a=d,d=w,i=31",
        "a=t,t=q,i=31",
        "a=t,o=q,i=31",
    }) |input| {
        try testing.expectError(
            error.InvalidFormat,
            Parser.parseString(alloc, input),
        );
    }
}
