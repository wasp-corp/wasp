const XCFrameworkStep = @This();
const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;
pub const Options = struct {
    name: []const u8,
    out_path: []const u8,
    libraries: []const Library,
};
pub const Library = struct {
    library: LazyPath,
    headers: LazyPath,
    dsym: ?LazyPath,
};
step: *Step,
pub fn create(b: *std.Build, opts: Options) *XCFrameworkStep {
    const self = b.allocator.create(XCFrameworkStep) catch @panic("OOM");
    const run_delete = run: {
        const run = RunStep.create(b, b.fmt("xcframework delete {s}", .{opts.name}));
        run.has_side_effects = true;
        run.addArgs(&.{ "rm", "-rf", opts.out_path });
        break :run run;
    };
    const run_create = run: {
        const run = RunStep.create(b, b.fmt("xcframework {s}", .{opts.name}));
        run.has_side_effects = true;
        run.addArgs(&.{ "xcodebuild", "-create-xcframework" });
        for (opts.libraries) |lib| {
            run.addArg("-library");
            run.addFileArg(lib.library);
            run.addArg("-headers");
            run.addFileArg(lib.headers);
            if (lib.dsym) |dsym| {
                run.addArg("-debug-symbols");
                run.addFileArg(dsym);
            }
        }
        run.addArg("-output");
        run.addArg(opts.out_path);
        run.expectExitCode(0);
        _ = run.captureStdOut(.{});
        _ = run.captureStdErr(.{});
        break :run run;
    };
    run_create.step.dependOn(&run_delete.step);
    self.* = .{
        .step = &run_create.step,
    };
    return self;
}
