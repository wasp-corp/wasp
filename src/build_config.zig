const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const apprt = @import("apprt.zig");
const font = @import("font/root.zig");
const rendererpkg = @import("renderer.zig");
const BuildConfig = @import("build/Config.zig");
pub const ReleaseChannel = BuildConfig.ReleaseChannel;
pub const version = options.app_version;
pub const version_string = options.app_version_string;
pub const release_channel = std.meta.stringToEnum(ReleaseChannel, @tagName(options.release_channel)).?;
pub const mode_string = mode: {
    const m = @tagName(builtin.mode);
    if (std.mem.lastIndexOfScalar(u8, m, '.')) |i| break :mode m[i..];
    break :mode m;
};
pub const artifact = Artifact.detect();
const config = BuildConfig.fromOptions();
pub const exe_entrypoint = config.exe_entrypoint;
pub const flatpak = options.flatpak;
pub const snap = options.snap;
pub const app_runtime: apprt.Runtime = config.app_runtime;
pub const font_backend: font.Backend = config.font_backend;
pub const renderer: rendererpkg.Backend = config.renderer;
pub const i18n: bool = config.i18n;
pub const bundle_id = "com.mitchellh.wasp";
pub const slow_runtime_safety = std.debug.runtime_safety and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe,
    .ReleaseSmall,
    .ReleaseFast,
    => false,
};
pub const Artifact = enum {
    exe,
    lib,
    wasm_module,
    pub fn detect() Artifact {
        if (builtin.target.cpu.arch.isWasm()) {
            assert(builtin.output_mode == .Obj);
            assert(builtin.link_mode == .Static);
            return .wasm_module;
        }
        return switch (builtin.output_mode) {
            .Exe => .exe,
            .Lib => .lib,
            else => {
                @compileLog(builtin.output_mode);
                @compileError("unsupported artifact output mode");
            },
        };
    }
};
pub const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
