const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard = @import("clipboard.zig");
const kitty_clipboard = @import("kitty/clipboard.zig");
const input_paste = @import("../input/paste.zig");
const Terminal = @import("Terminal.zig");
pub const Source = union(enum) {
    clipboard: clipboard.Location,
    text,
};
pub const Request = struct {
    source: Source = .{ .clipboard = .standard },
    contents: Contents,
    allow_unsafe: bool = false,
};
pub const Contents = union(enum) {
    memory: []const clipboard.Content,
    reader: Reader,
    pub const Reader = struct {
        mimes: []const []const u8,
        read: clipboard.MimeReader,
    };
    pub fn len(self: Contents) usize {
        return switch (self) {
            .memory => |v| v.len,
            .reader => |v| v.mimes.len,
        };
    }
    pub fn mime(self: Contents, index: usize) []const u8 {
        return switch (self) {
            .memory => |v| v[index].mime,
            .reader => |v| v.mimes[index],
        };
    }
};
pub const Context = struct {
    terminal: *const Terminal,
    alloc: Allocator,
    writer: *std.Io.Writer,
    kitty_clipboard: ?KittyClipboard,
    pub const KittyClipboard = struct {
        grants: *kitty_clipboard.Grants,
        io: std.Io,
    };
};
pub const Error = Allocator.Error ||
    std.Io.RandomSecureError ||
    clipboard.MimeReader.Error ||
    error{
        UnsafePaste,
    };
pub fn paste(ctx: Context, req: Request) Error!bool {
    if (req.source == .clipboard and
        ctx.terminal.modes.get(.kitty_paste_events))
    {
        if (ctx.kitty_clipboard) |kitty| {
            try pasteKittyEvent(ctx, kitty, req);
            return true;
        }
    }
    const index: usize = for (0..req.contents.len()) |i| {
        if (clipboard.isTextMime(req.contents.mime(i))) break i;
    } else return false;
    const opts: input_paste.Options = .fromTerminal(ctx.terminal);
    var aw: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer aw.deinit();
    const text: []const u8 = switch (req.contents) {
        .memory => |v| v[index].data,
        .reader => |v| text: {
            v.read.read(v.mimes[index], &aw.writer) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => |e| return e,
            };
            break :text aw.writer.buffered();
        },
    };
    if (text.len == 0) return false;
    if (!req.allow_unsafe and !input_paste.isSafeWith(
        text,
        opts,
    )) return error.UnsafePaste;
    try input_paste.encodeWriter(ctx.writer, text, opts);
    return true;
}
fn pasteKittyEvent(
    ctx: Context,
    kitty: Context.KittyClipboard,
    req: Request,
) Error!void {
    const otp = try kitty_clipboard.generateOtp(kitty.io);
    var mimes_buf: [kitty_clipboard.max_listing_mimes][]const u8 = undefined;
    const mimes_len = @min(req.contents.len(), mimes_buf.len);
    for (mimes_buf[0..mimes_len], 0..) |*mime, i| mime.* = req.contents.mime(i);
    try kitty.grants.grant(ctx.alloc, &otp, .read, true);
    errdefer _ = kitty.grants.use(ctx.alloc, &otp, .read);
    try (kitty_clipboard.PasteEvent{
        .primary = req.source.clipboard != .standard,
        .pw = &otp,
        .available = mimes_buf[0..mimes_len],
    }).encode(ctx.writer);
}
test {
    std.testing.refAllDecls(@This());
}
