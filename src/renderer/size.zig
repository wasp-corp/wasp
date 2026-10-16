const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal_size = @import("../terminal/size.zig");
const log = std.log.scoped(.renderer_size);
pub const PaddingBalance = enum {
    false,
    true,
    equal,
};
pub const Size = struct {
    screen: ScreenSize,
    cell: CellSize,
    padding: Padding,
    pub fn grid(self: Size) GridSize {
        return .init(self.screen.subPadding(self.padding), self.cell);
    }
    pub fn terminal(self: Size) ScreenSize {
        return self.screen.subPadding(self.padding);
    }
    pub fn balancePadding(
        self: *Size,
        explicit: Padding,
        mode: PaddingBalance,
    ) void {
        self.padding = explicit;
        self.padding = .balanced(
            self.screen,
            self.grid(),
            self.cell,
        );
        switch (mode) {
            .false => unreachable,
            .equal => {},
            .true => {
                const max_top = (explicit.left + explicit.right + self.cell.width) / 2;
                const vshift = self.padding.top -| max_top;
                self.padding.top -= vshift;
                self.padding.bottom += vshift;
            },
        }
    }
};
pub const Coordinate = union(enum) {
    surface: Surface,
    terminal: Terminal,
    grid: Grid,
    pub const Tag = @typeInfo(Coordinate).@"union".tag_type.?;
    pub const Surface = struct { x: f64, y: f64 };
    pub const Terminal = struct { x: f64, y: f64 };
    pub const Grid = struct { x: GridSize.Unit, y: GridSize.Unit };
    pub fn convert(self: Coordinate, to: Tag, size: Size) Coordinate {
        if (@as(Tag, self) == to) return self;
        const surface = self.convertToSurface(size);
        return switch (to) {
            .surface => .{ .surface = surface },
            .terminal => .{ .terminal = .{
                .x = surface.x - @as(f64, @floatFromInt(size.padding.left)),
                .y = surface.y - @as(f64, @floatFromInt(size.padding.top)),
            } },
            .grid => grid: {
                const term = (Coordinate{ .surface = surface }).convert(
                    .terminal,
                    size,
                ).terminal;
                const grid = size.grid();
                const cell_width: f64 = @as(f64, @floatFromInt(size.cell.width));
                const cell_height: f64 = @as(f64, @floatFromInt(size.cell.height));
                const clamped_x: f64 = @max(0, term.x);
                const clamped_y: f64 = @max(0, term.y);
                const col: GridSize.Unit = @intFromFloat(clamped_x / cell_width);
                const row: GridSize.Unit = @intFromFloat(clamped_y / cell_height);
                const clamped_col: GridSize.Unit = @min(col, grid.columns - 1);
                const clamped_row: GridSize.Unit = @min(row, grid.rows - 1);
                break :grid .{ .grid = .{ .x = clamped_col, .y = clamped_row } };
            },
        };
    }
    fn convertToSurface(self: Coordinate, size: Size) Surface {
        return switch (self) {
            .surface => |v| v,
            .terminal => |v| .{
                .x = v.x + @as(f64, @floatFromInt(size.padding.left)),
                .y = v.y + @as(f64, @floatFromInt(size.padding.top)),
            },
            .grid => |v| grid: {
                const col: f64 = @floatFromInt(v.x);
                const row: f64 = @floatFromInt(v.y);
                const cell_width: f64 = @floatFromInt(size.cell.width);
                const cell_height: f64 = @floatFromInt(size.cell.height);
                const padding_left: f64 = @floatFromInt(size.padding.left);
                const padding_top: f64 = @floatFromInt(size.padding.top);
                break :grid .{
                    .x = col * cell_width + padding_left,
                    .y = row * cell_height + padding_top,
                };
            },
        };
    }
};
pub const CellSize = extern struct {
    width: u32,
    height: u32,
};
pub const ScreenSize = extern struct {
    width: u32,
    height: u32,
    pub fn subPadding(self: ScreenSize, padding: Padding) ScreenSize {
        return .{
            .width = self.width -| (padding.left + padding.right),
            .height = self.height -| (padding.top + padding.bottom),
        };
    }
    pub fn blankPadding(self: ScreenSize, padding: Padding, grid: GridSize, cell: CellSize) Padding {
        const grid_width = grid.columns * cell.width;
        const grid_height = grid.rows * cell.height;
        const padded_width = grid_width + (padding.left + padding.right);
        const padded_height = grid_height + (padding.top + padding.bottom);
        const leftover_width = self.width -| padded_width;
        const leftover_height = self.height -| padded_height;
        return .{
            .top = 0,
            .bottom = leftover_height,
            .right = leftover_width,
            .left = 0,
        };
    }
    pub fn equals(self: ScreenSize, other: ScreenSize) bool {
        return self.width == other.width and self.height == other.height;
    }
};
pub const GridSize = extern struct {
    pub const Unit = terminal_size.CellCountInt;
    columns: Unit = 0,
    rows: Unit = 0,
    pub fn init(screen: ScreenSize, cell: CellSize) GridSize {
        var result: GridSize = undefined;
        result.update(screen, cell);
        return result;
    }
    pub fn update(self: *GridSize, screen: ScreenSize, cell: CellSize) void {
        const cell_width: f32 = @floatFromInt(cell.width);
        const cell_height: f32 = @floatFromInt(cell.height);
        const screen_width: f32 = @floatFromInt(screen.width);
        const screen_height: f32 = @floatFromInt(screen.height);
        const calc_cols: Unit = @intFromFloat(screen_width / cell_width);
        const calc_rows: Unit = @intFromFloat(screen_height / cell_height);
        self.columns = @max(1, calc_cols);
        self.rows = @max(1, calc_rows);
    }
    pub fn equals(self: GridSize, other: GridSize) bool {
        return self.columns == other.columns and self.rows == other.rows;
    }
};
pub const Padding = extern struct {
    top: u32 = 0,
    bottom: u32 = 0,
    right: u32 = 0,
    left: u32 = 0,
    pub fn balanced(screen: ScreenSize, grid: GridSize, cell: CellSize) Padding {
        const cell_width: f32 = @floatFromInt(cell.width);
        const cell_height: f32 = @floatFromInt(cell.height);
        const grid_width = @as(f32, @floatFromInt(grid.columns)) * cell_width;
        const grid_height = @as(f32, @floatFromInt(grid.rows)) * cell_height;
        const space_right = @as(f32, @floatFromInt(screen.width)) - grid_width;
        const space_bot = @as(f32, @floatFromInt(screen.height)) - grid_height;
        const padding_right = @floor(space_right / 2);
        const padding_left = padding_right;
        const padding_bot = @floor(space_bot / 2);
        const padding_top = padding_bot;
        const zero = @as(f32, 0);
        return .{
            .top = @intFromFloat(@max(zero, padding_top)),
            .bottom = @intFromFloat(@max(zero, padding_bot)),
            .right = @intFromFloat(@max(zero, padding_right)),
            .left = @intFromFloat(@max(zero, padding_left)),
        };
    }
    pub fn add(self: Padding, other: Padding) Padding {
        return .{
            .top = self.top + other.top,
            .bottom = self.bottom + other.bottom,
            .right = self.right + other.right,
            .left = self.left + other.left,
        };
    }
    pub fn eql(self: Padding, other: Padding) bool {
        return self.top == other.top and
            self.bottom == other.bottom and
            self.right == other.right and
            self.left == other.left;
    }
};
test "Size.balancePadding equal distributes whitespace equally" {
    const testing = std.testing;
    var size: Size = .{
        .screen = .{ .width = 1050, .height = 850 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    size.balancePadding(.{ .top = 4, .bottom = 4, .left = 4, .right = 4 }, .equal);
    try testing.expectEqual(size.padding.left, size.padding.right);
    try testing.expectEqual(size.padding.top, size.padding.bottom);
    try testing.expect(size.padding.top > 0);
}
test "Size.balancePadding true shifts excess top to bottom" {
    const testing = std.testing;
    var size: Size = .{
        .screen = .{ .width = 1090, .height = 1070 },
        .cell = .{ .width = 20, .height = 40 },
        .padding = .{},
    };
    size.balancePadding(.{}, .true);
    try testing.expectEqual(size.padding.left, size.padding.right);
    try testing.expect(size.padding.top < size.padding.bottom);
    try testing.expectEqual(@as(u32, 10), size.padding.top);
    try testing.expectEqual(@as(u32, 20), size.padding.bottom);
}
test "Padding balanced on zero" {
    const testing = std.testing;
    const grid: GridSize = .{ .columns = 100, .rows = 37 };
    const cell: CellSize = .{ .width = 10, .height = 20 };
    const screen: ScreenSize = .{ .width = 0, .height = 0 };
    const padding = Padding.balanced(screen, grid, cell);
    try testing.expectEqual(Padding{}, padding);
}
test "GridSize update exact" {
    const testing = std.testing;
    var grid: GridSize = .{};
    grid.update(.{
        .width = 100,
        .height = 40,
    }, .{
        .width = 5,
        .height = 10,
    });
    try testing.expectEqual(@as(GridSize.Unit, 20), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 4), grid.rows);
}
test "GridSize update rounding" {
    const testing = std.testing;
    var grid: GridSize = .{};
    grid.update(.{
        .width = 20,
        .height = 40,
    }, .{
        .width = 6,
        .height = 15,
    });
    try testing.expectEqual(@as(GridSize.Unit, 3), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 2), grid.rows);
}
test "coordinate conversion" {
    const testing = std.testing;
    const test_size: Size = .{
        .screen = .{
            .width = 100,
            .height = 100,
        },
        .cell = .{
            .width = 5,
            .height = 10,
        },
        .padding = .{},
    };
    const table: []const [2]Coordinate = &.{
        .{
            .{ .grid = .{ .x = 0, .y = 0 } },
            .{ .surface = .{ .x = 0, .y = 0 } },
        },
        .{
            .{ .grid = .{ .x = 1, .y = 0 } },
            .{ .surface = .{ .x = 6, .y = 0 } },
        },
        .{
            .{ .grid = .{ .x = 1, .y = 1 } },
            .{ .surface = .{ .x = 6, .y = 10 } },
        },
        .{
            .{ .grid = .{ .x = 0, .y = 0 } },
            .{ .surface = .{ .x = -10, .y = -10 } },
        },
        .{
            .{ .grid = .{ .x = test_size.grid().columns - 1, .y = test_size.grid().rows - 1 } },
            .{ .surface = .{ .x = 100_000, .y = 100_000 } },
        },
    };
    for (table) |pair| {
        const expected = pair[0];
        const actual = pair[1].convert(@as(Coordinate.Tag, expected), test_size);
        try testing.expectEqual(expected, actual);
    }
}
