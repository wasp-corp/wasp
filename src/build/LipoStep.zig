const LipoStep = @This();
const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;
pub const Options = struct {
    name: []const u8,
    out_name: []const u8,
    input_a: LazyPath,
    input_b: LazyPath,
};
step: *Step,
output: LazyPath,
pub fn create(b: *std.Build, opts: Options) *LipoStep {
    const self = b.allocator.create(LipoStep) catch @panic("OOM");
    const run_step = RunStep.create(b, b.fmt("lipo {s}", .{opts.name}));
    run_step.addArgs(&.{ "lipo", "-create", "-output" });
    const output = run_step.addOutputFileArg(opts.out_name);
    run_step.addFileArg(opts.input_a);
    run_step.addFileArg(opts.input_b);
    self.* = .{
        .step = &run_step.step,
        .output = output,
    };
    return self;
}
