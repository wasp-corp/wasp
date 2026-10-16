const std = @import("std");
const builtin = @import("builtin");
pub const Result = struct {
    step: ?*std.Build.Step,
    output: std.Build.LazyPath,
};
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    input: std.Build.LazyPath,
    out_name: []const u8,
) Result {
    if (!target.result.os.tag.isDarwin() or
        comptime !builtin.os.tag.isDarwin())
    {
        return .{ .step = null, .output = input };
    }
    const run = b.addSystemCommand(&.{"/bin/sh"});
    run.setName("libsystem override");
    run.addFileArg(b.path("src/build/libsystem_override.sh"));
    run.addFileArg(input);
    const output = run.addOutputFileArg(out_name);
    return .{ .step = &run.step, .output = output };
}
