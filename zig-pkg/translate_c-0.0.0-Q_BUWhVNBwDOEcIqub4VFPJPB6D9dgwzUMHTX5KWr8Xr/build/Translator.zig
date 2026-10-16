const Translator = @This();
const std = @import("std");
const Build = std.Build;
output_file: Build.LazyPath,
mod: *Build.Module,
run: *Build.Step.Run,
pub const LinkSystemLib = struct {
    name: []const u8,
    options: std.Build.Module.LinkSystemLibraryOptions = .{},
};
pub const Options = struct {
    name: ?[]const u8 = null,
    c_source_file: Build.LazyPath,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_libc: bool = true,
    link_system_libs: []const LinkSystemLib = &.{},
    warnings: enum { ignore, show, @"error" } = .ignore,
    module_libs: bool = true,
    pub_static: ?bool = null,
    func_bodies: ?bool = null,
    keep_macro_literals: ?bool = null,
    default_init: ?bool = null,
    strict_flex_arrays: ?enum { @"0", @"1", @"2", @"3" } = null,
    libc_file: ?std.Build.LazyPath = null,
    extra_args: []const []const u8 = &.{},
};
pub fn init(translate_c_dep: *Build.Dependency, options: Options) Translator {
    return initInner(translate_c_dep.builder, .{
        .exe = translate_c_dep.artifact("translate-c"),
        .aro_resource_dir = translate_c_dep.namedLazyPath("aro_resource_dir"),
        .c_builtins = translate_c_dep.module("c_builtins"),
        .helpers = translate_c_dep.module("helpers"),
    }, options);
}
pub fn initInner(
    b: *Build,
    tc_conf: TranslateCConfig,
    options: Options,
) Translator {
    const name = options.name orelse options.c_source_file.basename(b, null);
    const run = b.addRunArtifact(tc_conf.exe);
    run.setName(b.fmt("translate-c {s}", .{name}));
    const output_file = run.addPrefixedOutputFileArg("-o=", b.fmt("{s}.zig", .{name}));
    const mod = b.createModule(.{
        .root_source_file = output_file,
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = options.link_libc,
    });
    if (options.optimize != .Debug) {
        run.addArg(b.fmt("-O={t}", .{options.optimize}));
    }
    if (!options.target.query.isNative()) {
        const triple = options.target.query.zigTriple(b.graph.arena) catch @panic("OOM");
        const model = options.target.query.serializeCpuAlloc(b.graph.arena) catch @panic("OOM");
        run.addArg(b.fmt("--target={s}", .{triple}));
        run.addArg(b.fmt("-mcpu={s}", .{model}));
    }
    if (options.link_libc)
        run.addArg("-lc");
    for (options.link_system_libs) |lsl| {
        mod.linkSystemLibrary(lsl.name, lsl.options);
        run.addArg(b.fmt("-l={d}{d}{d}{d}{d},{s}", .{
            @intFromBool(lsl.options.needed),
            @intFromBool(lsl.options.weak),
            @intFromEnum(lsl.options.use_pkg_config),
            @intFromEnum(lsl.options.preferred_link_mode),
            @intFromEnum(lsl.options.search_strategy),
            lsl.name,
        }));
    }
    run.addPrefixedDirectoryArg("--zig-lib=", .{
        .cwd_relative = b.graph.zig_lib_directory.path orelse
            std.process.fatal("zig_lib_directory missing in build graph", .{}),
    });
    addFlag(run, "module-libs", options.module_libs);
    addFlag(run, "pub-static", options.pub_static);
    addFlag(run, "func-bodies", options.func_bodies);
    addFlag(run, "keep-macro-literals", options.keep_macro_literals);
    addFlag(run, "default-init", options.default_init);
    if (options.strict_flex_arrays) |level| {
        run.addArg(b.fmt("-fstrict-flex-arrays={d}", .{@intFromEnum(level)}));
    }
    if (options.libc_file) |libc_file| {
        run.addPrefixedFileArg("--libc=", libc_file);
    }
    run.addArg("--");
    run.addArgs(options.extra_args);
    run.addFileArg(options.c_source_file);
    run.addArgs(&.{ "-MD", "-MV", "-MF" });
    _ = run.addDepFileOutputArg("deps.d");
    mod.addImport("c_builtins", tc_conf.c_builtins);
    mod.addImport("helpers", tc_conf.helpers);
    switch (options.warnings) {
        .ignore => run.addArg("-w"),
        .show => {},
        .@"error" => run.addArg("-Werror"),
    }
    appendIncludeArg(run, "-resource-dir", tc_conf.aro_resource_dir);
    return .{
        .output_file = output_file,
        .mod = mod,
        .run = run,
    };
}
pub const TranslateCConfig = struct {
    exe: *Build.Step.Compile,
    aro_resource_dir: Build.LazyPath,
    c_builtins: *Build.Module,
    helpers: *Build.Module,
};
pub fn linkLibrary(t: *const Translator, lib: *Build.Step.Compile) void {
    t.mod.linkLibrary(lib);
    appendIncludeArg(t.run, "-I", lib.getEmittedIncludeTree());
}
pub fn addObject(t: *const Translator, obj: *Build.Step.Compile) void {
    t.mod.addObject(obj);
    appendIncludeArg(t.run, "-I", obj.getEmittedIncludeTree());
}
pub fn addIncludePath(t: *const Translator, path: Build.LazyPath) void {
    t.mod.addIncludePath(path);
    appendIncludeArg(t.run, "-I", path);
}
pub fn addSystemIncludePath(t: *const Translator, path: Build.LazyPath) void {
    t.mod.addSystemIncludePath(path);
    appendIncludeArg(t.run, "-isystem", path);
}
pub fn addAfterIncludePath(t: *const Translator, path: Build.LazyPath) void {
    t.mod.addAfterIncludePath(path);
    appendIncludeArg(t.run, "-idirafter", path);
}
pub fn addFrameworkPath(t: *const Translator, path: Build.LazyPath) void {
    t.mod.addFrameworkPath(path);
    appendIncludeArg(t.run, "-F", path);
}
pub fn addSystemFrameworkPath(t: *const Translator, path: Build.LazyPath) void {
    t.mod.addSystemFrameworkPath(path);
    appendIncludeArg(t.run, "-iframework", path);
}
pub fn addEmbedPath(t: *const Translator, path: Build.LazyPath) void {
    t.mod.addEmbedPath(path);
    t.run.addPrefixedDirectoryArg("--embed-dir=", path);
}
pub fn addConfigHeader(t: *const Translator, ch: *Build.Step.ConfigHeader) void {
    t.mod.addConfigHeader(ch);
    appendIncludeArg(t.run, "-I", ch.getOutputDir());
}
pub fn defineCMacro(t: *const Translator, name: []const u8, value: ?[]const u8) void {
    const b = t.mod.owner;
    const macro = b.fmt("-D{s}={s}", .{ name, value orelse "1" });
    t.mod.c_macros.append(b.allocator, macro) catch @panic("OOM");
    t.run.addArg(macro);
}
fn addFlag(run: *Build.Step.Run, name: []const u8, opt_value: ?bool) void {
    const value = opt_value orelse return;
    const prefix = if (value) "-f" else "-fno-";
    const arg = run.step.owner.fmt("{s}{s}", .{ prefix, name });
    run.addArg(arg);
}
fn appendIncludeArg(run: *Build.Step.Run, arg: []const u8, path: Build.LazyPath) void {
    run.addArg(arg);
    run.addDirectoryArg(path);
}
