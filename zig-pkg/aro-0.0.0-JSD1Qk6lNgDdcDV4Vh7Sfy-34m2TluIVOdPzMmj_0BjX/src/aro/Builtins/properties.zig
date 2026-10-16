const std = @import("std");
pub const Header = enum {
    none,
    stdio,
    stdlib,
    setjmpex,
    stdarg,
    string,
    ctype,
    wchar,
    setjmp,
    malloc,
    strings,
    unistd,
    pthread,
    math,
    complex,
    blocks,
    intrin,
    immintrin,
    xmmintrin,
    emmintrin,
    mmintrin,
    arm_acle,
};
pub const Language = enum {
    all_languages,
    all_ms_languages,
    all_gnu_languages,
    gnu_lang,
    c23_lang,
};
pub const Attributes = packed struct {
    noreturn: bool = false,
    pure: bool = false,
    @"const": bool = false,
    custom_typecheck: bool = false,
    allow_type_mismatch: bool = false,
    lib_function_with_builtin_prefix: bool = false,
    lib_function_without_prefix: bool = false,
    returns_twice: bool = false,
    format_kind: enum(u3) {
        none,
        printf,
        vprintf,
        scanf,
        vscanf,
    } = .none,
    format_string_position: u5 = 0,
    eval_args: bool = true,
    const_without_errno_and_fp_exceptions: bool = false,
    const_without_fp_exceptions: bool = false,
    const_evaluable: bool = false,
};
pub fn isVarArgs(param_str: [*:0]const u8) bool {
    const slice = std.mem.sliceTo(param_str, 0);
    return slice[slice.len - 1] == '.';
}
