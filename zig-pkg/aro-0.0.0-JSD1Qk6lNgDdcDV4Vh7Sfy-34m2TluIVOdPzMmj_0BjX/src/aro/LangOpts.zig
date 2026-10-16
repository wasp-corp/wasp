const std = @import("std");
const Attribute = @import("Attribute.zig");
const char_info = @import("char_info.zig");
const Target = @import("Target.zig");
pub const Compiler = enum {
    clang,
    gcc,
    msvc,
    no,
    pub fn defaultGccVersion(self: Compiler) u32 {
        return switch (self) {
            .clang => 4 * 10_000 + 2 * 100 + 1,
            .no, .gcc => 7 * 10_000 + 1 * 100 + 0,
            .msvc => 0,
        };
    }
};
pub const BoundsSafety = enum {
    none,
    clang,
};
pub const FPEvalMethod = enum(i8) {
    indeterminate = -1,
    source = 0,
    double = 1,
    extended = 2,
};
pub const Standard = enum {
    c89,
    iso9899,
    gnu89,
    c99,
    gnu99,
    c11,
    gnu11,
    c17,
    default,
    gnu17,
    c23,
    gnu23,
    c2y,
    gnu2y,
    const NameMap = std.StaticStringMap(Standard).initComptime(.{
        .{ "c89", .c89 },                .{ "c90", .c89 },          .{ "iso9899:1990", .c89 },
        .{ "iso9899:199409", .iso9899 }, .{ "gnu89", .gnu89 },      .{ "gnu90", .gnu89 },
        .{ "c99", .c99 },                .{ "iso9899:1999", .c99 }, .{ "c9x", .c99 },
        .{ "iso9899:199x", .c99 },       .{ "gnu99", .gnu99 },      .{ "gnu9x", .gnu99 },
        .{ "c11", .c11 },                .{ "iso9899:2011", .c11 }, .{ "c1x", .c11 },
        .{ "iso9899:201x", .c11 },       .{ "gnu11", .gnu11 },      .{ "c17", .c17 },
        .{ "iso9899:2017", .c17 },       .{ "c18", .c17 },          .{ "iso9899:2018", .c17 },
        .{ "gnu17", .gnu17 },            .{ "gnu18", .gnu17 },      .{ "c23", .c23 },
        .{ "iso9899:2024", .c23 },       .{ "gnu23", .gnu23 },      .{ "c2x", .c23 },
        .{ "gnu2x", .gnu23 },            .{ "c2y", .c2y },          .{ "gnu2y", .gnu23 },
    });
    pub fn atLeast(self: Standard, other: Standard) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
    pub fn isGNU(standard: Standard) bool {
        return switch (standard) {
            .gnu89, .gnu99, .gnu11, .default, .gnu17, .gnu23, .gnu2y => true,
            else => false,
        };
    }
    pub fn isExplicitGNU(standard: Standard) bool {
        return standard.isGNU() and standard != .default;
    }
    pub fn StdCVersionMacro(standard: Standard) ?[]const u8 {
        return switch (standard) {
            .c89, .gnu89 => null,
            .iso9899 => "199409L",
            .c99, .gnu99 => "199901L",
            .c11, .gnu11 => "201112L",
            .default, .c17, .gnu17 => "201710L",
            .c23, .gnu23 => "202311L",
            .c2y, .gnu2y => "202400L",
        };
    }
    pub fn codepointAllowedInIdentifier(standard: Standard, codepoint: u21, is_start: bool) bool {
        if (is_start) {
            return if (standard.atLeast(.c23))
                char_info.isXidStart(codepoint)
            else if (standard.atLeast(.c11))
                char_info.isC11IdChar(codepoint) and !char_info.isC11DisallowedInitialIdChar(codepoint)
            else
                char_info.isC99IdChar(codepoint) and !char_info.isC99DisallowedInitialIDChar(codepoint);
        } else {
            return if (standard.atLeast(.c23))
                char_info.isXidContinue(codepoint)
            else if (standard.atLeast(.c11))
                char_info.isC11IdChar(codepoint)
            else
                char_info.isC99IdChar(codepoint);
        }
    }
};
pub const ArmLdrex = packed struct(u4) {
    b: bool = false, 
    h: bool = false, 
    w: bool = false, 
    d: bool = false, 
    pub const b_int: u4 = 1;
    pub const h_int: u4 = 2;
    pub const w_int: u4 = 4;
    pub const d_int: u4 = 8;
    pub const none: ArmLdrex = .{};
    pub const all: ArmLdrex = @bitCast(@as(u4, 15));
};
const LangOpts = @This();
emulate: Compiler = .no,
standard: Standard = .default,
short_enums: bool = false,
dollars_in_identifiers: bool = true,
declspec_attrs: bool = false,
ms_extensions: bool = false,
digraphs: ?bool = null,
use_native_half_type: bool = false,
allow_half_args_and_returns: bool = false,
fp_eval_method: ?FPEvalMethod = null,
char_signedness_override: ?std.builtin.Signedness = null,
has_char8_t_override: ?bool = null,
gnu_asm: bool = true,
preserve_comments: bool = false,
preserve_comments_in_macros: bool = false,
gnuc_version: ?u32 = null,
bounds_safety: BoundsSafety = .none,
default_symbol_visibility: Attribute.Args.Visibility = .default,
blocks: bool = false,
arm_ldrex: ?ArmLdrex = null,
has_int24: bool = false,
pthread: bool = false,
pub fn setStandard(self: *LangOpts, name: []const u8) error{InvalidStandard}!void {
    self.standard = Standard.NameMap.get(name) orelse return error.InvalidStandard;
}
pub fn setMSExtensions(self: *LangOpts, enabled: bool) void {
    self.declspec_attrs = enabled;
    self.ms_extensions = enabled;
}
pub fn hasChar8_T(self: *const LangOpts) bool {
    return self.has_char8_t_override orelse self.standard.atLeast(.c23);
}
pub fn hasDigraphs(self: *const LangOpts) bool {
    return self.digraphs orelse self.standard.atLeast(.gnu89);
}
pub fn hasTargetOsMacros(self: *const LangOpts) bool {
    return self.emulate == .no or self.emulate == .clang;
}
pub fn setEmulatedCompiler(self: *LangOpts, compiler: Compiler) void {
    self.emulate = compiler;
    self.setMSExtensions(compiler == .msvc);
}
pub fn setFpEvalMethod(self: *LangOpts, fp_eval_method: FPEvalMethod) void {
    self.fp_eval_method = fp_eval_method;
}
pub fn setCharSignedness(self: *LangOpts, signedness: std.builtin.Signedness) void {
    self.char_signedness_override = signedness;
}
pub fn allowFixedSizedIntSuffixes(self: *const LangOpts) bool {
    return switch (self.emulate) {
        .msvc => true,
        .clang, .no => self.ms_extensions,
        .gcc => false,
    };
}
pub fn setTargetOptions(self: *LangOpts, target: Target) void {
    self.has_int24 = target.cpu.arch == .avr;
    switch (target.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb => {
            {
                const arm_version = if (target.armVersion()) |v| v.version else 6;
                const ldrex: ArmLdrex = switch (arm_version) {
                    6 => if (target.cpu.has(.arm, .mclass))
                        .none
                    else if (target.cpu.has(.arm, .v6k) or target.cpu.has(.arm, .v6kz))
                        .all
                    else
                        .{ .w = true },
                    7, 8 => if (target.cpu.has(.arm, .mclass))
                        .{ .b = true, .h = true, .w = true }
                    else
                        .all,
                    9 => .all,
                    else => .none,
                };
                self.arm_ldrex = ldrex;
            }
        },
        .aarch64, .aarch64_be => {
            self.arm_ldrex = .all;
        },
        else => {},
    }
}
test "ArmLdrex versions" {
    const cases = [_]struct {
        ldrex: ArmLdrex,
        val: u4,
    }{
        .{ .ldrex = .{ .b = true }, .val = 1 },
        .{ .ldrex = .{ .b = true, .h = true }, .val = 3 },
        .{ .ldrex = .{ .b = true, .h = true, .w = true }, .val = 7 },
        .{ .ldrex = .{ .b = true, .h = true, .w = true, .d = true }, .val = 15 },
        .{ .ldrex = .{ .b = true }, .val = ArmLdrex.b_int },
        .{ .ldrex = .{ .h = true }, .val = ArmLdrex.h_int },
        .{ .ldrex = .{ .w = true }, .val = ArmLdrex.w_int },
        .{ .ldrex = .{ .d = true }, .val = ArmLdrex.d_int },
        .{ .ldrex = .none, .val = 0 },
        .{ .ldrex = .all, .val = 15 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.val, @as(u4, @bitCast(c.ldrex)));
    }
}
