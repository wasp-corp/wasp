const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_step = b.step("run", "Run the app");
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"main.c"},
    });
    if (b.lazyDependency("wasp", .{})) |dep| {
        exe_mod.linkLibrary(dep.artifact("wasp-vt"));
    }
    const exe = b.addExecutable(.{
        .name = "c_vt_encode_mouse",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
