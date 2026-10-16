const std = @import("std");
const getpkg = @import("get.zig");
pub const config = @import("config.zig");
pub const types = @import("types.zig");
pub const ascii = @import("ascii.zig");
pub const grapheme = @import("grapheme.zig");
pub const code_point = @import("code_point.zig");
pub const utf8 = @import("utf8.zig");
const testing = std.testing;
pub const FieldEnum = getpkg.FieldEnum;
pub const TypeOf = getpkg.TypeOf;
pub const TypeOfAll = getpkg.TypeOfAll;
pub const get = getpkg.get;
pub const getAll = getpkg.getAll;
pub const hasField = getpkg.hasField;
pub const backingFor = getpkg.backingFor;
pub const WithBacking = getpkg.WithBacking;
test {
    _ = config;
    _ = ascii;
    _ = grapheme;
    _ = code_point;
    _ = utf8;
}
test "name" {
    try testing.expect(std.mem.eql(u8, get(.name, 65), "LATIN CAPITAL LETTER A"));
}
test "is_alphabetic" {
    try testing.expect(get(.is_alphabetic, 65)); 
    try testing.expect(get(.is_alphabetic, 97)); 
    try testing.expect(!get(.is_alphabetic, 0));
}
test "case_folding_simple" {
    try testing.expectEqual(97, get(.case_folding_simple, 65)); 
    try testing.expectEqual(97, get(.case_folding_simple, 97)); 
    try testing.expectEqual(0x0130, get(.case_folding_simple, 0x0130)); 
    try testing.expectEqual(0x0069, get(.case_folding_turkish_only, 0x0130).?); 
}
test "simple_uppercase_mapping" {
    try testing.expectEqual(65, get(.simple_uppercase_mapping, 97)); 
    try testing.expectEqual(65, get(.simple_uppercase_mapping, 65)); 
}
test "generalCategory" {
    try testing.expect(get(.general_category, 65) == .letter_uppercase); 
}
test "getAll" {
    const d1 = getAll("1", 65);
    try testing.expect(d1.general_category == .letter_uppercase);
    try testing.expect(d1.case_folding_simple.unshift(65) == 97);
    const d_checks = getAll("checks", 65);
    try testing.expectEqual(.@"packed", @typeInfo(TypeOfAll("checks")).@"struct".layout);
    try testing.expect(d_checks.simple_uppercase_mapping.unshift(65) == 65);
    try testing.expect(d_checks.is_alphabetic);
    try testing.expect(d_checks.is_uppercase);
    try testing.expect(!d_checks.is_lowercase);
}
test "get extension foo" {
    try testing.expectEqual(0, get(.foo, 65));
    try testing.expectEqual(3, get(.foo, 0));
}
test "get extension emoji_odd_or_even" {
    try testing.expectEqual(.odd_emoji, get(.emoji_odd_or_even, 0x1F34B)); 
}
test "get packed optional enum works" {
    try testing.expectEqual(.odd_emoji, get(.opt_emoji_odd_or_even, 0x1F34B)); 
    try testing.expectEqual(null, get(.opt_emoji_odd_or_even, 0x01D8)); 
}
test "get packed optional bool works" {
    try testing.expectEqual(true, get(.maybe_bit, 0x1200));
    try testing.expectEqual(false, get(.maybe_bit, 0x1235));
    try testing.expectEqual(null, get(.maybe_bit, 0x1236));
}
test "get union unpacked, shift" {
    try testing.expectEqual(0x1234, get(.next_or_prev, 0x1233).next);
    try testing.expectEqual(0x1200, get(.next_or_prev, 0x1201).prev);
    try testing.expectEqual(.none, get(.next_or_prev, 0x1235));
}
test "get union unpacked, direct" {
    try testing.expectEqual(0x1234, get(.next_or_prev_direct, 0x1233).next);
    try testing.expectEqual(0x1200, get(.next_or_prev_direct, 0x1201).prev);
    try testing.expectEqual(.none, get(.next_or_prev_direct, 0x1235));
}
test "get union packed, shift" {
    try testing.expectEqual(5, @bitSizeOf(@FieldType(TypeOfAll("pack"), "bidi_paired_bracket")));
    try testing.expectEqual(0x0029, get(.bidi_paired_bracket, 0x0028).open);
    try testing.expectEqual(0x2997, get(.bidi_paired_bracket, 0x2998).close);
    try testing.expectEqual(.none, get(.bidi_paired_bracket, 0x4000));
}
test "get union packed, direct" {
    try testing.expectEqual(0x0029, get(.bidi_paired_bracket_direct, 0x0028).open);
    try testing.expectEqual(0x2997, get(.bidi_paired_bracket_direct, 0x2998).close);
    try testing.expectEqual(.none, get(.bidi_paired_bracket_direct, 0x4000));
}
test "get bidi_class" {
    try testing.expectEqual(.arabic_number, get(.bidi_class, 0x0600));
}
test "special_casing_condition" {
    const conditions1 = get(.special_casing_condition, 65); 
    try testing.expectEqual(0, conditions1.len);
    const conditions = get(.special_casing_condition, 0x03A3);
    try testing.expectEqual(1, conditions.len);
    try testing.expectEqual(types.SpecialCasingCondition.final_sigma, conditions[0]);
}
test "info extension" {
    try testing.expectEqual(0x004A, get(.uppercase_mapping_first_char, 0x01F0));
    try testing.expect(get(.has_simple_lowercase, 0x1FD9)); 
    try testing.expect(!get(.has_simple_lowercase, 0x1FE0)); 
    try testing.expect(std.mem.eql(u8, "061/1", get(.numeric_value_numeric_reversed, 0x0D58)));
}
test "is_emoji_vs_base" {
    try testing.expect(get(.is_emoji_vs_base, 0x231B)); 
    try testing.expect(get(.is_emoji_vs_base, 0x1F327)); 
    try testing.expect(!get(.is_emoji_vs_base, 0x1F46C)); 
}
test "bidi_mirroring" {
    try testing.expectEqual(0x0029, get(.bidi_mirroring, 0x0028)); 
    try testing.expectEqual(0x0028, get(.bidi_mirroring, 0x0029)); 
    try testing.expectEqual(null, get(.bidi_mirroring, 0x0041)); 
}
test "block" {
    try testing.expectEqual(.basic_latin, get(.block, 0x0041)); 
    try testing.expectEqual(.greek_and_coptic, get(.block, 0x03B1)); 
    try testing.expectEqual(.cjk_unified_ideographs, get(.block, 0x4E00)); 
}
test "script" {
    try testing.expectEqual(.latin, get(.script, 0x0041)); 
    try testing.expectEqual(.greek, get(.script, 0x03B1)); 
    try testing.expectEqual(.han, get(.script, 0x4E00)); 
    try testing.expectEqual(.arabic, get(.script, 0x0627)); 
}
test "decomposition" {
    var buffer: [1]u21 = undefined;
    var mapping = get(.decomposition_mapping, 0x00C0).with(&buffer, 0x00C0);
    try testing.expectEqual(.canonical, get(.decomposition_type, 0x00C0));
    try testing.expect(std.mem.eql(u21, mapping, &.{ 0x0041, 0x0300 }));
    mapping = get(.decomposition_mapping, 0xFCC8).with(&buffer, 0xFCC8);
    try testing.expectEqual(.initial, get(.decomposition_type, 0xFCC8));
    try testing.expect(std.mem.eql(u21, mapping, &.{ 0x0643, 0x0645 }));
    mapping = get(.decomposition_mapping, 0x0041).with(&buffer, 0x0041);
    try testing.expectEqual(.default, get(.decomposition_type, 0x0041));
    try testing.expect(std.mem.eql(u21, mapping, &.{0x0041}));
}
test "canonical_decomposition" {
    var buffer: [1]u21 = undefined;
    var mapping = get(.canonical_decomposition_mapping, 0x00C0).with(&buffer, 0x00C0);
    try testing.expect(std.mem.eql(u21, mapping, &.{ 0x0041, 0x0300 }));
    mapping = get(.canonical_decomposition_mapping, 0xFCC8).with(&buffer, 0xFCC8);
    try testing.expectEqual(0, mapping.len);
}
test "is_composition_exclusion" {
    try testing.expect(get(.is_composition_exclusion, 0x0958));
    try testing.expect(!get(.is_composition_exclusion, 0x0300));
}
test "joining_type" {
    try testing.expectEqual(.dual_joining, get(.joining_type, 0x0628)); 
    try testing.expectEqual(.right_joining, get(.joining_type, 0x0627)); 
    try testing.expectEqual(.non_joining, get(.joining_type, 0x0041)); 
}
test "joining_group" {
    try testing.expectEqual(.beh, get(.joining_group, 0x0628)); 
    try testing.expectEqual(.alef, get(.joining_group, 0x0627)); 
    try testing.expectEqual(.no_joining_group, get(.joining_group, 0x0041)); 
}
test "indic_positional_category" {
    try testing.expectEqual(.top, get(.indic_positional_category, 0x0A81)); 
    try testing.expectEqual(.right, get(.indic_positional_category, 0x1182E)); 
    try testing.expectEqual(.not_applicable, get(.indic_positional_category, 0x0041)); 
}
test "indic_syllabic_category" {
    try testing.expectEqual(.consonant, get(.indic_syllabic_category, 0x0A97)); 
    try testing.expectEqual(.vowel_dependent, get(.indic_syllabic_category, 0x1182E)); 
    try testing.expectEqual(.other, get(.indic_syllabic_category, 0x0041)); 
}
test "east_asian_width" {
    try testing.expectEqual(.narrow, get(.east_asian_width, 0x0041)); 
    try testing.expectEqual(.wide, get(.east_asian_width, 0x4E00)); 
    try testing.expectEqual(.fullwidth, get(.east_asian_width, 0xFF01)); 
}
test "canonical_combining_class" {
    try testing.expectEqual(@as(u8, 230), get(.canonical_combining_class, 0x0300)); 
    try testing.expectEqual(@as(u8, 0), get(.canonical_combining_class, 0x0041)); 
}
test "numeric_type" {
    try testing.expectEqual(.decimal, get(.numeric_type, 0x0030)); 
    try testing.expectEqual(.digit, get(.numeric_type, 0x00B2)); 
    try testing.expectEqual(.numeric, get(.numeric_type, 0x00BD)); 
    try testing.expectEqual(.none, get(.numeric_type, 0x0041)); 
}
test "numeric_value_decimal" {
    try testing.expectEqual(@as(?u4, 0), get(.numeric_value_decimal, 0x0030)); 
    try testing.expectEqual(@as(?u4, 5), get(.numeric_value_decimal, 0x0035)); 
    try testing.expectEqual(@as(?u4, null), get(.numeric_value_decimal, 0x0041)); 
}
test "numeric_value_digit" {
    try testing.expectEqual(@as(?u4, 2), get(.numeric_value_digit, 0x00B2)); 
    try testing.expectEqual(@as(?u4, null), get(.numeric_value_digit, 0x0041)); 
}
test "is_bidi_mirrored" {
    try testing.expect(get(.is_bidi_mirrored, 0x0028)); 
    try testing.expect(!get(.is_bidi_mirrored, 0x0041)); 
}
test "unicode_1_name" {
    try testing.expect(std.mem.eql(u8, "NULL", get(.unicode_1_name, 0x0000)));
    try testing.expect(std.mem.eql(u8, "", get(.unicode_1_name, 0x0041))); 
}
test "simple_titlecase_mapping" {
    try testing.expectEqual(0x0041, get(.simple_titlecase_mapping, 0x0061)); 
    try testing.expectEqual(0x0041, get(.simple_titlecase_mapping, 0x0041)); 
}
test "simple_lowercase_mapping" {
    try testing.expectEqual(0x0061, get(.simple_lowercase_mapping, 0x0041)); 
    try testing.expectEqual(0x0061, get(.simple_lowercase_mapping, 0x0061)); 
}
test "case_folding_full" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.case_folding_full, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0073, mapping[0]);
    try testing.expectEqual(0x0073, mapping[1]);
}
test "case_folding_turkish_only" {
    try testing.expectEqual(0x0131, get(.case_folding_turkish_only, 0x0049).?);
    try testing.expectEqual(0x0069, get(.case_folding_turkish_only, 0x0130).?);
    try testing.expectEqual(null, get(.case_folding_turkish_only, 0x0041));
}
test "case_folding_common_only" {
    try testing.expectEqual(0x0061, get(.case_folding_common_only, 0x0041).?);
    try testing.expectEqual(null, get(.case_folding_common_only, 0x1E9E));
    try testing.expectEqual(0x1E943, get(.case_folding_common_only, 0x1E921).?);
}
test "case_folding_simple_only" {
    try testing.expectEqual(0x00DF, get(.case_folding_simple_only, 0x1E9E).?);
    try testing.expectEqual(0x1F80, get(.case_folding_simple_only, 0x1F88).?);
    try testing.expectEqual(null, get(.case_folding_simple_only, 0x0041));
}
test "case_folding _only fields in a packed table" {
    try testing.expectEqual(null, get(.case_folding_turkish_only, 0x10FFFF));
    try testing.expectEqual(null, get(.case_folding_common_only, 0x10FFFF));
    try testing.expectEqual(null, get(.case_folding_simple_only, 0x10FFFF));
    try testing.expectEqual(null, get(.case_folding_turkish_only, 0x0000));
    try testing.expectEqual(null, get(.case_folding_common_only, 0x0000));
    try testing.expectEqual(null, get(.case_folding_simple_only, 0x0000));
}
test "case_folding_full_only" {
    const mapping = get(.case_folding_full_only, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0073, mapping[0]);
    try testing.expectEqual(0x0073, mapping[1]);
}
test "has_special_casing" {
    try testing.expect(get(.has_special_casing, 0x00DF)); 
    try testing.expect(!get(.has_special_casing, 0x0041)); 
}
test "special_lowercase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping_df = get(.special_lowercase_mapping, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(1, mapping_df.len);
    try testing.expectEqual(0x00DF, mapping_df[0]);
    const mapping_a = get(.special_lowercase_mapping, 65).with(&buffer, 65);
    try testing.expectEqual(0, mapping_a.len);
}
test "special_titlecase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.special_titlecase_mapping, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0053, mapping[0]);
    try testing.expectEqual(0x0073, mapping[1]);
}
test "special_uppercase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.special_uppercase_mapping, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0053, mapping[0]);
    try testing.expectEqual(0x0053, mapping[1]);
}
test "special_lowercase_mapping_conditional" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.special_lowercase_mapping_conditional, 0x03A3).with(&buffer, 0x03A3);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x03C2, mapping[0]); 
}
test "special_titlecase_mapping_conditional" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.special_titlecase_mapping_conditional, 0x03A3).with(&buffer, 0x03A3);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x03A3, mapping[0]);
}
test "special_uppercase_mapping_conditional" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.special_uppercase_mapping_conditional, 0x03A3).with(&buffer, 0x03A3);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x03A3, mapping[0]);
}
test "lowercase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.lowercase_mapping, 0x0041).with(&buffer, 0x0041); 
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0061, mapping[0]);
}
test "uppercase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.uppercase_mapping, 0x0061).with(&buffer, 0x0061); 
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0041, mapping[0]);
}
test "titlecase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.titlecase_mapping, 0x0061).with(&buffer, 0x0061); 
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0041, mapping[0]);
}
test "is_math" {
    try testing.expect(get(.is_math, 0x002B)); 
    try testing.expect(!get(.is_math, 0x0041)); 
}
test "is_cased" {
    try testing.expect(get(.is_cased, 0x0041)); 
    try testing.expect(!get(.is_cased, 0x0030)); 
}
test "is_case_ignorable" {
    try testing.expect(get(.is_case_ignorable, 0x0027)); 
    try testing.expect(!get(.is_case_ignorable, 0x0041)); 
}
test "changes_when_lowercased" {
    try testing.expect(get(.changes_when_lowercased, 0x0041)); 
    try testing.expect(!get(.changes_when_lowercased, 0x0061)); 
}
test "changes_when_uppercased" {
    try testing.expect(get(.changes_when_uppercased, 0x0061)); 
    try testing.expect(!get(.changes_when_uppercased, 0x0041)); 
}
test "changes_when_titlecased" {
    try testing.expect(get(.changes_when_titlecased, 0x0061)); 
    try testing.expect(!get(.changes_when_titlecased, 0x0041)); 
}
test "changes_when_casefolded" {
    try testing.expect(get(.changes_when_casefolded, 0x0041)); 
    try testing.expect(!get(.changes_when_casefolded, 0x0061)); 
}
test "changes_when_casemapped" {
    try testing.expect(get(.changes_when_casemapped, 0x0041)); 
    try testing.expect(!get(.changes_when_casemapped, 0x0030)); 
}
test "is_id_start" {
    try testing.expect(get(.is_id_start, 0x0041)); 
    try testing.expect(!get(.is_id_start, 0x0030)); 
}
test "is_id_continue" {
    try testing.expect(get(.is_id_continue, 0x0041)); 
    try testing.expect(get(.is_id_continue, 0x0030)); 
}
test "is_xid_start" {
    try testing.expect(get(.is_xid_start, 0x0041)); 
    try testing.expect(!get(.is_xid_start, 0x0030)); 
}
test "is_xid_continue" {
    try testing.expect(get(.is_xid_continue, 0x0041)); 
    try testing.expect(get(.is_xid_continue, 0x0030)); 
}
test "is_default_ignorable" {
    try testing.expect(get(.is_default_ignorable, 0x00AD)); 
    try testing.expect(!get(.is_default_ignorable, 0x0041)); 
}
test "is_grapheme_extend" {
    try testing.expect(get(.is_grapheme_extend, 0x0300)); 
    try testing.expect(!get(.is_grapheme_extend, 0x0041)); 
}
test "is_grapheme_base" {
    try testing.expect(get(.is_grapheme_base, 0x0041)); 
    try testing.expect(!get(.is_grapheme_base, 0x0300)); 
}
test "is_grapheme_link" {
    try testing.expect(get(.is_grapheme_link, 0x094D)); 
    try testing.expect(!get(.is_grapheme_link, 0x0041)); 
}
test "indic_conjunct_break" {
    try testing.expectEqual(.linker, get(.indic_conjunct_break, 0x094D)); 
    try testing.expectEqual(.consonant, get(.indic_conjunct_break, 0x0915)); 
    try testing.expectEqual(.none, get(.indic_conjunct_break, 0x0041)); 
}
test "original_grapheme_break" {
    try testing.expectEqual(.cr, get(.original_grapheme_break, 0x000D));
    try testing.expectEqual(.lf, get(.original_grapheme_break, 0x000A));
    try testing.expectEqual(.other, get(.original_grapheme_break, 0x0041)); 
}
test "Unicode 18 Indic linker classifications" {
    const extend_linkers = [_]u21{
        0x094D,  0x09CD,  0x0ACD,  0x0B4D,  0x0C4D,
        0x0D4D,  0x1039,  0x17D2,  0x1A60,  0x1B44,
        0x1BAB,  0xA9C0,  0xAAF6,  0x10A3F, 0x11133,
        0x113D0, 0x1193E, 0x11A47, 0x11A99, 0x11F42,
    };
    const other_linkers = [_]u21{ 0x1CF5, 0x1CF6, 0x11A3A };
    for (extend_linkers) |cp| {
        try testing.expectEqual(.linker, get(.indic_conjunct_break, cp));
        try testing.expectEqual(.extend, get(.original_grapheme_break, cp));
        try testing.expectEqual(.indic_conjunct_break_linker_extend, get(.grapheme_break, cp));
        try testing.expectEqual(.indic_conjunct_break_linker_extend, get(.grapheme_break_no_control, cp));
    }
    for (other_linkers) |cp| {
        try testing.expectEqual(.linker, get(.indic_conjunct_break, cp));
        try testing.expectEqual(.other, get(.original_grapheme_break, cp));
        try testing.expectEqual(.indic_conjunct_break_linker_other, get(.grapheme_break, cp));
        try testing.expectEqual(.indic_conjunct_break_linker_other, get(.grapheme_break_no_control, cp));
    }
}
test "is_emoji" {
    try testing.expect(get(.is_emoji, 0x1F600)); 
    try testing.expect(!get(.is_emoji, 0x0041)); 
}
test "is_emoji_presentation" {
    try testing.expect(get(.is_emoji_presentation, 0x1F600)); 
    try testing.expect(!get(.is_emoji_presentation, 0x0041)); 
}
test "is_emoji_modifier" {
    try testing.expect(get(.is_emoji_modifier, 0x1F3FB)); 
    try testing.expect(!get(.is_emoji_modifier, 0x0041)); 
}
test "is_emoji_component" {
    try testing.expect(get(.is_emoji_component, 0x1F3FB)); 
    try testing.expect(!get(.is_emoji_component, 0x0041)); 
}
test "is_extended_pictographic" {
    try testing.expect(get(.is_extended_pictographic, 0x1F600)); 
    try testing.expect(!get(.is_extended_pictographic, 0x0041)); 
}
test "wcwidth_standalone control characters are width 0" {
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x0000)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x001F)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x007F)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x0080)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x009F)); 
}
test "wcwidth_standalone surrogates are width 0" {
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xD800)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xDBFF)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xDC00)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xDFFF)); 
}
test "wcwidth_standalone line and paragraph separators are width 0" {
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x2028)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x2029)); 
}
test "wcwidth_standalone default ignorable characters are width 0" {
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x200B)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x200C)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0x200D)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xFE00)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xFE0F)); 
    try testing.expectEqual(0, get(.wcwidth_standalone, 0xFEFF)); 
}
test "wcwidth_standalone soft hyphen exception is width 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x00AD)); 
}
test "wcwidth_standalone combining marks are width 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x0300)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x0903)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x20DD)); 
}
test "wcwidth_zero_in_grapheme combining marks" {
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x0300)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x0341)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x20DD)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x20DE)); 
    try testing.expect(!get(.wcwidth_zero_in_grapheme, 0x0903)); 
    try testing.expect(!get(.wcwidth_zero_in_grapheme, 0x093E)); 
    try testing.expect(!get(.wcwidth_zero_in_grapheme, 0x302E)); 
    try testing.expect(!get(.wcwidth_zero_in_grapheme, 0x302F)); 
    try testing.expect(!get(.wcwidth_zero_in_grapheme, 0x16FF0)); 
    try testing.expect(!get(.wcwidth_zero_in_grapheme, 0x16FF1)); 
}
test "wcwidth_standalone combining enclosing keycap exception is width 2" {
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x20E3)); 
}
test "wcwidth_zero_in_grapheme combining enclosing keycap exception is true" {
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x20E3)); 
}
test "wcwidth_standalone regional indicators are width 2" {
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1F1E6)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1F1FA)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1F1F8)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1F1FF)); 
}
test "wcwidth_standalone em dashes have special widths" {
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x2E3A)); 
    try testing.expectEqual(3, get(.wcwidth_standalone, 0x2E3B)); 
}
test "wcwidth_standalone ambiguous width characters are width 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x00A1)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x00B1)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x2664)); 
}
test "wcwidth_standalone east asian wide and fullwidth are width 2" {
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x3000)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0xFF01)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x4E00)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0xAC00)); 
}
test "wcwidth_standalone hangul jamo V and T are width 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x1161)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x11A8)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0xD7B0)); 
    try testing.expectEqual(1, get(.wcwidth_standalone, 0xD7CB)); 
}
test "wcwidth_zero_in_grapheme hangul jamo V and T are true" {
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x1161)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x11A8)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0xD7B0)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0xD7CB)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x16D63)); 
}
test "wcwidth_standalone format characters non-DI are width 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x0600)); 
}
test "wcwidth_zero_in_grapheme format characters non-DI is true" {
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x0600)); 
}
test "wcwidth_standalone prepend characters are width 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x0D4E));
}
test "wcwidth_zero_in_grapheme prepend characters are true" {
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x0D4E));
}
test "wcwidth_standalone emoji with default text presentation is 1" {
    try testing.expectEqual(1, get(.wcwidth_standalone, 0x1F3CB));
}
test "wcwidth_standalone emoji_modifier is 2" {
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1F3FB)); 
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1F3FF)); 
}
test "wcwidth_zero_in_grapheme emoji_modifier is true" {
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x1F3FB)); 
    try testing.expect(get(.wcwidth_zero_in_grapheme, 0x1F3FF)); 
}
test "Unicode 18 scripts and blocks" {
    const cases = [_]struct { cp: u21, block: types.Block, script: types.Script }{
        .{ .cp = 0x11DF0, .block = .bengali_supplement, .script = .bengali },
        .{ .cp = 0x12550, .block = .archaic_cuneiform_numerals, .script = .cuneiform },
        .{ .cp = 0x125A8, .block = .archaic_cuneiform_numerals, .script = .proto_cuneiform },
        .{ .cp = 0x18E00, .block = .jurchen, .script = .jurchen },
        .{ .cp = 0x19191, .block = .jurchen, .script = .jurchen },
        .{ .cp = 0x191A0, .block = .jurchen_radicals, .script = .jurchen },
        .{ .cp = 0x1D250, .block = .musical_symbols_supplement, .script = .common },
        .{ .cp = 0x1DB10, .block = .miscellaneous_symbols_and_arrows_extended, .script = .common },
        .{ .cp = 0x3D000, .block = .seal, .script = .seal },
        .{ .cp = 0x3FC3F, .block = .seal, .script = .seal },
    };
    for (cases) |case| {
        try testing.expectEqual(case.block, get(.block, case.cp));
        try testing.expectEqual(case.script, get(.script, case.cp));
        try testing.expect(get(.general_category, case.cp) != .other_not_assigned);
    }
    try testing.expectEqual(.other_not_assigned, get(.general_category, 0x19192));
    try testing.expectEqual(.other_not_assigned, get(.general_category, 0x3FC40));
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x18E00));
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x3D000));
    try testing.expectEqualStrings("CUNEIFORM NUMERIC SIGN ONE N01", get(.name, 0x12550));
}
test "Unicode 18 mappings and emoji" {
    try testing.expectEqual(0x00DF, get(.case_folding_simple, 0x1DF95));
    try testing.expectEqual(0x00DF, get(.case_folding_simple_only, 0x1DF95));
    try testing.expectEqual(0x1DB10, get(.bidi_mirroring, 0x221D));
    try testing.expectEqual(0x221D, get(.bidi_mirroring, 0x1DB10));
    try testing.expectEqual(.crown_beh, get(.joining_group, 0x10ED9));
    try testing.expectEqual(.crown_heh, get(.joining_group, 0x10EED));
    try testing.expectEqualStrings("PICKLE", get(.name, 0x1FADD));
    try testing.expect(get(.is_emoji, 0x1FADD));
    try testing.expect(get(.is_emoji_presentation, 0x1FADD));
    try testing.expectEqual(2, get(.wcwidth_standalone, 0x1FADD));
}
