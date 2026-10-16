const std = @import("std");
const testing = std.testing;
pub fn DoublyLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Node = T;
        first: ?*Node = null,
        last: ?*Node = null,
        pub inline fn insertAfter(list: *Self, node: *Node, new_node: *Node) void {
            new_node.prev = node;
            if (node.next) |next_node| {
                new_node.next = next_node;
                next_node.prev = new_node;
            } else {
                new_node.next = null;
                list.last = new_node;
            }
            node.next = new_node;
        }
        pub inline fn insertBefore(list: *Self, node: *Node, new_node: *Node) void {
            new_node.next = node;
            if (node.prev) |prev_node| {
                new_node.prev = prev_node;
                prev_node.next = new_node;
            } else {
                new_node.prev = null;
                list.first = new_node;
            }
            node.prev = new_node;
        }
        pub inline fn append(list: *Self, new_node: *Node) void {
            if (list.last) |last| {
                list.insertAfter(last, new_node);
            } else {
                list.prepend(new_node);
            }
        }
        pub inline fn prepend(list: *Self, new_node: *Node) void {
            if (list.first) |first| {
                list.insertBefore(first, new_node);
            } else {
                list.first = new_node;
                list.last = new_node;
                new_node.prev = null;
                new_node.next = null;
            }
        }
        pub inline fn remove(list: *Self, node: *Node) void {
            if (node.prev) |prev_node| {
                prev_node.next = node.next;
            } else {
                list.first = node.next;
            }
            if (node.next) |next_node| {
                next_node.prev = node.prev;
            } else {
                list.last = node.prev;
            }
        }
        pub inline fn pop(list: *Self) ?*Node {
            const last = list.last orelse return null;
            list.remove(last);
            return last;
        }
        pub inline fn popFirst(list: *Self) ?*Node {
            const first = list.first orelse return null;
            list.remove(first);
            return first;
        }
    };
}
test "basic DoublyLinkedList test" {
    const Node = struct {
        data: u32,
        prev: ?*@This() = null,
        next: ?*@This() = null,
    };
    const L = DoublyLinkedList(Node);
    var list: L = .{};
    var one: Node = .{ .data = 1 };
    var two: Node = .{ .data = 2 };
    var three: Node = .{ .data = 3 };
    var four: Node = .{ .data = 4 };
    var five: Node = .{ .data = 5 };
    list.append(&two); 
    list.append(&five); 
    list.prepend(&one); 
    list.insertBefore(&five, &four); 
    list.insertAfter(&two, &three); 
    {
        var it = list.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            try testing.expect(node.data == index);
            index += 1;
        }
    }
    {
        var it = list.last;
        var index: u32 = 1;
        while (it) |node| : (it = node.prev) {
            try testing.expect(node.data == (6 - index));
            index += 1;
        }
    }
    _ = list.popFirst(); 
    _ = list.pop(); 
    list.remove(&three); 
    try testing.expect(list.first.?.data == 2);
    try testing.expect(list.last.?.data == 4);
}
