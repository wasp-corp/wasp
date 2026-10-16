const WaspResources = @This();
const std = @import("std");
const assert = std.debug.assert;
const Config = @import("Config.zig");
const RunStep = std.Build.Step.Run;
const SharedDeps = @import("SharedDeps.zig");
steps: []*std.Build.Step,
pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !WaspResources {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    errdefer steps.deinit(b.allocator);
    const build_data_exe = b.addExecutable(.{
        .name = "wasp-build-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_build_data.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
            .link_libc = true,
        }),
    });
    deps.help_strings.addImport(build_data_exe);
    terminfo: {
        const os_tag = cfg.target.result.os.tag;
        const terminfo_share_dir = if (os_tag == .freebsd)
            "site-terminfo"
        else
            "terminfo";
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+terminfo");
        const wf = b.addWriteFiles();
        const source = wf.addCopyFile(run.captureStdOut(.{}), "wasp.terminfo");
        if (cfg.emit_terminfo) {
            const source_install = b.addInstallFile(
                source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/wasp.terminfo"
                else
                    "share/terminfo/wasp.terminfo",
            );
            try steps.append(b.allocator, &source_install.step);
        }
        if (os_tag == .windows) break :terminfo;
        if (cfg.emit_termcap) {
            const run_step = RunStep.create(b, "infotocap");
            run_step.addArg("infotocap");
            run_step.addFileArg(source);
            const out_source = run_step.captureStdOut(.{});
            _ = run_step.captureStdErr(.{});
            const cap_install = b.addInstallFile(
                out_source,
                if (os_tag == .freebsd)
                    "share/site-terminfo/wasp.termcap"
                else
                    "share/terminfo/wasp.termcap",
            );
            try steps.append(b.allocator, &cap_install.step);
        }
        {
            const run_step = RunStep.create(b, "tic");
            run_step.addArgs(&.{ "tic", "-x", "-o" });
            const path = run_step.addOutputFileArg(terminfo_share_dir);
            run_step.addFileArg(source);
            _ = run_step.captureStdErr(.{});
            const mkdir_step = RunStep.create(b, "make share/terminfo directory");
            switch (cfg.target.result.os.tag) {
                .windows => mkdir_step.addArgs(&.{"mkdir"}),
                else => mkdir_step.addArgs(&.{ "mkdir", "-p" }),
            }
            mkdir_step.addArg(b.fmt(
                "{s}/share/{s}",
                .{ b.install_path, terminfo_share_dir },
            ));
            try steps.append(b.allocator, &mkdir_step.step);
            const copy_step = RunStep.create(b, "copy terminfo db");
            copy_step.addArgs(&.{ "cp", "-R" });
            copy_step.addFileArg(path);
            copy_step.addArg(b.fmt("{s}/share", .{b.install_path}));
            copy_step.step.dependOn(&mkdir_step.step);
            try steps.append(b.allocator, &copy_step.step);
        }
    }
    {
        const install_step = b.addInstallDirectory(.{
            .source_dir = b.path("src/shell-integration"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "wasp", "shell-integration" }),
            .exclude_extensions = &.{".md"},
        });
        try steps.append(b.allocator, &install_step.step);
    }
    if (cfg.emit_themes) {
        if (b.lazyDependency("iterm2_themes", .{})) |upstream| {
            const install_step = b.addInstallDirectory(.{
                .source_dir = upstream.path(""),
                .install_dir = .{ .custom = "share" },
                .install_subdir = b.pathJoin(&.{ "wasp", "themes" }),
                .exclude_extensions = &.{".md"},
            });
            try steps.append(b.allocator, &install_step.step);
        }
    }
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+fish");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "wasp.fish");
        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/fish/vendor_completions.d",
        });
        try steps.append(b.allocator, &install_step.step);
    }
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+zsh");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "_wasp");
        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/zsh/site-functions",
        });
        try steps.append(b.allocator, &install_step.step);
    }
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+bash");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "wasp.bash");
        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bash-completion/completions",
        });
        try steps.append(b.allocator, &install_step.step);
    }
    {
        const wf = b.addWriteFiles();
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-syntax");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "syntax/wasp.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftdetect");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "ftdetect/wasp.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftplugin");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "ftplugin/wasp.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-compiler");
            _ = wf.addCopyFile(run.captureStdOut(.{}), "compiler/wasp.vim");
        }
        const vim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/vim/vimfiles",
        });
        try steps.append(b.allocator, &vim_step.step);
        const neovim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/nvim/site",
        });
        try steps.append(b.allocator, &neovim_step.step);
    }
    {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+sublime");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(.{}), "wasp.sublime-syntax");
        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bat/syntaxes",
        });
        try steps.append(b.allocator, &install_step.step);
    }
    if (cfg.target.result.os.tag == .linux) try addLinuxAppResources(
        b,
        cfg,
        &steps,
    );
    return .{ .steps = steps.items };
}
fn addLinuxAppResources(
    b: *std.Build,
    cfg: *const Config,
    steps: *std.ArrayList(*std.Build.Step),
) !void {
    assert(cfg.target.result.os.tag == .linux);
    const name = b.fmt("Wasp{s}", .{
        switch (cfg.optimize) {
            .Debug, .ReleaseSafe => " (Debug)",
            .ReleaseFast, .ReleaseSmall => "",
        },
    });
    const app_id = b.fmt("com.mitchellh.wasp{s}", .{
        switch (cfg.optimize) {
            .Debug, .ReleaseSafe => "-debug",
            .ReleaseFast, .ReleaseSmall => "",
        },
    });
    const exe_abs_path = b.fmt(
        "{s}/bin/wasp",
        .{b.install_prefix},
    );
    const Template = struct { std.Build.LazyPath, []const u8 };
    const templates: []const Template = templates: {
        var ts: std.ArrayList(Template) = .empty;
        defer ts.deinit(b.allocator);
        try ts.append(b.allocator, .{
            b.path("dist/linux/app.desktop.in"),
            b.fmt("share/applications/{s}.desktop", .{app_id}),
        });
        try ts.append(b.allocator, .{
            if (cfg.flatpak)
                b.path("dist/linux/dbus.service.flatpak.in")
            else
                b.path("dist/linux/dbus.service.in"),
            b.fmt("share/dbus-1/services/{s}.service", .{app_id}),
        });
        if (!cfg.flatpak) try ts.append(b.allocator, .{
            b.path("dist/linux/systemd.service.in"),
            b.fmt(
                "{s}/systemd/user/app-{s}.service",
                .{
                    if (b.graph.system_package_mode) "lib" else "share",
                    app_id,
                },
            ),
        });
        try ts.append(b.allocator, .{
            b.path("dist/linux/com.mitchellh.wasp.metainfo.xml.in"),
            b.fmt("share/metainfo/{s}.metainfo.xml", .{app_id}),
        });
        break :templates try ts.toOwnedSlice(b.allocator);
    };
    for (templates) |template| {
        const tpl = b.addConfigHeader(.{
            .style = .{ .cmake = template[0] },
        }, .{
            .NAME = name,
            .APPID = app_id,
            .WASP = exe_abs_path,
        });
        const tail = b.addSystemCommand(&.{ "tail", "-n", "+2" });
        tail.setStdIn(.{ .lazy_path = tpl.getOutputFile() });
        const copy = b.addInstallFile(
            tail.captureStdOut(.{}),
            template[1],
        );
        try steps.append(b.allocator, &copy.step);
    }
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("dist/linux/wasp_dolphin.desktop"),
        "share/kio/servicemenus/com.mitchellh.wasp.desktop",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("dist/linux/wasp_nautilus.py"),
        "share/nautilus-python/extensions/wasp.py",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/16.png"),
        "share/icons/hicolor/16x16/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/32.png"),
        "share/icons/hicolor/32x32/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/128.png"),
        "share/icons/hicolor/128x128/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/256.png"),
        "share/icons/hicolor/256x256/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/512.png"),
        "share/icons/hicolor/512x512/apps/com.mitchellh.wasp.png",
    ).step);
    if (!cfg.flatpak) {
        try steps.append(b.allocator, &b.addInstallFile(
            b.path("images/gnome/1024.png"),
            "share/icons/hicolor/1024x1024/apps/com.mitchellh.wasp.png",
        ).step);
    }
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/32.png"),
        "share/icons/hicolor/16x16@2/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/64.png"),
        "share/icons/hicolor/32x32@2/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/256.png"),
        "share/icons/hicolor/128x128@2/apps/com.mitchellh.wasp.png",
    ).step);
    try steps.append(b.allocator, &b.addInstallFile(
        b.path("images/gnome/512.png"),
        "share/icons/hicolor/256x256@2/apps/com.mitchellh.wasp.png",
    ).step);
}
pub fn install(self: *const WaspResources) void {
    const b = self.steps[0].owner;
    self.addStepDependencies(b.getInstallStep());
}
pub fn addStepDependencies(
    self: *const WaspResources,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}
