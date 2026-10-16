const std = @import("std");
const Attribute = @import("Attribute.zig");
const Compilation = @import("Compilation.zig");
pub fn hasFeature(comp: *Compilation, ext_raw: []const u8) bool {
    const ext = Attribute.normalize(ext_raw);
    const list = .{
        .assume_nonnull = true,
        .attribute_analyzer_noreturn = true,
        .attribute_availability = true,
        .attribute_availability_with_message = true,
        .attribute_availability_app_extension = true,
        .attribute_availability_with_version_underscores = true,
        .attribute_availability_tvos = true,
        .attribute_availability_watchos = true,
        .attribute_availability_with_strict = true,
        .attribute_availability_with_replacement = true,
        .attribute_availability_in_templates = true,
        .attribute_availability_swift = true,
        .attribute_cf_returns_not_retained = true,
        .attribute_cf_returns_retained = true,
        .attribute_cf_returns_on_parameters = true,
        .attribute_deprecated_with_message = true,
        .attribute_deprecated_with_replacement = true,
        .attribute_ext_vector_type = true,
        .attribute_ns_returns_not_retained = true,
        .attribute_ns_returns_retained = true,
        .attribute_ns_consumes_self = true,
        .attribute_ns_consumed = true,
        .attribute_cf_consumed = true,
        .attribute_overloadable = true,
        .attribute_unavailable_with_message = true,
        .attribute_unused_on_fields = true,
        .attribute_diagnose_if_objc = true,
        .blocks = false, 
        .c_thread_safety_attributes = true,
        .enumerator_attributes = true,
        .nullability = true,
        .nullability_on_arrays = true,
        .nullability_nullable_result = true,
        .c_alignas = comp.langopts.standard.atLeast(.c11),
        .c_alignof = comp.langopts.standard.atLeast(.c11),
        .c_atomic = comp.langopts.standard.atLeast(.c11),
        .c_generic_selections = comp.langopts.standard.atLeast(.c11),
        .c_static_assert = comp.langopts.standard.atLeast(.c11),
        .c_thread_local = comp.langopts.standard.atLeast(.c11) and comp.target.isTlsSupported(),
        .c_attributes = comp.langopts.standard.atLeast(.c23),
        .c_fixed_enum = comp.langopts.standard.atLeast(.c23),
        .bounds_attributes = comp.langopts.bounds_safety == .clang,
    };
    inline for (@typeInfo(@TypeOf(list)).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, ext)) return @field(list, f.name);
    }
    return false;
}
pub fn hasExtension(comp: *Compilation, ext_raw: []const u8) bool {
    const ext = Attribute.normalize(ext_raw);
    if (hasFeature(comp, ext)) {
        return true;
    }
    switch (comp.diagnostics.state.extensions) {
        .@"error", .@"fatal error" => return false,
        else => {},
    }
    const list = .{
        .c_alignas = true,
        .c_alignof = true,
        .c_atomic = true,
        .c_generic_selections = true,
        .c_static_assert = true,
        .c_thread_local = comp.target.isTlsSupported(),
        .c_attributes = true,
        .c_fixed_enum = true,
        .overloadable_unmarked = false, 
        .statement_attributes_with_gnu_syntax = true,
        .gnu_asm = comp.langopts.gnu_asm,
        .gnu_asm_goto_with_outputs = comp.langopts.gnu_asm,
        .matrix_types = false, 
        .matrix_types_scalar_division = false, 
        .define_target_os_macros = comp.langopts.hasTargetOsMacros(),
    };
    inline for (@typeInfo(@TypeOf(list)).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, ext)) return @field(list, f.name);
    }
    return false;
}
