const Osc = @This();
const std = @import("std");
const assert = std.debug.assert;
const Generator = @import("Generator.zig");
const Bytes = @import("Bytes.zig");
const urlPercentEncode = @import("../os/string_encoding.zig").urlPercentEncode;
pub const ValidKind = enum {
    change_window_title,
    prompt_start,
    prompt_end,
    end_of_input,
    end_of_command,
    rxvt_notify,
    mouse_shape,
    clipboard_operation,
    report_pwd,
    hyperlink_start,
    hyperlink_end,
    conemu_progress,
    iterm2_notification,
};
pub const InvalidKind = enum {
    random,
    good_prefix,
};
rand: std.Random,
p_valid: f64 = 1.0,
p_valid_kind: std.enums.EnumArray(ValidKind, f64) = .initFill(1.0),
p_invalid_kind: std.enums.EnumArray(InvalidKind, f64) = .initFill(1.0),
fn checkKvAlphabet(c: u8) bool {
    return switch (c) {
        std.ascii.control_code.esc, std.ascii.control_code.bel, ';', '=' => false,
        else => std.ascii.isPrint(c),
    };
}
pub const kv_alphabet = Bytes.generateAlphabet(checkKvAlphabet);
fn checkOscAlphabet(c: u8) bool {
    return switch (c) {
        std.ascii.control_code.esc, std.ascii.control_code.bel => false,
        else => true,
    };
}
pub const osc_alphabet = Bytes.generateAlphabet(checkOscAlphabet);
pub const ascii_alphabet = Bytes.generateAlphabet(std.ascii.isPrint);
pub const alphabetic_alphabet = Bytes.generateAlphabet(std.ascii.isAlphabetic);
pub const alphanumeric_alphabet = Bytes.generateAlphabet(std.ascii.isAlphanumeric);
pub fn generator(self: *Osc) Generator {
    return .init(self, next);
}
const osc = std.fmt.comptimePrint("{c}]", .{std.ascii.control_code.esc});
const st = std.fmt.comptimePrint("{c}", .{std.ascii.control_code.bel});
pub fn next(self: *Osc, writer: *std.Io.Writer, max_len: usize) Generator.Error!void {
    assert(max_len >= 3);
    try writer.writeAll(osc);
    try self.nextUnwrapped(writer, max_len - (osc.len + st.len));
    try writer.writeAll(st);
}
fn nextUnwrapped(self: *Osc, writer: *std.Io.Writer, max_len: usize) Generator.Error!void {
    return switch (self.chooseValidity()) {
        .valid => valid: {
            const Indexer = @TypeOf(self.p_valid_kind).Indexer;
            const idx = self.rand.weightedIndex(f64, &self.p_valid_kind.values);
            break :valid try self.nextUnwrappedValidExact(
                writer,
                Indexer.keyForIndex(idx),
                max_len,
            );
        },
        .invalid => invalid: {
            const Indexer = @TypeOf(self.p_invalid_kind).Indexer;
            const idx = self.rand.weightedIndex(f64, &self.p_invalid_kind.values);
            break :invalid try self.nextUnwrappedInvalidExact(
                writer,
                Indexer.keyForIndex(idx),
                max_len,
            );
        },
    };
}
fn nextUnwrappedValidExact(self: *const Osc, writer: *std.Io.Writer, k: ValidKind, max_len: usize) Generator.Error!void {
    switch (k) {
        .change_window_title => change_window_title: {
            if (max_len < 3) break :change_window_title;
            try writer.print("0;{f}", .{self.bytes().atMost(max_len - 3)}); 
        },
        .prompt_start => prompt_start: {
            if (max_len < 4) break :prompt_start;
            var remaining = max_len;
            try writer.writeAll("133;A"); 
            remaining -= 4;
            if (self.rand.boolean()) aid: {
                if (remaining < 6) break :aid;
                try writer.writeAll(";aid=");
                remaining -= 5;
                remaining -= try self.bytes().newAlphabet(kv_alphabet).atMost(@min(16, remaining)).write(writer);
            }
            if (self.rand.boolean()) redraw: {
                if (remaining < 9) break :redraw;
                try writer.writeAll(";redraw=");
                if (self.rand.boolean()) {
                    try writer.writeAll("1");
                } else {
                    try writer.writeAll("0");
                }
                remaining -= 9;
            }
        },
        .prompt_end => prompt_end: {
            if (max_len < 4) break :prompt_end;
            try writer.writeAll("133;B"); 
        },
        .end_of_input => end_of_input: {
            if (max_len < 5) break :end_of_input;
            var remaining = max_len;
            try writer.writeAll("133;C"); 
            remaining -= 5;
            if (self.rand.boolean()) cmdline: {
                const prefix = ";cmdline_url=";
                if (remaining < prefix.len + 1) break :cmdline;
                try writer.writeAll(prefix);
                remaining -= prefix.len;
                var buf: [128]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                try self.bytes().newAlphabet(ascii_alphabet).atMost(@min(remaining, buf.len)).format(&w);
                try urlPercentEncode(writer, w.buffered());
                remaining -= w.buffered().len;
            }
        },
        .end_of_command => end_of_command: {
            if (max_len < 4) break :end_of_command;
            try writer.writeAll("133;D"); 
            if (self.rand.boolean()) exit_code: {
                if (max_len < 7) break :exit_code;
                try writer.print(";{d}", .{self.rand.int(u8)});
            }
        },
        .mouse_shape => mouse_shape: {
            if (max_len < 4) break :mouse_shape;
            try writer.print("22;{f}", .{self.bytes().newAlphabet(alphabetic_alphabet).atMost(@min(32, max_len - 3))}); 
        },
        .rxvt_notify => rxvt_notify: {
            const prefix = "777;notify;";
            if (max_len < prefix.len) break :rxvt_notify;
            var remaining = max_len;
            try writer.writeAll(prefix);
            remaining -= prefix.len;
            remaining -= try self.bytes().newAlphabet(kv_alphabet).atMost(@min(remaining - 2, 32)).write(writer);
            try writer.writeByte(';');
            remaining -= 1;
            remaining -= try self.bytes().newAlphabet(osc_alphabet).atMost(remaining).write(writer);
        },
        .clipboard_operation => {
            try writer.writeAll("52;");
            var remaining = max_len - 3;
            if (self.rand.boolean()) {
                remaining -= try self.bytes().newAlphabet(alphabetic_alphabet).atMost(1).write(writer);
            }
            try writer.writeByte(';');
            remaining -= 1;
            if (self.rand.boolean()) {
                remaining -= try self.bytes().newAlphabet(osc_alphabet).atMost(remaining).write(writer);
            }
        },
        .report_pwd => report_pwd: {
            const prefix = "7;file://localhost";
            if (max_len < prefix.len) break :report_pwd;
            var remaining = max_len;
            try writer.writeAll(prefix);
            remaining -= prefix.len;
            for (0..self.rand.intRangeAtMost(usize, 2, 5)) |_| {
                try writer.writeByte('/');
                remaining -= 1;
                remaining -= try self.bytes().newAlphabet(alphanumeric_alphabet).atMost(@min(16, remaining)).write(writer);
            }
        },
        .hyperlink_start => {
            try writer.writeAll("8;");
            if (self.rand.boolean()) {
                try writer.print("id={f}", .{self.bytes().newAlphabet(alphanumeric_alphabet).atMost(16)});
            }
            try writer.writeAll(";https://localhost");
            for (0..self.rand.intRangeAtMost(usize, 2, 5)) |_| {
                try writer.print("/{f}", .{self.bytes().newAlphabet(alphanumeric_alphabet).atMost(16)});
            }
        },
        .hyperlink_end => hyperlink_end: {
            if (max_len < 3) break :hyperlink_end;
            try writer.writeAll("8;;");
        },
        .conemu_progress => {
            try writer.writeAll("9;");
            switch (self.rand.intRangeAtMost(u3, 0, 4)) {
                0, 3 => |c| {
                    try writer.print(";{d}", .{c});
                },
                1, 2, 4 => |c| {
                    if (self.rand.boolean()) {
                        try writer.print(";{d}", .{c});
                    } else {
                        try writer.print(";{d};{d}", .{ c, self.rand.intRangeAtMost(u8, 0, 100) });
                    }
                },
                else => unreachable,
            }
        },
        .iterm2_notification => iterm2_notification: {
            if (max_len < 3) break :iterm2_notification;
            try writer.print("9;_{f}", .{self.bytes().newAlphabet(ascii_alphabet).atMost(max_len - 3)});
        },
    }
}
fn nextUnwrappedInvalidExact(
    self: *const Osc,
    writer: *std.Io.Writer,
    k: InvalidKind,
    max_len: usize,
) Generator.Error!void {
    switch (k) {
        .random => {
            try self.bytes().atMost(max_len).format(writer);
        },
        .good_prefix => {
            try writer.print("133;{f}", .{self.bytes().atMost(max_len - 4)});
        },
    }
}
fn bytes(self: *const Osc) Bytes {
    return .{
        .rand = self.rand,
        .alphabet = osc_alphabet,
    };
}
fn chooseValidity(self: *const Osc) Validity {
    return if (self.rand.float(f64) > self.p_valid)
        .invalid
    else
        .valid;
}
const Validity = enum { valid, invalid };
const test_seed = 0xC0FFEEEEEEEEEEEE;
test "OSC generator" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    {
        var v: Osc = .{
            .rand = prng.random(),
        };
        const gen = v.generator();
        for (0..50) |_| {
            var writer: std.Io.Writer = .fixed(&buf);
            try gen.next(&writer, buf.len);
            const result = writer.buffered();
            try testing.expect(result.len > 0);
        }
    }
}
test "OSC generator valid" {
    const testing = std.testing;
    const terminal = @import("../terminal/main.zig");
    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    var gen: Osc = .{
        .rand = prng.random(),
        .p_valid = 1.0,
    };
    for (0..50) |_| {
        var writer: std.Io.Writer = .fixed(&buf);
        try gen.next(&writer, buf.len);
        const seq = writer.buffered();
        var parser: terminal.osc.Parser = .init(null);
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) != null);
    }
}
test "OSC generator invalid" {
    const testing = std.testing;
    const terminal = @import("../terminal/main.zig");
    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    var gen: Osc = .{
        .rand = prng.random(),
        .p_valid = 0.0,
    };
    for (0..50) |_| {
        var writer: std.Io.Writer = .fixed(&buf);
        try gen.next(&writer, buf.len);
        const seq = writer.buffered();
        var parser: terminal.osc.Parser = .init(null);
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) == null);
    }
}
