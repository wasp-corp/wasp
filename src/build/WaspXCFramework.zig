const WaspXCFramework = @This();
const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const WaspLib = @import("WaspLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;
xcframework: *XCFrameworkStep,
target: Target,
pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !WaspXCFramework {
    const macos_universal = try WaspLib.initMacOSUniversal(b, deps);
    const macos_native = try WaspLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("include/wasp.h"), "wasp.h");
    _ = wf.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
    const headers = wf.getDirectory();
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "WaspKit",
        .out_path = "macos/WaspKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = macos_universal.output,
                    .headers = headers,
                    .dsym = macos_universal.dsym,
                },
            },
            .native => &.{.{
                .library = macos_native.output,
                .headers = headers,
                .dsym = macos_native.dsym,
            }},
        },
    });
    return .{
        .xcframework = xcframework,
        .target = target,
    };
}
pub fn install(self: *const WaspXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}
pub fn addStepDependencies(
    self: *const WaspXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
