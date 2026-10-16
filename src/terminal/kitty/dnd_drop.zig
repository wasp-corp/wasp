const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const osc = @import("../osc.zig");
const command = @import("dnd_command.zig");
const response = @import("dnd_response.zig");
const Metadata = command.Metadata;
const Operation = command.Operation;
const Operations = command.Operations;
const log = std.log.scoped(.kitty_dnd);
pub const max_mime_list_bytes = 1024 * 1024;
pub fn handleCommand(
    slot: *?*State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    v: osc.Command.KittyDndProtocol,
) (Allocator.Error || std.Io.Writer.Error)!?Event {
    const raw = Metadata.parse(v.metadata) orelse {
        log.debug("dropping malformed OSC 72 metadata", .{});
        return null;
    };
    const continuation = if (slot.*) |state| state.chunking.active else false;
    const meta = if (slot.*) |state| state.chunking.apply(raw) else raw;
    const payload = v.payload orelse "";
    const t = meta.type orelse return null;
    switch (t) {
        .register => {
            if (meta.cell_x == 1) return null;
            const state = slot.* orelse state: {
                const state = try State.create(alloc);
                slot.* = state;
                _ = state.chunking.apply(raw);
                break :state state;
            };
            state.drop.client_id = meta.client_id;
            return try state.register(
                alloc,
                payload,
                continuation,
                meta.more,
            );
        },
        .unregister => {
            const state = slot.* orelse return null;
            state.destroy(alloc);
            slot.* = null;
            return .registration;
        },
        .status => {
            const state = slot.* orelse return null;
            return try state.acceptStatus(alloc, meta, payload);
        },
        .request => return try dataRequest(
            slot.*,
            alloc,
            writer,
            meta,
            v.terminator,
        ),
        .offer => if (meta.cell_x == 0) try refuseDragOut(
            writer,
            meta,
            v.terminator,
        ),
        .present, .start_drag => try refuseDragOut(
            writer,
            meta,
            v.terminator,
        ),
        .drag_event, .drag_error, .remote_data => {},
        .query => try response.encode(
            writer,
            "t=q",
            meta.client_id,
            "",
            .plain,
            v.terminator,
        ),
        .drop, .request_error => {},
    }
    return null;
}
fn dataRequest(
    state: ?*State,
    alloc: Allocator,
    writer: *std.Io.Writer,
    meta: Metadata,
    terminator: osc.Terminator,
) (Allocator.Error || std.Io.Writer.Error)!?Event {
    const client_id = if (state) |s| s.drop.client_id else 0;
    switch (command.Request.init(meta)) {
        .conclude => |op| {
            const s = state orelse return null;
            const dropped = s.drop.dropped;
            s.resetDrop(alloc);
            return if (dropped) Event.concluded(op) else null;
        },
        .mime => |idx| {
            const keys: response.RequestKeys = .{ .x = idx };
            const items = (if (state) |s| s.drop.items else null) orelse {
                try response.encodeError(
                    writer,
                    .drop,
                    keys,
                    client_id,
                    .ENOENT,
                    "no drop data available",
                    terminator,
                );
                return null;
            };
            if (idx < 1 or @as(usize, @intCast(idx)) > items.len) {
                try response.encodeError(
                    writer,
                    .drop,
                    keys,
                    client_id,
                    .ENOENT,
                    "drop data request index out of bounds",
                    terminator,
                );
                return null;
            }
            var header_buf: [32]u8 = undefined;
            const header = std.fmt.bufPrint(
                &header_buf,
                "t=r{f}",
                .{keys},
            ) catch unreachable;
            const item = items[@intCast(idx - 1)];
            if (item.data.len > 0) try response.encode(
                writer,
                header,
                client_id,
                item.data,
                .base64,
                terminator,
            );
            try response.encode(writer, header, client_id, "", .base64, terminator);
            return null;
        },
        .uri => |uri| try response.encodeError(
            writer,
            .drop,
            .{ .x = uri.mime_idx, .y = uri.uri_idx },
            client_id,
            .EINVAL,
            "remote drop data is not supported",
            terminator,
        ),
        .dir => |dir| try response.encodeError(
            writer,
            .drop,
            .{ .x = dir.entry, .Y = dir.handle },
            client_id,
            .EINVAL,
            "remote drop data is not supported",
            terminator,
        ),
    }
    return null;
}
fn refuseDragOut(
    writer: *std.Io.Writer,
    meta: Metadata,
    terminator: osc.Terminator,
) std.Io.Writer.Error!void {
    try response.encodeError(
        writer,
        .drag,
        .{},
        meta.client_id,
        .EPERM,
        "drag out is not supported by this terminal",
        terminator,
    );
}
pub const Event = enum {
    registration,
    acceptance,
    concluded_none,
    concluded_copy,
    concluded_move,
    pub fn concluded(op: Operation) Event {
        return switch (op) {
            .none => .concluded_none,
            .copy => .concluded_copy,
            .move => .concluded_move,
        };
    }
};
pub const State = struct {
    chunking: command.Chunking = .{},
    drop: DropTarget = .{},
    pub const DropTarget = struct {
        client_id: u32 = 0,
        registered_mimes: std.ArrayListUnmanaged(u8) = .empty,
        hovered: bool = false,
        dropped: bool = false,
        accepted: ?Operation = null,
        accept_in_progress: bool = false,
        accepted_mimes: std.ArrayListUnmanaged(u8) = .empty,
        offered: ?Offered = null,
        items: ?[]const Item = null,
    };
    pub const Item = struct {
        mime: []const u8,
        data: []const u8,
    };
    const Offered = struct {
        mimes: []const []const u8,
        payload: []const u8,
        fn init(alloc: Allocator, mimes: []const []const u8) Allocator.Error!Offered {
            const copies = try alloc.alloc([]const u8, mimes.len);
            errdefer alloc.free(copies);
            var payload_len: usize = 0;
            for (mimes) |m| payload_len += m.len + 1;
            const payload = try alloc.alloc(u8, payload_len);
            errdefer alloc.free(payload);
            var offset: usize = 0;
            for (mimes, copies) |m, *copy| {
                @memcpy(payload[offset..][0..m.len], m);
                payload[offset + m.len] = ' ';
                copy.* = payload[offset..][0..m.len];
                offset += m.len + 1;
            }
            return .{ .mimes = copies, .payload = payload };
        }
        fn deinit(self: *const Offered, alloc: Allocator) void {
            alloc.free(self.mimes);
            alloc.free(self.payload);
        }
        fn eql(self: *const Offered, mimes: []const []const u8) bool {
            if (self.mimes.len != mimes.len) return false;
            for (self.mimes, mimes) |a, b| {
                if (!std.mem.eql(u8, a, b)) return false;
            }
            return true;
        }
    };
    pub const max_items = 16;
    fn create(alloc: Allocator) Allocator.Error!*State {
        const state = try alloc.create(State);
        state.* = .{};
        return state;
    }
    pub fn destroy(self: *State, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }
    fn deinit(self: *State, alloc: Allocator) void {
        self.freeDragData(alloc);
        self.drop.accepted_mimes.deinit(alloc);
        self.drop.registered_mimes.deinit(alloc);
    }
    pub fn registeredMimes(self: *const State) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(
            u8,
            self.drop.registered_mimes.items,
            ' ',
        );
    }
    fn register(
        self: *State,
        alloc: Allocator,
        payload: []const u8,
        continuation: bool,
        more: bool,
    ) Allocator.Error!?Event {
        const list = &self.drop.registered_mimes;
        if (!continuation) list.clearRetainingCapacity();
        if (list.items.len + payload.len > max_mime_list_bytes) return null;
        try list.appendSlice(alloc, payload);
        return if (more) null else .registration;
    }
    pub fn clientAccepted(self: *const State) ?Operation {
        if (self.drop.accept_in_progress) return null;
        return self.drop.accepted;
    }
    fn freeDragData(self: *State, alloc: Allocator) void {
        if (self.drop.offered) |*offered| {
            offered.deinit(alloc);
            self.drop.offered = null;
        }
        if (self.drop.items) |items| {
            for (items) |item| {
                alloc.free(item.mime);
                alloc.free(item.data);
            }
            alloc.free(items);
            self.drop.items = null;
        }
    }
    fn resetDrop(self: *State, alloc: Allocator) void {
        self.freeDragData(alloc);
        self.drop.accepted_mimes.clearAndFree(alloc);
        self.drop.hovered = false;
        self.drop.dropped = false;
        self.drop.accepted = null;
        self.drop.accept_in_progress = false;
    }
    fn acceptStatus(
        self: *State,
        alloc: Allocator,
        meta: Metadata,
        payload: []const u8,
    ) Allocator.Error!?Event {
        const d = &self.drop;
        if (!d.accept_in_progress) {
            d.accepted_mimes.clearRetainingCapacity();
            d.accept_in_progress = true;
            d.accepted = .fromProtocol(meta.operation);
        }
        if (payload.len > 0) {
            if (d.accepted_mimes.items.len + payload.len > max_mime_list_bytes) return null;
            try d.accepted_mimes.appendSlice(alloc, payload);
        }
        if (meta.more) return null;
        d.accept_in_progress = false;
        if (d.accepted_mimes.items.len > 0) {
            for (d.accepted_mimes.items) |*c| {
                if (c.* == ' ') c.* = 0;
            }
            try d.accepted_mimes.append(alloc, 0);
        }
        return .acceptance;
    }
    pub const MoveEvent = struct {
        cell_x: u32,
        cell_y: u32,
        pixel_x: i32,
        pixel_y: i32,
        operations: Operations,
    };
    pub fn dragMove(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        try self.moveEvent(
            alloc,
            writer,
            ev,
            mimes,
            false,
        );
    }
    pub fn dragDrop(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        items: []const Item,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        const accepted_items = items[0..@min(items.len, max_items)];
        const copies = try alloc.alloc(Item, accepted_items.len);
        errdefer alloc.free(copies);
        var copied: usize = 0;
        errdefer for (copies[0..copied]) |item| {
            alloc.free(item.mime);
            alloc.free(item.data);
        };
        for (accepted_items, copies) |item, *copy| {
            const mime = try alloc.dupe(u8, item.mime);
            errdefer alloc.free(mime);
            const data = try alloc.dupe(u8, item.data);
            copy.* = .{ .mime = mime, .data = data };
            copied += 1;
        }
        var mimes_buf: [max_items][]const u8 = undefined;
        const mimes = mimes_buf[0..copies.len];
        for (mimes, copies) |*m, item| m.* = item.mime;
        try self.moveEvent(
            alloc,
            writer,
            ev,
            mimes,
            true,
        );
        assert(self.drop.items == null);
        self.drop.items = copies;
    }
    pub fn dragLeave(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.drop.dropped) return;
        const hovered = self.drop.hovered;
        self.drop.hovered = false;
        if (self.drop.offered) |*offered| {
            offered.deinit(alloc);
            self.drop.offered = null;
        }
        if (!hovered) return;
        try response.encode(
            writer,
            "t=m:x=-1:y=-1",
            self.drop.client_id,
            "",
            .plain,
            .st,
        );
    }
    fn moveEvent(
        self: *State,
        alloc: Allocator,
        writer: *std.Io.Writer,
        ev: MoveEvent,
        mimes: []const []const u8,
        is_drop: bool,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        if (!self.drop.hovered) {
            self.resetDrop(alloc);
            self.drop.hovered = true;
        }
        if (is_drop) {
            self.drop.dropped = true;
            self.drop.hovered = false;
        }
        if (self.drop.offered == null or !self.drop.offered.?.eql(mimes)) {
            if (self.drop.offered) |*offered| offered.deinit(alloc);
            self.drop.offered = null;
            self.drop.offered = try Offered.init(alloc, mimes);
        }
        var header_buf: [96]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "t={c}:x={d}:y={d}:X={d}:Y={d}:o={d}",
            .{
                @as(u8, if (is_drop) 'M' else 'm'),
                ev.cell_x,
                ev.cell_y,
                ev.pixel_x,
                ev.pixel_y,
                ev.operations.protocolValue(),
            },
        ) catch unreachable;
        try response.encode(
            writer,
            header,
            self.drop.client_id,
            self.drop.offered.?.payload,
            .plain,
            .st,
        );
    }
};
