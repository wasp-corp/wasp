const LibtoolStep = @This();
const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;
pub const Options = struct {
    name: []const u8,
    out_name: []const u8,
    sources: []LazyPath,
};
step: *Step,
output: LazyPath,
pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");
    const run_step = RunStep.create(b, b.fmt("libtool {s}", .{opts.name}));
    run_step.addArgs(&.{ "libtool", "-static", "-o" });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.sources, 0..) |source, i| {
        run_step.addFileArg(normalizeArchive(
            b,
            opts.name,
            opts.out_name,
            i,
            source,
        ));
    }
    self.* = .{
        .step = &run_step.step,
        .output = output,
    };
    return self;
}
fn normalizeArchive(
    b: *std.Build,
    step_name: []const u8,
    out_name: []const u8,
    index: usize,
    source: LazyPath,
) LazyPath {
    const run_step = RunStep.create(
        b,
        b.fmt("ranlib {s} #{d}", .{ step_name, index }),
    );
    run_step.addArgs(&.{
        "/bin/sh",
        "-c",
        "/bin/cp \"$1\" \"$2\" && /usr/bin/ranlib \"$2\"",
        "_",
    });
    run_step.addFileArg(source);
    return run_step.addOutputFileArg(b.fmt("{d}-{s}", .{ index, out_name }));
}
