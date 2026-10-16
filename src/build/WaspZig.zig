const WaspZig = @This();
const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
vt: *std.Build.Module,
vt_c: *std.Build.Module,
version: std.SemanticVersion,
simd_libs: SharedDeps.LazyPathList,
pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !WaspZig {
    return initInner(b, cfg, deps, "wasp-vt", "wasp-vt-c");
}
pub fn retarget(
    self: *const WaspZig,
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    target: std.Build.ResolvedTarget,
) !WaspZig {
    _ = self;
    const retargeted_config = try b.allocator.create(Config);
    retargeted_config.* = cfg.*;
    retargeted_config.target = target;
    const retargeted_deps = try b.allocator.create(SharedDeps);
    retargeted_deps.* = try deps.retarget(b, target);
    const arch_name = @tagName(target.result.cpu.arch);
    return initInner(
        b,
        retargeted_config,
        retargeted_deps,
        b.fmt("wasp-vt-{s}", .{arch_name}),
        b.fmt("wasp-vt-c-{s}", .{arch_name}),
    );
}
fn initInner(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_name: []const u8,
    vt_c_name: []const u8,
) !WaspZig {
    var vt_options = cfg.terminalOptions(.lib, cfg.optimize);
    vt_options.artifact = .lib;
    vt_options.oniguruma = false;
    var simd_libs: SharedDeps.LazyPathList = .empty;
    return .{
        .vt = try initVt(
            vt_name,
            b,
            cfg,
            deps,
            vt_options,
            null,
        ),
        .vt_c = try initVt(
            vt_c_name,
            b,
            cfg,
            deps,
            options: {
                var dup = vt_options;
                dup.c_abi = true;
                break :options dup;
            },
            &simd_libs,
        ),
        .version = cfg.lib_version,
        .simd_libs = simd_libs,
    };
}
fn initVt(
    name: []const u8,
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_options: TerminalBuildOptions,
    simd_libs: ?*SharedDeps.LazyPathList,
) !*std.Build.Module {
    const general_options = b.addOptions();
    try cfg.addOptions(general_options);
    const vt = b.addModule(name, .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = if (cfg.simd) true else null,
        .link_libcpp = if (cfg.simd and
            b.systemIntegrationOption("simdutf", .{}) and
            cfg.target.result.abi != .msvc) true else null,
    });
    vt.addOptions("build_options", general_options);
    vt_options.add(b, vt);
    deps.unicode_tables.addModuleImport(vt);
    vt.addImport("uucode", deps.uucode_mod);
    if (vt_options.kittyGraphics(cfg.target.result)) {
        if (b.lazyDependency("wuffs", .{
            .target = cfg.target,
            .optimize = cfg.optimize,
        })) |dep| {
            vt.addImport("wuffs", dep.module("wuffs"));
        }
    }
    if (cfg.simd) {
        try SharedDeps.addSimd(b, vt, simd_libs);
    }
    return vt;
}
