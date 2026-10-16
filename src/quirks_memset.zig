const std = @import("std");
const builtin = @import("builtin");
comptime {
    const linkage: std.builtin.GlobalLinkage = switch (builtin.output_mode) {
        .Exe => .strong,
        .Lib => switch (builtin.link_mode) {
            .dynamic => .strong,
            .static => .weak,
        },
        .Obj => .weak,
    };
    const enabled =
        std.simd.suggestVectorLength(u8) != null and
        builtin.object_format != .c and
        !(linkage == .weak and builtin.object_format == .coff);
    if (enabled) @export(&memset, .{
        .name = "memset",
        .linkage = linkage,
        .visibility = .hidden,
    });
}
const vec_bytes = @min(128, 2 * (std.simd.suggestVectorLength(u8) orelse 8));
const zva_enabled = builtin.cpu.arch == .aarch64 and
    builtin.os.tag != .freestanding;
const zva_threshold = 16384;
fn memset(dest: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len == 0) return dest;
    const d = dest.?;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    if (len >= vec_bytes) {
        if (comptime zva_enabled) {
            if (len >= zva_threshold and byte == 0) zva: {
                if (zvaSize() != 64) break :zva;
                const splat64: @Vector(64, u8) = @splat(0);
                const addr = @intFromPtr(d);
                const aligned = std.mem.alignForward(usize, addr, 64);
                d[0..64].* = splat64;
                var p: [*]u8 = @ptrFromInt(aligned);
                const end_addr = addr + len;
                while (@intFromPtr(p) + 64 <= end_addr) : (p += 64) {
                    asm volatile ("dc zva, %[ptr]"
                        :
                        : [ptr] "r" (p),
                        : .{ .memory = true });
                }
                d[len - 64 ..][0..64].* = splat64;
                return dest;
            }
        }
        const splat: @Vector(vec_bytes, u8) = @splat(byte);
        var i: usize = 0;
        while (i + vec_bytes <= len) : (i += vec_bytes) {
            d[i..][0..vec_bytes].* = splat;
            asm volatile ("" ::: .{ .memory = true });
        }
        if (i != len) d[len - vec_bytes ..][0..vec_bytes].* = splat;
        return dest;
    }
    comptime std.debug.assert(vec_bytes <= 128);
    if (comptime vec_bytes > 64) {
        if (len >= 64) {
            const splat64: @Vector(64, u8) = @splat(byte);
            d[0..64].* = splat64;
            d[len - 64 ..][0..64].* = splat64;
            return dest;
        }
    }
    if (len >= 16) {
        const splat16: @Vector(16, u8) = @splat(byte);
        d[0..16].* = splat16;
        d[len - 16 ..][0..16].* = splat16;
        if (len > 32) {
            d[16..32].* = splat16;
            d[len - 32 ..][0..16].* = splat16;
        }
        return dest;
    }
    if (len >= 8) {
        const splat8: @Vector(8, u8) = @splat(byte);
        d[0..8].* = splat8;
        d[len - 8 ..][0..8].* = splat8;
        return dest;
    }
    if (len >= 4) {
        const splat4: @Vector(4, u8) = @splat(byte);
        d[0..4].* = splat4;
        d[len - 4 ..][0..4].* = splat4;
        return dest;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        d[i] = byte;
        asm volatile ("" ::: .{ .memory = true });
    }
    return dest;
}
var zva_size: std.atomic.Value(usize) = .init(0);
fn zvaSize() usize {
    const cached = zva_size.load(.monotonic);
    if (cached != 0) return cached;
    const dczid = asm ("mrs %[out], dczid_el0"
        : [out] "=r" (-> u64),
    );
    const size: usize = if (dczid & 0x10 != 0)
        1
    else
        @as(usize, 4) << @intCast(dczid & 0xF);
    zva_size.store(size, .monotonic);
    return size;
}
test memset {
    const testing = std.testing;
    var buf: [4 * vec_bytes + 33]u8 = undefined;
    for (0..vec_bytes + 1) |offset| {
        for (0..buf.len - offset) |len| {
            for ([_]u8{ 0x00, 0x5C, 0xFF }) |c| {
                @memset(&buf, 0xAA);
                const region = buf[offset..][0..len];
                const ret = memset(region.ptr, c, len);
                try testing.expectEqual(region.ptr, ret.?);
                for (buf[0..offset]) |b| try testing.expectEqual(0xAA, b);
                for (region) |b| try testing.expectEqual(c, b);
                for (buf[offset + len ..]) |b| try testing.expectEqual(0xAA, b);
            }
        }
    }
    try testing.expectEqual(null, memset(null, 0x11, 0));
    var one: [1]u8 = .{0xAA};
    _ = memset(&one, 0x11, 0);
    try testing.expectEqual(0xAA, one[0]);
}
test "memset truncates C int fill value" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    _ = memset(&buf, -1, buf.len);
    for (buf) |b| try testing.expectEqual(0xFF, b);
    _ = memset(&buf, 0x1234, buf.len);
    for (buf) |b| try testing.expectEqual(0x34, b);
}
test "memset large zero fills (dc zva path)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const buf = try alloc.alloc(u8, 2 * zva_threshold + 66);
    defer alloc.free(buf);
    for ([_]usize{
        zva_threshold - 1,
        zva_threshold,
        zva_threshold + 63,
        2 * zva_threshold,
    }) |len| {
        for (0..65) |offset| {
            @memset(buf, 0xAA);
            const region = buf[1 + offset ..][0..len];
            _ = memset(region.ptr, 0x00, len);
            for (buf[0 .. 1 + offset]) |b| try testing.expectEqual(0xAA, b);
            for (region) |b| try testing.expectEqual(0x00, b);
            for (buf[1 + offset + len ..]) |b| try testing.expectEqual(0xAA, b);
        }
    }
    @memset(buf, 0xAA);
    _ = memset(buf.ptr + 1, 0x5C, zva_threshold);
    try testing.expectEqual(0xAA, buf[0]);
    for (buf[1 .. 1 + zva_threshold]) |b| try testing.expectEqual(0x5C, b);
    try testing.expectEqual(0xAA, buf[1 + zva_threshold]);
}
