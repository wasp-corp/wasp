const std = @import("std");
const builtin = @import("builtin");
const LibtoolStep = @import("LibtoolStep.zig");
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    sources: []const std.Build.LazyPath,
) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    if (target.result.os.tag.isDarwin() and
        comptime builtin.os.tag.isDarwin())
    {
        const libtool = LibtoolStep.create(b, .{
            .name = name,
            .out_name = b.fmt("lib{s}-fat.a", .{name}),
            .sources = @constCast(sources),
        });
        return .{ .step = libtool.step, .output = libtool.output };
    }
    const tool = b.addExecutable(.{
        .name = "combine_archives",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/combine_archives.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addArg(b.graph.zig_exe);
    const out_name = if (target.result.os.tag == .windows)
        b.fmt("{s}-fat.lib", .{name})
    else
        b.fmt("lib{s}-fat.a", .{name});
    const output = run.addOutputFileArg(out_name);
    for (sources) |source| run.addFileArg(source);
    return .{ .step = &run.step, .output = output };
}
