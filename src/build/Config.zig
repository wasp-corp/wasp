const Config = @This();
const std = @import("std");
const builtin = @import("builtin");
const ApprtRuntime = @import("../app/rt.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const XCFrameworkTarget = @import("xcframework.zig").Target;
const WasmTarget = @import("../os/wasm/target.zig").Target;
const expandPath = @import("../os/path.zig").expand;
const gtk = @import("gtk.zig");
const GitVersion = @import("GitVersion.zig");
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
xcframework_target: XCFrameworkTarget = .universal,
wasm_target: WasmTarget,
app_runtime: ApprtRuntime = .none,
renderer: RendererBackend = .opengl,
font_backend: FontBackend = .freetype,
x11: bool = false,
wayland: bool = false,
sentry: bool = true,
simd: bool = true,
i18n: bool = true,
wasm_shared: bool = true,
exe_entrypoint: ExeEntrypoint = .wasp,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
lib_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
pie: bool = false,
strip: bool = false,
patchelf: ?PatchElf = null,
flatpak: bool = false,
snap: bool = false,
emit_bench: bool = false,
emit_docs: bool = false,
emit_exe: bool = false,
emit_helpgen: bool = false,
emit_lib_vt: bool = false,
emit_macos_app: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = false,
emit_xcframework: bool = false,
emit_webdata: bool = false,
emit_unicode_table_gen: bool = false,
vt_features: TerminalBuildOptions.Features = .{},
is_dep: bool = false,
env: *const std.process.Environ.Map,
pub fn init(b: *std.Build, appVersion: []const u8, libVersion: []const u8) !Config {
    const optimize = b.standardOptimizeOption(.{});
    const is_dep = b.dep_prefix.len > 0;
    const emit_lib_vt = b.option(
        bool,
        "emit-lib-vt",
        "Set defaults for a libwasp-vt-only build (disables xcframework, macOS app, and docs).",
    ) orelse is_dep;
    const target = target: {
        var result = b.standardTargetOptions(.{});
        if (result.result.os.tag == .macos and
            builtin.target.os.tag.isDarwin())
        {
            result = genericMacOSTarget(b, result.query.cpu_arch);
        }
        if (result.result.os.tag == .windows and
            result.query.abi == null)
        {
            var query = result.query;
            query.abi = .msvc;
            result = b.resolveTargetQuery(query);
        }
        if (result.result.cpu.arch.isWasm() and
            result.query.cpu_model == .determined_by_arch_os and
            result.query.cpu_features_add.isEmpty() and
            result.query.cpu_features_sub.isEmpty())
        {
            var query = result.query;
            query.cpu_features_add.addFeature(
                @intFromEnum(std.Target.wasm.Feature.simd128),
            );
            result = b.resolveTargetQuery(query);
        }
        if (result.result.os.tag == .ios and !emit_lib_vt) {
            std.log.err(
                "iOS is not a supported target for the full Wasp build; " ++
                    "only libwasp-vt supports iOS (-Demit-lib-vt)",
                .{},
            );
            return error.UnsupportedTarget;
        }
        if (result.query.os_version_min == null) {
            result.query.os_version_min = if (emit_lib_vt)
                osVersionMinLibVt(result.result.os.tag)
            else
                osVersionMin(result.result.os.tag);
        }
        break :target result;
    };
    const system_package = b.graph.system_package_mode;
    const wasm_target: WasmTarget = .browser;
    const gtk_targets = gtk.targets(b);
    const env = &b.graph.environ_map;
    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = wasm_target,
        .is_dep = is_dep,
        .env = env,
    };
    config.xcframework_target = b.option(
        XCFrameworkTarget,
        "xcframework-target",
        "The target for the xcframework.",
    ) orelse .universal;
    config.font_backend = b.option(
        FontBackend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse FontBackend.default(target.result, wasm_target);
    config.app_runtime = b.option(
        ApprtRuntime,
        "app-runtime",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse ApprtRuntime.default(target.result);
    config.renderer = b.option(
        RendererBackend,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse RendererBackend.default(target.result, wasm_target);
    config.flatpak = b.option(
        bool,
        "flatpak",
        "Build for Flatpak (integrates with Flatpak APIs). Only has an effect targeting Linux.",
    ) orelse false;
    config.snap = b.option(
        bool,
        "snap",
        "Build for Snap (do specific Snap operations). Only has an effect targeting Linux.",
    ) orelse false;
    config.sentry = b.option(
        bool,
        "sentry",
        "Build with Sentry crash reporting. Default for macOS is true, false for any other system.",
    ) orelse sentry: {
        switch (target.result.os.tag) {
            .macos, .ios => break :sentry true,
            else => break :sentry false,
        }
    };
    config.simd = b.option(
        bool,
        "simd",
        "Build with SIMD-accelerated code paths. Results in significant performance improvements.",
    ) orelse simd: {
        if (target.result.cpu.arch.isWasm() or
            target.result.os.tag == .freestanding) break :simd false;
        break :simd true;
    };
    config.wayland = b.option(
        bool,
        "gtk-wayland",
        "Enables linking against Wayland libraries when using the GTK rendering backend.",
    ) orelse gtk_targets.wayland;
    config.x11 = b.option(
        bool,
        "gtk-x11",
        "Enables linking against X11 libraries when using the GTK rendering backend.",
    ) orelse gtk_targets.x11;
    config.i18n = b.option(
        bool,
        "i18n",
        "Enables gettext-based internationalization. Enabled by default only for macOS, and other Unix-like systems like Linux and FreeBSD when using glibc.",
    ) orelse switch (target.result.os.tag) {
        .macos, .ios => true,
        .linux, .freebsd => target.result.isGnuLibC(),
        else => false,
    };
    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );
    config.version = if (version_string) |v|
        try std.SemanticVersion.parse(v)
    else version: {
        const app_version = try std.SemanticVersion.parse(appVersion);
        if (is_dep) break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
        };
        const vsn = GitVersion.detect(b) catch |err| switch (err) {
            error.GitNotFound,
            error.GitNotRepository,
            => break :version .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
                .pre = "dev",
                .build = "0000000",
            },
            else => return err,
        };
        if (vsn.tag) |tag| {
            if (!std.mem.eql(u8, tag, "tip")) {
                const expected = b.fmt("v{d}.{d}.{d}", .{
                    app_version.major,
                    app_version.minor,
                    app_version.patch,
                });
                if (!std.mem.eql(u8, tag, expected)) {
                    @panic("tagged releases must be in vX.Y.Z format matching build.zig");
                }
                break :version .{
                    .major = app_version.major,
                    .minor = app_version.minor,
                    .patch = app_version.patch,
                };
            }
        }
        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = vsn.branch,
            .build = vsn.short_hash,
        };
    };
    const lib_version_string = b.option(
        []const u8,
        "lib-version-string",
        "A specific version string to use for the build of libwasp-vt. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );
    config.lib_version = if (lib_version_string) |v|
        try std.SemanticVersion.parse(v)
    else
        try std.SemanticVersion.parse(libVersion);
    if (b.option(
        []const u8,
        "patch-interp",
        "Inject the supplied path as the dynamic linker in the built binary. " ++
            "Under Nix, this defaults to the dynamic linker found in PATH.",
    )) |interp| {
        PatchElf.setInterp(&config, interp);
    } else patch_interp: {
        if (!(target.result.os.tag == .linux) or !target.query.isNativeCpu()) break :patch_interp;
        if (env.get("IN_NIX_SHELL") == null) break :patch_interp;
        if (b.findProgram(&.{"ld.so"}, &.{})) |ld_so| {
            PatchElf.setInterp(
                &config,
                std.Io.Dir.realPathFileAbsoluteAlloc(b.graph.io, ld_so, b.allocator) catch break :patch_interp,
            );
        } else |_| {}
    }
    if (b.option(
        []const u8,
        "patch-rpath",
        "Inject the supplied colon-delimited search path as the rpath in the built binary. " ++
            "This defaults to LD_LIBRARY_PATH if we're in a Nix shell environment.",
    )) |rpath| {
        PatchElf.setRpath(&config, rpath);
    } else patch_rpath: {
        if (!(target.result.os.tag == .linux) or !target.query.isNativeCpu()) break :patch_rpath;
        if (env.get("IN_NIX_SHELL") == null) break :patch_rpath;
        if (env.get("LD_LIBRARY_PATH")) |ld_library_path| {
            if (ld_library_path.len > 0) {
                PatchElf.setRpath(&config, ld_library_path);
            }
        }
    }
    config.pie = b.option(
        bool,
        "pie",
        "Build a Position Independent Executable. Default true for system packages.",
    ) orelse system_package;
    config.strip = b.option(
        bool,
        "strip",
        "Strip the final executable. Default true for fast and small releases",
    ) orelse switch (optimize) {
        .Debug => false,
        .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };
    config.emit_lib_vt = emit_lib_vt;
    config.vt_features = features: {
        const list = b.option(
            []const u8,
            "vt-features",
            "Comma-separated libwasp-vt feature modifications applied " ++
                "to the default all-enabled set, -Dcpu style: `+feature` " ++
                "or `feature` enables, `-feature` disables, and `all` " ++
                "means every feature (e.g. `-all,+render-state` for a " ++
                "render-only build). Only applies to lib artifacts.",
        ) orelse break :features .{};
        break :features TerminalBuildOptions.Features.parse(list) catch {
            var valid: std.ArrayList(u8) = .empty;
            inline for (@typeInfo(TerminalBuildOptions.Features).@"struct".fields) |field| {
                if (valid.items.len > 0) try valid.appendSlice(b.allocator, ", ");
                try valid.appendSlice(b.allocator, field.name);
            }
            std.log.err(
                "-Dvt-features={s} contains an unknown feature. Valid features: all, {s}",
                .{ list, valid.items },
            );
            return error.UnknownVtFeature;
        };
    };
    config.emit_exe = b.option(
        bool,
        "emit-exe",
        "Build and install main executables with 'build'",
    ) orelse !config.emit_lib_vt;
    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;
    config.emit_unicode_table_gen = b.option(
        bool,
        "emit-unicode-table-gen",
        "Build and install executables that generate unicode tables with 'build'",
    ) orelse false;
    config.emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;
    config.emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;
    config.emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        if (config.emit_bench or
            config.emit_test_exe or
            config.emit_helpgen or
            config.emit_lib_vt) break :emit_docs false;
        if (system_package) break :emit_docs true;
        const path = expandPath(b.graph.io, b.allocator, &b.graph.environ_map, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };
    config.emit_terminfo = b.option(
        bool,
        "emit-terminfo",
        "Install Wasp terminfo source file",
    ) orelse switch (target.result.os.tag) {
        .windows => true,
        else => switch (optimize) {
            .Debug => true,
            .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
        },
    };
    config.emit_termcap = b.option(
        bool,
        "emit-termcap",
        "Install Wasp termcap file",
    ) orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };
    config.emit_themes = b.option(
        bool,
        "emit-themes",
        "Install bundled iTerm2-Color-Schemes Wasp themes",
    ) orelse true;
    config.emit_webdata = b.option(
        bool,
        "emit-webdata",
        "Build the website data for the website.",
    ) orelse false;
    config.emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build and install the xcframework for the macOS library.",
    ) orelse emit_xcfw: {
        if (!builtin.target.os.tag.isDarwin() or target.result.os.tag != .macos)
            break :emit_xcfw false;
        if (config.emit_lib_vt) {
            const path = expandPath(b.graph.io, b.allocator, &b.graph.environ_map, "xcodebuild") catch
                break :emit_xcfw false;
            defer if (path) |p| b.allocator.free(p);
            break :emit_xcfw path != null;
        }
        break :emit_xcfw config.app_runtime == .none and
            (!config.emit_bench and
                !config.emit_test_exe and
                !config.emit_helpgen);
    };
    config.emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the macOS app bundle.",
    ) orelse !config.emit_lib_vt and config.emit_xcframework;
    {
        for (&[_][]const u8{
            "freetype",
            "harfbuzz",
            "fontconfig",
            "libpng",
            "zlib",
            "oniguruma",
        }) |dep| {
            _ = b.systemIntegrationOption(
                dep,
                .{
                    .default = if (target.result.os.tag.isDarwin()) false else null,
                },
            );
        }
        for (&[_][]const u8{
            "glslang",
            "spirv-cross",
            "simdutf",
        }) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = false });
        }
        for (&[_][]const u8{"gtk4-layer-shell"}) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = true });
        }
    }
    return config;
}
const PatchElf = struct {
    interp: ?[]const u8 = null,
    rpath: ?[]const u8 = null,
    fn setInterp(config: *Config, interp: []const u8) void {
        if (config.patchelf) |*patchelf| {
            patchelf.interp = interp;
            return;
        }
        config.patchelf = .{ .interp = interp };
    }
    fn setRpath(config: *Config, rpath: []const u8) void {
        if (config.patchelf) |*patchelf| {
            patchelf.rpath = rpath;
            return;
        }
        config.patchelf = .{ .rpath = rpath };
    }
};
pub fn addPatchElf(self: *const Config, artifact: *std.Build.Step.Compile, step: *std.Build.Step) void {
    const b = artifact.step.owner;
    std.debug.assert(b == step.owner);
    if (self.patchelf) |patchelf| {
        const run = std.Build.Step.Run.create(b, "patchelf");
        run.addArgs(&.{"patchelf"});
        if (patchelf.interp) |interp| run.addArgs(&.{ "--set-interpreter", interp });
        if (patchelf.rpath) |rpath| run.addArgs(&.{ "--set-rpath", rpath });
        run.addArtifactArg(artifact);
        step.dependOn(&run.step);
    }
}
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    step.addOption(bool, "flatpak", self.flatpak);
    step.addOption(bool, "snap", self.snap);
    step.addOption(bool, "x11", self.x11);
    step.addOption(bool, "wayland", self.wayland);
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(WasmTarget, "wasm_target", self.wasm_target);
    step.addOption(bool, "wasm_shared", self.wasm_shared);
    var app_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
        &app_version_buf,
        "{f}",
        .{self.version},
    ));
    var lib_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "lib_version", self.lib_version);
    step.addOption([:0]const u8, "lib_version_string", try std.fmt.bufPrintZ(
        &lib_version_buf,
        "{f}",
        .{self.lib_version},
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}
pub fn terminalOptions(
    self: *const Config,
    artifact: TerminalBuildOptions.Artifact,
    optimize: std.builtin.OptimizeMode,
) TerminalBuildOptions {
    return .{
        .artifact = artifact,
        .simd = self.simd,
        .oniguruma = true,
        .c_abi = false,
        .features = switch (artifact) {
            .wasp => .{},
            .lib => self.vt_features,
        },
        .version = switch (artifact) {
            .wasp => self.version,
            .lib => self.lib_version,
        },
        .slow_runtime_safety = switch (optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    };
}
pub fn baselineTarget(self: *const Config, io: std.Io) std.Build.ResolvedTarget {
    var q = self.target.query;
    q.cpu_model = .baseline;
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(io, q) catch
            @panic("unable to resolve baseline query"),
    };
}
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        .optimize = undefined,
        .target = undefined,
        .env = undefined,
        .version = options.app_version,
        .flatpak = options.flatpak,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .snap = options.snap,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
        .i18n = options.i18n,
    };
}
pub fn omitFramePointer(self: *const Config) bool {
    if (self.target.result.os.tag.isDarwin()) return false;
    return self.strip;
}
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },
        else => null,
    };
}
pub fn osVersionMinLibVt(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    if (tag == .ios) return .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
    return osVersionMin(tag);
}
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
}
pub const ExeEntrypoint = enum {
    wasp,
    helpgen,
    mdgen_wasp_1,
    mdgen_wasp_5,
    webgen_config,
    webgen_actions,
    webgen_commands,
};
pub const ReleaseChannel = enum {
    tip,
    stable,
};
