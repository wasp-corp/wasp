const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;
pub const OSC = struct {
    metadata: []const u8,
    payload: ?[]const u8,
    terminator: Terminator,
    pub const C = void;
    pub fn cval(_: OSC) C {
        return {};
    }
};
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"72");
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const metadata: []const u8, const payload: ?[]const u8 = result: {
        const sep = std.mem.indexOfScalar(u8, data, ';') orelse break :result .{ data, null };
        break :result .{ data[0..sep], data[sep + 1 .. data.len] };
    };
    parser.command = .{
        .kitty_dnd_protocol = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };
    return &parser.command;
}
test "OSC 72: metadata only, no payload" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;t=a";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a", cmd.kitty_dnd_protocol.metadata);
    try testing.expect(cmd.kitty_dnd_protocol.payload == null);
}
test "OSC 72: metadata and empty payload" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;t=a;";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("", cmd.kitty_dnd_protocol.payload.?);
}
test "OSC 72: metadata and non-empty payload" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;t=a:i=5;text/plain text/uri-list";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a:i=5", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("text/plain text/uri-list", cmd.kitty_dnd_protocol.payload.?);
}
test "OSC 72: empty metadata with payload" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;;payload";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("payload", cmd.kitty_dnd_protocol.payload.?);
}
test "OSC 72: BEL terminator recorded" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;t=q";
    for (input) |ch| p.next(ch);
    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.terminator == .bel);
}
