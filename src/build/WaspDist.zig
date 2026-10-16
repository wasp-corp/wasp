const WaspDist = @This();
const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const WaspFrameData = @import("WaspFrameData.zig");
archive: std.Build.LazyPath,
install_step: *std.Build.Step,
archive_step: *std.Build.Step,
check_step: *std.Build.Step,
pub fn init(b: *std.Build, cfg: *const Config) !WaspDist {
    const name = if (cfg.emit_lib_vt) "libwasp-vt" else "wasp";
    const alloc = b.allocator;
    var resources: std.ArrayListUnmanaged(Resource) = .empty;
    if (!cfg.emit_lib_vt) {
        {
            const gtk = SharedDeps.gtkDistResources(b);
            try resources.append(alloc, gtk.resources_c);
            try resources.append(alloc, gtk.resources_h);
        }
        {
            const framedata = WaspFrameData.distResources(b);
            try resources.append(alloc, framedata.framedata);
        }
    }
    const git_archive = b.addSystemCommand(&.{
        "git",
        "archive",
        "--format=tgz",
    });
    {
        const version = b.addWriteFiles().add("VERSION", b.fmt("{f}", .{cfg.version}));
        git_archive.addArg(b.fmt("--prefix={s}-{f}/", .{
            name, cfg.version,
        }));
        git_archive.addPrefixedFileArg("--add-file=", version);
    }
    for (resources.items) |resource| {
        const copied = b.addWriteFiles().addCopyFile(
            resource.generated,
            std.fs.path.basename(resource.dist),
        );
        git_archive.addArg(b.fmt("--prefix={s}-{f}/{s}/", .{
            name,                                 cfg.version,
            std.fs.path.dirname(resource.dist).?,
        }));
        git_archive.addPrefixedFileArg("--add-file=", copied);
    }
    git_archive.addArgs(&.{
        b.fmt("--prefix={s}-{f}/", .{ name, cfg.version }),
        "-o",
    });
    const output = git_archive.addOutputFileArg(b.fmt(
        "{s}-{f}.tar.gz",
        .{ name, cfg.version },
    ));
    git_archive.addArg("HEAD");
    if (cfg.emit_lib_vt) {
        for (lib_vt_excludes) |exclude| {
            git_archive.addArg(b.fmt(":(exclude){s}", .{exclude}));
        }
    }
    const install = b.addInstallFile(
        output,
        b.fmt("dist/{s}-{f}.tar.gz", .{ name, cfg.version }),
    );
    const check = b.addSystemCommand(&.{ "tar", "xvzf" });
    check.addFileArg(output);
    check.addArg("-C");
    const extract_dir = check
        .addOutputDirectoryArg(name)
        .path(b, b.fmt("{s}-{f}", .{ name, cfg.version }));
    const check_test = step: {
        const check_cmd = if (cfg.emit_lib_vt)
            &[_][]const u8{ "zig", "build", "test-lib-vt", "-Demit-lib-vt=true" }
        else
            &[_][]const u8{ "zig", "build", "test" };
        const step = b.addSystemCommand(check_cmd);
        step.setCwd(extract_dir);
        step.expectExitCode(0);
        break :step step;
    };
    for (resources.items) |resource| {
        const path = extract_dir.path(b, resource.dist);
        const check_path = b.addCheckFile(path, .{});
        check_test.step.dependOn(&check_path.step);
    }
    if (cfg.emit_lib_vt) {
        const cmake_build_dir = extract_dir.path(b, "cmake-build");
        const cmake_configure = b.addSystemCommand(&.{ "cmake", "-B" });
        cmake_configure.addDirectoryArg(cmake_build_dir);
        cmake_configure.setCwd(extract_dir);
        cmake_configure.expectExitCode(0);
        cmake_configure.step.dependOn(&check.step);
        const cmake_build = b.addSystemCommand(&.{ "cmake", "--build" });
        cmake_build.addDirectoryArg(cmake_build_dir);
        cmake_build.expectExitCode(0);
        cmake_build.step.dependOn(&cmake_configure.step);
        check_test.step.dependOn(&cmake_build.step);
    }
    return .{
        .archive = output,
        .install_step = &install.step,
        .archive_step = &git_archive.step,
        .check_step = &check_test.step,
    };
}
const lib_vt_excludes = &[_][]const u8{
    "images",
    "macos",
    "dist/doxygen",
    "dist/linux",
    "dist/macos",
    "dist/windows",
    "flatpak",
    "snap",
    "po",
    "example",
    "test",
    "src/font/res",
    "src/crash/testdata",
    "pkg/wuffs/src/too_big.jpg",
    "pkg/wuffs/src/too_big.png",
    "pkg/breakpad/vendor",
    "vendor",
};
pub const Resource = struct {
    dist: []const u8,
    generated: std.Build.LazyPath,
    pub fn path(self: *const Resource, b: *std.Build) std.Build.LazyPath {
        if (self.exists(b)) {
            return b.path(self.dist);
        }
        return self.generated;
    }
    pub fn exists(self: *const Resource, b: *std.Build) bool {
        if (b.build_root.handle.access(b.graph.io, self.dist, .{})) {
            if (b.build_root.handle.access(b.graph.io, ".git", .{})) {
                std.log.warn(
                    "dist resource '{s}' should not be in a git checkout",
                    .{self.dist},
                );
                return false;
            } else |_| {}
            return true;
        } else |_| {
            return false;
        }
    }
};
