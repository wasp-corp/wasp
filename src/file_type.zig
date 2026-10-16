const std = @import("std");
const type_details: []const struct {
    typ: FileType,
    sigs: []const []const ?u8,
    exts: []const []const u8,
} = &.{
    .{
        .typ = .jpeg,
        .sigs = &.{
            &.{ 0xFF, 0xD8, 0xFF, 0xDB },
            &.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01 },
            &.{ 0xFF, 0xD8, 0xFF, 0xEE },
            &.{ 0xFF, 0xD8, 0xFF, 0xE1, null, null, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00 },
            &.{ 0xFF, 0xD8, 0xFF, 0xE0 },
        },
        .exts = &.{ ".jpg", ".jpeg", ".jfif" },
    },
    .{
        .typ = .png,
        .sigs = &.{&.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }},
        .exts = &.{".png"},
    },
    .{
        .typ = .gif,
        .sigs = &.{
            &.{ 'G', 'I', 'F', '8', '7', 'a' },
            &.{ 'G', 'I', 'F', '8', '9', 'a' },
        },
        .exts = &.{".gif"},
    },
    .{
        .typ = .bmp,
        .sigs = &.{&.{ 'B', 'M' }},
        .exts = &.{".bmp"},
    },
    .{
        .typ = .qoi,
        .sigs = &.{&.{ 'q', 'o', 'i', 'f' }},
        .exts = &.{".qoi"},
    },
    .{
        .typ = .webp,
        .sigs = &.{
            &.{ 0x52, 0x49, 0x46, 0x46, null, null, null, null, 0x57, 0x45, 0x42, 0x50 },
        },
        .exts = &.{".webp"},
    },
};
pub const FileType = enum {
    jpeg,
    png,
    gif,
    bmp,
    qoi,
    webp,
    unknown,
    pub fn detect(contents: []const u8) FileType {
        inline for (type_details) |typ| {
            inline for (typ.sigs) |signature| {
                if (contents.len >= signature.len) {
                    for (contents[0..signature.len], signature) |f, sig| {
                        if (sig) |s| if (f != s) break;
                    } else {
                        return typ.typ;
                    }
                }
            }
        }
        return .unknown;
    }
    pub fn guessFromExtension(extension: []const u8) FileType {
        inline for (type_details) |typ| {
            inline for (typ.exts) |ext| {
                if (std.ascii.eqlIgnoreCase(extension, ext)) return typ.typ;
            }
        }
        return .unknown;
    }
};
