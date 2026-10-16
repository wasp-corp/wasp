const Version = @This();
const std = @import("std");
short_hash: []const u8,
changes: bool,
tag: ?[]const u8,
branch: []const u8,
pub fn detect(b: *std.Build) !Version {
    var code: u8 = 0;
    const branch: []const u8 = b: {
        const tmp: []u8 = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--abbrev-ref", "HEAD" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            error.ExitCodeFailure => return error.GitNotRepository,
            else => return err,
        };
        const trimmed = tmp[0..std.mem.trim(u8, tmp, &std.ascii.whitespace).len];
        for (trimmed) |*c| {
            if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
        }
        break :b trimmed;
    };
    const short_hash = short_hash: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };
        break :short_hash std.mem.trim(u8, output, &std.ascii.whitespace);
    };
    const tag = b.runAllowFail(
        &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "describe", "--exact-match", "--tags" },
        &code,
        .ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => "", 
        else => return err,
    };
    _ = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "diff",
        "--quiet",
        "--exit-code",
    }, &code, .ignore) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => {}, 
        else => return err,
    };
    const changes = code != 0;
    return .{
        .short_hash = short_hash,
        .changes = changes,
        .tag = if (tag.len > 0) std.mem.trimEnd(u8, tag, "\r\n ") else null,
        .branch = branch,
    };
}
