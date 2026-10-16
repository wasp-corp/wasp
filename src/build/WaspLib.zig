const WaspLib = @This();
const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const Config = @import("Config.zig");
const LibsystemOverrideStep = @import("LibsystemOverrideStep.zig");
const SharedDeps = @import("SharedDeps.zig");
const LipoStep = @import("LipoStep.zig");
step: *std.Build.Step,
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: ?std.Build.LazyPath,
pkg_config_static: ?std.Build.LazyPath,
pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !WaspLib {
    const lib = b.addLibrary(.{
        .name = "wasp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.omitFramePointer(),
            .unwind_tables = if (deps.config.strip) .none else .sync,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;
    if (deps.config.target.result.os.tag == .windows) {
        lib.bundle_ubsan_rt = false;
    }
    var lib_list = try deps.add(lib);
    try lib_list.append(b.allocator, lib.getEmittedBin());
    const combined = CombineArchivesStep.create(b, deps.config.target, "wasp-internal", lib_list.items);
    combined.step.dependOn(&lib.step);
    const override = LibsystemOverrideStep.create(
        b,
        deps.config.target,
        combined.output,
        "libwasp-internal.a",
    );
    return .{
        .step = override.step orelse combined.step,
        .output = override.output,
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}
pub fn initShared(
    b: *std.Build,
    deps: *const SharedDeps,
) !WaspLib {
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };
    const lib = b.addLibrary(.{
        .name = "wasp",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.omitFramePointer(),
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),
        .use_llvm = true,
    });
    _ = try deps.add(lib);
    if (deps.config.target.result.os.tag == .windows and
        deps.config.target.result.abi == .msvc)
    {
        lib.root_module.linkSystemLibrary("libvcruntime", dynamic_link_opts);
        const arch = deps.config.target.result.cpu.arch;
        const sdk = std.zig.WindowsSdk.find(b.allocator, b.graph.io, arch, &b.graph.environ_map) catch null;
        if (sdk) |s| {
            if (s.windows10sdk) |w10| {
                const arch_str: []const u8 = switch (arch) {
                    .x86_64 => "x64",
                    .x86 => "x86",
                    .aarch64 => "arm64",
                    else => "x64",
                };
                const ucrt_lib_path = std.fmt.allocPrint(
                    b.allocator,
                    "{s}\\Lib\\{s}\\ucrt\\{s}",
                    .{ w10.path, w10.version, arch_str },
                ) catch null;
                if (ucrt_lib_path) |path| {
                    lib.root_module.addLibraryPath(.{ .cwd_relative = path });
                }
            }
        }
        lib.root_module.linkSystemLibrary("libucrt", dynamic_link_opts);
    }
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (!deps.config.target.result.os.tag.isDarwin()) {
            break :dsymutil null;
        }
        const dsymutil = RunStep.create(b, "dsymutil");
        dsymutil.addArgs(&.{"dsymutil"});
        dsymutil.addFileArg(lib.getEmittedBin());
        dsymutil.addArgs(&.{"-o"});
        const output = dsymutil.addOutputFileArg("libwasp.dSYM");
        break :dsymutil output;
    };
    const pcs = pkgConfigFiles(b, deps);
    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .pkg_config = pcs.shared,
        .pkg_config_static = pcs.static,
    };
}
pub fn initMacOSUniversal(
    b: *std.Build,
    original_deps: *const SharedDeps,
) !WaspLib {
    const aarch64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .aarch64),
    ));
    const x86_64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .x86_64),
    ));
    const universal = LipoStep.create(b, .{
        .name = "wasp",
        .out_name = "wasp-internal.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });
    return .{
        .step = universal.step,
        .output = universal.output,
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}
pub fn install(self: *const WaspLib, name: []const u8) void {
    const b = self.step.owner;
    const step = b.getInstallStep();
    const lib_install = b.addInstallLibFile(self.output, name);
    step.dependOn(&lib_install.step);
    if (self.pkg_config) |pc| {
        step.dependOn(&b.addInstallFileWithDir(
            pc,
            .prefix,
            "share/pkgconfig/wasp-internal.pc",
        ).step);
    }
    if (self.pkg_config_static) |pc| {
        step.dependOn(&b.addInstallFileWithDir(
            pc,
            .prefix,
            "share/pkgconfig/wasp-internal-static.pc",
        ).step);
    }
}
pub fn installHeader(self: *const WaspLib) void {
    const b = self.step.owner;
    const header_install = b.addInstallHeaderFile(
        b.path("include/wasp.h"),
        "wasp.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
}
const PkgConfigFiles = struct {
    shared: std.Build.LazyPath,
    static: std.Build.LazyPath,
};
fn pkgConfigFiles(
    b: *std.Build,
    deps: *const SharedDeps,
) PkgConfigFiles {
    const os_tag = deps.config.target.result.os.tag;
    const wf = b.addWriteFiles();
    return .{
        .shared = wf.add("wasp-internal.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: wasp-internal
            \\URL: https://github.com/wasp-org/wasp
            \\Description: Wasp internal library (not for external use)
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: ${{libdir}}/{s}
            \\Libs.private:
            \\Requires.private:
        , .{ b.install_prefix, deps.config.version, sharedLibraryName(os_tag) })),
        .static = wf.add("wasp-internal-static.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: wasp-internal-static
            \\URL: https://github.com/wasp-org/wasp
            \\Description: Wasp internal library, static (not for external use)
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: ${{libdir}}/{s}
            \\Libs.private:
            \\Requires.private:
        , .{ b.install_prefix, deps.config.version, staticLibraryName(os_tag) })),
    };
}
fn sharedLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "wasp-internal.dll"
    else
        "wasp-internal.so";
}
fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "wasp-internal-static.lib"
    else
        "wasp-internal.a";
}
