const Wasp = @This();
const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const Docs = @import("WaspDocs.zig");
const I18n = @import("WaspI18n.zig");
const Resources = @import("WaspResources.zig");
const XCFramework = @import("WaspXCFramework.zig");
build: *std.Build.Step.Run,
open: *std.Build.Step.Run,
copy: *std.Build.Step.Run,
xctest: *std.Build.Step.Run,
pub const Deps = struct {
    xcframework: *const XCFramework,
    docs: *const Docs,
    i18n: ?*const I18n,
    resources: *const Resources,
};
pub fn init(
    b: *std.Build,
    config: *const Config,
    deps: Deps,
) !Wasp {
    const xc_config = switch (config.optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "ReleaseLocal",
    };
    const xc_arch: ?[]const u8 = switch (deps.xcframework.target) {
        .universal => null,
        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
    };
    const env = b.graph.environ_map;
    const app_path = b.fmt("macos/build/{s}/Wasp.app", .{xc_config});
    const build = build: {
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = .init(b.allocator);
        if (env.get("PATH")) |v| try env_map.put("PATH", v);
        const step = RunStep.create(b, "xcodebuild");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.environ_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "-target",
            "Wasp",
            "-configuration",
            xc_config,
        });
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });
        deps.xcframework.addStepDependencies(&step.step);
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);
        step.expectExitCode(0);
        break :build step;
    };
    const xctest = xctest: {
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = .init(b.allocator);
        if (env.get("PATH")) |v| try env_map.put("PATH", v);
        const step = RunStep.create(b, "xcodebuild test");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.environ_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "test",
            "-scheme",
            "Wasp",
            "-skip-testing",
            "WaspUITests",
        });
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });
        deps.xcframework.addStepDependencies(&step.step);
        deps.resources.addStepDependencies(&step.step);
        if (deps.i18n) |v| v.addStepDependencies(&step.step);
        deps.docs.installDummy(&step.step);
        step.expectExitCode(0);
        break :xctest step;
    };
    const open = open: {
        const disable_save_state = RunStep.create(b, "disable save state");
        disable_save_state.has_side_effects = true;
        disable_save_state.addArgs(&.{
            "/usr/libexec/PlistBuddy",
            "-c",
            "Add :NSQuitAlwaysKeepsWindows bool false",
            b.fmt("{s}/Contents/Info.plist", .{app_path}),
        });
        disable_save_state.expectExitCode(0);
        disable_save_state.step.dependOn(&build.step);
        const open = RunStep.create(b, "run Wasp app");
        open.has_side_effects = true;
        open.cwd = b.path("");
        open.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/wasp",
            .{app_path},
        )});
        open.step.dependOn(&build.step);
        open.step.dependOn(&disable_save_state.step);
        open.setEnvironmentVariable("WASP_LOG", "stderr,macos");
        open.setEnvironmentVariable("WASP_MAC_LAUNCH_SOURCE", "zig_run");
        if (b.args) |args| {
            open.addArgs(args);
        }
        break :open open;
    };
    const copy = copy: {
        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&build.step);
        break :copy step;
    };
    return .{
        .build = build,
        .open = open,
        .copy = copy,
        .xctest = xctest,
    };
}
pub fn install(self: *const Wasp) void {
    const b = self.copy.step.owner;
    b.getInstallStep().dependOn(&self.copy.step);
}
pub fn installXcframework(self: *const Wasp) void {
    const b = self.build.step.owner;
    b.getInstallStep().dependOn(&self.build.step);
}
pub fn addTestStepDependencies(
    self: *const Wasp,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(&self.xctest.step);
}
