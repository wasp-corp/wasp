const std = @import("std");
const oni = @import("oniguruma");
const url_schemes =
    \\https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:
;
const ipv6_url_pattern =
    \\(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)
;
const scheme_url_chars =
    \\[\w\-.~:/?#@!$&*+,;=%]
;
const path_chars =
    \\[\w\-.~:\/?#@!$&*+;=%]
;
const optional_bracketed_word_suffix =
    \\(?:[\(\[]\w*[\)\]])?
;
const no_trailing_punctuation =
    \\(?<![,.])
;
const no_trailing_colon =
    \\(?<!:)
;
const dotted_path_lookahead =
    \\(?=[\w\-.~:\/?#@!$&*+;=%]*\.)
;
const non_dotted_path_lookahead =
    \\(?![\w\-.~:\/?#@!$&*+;=%]*\.)
;
const dotted_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*
;
const any_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]+)*
;
const scheme_url_branch =
    "(?:" ++ url_schemes ++ ")" ++
    "(?:" ++ ipv6_url_pattern ++ "|" ++ scheme_url_chars ++ "+" ++ optional_bracketed_word_suffix ++ ")+" ++
    no_trailing_punctuation;
const rooted_or_relative_path_prefix =
    \\(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))
;
const rooted_or_relative_path_branch =
    rooted_or_relative_path_prefix ++
    "(?:" ++
    dotted_path_lookahead ++
    path_chars ++ "+" ++
    dotted_path_space_segments ++
    no_trailing_colon ++
    "|" ++
    non_dotted_path_lookahead ++
    path_chars ++ "+" ++
    any_path_space_segments ++
    no_trailing_colon ++
    ")";
const bare_relative_path_prefix =
    \\(?<!\$\d*)(?<!\w)[\w][\w\-.]*\/
;
const bare_relative_path_branch =
    dotted_path_lookahead ++
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_colon;
pub const regex =
    scheme_url_branch ++
    "|" ++
    rooted_or_relative_path_branch ++
    "|" ++
    bare_relative_path_branch;
test "url regex" {
    const testing = std.testing;
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();
    const cases = [_]struct {
        input: []const u8,
        expect: []const u8,
        num_matches: usize = 1,
    }{
        .{
            .input = "hello https://example.com world",
            .expect = "https://example.com",
        },
        .{
            .input = "https://example.com/foo(bar) more",
            .expect = "https://example.com/foo(bar)",
        },
        .{
            .input = "https://example.com/foo(bar)baz more",
            .expect = "https://example.com/foo(bar)baz",
        },
        .{
            .input = "Link inside (https://example.com) parens",
            .expect = "https://example.com",
        },
        .{
            .input = "Link period https://example.com. More text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link trailing comma https://example.com, more text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in double quotes \"https://example.com\" and more",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in single quotes 'https://example.com' and more",
            .expect = "https://example.com",
        },
        .{
            .input = "some file with https://google.com https://duckduckgo.com links.",
            .expect = "https://google.com",
        },
        .{
            .input = "and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4",
            .expect = "https://yahoo.com",
        },
        .{
            .input = "also match http://example.com non-secure links",
            .expect = "http://example.com",
        },
        .{
            .input = "match tel://+12123456789 phone numbers",
            .expect = "tel://+12123456789",
        },
        .{
            .input = "match with query url https://example.com?query=1&other=2 and more text.",
            .expect = "https://example.com?query=1&other=2",
        },
        .{
            .input = "url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support",
            .expect = "https://github.com/contour-terminal/terminal-unicode-core",
        },
        .{
            .input = "dot.http://example.com",
            .expect = "http://example.com",
        },
        .{
            .input = "weird characters https://example.com/~user/?query=1&other=2#hash and more",
            .expect = "https://example.com/~user/?query=1&other=2#hash",
        },
        .{
            .input = "square brackets https://example.com/[foo] and more",
            .expect = "https://example.com/[foo]",
        },
        .{
            .input = "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
            .expect = "https://example.com/docs/Too-Many-Statements.md",
        },
        .{
            .input = "match ftp://example.com ftp links",
            .expect = "ftp://example.com",
        },
        .{
            .input = "match file://example.com file links",
            .expect = "file://example.com",
        },
        .{
            .input = "match ssh://example.com ssh links",
            .expect = "ssh://example.com",
        },
        .{
            .input = "match git://example.com git links",
            .expect = "git://example.com",
        },
        .{
            .input = "/tmp/test.txt http://www.google.com",
            .expect = "/tmp/test.txt",
        },
        .{
            .input = "match tel:+18005551234 tel links",
            .expect = "tel:+18005551234",
        },
        .{
            .input = "match magnet:?xt=urn:btih:1234567890 magnet links",
            .expect = "magnet:?xt=urn:btih:1234567890",
        },
        .{
            .input = "match ipfs://QmSomeHashValue ipfs links",
            .expect = "ipfs://QmSomeHashValue",
        },
        .{
            .input = "match ipns://QmSomeHashValue ipns links",
            .expect = "ipns://QmSomeHashValue",
        },
        .{
            .input = "match gemini://example.com gemini links",
            .expect = "gemini://example.com",
        },
        .{
            .input = "match gopher://example.com gopher links",
            .expect = "gopher://example.com",
        },
        .{
            .input = "match news:comp.infosystems.www.servers.unix news links",
            .expect = "news:comp.infosystems.www.servers.unix",
        },
        .{
            .input = "/Users/wasp.user/code/example.py",
            .expect = "/Users/wasp.user/code/example.py",
        },
        .{
            .input = "/Users/wasp.user/code/../example.py",
            .expect = "/Users/wasp.user/code/../example.py",
        },
        .{
            .input = "/Users/wasp.user/code/../example.py hello world",
            .expect = "/Users/wasp.user/code/../example.py",
        },
        .{
            .input = "../example.py",
            .expect = "../example.py",
        },
        .{
            .input = "../example.py ",
            .expect = "../example.py",
        },
        .{
            .input = "first time ../example.py contributor ",
            .expect = "../example.py",
        },
        .{
            .input = "[link](/home/user/wasp.user/example)",
            .expect = "/home/user/wasp.user/example",
        },
        .{
            .input = "Serving HTTP on :: port 8000 (http://[::]:8000/)",
            .expect = "http://[::]:8000/",
        },
        .{
            .input = "IPv6 address https://[2001:db8::1]:8080/path",
            .expect = "https://[2001:db8::1]:8080/path",
        },
        .{
            .input = "IPv6 localhost http://[::1]:3000",
            .expect = "http://[::1]:3000",
        },
        .{
            .input = "Complex IPv6 https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
            .expect = "https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
        },
        .{
            .input = "IPv6 with path https://[2001:db8::1]/path/to/resource",
            .expect = "https://[2001:db8::1]/path/to/resource",
        },
        .{
            .input = "IPv6 with query https://[2001:db8::1]:8080/api?param=value&other=123",
            .expect = "https://[2001:db8::1]:8080/api?param=value&other=123",
        },
        .{
            .input = "IPv6 compressed http://[2001:db8::]:80/",
            .expect = "http://[2001:db8::]:80/",
        },
        .{
            .input = "IPv6 multiple zeros http://[2001:0:0:0:0:0:0:1]",
            .expect = "http://[2001:0:0:0:0:0:0:1]",
        },
        .{
            .input = "IPv6 link-local https://[fe80::1234:5678:9abc]",
            .expect = "https://[fe80::1234:5678:9abc]",
        },
        .{
            .input = "IPv6 multicast http://[ff02::1]/stream",
            .expect = "http://[ff02::1]/stream",
        },
        .{
            .input = "IPv6 in markdown [link](http://[2001:db8::1]/docs)",
            .expect = "http://[2001:db8::1]/docs",
        },
        .{
            .input = "./spaces-end.   ",
            .expect = "./spaces-end.",
        },
        .{
            .input = "./space middle",
            .expect = "./space middle",
        },
        .{
            .input = "../test folder/file.txt",
            .expect = "../test folder/file.txt",
        },
        .{
            .input = "/tmp/test folder/file.txt",
            .expect = "/tmp/test folder/file.txt",
        },
        .{
            .input = "/tmp/test  folder/file.txt",
            .expect = "/tmp/test",
        },
        .{
            .input = "diff --git a/src/font/shaper/harfbuzz.zig b/src/font/shaper/harfbuzz.zig",
            .expect = "a/src/font/shaper/harfbuzz.zig",
        },
        .{
            .input = "/tmp/foo /tmp/bar",
            .expect = "/tmp/foo",
        },
        .{
            .input = "/tmp/foo.txt /tmp/bar.txt",
            .expect = "/tmp/foo.txt",
        },
        .{
            .input = "src/config/url.zig",
            .expect = "src/config/url.zig",
        },
        .{
            .input = "app/folder/file.rb:1",
            .expect = "app/folder/file.rb:1",
        },
        .{
            .input = "modified:   src/config/url.zig",
            .expect = "src/config/url.zig",
        },
        .{
            .input = "lib/wasp/terminal.zig:42:10",
            .expect = "lib/wasp/terminal.zig:42:10",
        },
        .{
            .input = "some-pkg/src/file.txt more text",
            .expect = "some-pkg/src/file.txt",
        },
        .{
            .input = "src/foo.c,baz.txt",
            .expect = "src/foo.c",
        },
        .{
            .input = "~/foo/bar.txt",
            .expect = "~/foo/bar.txt",
        },
        .{
            .input = "open ~/Documents/notes.md please",
            .expect = "~/Documents/notes.md",
        },
        .{
            .input = "~/.config/wasp/config",
            .expect = "~/.config/wasp/config",
        },
        .{
            .input = "directory: ~/src/wasp-org/wasp",
            .expect = "~/src/wasp-org/wasp",
        },
        .{
            .input = "$HOME/src/config/url.zig",
            .expect = "$HOME/src/config/url.zig",
        },
        .{
            .input = "project dir: $PWD/src/wasp/main.zig",
            .expect = "$PWD/src/wasp/main.zig",
        },
        .{
            .input = "foo/$BAR/baz",
            .expect = "foo/$BAR/baz",
        },
        .{
            .input = ".foo/bar/$VAR",
            .expect = ".foo/bar/$VAR",
        },
        .{
            .input = ".config/wasp/config",
            .expect = ".config/wasp/config",
        },
        .{
            .input = "loaded from .local/share/wasp/state.db now",
            .expect = ".local/share/wasp/state.db",
        },
        .{
            .input = "../some/where",
            .expect = "../some/where",
        },
        .{
            .input = "  - shared/src/foo/SomeItem.m:12, shared/src/",
            .expect = "shared/src/foo/SomeItem.m:12",
        },
        .{
            .input = "foo.local/share",
            .expect = "foo.local/share",
        },
        .{
            .input = "2024/report.txt",
            .expect = "2024/report.txt",
        },
        .{
            .input = "./foo bar,baz",
            .expect = "./foo bar",
        },
        .{
            .input = "/tmp/foo bar,baz",
            .expect = "/tmp/foo bar",
        },
        .{
            .input = "./.config/wasp: Needs upstream (main)",
            .expect = "./.config/wasp",
        },
        .{
            .input = "./Downloads: Operation not permitted",
            .expect = "./Downloads",
        },
    };
    for (cases) |case| {
        var reg = try re.search(case.input, .{});
        defer reg.deinit();
        try testing.expectEqual(@as(usize, case.num_matches), reg.count());
        const match = case.input[@intCast(reg.starts()[0])..@intCast(reg.ends()[0])];
        try testing.expectEqualStrings(case.expect, match);
    }
    const no_match_cases = [_][]const u8{
        "input/output",
        "foo/bar",
        "$10/bar",
        "$10/$20",
        "$10/bar.txt",
        "foo/bar,baz.txt",
        "foo$BAR/baz.txt",
        "foo~/bar.txt",
        "// foo bar",
        "//foo",
    };
    for (no_match_cases) |input| {
        var result = re.search(input, .{});
        if (result) |*reg| {
            reg.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
