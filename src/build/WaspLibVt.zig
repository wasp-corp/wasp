const WaspLibVt = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const RunStep = std.Build.Step.Run;
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const LibsystemOverrideStep = @import("LibsystemOverrideStep.zig");
const Config = @import("Config.zig");
const WaspZig = @import("WaspZig.zig");
const LipoStep = @import("LipoStep.zig");
const SharedDeps = @import("SharedDeps.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
step: *std.Build.Step,
artifact: *std.Build.Step,
kind: Kind,
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: ?std.Build.LazyPath,
pkg_config_static: ?std.Build.LazyPath,
const Kind = enum {
    wasm,
    shared,
    static,
};
pub fn initWasm(
    b: *std.Build,
    zig: *const WaspZig,
) !WaspLibVt {
    const target = zig.vt.resolved_target.?;
    assert(target.result.cpu.arch.isWasm());
    const exe = b.addExecutable(.{
        .name = "wasp-vt",
        .root_module = zig.vt_c,
        .version = zig.version,
    });
    exe.rdynamic = true;
    exe.export_table = true;
    exe.entry = .disabled;
    exe.stack_size = 128 * 1024;
    const patch_run = patch: {
        const patcher = b.addExecutable(.{
            .name = "wasm_patch_growable_table",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/wasm_patch_growable_table.zig"),
                .target = b.graph.host,
            }),
        });
        break :patch b.addRunArtifact(patcher);
    };
    patch_run.addFileArg(exe.getEmittedBin());
    const output = patch_run.addOutputFileArg("wasp-vt.wasm");
    const artifact_install = b.addInstallFileWithDir(
        output,
        .bin,
        "wasp-vt.wasm",
    );
    return .{
        .step = &patch_run.step,
        .artifact = &artifact_install.step,
        .kind = .wasm,
        .output = output,
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}
pub fn initStatic(
    b: *std.Build,
    zig: *const WaspZig,
) !WaspLibVt {
    return initLib(b, zig, .static);
}
pub fn initShared(
    b: *std.Build,
    zig: *const WaspZig,
) !WaspLibVt {
    const target = zig.vt.resolved_target.?;
    if (@import("apple_sdk").nativeLink.available(target)) {
        return initLibApple(b, zig);
    }
    return initLib(b, zig, .dynamic);
}
pub const ApplePlatform = enum {
    macos_universal,
    ios,
    ios_simulator,
    const sdk_platforms = [_]struct {
        os_tag: std.Target.Os.Tag,
        device: ApplePlatform,
        simulator: ApplePlatform,
    }{
        .{ .os_tag = .ios, .device = .ios, .simulator = .ios_simulator },
    };
};
pub const AppleLibs = std.EnumMap(ApplePlatform, WaspLibVt);
pub fn initStaticAppleUniversal(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    zig: *const WaspZig,
) !AppleLibs {
    var result: AppleLibs = .{};
    const aarch64_zig = try zig.retarget(
        b,
        cfg,
        deps,
        Config.genericMacOSTarget(b, .aarch64),
    );
    const x86_64_zig = try zig.retarget(
        b,
        cfg,
        deps,
        Config.genericMacOSTarget(b, .x86_64),
    );
    const aarch64 = try initStatic(b, &aarch64_zig);
    const x86_64 = try initStatic(b, &x86_64_zig);
    const universal = LipoStep.create(b, .{
        .name = "wasp-vt",
        .out_name = "libwasp-vt.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });
    result.put(.macos_universal, .{
        .step = universal.step,
        .artifact = universal.step,
        .kind = .static,
        .output = universal.output,
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    });
    for (ApplePlatform.sdk_platforms) |p| {
        const target_query: std.Target.Query = .{
            .cpu_arch = .aarch64,
            .os_tag = p.os_tag,
            .os_version_min = Config.osVersionMinLibVt(p.os_tag),
        };
        if (detectAppleSDK(
            b.graph.io,
            b.allocator,
            &b.graph.environ_map,
            b.resolveTargetQuery(target_query).result,
        )) {
            const dev_zig = try zig.retarget(b, cfg, deps, b.resolveTargetQuery(target_query));
            result.put(p.device, try initStatic(b, &dev_zig));
            const sim_zig = try zig.retarget(b, cfg, deps, b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = p.os_tag,
                .os_version_min = Config.osVersionMinLibVt(p.os_tag),
                .abi = .simulator,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
            }));
            result.put(p.simulator, try initStatic(b, &sim_zig));
        }
    }
    return result;
}
fn initLib(
    b: *std.Build,
    zig: *const WaspZig,
    linkage: std.builtin.LinkMode,
) !WaspLibVt {
    const kind: Kind = switch (linkage) {
        .static => .static,
        .dynamic => .shared,
    };
    const target = zig.vt.resolved_target.?;
    const lib = b.addLibrary(.{
        .name = if (kind == .static) "wasp-vt-static" else "wasp-vt",
        .linkage = linkage,
        .root_module = zig.vt_c,
        .version = zig.version,
    });
    lib.installHeadersDirectory(
        b.path("include/wasp"),
        "wasp",
        .{ .include_extensions = &.{".h"} },
    );
    if (kind == .static) {
        lib.bundle_compiler_rt = true;
        lib.bundle_ubsan_rt = true;
        lib.root_module.pic = target.result.os.tag != .freestanding;
    }
    if (target.result.os.tag == .windows) {
        lib.bundle_ubsan_rt = false;
        if (kind == .static) {
            if (target.result.abi == .msvc) {
                lib.root_module.stack_protector = false;
            }
            lib.root_module.linkSystemLibrary("ntdll", .{});
            lib.root_module.linkSystemLibrary("kernel32", .{});
        }
    }
    if (lib.rootModuleTarget().abi.isAndroid()) {
        lib.link_z_max_page_size = 16384;
        try @import("android_ndk").addPaths(b, lib);
    }
    if (lib.rootModuleTarget().os.tag.isDarwin()) {
        lib.use_llvm = true;
        lib.headerpad_max_install_names = true;
        if (builtin.os.tag.isDarwin()) try @import("apple_sdk").addPaths(b, lib);
    }
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (kind != .shared) break :dsymutil null;
        if (!target.result.os.tag.isDarwin()) break :dsymutil null;
        const dsymutil = RunStep.create(b, "dsymutil");
        dsymutil.addArgs(&.{"dsymutil"});
        dsymutil.addFileArg(lib.getEmittedBin());
        dsymutil.addArgs(&.{"-o"});
        const output = dsymutil.addOutputFileArg("libwasp-vt.dSYM");
        break :dsymutil output;
    };
    const pcs: ?PkgConfigFiles = if (kind == .shared)
        pkgConfigFiles(b, zig, target.result.os.tag)
    else
        null;
    if (kind == .static and
        zig.simd_libs.items.len > 0)
    {
        var sources: SharedDeps.LazyPathList = .empty;
        try sources.append(b.allocator, lib.getEmittedBin());
        try sources.appendSlice(b.allocator, zig.simd_libs.items);
        const combined = CombineArchivesStep.create(b, target, "wasp-vt", sources.items);
        combined.step.dependOn(&lib.step);
        const override = LibsystemOverrideStep.create(
            b,
            target,
            combined.output,
            "libwasp-vt-fat.a",
        );
        return .{
            .step = override.step orelse combined.step,
            .artifact = &b.addInstallArtifact(lib, .{}).step,
            .kind = kind,
            .output = override.output,
            .dsym = dsymutil,
            .pkg_config = if (pcs) |v| v.shared else null,
            .pkg_config_static = if (pcs) |v| v.static else null,
        };
    }
    const override: LibsystemOverrideStep.Result = if (kind == .static) LibsystemOverrideStep.create(
        b,
        target,
        lib.getEmittedBin(),
        "libwasp-vt-static.a",
    ) else .{
        .step = null,
        .output = lib.getEmittedBin(),
    };
    return .{
        .step = override.step orelse &lib.step,
        .artifact = &b.addInstallArtifact(lib, .{}).step,
        .kind = kind,
        .output = override.output,
        .dsym = dsymutil,
        .pkg_config = if (pcs) |v| v.shared else null,
        .pkg_config_static = if (pcs) |v| v.static else null,
    };
}
fn initLibApple(
    b: *std.Build,
    zig: *const WaspZig,
) !WaspLibVt {
    const target = zig.vt.resolved_target.?;
    assert(target.result.os.tag.isDarwin());
    const static = try initStatic(b, zig);
    const exports = b.addWriteFiles().add(
        "libwasp-vt.exports",
        "_wasp_*\n",
    );
    const real_name = b.fmt("libwasp-vt.{d}.{d}.{d}.dylib", .{
        zig.version.major,
        zig.version.minor,
        zig.version.patch,
    });
    const soname = b.fmt("libwasp-vt.{d}.dylib", .{zig.version.major});
    const native_link = try @import("apple_sdk").nativeLink.addCommand(
        b,
        "link libwasp-vt with Apple ld",
        target,
    );
    native_link.addArgs(&.{
        "-dynamiclib",
        "-Wl,-all_load",
        "-Wl,-dead_strip",
        "-Wl,-headerpad_max_install_names",
    });
    native_link.addPrefixedFileArg("-Wl,-exported_symbols_list,", exports);
    native_link.addFileArg(static.output);
    native_link.addArgs(&.{
        "-install_name",
        "@rpath/libwasp-vt.dylib",
        "-current_version",
        b.fmt("{d}.{d}.{d}", .{
            zig.version.major,
            zig.version.minor,
            zig.version.patch,
        }),
        "-compatibility_version",
        "1.0.0",
        "-o",
    });
    const output = native_link.addOutputFileArg(real_name);
    const artifact_install = b.addInstallFileWithDir(
        output,
        .lib,
        real_name,
    );
    const soname_install = b.addSystemCommand(&.{
        "/bin/ln",
        "-sf",
        real_name,
        b.getInstallPath(.lib, soname),
    });
    soname_install.step.dependOn(&artifact_install.step);
    const unversioned_install = b.addSystemCommand(&.{
        "/bin/ln",
        "-sf",
        soname,
        b.getInstallPath(.lib, "libwasp-vt.dylib"),
    });
    unversioned_install.step.dependOn(&soname_install.step);
    const headers_install = b.addInstallDirectory(.{
        .source_dir = b.path("include/wasp"),
        .install_dir = .header,
        .install_subdir = "wasp",
        .include_extensions = &.{".h"},
    });
    unversioned_install.step.dependOn(&headers_install.step);
    const dsymutil = RunStep.create(b, "dsymutil");
    dsymutil.addArgs(&.{"dsymutil"});
    dsymutil.addFileArg(output);
    dsymutil.addArgs(&.{"-o"});
    const dsym = dsymutil.addOutputFileArg("libwasp-vt.dSYM");
    const pcs = pkgConfigFiles(b, zig, target.result.os.tag);
    return .{
        .step = &native_link.step,
        .artifact = &unversioned_install.step,
        .kind = .shared,
        .output = output,
        .dsym = dsym,
        .pkg_config = pcs.shared,
        .pkg_config_static = pcs.static,
    };
}
fn libsPrivate(
    zig: *const WaspZig,
) []const u8 {
    return if (zig.vt_c.link_libcpp orelse false) "-lc++" else "";
}
const PkgConfigFiles = struct {
    shared: std.Build.LazyPath,
    static: std.Build.LazyPath,
};
fn pkgConfigFiles(
    b: *std.Build,
    zig: *const WaspZig,
    os_tag: std.Target.Os.Tag,
) PkgConfigFiles {
    const wf = b.addWriteFiles();
    const libs_private = libsPrivate(zig);
    const requires_private = requiresPrivate(b);
    return .{
        .shared = wf.add("libwasp-vt.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libwasp-vt
            \\URL: https://github.com/wasp-org/wasp
            \\Description: Wasp VT library
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lwasp-vt
            \\Libs.private: {s}
            \\Requires.private: {s}
        , .{ b.install_prefix, zig.version, libs_private, requires_private })),
        .static = wf.add("libwasp-vt-static.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libwasp-vt-static
            \\URL: https://github.com/wasp-org/wasp
            \\Description: Wasp VT library (static)
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: ${{libdir}}/{s}
            \\Libs.private: {s}
            \\Requires.private: {s}
        , .{
            b.install_prefix,
            zig.version,
            staticLibraryName(os_tag),
            libs_private,
            requires_private,
        })),
    };
}
fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "wasp-vt-static.lib"
    else
        "libwasp-vt.a";
}
fn requiresPrivate(b: *std.Build) []const u8 {
    const system_simdutf = b.systemIntegrationOption("simdutf", .{});
    const system_highway = b.systemIntegrationOption("highway", .{ .default = false });
    if (system_simdutf and system_highway) return "simdutf, libhwy";
    if (system_simdutf) return "simdutf";
    if (system_highway) return "libhwy";
    return "";
}
pub fn xcframework(
    apple_libs: *const AppleLibs,
    b: *std.Build,
) *XCFrameworkStep {
    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(
        b.path("include/wasp"),
        "wasp",
        .{ .include_extensions = &.{".h"} },
    );
    _ = wf.add("module.modulemap",
        \\module WaspVt {
        \\    umbrella header "wasp/vt.h"
        \\    export *
        \\}
        \\
    );
    const headers = wf.getDirectory();
    var libraries: [AppleLibs.len]XCFrameworkStep.Library = undefined;
    var lib_count: usize = 0;
    for (std.enums.values(ApplePlatform)) |platform| {
        if (apple_libs.get(platform)) |lib| {
            libraries[lib_count] = .{
                .library = lib.output,
                .headers = headers,
                .dsym = null,
            };
            lib_count += 1;
        }
    }
    return XCFrameworkStep.create(b, .{
        .name = "wasp-vt",
        .out_path = b.pathJoin(&.{ b.install_prefix, "lib/wasp-vt.xcframework" }),
        .libraries = libraries[0..lib_count],
    });
}
fn detectAppleSDK(
    io: std.Io,
    alloc: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    target: std.Target,
) bool {
    _ = std.zig.LibCInstallation.findNative(
        alloc,
        io,
        .{
            .environ_map = environ_map,
            .target = &target,
            .verbose = false,
        },
    ) catch return false;
    return true;
}
pub fn install(
    self: *const WaspLibVt,
    step: *std.Build.Step,
) void {
    const b = step.owner;
    step.dependOn(self.artifact);
    if (self.pkg_config) |pkg_config| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config,
            .prefix,
            "share/pkgconfig/libwasp-vt.pc",
        ).step);
    }
    if (self.pkg_config_static) |pkg_config_static| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config_static,
            .prefix,
            "share/pkgconfig/libwasp-vt-static.pc",
        ).step);
    }
}
