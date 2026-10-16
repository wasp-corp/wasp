const std = @import("std");
const Config = @import("../config/Config.zig");
pub const syntax = comptimeGenSyntax();
pub const ftdetect =
    \\" Vim filetype detect file
    \\" Language: Wasp config file
    \\" Maintainer: Wasp <https://github.com/wasp-org/wasp>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\au BufRead,BufNewFile */wasp/config,*/*.wasp/config,*/wasp/themes/*,*.wasp setf wasp
    \\
;
pub const ftplugin =
    \\" Vim filetype plugin file
    \\" Language: Wasp config file
    \\" Maintainer: Wasp <https://github.com/wasp-org/wasp>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\if exists('b:did_ftplugin')
    \\  finish
    \\endif
    \\let b:did_ftplugin = 1
    \\
    \\setlocal commentstring=#\ %s
    \\setlocal iskeyword+=-
    \\
    \\" Use syntax keywords for completion
    \\setlocal omnifunc=syntaxcomplete#Complete
    \\
    \\" Ask wasp to explain config keywords
    \\setlocal keywordprg=wasp\ +explain-config
    \\
    \\let b:undo_ftplugin = 'setl cms< isk< ofu< kp<'
    \\
    \\if !exists('current_compiler')
    \\  compiler wasp
    \\  let b:undo_ftplugin .= " makeprg< errorformat<"
    \\endif
    \\
;
pub const compiler =
    \\" Vim compiler file
    \\" Language: Wasp config file
    \\" Maintainer: Wasp <https://github.com/wasp-org/wasp>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\if exists("current_compiler")
    \\  finish
    \\endif
    \\let current_compiler = "wasp"
    \\
    \\CompilerSet makeprg=wasp\ +validate-config\ --config-file=%:S
    \\CompilerSet errorformat=%f:%l:%m,%m
    \\
;
fn comptimeGenSyntax() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writeSyntax(&counter.writer);
        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeSyntax(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}
fn writeSyntax(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\" Vim syntax file
        \\" Language: Wasp config file
        \\" Maintainer: Wasp <https://github.com/wasp-org/wasp>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
        \\if exists('b:current_syntax')
        \\  finish
        \\endif
        \\
        \\let b:current_syntax = 'wasp'
        \\
        \\let s:cpo_save = &cpo
        \\set cpo&vim
        \\
        \\syn iskeyword @,48-57,-
        \\syn keyword waspConfigKeyword
    );
    const config_fields = @typeInfo(Config).@"struct".fields;
    inline for (config_fields) |field| {
        if (field.name[0] == '_') continue;
        try writer.print("\n\t\\ {s}", .{field.name});
    }
    try writer.writeAll(
        \\
        \\
        \\syn match waspConfigComment /^\s*#.*/ contains=@Spell
        \\
        \\hi def link waspConfigComment Comment
        \\hi def link waspConfigKeyword Keyword
        \\
        \\let &cpo = s:cpo_save
        \\unlet s:cpo_save
        \\
    );
}
test {
    _ = syntax;
}
