const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lz4 = @import("lz4.zig");
const last_literals = 5;
const match_find_limit = 12;
const boundary_sizes = [_]usize{
    0,   1,    2,    3,    4,    5,    6,   7,
    8,   9,    11,   12,   13,   14,   15,  16,
    17,  18,   19,   20,   31,   32,   33,  63,
    64,  65,   254,  255,  256,  269,  270, 271,
    272, 1023, 1024, 4095, 4096, 4097,
};
const Generator = enum {
    random_bytes,
    runs,
    periodic,
    cells,
    words,
    sparse,
    mixed,
    fn fill(gen: Generator, random: std.Random, buf: []u8) void {
        switch (gen) {
            .random_bytes => random.bytes(buf),
            .runs => {
                var i: usize = 0;
                while (i < buf.len) {
                    const run = @min(
                        random.intRangeAtMost(usize, 1, 300),
                        buf.len - i,
                    );
                    @memset(buf[i..][0..run], random.int(u8));
                    i += run;
                }
            },
            .periodic => fillPeriodic(
                random,
                buf,
                random.intRangeAtMost(usize, 1, 40),
            ),
            .cells => {
                var i: usize = 0;
                while (i + 8 <= buf.len) : (i += 8) {
                    const cell = buf[i..][0..8];
                    if (i >= 8 and random.boolean()) {
                        const back = 8 * random.intRangeAtMost(
                            usize,
                            1,
                            @min(i / 8, 256),
                        );
                        cell.* = buf[i - back ..][0..8].*;
                    } else {
                        @memset(cell, 0);
                        cell[0] = ' ' + random.uintLessThan(u8, 95);
                        cell[1] = random.uintLessThan(u8, 4);
                    }
                }
                random.bytes(buf[i..]);
            },
            .words => {
                const words = [_][]const u8{
                    "the",   "terminal", "page",   "compress",
                    "row",   "cell",     "style",  "zig",
                    "lz4",   "block",    "offset", "match",
                    "a",     "of",       "and",    "literal",
                    "0x00",  "0xFF",     "    ",   "\r\n",
                    "-----", "=",        "pub fn", "const",
                };
                var i: usize = 0;
                while (i < buf.len) {
                    const word = words[random.uintLessThan(usize, words.len)];
                    const n = @min(word.len, buf.len - i);
                    @memcpy(buf[i..][0..n], word[0..n]);
                    i += n;
                    if (i < buf.len) {
                        buf[i] = if (random.boolean()) ' ' else '\n';
                        i += 1;
                    }
                }
            },
            .sparse => {
                @memset(buf, 0);
                if (buf.len == 0) return;
                for (0..buf.len / 32 + 1) |_| {
                    const at = random.uintLessThan(usize, buf.len);
                    buf[at] = random.int(u8);
                }
            },
            .mixed => {
                var i: usize = 0;
                while (i < buf.len) {
                    const segment = @min(
                        random.intRangeAtMost(usize, 1, 2048),
                        buf.len - i,
                    );
                    const sub = random.enumValue(Generator);
                    if (sub != .mixed) sub.fill(random, buf[i..][0..segment]);
                    i += segment;
                }
            },
        }
    }
};
fn fillPeriodic(random: std.Random, buf: []u8, period: usize) void {
    if (buf.len == 0) return;
    const head = @min(period, buf.len);
    random.bytes(buf[0..head]);
    for (head..buf.len) |i| buf[i] = buf[i - period];
}
const Workspace = struct {
    input: []u8,
    encoded: []u8,
    decoded: []u8,
    table: *lz4.HashTable,
    fn init(alloc: Allocator, max_input: usize) !Workspace {
        const input = try alloc.alloc(u8, max_input);
        errdefer alloc.free(input);
        const encoded = try alloc.alloc(u8, try lz4.compressBound(max_input));
        errdefer alloc.free(encoded);
        const decoded = try alloc.alloc(u8, max_input + 1);
        errdefer alloc.free(decoded);
        const table = try alloc.create(lz4.HashTable);
        return .{
            .input = input,
            .encoded = encoded,
            .decoded = decoded,
            .table = table,
        };
    }
    fn deinit(ws: *Workspace, alloc: Allocator) void {
        alloc.free(ws.input);
        alloc.free(ws.encoded);
        alloc.free(ws.decoded);
        alloc.destroy(ws.table);
        ws.* = undefined;
    }
};
fn expectCodecProperties(ws: *Workspace, input: []const u8) !usize {
    const encoded_len = try lz4.compress(input, ws.encoded, ws.table);
    try testing.expect(encoded_len <= try lz4.compressBound(input.len));
    const encoded = ws.encoded[0..encoded_len];
    try expectValidBlock(encoded, input.len);
    const output = ws.decoded[0..input.len];
    @memset(output, 0xAA);
    try testing.expectEqual(input.len, try lz4.decompress(encoded, output));
    try testing.expectEqualSlices(u8, input, output);
    if (input.len > 0) {
        try testing.expectError(
            error.OutputTooSmall,
            lz4.decompress(encoded, ws.decoded[0 .. input.len - 1]),
        );
    }
    try testing.expectError(
        error.OutputSizeMismatch,
        lz4.decompress(encoded, ws.decoded[0 .. input.len + 1]),
    );
    return encoded_len;
}
fn expectValidBlock(encoded: []const u8, raw_len: usize) !void {
    var ip: usize = 0;
    var op: usize = 0;
    var last_match_end: usize = 0;
    while (true) {
        try testing.expect(ip < encoded.len);
        const token = encoded[ip];
        ip += 1;
        var literal_len: usize = token >> 4;
        if (literal_len == 15) literal_len += try readExtension(encoded, &ip);
        try testing.expect(encoded.len - ip >= literal_len);
        ip += literal_len;
        op += literal_len;
        if (ip == encoded.len) {
            try testing.expectEqual(raw_len, op);
            if (last_match_end > 0)
                try testing.expect(raw_len - last_match_end >= last_literals);
            return;
        }
        try testing.expect(encoded.len - ip >= 2);
        const offset = std.mem.readInt(u16, encoded[ip..][0..2], .little);
        ip += 2;
        try testing.expect(offset >= 1);
        try testing.expect(offset <= op);
        try testing.expect(op + match_find_limit <= raw_len);
        var match_len: usize = (token & 0x0F) + 4;
        if (token & 0x0F == 15) match_len += try readExtension(encoded, &ip);
        op += match_len;
        try testing.expect(op + last_literals <= raw_len);
        last_match_end = op;
    }
}
fn readExtension(encoded: []const u8, ip: *usize) !usize {
    var total: usize = 0;
    while (true) {
        try testing.expect(ip.* < encoded.len);
        const value = encoded[ip.*];
        ip.* += 1;
        total += value;
        if (value != 255) return total;
    }
}
fn expectMutationSafety(
    ws: *Workspace,
    random: std.Random,
    encoded_len: usize,
    raw_len: usize,
    mutations: usize,
) !void {
    const original = try testing.allocator.dupe(u8, ws.encoded[0..encoded_len]);
    defer testing.allocator.free(original);
    for (0..mutations) |_| {
        const block = ws.encoded[0..encoded_len];
        @memcpy(block, original);
        switch (random.uintLessThan(u8, 4)) {
            0 => for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
                const at = random.uintLessThan(usize, block.len);
                block[at] ^= @as(u8, 1) << random.int(u3);
            },
            1 => block[random.uintLessThan(usize, block.len)] =
                random.int(u8),
            2 => {
                const at = random.uintLessThan(usize, block.len);
                const span = @min(
                    random.intRangeAtMost(usize, 1, 16),
                    block.len - at,
                );
                random.bytes(block[at..][0..span]);
            },
            else => {},
        }
        const len = if (random.boolean())
            random.uintAtMost(usize, block.len)
        else
            block.len;
        _ = lz4.decompress(block[0..len], ws.decoded[0..raw_len]) catch {};
    }
}
const Budget = struct {
    sweep_max: usize,
    sweep_step: usize,
    random_inputs: usize,
    random_max: usize,
    periods: []const usize,
    period_len: usize,
    mutations: usize,
    fn maxInput(budget: Budget) usize {
        return @max(
            budget.random_max,
            @max(budget.period_len, boundary_sizes[boundary_sizes.len - 1]),
        );
    }
};
const light_budget: Budget = .{
    .sweep_max = 96,
    .sweep_step = 1,
    .random_inputs = 24,
    .random_max = 32 * 1024,
    .periods = &.{ 1, 2, 3, 4, 8, 9, 17, 65534, 65535, 65536, 65537 },
    .period_len = 160 * 1024,
    .mutations = 64,
};
const exhaustive_budget: Budget = .{
    .sweep_max = 2048,
    .sweep_step = 1,
    .random_inputs = 512,
    .random_max = 512 * 1024,
    .periods = &.{
        1,     2,     3,    4,     5,     6,     7,     8,
        9,     10,    11,   12,    13,    14,    15,    16,
        17,    18,    19,   23,    24,    31,    32,    33,
        48,    63,    64,   65,    127,   128,   255,   256,
        257,   4095,  4096, 32768, 65533, 65534, 65535, 65536,
        65537, 65538,
    },
    .period_len = 320 * 1024,
    .mutations = 4096,
};
fn runSuite(budget: Budget, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var ws: Workspace = try .init(testing.allocator, budget.maxInput());
    defer ws.deinit(testing.allocator);
    inline for (@typeInfo(Generator).@"enum".fields) |field| {
        const gen: Generator = @enumFromInt(field.value);
        for (boundary_sizes) |size| {
            const input = ws.input[0..size];
            gen.fill(random, input);
            _ = try expectCodecProperties(&ws, input);
        }
        var size: usize = 0;
        while (size <= budget.sweep_max) : (size += budget.sweep_step) {
            const input = ws.input[0..size];
            gen.fill(random, input);
            _ = try expectCodecProperties(&ws, input);
        }
    }
    for (0..budget.random_inputs) |_| {
        const gen = random.enumValue(Generator);
        const scale = random.float(f64);
        const size: usize = @intFromFloat(
            scale * scale * @as(f64, @floatFromInt(budget.random_max)),
        );
        const input = ws.input[0..size];
        gen.fill(random, input);
        const encoded_len = try expectCodecProperties(&ws, input);
        try expectMutationSafety(
            &ws,
            random,
            encoded_len,
            input.len,
            budget.mutations / budget.random_inputs + 1,
        );
    }
    for (budget.periods) |period| {
        const input = ws.input[0..budget.period_len];
        fillPeriodic(random, input, period);
        _ = try expectCodecProperties(&ws, input);
    }
    {
        const input = ws.input[0..@min(16 * 1024, budget.random_max)];
        Generator.words.fill(random, input);
        const encoded_len = try expectCodecProperties(&ws, input);
        try expectMutationSafety(
            &ws,
            random,
            encoded_len,
            input.len,
            budget.mutations,
        );
        for (0..encoded_len) |prefix| {
            _ = lz4.decompress(
                ws.encoded[0..prefix],
                ws.decoded[0..input.len],
            ) catch {};
        }
    }
}
test "lz4 differential light" {
    try runSuite(light_budget, 0x4C5A_3403);
}
test "lz4 differential exhaustive" {
    if (!std.testing.environ.containsConstant("WASP_LZ4_SLOW"))
        return error.SkipZigTest;
    for (0..4) |seed| try runSuite(exhaustive_budget, 0x4C5A_4000 + seed);
}
