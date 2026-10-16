const std = @import("std");
pub fn ArithmeticConversion(comptime A: type, comptime B: type) type {
    if (A == c_longdouble or B == c_longdouble) return c_longdouble;
    if (A == f80 or B == f80) return f80;
    if (A == f64 or B == f64) return f64;
    if (A == f32 or B == f32) return f32;
    const A_Promoted = PromotedIntType(A);
    const B_Promoted = PromotedIntType(B);
    comptime {
        std.debug.assert(integerRank(A_Promoted) >= integerRank(c_int));
        std.debug.assert(integerRank(B_Promoted) >= integerRank(c_int));
    }
    if (A_Promoted == B_Promoted) return A_Promoted;
    const a_signed = @typeInfo(A_Promoted).int.signedness == .signed;
    const b_signed = @typeInfo(B_Promoted).int.signedness == .signed;
    if (a_signed == b_signed) {
        return if (integerRank(A_Promoted) > integerRank(B_Promoted)) A_Promoted else B_Promoted;
    }
    const SignedType = if (a_signed) A_Promoted else B_Promoted;
    const UnsignedType = if (!a_signed) A_Promoted else B_Promoted;
    if (integerRank(UnsignedType) >= integerRank(SignedType)) return UnsignedType;
    if (std.math.maxInt(SignedType) >= std.math.maxInt(UnsignedType)) return SignedType;
    return ToUnsigned(SignedType);
}
fn PromotedIntType(comptime T: type) type {
    return switch (T) {
        bool, c_short => c_int,
        c_ushort => if (@sizeOf(c_ushort) == @sizeOf(c_int)) c_uint else c_int,
        c_int, c_uint, c_long, c_ulong, c_longlong, c_ulonglong => T,
        else => switch (@typeInfo(T)) {
            .comptime_int => @compileError("Cannot promote `" ++ @typeName(T) ++ "`; a fixed-size number type is required"),
            .int => |int_info| if (int_info.bits < @bitSizeOf(c_int))
                c_int
            else if (int_info.bits == @bitSizeOf(c_int))
                if (int_info.signedness == .unsigned) c_uint else c_int
            else if (int_info.bits <= @bitSizeOf(c_long))
                if (int_info.signedness == .unsigned) c_ulong else c_long
            else if (int_info.bits <= @bitSizeOf(c_longlong))
                if (int_info.signedness == .unsigned) c_ulonglong else c_longlong
            else
                @compileError("Cannot promote `" ++ @typeName(T) ++ "`; a C ABI type is required"),
            else => @compileError("Attempted to promote invalid type `" ++ @typeName(T) ++ "`"),
        },
    };
}
fn integerRank(comptime T: type) u8 {
    return switch (T) {
        bool => 0,
        u8, i8 => 1,
        c_short, c_ushort => 2,
        c_int, c_uint => 3,
        c_long, c_ulong => 4,
        c_longlong, c_ulonglong => 5,
        else => @compileError("integer rank not supported for `" ++ @typeName(T) ++ "`"),
    };
}
fn ToUnsigned(comptime T: type) type {
    return switch (T) {
        c_int => c_uint,
        c_long => c_ulong,
        c_longlong => c_ulonglong,
        else => @compileError("Cannot convert `" ++ @typeName(T) ++ "` to unsigned"),
    };
}
pub fn FlexibleArrayType(comptime SelfType: type, comptime ElementType: type) type {
    switch (@typeInfo(SelfType)) {
        .pointer => |ptr| {
            return @Pointer(.c, .{
                .@"const" = ptr.is_const,
                .@"volatile" = ptr.is_volatile,
                .@"allowzero" = true,
                .@"addrspace" = .generic,
                .@"align" = null,
            }, ElementType, null);
        },
        else => |info| @compileError("Invalid self type \"" ++ @tagName(info) ++ "\" for flexible array getter: " ++ @typeName(SelfType)),
    }
}
pub inline fn promoteIntLiteral(
    comptime SuffixType: type,
    comptime number: comptime_int,
    comptime base: CIntLiteralBase,
) PromoteIntLiteralReturnType(SuffixType, number, base) {
    return number;
}
const CIntLiteralBase = enum { decimal, octal, hex };
fn PromoteIntLiteralReturnType(comptime SuffixType: type, comptime number: comptime_int, comptime base: CIntLiteralBase) type {
    const signed_decimal = [_]type{ c_int, c_long, c_longlong, c_ulonglong };
    const signed_oct_hex = [_]type{ c_int, c_uint, c_long, c_ulong, c_longlong, c_ulonglong };
    const unsigned = [_]type{ c_uint, c_ulong, c_ulonglong };
    const list: []const type = if (@typeInfo(SuffixType).int.signedness == .unsigned)
        &unsigned
    else if (base == .decimal)
        &signed_decimal
    else
        &signed_oct_hex;
    var pos = std.mem.indexOfScalar(type, list, SuffixType).?;
    while (pos < list.len) : (pos += 1) {
        if (number >= std.math.minInt(list[pos]) and number <= std.math.maxInt(list[pos])) {
            return list[pos];
        }
    }
    @compileError("Integer literal is too large");
}
pub fn shuffleVectorIndex(comptime this_index: c_int, comptime source_vector_len: usize) i32 {
    const positive_index = std.math.cast(usize, this_index) orelse return undefined;
    if (positive_index < source_vector_len) return @as(i32, @intCast(this_index));
    const b_index = positive_index - source_vector_len;
    return ~@as(i32, @intCast(b_index));
}
pub fn signedRemainder(numerator: anytype, denominator: anytype) @TypeOf(numerator, denominator) {
    std.debug.assert(@typeInfo(@TypeOf(numerator, denominator)).int.signedness == .signed);
    if (denominator > 0) return @rem(numerator, denominator);
    return numerator - @divTrunc(numerator, denominator) * denominator;
}
pub fn cast(comptime DestType: type, target: anytype) DestType {
    const SourceType = @TypeOf(target);
    switch (@typeInfo(DestType)) {
        .@"fn" => return castToPtr(*const DestType, SourceType, target),
        .pointer => return castToPtr(DestType, SourceType, target),
        .optional => |dest_opt| {
            if (@typeInfo(dest_opt.child) == .pointer) {
                return castToPtr(DestType, SourceType, target);
            } else if (@typeInfo(dest_opt.child) == .@"fn") {
                return castToPtr(?*const dest_opt.child, SourceType, target);
            }
        },
        .int => {
            switch (@typeInfo(SourceType)) {
                .pointer => {
                    return castInt(DestType, @intFromPtr(target));
                },
                .optional => |opt| {
                    if (@typeInfo(opt.child) == .pointer) {
                        return castInt(DestType, @intFromPtr(target));
                    }
                },
                .int => {
                    return castInt(DestType, target);
                },
                .@"fn" => {
                    return castInt(DestType, @intFromPtr(&target));
                },
                .bool => {
                    return @intFromBool(target);
                },
                else => {},
            }
        },
        .float => {
            switch (@typeInfo(SourceType)) {
                .int => return @as(DestType, @floatFromInt(target)),
                .float => return @as(DestType, @floatCast(target)),
                .bool => return @as(DestType, @floatFromInt(@intFromBool(target))),
                else => {},
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                if (field.type == SourceType) return @unionInit(DestType, field.name, target);
            }
            @compileError("cast to union type '" ++ @typeName(DestType) ++ "' from type '" ++ @typeName(SourceType) ++ "' which is not present in union");
        },
        .bool => return cast(usize, target) != 0,
        else => {},
    }
    return @as(DestType, target);
}
fn castInt(comptime DestType: type, target: anytype) DestType {
    const dest = @typeInfo(DestType).int;
    const source = @typeInfo(@TypeOf(target)).int;
    const Int = @Int(source.signedness, dest.bits);
    if (dest.bits < source.bits)
        return @as(DestType, @bitCast(@as(Int, @truncate(target))))
    else
        return @as(DestType, @bitCast(@as(Int, target)));
}
fn castPtr(comptime DestType: type, target: anytype) DestType {
    return @ptrCast(@alignCast(@constCast(@volatileCast(target))));
}
fn castToPtr(comptime DestType: type, comptime SourceType: type, target: anytype) DestType {
    switch (@typeInfo(SourceType)) {
        .int => {
            return @as(DestType, @ptrFromInt(castInt(usize, target)));
        },
        .comptime_int => {
            if (target < 0)
                return @as(DestType, @ptrFromInt(@as(usize, @bitCast(@as(isize, @intCast(target))))))
            else
                return @as(DestType, @ptrFromInt(@as(usize, @intCast(target))));
        },
        .pointer => {
            return castPtr(DestType, target);
        },
        .@"fn" => {
            return castPtr(DestType, &target);
        },
        .optional => |target_opt| {
            if (@typeInfo(target_opt.child) == .pointer) {
                return castPtr(DestType, target);
            }
        },
        else => {},
    }
    return @as(DestType, target);
}
pub fn sizeof(target: anytype) usize {
    const T: type = if (@TypeOf(target) == type) target else @TypeOf(target);
    switch (@typeInfo(T)) {
        .float, .int, .@"struct", .@"union", .array, .bool, .vector => return @sizeOf(T),
        .@"fn" => {
            return 1;
        },
        .null => return @sizeOf(*anyopaque),
        .void => {
            return 1;
        },
        .@"opaque" => {
            if (T == anyopaque) {
                return 1;
            } else {
                @compileError("Cannot use C sizeof on opaque type " ++ @typeName(T));
            }
        },
        .optional => |opt| {
            if (@typeInfo(opt.child) == .pointer) {
                return sizeof(opt.child);
            } else {
                @compileError("Cannot use C sizeof on non-pointer optional " ++ @typeName(T));
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("Cannot use C sizeof on slice type " ++ @typeName(T));
            }
            if (ptr.size == .one and ptr.is_const and @typeInfo(ptr.child) == .array) {
                const array_info = @typeInfo(ptr.child).array;
                if ((array_info.child == u8 or array_info.child == u16) and array_info.sentinel() == 0) {
                    return (array_info.len + 1) * @sizeOf(array_info.child);
                }
            }
            if (@sizeOf(T) == 0) {
                return @sizeOf(*anyopaque);
            }
            return @sizeOf(T);
        },
        .comptime_float => return @sizeOf(f64), 
        .comptime_int => {
            return @sizeOf(c_int);
        },
        else => @compileError("__helpers.sizeof does not support type " ++ @typeName(T)),
    }
}
pub fn div(a: anytype, b: anytype) ArithmeticConversion(@TypeOf(a), @TypeOf(b)) {
    const ResType = ArithmeticConversion(@TypeOf(a), @TypeOf(b));
    const a_casted = cast(ResType, a);
    const b_casted = cast(ResType, b);
    switch (@typeInfo(ResType)) {
        .float => return a_casted / b_casted,
        .int => return @divTrunc(a_casted, b_casted),
        else => unreachable,
    }
}
pub fn rem(a: anytype, b: anytype) ArithmeticConversion(@TypeOf(a), @TypeOf(b)) {
    const ResType = ArithmeticConversion(@TypeOf(a), @TypeOf(b));
    const a_casted = cast(ResType, a);
    const b_casted = cast(ResType, b);
    switch (@typeInfo(ResType)) {
        .int => {
            if (@typeInfo(ResType).int.signedness == .signed) {
                return signedRemainder(a_casted, b_casted);
            } else {
                return a_casted % b_casted;
            }
        },
        else => unreachable,
    }
}
pub fn CAST_OR_CALL(a: anytype, b: anytype) switch (@typeInfo(@TypeOf(a))) {
    .type => a,
    .@"fn" => |fn_info| fn_info.return_type orelse void,
    else => |info| @compileError("Unexpected argument type: " ++ @tagName(info)),
} {
    switch (@typeInfo(@TypeOf(a))) {
        .type => return cast(a, b),
        .@"fn" => return a(b),
        else => unreachable, 
    }
}
pub inline fn DISCARD(x: anytype) void {
    _ = x;
}
pub fn F_SUFFIX(comptime f: comptime_float) f32 {
    return @as(f32, f);
}
fn L_SUFFIX_ReturnType(comptime number: anytype) type {
    switch (@typeInfo(@TypeOf(number))) {
        .int, .comptime_int => return @TypeOf(promoteIntLiteral(c_long, number, .decimal)),
        .float, .comptime_float => return c_longdouble,
        else => @compileError("Invalid value for L suffix"),
    }
}
pub inline fn L_SUFFIX(comptime number: anytype) L_SUFFIX_ReturnType(number) {
    switch (@typeInfo(@TypeOf(number))) {
        .int, .comptime_int => return promoteIntLiteral(c_long, number, .decimal),
        .float, .comptime_float => @compileError("TODO: c_longdouble initialization from comptime_float not supported"),
        else => @compileError("Invalid value for L suffix"),
    }
}
pub inline fn LL_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_longlong, n, .decimal)) {
    return promoteIntLiteral(c_longlong, n, .decimal);
}
pub inline fn U_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_uint, n, .decimal)) {
    return promoteIntLiteral(c_uint, n, .decimal);
}
pub inline fn UL_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_ulong, n, .decimal)) {
    return promoteIntLiteral(c_ulong, n, .decimal);
}
pub inline fn ULL_SUFFIX(comptime n: comptime_int) @TypeOf(promoteIntLiteral(c_ulonglong, n, .decimal)) {
    return promoteIntLiteral(c_ulonglong, n, .decimal);
}
pub fn WL_CONTAINER_OF(ptr: anytype, sample: anytype, comptime member: []const u8) @TypeOf(sample) {
    return @fieldParentPtr(member, ptr);
}
