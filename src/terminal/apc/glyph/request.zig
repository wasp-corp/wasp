const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const LimitedAllocator = @import("../../../datastruct/root.zig").LimitedAllocator;
const Glyf = @import("../../../font/opentype/glyf.zig").Glyf;
const fraction = @import("../../fraction.zig");
const max_payload_size = 64 * 1024;
pub const CommandParser = struct {
    alloc: Allocator,
    data: std.ArrayList(u8) = .empty,
    max_bytes: usize,
    pub const Error = Allocator.Error || error{InvalidFormat};
    pub fn init(alloc: Allocator, max_bytes: usize) CommandParser {
        return .{ .alloc = alloc, .max_bytes = max_bytes };
    }
    pub fn deinit(self: *CommandParser) void {
        self.data.deinit(self.alloc);
    }
    pub fn feed(self: *CommandParser, byte: u8) Allocator.Error!void {
        if (self.data.items.len >= self.max_bytes) return error.OutOfMemory;
        try self.data.append(self.alloc, byte);
    }
    pub fn feedSlice(self: *CommandParser, bytes: []const u8) Allocator.Error!void {
        if (self.data.items.len + bytes.len > self.max_bytes) return error.OutOfMemory;
        try self.data.appendSlice(self.alloc, bytes);
    }
    pub fn complete(self: *CommandParser, alloc: Allocator) Error!Request {
        if (self.data.items.len == 1) try self.data.append(self.alloc, ';');
        const raw = try self.data.toOwnedSlice(alloc);
        self.data = .empty;
        errdefer alloc.free(raw);
        return try Request.parse(alloc, raw);
    }
};
pub const Request = union(enum) {
    support,
    query: Query,
    register: Register,
    clear: Clear,
    pub const Query = struct {
        raw: []const u8,
        pub fn init(raw: []const u8) Query {
            return .{ .raw = raw };
        }
        pub const Option = enum {
            cp,
            pub fn Type(comptime self: Option) type {
                return switch (self) {
                    .cp => u21,
                };
            }
            fn key(comptime self: Option) []const u8 {
                return @tagName(self);
            }
            pub fn read(comptime self: Option, raw: []const u8) ?self.Type() {
                const value = optionValue(raw, self.key()) orelse return null;
                return switch (self) {
                    .cp => std.fmt.parseInt(u21, value, 16) catch null,
                };
            }
        };
        pub fn get(self: Query, comptime option: Option) ?option.Type() {
            return option.read(self.rawOptions());
        }
        fn rawOptions(self: Query) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'q');
            assert(self.raw[1] == ';');
            return self.raw[2..];
        }
    };
    pub const Register = struct {
        raw: []const u8,
        payload_idx: usize,
        pub fn init(raw: []const u8) ?Register {
            if (raw.len < 2) return null;
            if (raw[0] != 'r') return null;
            if (raw[1] != ';') return null;
            const payload_idx = std.mem.lastIndexOfScalar(u8, raw, ';') orelse return null;
            if (payload_idx <= 1) return null;
            return .{
                .raw = raw,
                .payload_idx = payload_idx,
            };
        }
        pub const Option = enum {
            cp,
            fmt,
            reply,
            upm,
            aw,
            lh,
            width,
            size,
            @"align",
            pad,
            pub fn Type(comptime self: Option) type {
                return switch (self) {
                    .cp => u21,
                    .fmt => Format,
                    .reply => Reply,
                    .upm => u32,
                    .aw => u32,
                    .lh => u32,
                    .width => Width,
                    .size => Size,
                    .@"align" => Align,
                    .pad => Pad,
                };
            }
            pub fn default(comptime self: Option) ?self.Type() {
                return switch (self) {
                    .cp => null,
                    .fmt => .glyf,
                    .reply => .all,
                    .upm => 1000,
                    .aw => null,
                    .lh => null,
                    .width => .narrow,
                    .size => .height,
                    .@"align" => .{},
                    .pad => .{},
                };
            }
            fn key(comptime self: Option) []const u8 {
                return @tagName(self);
            }
            pub fn read(comptime self: Option, raw: []const u8) ?self.Type() {
                const value = optionValue(raw, self.key()) orelse return null;
                return switch (self) {
                    .cp => std.fmt.parseInt(u21, value, 16) catch null,
                    .fmt => Format.init(value),
                    .reply => Reply.init(value) orelse .all,
                    .upm => std.fmt.parseInt(u32, value, 10) catch null,
                    .aw => std.fmt.parseInt(u32, value, 10) catch null,
                    .lh => std.fmt.parseInt(u32, value, 10) catch null,
                    .width => Width.init(value),
                    .size => Size.init(value),
                    .@"align" => Align.init(value),
                    .pad => Pad.init(value),
                };
            }
        };
        pub fn get(self: Register, comptime option: Option) ?option.Type() {
            const raw = self.rawOptions();
            if (optionValue(raw, option.key()) == null) {
                return switch (option) {
                    .aw, .lh => self.get(.upm),
                    else => option.default(),
                };
            }
            return option.read(raw);
        }
        pub fn payload(self: Register) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'r');
            assert(self.raw[1] == ';');
            return if (self.payload_idx == self.raw.len)
                ""
            else
                self.raw[self.payload_idx + 1 ..];
        }
        pub const DecodeError = Allocator.Error || error{
            PayloadTooLarge,
            MalformedPayload,
            CompositeUnsupported,
            HintingUnsupported,
        };
        pub fn decodeGlyfPayload(
            self: Register,
            alloc: Allocator,
            max_allocation_bytes: usize,
        ) DecodeError!Glyf.Outline {
            const Decoder = std.base64.standard.Decoder;
            const payload_bytes = self.payload();
            const size = Decoder.calcSizeForSlice(payload_bytes) catch
                return error.MalformedPayload;
            if (size > max_payload_size) return error.PayloadTooLarge;
            var data_stack = std.heap.stackFallback(
                max_payload_size,
                alloc,
            );
            const data_alloc = data_stack.get();
            const data = try data_alloc.alloc(u8, size);
            defer data_alloc.free(data);
            Decoder.decode(data, payload_bytes) catch
                return error.MalformedPayload;
            const glyf_entry = Glyf.Entry.init(data) catch return error.MalformedPayload;
            var limited: LimitedAllocator = .init(alloc, max_allocation_bytes);
            return glyf_entry.decode(limited.allocator()) catch |err| switch (err) {
                error.OutOfMemory => if (limited.limit_exceeded)
                    error.PayloadTooLarge
                else
                    error.OutOfMemory,
                error.CompositeNotSupported => error.CompositeUnsupported,
                error.InstructionsNotSupported => error.HintingUnsupported,
                error.ReadFailed,
                error.EndOfStream,
                error.EndPointsOutOfOrder,
                error.TooManyPoints,
                error.CoordinateOverflow,
                => error.MalformedPayload,
            };
        }
        fn rawOptions(self: Register) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'r');
            assert(self.raw[1] == ';');
            assert(self.payload_idx >= 2);
            assert(self.payload_idx <= self.raw.len);
            return self.raw[2..self.payload_idx];
        }
    };
    pub const Clear = struct {
        raw: []const u8,
        pub fn init(raw: []const u8) Clear {
            return .{ .raw = raw };
        }
        pub const Option = enum {
            cp,
            pub fn Type(comptime self: Option) type {
                return switch (self) {
                    .cp => u21,
                };
            }
            fn key(comptime self: Option) []const u8 {
                return @tagName(self);
            }
            pub fn read(comptime self: Option, raw: []const u8) ?self.Type() {
                const value = optionValue(raw, self.key()) orelse return null;
                return switch (self) {
                    .cp => std.fmt.parseInt(u21, value, 16) catch null,
                };
            }
            pub fn present(comptime self: Option, raw: []const u8) bool {
                return optionValue(raw, self.key()) != null;
            }
        };
        pub fn get(self: Clear, comptime option: Option) ?option.Type() {
            return option.read(self.rawOptions());
        }
        pub fn has(self: Clear, comptime option: Option) bool {
            return option.present(self.rawOptions());
        }
        fn rawOptions(self: Clear) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'c');
            assert(self.raw[1] == ';');
            return self.raw[2..];
        }
    };
    pub fn parse(alloc: Allocator, raw: []const u8) error{InvalidFormat}!Request {
        if (raw.len < 2) return error.InvalidFormat;
        if (raw[1] != ';') return error.InvalidFormat;
        return switch (raw[0]) {
            's' => {
                alloc.free(raw);
                return .support;
            },
            'q' => .{ .query = .init(raw) },
            'r' => .{ .register = Register.init(raw) orelse return error.InvalidFormat },
            'c' => .{ .clear = .init(raw) },
            else => error.InvalidFormat,
        };
    }
    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .support => {},
            inline else => |*cmd| if (cmd.raw.len > 0) alloc.free(cmd.raw),
        }
    }
};
pub const Format = enum {
    glyf,
    colrv0,
    colrv1,
    pub fn init(value: []const u8) ?Format {
        return std.meta.stringToEnum(Format, value);
    }
};
pub const Reply = enum(u2) {
    none = 0,
    all = 1,
    failures = 2,
    pub fn init(value: []const u8) ?Reply {
        if (value.len != 1) return null;
        return switch (value[0]) {
            '0' => .none,
            '1' => .all,
            '2' => .failures,
            else => null,
        };
    }
};
pub const Width = enum(u2) {
    narrow = 1,
    wide = 2,
    pub fn init(value: []const u8) ?Width {
        if (value.len != 1) return null;
        return switch (value[0]) {
            '1' => .narrow,
            '2' => .wide,
            else => null,
        };
    }
};
pub const Size = enum {
    height,
    advance,
    contain,
    cover,
    stretch,
    pub fn init(value: []const u8) ?Size {
        return std.meta.stringToEnum(Size, value);
    }
};
pub const Align = struct {
    horizontal: Horizontal = .center,
    vertical: Vertical = .center,
    pub const Horizontal = enum {
        start,
        center,
        end,
        fn init(value: []const u8) ?Horizontal {
            return std.meta.stringToEnum(Horizontal, value);
        }
    };
    pub const Vertical = enum {
        start,
        center,
        end,
        baseline,
        fn init(value: []const u8) ?Vertical {
            return std.meta.stringToEnum(Vertical, value);
        }
    };
    pub fn init(value: []const u8) ?Align {
        var it = std.mem.splitScalar(u8, value, ',');
        const horizontal = Horizontal.init(it.next() orelse return null) orelse return null;
        const vertical = Vertical.init(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null;
        return .{
            .horizontal = horizontal,
            .vertical = vertical,
        };
    }
};
pub const Pad = struct {
    top: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
    left: f64 = 0,
    pub fn init(value: []const u8) ?Pad {
        var it = std.mem.splitScalar(u8, value, ',');
        const top = parseFraction(it.next() orelse return null) orelse return null;
        const right = parseFraction(it.next() orelse return null) orelse return null;
        const bottom = parseFraction(it.next() orelse return null) orelse return null;
        const left = parseFraction(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null;
        if (left + right >= 1 or top + bottom >= 1) return .{};
        return .{
            .top = top,
            .right = right,
            .bottom = bottom,
            .left = left,
        };
    }
    fn parseFraction(value: []const u8) ?f64 {
        return fraction.parse(value);
    }
};
fn optionValue(raw: []const u8, comptime key: []const u8) ?[]const u8 {
    var remaining = raw;
    var result: ?[]const u8 = null;
    while (remaining.len > 0) {
        const len = std.mem.indexOfScalar(u8, remaining, ';') orelse remaining.len;
        const full = remaining[0..len];
        if (std.mem.indexOfScalar(u8, full, '=')) |eql_idx| {
            if (std.mem.eql(u8, full[0..eql_idx], key)) {
                result = full[eql_idx + 1 ..];
            }
        }
        if (len == remaining.len) break;
        remaining = remaining[len + 1 ..];
    }
    return result;
}
fn testParse(alloc: Allocator, data: []const u8) CommandParser.Error!Request {
    var parser = CommandParser.init(alloc, 1024 * 1024);
    defer parser.deinit();
    for (data) |byte| try parser.feed(byte);
    return try parser.complete(alloc);
}
test "support command" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "s");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .support);
}
test "query command" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "q;cp=E0A0");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .query);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.query.get(.cp).?);
}
test "register command with payload" {
    const testing = std.testing;
    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;fmt=glyf;upm=1000;reply=2;QQ==",
    );
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqual(Format.glyf, cmd.register.get(.fmt).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.upm).?);
    try testing.expectEqual(Reply.failures, cmd.register.get(.reply).?);
    try testing.expectEqualStrings("QQ==", cmd.register.payload());
}
test "register command with sizing and placement options" {
    const testing = std.testing;
    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;upm=2048;aw=1024;lh=1536;width=2;size=contain;align=end,baseline;pad=0.1,0.2,0.3,0.4;QQ==",
    );
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u32, 2048), cmd.register.get(.upm).?);
    try testing.expectEqual(@as(u32, 1024), cmd.register.get(.aw).?);
    try testing.expectEqual(@as(u32, 1536), cmd.register.get(.lh).?);
    try testing.expectEqual(Width.wide, cmd.register.get(.width).?);
    try testing.expectEqual(Size.contain, cmd.register.get(.size).?);
    try testing.expectEqual(Align{
        .horizontal = .end,
        .vertical = .baseline,
    }, cmd.register.get(.@"align").?);
    try testing.expectEqual(Pad{
        .top = 0.1,
        .right = 0.2,
        .bottom = 0.3,
        .left = 0.4,
    }, cmd.register.get(.pad).?);
    try testing.expectEqualStrings("QQ==", cmd.register.payload());
}
test "register option defaults" {
    const testing = std.testing;
    const Option = Request.Register.Option;
    try testing.expect(Option.cp.default() == null);
    try testing.expectEqual(Format.glyf, Option.fmt.default().?);
    try testing.expectEqual(@as(u32, 1000), Option.upm.default().?);
    try testing.expect(Option.aw.default() == null);
    try testing.expect(Option.lh.default() == null);
    try testing.expectEqual(Width.narrow, Option.width.default().?);
    try testing.expectEqual(Size.height, Option.size.default().?);
    try testing.expectEqual(Align{}, Option.@"align".default().?);
    try testing.expectEqual(Pad{}, Option.pad.default().?);
    try testing.expectEqual(Reply.all, Option.reply.default().?);
}
test "register command defaults" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "r;cp=e0a0;QQ==");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqual(Format.glyf, cmd.register.get(.fmt).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.upm).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.aw).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.lh).?);
    try testing.expectEqual(Width.narrow, cmd.register.get(.width).?);
    try testing.expectEqual(Size.height, cmd.register.get(.size).?);
    try testing.expectEqual(Align{}, cmd.register.get(.@"align").?);
    try testing.expectEqual(Pad{}, cmd.register.get(.pad).?);
    try testing.expectEqual(Reply.all, cmd.register.get(.reply).?);
}
test "register command aw and lh default to upm" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "r;cp=e0a0;upm=2048;QQ==");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u32, 2048), cmd.register.get(.aw).?);
    try testing.expectEqual(@as(u32, 2048), cmd.register.get(.lh).?);
}
test "register command invalid sizing and placement options" {
    const testing = std.testing;
    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;width=3;size=invalid;align=center,middle;pad=0,1.2,0,0;QQ==",
    );
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expect(cmd.register.get(.width) == null);
    try testing.expect(cmd.register.get(.size) == null);
    try testing.expect(cmd.register.get(.@"align") == null);
    try testing.expect(cmd.register.get(.pad) == null);
}
test "register command degenerate padding defaults to no padding" {
    const testing = std.testing;
    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;pad=0.4,0.2,0.6,0.1;QQ==",
    );
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(Pad{}, cmd.register.get(.pad).?);
}
test "register command invalid reply falls back to reply=1" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "r;cp=e0a0;reply=9;QQ==");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(Reply.all, cmd.register.get(.reply).?);
}
test "register command duplicate options use the last value" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "r;cp=e0a0;reply=1;reply=2;QQ==");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(Reply.failures, cmd.register.get(.reply).?);
}
test "register command with invalid payload" {
    const testing = std.testing;
    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;fmt=glyf;%%%not-base64%%%",
    );
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqual(Format.glyf, cmd.register.get(.fmt).?);
    try testing.expectEqualStrings("%%%not-base64%%%", cmd.register.payload());
}
test "register command rejects missing payload separator" {
    const testing = std.testing;
    for ([_][]const u8{ "r", "r;cp=e0a0", "r;foo" }) |data| {
        try testing.expectError(
            error.InvalidFormat,
            testParse(testing.allocator, data),
        );
    }
}
test "register decodes glyf payload" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer cmd.deinit(testing.allocator);
    var outline = try cmd.register.decodeGlyfPayload(
        testing.allocator,
        std.math.maxInt(usize),
    );
    defer outline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), outline.points.len);
    try testing.expectEqual(@as(usize, 0), outline.contours.len);
}
test "register rejects malformed glyf payload" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "r;cp=e0a0;%%%not-base64%%%");
    defer cmd.deinit(testing.allocator);
    try testing.expectError(
        error.MalformedPayload,
        cmd.register.decodeGlyfPayload(testing.allocator, std.math.maxInt(usize)),
    );
}
test "register response without payload" {
    const testing = std.testing;
    var cmd = try testParse(
        testing.allocator,
        "r;cp=E0A0;status=4;reason=out_of_namespace",
    );
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqualStrings("reason=out_of_namespace", cmd.register.payload());
}
test "clear command" {
    const testing = std.testing;
    var cmd = try testParse(testing.allocator, "c;cp=e0a0");
    defer cmd.deinit(testing.allocator);
    try testing.expect(cmd == .clear);
    try testing.expect(cmd.clear.has(.cp));
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.clear.get(.cp).?);
}
test "clear command tracks malformed cp presence" {
    const testing = std.testing;
    for ([_][]const u8{ "c;cp=zz", "c;cp=", "c;cp=200000" }) |data| {
        var cmd = try testParse(testing.allocator, data);
        defer cmd.deinit(testing.allocator);
        try testing.expect(cmd == .clear);
        try testing.expect(cmd.clear.has(.cp));
        try testing.expect(cmd.clear.get(.cp) == null);
    }
}
test "invalid command" {
    const testing = std.testing;
    try testing.expectError(
        error.InvalidFormat,
        testParse(testing.allocator, "x"),
    );
}
