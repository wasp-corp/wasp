const std = @import("std");
const mem = std.mem;
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const diags = @import("diagnostics.zig");
const internal_os = @import("../os/root.zig");
const Diagnostic = diags.Diagnostic;
const DiagnosticList = diags.DiagnosticList;
const CommaSplitter = @import("CommaSplitter.zig");
const log = std.log.scoped(.cli);
pub const whitespace = " \t";
pub const Error = error{
    ValueRequired,
    InvalidField,
    InvalidValue,
};
pub fn parse(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    iter: anytype,
) !void {
    const info = @typeInfo(T);
    assert(info == .@"struct");
    const arena_available = @hasField(T, "_arena");
    var arena_owned: bool = false;
    const arena_alloc = if (arena_available) arena: {
        if (dst._arena == null) {
            dst._arena = .init(alloc);
            arena_owned = true;
        }
        break :arena dst._arena.?.allocator();
    } else fail: {
        var fail = std.testing.FailingAllocator.init(alloc, .{});
        break :fail fail.allocator();
    };
    errdefer if (arena_available and arena_owned) {
        dst._arena.?.deinit();
        dst._arena = null;
    };
    while (iter.next()) |arg| {
        if (@hasDecl(T, "parseManuallyHook")) {
            if (!try dst.parseManuallyHook(
                arena_alloc,
                arg,
                iter,
            )) return;
        }
        if (@hasDecl(T, "help")) {
            if (mem.eql(u8, arg, "--help") or
                mem.eql(u8, arg, "-h"))
            {
                try dst.help();
                return;
            }
        }
        if (!mem.startsWith(u8, arg, "--")) {
            if (comptime !canTrackDiags(T)) return Error.InvalidField;
            try dst._diagnostics.append(arena_alloc, .{
                .key = try arena_alloc.dupeZ(u8, arg),
                .message = "invalid field",
                .location = try diags.Location.fromIter(iter, arena_alloc),
            });
            continue;
        }
        var key: []const u8 = arg[2..];
        const value: ?[]const u8 = value: {
            if (mem.indexOf(u8, key, "=")) |idx| {
                defer key = key[0..idx];
                break :value key[idx + 1 ..];
            }
            break :value null;
        };
        parseIntoField(T, arena_alloc, dst, key, value) catch |err| err: {
            if (@hasDecl(T, "compatibility")) {
                if (T.compatibility.get(key)) |handler| {
                    if (handler(dst, arena_alloc, key, value)) {
                        log.info(
                            "compatibility handler for {s} handled error, you may be using a deprecated field: {}",
                            .{ key, err },
                        );
                        break :err;
                    }
                }
            }
            if (comptime !canTrackDiags(T)) return err;
            const ErrSet = @TypeOf(err) || error{ Unknown, OutOfMemory } || Error;
            const message: [:0]const u8 = switch (@as(ErrSet, @errorCast(err))) {
                error.OutOfMemory => return err,
                error.InvalidField => "unknown field",
                error.ValueRequired => formatValueRequired(T, arena_alloc, key) catch "value required",
                error.InvalidValue => formatInvalidValue(T, arena_alloc, key, value) catch "invalid value",
                else => try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "unknown error {}",
                    .{err},
                    0,
                ),
            };
            try dst._diagnostics.append(arena_alloc, .{
                .key = try arena_alloc.dupeZ(u8, key),
                .message = message,
                .location = try diags.Location.fromIter(iter, arena_alloc),
            });
        };
    }
}
pub fn CompatibilityHandler(comptime T: type) type {
    return *const fn (
        dst: *T,
        alloc: Allocator,
        key: []const u8,
        value: ?[]const u8,
    ) bool;
}
pub fn compatibilityRenamed(
    comptime T: type,
    comptime to: []const u8,
) CompatibilityHandler(T) {
    comptime assert(@hasField(T, to));
    return (struct {
        fn compat(
            dst: *T,
            alloc: Allocator,
            key: []const u8,
            value: ?[]const u8,
        ) bool {
            _ = key;
            parseIntoField(T, alloc, dst, to, value) catch |err| {
                log.warn("error parsing renamed field {s}: {}", .{
                    to,
                    err,
                });
                return false;
            };
            return true;
        }
    }).compat;
}
fn formatValueRequired(
    comptime T: type,
    arena_alloc: std.mem.Allocator,
    key: []const u8,
) std.Io.Writer.Error![:0]const u8 {
    var stream: std.Io.Writer.Allocating = .init(arena_alloc);
    const writer = &stream.writer;
    try writer.print("value required", .{});
    try formatValues(T, key, writer);
    try writer.writeByte(0);
    const written = stream.written();
    return written[0 .. written.len - 1 :0];
}
fn formatInvalidValue(
    comptime T: type,
    arena_alloc: std.mem.Allocator,
    key: []const u8,
    value: ?[]const u8,
) std.Io.Writer.Error![:0]const u8 {
    var stream: std.Io.Writer.Allocating = .init(arena_alloc);
    const writer = &stream.writer;
    try writer.print("invalid value \"{?s}\"", .{value});
    try formatValues(T, key, writer);
    try writer.writeByte(0);
    const written = stream.written();
    return written[0 .. written.len - 1 :0];
}
fn formatValues(
    comptime T: type,
    key: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    @setEvalBranchQuota(2000);
    const typeinfo = @typeInfo(T);
    inline for (typeinfo.@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            switch (@typeInfo(f.type)) {
                .@"enum" => |e| {
                    try writer.print(", valid values are: ", .{});
                    inline for (e.fields, 0..) |field, i| {
                        if (i != 0) try writer.print(", ", .{});
                        try writer.print("{s}", .{field.name});
                    }
                },
                else => {},
            }
            break;
        }
    }
}
fn canTrackDiags(comptime T: type) bool {
    return @hasField(T, "_diagnostics");
}
pub fn parseIntoField(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    key: []const u8,
    value: ?[]const u8,
) !void {
    const info = @typeInfo(T);
    assert(info == .@"struct");
    inline for (info.@"struct".fields) |field| {
        if (field.name[0] != '_' and mem.eql(u8, field.name, key)) {
            const Field = switch (@typeInfo(field.type)) {
                .optional => |opt| opt.child,
                else => field.type,
            };
            const fieldInfo = @typeInfo(Field);
            const canHaveDecls = fieldInfo == .@"struct" or
                fieldInfo == .@"union" or
                fieldInfo == .@"enum";
            if (value) |v| default: {
                if (v.len != 0) break :default;
                if (canHaveDecls and @hasDecl(Field, "init")) {
                    try @field(dst, field.name).init(alloc);
                    return;
                }
                const raw = field.default_value_ptr orelse break :default;
                const ptr: *const field.type = @ptrCast(@alignCast(raw));
                @field(dst, field.name) = ptr.*;
                return;
            }
            if (canHaveDecls) {
                if (@hasDecl(Field, "parseCLI")) {
                    const fnInfo = @typeInfo(@TypeOf(Field.parseCLI)).@"fn";
                    switch (fnInfo.params.len) {
                        1 => @field(dst, field.name) = try Field.parseCLI(value),
                        2 => switch (@typeInfo(field.type)) {
                            .@"struct",
                            .@"union",
                            .@"enum",
                            => try @field(dst, field.name).parseCLI(value),
                            .optional => if (@field(dst, field.name)) |*v| {
                                try v.parseCLI(value);
                            } else {
                                var tmp: Field = undefined;
                                try tmp.parseCLI(value);
                                @field(dst, field.name) = tmp;
                            },
                            else => @compileError("unexpected field type"),
                        },
                        3 => switch (@typeInfo(field.type)) {
                            .@"struct",
                            .@"union",
                            .@"enum",
                            => try @field(dst, field.name).parseCLI(alloc, value),
                            .optional => if (@field(dst, field.name)) |*v| {
                                try v.parseCLI(alloc, value);
                            } else {
                                var tmp: Field = undefined;
                                try tmp.parseCLI(alloc, value);
                                @field(dst, field.name) = tmp;
                            },
                            else => @compileError("unexpected field type"),
                        },
                        else => @compileError("parseCLI invalid argument count"),
                    }
                    return;
                }
            }
            @field(dst, field.name) = switch (Field) {
                []const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.alloc(u8, slice.len);
                    @memcpy(buf, slice);
                    break :value buf;
                },
                [:0]const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.allocSentinel(u8, slice.len, 0);
                    @memcpy(buf, slice);
                    buf[slice.len] = 0;
                    break :value buf;
                },
                bool => try parseBool(value orelse "t"),
                inline u8,
                u16,
                u21,
                u32,
                u64,
                usize,
                i8,
                i16,
                i32,
                i64,
                isize,
                => |Int| std.fmt.parseInt(
                    Int,
                    value orelse return error.ValueRequired,
                    0,
                ) catch return error.InvalidValue,
                f32,
                f64,
                => |Float| std.fmt.parseFloat(
                    Float,
                    value orelse return error.ValueRequired,
                ) catch return error.InvalidValue,
                else => switch (fieldInfo) {
                    .@"enum" => std.meta.stringToEnum(
                        Field,
                        value orelse return error.ValueRequired,
                    ) orelse return error.InvalidValue,
                    .@"struct" => try parseStruct(
                        Field,
                        alloc,
                        value orelse return error.ValueRequired,
                    ),
                    .@"union" => try parseTaggedUnion(
                        Field,
                        alloc,
                        value orelse return error.ValueRequired,
                    ),
                    else => @compileError("unsupported field type"),
                },
            };
            return;
        }
    }
    return error.InvalidField;
}
pub fn parseTaggedUnion(comptime T: type, alloc: Allocator, v: []const u8) !T {
    const info = @typeInfo(T).@"union";
    assert(@typeInfo(info.tag_type.?) == .@"enum");
    const colon_idx = mem.indexOf(u8, v, ":") orelse v.len;
    const tag_str = std.mem.trim(u8, v[0..colon_idx], whitespace);
    const value = if (colon_idx < v.len) v[colon_idx + 1 ..] else "";
    inline for (info.fields) |field| {
        if (mem.eql(u8, field.name, tag_str)) {
            if (field.type == void) {
                if (value.len > 0) return error.InvalidValue;
                return @unionInit(T, field.name, {});
            }
            const Target = @Struct(
                .auto,
                null,
                &.{field.name},
                &.{field.type},
                &.{.{ .@"align" = @alignOf(field.type) }},
            );
            var t: Target = undefined;
            try parseIntoField(Target, alloc, &t, field.name, value);
            return @unionInit(T, field.name, @field(t, field.name));
        }
    }
    return error.InvalidValue;
}
fn parseStruct(comptime T: type, alloc: Allocator, v: []const u8) !T {
    return switch (@typeInfo(T).@"struct".layout) {
        .auto => parseAutoStruct(T, alloc, v, null),
        .@"packed" => parsePackedStruct(T, v),
        else => @compileError("unsupported struct layout"),
    };
}
pub fn parseAutoStruct(
    comptime T: type,
    alloc: Allocator,
    v: []const u8,
    default_: ?T,
) !T {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout == .auto);
    var result: T = undefined;
    const FieldSet = std.StaticBitSet(info.fields.len);
    var fields_set: FieldSet = .initEmpty();
    var iter: CommaSplitter = .init(v);
    loop: while (try iter.next()) |entry| {
        const idx = mem.indexOf(u8, entry, ":") orelse return error.InvalidValue;
        const key = std.mem.trim(u8, entry[0..idx], whitespace);
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        const value = value: {
            const value = std.mem.trim(u8, entry[idx + 1 ..], whitespace);
            if (value.len >= 2 and
                value[0] == '"' and
                value[value.len - 1] == '"')
            {
                const parsed = try std.zig.string_literal.parseWrite(&buf.writer, value);
                if (parsed == .failure) return error.InvalidValue;
                break :value buf.written();
            }
            break :value value;
        };
        inline for (info.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, key)) {
                try parseIntoField(T, alloc, &result, key, value);
                fields_set.set(i);
                continue :loop;
            }
        }
        return error.InvalidValue;
    }
    inline for (info.fields, 0..) |field, i| {
        if (!fields_set.isSet(i)) {
            @field(result, field.name) = default: {
                if (default_) |default| {
                    break :default @field(default, field.name);
                } else {
                    const default_ptr = field.default_value_ptr orelse return error.InvalidValue;
                    const typed_ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                    break :default typed_ptr.*;
                }
            };
        }
    }
    return result;
}
pub fn parsePackedStruct(comptime T: type, v: []const u8) !T {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout == .@"packed");
    var result: T = .{};
    bools: {
        const b = parseBool(v) catch break :bools;
        inline for (info.fields) |field| {
            assert(field.type == bool);
            @field(result, field.name) = b;
        }
        return result;
    }
    var iter = std.mem.splitSequence(u8, v, ",");
    loop: while (iter.next()) |part_raw| {
        const part, const value = part: {
            const negation_prefix = "no-";
            const trimmed = std.mem.trim(u8, part_raw, whitespace);
            if (std.mem.startsWith(u8, trimmed, negation_prefix)) {
                break :part .{ trimmed[negation_prefix.len..], false };
            } else {
                break :part .{ trimmed, true };
            }
        };
        inline for (info.fields) |field| {
            assert(field.type == bool);
            if (std.mem.eql(u8, field.name, part)) {
                @field(result, field.name) = value;
                continue :loop;
            }
        }
        return error.InvalidValue;
    }
    return result;
}
pub fn parseBool(v: []const u8) !bool {
    const t = &[_][]const u8{ "1", "t", "T", "true" };
    const f = &[_][]const u8{ "0", "f", "F", "false" };
    inline for (t) |str| {
        if (mem.eql(u8, v, str)) return true;
    }
    inline for (f) |str| {
        if (mem.eql(u8, v, str)) return false;
    }
    return error.InvalidValue;
}
test "parse: simple" {
    const testing = std.testing;
    var data: struct {
        a: []const u8 = "",
        b: bool = false,
        @"b-f": bool = true,
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");
    var iter2 = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--a=84",
    );
    defer iter2.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter2);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("84", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");
}
test "parse: quoted value" {
    const testing = std.testing;
    var data: struct {
        a: u8 = 0,
        b: []const u8 = "",
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--a=\"42\" --b=\"hello!\"",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expectEqual(@as(u8, 42), data.a);
    try testing.expectEqualStrings("hello!", data.b);
}
test "parse: empty value resets to default" {
    const testing = std.testing;
    var data: struct {
        a: u8 = 42,
        b: bool = false,
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--a= --b=",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expectEqual(@as(u8, 42), data.a);
    try testing.expect(!data.b);
}
test "parse: positional arguments are invalid" {
    const testing = std.testing;
    var data: struct {
        a: u8 = 42,
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--a=84 what",
    );
    defer iter.deinit();
    try testing.expectError(
        error.InvalidField,
        parse(@TypeOf(data), testing.allocator, &data, &iter),
    );
    try testing.expectEqual(@as(u8, 84), data.a);
}
test "parse: diagnostic tracking" {
    const testing = std.testing;
    var data: struct {
        a: []const u8 = "",
        b: enum { one } = .one,
        _arena: ?ArenaAllocator = null,
        _diagnostics: DiagnosticList = .{},
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--what --a=42",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data._diagnostics.items().len == 1);
    {
        const diag = data._diagnostics.items()[0];
        try testing.expectEqual(diags.Location.none, diag.location);
        try testing.expectEqualStrings("what", diag.key);
        try testing.expectEqualStrings("unknown field", diag.message);
    }
}
test "parse: diagnostic location" {
    const testing = std.testing;
    var data: struct {
        a: []const u8 = "",
        b: enum { one, two } = .one,
        _arena: ?ArenaAllocator = null,
        _diagnostics: DiagnosticList = .{},
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var r: std.Io.Reader = .fixed(
        \\a=42
        \\what
        \\b=two
    );
    var iter: LineIterator = .{ .r = &r, .filepath = "test" };
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b == .two);
    try testing.expect(data._diagnostics.items().len == 1);
    {
        const diag = data._diagnostics.items()[0];
        try testing.expectEqualStrings("what", diag.key);
        try testing.expectEqualStrings("unknown field", diag.message);
        try testing.expectEqualStrings("test", diag.location.file.path);
        try testing.expectEqual(2, diag.location.file.line);
    }
}
test "parse: compatibility handler" {
    const testing = std.testing;
    var data: struct {
        a: bool = false,
        _arena: ?ArenaAllocator = null,
        pub const compatibility: std.StaticStringMap(
            CompatibilityHandler(@This()),
        ) = .initComptime(&.{
            .{ "a", compat },
        });
        fn compat(
            self: *@This(),
            alloc: Allocator,
            key: []const u8,
            value: ?[]const u8,
        ) bool {
            _ = alloc;
            if (std.mem.eql(u8, key, "a")) {
                if (value) |v| {
                    if (mem.eql(u8, v, "yuh")) {
                        self.a = true;
                        return true;
                    }
                }
            }
            return false;
        }
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--a=yuh",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expect(data.a);
}
test "parse: compatibility renamed" {
    const testing = std.testing;
    var data: struct {
        a: bool = false,
        b: bool = false,
        _arena: ?ArenaAllocator = null,
        pub const compatibility: std.StaticStringMap(
            CompatibilityHandler(@This()),
        ) = .initComptime(&.{
            .{ "old", compatibilityRenamed(@This(), "a") },
        });
    } = .{};
    defer if (data._arena) |arena| arena.deinit();
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--old=true --b=true",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expect(data.a);
    try testing.expect(data.b);
}
test "parseIntoField: ignore underscore-prefixed fields" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        _a: []const u8 = "12",
    } = .{};
    try testing.expectError(
        error.InvalidField,
        parseIntoField(@TypeOf(data), alloc, &data, "_a", "42"),
    );
    try testing.expectEqualStrings("12", data._a);
}
test "parseIntoField: struct with init func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: struct {
            const Self = @This();
            v: []const u8,
            pub fn init(self: *Self, _alloc: Allocator) !void {
                _ = _alloc;
                self.* = .{ .v = "HELLO!" };
            }
        },
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}
test "parseIntoField: string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: []const u8,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
}
test "parseIntoField: sentinel string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: [:0]const u8,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
    try testing.expectEqual(@as(u8, 0), data.a[data.a.len]);
}
test "parseIntoField: bool" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: bool,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "t");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "T");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "true");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "0");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "f");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "F");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "false");
    try testing.expectEqual(false, data.a);
}
test "parseIntoField: unsigned numbers" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        u8: u8,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "u8", "1");
    try testing.expectEqual(@as(u8, 1), data.u8);
}
test "parseIntoField: floats" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        f64: f64,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "f64", "1");
    try testing.expectEqual(@as(f64, 1.0), data.f64);
}
test "parseIntoField: enums" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Enum = enum { one, two, three };
    var data: struct {
        v: Enum,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "v", "two");
    try testing.expectEqual(Enum.two, data.v);
}
test "parseIntoField: packed struct" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "v", "b");
    try testing.expect(!data.v.a);
    try testing.expect(data.v.b);
}
test "parseIntoField: packed struct negation" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "v", "a,no-b");
    try testing.expect(data.v.a);
    try testing.expect(!data.v.b);
}
test "parseIntoField: packed struct true/false" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "v", "true");
    try testing.expect(data.v.a);
    try testing.expect(data.v.b);
    try parseIntoField(@TypeOf(data), alloc, &data, "v", "false");
    try testing.expect(!data.v.a);
    try testing.expect(!data.v.b);
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "v", "true,a"),
    );
}
test "parseIntoField: packed struct whitespace" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "v", " a, no-b ");
    try testing.expect(data.v.a);
    try testing.expect(!data.v.b);
}
test "parseIntoField: optional field" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: ?bool = null,
    } = .{};
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a.?);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "");
    try testing.expect(data.a == null);
}
test "parseIntoField: struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: struct {
            const Self = @This();
            v: []const u8,
            pub fn parseCLI(value: ?[]const u8) !Self {
                _ = value;
                return Self{ .v = "HELLO!" };
            }
        },
    } = undefined;
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}
test "parseIntoField: optional struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        a: ?struct {
            const Self = @This();
            v: []const u8,
            pub fn parseCLI(self: *Self, _: Allocator, value: ?[]const u8) !void {
                _ = value;
                self.* = .{ .v = "HELLO!" };
            }
        } = null,
    } = .{};
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.?.v);
}
test "parseIntoField: struct with basic fields" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        value: struct {
            a: []const u8,
            b: u32,
            c: u8 = 12,
        } = undefined,
    } = .{};
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "a:hello,b:42");
    try testing.expectEqualStrings("hello", data.value.a);
    try testing.expectEqual(42, data.value.b);
    try testing.expectEqual(12, data.value.c);
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "a:world,b:84,c:24");
    try testing.expectEqualStrings("world", data.value.a);
    try testing.expectEqual(84, data.value.b);
    try testing.expectEqual(24, data.value.c);
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "a:hello"),
    );
}
test "parseIntoField: tagged union" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
            c: void,
            d: []const u8,
            e: [:0]const u8,
        } = undefined,
    } = .{};
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "a:1");
    try testing.expectEqual(1, data.value.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "b:2");
    try testing.expectEqual(2, data.value.b);
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "c");
    try testing.expectEqual({}, data.value.c);
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "d:hello");
    try testing.expectEqualStrings("hello", data.value.d);
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "e:hello");
    try testing.expectEqualStrings("hello", data.value.e);
}
test "parseIntoField: tagged union unknown filed" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
        } = undefined,
    } = .{};
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "c:1"),
    );
}
test "parseIntoField: tagged union invalid field value" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
        } = undefined,
    } = .{};
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "a:hello"),
    );
}
test "parseIntoField: tagged union missing tag" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
        } = undefined,
    } = .{};
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "a"),
    );
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", ":a"),
    );
}
pub fn ArgsIterator(comptime Iterator: type) type {
    return struct {
        const Self = @This();
        iterator: Iterator,
        index: usize = 0,
        pub fn deinit(self: *Self) void {
            if (@hasDecl(Iterator, "deinit")) {
                self.iterator.deinit();
            }
        }
        pub fn next(self: *Self) ?[]const u8 {
            const value = self.iterator.next() orelse return null;
            self.index += 1;
            if (value.len > 0 and value[0] == '+') return self.next();
            return value;
        }
        pub fn location(self: *const Self, _: Allocator) error{}!?diags.Location {
            return .{ .cli = self.index };
        }
    };
}
pub fn argsIterator(
    alloc_gpa: Allocator,
    args: std.process.Args,
) std.process.Args.Iterator.InitError!ArgsIterator(std.process.Args.Iterator) {
    var iter: std.process.Args.Iterator = try .initAllocator(args, alloc_gpa);
    errdefer iter.deinit();
    _ = iter.next();
    return .{ .iterator = iter };
}
test "ArgsIterator" {
    const testing = std.testing;
    const child = try std.process.Args.IteratorGeneral(.{}).init(
        testing.allocator,
        "--what +list-things --a=42",
    );
    const Iter = ArgsIterator(@TypeOf(child));
    var iter: Iter = .{ .iterator = child };
    defer iter.deinit();
    try testing.expectEqualStrings("--what", iter.next().?);
    try testing.expectEqualStrings("--a=42", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
pub const LineIterator = struct {
    const Self = @This();
    pub const MAX_LINE_SIZE = 4096;
    r: *std.Io.Reader,
    filepath: []const u8 = "",
    line: usize = 0,
    entry: [MAX_LINE_SIZE]u8 = [_]u8{ '-', '-' } ++ ([_]u8{0} ** (MAX_LINE_SIZE - 2)),
    pub fn init(reader: *std.Io.Reader) Self {
        return .{ .r = reader };
    }
    pub fn next(self: *Self) ?[]const u8 {
        if (self.r.bufferedLen() < self.r.buffer.len) {
            self.r.fillMore() catch {};
        }
        var writer: std.Io.Writer = .fixed(self.entry[2..]);
        var entry = while (self.r.seek != self.r.end) {
            writer.end = 0;
            _ = self.r.streamDelimiterEnding(&writer, '\n') catch |e| {
                log.warn("cannot read from \"{s}\": {}", .{ self.filepath, e });
                return null;
            };
            _ = self.r.discardDelimiterInclusive('\n') catch {};
            var entry = writer.buffered();
            self.line += 1;
            const trim = std.mem.trim(u8, entry, whitespace ++ "\r");
            if (trim.len != entry.len) {
                std.mem.copyForwards(u8, entry, trim);
                entry = entry[0..trim.len];
            }
            if (entry.len == 0 or entry[0] == '#') {
                if (self.r.seek == self.r.end) {
                    self.r.fillMore() catch {};
                }
                continue;
            }
            break entry;
        } else return null;
        if (mem.indexOf(u8, entry, "=")) |idx| {
            const key = std.mem.trim(u8, entry[0..idx], whitespace);
            const value = value: {
                var value = std.mem.trim(u8, entry[idx + 1 ..], whitespace);
                if (value.len >= 2 and
                    value[0] == '"' and
                    value[value.len - 1] == '"')
                {
                    value = value[1 .. value.len - 1];
                }
                break :value value;
            };
            const len = key.len + value.len + 1;
            if (entry.len != len) {
                std.mem.copyForwards(u8, entry, key);
                entry[key.len] = '=';
                std.mem.copyForwards(u8, entry[key.len + 1 ..], value);
                entry = entry[0..len];
            }
        }
        return self.entry[0 .. entry.len + 2];
    }
    pub fn location(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!?diags.Location {
        if (self.filepath.len == 0) return null;
        return .{ .file = .{
            .path = try alloc.dupe(u8, self.filepath),
            .line = self.line,
        } };
    }
};
pub const SliceIterator = struct {
    const Self = @This();
    slice: []const []const u8,
    idx: usize = 0,
    pub fn next(self: *Self) ?[]const u8 {
        if (self.idx >= self.slice.len) return null;
        defer self.idx += 1;
        return self.slice[self.idx];
    }
};
pub fn sliceIterator(slice: []const []const u8) SliceIterator {
    return .{ .slice = slice };
}
test "LineIterator" {
    const testing = std.testing;
    var reader: std.Io.Reader = .fixed(
        \\A
        \\B=42
        \\C
        \\
        \\# A comment
        \\D
        \\
        \\  # An indented comment
        \\  E
        \\
        \\# A quoted string with whitespace
        \\F=  "value "
    );
    var iter: LineIterator = .init(&reader);
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=42", iter.next().?);
    try testing.expectEqualStrings("--C", iter.next().?);
    try testing.expectEqualStrings("--D", iter.next().?);
    try testing.expectEqualStrings("--E", iter.next().?);
    try testing.expectEqualStrings("--F=value ", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator end in newline" {
    const testing = std.testing;
    var reader: std.Io.Reader = .fixed("A\n\n");
    var iter: LineIterator = .init(&reader);
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator spaces around '='" {
    const testing = std.testing;
    var reader: std.Io.Reader = .fixed("A = B\n\n");
    var iter: LineIterator = .init(&reader);
    try testing.expectEqualStrings("--A=B", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator no value" {
    const testing = std.testing;
    var reader: std.Io.Reader = .fixed("A = \n\n");
    var iter: LineIterator = .init(&reader);
    try testing.expectEqualStrings("--A=", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator with CRLF line endings" {
    const testing = std.testing;
    var reader: std.Io.Reader = .fixed("A\r\nB = C\r\n");
    var iter: LineIterator = .init(&reader);
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=C", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator with buffered reader" {
    const testing = std.testing;
    var f: std.Io.Reader = .fixed("A\nB = C\n");
    var buf: [2]u8 = undefined;
    var r = f.limited(.unlimited, &buf);
    const reader = &r.interface;
    var iter: LineIterator = .init(reader);
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=C", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator with buffered and primed reader" {
    const testing = std.testing;
    var f: std.Io.Reader = .fixed("A\nB = C\n");
    var buf: [2]u8 = undefined;
    var r = f.limited(.unlimited, &buf);
    const reader = &r.interface;
    try reader.fill(buf.len);
    var iter: LineIterator = .init(reader);
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=C", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
test "LineIterator refills after ignored line at buffer boundary" {
    const testing = std.testing;
    {
        var f: std.Io.Reader = .fixed("#\nA\n");
        var buf: [2]u8 = undefined;
        var r = f.limited(.unlimited, &buf);
        var iter: LineIterator = .init(&r.interface);
        try testing.expectEqualStrings("--A", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }
    {
        var f: std.Io.Reader = .fixed("\nA\n");
        var buf: [1]u8 = undefined;
        var r = f.limited(.unlimited, &buf);
        var iter: LineIterator = .init(&r.interface);
        try testing.expectEqualStrings("--A", iter.next().?);
        try testing.expectEqual(@as(?[]const u8, null), iter.next());
    }
}
