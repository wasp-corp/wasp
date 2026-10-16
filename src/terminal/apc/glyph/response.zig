const std = @import("std");
pub const Coverage = packed struct(u2) {
    system: bool = false,
    glossary: bool = false,
    pub const free: Coverage = .{};
    pub fn init(value: []const u8) ?Coverage {
        var result: Coverage = .free;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |name| {
            if (std.mem.eql(u8, name, "system")) {
                result.system = true;
            } else if (std.mem.eql(u8, name, "glossary")) {
                result.glossary = true;
            }
        }
        return result;
    }
};
pub const Response = union(enum) {
    pub const max_wire_bytes = 1024;
    support: Support,
    query: Query,
    register: Register,
    clear: Clear,
    pub const Support = struct {
        fmt: Formats,
        pub const Formats = packed struct(u8) {
            glyf: bool = false,
            colrv0: bool = false,
            colrv1: bool = false,
            _padding: u5 = 0,
        };
    };
    pub const Query = struct {
        cp: u21,
        status: Coverage,
    };
    pub const Register = struct {
        cp: u21,
        status: Status = .ok,
        reason: ?Reason = null,
        pub const Reason = union(enum) {
            out_of_namespace,
            composite_unsupported,
            hinting_unsupported,
            malformed_payload,
            payload_too_large,
            other: []const u8,
            pub fn name(self: Reason) []const u8 {
                return switch (self) {
                    .out_of_namespace => "out_of_namespace",
                    .composite_unsupported => "composite_unsupported",
                    .hinting_unsupported => "hinting_unsupported",
                    .malformed_payload => "malformed_payload",
                    .payload_too_large => "payload_too_large",
                    .other => |value| value,
                };
            }
        };
    };
    pub const Clear = struct {
        status: Status = .ok,
        reason: ?[]const u8 = null,
    };
    pub const Status = enum(u8) {
        ok = 0,
        err = 1,
        _,
    };
    pub fn formatWire(
        self: Response,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b_25a1;");
        switch (self) {
            .support => |r| {
                try writer.writeAll("s;fmt=");
                var first = true;
                if (r.fmt.glyf) {
                    first = false;
                    try writer.writeAll("glyf");
                }
                if (r.fmt.colrv0) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.writeAll("colrv0");
                }
                if (r.fmt.colrv1) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.writeAll("colrv1");
                }
            },
            .query => |r| {
                try writer.print("q;cp={x};status=", .{r.cp});
                var first = true;
                if (r.status.system) {
                    first = false;
                    try writer.writeAll("system");
                }
                if (r.status.glossary) {
                    if (!first) try writer.writeByte(',');
                    try writer.writeAll("glossary");
                }
            },
            .register => |r| {
                try writer.print("r;cp={x};status={d}", .{ r.cp, @intFromEnum(r.status) });
                if (r.reason) |reason| {
                    try writer.writeAll(";reason=");
                    try writer.writeAll(reason.name());
                }
            },
            .clear => |r| {
                try writer.print("c;status={d}", .{@intFromEnum(r.status)});
                if (r.reason) |reason| {
                    try writer.writeAll(";reason=");
                    try writer.writeAll(reason);
                }
            },
        }
        try writer.writeAll("\x1b\\");
    }
};
test "support formats default to no advertised formats" {
    const testing = std.testing;
    const Formats = Response.Support.Formats;
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Formats{})));
}
test "response support formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .support = .{ .fmt = .{ .glyf = true, .colrv0 = true } } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=glyf,colrv0\x1b\\", writer.buffered());
}
test "response support formatWire with no formats" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .support = .{ .fmt = .{} } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=\x1b\\", writer.buffered());
}
test "response query formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .query = .{ .cp = 0xE0A0, .status = .{ .system = true, .glossary = true } } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=system,glossary\x1b\\", writer.buffered());
}
test "response query formatWire with no coverage" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .query = .{ .cp = 0xE0A0, .status = .{} } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=\x1b\\", writer.buffered());
}
test "coverage parses comma-separated names" {
    const testing = std.testing;
    try testing.expectEqual(Coverage{}, Coverage.init("").?);
    try testing.expectEqual(Coverage{ .system = true }, Coverage.init("system").?);
    try testing.expectEqual(Coverage{ .glossary = true }, Coverage.init("glossary").?);
    try testing.expectEqual(Coverage{ .system = true, .glossary = true }, Coverage.init("system,glossary").?);
    try testing.expectEqual(Coverage{ .system = true, .glossary = true }, Coverage.init("glossary,system").?);
    try testing.expectEqual(Coverage{ .system = true }, Coverage.init("system,future").?);
    try testing.expectEqual(Coverage{}, Coverage.init("future").?);
}
test "response register success formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .register = .{ .cp = 0xE0A0 } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=0\x1b\\", writer.buffered());
}
test "response register error formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .register = .{ .cp = 0xE0A0, .status = .err, .reason = .out_of_namespace } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=1;reason=out_of_namespace\x1b\\", writer.buffered());
}
test "response register arbitrary status formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .register = .{ .cp = 0xE0A0, .status = @enumFromInt(37), .reason = .payload_too_large } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=37;reason=payload_too_large\x1b\\", writer.buffered());
}
test "register reason names" {
    const testing = std.testing;
    const Reason = Response.Register.Reason;
    try testing.expectEqualStrings("out_of_namespace", (Reason{ .out_of_namespace = {} }).name());
    try testing.expectEqualStrings("composite_unsupported", (Reason{ .composite_unsupported = {} }).name());
    try testing.expectEqualStrings("hinting_unsupported", (Reason{ .hinting_unsupported = {} }).name());
    try testing.expectEqualStrings("malformed_payload", (Reason{ .malformed_payload = {} }).name());
    try testing.expectEqualStrings("payload_too_large", (Reason{ .payload_too_large = {} }).name());
    try testing.expectEqualStrings("future_reason", (Reason{ .other = "future_reason" }).name());
}
test "response clear formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .clear = .{} };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;c;status=0\x1b\\", writer.buffered());
}
test "response clear error formatWire" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const resp: Response = .{ .clear = .{ .status = .err, .reason = "out_of_namespace" } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;c;status=1;reason=out_of_namespace\x1b\\", writer.buffered());
}
