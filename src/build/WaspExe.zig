const Wasp = @This();
const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,
pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Wasp {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "wasp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omitFramePointer(),
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    if (cfg.pie) exe.pie = true;
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);
    try checkNixShell(exe, cfg);
    cfg.addPatchElf(exe, &install_step.step);
    switch (cfg.target.result.os.tag) {
        .windows => {
            exe.subsystem = .Windows;
            exe.root_module.addWin32ResourceFile(.{
                .file = b.path("dist/windows/wasp.rc"),
            });
        },
        else => {},
    }
    return .{
        .exe = exe,
        .install_step = install_step,
    };
}
pub fn install(self: *const Wasp) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
fn checkNixShell(exe: *std.Build.Step.Compile, cfg: *const Config) !void {
    if (cfg.target.result.os.tag != .linux) return;
    if (!cfg.target.query.isNativeCpu()) return;
    if (!cfg.target.query.isNativeOs()) return;
    std.Io.Dir.accessAbsolute(exe.step.owner.graph.io, "/etc/NIXOS", .{}) catch return;
    if (cfg.env.get("IN_NIX_SHELL") != null) return;
    try exe.step.addError(
        "\x1b[" ++ color_map.get("yellow").? ++
            "\x1b[" ++ color_map.get("d").? ++
            \\Detected building on and for NixOS outside of the Nix shell environment.
            \\
            \\The resulting wasp binary will likely fail on launch because it is
            \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
            \\We highly recommend running only within the Nix build environment
            \\and the resulting binary will be portable across your system.
            \\
            \\To run in the Nix build environment, use the following command.
            \\Append any additional options like (`-Doptimize` flags). The resulting
            \\binary will be in zig-out as usual.
            \\
            \\  nix develop -c zig build
            \\
        ++
            "\x1b[0m",
        .{},
    );
}
const color_map = std.StaticStringMap([]const u8).initComptime(.{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
