const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const build_config = @import("../build_config.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
pub fn SplitTree(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const View = V;
        arena: ArenaAllocator,
        nodes: []const Node,
        zoomed: ?Node.Handle,
        pub const empty: Self = .{
            .arena = undefined,
            .nodes = &.{},
            .zoomed = null,
        };
        pub const Node = union(enum) {
            leaf: *View,
            split: Split,
            pub const Handle = enum(Backing) {
                root = 0,
                _,
                pub const Backing = u16;
                pub inline fn idx(self: Handle) usize {
                    return @intFromEnum(self);
                }
                pub fn offset(self: Handle, v: usize) Handle {
                    const self_usize: usize = @intCast(@intFromEnum(self));
                    const final = self_usize + v;
                    assert(final < std.math.maxInt(Backing));
                    return @enumFromInt(final);
                }
            };
        };
        pub const Split = struct {
            layout: Layout,
            ratio: f16,
            left: Node.Handle,
            right: Node.Handle,
            pub const Layout = enum { horizontal, vertical };
            pub const Direction = enum { left, right, down, up };
        };
        pub fn init(gpa: Allocator, view: *View) Allocator.Error!Self {
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            const nodes = try alloc.alloc(Node, 1);
            nodes[0] = .{ .leaf = try viewRef(view, gpa) };
            errdefer viewUnref(view, gpa);
            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = null,
            };
        }
        pub fn deinit(self: *Self) void {
            if (self.nodes.len > 0) {
                const gpa: Allocator = self.arena.child_allocator;
                for (self.nodes) |node| switch (node) {
                    .leaf => |view| viewUnref(view, gpa),
                    .split => {},
                };
                self.arena.deinit();
            }
            self.* = undefined;
        }
        pub fn clone(self: *const Self, gpa: Allocator) Allocator.Error!Self {
            if (self.isEmpty()) return .empty;
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            const nodes = try alloc.dupe(Node, self.nodes);
            try refNodes(gpa, nodes);
            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = self.zoomed,
            };
        }
        pub fn isEmpty(self: *const Self) bool {
            return self.nodes.len == 0;
        }
        pub fn isSplit(self: *const Self) bool {
            if (self.isEmpty()) return false;
            return switch (self.nodes[0]) {
                .split => true,
                .leaf => false,
            };
        }
        pub fn locate(self: *const Self, view: *const View) ?Node.Handle {
            var it = self.iterator();
            while (it.next()) |entry| {
                if (entry.view == view) {
                    return entry.handle;
                }
            }
            return null;
        }
        pub fn iterator(
            self: *const Self,
        ) Iterator {
            return .{ .nodes = self.nodes };
        }
        pub const ViewEntry = struct {
            handle: Node.Handle,
            view: *View,
        };
        pub const Iterator = struct {
            i: Node.Handle = .root,
            nodes: []const Node,
            pub fn next(self: *Iterator) ?ViewEntry {
                if (@intFromEnum(self.i) >= self.nodes.len) return null;
                const handle = self.i;
                self.i = @enumFromInt(handle.idx() + 1);
                const node = self.nodes[handle.idx()];
                return switch (node) {
                    .leaf => |v| .{ .handle = handle, .view = v },
                    .split => self.next(),
                };
            }
        };
        pub fn zoom(self: *Self, handle: ?Node.Handle) void {
            if (handle) |v| {
                assert(@intFromEnum(v) >= 0);
                assert(@intFromEnum(v) < self.nodes.len);
            }
            self.zoomed = handle;
        }
        pub const Goto = union(enum) {
            previous,
            next,
            previous_wrapped,
            next_wrapped,
            spatial: Spatial.Direction,
        };
        pub fn goto(
            self: *const Self,
            alloc: Allocator,
            from: Node.Handle,
            to: Goto,
        ) Allocator.Error!?Node.Handle {
            return switch (to) {
                .previous => self.previous(from),
                .next => self.next(from),
                .previous_wrapped => self.previous(from) orelse self.deepest(.right, .root),
                .next_wrapped => self.next(from) orelse self.deepest(.left, .root),
                .spatial => |d| spatial: {
                    var sp = try self.spatial(alloc);
                    defer sp.deinit(alloc);
                    break :spatial self.nearestWrapped(sp, from, d);
                },
            };
        }
        pub const Side = enum { left, right };
        pub fn deepest(
            self: *const Self,
            side: Side,
            from: Node.Handle,
        ) Node.Handle {
            var current: Node.Handle = from;
            while (true) {
                switch (self.nodes[current.idx()]) {
                    .leaf => return current,
                    .split => |s| current = switch (side) {
                        .left => s.left,
                        .right => s.right,
                    },
                }
            }
        }
        fn previous(self: *const Self, from: Node.Handle) ?Node.Handle {
            return switch (self.previousBacktrack(from, .root)) {
                .result => |v| v,
                .backtrack, .deadend => null,
            };
        }
        fn next(self: *const Self, from: Node.Handle) ?Node.Handle {
            return switch (self.nextBacktrack(from, .root)) {
                .result => |v| v,
                .backtrack, .deadend => null,
            };
        }
        const Backtrack = union(enum) {
            deadend,
            backtrack,
            result: Node.Handle,
        };
        fn previousBacktrack(
            self: *const Self,
            from: Node.Handle,
            current: Node.Handle,
        ) Backtrack {
            if (from == current) return .backtrack;
            return switch (self.nodes[current.idx()]) {
                .leaf => .deadend,
                .split => |s| switch (self.previousBacktrack(from, s.left)) {
                    .result => |v| .{ .result = v },
                    .backtrack => .backtrack,
                    .deadend => switch (self.previousBacktrack(from, s.right)) {
                        .result => |v| .{ .result = v },
                        .deadend => .deadend,
                        .backtrack => .{ .result = self.deepest(.right, s.left) },
                    },
                },
            };
        }
        fn nextBacktrack(
            self: *const Self,
            from: Node.Handle,
            current: Node.Handle,
        ) Backtrack {
            if (from == current) return .backtrack;
            return switch (self.nodes[current.idx()]) {
                .leaf => .deadend,
                .split => |s| switch (self.nextBacktrack(from, s.right)) {
                    .result => |v| .{ .result = v },
                    .backtrack => .backtrack,
                    .deadend => switch (self.nextBacktrack(from, s.left)) {
                        .result => |v| .{ .result = v },
                        .deadend => .deadend,
                        .backtrack => .{ .result = self.deepest(.left, s.right) },
                    },
                },
            };
        }
        fn nearest(
            self: *const Self,
            sp: Spatial,
            from: Node.Handle,
            direction: Spatial.Direction,
            target: Spatial.Slot,
        ) ?Node.Handle {
            var result: ?struct {
                handle: Node.Handle,
                distance: f16,
            } = null;
            for (sp.slots, 0..) |slot, handle| {
                if (handle == from.idx()) continue;
                switch (self.nodes[handle]) {
                    .leaf => {},
                    .split => continue,
                }
                if (!switch (direction) {
                    .left => slot.maxX() <= target.x,
                    .right => slot.x >= target.maxX(),
                    .up => slot.maxY() <= target.y,
                    .down => slot.y >= target.maxY(),
                }) continue;
                const dx = slot.x - target.x;
                const dy = slot.y - target.y;
                const distance = @sqrt(dx * dx + dy * dy);
                if (result) |n| {
                    if (distance >= n.distance) continue;
                }
                result = .{
                    .handle = @enumFromInt(handle),
                    .distance = distance,
                };
            }
            return if (result) |n| n.handle else null;
        }
        fn nearestWrapped(
            self: *const Self,
            sp: Spatial,
            from: Node.Handle,
            direction: Spatial.Direction,
        ) ?Node.Handle {
            var target = sp.slots[from.idx()];
            if (self.nearest(
                sp,
                from,
                direction,
                target,
            )) |v| return v;
            assert(target.x >= 0 and target.y >= 0);
            assert(target.maxX() <= 1 and target.maxY() <= 1);
            switch (direction) {
                .left => target.x += 1,
                .right => target.x -= 1,
                .up => target.y += 1,
                .down => target.y -= 1,
            }
            return self.nearest(
                sp,
                from,
                direction,
                target,
            );
        }
        pub fn resizeInPlace(
            self: *Self,
            at: Node.Handle,
            ratio: f16,
        ) void {
            const s: *Split = @constCast(&self.nodes[at.idx()].split);
            s.ratio = ratio;
        }
        pub fn split(
            self: *const Self,
            gpa: Allocator,
            at: Node.Handle,
            direction: Split.Direction,
            ratio: f16,
            insert: *const Self,
        ) Allocator.Error!Self {
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            const nodes = try alloc.alloc(Node, self.nodes.len + insert.nodes.len + 1);
            if (nodes.len > std.math.maxInt(Node.Handle.Backing)) return error.OutOfMemory;
            @memcpy(nodes[0..self.nodes.len], self.nodes);
            const nodes_inserted = nodes[self.nodes.len..][0..insert.nodes.len];
            @memcpy(nodes_inserted, insert.nodes);
            for (nodes_inserted) |*node| switch (node.*) {
                .leaf => {},
                .split => |*s| {
                    s.left = s.left.offset(self.nodes.len);
                    s.right = s.right.offset(self.nodes.len);
                },
            };
            const layout: Split.Layout, const left: bool = switch (direction) {
                .left => .{ .horizontal, true },
                .right => .{ .horizontal, false },
                .up => .{ .vertical, true },
                .down => .{ .vertical, false },
            };
            nodes[nodes.len - 1] = nodes[at.idx()];
            nodes[at.idx()] = .{ .split = .{
                .layout = layout,
                .ratio = ratio,
                .left = @enumFromInt(if (left) self.nodes.len else nodes.len - 1),
                .right = @enumFromInt(if (left) nodes.len - 1 else self.nodes.len),
            } };
            try refNodes(gpa, nodes);
            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = null,
            };
        }
        pub fn remove(
            self: *Self,
            gpa: Allocator,
            at: Node.Handle,
        ) Allocator.Error!Self {
            assert(at.idx() < self.nodes.len);
            if (at == .root) return .empty;
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            const nodes = try alloc.alloc(Node, self.countAfterRemoval(
                .root,
                at,
                0,
            ));
            var result: Self = .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = null,
            };
            assert(self.removeNode(
                &result,
                0,
                .root,
                at,
            ) != 0);
            try refNodes(gpa, nodes);
            return result;
        }
        fn removeNode(
            old: *Self,
            new: *Self,
            new_offset: usize,
            current: Node.Handle,
            target: Node.Handle,
        ) usize {
            assert(current != target);
            if (old.zoomed) |v| {
                if (v == current) {
                    assert(new.zoomed == null);
                    new.zoomed = @enumFromInt(new_offset);
                }
            }
            const new_nodes: []Node = @constCast(new.nodes);
            switch (old.nodes[current.idx()]) {
                .leaf => |view| {
                    new_nodes[new_offset] = .{ .leaf = view };
                    return 1;
                },
                .split => |s| {
                    if (s.left == target) return old.removeNode(
                        new,
                        new_offset,
                        s.right,
                        target,
                    );
                    if (s.right == target) return old.removeNode(
                        new,
                        new_offset,
                        s.left,
                        target,
                    );
                    const left = old.removeNode(
                        new,
                        new_offset + 1,
                        s.left,
                        target,
                    );
                    assert(left != 0);
                    const right = old.removeNode(
                        new,
                        new_offset + left + 1,
                        s.right,
                        target,
                    );
                    assert(right != 0);
                    new_nodes[new_offset] = .{ .split = .{
                        .layout = s.layout,
                        .ratio = s.ratio,
                        .left = @enumFromInt(new_offset + 1),
                        .right = @enumFromInt(new_offset + 1 + left),
                    } };
                    return left + right + 1;
                },
            }
        }
        fn countAfterRemoval(
            self: *Self,
            current: Node.Handle,
            target: Node.Handle,
            acc: usize,
        ) usize {
            assert(current != target);
            return switch (self.nodes[current.idx()]) {
                .leaf => acc + 1,
                .split => |s| if (s.left == target) self.countAfterRemoval(
                    s.right,
                    target,
                    acc,
                ) else if (s.right == target) self.countAfterRemoval(
                    s.left,
                    target,
                    acc,
                ) else self.countAfterRemoval(
                    s.left,
                    target,
                    acc,
                ) + self.countAfterRemoval(
                    s.right,
                    target,
                    acc,
                ) + 1,
            };
        }
        fn refNodes(gpa: Allocator, nodes: []Node) Allocator.Error!void {
            var reffed: usize = 0;
            errdefer for (0..reffed) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| viewUnref(view, gpa),
                }
            };
            for (0..nodes.len) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| nodes[i] = .{ .leaf = try viewRef(view, gpa) },
                }
                reffed = i;
            }
            assert(reffed == nodes.len - 1);
        }
        pub fn equalize(
            self: *const Self,
            gpa: Allocator,
        ) Allocator.Error!Self {
            if (self.isEmpty()) return .empty;
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            const nodes = try alloc.dupe(Node, self.nodes);
            for (nodes) |*node| switch (node.*) {
                .leaf => {},
                .split => |*s| {
                    const weight_left = self.weight(s.left, s.layout, 0);
                    const weight_right = self.weight(s.right, s.layout, 0);
                    assert(weight_left > 0);
                    assert(weight_right > 0);
                    const total_f16: f16 = @floatFromInt(weight_left + weight_right);
                    const weight_left_f16: f16 = @floatFromInt(weight_left);
                    s.ratio = weight_left_f16 / total_f16;
                },
            };
            try refNodes(gpa, nodes);
            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = self.zoomed,
            };
        }
        fn weight(
            self: *const Self,
            from: Node.Handle,
            layout: Split.Layout,
            acc: usize,
        ) usize {
            return switch (self.nodes[from.idx()]) {
                .leaf => acc + 1,
                .split => |s| if (s.layout == layout)
                    self.weight(s.left, layout, acc) +
                        self.weight(s.right, layout, acc)
                else
                    1,
            };
        }
        pub fn resize(
            self: *const Self,
            gpa: Allocator,
            from: Node.Handle,
            layout: Split.Layout,
            ratio: f16,
        ) Allocator.Error!Self {
            assert(ratio >= -1 and ratio <= 1);
            assert(!std.math.isNan(ratio));
            assert(!std.math.isInf(ratio));
            if (self.isEmpty()) return .empty;
            var result = try self.clone(gpa);
            errdefer result.deinit();
            const parent_handle = switch (self.findParentSplit(
                layout,
                from,
                .root,
            )) {
                .deadend, .backtrack => return result,
                .result => |v| v,
            };
            var sp = try result.spatial(gpa);
            defer sp.deinit(gpa);
            const scale = switch (layout) {
                .horizontal => sp.slots[parent_handle.idx()].width / sp.slots[0].width,
                .vertical => sp.slots[parent_handle.idx()].height / sp.slots[0].height,
            };
            if (scale == 0) return result;
            const new_ratio = result.nodes[parent_handle.idx()].split.ratio + (ratio / scale);
            result.resizeInPlace(
                parent_handle,
                @min(@max(new_ratio, 0), 1),
            );
            return result;
        }
        fn findParentSplit(
            self: *const Self,
            layout: Split.Layout,
            from: Node.Handle,
            current: Node.Handle,
        ) Backtrack {
            if (from == current) return .backtrack;
            return switch (self.nodes[current.idx()]) {
                .leaf => .deadend,
                .split => |s| switch (self.findParentSplit(
                    layout,
                    from,
                    s.left,
                )) {
                    .result => |v| .{ .result = v },
                    .backtrack => if (s.layout == layout)
                        .{ .result = current }
                    else
                        .backtrack,
                    .deadend => switch (self.findParentSplit(
                        layout,
                        from,
                        s.right,
                    )) {
                        .deadend => .deadend,
                        .result => |v| .{ .result = v },
                        .backtrack => if (s.layout == layout)
                            .{ .result = current }
                        else
                            .backtrack,
                    },
                },
            };
        }
        pub const Spatial = struct {
            slots: []const Slot,
            pub const empty: Spatial = .{ .slots = &.{} };
            pub const Direction = enum { left, right, down, up };
            const Slot = struct {
                x: f16,
                y: f16,
                width: f16,
                height: f16,
                fn maxX(self: *const Slot) f16 {
                    return self.x + self.width;
                }
                fn maxY(self: *const Slot) f16 {
                    return self.y + self.height;
                }
            };
            pub fn deinit(self: *Spatial, alloc: Allocator) void {
                alloc.free(self.slots);
                self.* = undefined;
            }
        };
        pub fn spatial(
            self: *const Self,
            alloc: Allocator,
        ) Allocator.Error!Spatial {
            if (self.nodes.len == 0) return .empty;
            const dim = self.dimensions(.root);
            const slots = try alloc.alloc(Spatial.Slot, self.nodes.len);
            errdefer alloc.free(slots);
            slots[0] = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(dim.width),
                .height = @floatFromInt(dim.height),
            };
            self.fillSpatialSlots(slots, .root);
            for (slots) |*slot| {
                slot.x /= @floatFromInt(dim.width);
                slot.y /= @floatFromInt(dim.height);
                slot.width /= @floatFromInt(dim.width);
                slot.height /= @floatFromInt(dim.height);
            }
            return .{ .slots = slots };
        }
        fn fillSpatialSlots(
            self: *const Self,
            slots: []Spatial.Slot,
            current_: Node.Handle,
        ) void {
            const current = current_.idx();
            assert(slots[current].width >= 0 and slots[current].height >= 0);
            switch (self.nodes[current]) {
                .leaf => {},
                .split => |s| {
                    switch (s.layout) {
                        .horizontal => {
                            slots[s.left.idx()] = .{
                                .x = slots[current].x,
                                .y = slots[current].y,
                                .width = slots[current].width * s.ratio,
                                .height = slots[current].height,
                            };
                            slots[s.right.idx()] = .{
                                .x = slots[current].x + slots[current].width * s.ratio,
                                .y = slots[current].y,
                                .width = slots[current].width * (1 - s.ratio),
                                .height = slots[current].height,
                            };
                        },
                        .vertical => {
                            slots[s.left.idx()] = .{
                                .x = slots[current].x,
                                .y = slots[current].y,
                                .width = slots[current].width,
                                .height = slots[current].height * s.ratio,
                            };
                            slots[s.right.idx()] = .{
                                .x = slots[current].x,
                                .y = slots[current].y + slots[current].height * s.ratio,
                                .width = slots[current].width,
                                .height = slots[current].height * (1 - s.ratio),
                            };
                        },
                    }
                    self.fillSpatialSlots(slots, s.left);
                    self.fillSpatialSlots(slots, s.right);
                },
            }
        }
        fn dimensions(self: *const Self, current: Node.Handle) struct {
            width: u16,
            height: u16,
        } {
            return switch (self.nodes[current.idx()]) {
                .leaf => .{ .width = 1, .height = 1 },
                .split => |s| split: {
                    const left = self.dimensions(s.left);
                    const right = self.dimensions(s.right);
                    break :split switch (s.layout) {
                        .horizontal => .{
                            .width = left.width + right.width,
                            .height = @max(left.height, right.height),
                        },
                        .vertical => .{
                            .width = @max(left.width, right.width),
                            .height = left.height + right.height,
                        },
                    };
                },
            };
        }
        pub fn format(
            self: *const Self,
            writer: *std.Io.Writer,
        ) !void {
            if (self.nodes.len == 0) {
                try writer.writeAll("empty");
                return;
            }
            self.formatDiagram(writer) catch {};
            try self.formatText(writer);
        }
        pub fn formatText(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.nodes.len == 0) {
                try writer.writeAll("empty");
                return;
            }
            try self.formatTextInner(writer, .root, 0);
        }
        fn formatTextInner(
            self: Self,
            writer: *std.Io.Writer,
            current: Node.Handle,
            depth: usize,
        ) std.Io.Writer.Error!void {
            for (0..depth) |_| try writer.writeAll("  ");
            if (self.zoomed) |zoomed| if (zoomed == current) {
                try writer.writeAll("(zoomed) ");
            };
            switch (self.nodes[current.idx()]) {
                .leaf => |v| if (@hasDecl(View, "splitTreeLabel"))
                    try writer.print("leaf: {s}\n", .{v.splitTreeLabel()})
                else
                    try writer.print("leaf: {d}\n", .{current}),
                .split => |s| {
                    try writer.print("split (layout: {t}, ratio: {d:.2})\n", .{
                        s.layout,
                        s.ratio,
                    });
                    try self.formatTextInner(writer, s.left, depth + 1);
                    try self.formatTextInner(writer, s.right, depth + 1);
                },
            }
        }
        pub fn formatDiagram(
            self: Self,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (self.nodes.len == 0) {
                try writer.writeAll("empty");
                return;
            }
            var arena: ArenaAllocator = .init(self.arena.child_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const sp = spatial: {
                const sp = self.spatial(alloc) catch return error.WriteFailed;
                var min_w: f16 = 1;
                var min_h: f16 = 1;
                for (sp.slots) |slot| {
                    if (slot.width > 0) min_w = @min(min_w, slot.width);
                    if (slot.height > 0) min_h = @min(min_h, slot.height);
                }
                const ratio_w: f16 = 1 / min_w;
                const ratio_h: f16 = 1 / min_h;
                const slots = alloc.dupe(Spatial.Slot, sp.slots) catch return error.WriteFailed;
                for (slots) |*slot| {
                    slot.x *= ratio_w;
                    slot.y *= ratio_h;
                    slot.width *= ratio_w;
                    slot.height *= ratio_h;
                }
                break :spatial .{ .slots = slots };
            };
            const max_label_width: usize = max_label_width: {
                if (!@hasDecl(View, "splitTreeLabel")) {
                    break :max_label_width std.math.log10(sp.slots.len) + 1;
                }
                var max: usize = 0;
                for (self.nodes) |node| switch (node) {
                    .split => {},
                    .leaf => |view| {
                        const label = view.splitTreeLabel();
                        max = @max(max, label.len);
                    },
                };
                break :max_label_width max;
            };
            const cell_width = cell_width: {
                break :cell_width 2 + max_label_width + 2;
            };
            const cell_height = cell_height: {
                break :cell_height 1 + 1 + 1;
            };
            const grid = grid: {
                var width: usize = @intFromFloat(@ceil(sp.slots[0].width));
                var height: usize = @intFromFloat(@ceil(sp.slots[0].height));
                width *= cell_width;
                height *= cell_height;
                const rows = alloc.alloc([]u8, height) catch return error.WriteFailed;
                for (0..rows.len) |y| {
                    rows[y] = alloc.alloc(u8, width + 1) catch return error.WriteFailed;
                    @memset(rows[y], ' ');
                    rows[y][width] = '\n';
                }
                break :grid rows;
            };
            for (sp.slots, 0..) |slot, handle| {
                const node = self.nodes[handle];
                switch (node) {
                    .leaf => {},
                    .split => continue,
                }
                if (slot.width == 0 or slot.height == 0) continue;
                var x: usize = @intFromFloat(@floor(slot.x));
                var y: usize = @intFromFloat(@floor(slot.y));
                var width: usize = @intFromFloat(@max(@floor(slot.width), 1));
                var height: usize = @intFromFloat(@max(@floor(slot.height), 1));
                x *= cell_width;
                y *= cell_height;
                width *= cell_width;
                height *= cell_height;
                {
                    const top = grid[y][x..][0..width];
                    top[0] = '+';
                    for (1..width - 1) |i| top[i] = '-';
                    top[width - 1] = '+';
                }
                {
                    const bottom = grid[y + height - 1][x..][0..width];
                    bottom[0] = '+';
                    for (1..width - 1) |i| bottom[i] = '-';
                    bottom[width - 1] = '+';
                }
                for (y + 1..y + height - 1) |y_cur| grid[y_cur][x] = '|';
                for (y + 1..y + height - 1) |y_cur| grid[y_cur][x + width - 1] = '|';
                var buf: [10]u8 = undefined;
                const label: []const u8 = if (@hasDecl(View, "splitTreeLabel"))
                    node.leaf.splitTreeLabel()
                else
                    std.fmt.bufPrint(&buf, "{d}", .{handle}) catch return error.WriteFailed;
                const x_mid = width / 2 + x;
                const y_mid = height / 2 + y;
                const label_width = label.len;
                const label_start = x_mid - label_width / 2;
                const row = grid[y_mid][label_start..];
                _ = std.fmt.bufPrint(row, "{s}", .{label}) catch return error.WriteFailed;
            }
            for (grid) |row| {
                if (row[0] == ' ') break;
                try writer.writeAll(row);
            }
        }
        fn viewRef(view: *View, gpa: Allocator) Allocator.Error!*View {
            const func = @typeInfo(@TypeOf(View.ref)).@"fn";
            return switch (func.params.len) {
                1 => view.ref(),
                2 => try view.ref(gpa),
                else => @compileError("invalid view ref function"),
            };
        }
        fn viewUnref(view: *View, gpa: Allocator) void {
            const func = @typeInfo(@TypeOf(View.unref)).@"fn";
            switch (func.params.len) {
                1 => view.unref(),
                2 => view.unref(gpa),
                else => @compileError("invalid view unref function"),
            }
        }
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk => @import("gobject").ext.defineBoxed(
                Self,
                .{
                    .name = name: {
                        const type_name = @typeName(View);
                        const last = if (std.mem.lastIndexOfScalar(
                            u8,
                            type_name,
                            '.',
                        )) |idx|
                            type_name[idx + 1 ..]
                        else
                            type_name;
                        assert(last.len > 0);
                        break :name "WaspSplitTree" ++ last;
                    },
                    .funcs = .{
                        .copy = &struct {
                            fn copy(self: *Self) callconv(.c) *Self {
                                const ptr = @import("glib").ext.create(Self);
                                ptr.* = if (self.nodes.len == 0)
                                    .empty
                                else
                                    self.clone(self.arena.child_allocator) catch @panic("oom");
                                return ptr;
                            }
                        }.copy,
                        .free = &struct {
                            fn free(self: *Self) callconv(.c) void {
                                self.deinit();
                                @import("glib").ext.destroy(self);
                            }
                        }.free,
                    },
                },
            ),
            .none => void,
        };
    };
}
const TestTree = SplitTree(TestView);
const TestView = struct {
    const Self = @This();
    label: []const u8,
    pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
        const ptr = try alloc.create(Self);
        ptr.* = self.*;
        return ptr;
    }
    pub fn unref(self: *Self, alloc: Allocator) void {
        alloc.destroy(self);
    }
    pub fn splitTreeLabel(self: *const Self) []const u8 {
        return self.label;
    }
};
test "SplitTree: isSplit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var empty: TestTree = .empty;
    defer empty.deinit();
    try testing.expect(!empty.isSplit());
    var v1: TestView = .{ .label = "A" };
    var single: TestTree = try TestTree.init(alloc, &v1);
    defer single.deinit();
    try testing.expect(!single.isSplit());
    var v2: TestView = .{ .label = "B" };
    var tree2: TestTree = try TestTree.init(alloc, &v2);
    defer tree2.deinit();
    var split = try single.split(
        alloc,
        .root,
        .right,
        0.5,
        &tree2,
    );
    defer split.deinit();
    try testing.expect(split.isSplit());
}
test "SplitTree: empty tree" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: TestTree = .empty;
    defer t.deinit();
    const str = try std.fmt.allocPrint(alloc, "{f}", .{t});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\empty
    );
}
test "SplitTree: single node" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v: TestTree.View = .{ .label = "A" };
    var t: TestTree = try .init(alloc, &v);
    defer t.deinit();
    const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(t, .formatDiagram)});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| A |
        \\+---+
        \\
    );
}
test "SplitTree: split horizontal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var t3 = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer t3.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{t3});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  leaf: B
            \\
        );
    }
    var vC: TestTree.View = .{ .label = "C" };
    var tC: TestTree = try .init(alloc, &vC);
    defer tC.deinit();
    var it = t3.iterator();
    var t4 = try t3.split(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound,
        .right,
        0.5,
        &tC,
    );
    defer t4.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{t4});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+--------++---++---+
            \\|    A   || B || C |
            \\+--------++---++---+
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  split (layout: horizontal, ratio: 0.50)
            \\    leaf: B
            \\    leaf: C
            \\
        );
    }
    var vD: TestTree.View = .{ .label = "D" };
    var tD: TestTree = try .init(alloc, &vD);
    defer tD.deinit();
    it = t4.iterator();
    var t5 = try t4.split(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "C")) {
                break entry.handle;
            }
        } else return error.NotFound,
        .right,
        0.5,
        &tD,
    );
    defer t5.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{t5});
        defer alloc.free(str);
        try testing.expectEqualStrings(
            \\+------------------++--------++---++---+
            \\|         A        ||    B   || C || D |
            \\+------------------++--------++---++---+
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  split (layout: horizontal, ratio: 0.50)
            \\    leaf: B
            \\    split (layout: horizontal, ratio: 0.50)
            \\      leaf: C
            \\      leaf: D
            \\
        , str);
    }
    {
        var current: u8 = 'D';
        while (current != 'A') : (current -= 1) {
            it = t5.iterator();
            const handle = t5.previous(
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, &.{current})) {
                        break entry.handle;
                    }
                } else return error.NotFound,
            ).?;
            const entry = t5.nodes[handle.idx()].leaf;
            try testing.expectEqualStrings(
                entry.label,
                &.{current - 1},
            );
        }
        it = t5.iterator();
        try testing.expect(t5.previous(
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, &.{current})) {
                    break entry.handle;
                }
            } else return error.NotFound,
        ) == null);
    }
    {
        var current: u8 = 'A';
        while (current != 'D') : (current += 1) {
            it = t5.iterator();
            const handle = t5.next(
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, &.{current})) {
                        break entry.handle;
                    }
                } else return error.NotFound,
            ).?;
            const entry = t5.nodes[handle.idx()].leaf;
            try testing.expectEqualStrings(
                entry.label,
                &.{current + 1},
            );
        }
        it = t5.iterator();
        try testing.expect(t5.next(
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, &.{current})) {
                    break entry.handle;
                }
            } else return error.NotFound,
        ) == null);
    }
}
test "SplitTree: split vertical" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var t3 = try t1.split(
        alloc,
        .root,
        .down,
        0.5,
        &t2,
    );
    defer t3.deinit();
    const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(t3, .formatDiagram)});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| A |
        \\+---+
        \\+---+
        \\| B |
        \\+---+
        \\
    );
}
test "SplitTree: split horizontal with zero ratio" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var splitAB = try t1.split(
        alloc,
        .root,
        .right,
        0,
        &t2,
    );
    defer splitAB.deinit();
    const split = splitAB;
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| B |
            \\+---+
            \\
        );
    }
}
test "SplitTree: split vertical with zero ratio" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var splitAB = try t1.split(
        alloc,
        .root,
        .down,
        0,
        &t2,
    );
    defer splitAB.deinit();
    const split = splitAB;
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| B |
            \\+---+
            \\
        );
    }
}
test "SplitTree: split horizontal with full width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var splitAB = try t1.split(
        alloc,
        .root,
        .right,
        1,
        &t2,
    );
    defer splitAB.deinit();
    const split = splitAB;
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\
        );
    }
}
test "SplitTree: split vertical with full width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var splitAB = try t1.split(
        alloc,
        .root,
        .down,
        1,
        &t2,
    );
    defer splitAB.deinit();
    const split = splitAB;
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\
        );
    }
}
test "SplitTree: remove leaf" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var t3 = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer t3.deinit();
    var it = t3.iterator();
    var t4 = try t3.remove(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound,
    );
    defer t4.deinit();
    const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(t4, .formatDiagram)});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| B |
        \\+---+
        \\
    );
}
test "SplitTree: split twice, remove intermediary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var v3: TestTree.View = .{ .label = "C" };
    var t3: TestTree = try .init(alloc, &v3);
    defer t3.deinit();
    var split1 = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer split1.deinit();
    var split2 = try split1.split(
        alloc,
        .root,
        .down,
        0.5,
        &t3,
    );
    defer split2.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split2, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\+--------+
            \\|    C   |
            \\+--------+
            \\
        );
    }
    var it = split2.iterator();
    var split3 = try split2.remove(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound,
    );
    defer split3.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split3, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\+---+
            \\| C |
            \\+---+
            \\
        );
    }
    for (0..split2.nodes.len) |i| {
        var t = try split2.remove(alloc, @enumFromInt(i));
        t.deinit();
    }
}
test "SplitTree: spatial goto" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var v3: TestTree.View = .{ .label = "C" };
    var t3: TestTree = try .init(alloc, &v3);
    defer t3.deinit();
    var v4: TestTree.View = .{ .label = "D" };
    var t4: TestTree = try .init(alloc, &v4);
    defer t4.deinit();
    var splitAB = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer splitAB.deinit();
    var splitAC = try splitAB.split(
        alloc,
        at: {
            var it = splitAB.iterator();
            break :at while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, "A")) {
                    break entry.handle;
                }
            } else return error.NotFound;
        },
        .down,
        0.8,
        &t3,
    );
    defer splitAC.deinit();
    var splitBD = try splitAC.split(
        alloc,
        at: {
            var it = splitAB.iterator();
            break :at while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, "B")) {
                    break entry.handle;
                }
            } else return error.NotFound;
        },
        .down,
        0.3,
        &t4,
    );
    defer splitBD.deinit();
    const split = splitBD;
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\|   || B |
            \\|   |+---+
            \\|   |+---+
            \\| A ||   |
            \\|   ||   |
            \\|   ||   |
            \\|   || D |
            \\+---+|   |
            \\+---+|   |
            \\| C ||   |
            \\+---++---+
            \\
        );
    }
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "C")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .right },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings(view.label, "D");
    }
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "D")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .left },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings("A", view.label);
    }
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "A")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .left },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings("B", view.label);
    }
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .right },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings("A", view.label);
    }
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "C")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .down },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings("A", view.label);
    }
    var equal = try split.equalize(alloc);
    defer equal.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(equal, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\+---++---+
            \\| C || D |
            \\+---++---+
            \\
        );
    }
}
test "SplitTree: resize" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var split = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer split.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\
        );
    }
    {
        var resized = try split.resize(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .horizontal,
            0.25,
        );
        defer resized.deinit();
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(resized, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+-------------++---+
            \\|      A      || B |
            \\+-------------++---+
            \\
        );
    }
    {
        var resized = try split.resize(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .horizontal,
            -0.25,
        );
        defer resized.deinit();
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(resized, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++-------------+
            \\| A ||      B      |
            \\+---++-------------+
            \\
        );
    }
}
test "SplitTree: resize nested split" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var v3: TestTree.View = .{ .label = "C" };
    var t3: TestTree = try .init(alloc, &v3);
    defer t3.deinit();
    var splitAB = try t1.split(
        alloc,
        .root,
        .down,
        0.5,
        &t2,
    );
    defer splitAB.deinit();
    var splitBC = try splitAB.split(
        alloc,
        at: {
            var it = splitAB.iterator();
            break :at while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, "B")) {
                    break entry.handle;
                }
            } else return error.NotFound;
        },
        .down,
        0.5,
        &t3,
    );
    defer splitBC.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(splitBC, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\|   |
            \\|   |
            \\| A |
            \\|   |
            \\+---+
            \\+---+
            \\| B |
            \\+---+
            \\+---+
            \\| C |
            \\+---+
            \\
        );
    }
    {
        var resized = try splitBC.resize(
            alloc,
            at: {
                var it = splitBC.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .vertical,
            0.125,
        );
        defer resized.deinit();
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(resized, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\|   |
            \\|   |
            \\|   |
            \\|   |
            \\|   |
            \\| A |
            \\|   |
            \\|   |
            \\|   |
            \\|   |
            \\+---+
            \\+---+
            \\|   |
            \\|   |
            \\|   |
            \\| B |
            \\|   |
            \\|   |
            \\|   |
            \\+---+
            \\+---+
            \\| C |
            \\+---+
            \\
        );
    }
    {
        var resized = try splitBC.resize(
            alloc,
            at: {
                var it = splitBC.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .vertical,
            -0.0833,
        );
        defer resized.deinit();
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(resized, .formatDiagram)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\|   |
            \\|   |
            \\|   |
            \\| A |
            \\|   |
            \\|   |
            \\|   |
            \\+---+
            \\+---+
            \\| B |
            \\+---+
            \\+---+
            \\|   |
            \\|   |
            \\| C |
            \\|   |
            \\+---+
            \\
        );
    }
}
test "SplitTree: clone empty tree" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: TestTree = .empty;
    defer t.deinit();
    var t2 = try t.clone(alloc);
    defer t2.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{t2});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\empty
        );
    }
}
test "SplitTree: zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var split = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer split.deinit();
    split.zoom(at: {
        var it = split.iterator();
        break :at while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound;
    });
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatText)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  (zoomed) leaf: B
            \\
        );
    }
    var clone = try split.clone(alloc);
    defer clone.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(clone, .formatText)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  (zoomed) leaf: B
            \\
        );
    }
}
test "SplitTree: split resets zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    t1.zoom(at: {
        var it = t1.iterator();
        break :at while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound;
    });
    var split = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer split.deinit();
    {
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(split, .formatText)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  leaf: B
            \\
        );
    }
}
test "SplitTree: remove and zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var split = try t1.split(
        alloc,
        .root,
        .right,
        0.5,
        &t2,
    );
    defer split.deinit();
    split.zoom(at: {
        var it = split.iterator();
        break :at while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound;
    });
    {
        var removed = try split.remove(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "A")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
        );
        defer removed.deinit();
        try testing.expect(removed.zoomed == null);
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(removed, .formatText)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\leaf: B
            \\
        );
    }
    {
        var removed = try split.remove(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
        );
        defer removed.deinit();
        const str = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(removed, .formatText)});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\(zoomed) leaf: A
            \\
        );
    }
}
