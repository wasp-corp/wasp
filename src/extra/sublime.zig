const Config = @import("../config/Config.zig");
const Template = struct {
    const header =
        \\%YAML 1.2
        \\---
        \\# See http://www.sublimetext.com/docs/syntax.html
        \\name: Wasp Config
        \\file_extensions:
        \\  - wasp
        \\scope: source.wasp
        \\
        \\contexts:
        \\  main:
        \\    # Comments
        \\    - match: '^\s*#.*$'
        \\      scope: comment.line.number-sign.wasp
        \\
        \\    # Keywords
        \\    - match: '\b(
    ;
    const footer =
        \\)\b'
        \\      scope: keyword.other.wasp
        \\
    ;
};
fn isInternal(name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}
fn generateKeywords() []const u8 {
    @setEvalBranchQuota(5000);
    var keywords: []const u8 = "";
    const config_fields = @typeInfo(Config).@"struct".fields;
    for (config_fields) |field| {
        if (isInternal(field.name)) continue;
        if (keywords.len > 0) keywords = keywords ++ "|";
        keywords = keywords ++ field.name;
    }
    return keywords;
}
pub const syntax = Template.header ++ generateKeywords() ++ Template.footer;
