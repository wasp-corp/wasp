const program_status = @This();
const std = @import("std");
const lib = @import("../../lib.zig");
const osc = @import("../../osc.zig");
const encoding = @import("../encoding.zig");
const kitty_metadata = @import("../kitty_metadata.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = osc.Parser;
const OSCCommand = osc.Command;
const Terminator = osc.Terminator;
const log = std.log.scoped(.osc_program_status);
pub const max_sequence_bytes = 4096;
pub const max_body_bytes = max_sequence_bytes - "\x1b]7501;".len - "\x1b\\".len;
pub const max_key_bytes = 16;
pub const max_msg_encoded_bytes = 2732;
pub const max_msg_bytes = 2048;
pub const max_title_encoded_bytes = 256;
pub const max_title_bytes = 192;
pub const max_app_bytes = 32;
pub const max_id_bytes = 128;
pub const max_id_segment_bytes = 32;
pub const max_id_depth = 8;
pub const query_reply = "?:states=" ++
    names(State, &.{.clear}) ++
    ":kinds=" ++
    names(Kind, &.{});
fn names(comptime E: type, comptime skip: []const E) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (@typeInfo(E).@"enum".fields) |field| {
            const value = @field(E, field.name);
            if (std.mem.indexOfScalar(E, skip, value) != null) continue;
            if (result.len > 0) result = result ++ ",";
            result = result ++ field.name;
        }
        return result;
    }
}
pub const Command = union(enum) {
    pub const C = void;
    pub const Report = program_status.Report;
    pub const State = program_status.State;
    pub const Kind = program_status.Kind;
    pub const Option = program_status.Option;
    query: Terminator,
    report: program_status.Report,
};
pub const State = lib.Enum(lib.target, &.{
    "idle",
    "working",
    "done",
    "blocked",
    "error",
    "clear",
});
pub const Kind = lib.Enum(lib.target, &.{
    "permission",
    "question",
    "auth",
});
pub const Report = struct {
    state: State,
    data: []const u8 = "",
    pub fn readOption(
        self: Report,
        comptime option: Option,
    ) ?option.Type() {
        const v = lastValue(@tagName(option), self.data) orelse return null;
        return switch (option) {
            .id => v,
            .app => if (isName(v)) v else null,
            .kind => if (self.state == .blocked) std.meta.stringToEnum(Kind, v) else null,
            .progress => switch (self.state) {
                .working, .blocked => parseProgress(v),
                else => null,
            },
            .title, .msg => if (v.len > 0) v else null,
        };
    }
    pub fn writeText(
        self: Report,
        comptime option: Option,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        comptime assert(option == .title or option == .msg);
        const encoded = self.readOption(option) orelse return;
        var buf: [max_msg_bytes]u8 = undefined;
        try writer.writeAll(decodeText(encoded, &buf) catch unreachable);
    }
};
pub const Option = enum {
    id,
    kind,
    progress,
    app,
    title,
    msg,
    pub fn Type(comptime self: Option) type {
        return switch (self) {
            .kind => Kind,
            .progress => u8,
            .id, .app, .title, .msg => []const u8,
        };
    }
};
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*OSCCommand {
    assert(parser.state == .@"7501");
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    if (data.len > max_body_bytes) {
        log.warn("OSC 7501 sequence too long len={d}", .{data.len});
        parser.state = .invalid;
        return null;
    }
    if (std.mem.eql(u8, data, "?")) {
        parser.command = .{ .program_status = .{ .query = .init(terminator_ch) } };
        return &parser.command;
    }
    const state = validate(data) catch |err| {
        log.warn("invalid OSC 7501 report err={}", .{err});
        parser.state = .invalid;
        return null;
    };
    parser.command = .{ .program_status = .{ .report = .{
        .state = state,
        .data = data,
    } } };
    return &parser.command;
}
fn validate(data: []const u8) error{
    InvalidState,
    InvalidId,
    InvalidText,
    TooLong,
}!State {
    var pairs = std.mem.splitScalar(u8, data, ':');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eq], &std.ascii.whitespace);
        if (key.len > max_key_bytes) return error.TooLong;
    }
    var ids: kitty_metadata.ValueIterator("id", value_bytes) = .init(data);
    while (ids.next()) |v| try validateId(v);
    inline for (.{
        .{ "app", max_app_bytes },
        .{ "title", max_title_encoded_bytes },
        .{ "msg", max_msg_encoded_bytes },
    }) |limit| {
        var it: kitty_metadata.ValueIterator(limit[0], value_bytes) = .init(data);
        while (it.next()) |v| if (v.len > limit[1]) return error.TooLong;
    }
    var buf: [max_msg_bytes]u8 = undefined;
    if (lastValue("title", data)) |v| {
        if ((try decodeText(v, &buf)).len > max_title_bytes) return error.TooLong;
    }
    if (lastValue("msg", data)) |v| _ = try decodeText(v, &buf);
    return std.meta.stringToEnum(
        State,
        lastValue("state", data) orelse return error.InvalidState,
    ) orelse error.InvalidState;
}
fn lastValue(comptime key: []const u8, data: []const u8) ?[]const u8 {
    var it: kitty_metadata.ValueIterator(key, value_bytes) = .init(data);
    var last: ?[]const u8 = null;
    while (it.next()) |v| last = v;
    return last;
}
const name_bytes = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-";
const value_bytes = name_bytes ++ ",/=";
fn isName(s: []const u8) bool {
    return s.len > 0 and std.mem.indexOfNone(u8, s, name_bytes) == null;
}
fn validateId(value: []const u8) error{ InvalidId, TooLong }!void {
    if (value.len > max_id_bytes) return error.TooLong;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, value, '/');
    while (it.next()) |segment| {
        depth += 1;
        if (depth > max_id_depth) return error.TooLong;
        if (segment.len > max_id_segment_bytes) return error.TooLong;
        if (!isName(segment)) return error.InvalidId;
    }
}
fn parseProgress(value: []const u8) ?u8 {
    if (value.len == 0) return null;
    var n: u16 = 0;
    for (value) |c| {
        const digit = std.fmt.charToDigit(c, 10) catch return null;
        n = n * 10 + digit;
        if (n > 100) return null;
    }
    return @intCast(n);
}
fn decodeText(
    encoded: []const u8,
    buf: *[max_msg_bytes]u8,
) error{ InvalidText, TooLong }![]const u8 {
    const decoder = if (std.mem.endsWith(u8, encoded, "="))
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch
        return error.InvalidText;
    if (len > buf.len) return error.TooLong;
    const decoded = buf[0..len];
    decoder.decode(decoded, encoded) catch return error.InvalidText;
    if (!encoding.isSafeUtf8(decoded)) return error.InvalidText;
    return decoded;
}
test "OSC 7501: query" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;?");
    try testing.expectEqual(Terminator.st, p.end('\x1b').?.program_status.query);
    p.reset();
    p.nextSlice("7501;?");
    try testing.expectEqual(Terminator.bel, p.end(0x07).?.program_status.query);
}
test "OSC 7501: query reply lists every state and kind" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        "?:states=idle,working,done,blocked,error:kinds=permission,question,auth",
        query_reply,
    );
}
test "OSC 7501: minimal report" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=idle");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.idle, report.state);
    try testing.expect(report.readOption(.kind) == null);
    try testing.expect(report.readOption(.progress) == null);
    try testing.expect(report.readOption(.id) == null);
    try testing.expect(report.readOption(.app) == null);
    try testing.expect(report.readOption(.title) == null);
    try testing.expect(report.readOption(.msg) == null);
}
test "OSC 7501: all keys" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform" ++
        ":title=UGxhbg==:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.blocked, report.state);
    try testing.expectEqual(Kind.permission, report.readOption(.kind).?);
    try testing.expectEqual(@as(u8, 42), report.readOption(.progress).?);
    try testing.expectEqualStrings("tf/plan", report.readOption(.id).?);
    try testing.expectEqualStrings("terraform", report.readOption(.app).?);
    var buf: [max_msg_bytes]u8 = undefined;
    var title: std.Io.Writer = .fixed(&buf);
    try report.writeText(.title, &title);
    try testing.expectEqualStrings("Plan", title.buffered());
    var msg: std.Io.Writer = .fixed(&buf);
    try report.writeText(.msg, &msg);
    try testing.expectEqualStrings(
        "Apply 3 to add, 1 to change, 0 to destroy?",
        msg.buffered(),
    );
}
test "OSC 7501: base64 padding is optional" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=done:msg=UGxhbg");
    const report = p.end('\x1b').?.program_status.report;
    var buf: [max_msg_bytes]u8 = undefined;
    var msg: std.Io.Writer = .fixed(&buf);
    try report.writeText(.msg, &msg);
    try testing.expectEqualStrings("Plan", msg.buffered());
}
test "OSC 7501: whitespace around keys and values" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501; state = working :\tapp=cargo\t");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.working, report.state);
    try testing.expectEqualStrings("cargo", report.readOption(.app).?);
}
test "OSC 7501: last value wins" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=idle:app=a:state=done:app=b");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.done, report.state);
    try testing.expectEqualStrings("b", report.readOption(.app).?);
}
test "OSC 7501: malformed pairs and unknown keys are skipped" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;garbage:=x:Bad=1:app=b@d:future=yes:state=working:app=ok:::");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.working, report.state);
    try testing.expectEqualStrings("ok", report.readOption(.app).?);
}
test "OSC 7501: kind and progress only apply to some states" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=working:kind=auth:progress=10");
    var report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.kind) == null);
    try testing.expectEqual(@as(u8, 10), report.readOption(.progress).?);
    p.reset();
    p.nextSlice("7501;state=done:kind=auth:progress=10");
    report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.kind) == null);
    try testing.expect(report.readOption(.progress) == null);
    p.reset();
    p.nextSlice("7501;state=blocked:kind=dance");
    report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.kind) == null);
}
test "OSC 7501: out of range progress is absent" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const cases = [_]struct { []const u8, ?u8 }{
        .{ "0", 0 },
        .{ "100", 100 },
        .{ "101", null },
        .{ "256", null },
        .{ "99999999999999999999", null },
        .{ "-1", null },
        .{ "+1", null },
        .{ "4.5", null },
        .{ "1_0", null },
        .{ "007", 7 },
        .{ "", null },
    };
    for (cases) |case| {
        p.reset();
        p.nextSlice("7501;state=working:progress=");
        p.nextSlice(case[0]);
        const report = p.end('\x1b').?.program_status.report;
        try testing.expectEqual(case[1], report.readOption(.progress));
    }
}
test "OSC 7501: invalid app is ignored" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=idle:app=a/b");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.app) == null);
}
test "OSC 7501: ids" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const max_segment = "a" ** max_id_segment_bytes;
    const valid = [_][]const u8{
        "a",
        "build/test",
        "A-Z_0.9+",
        max_segment,
        "a/b/c/d/e/f/g/h",
    };
    for (valid) |id| {
        p.reset();
        p.nextSlice("7501;state=clear:id=");
        p.nextSlice(id);
        const report = p.end('\x1b').?.program_status.report;
        try testing.expectEqualStrings(id, report.readOption(.id).?);
    }
    const invalid = [_][]const u8{
        "",
        "/",
        "a/",
        "/a",
        "a//b",
        "a,b",
        "a=b",
        max_segment ++ "a",
        "a/b/c/d/e/f/g/h/i",
        ("a" ** 31 ++ "/") ** 4 ++ "a",
    };
    for (invalid) |id| {
        p.reset();
        p.nextSlice("7501;state=clear:id=");
        p.nextSlice(id);
        try testing.expect(p.end('\x1b') == null);
    }
}
test "OSC 7501: text must decode to safe UTF-8" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const invalid = [_][]const u8{
        "7501;state=done:msg=a",
        "7501;state=done:msg=QQ=",
        "7501;state=done:title=a",
        "7501;state=done:msg=YQpi",
        "7501;state=done:msg=wps=",
        "7501;state=done:msg=/w==",
    };
    for (invalid) |input| {
        p.reset();
        p.nextSlice(input);
        try testing.expect(p.end('\x1b') == null);
    }
    p.reset();
    p.nextSlice("7501;state=done:msg=5a6J5YWo");
    const report = p.end('\x1b').?.program_status.report;
    var buf: [max_msg_bytes]u8 = undefined;
    var msg: std.Io.Writer = .fixed(&buf);
    try report.writeText(.msg, &msg);
    try testing.expectEqualStrings("安全", msg.buffered());
}
test "OSC 7501: empty text is absent" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;state=done:msg=:title=");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.msg) == null);
    try testing.expect(report.readOption(.title) == null);
}
test "OSC 7501: discarded reports" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const title = "QUFB" ** (max_title_encoded_bytes / 4);
    const msg = "QUFB" ** (max_msg_bytes / 3) ++ "QUE";
    const fill = max_sequence_bytes - "\x1b]7501;state=idle:".len - "\x1b\\".len;
    const cases = [_]struct { []const u8, bool }{
        .{ "7501;", false },
        .{ "7501;app=cargo", false },
        .{ "7501;state=sleeping", false },
        .{ "7501;state=", false },
        .{ "7501;state=IDLE", false },
        .{ "7501;state=idle:" ++ "a" ** max_key_bytes ++ "=1", true },
        .{ "7501;state=idle:" ++ "a" ** (max_key_bytes + 1) ++ "=1", false },
        .{ "7501;state=idle:app=" ++ "a" ** (max_app_bytes + 1), false },
        .{ "7501;state=idle:app=" ++ "a" ** (max_app_bytes + 1) ++ ":app=ok", false },
        .{ "7501;state=idle:title=" ++ title, true },
        .{ "7501;state=idle:title=" ++ title ++ "QUFB", false },
        .{ "7501;state=idle:msg=" ++ msg, true },
        .{ "7501;state=idle:msg=" ++ "QUFB" ** (max_msg_bytes / 3 + 1), false },
        .{ "7501;state=idle:" ++ "x" ** fill, true },
        .{ "7501;state=idle:" ++ "x" ** (fill + 1), false },
        .{ "75;state=idle", false },
        .{ "750;state=idle", false },
        .{ "75010;state=idle", false },
        .{ "7501", false },
    };
    for (cases) |case| {
        p.reset();
        p.nextSlice(case[0]);
        try testing.expectEqual(case[1], p.end('\x1b') != null);
    }
}
test "OSC 7501: no allocator" {
    const testing = std.testing;
    var p: Parser = .init(null);
    defer p.deinit();
    p.nextSlice("7501;state=working:app=cargo");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.working, report.state);
    try testing.expectEqualStrings("cargo", report.readOption(.app).?);
}
