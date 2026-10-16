const assert = std.debug.assert;
const builtin = @import("builtin");
const buildpkg = @import("src/build/root.zig");
const std = @import("std");
const zig = @import("src/build/zig.zig");
const app_zon_version = @import("build.zig.zon").version;
const lib_version = "0.1.0-dev";
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;
comptime {
    zig.version(minimum_zig_version);
}
pub fn build(b: *std.Build) !void {
    const file_version: ?[]const u8 = if (b.build_root.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(128),
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;
    const config = try buildpkg.Config.init(
        b,
        file_version orelse app_zon_version,
        lib_version,
    );
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const mod = try buildpkg.WaspZig.init(
        b,
        &config,
        &deps,
    );
    const run_step = b.step("run", "Run the app");
    const run_valgrind_step = b.step(
        "run-valgrind",
        "Run the app under valgrind",
    );
    const test_step = b.step("test", "Run tests");
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run libwasp-vt tests",
    );
    const test_lib_vt_build_step = b.step(
        "test-lib-vt-build",
        "Build libwasp-vt tests without running them (compile check)",
    );
    const test_lib_vt_schema_step = b.step(
        "test-lib-vt-schema",
        "Validate the libwasp-vt ABI type manifest",
    );
    const test_valgrind_step = b.step(
        "test-valgrind",
        "Run tests under valgrind",
    );
    const translations_step = b.step(
        "update-translations",
        "Update translation files",
    );
    const resources = try buildpkg.WaspResources.init(b, &config, &deps);
    const i18n = if (config.i18n) try buildpkg.WaspI18n.init(b, &config) else null;
    const exe = try buildpkg.WaspExe.init(b, &config, &deps);
    const docs = try buildpkg.WaspDocs.init(b, &deps);
    if (config.emit_docs) {
        docs.install();
    } else if (config.target.result.os.tag.isDarwin()) {
        docs.installDummy(b.getInstallStep());
    }
    const webdata = try buildpkg.WaspWebdata.init(b, &deps);
    if (config.emit_webdata) webdata.install();
    if (config.emit_bench) {
        const bench = try buildpkg.WaspBench.init(b, &deps);
        bench.install();
    }
    const dist = try buildpkg.WaspDist.init(b, &config);
    {
        const step = b.step("dist", "Build the dist tarball");
        step.dependOn(dist.install_step);
        const check_step = b.step("distcheck", "Install and validate the dist tarball");
        check_step.dependOn(dist.check_step);
        check_step.dependOn(dist.install_step);
    }
    const native_freestanding = config.target.result.os.tag == .freestanding and
        !config.target.result.cpu.arch.isWasm();
    const libwasp_vt_shared: ?buildpkg.WaspLibVt = shared: {
        if (config.target.result.cpu.arch.isWasm()) {
            break :shared try buildpkg.WaspLibVt.initWasm(
                b,
                &mod,
            );
        }
        if (native_freestanding) break :shared null;
        break :shared try buildpkg.WaspLibVt.initShared(
            b,
            &mod,
        );
    };
    if (libwasp_vt_shared) |shared| {
        shared.install(b.getInstallStep());
        const type_schema_test = b.addSystemCommand(&.{"python3"});
        type_schema_test.addFileArg(b.path("src/terminal/c/types-schema-verify.py"));
        type_schema_test.addFileArg(b.path("src/terminal/c/types.schema.json"));
        type_schema_test.addFileArg(shared.output);
        test_lib_vt_schema_step.dependOn(&type_schema_test.step);
    } else {
        try test_lib_vt_schema_step.addError(
            "cannot execute the ABI manifest for a native freestanding target",
            .{},
        );
    }
    const libwasp_vt_static = try buildpkg.WaspLibVt.initStatic(
        b,
        &mod,
    );
    if (config.is_dep) {
        libwasp_vt_static.install(b.getInstallStep());
    } else {
        const static_lib_name = if (config.target.result.os.tag == .windows)
            "wasp-vt-static.lib"
        else
            "libwasp-vt.a";
        b.getInstallStep().dependOn(&b.addInstallLibFile(
            libwasp_vt_static.output,
            static_lib_name,
        ).step);
        if (native_freestanding) {
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = b.path("include/wasp"),
                .install_dir = .header,
                .install_subdir = "wasp",
                .include_extensions = &.{".h"},
            }).step);
        }
    }
    if (config.emit_lib_vt and
        config.emit_xcframework and
        builtin.os.tag.isDarwin() and
        config.target.result.os.tag.isDarwin())
    {
        const apple_libs = try buildpkg.WaspLibVt.initStaticAppleUniversal(
            b,
            &config,
            &deps,
            &mod,
        );
        const xcframework = buildpkg.WaspLibVt.xcframework(&apple_libs, b);
        b.getInstallStep().dependOn(xcframework.step);
    }
    if (config.emit_helpgen) deps.help_strings.install();
    if (config.app_runtime != .none) {
        if (config.emit_exe) {
            exe.install();
            resources.install();
            if (i18n) |v| v.install();
        }
    } else if (!config.emit_lib_vt) {
        const lib_shared = try buildpkg.WaspLib.initShared(b, &deps);
        const lib_static = try buildpkg.WaspLib.initStatic(b, &deps);
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader();
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("wasp-internal.dll");
                lib_static.install("wasp-internal-static.lib");
            } else {
                lib_shared.install("wasp-internal.so");
                lib_static.install("wasp-internal.a");
            }
        }
    }
    if (!config.emit_lib_vt and config.target.result.os.tag.isDarwin() and
        (config.emit_xcframework or config.emit_macos_app))
    {
        const xcframework = try buildpkg.WaspXCFramework.init(
            b,
            &deps,
            config.xcframework_target,
        );
        if (config.emit_xcframework) {
            xcframework.install();
            resources.install();
            if (i18n) |v| v.install();
        }
        const macos_app = try buildpkg.WaspXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .i18n = if (i18n) |v| &v else null,
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }
    }
    run: {
        if (config.app_runtime != .none) {
            const run_cmd = b.addRunArtifact(exe.exe);
            if (b.args) |args| run_cmd.addArgs(args);
            run_cmd.setEnvironmentVariable(
                "WASP_RESOURCES_DIR",
                b.getInstallPath(.prefix, "share/wasp"),
            );
            run_step.dependOn(&run_cmd.step);
            break :run;
        }
        assert(config.app_runtime == .none);
        if (!config.emit_lib_vt and
            config.target.result.os.tag.isDarwin() and
            (config.emit_xcframework or config.emit_macos_app))
        {
            const xcframework_native = try buildpkg.WaspXCFramework.init(
                b,
                &deps,
                .native,
            );
            const macos_app_native_only = try buildpkg.WaspXcodebuild.init(
                b,
                &config,
                .{
                    .xcframework = &xcframework_native,
                    .docs = &docs,
                    .i18n = if (i18n) |v| &v else null,
                    .resources = &resources,
                },
            );
            run_step.dependOn(&macos_app_native_only.open.step);
            if (test_filters.len == 0) {
                macos_app_native_only.addTestStepDependencies(test_step);
            }
        }
    }
    if (config.app_runtime != .none) {
        const valgrind_exe = exe: {
            var valgrind_config = config;
            valgrind_config.target = valgrind_config.baselineTarget(b.graph.io);
            break :exe try buildpkg.WaspExe.init(
                b,
                &valgrind_config,
                &deps,
            );
        };
        const run_cmd = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--error-exitcode=1",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        run_cmd.addArtifactArg(valgrind_exe.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        run_valgrind_step.dependOn(&run_cmd.step);
    }
    {
        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);
        test_lib_vt_build_step.dependOn(&mod_vt_test.step);
        const mod_vt_c_test = b.addTest(.{
            .root_module = mod.vt_c,
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);
        test_lib_vt_build_step.dependOn(&mod_vt_c_test.step);
    }
    if (!config.emit_lib_vt) {
        const test_exe = b.addTest(.{
            .name = "wasp-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(b.graph.io),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            .use_llvm = true,
        });
        if (config.emit_test_exe) {
            const test_exe_install = b.addInstallArtifact(test_exe, .{});
            config.addPatchElf(test_exe, &test_exe_install.step);
            test_step.dependOn(&test_exe_install.step);
        }
        _ = try deps.add(test_exe);
        addWaspH(b, test_exe.root_module, config.baselineTarget(b.graph.io), .Debug);
        const test_run = b.addRunArtifact(test_exe);
        config.addPatchElf(test_exe, &test_run.step);
        test_step.dependOn(&test_run.step);
        const valgrind_run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--error-exitcode=1",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        valgrind_run.addArtifactArg(test_exe);
        config.addPatchElf(test_exe, &valgrind_run.step);
        test_valgrind_step.dependOn(&valgrind_run.step);
    }
    if (i18n) |v| {
        translations_step.dependOn(v.update_step);
    } else {
        try translations_step.addError("cannot update translations when i18n is disabled", .{});
    }
}
fn addWaspH(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;
    const translate_c_dep = b.lazyDependency("translate_c", .{}) orelse return;
    const translated: translate_c.Translator = .init(translate_c_dep, .{
        .c_source_file = b.addWriteFiles().add(
            "hb_c.h",
            \\#include <wasp.h>
            ,
        ),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translated.addSystemIncludePath(b.path("include"));
    module.addImport("wasp.h", translated.mod);
}
