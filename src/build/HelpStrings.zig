const HelpStrings = @This();
const std = @import("std");
const Config = @import("Config.zig");
exe: *std.Build.Step.Compile,
output: std.Build.LazyPath,
pub fn init(b: *std.Build, cfg: *const Config) !HelpStrings {
    const exe = b.addExecutable(.{
        .name = "helpgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/helpgen.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });
    const help_config = config: {
        var copy = cfg.*;
        copy.exe_entrypoint = .helpgen;
        break :config copy;
    };
    const options = b.addOptions();
    try help_config.addOptions(options);
    exe.root_module.addOptions("build_options", options);
    const help_run = b.addRunArtifact(exe);
    const wf = b.addWriteFiles();
    const output = wf.addCopyFile(help_run.captureStdOut(.{}), "helpgen.zig");
    return .{
        .exe = exe,
        .output = output,
    };
}
pub fn addImport(self: *const HelpStrings, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("help_strings", .{
        .root_source_file = self.output,
    });
}
pub fn install(self: *const HelpStrings) void {
    self.exe.step.owner.installArtifact(self.exe);
}
