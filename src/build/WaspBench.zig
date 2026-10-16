const WaspBench = @This();
const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
steps: []*std.Build.Step.Compile,
pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !WaspBench {
    var steps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer steps.deinit(b.allocator);
    {
        const exe = b.addExecutable(.{
            .name = "wasp-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_gen.zig"),
                .target = deps.config.target,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        _ = try deps.add(exe);
        try steps.append(b.allocator, exe);
    }
    {
        const exe = b.addExecutable(.{
            .name = "wasp-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_bench.zig"),
                .target = deps.config.target,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        _ = try deps.add(exe);
        try steps.append(b.allocator, exe);
    }
    return .{ .steps = steps.items };
}
pub fn install(self: *const WaspBench) void {
    const b = self.steps[0].step.owner;
    for (self.steps) |step| b.installArtifact(step);
}
