const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const oni = @import("oniguruma");
const log = std.log.scoped(.terminal_tmux);
pub const Parser = struct {
    state: State = .idle,
    buffer: std.Io.Writer.Allocating,
    max_bytes: usize = 1024 * 1024,
    const State = enum {
        idle,
        broken,
        notification,
        block,
    };
    pub fn deinit(self: *Parser) void {
        if (self.state == .broken) return;
        self.buffer.deinit();
    }
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        if (self.state == .broken) return null;
        switch (self.state) {
            .broken => return null,
            .idle => if (byte != '%') {
                self.broken();
                return .{ .exit = {} };
            } else {
                self.buffer.clearRetainingCapacity();
                self.state = .notification;
            },
            .notification => if (byte == '\n') {
                return self.parseNotification() catch {
                    return null;
                };
            },
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    written,
                    '\n',
                )) |v| v + 1 else 0;
                const line = written[idx..];
                if (parseBlockTerminator(line)) |terminator| {
                    const output = std.mem.trimEnd(
                        u8,
                        written[0..idx],
                        "\r\n",
                    );
                    self.state = .idle;
                    switch (terminator) {
                        .end => return .{ .block_end = output },
                        .err => {
                            log.warn("tmux control mode error={s}", .{output});
                            return .{ .block_err = output };
                        },
                    }
                }
            },
        }
        if (self.buffer.written().len >= self.max_bytes) {
            self.broken();
            return error.OutOfMemory;
        }
        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        return null;
    }
    const ParseError = error{RegexError};
    const BlockTerminator = enum { end, err };
    fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminator {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
            .end
        else if (std.mem.eql(u8, cmd, "%error"))
            .err
        else
            return null;
        const time = fields.next() orelse return null;
        const command_id = fields.next() orelse return null;
        const flags = fields.next() orelse return null;
        const extra = fields.next();
        _ = std.fmt.parseInt(usize, time, 10) catch return null;
        _ = std.fmt.parseInt(usize, command_id, 10) catch return null;
        _ = std.fmt.parseInt(usize, flags, 10) catch return null;
        if (extra != null) return null;
        return terminator;
    }
    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);
        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const cmd = cmd: {
            const idx = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            break :cmd line[0..idx];
        };
        if (std.mem.eql(u8, cmd, "%begin")) {
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            var re = oni.Regex.init(
                "^%output %([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const data = line[@intCast(starts[2])..@intCast(ends[2])];
            self.state = .idle;
            return .{ .output = .{ .pane_id = id, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-changed \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];
            self.state = .idle;
            return .{ .session_changed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) cmd: {
            if (!std.mem.eql(u8, line, "%sessions-changed")) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            var re = oni.Regex.init(
                "^%layout-change @([0-9]+) (.+) (.+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const layout = line[@intCast(starts[2])..@intCast(ends[2])];
            const visible_layout = line[@intCast(starts[3])..@intCast(ends[3])];
            const raw_flags = line[@intCast(starts[4])..@intCast(ends[4])];
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id,
                .layout = layout,
                .visible_layout = visible_layout,
                .raw_flags = raw_flags,
            } };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            var re = oni.Regex.init(
                "^%window-add @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%window-renamed")) cmd: {
            var re = oni.Regex.init(
                "^%window-renamed @([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];
            self.state = .idle;
            return .{ .window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            var re = oni.Regex.init(
                "^%window-pane-changed @([0-9]+) %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const pane_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = window_id, .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            var re = oni.Regex.init(
                "^%client-detached (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const client = line[@intCast(starts[1])..@intCast(ends[1])];
            self.state = .idle;
            return .{ .client_detached = .{ .client = client } };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%client-session-changed (.+) \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();
            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();
            const client = line[@intCast(starts[1])..@intCast(ends[1])];
            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[3])..@intCast(ends[3])];
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client, .session_id = session_id, .name = name } };
        } else {
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }
        self.buffer.clearRetainingCapacity();
        self.state = .idle;
        return null;
    }
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};
pub const Notification = union(enum) {
    enter,
    exit,
    block_end: []const u8,
    block_err: []const u8,
    output: struct {
        pane_id: usize,
        data: []const u8, 
    },
    session_changed: struct {
        id: usize,
        name: []const u8,
    },
    sessions_changed,
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },
    window_add: struct {
        id: usize,
    },
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },
    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },
    client_detached: struct {
        client: []const u8,
    },
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },
    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
        const info = @typeInfo(T).@"union";
        try writer.writeAll(@typeName(T));
        if (info.tag_type) |TagType| {
            try writer.writeAll("{ .");
            try writer.writeAll(@tagName(@as(TagType, self)));
            try writer.writeAll(" = ");
            inline for (info.fields) |u_field| {
                if (self == @field(TagType, u_field.name)) {
                    const value = @field(self, u_field.name);
                    switch (u_field.type) {
                        []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                        else => try writer.print("{any}", .{value}),
                    }
                }
            }
            try writer.writeAll(" }");
        }
    }
};
test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end);
}
test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err);
}
test "tmux notification exactly max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const line = "%sessions-changed";
    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = line.len };
    defer c.deinit();
    for (0..2) |_| {
        for (line) |byte| try testing.expect(try c.put(byte) == null);
        const n = (try c.put('\n')).?;
        try testing.expect(n == .sessions_changed);
    }
}
test "tmux block terminator exactly max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const block = "hello\n%end 1578922740 269 1";
    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = block.len };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for (block) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello", n.block_end);
}
test "tmux exceeding max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const line = "%sessions-changed";
    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = line.len - 1 };
    defer c.deinit();
    for (line[0 .. line.len - 1]) |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectError(error.OutOfMemory, c.put(line[line.len - 1]));
    try testing.expect(try c.put('\n') == null);
}
test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end);
}
test "tmux block payload may start with %end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end not really\nhello", n.block_end);
}
test "tmux block payload may start with %error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%error not really\nhello", n.block_end);
}
test "tmux block may terminate with real %error after misleading payload" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("%error not really\nhello", n.block_err);
}
test "tmux block terminator requires exact token count" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1 trailing\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end);
}
test "tmux block terminator requires numeric metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end foo bar baz\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end);
}
test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}
test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}
test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}
test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}
test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}
test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}
test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}
test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}
test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}
test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}
