const std = @import("std");
const lib = @import("../../lib.zig");
const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;
const log = std.log.scoped(.osc_hierarchical_context);
const max_context_id_len = 64;
pub const UnescapedString = struct {
    raw: []const u8,
    pub const Iterator = struct {
        raw: []const u8,
        index: usize = 0,
        pub fn next(self: *Iterator) ?u8 {
            if (self.index >= self.raw.len) return null;
            if (self.raw[self.index] == '\\' and self.index + 3 < self.raw.len) {
                if (std.mem.eql(u8, self.raw[self.index .. self.index + 4], "\\x3b")) {
                    self.index += 4;
                    return ';';
                }
                if (std.mem.eql(u8, self.raw[self.index .. self.index + 4], "\\x5c")) {
                    self.index += 4;
                    return '\\';
                }
            }
            const c = self.raw[self.index];
            self.index += 1;
            return c;
        }
    };
    pub fn iterator(self: UnescapedString) Iterator {
        return .{ .raw = self.raw };
    }
    pub fn toAllocated(self: UnescapedString, alloc: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(alloc);
        var it = self.iterator();
        while (it.next()) |c| try list.append(alloc, c);
        return list.toOwnedSlice(alloc);
    }
    pub fn eql(self: UnescapedString, other: []const u8) bool {
        var it = self.iterator();
        for (other) |c| {
            const next_c = it.next() orelse return false;
            if (next_c != c) return false;
        }
        return it.next() == null;
    }
};
pub const Command = struct {
    pub const C = void;
    action: Action,
    id: []const u8,
    metadata: []const u8,
    pub const Action = enum(c_int) {
        start,
        end,
    };
    pub fn readOption(
        self: Command,
        comptime option: Field,
    ) option.Type() {
        return option.read(self.metadata);
    }
};
pub const ContextType = enum {
    boot,
    container,
    vm,
    elevate,
    chpriv,
    subcontext,
    remote,
    shell,
    command,
    app,
    service,
    session,
    pub fn parse(value: []const u8) ?ContextType {
        return std.meta.stringToEnum(ContextType, value);
    }
};
pub const ExitStatus = enum {
    success,
    failure,
    crash,
    interrupt,
    pub fn parse(value: []const u8) ?ExitStatus {
        return std.meta.stringToEnum(ExitStatus, value);
    }
};
pub const Field = enum {
    type,
    user,
    hostname,
    machineid,
    bootid,
    pid,
    pidfdid,
    comm,
    cwd,
    cmdline,
    vm,
    container,
    targetuser,
    targethost,
    sessionid,
    exit,
    status,
    signal,
    pub fn Type(comptime self: Field) type {
        return switch (self) {
            .type => ?ContextType,
            .exit => ?ExitStatus,
            .pid, .pidfdid => ?u64,
            .status => ?u64,
            .user,
            .hostname,
            .machineid,
            .bootid,
            .comm,
            .cwd,
            .cmdline,
            .vm,
            .container,
            .targetuser,
            .targethost,
            .sessionid,
            .signal,
            => ?UnescapedString,
        };
    }
    fn key(comptime self: Field) []const u8 {
        return @tagName(self);
    }
    pub fn read(
        comptime self: Field,
        raw: []const u8,
    ) self.Type() {
        var it = std.mem.splitScalar(u8, raw, ';');
        while (it.next()) |full| {
            const value = value: {
                if (std.mem.indexOfScalar(
                    u8,
                    full,
                    '=',
                )) |eql_idx| {
                    if (std.mem.eql(
                        u8,
                        full[0..eql_idx],
                        self.key(),
                    )) {
                        break :value full[eql_idx + 1 ..];
                    }
                }
                continue;
            };
            return switch (self) {
                .type => .parse(value),
                .exit => .parse(value),
                .pid, .pidfdid, .status => lib.parseInt(
                    u64,
                    value,
                    10,
                ) catch null,
                .user,
                .hostname,
                .machineid,
                .bootid,
                .comm,
                .cwd,
                .cmdline,
                .vm,
                .container,
                .targetuser,
                .targethost,
                .sessionid,
                .signal,
                => if (value.len > 0) .{ .raw = value } else null,
            };
        }
        return null;
    }
};
pub fn parse(parser: *Parser, _: ?u8) ?*OSCCommand {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }
    const action: Command.Action = action: {
        if (std.mem.startsWith(u8, data, "start=")) break :action .start;
        if (std.mem.startsWith(u8, data, "end=")) break :action .end;
        log.warn("OSC 3008: expected 'start=' or 'end=' prefix, got: {s}", .{
            data[0..@min(data.len, 10)],
        });
        parser.state = .invalid;
        return null;
    };
    const prefix_len: usize = switch (action) {
        .start => "start=".len,
        .end => "end=".len,
    };
    const rest = data[prefix_len..];
    if (rest.len == 0) {
        log.warn("OSC 3008: missing context ID", .{});
        parser.state = .invalid;
        return null;
    }
    const id_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const id = rest[0..id_end];
    if (id.len == 0 or id.len > max_context_id_len) {
        log.warn("OSC 3008: context ID length {d} out of range (1-{d})", .{
            id.len,
            max_context_id_len,
        });
        parser.state = .invalid;
        return null;
    }
    for (id) |c| {
        if (c < 0x20 or c > 0x7e) {
            log.warn("OSC 3008: invalid character 0x{x:0>2} in context ID", .{c});
            parser.state = .invalid;
            return null;
        }
    }
    const metadata = if (id_end < rest.len) rest[id_end + 1 ..] else "";
    parser.command = .{
        .hierarchical_context = .{
            .action = action,
            .id = id,
            .metadata = metadata,
        },
    };
    return &parser.command;
}
test "OSC 3008: basic start command" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=abc123";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .start);
    try testing.expectEqualStrings("abc123", cmd.hierarchical_context.id);
    try testing.expectEqualStrings("", cmd.hierarchical_context.metadata);
}
test "OSC 3008: basic end command" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;end=abc123";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .end);
    try testing.expectEqualStrings("abc123", cmd.hierarchical_context.id);
    try testing.expectEqualStrings("", cmd.hierarchical_context.metadata);
}
test "OSC 3008: start with metadata fields" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=bed86fab93af4328bbed0a1224af6d40;type=container;user=lennart;hostname=zeta";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .start);
    try testing.expectEqualStrings("bed86fab93af4328bbed0a1224af6d40", cmd.hierarchical_context.id);
    try testing.expect(cmd.hierarchical_context.readOption(.type).? == .container);
    try testing.expect(cmd.hierarchical_context.readOption(.user).?.eql("lennart"));
    try testing.expect(cmd.hierarchical_context.readOption(.hostname).?.eql("zeta"));
}
test "OSC 3008: start with all common fields" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=myctx;type=shell;user=root;hostname=myhost;machineid=3deb5353d3ba43d08201c136a47ead7b;bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2;pid=1062862;pidfdid=1063162;comm=bash";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.type).? == .shell);
    try testing.expect(cmd.hierarchical_context.readOption(.user).?.eql("root"));
    try testing.expect(cmd.hierarchical_context.readOption(.hostname).?.eql("myhost"));
    try testing.expect(cmd.hierarchical_context.readOption(.machineid).?.eql("3deb5353d3ba43d08201c136a47ead7b"));
    try testing.expect(cmd.hierarchical_context.readOption(.bootid).?.eql("d4a3d0fdf2e24fdea6d971ce73f4fbf2"));
    try testing.expectEqual(@as(u64, 1062862), cmd.hierarchical_context.readOption(.pid).?);
    try testing.expectEqual(@as(u64, 1063162), cmd.hierarchical_context.readOption(.pidfdid).?);
    try testing.expect(cmd.hierarchical_context.readOption(.comm).?.eql("bash"));
}
test "OSC 3008: end with exit metadata" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;end=myctx;exit=success;status=0";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .end);
    try testing.expectEqualStrings("myctx", cmd.hierarchical_context.id);
    try testing.expect(cmd.hierarchical_context.readOption(.exit).? == .success);
    try testing.expectEqual(@as(u64, 0), cmd.hierarchical_context.readOption(.status).?);
}
test "OSC 3008: end with failure exit" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;end=myctx;exit=failure;status=1;signal=SIGKILL";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.exit).? == .failure);
    try testing.expectEqual(@as(u64, 1), cmd.hierarchical_context.readOption(.status).?);
    try testing.expect(cmd.hierarchical_context.readOption(.signal).?.eql("SIGKILL"));
}
test "OSC 3008: numeric fields reject non-digits" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=myctx;pid=4_2;pidfdid=+42;status=-1";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.pid) == null);
    try testing.expect(cmd.hierarchical_context.readOption(.pidfdid) == null);
    try testing.expect(cmd.hierarchical_context.readOption(.status) == null);
}
test "OSC 3008: unknown fields are ignored" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=myctx;type=shell;unknownfield=value;user=root";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.type).? == .shell);
    try testing.expect(cmd.hierarchical_context.readOption(.user).?.eql("root"));
}
test "OSC 3008: missing field returns null" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=myctx;user=lennart";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.type) == null);
    try testing.expect(cmd.hierarchical_context.readOption(.hostname) == null);
    try testing.expect(cmd.hierarchical_context.readOption(.pid) == null);
}
test "OSC 3008: invalid prefix" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;bogus=abc123";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}
test "OSC 3008: empty data" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}
test "OSC 3008: max length context ID" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const id = "a" ** 64;
    const input = "3008;start=" ++ id;
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expectEqualStrings(id, cmd.hierarchical_context.id);
}
test "OSC 3008: over-length context ID" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const id = "a" ** 65;
    const input = "3008;start=" ++ id;
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}
test "OSC 3008: context type enum coverage" {
    const testing = std.testing;
    const types = [_]struct { str: []const u8, expected: ContextType }{
        .{ .str = "boot", .expected = .boot },
        .{ .str = "container", .expected = .container },
        .{ .str = "vm", .expected = .vm },
        .{ .str = "elevate", .expected = .elevate },
        .{ .str = "chpriv", .expected = .chpriv },
        .{ .str = "subcontext", .expected = .subcontext },
        .{ .str = "remote", .expected = .remote },
        .{ .str = "shell", .expected = .shell },
        .{ .str = "command", .expected = .command },
        .{ .str = "app", .expected = .app },
        .{ .str = "service", .expected = .service },
        .{ .str = "session", .expected = .session },
    };
    for (types) |t| {
        try testing.expectEqual(t.expected, ContextType.parse(t.str).?);
    }
    try testing.expect(ContextType.parse("invalid") == null);
}
test "OSC 3008: exit status enum coverage" {
    const testing = std.testing;
    try testing.expect(ExitStatus.parse("success").? == .success);
    try testing.expect(ExitStatus.parse("failure").? == .failure);
    try testing.expect(ExitStatus.parse("crash").? == .crash);
    try testing.expect(ExitStatus.parse("interrupt").? == .interrupt);
    try testing.expect(ExitStatus.parse("invalid") == null);
}
test "OSC 3008: spec example - container start" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=bed86fab93af4328bbed0a1224af6d40;type=container;user=lennart;hostname=zeta;machineid=3deb5353d3ba43d08201c136a47ead7b;bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2;pid=1062862;pidfdid=1063162;comm=systemd-nspawn;container=foobar";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .start);
    try testing.expectEqualStrings("bed86fab93af4328bbed0a1224af6d40", cmd.hierarchical_context.id);
    try testing.expect(cmd.hierarchical_context.readOption(.type).? == .container);
    try testing.expect(cmd.hierarchical_context.readOption(.user).?.eql("lennart"));
    try testing.expect(cmd.hierarchical_context.readOption(.hostname).?.eql("zeta"));
    try testing.expect(cmd.hierarchical_context.readOption(.comm).?.eql("systemd-nspawn"));
    try testing.expect(cmd.hierarchical_context.readOption(.container).?.eql("foobar"));
    try testing.expectEqual(@as(u64, 1062862), cmd.hierarchical_context.readOption(.pid).?);
}
test "OSC 3008: spec example - context end" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;end=bed86fab93af4328bbed0a1224af6d40";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .end);
    try testing.expectEqualStrings("bed86fab93af4328bbed0a1224af6d40", cmd.hierarchical_context.id);
}
test "OSC 3008: cwd and cmdline fields" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=myctx;type=command;cwd=/home/user;cmdline=ls -la";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.cwd).?.eql("/home/user"));
    try testing.expect(cmd.hierarchical_context.readOption(.cmdline).?.eql("ls -la"));
}
test "OSC 3008: start command with no fields" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=simpleid";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.action == .start);
    try testing.expectEqualStrings("simpleid", cmd.hierarchical_context.id);
    try testing.expect(cmd.hierarchical_context.readOption(.type) == null);
    try testing.expect(cmd.hierarchical_context.readOption(.user) == null);
    try testing.expect(cmd.hierarchical_context.readOption(.exit) == null);
}
test "OSC 3008: string unescaping" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "3008;start=myctx;cmdline=echo \\x3b \\x5c;cwd=\\x5csystem07\\x5cC$\\x5c";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .hierarchical_context);
    try testing.expect(cmd.hierarchical_context.readOption(.cmdline).?.eql("echo ; \\"));
    try testing.expect(cmd.hierarchical_context.readOption(.cwd).?.eql("\\system07\\C$\\"));
}
