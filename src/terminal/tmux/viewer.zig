const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/root.zig").CircBuf;
const CursorStyle = @import("../cursor.zig").Style;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const log = std.log.scoped(.terminal_tmux_viewer);
const COMMAND_QUEUE_INITIAL = 8;
pub const Viewer = struct {
    io: std.Io,
    alloc: Allocator,
    state: State,
    session_id: usize,
    tmux_version: []const u8,
    command_queue: CommandQueue,
    windows: std.ArrayList(Window),
    panes: PanesMap,
    action_arena: ArenaAllocator.State,
    action_single: [1]Action,
    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, Pane);
    pub const Action = union(enum) {
        exit,
        command: []const u8,
        windows: []const Window,
        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
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
                            []const Window => try writer.print("[{d} windows]", .{value.len}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }
                try writer.writeAll(" }");
            }
        }
    };
    pub const Input = union(enum) {
        tmux: control.Notification,
    };
    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,
        pub fn deinit(self: *Window, alloc: Allocator) void {
            self.layout_arena.promote(alloc).deinit();
        }
    };
    pub const Pane = struct {
        terminal: Terminal,
        output_stream: ?*TerminalStream = null,
        fn outputStream(self: *Pane, alloc: Allocator) Allocator.Error!*TerminalStream {
            if (self.output_stream == null) {
                const stream = try alloc.create(TerminalStream);
                stream.* = self.terminal.vtStream();
                self.output_stream = stream;
            }
            const stream = self.output_stream.?;
            stream.handler.terminal = &self.terminal;
            return stream;
        }
        pub fn deinit(self: *Pane, alloc: Allocator) void {
            if (self.output_stream) |stream| {
                stream.handler.terminal = &self.terminal;
                stream.deinit();
                alloc.destroy(stream);
            }
            self.terminal.deinit(alloc);
        }
    };
    pub fn init(io: std.Io, alloc: Allocator) Allocator.Error!Viewer {
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);
        return .{
            .io = io,
            .alloc = alloc,
            .state = .startup_block,
            .session_id = 0,
            .tmux_version = "",
            .command_queue = command_queue,
            .windows = .empty,
            .panes = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }
    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
            self.panes.deinit(self.alloc);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.action_arena.promote(self.alloc).deinit();
    }
    pub fn next(self: *Viewer, input: Input) []const Action {
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
        };
    }
    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },
            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }
    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);
        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            .block_end, .block_err => {
                self.state = .startup_session;
                return &.{};
            },
            else => return &.{},
        }
    }
    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);
        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            .session_changed => |info| {
                self.session_id = info.id;
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);
                return self.enterCommandQueue(
                    arena.allocator(),
                    &.{ .tmux_version, .list_windows },
                ) catch {
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };
            },
            else => return &.{},
        }
    }
    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .idle);
        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            else => return &.{},
        }
    }
    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .command_queue);
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }
        var actions: std.ArrayList(Action) = .empty;
        var command_consumed = self.command_queue.empty();
        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            inline .block_end,
            .block_err,
            => |content, tag| {
                self.receivedCommandOutput(
                    &actions,
                    content,
                    tag == .block_err,
                ) catch {
                    log.warn("failed to process command output, becoming defunct", .{});
                    return self.defunct();
                };
                command_consumed = true;
            },
            .output => |out| self.receivedOutput(
                out.pane_id,
                out.data,
            ) catch |err| {
                log.warn(
                    "failed to process output for pane id={}: {}",
                    .{ out.pane_id, err },
                );
            },
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };
                command_consumed = true;
            },
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
            ) catch {
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },
            .window_pane_changed => {},
            .sessions_changed => {},
            .window_renamed => {},
            .client_detached,
            .client_session_changed,
            => {},
        }
        if (self.state == .command_queue and command_consumed) {
            if (self.command_queue.first()) |next_command| {
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();
                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
            }
        }
        return actions.items;
    }
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
    ) !void {
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };
        window.layout = layout: {
            var arena = window.layout_arena.promote(self.alloc);
            defer window.layout_arena = arena.state;
            _ = arena.reset(.retain_capacity);
            break :layout Layout.parseWithChecksum(
                arena.allocator(),
                layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return err;
            };
        };
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = self.windows.items });
        try self.syncLayouts(self.windows.items);
    }
    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id;
        try self.queueCommands(&.{.list_windows});
    }
    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        var panes: PanesMap = .empty;
        errdefer {
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.deinit(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.io,
            self.alloc,
            &self.panes,
            &panes,
            window.layout,
        );
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }
            break :removed removed;
        };
        defer removed.deinit(self.alloc);
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added = true;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });
            }
            if (added) try self.queueCommands(&.{.pane_state});
        }
        errdefer comptime unreachable;
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }
        {
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                var entry = entry_const;
                entry.value.deinit(self.alloc);
            };
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        var replacement: Viewer = try .init(self.io, self.alloc);
        errdefer replacement.deinit();
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);
        replacement.action_arena = arena.state;
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;
        self.session_id = session_id;
        assert(self.state == .command_queue);
    }
    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            log.info("unexpected block output err={}", .{is_err});
            return;
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();
        switch (command) {
            .user => {},
            .pane_state => try self.receivedPaneState(content),
            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),
            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
            ),
            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                content,
            ),
            .tmux_version => try self.receivedTmuxVersion(content),
        }
    }
    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;
        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch |err| {
            log.info("failed to parse tmux version: {s}", .{line});
            return err;
        };
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
    }
    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        const actions_len = actions.items.len;
        errdefer actions.shrinkRetainingCapacity(actions_len);
        var windows: std.ArrayList(Window) = .empty;
        defer windows.deinit(self.alloc);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch |err| {
                log.info("failed to parse list-windows line: {s}", .{line});
                return err;
            };
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const window_alloc = arena.allocator();
            const layout: Layout = Layout.parseWithChecksum(
                window_alloc,
                data.window_layout,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                return err;
            };
            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout_arena = arena.state,
                .layout = layout,
            });
        }
        try self.syncLayouts(windows.items);
        try actions.append(arena_alloc, .{ .windows = self.windows.items });
    }
    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse list-panes line: {s}", .{line});
                return err;
            };
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr;
            const t: *Terminal = &pane.terminal;
            const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;
            _ = try t.switchScreen(screen_key);
            if (t.screens.get(screen_key)) |screen| {
                cursor: {
                    const cursor_x = std.math.cast(
                        size.CellCountInt,
                        data.cursor_x,
                    ) orelse break :cursor;
                    const cursor_y = std.math.cast(
                        size.CellCountInt,
                        data.cursor_y,
                    ) orelse break :cursor;
                    if (cursor_x >= screen.pages.cols or
                        cursor_y >= screen.pages.rows) break :cursor;
                    screen.cursorAbsolute(cursor_x, cursor_y);
                }
                if (data.cursor_shape.len > 0) {
                    if (std.mem.eql(u8, data.cursor_shape, "block")) {
                        screen.cursor.cursor_style = .block;
                    } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                        screen.cursor.cursor_style = .underline;
                    } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                        screen.cursor.cursor_style = .bar;
                    }
                }
            }
            if (t.screens.get(.alternate)) |alt_screen| cursor: {
                const alt_x = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_x,
                ) orelse break :cursor;
                const alt_y = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_y,
                ) orelse break :cursor;
                if (alt_x >= alt_screen.pages.cols or
                    alt_y >= alt_screen.pages.rows) break :cursor;
                alt_screen.cursorAbsolute(alt_x, alt_y);
            }
            t.modes.set(.cursor_visible, data.cursor_flag);
            t.modes.set(.cursor_blinking, data.cursor_blinking);
            t.modes.set(.insert, data.insert_flag);
            t.modes.set(.wraparound, data.wrap_flag);
            t.modes.set(.keypad_keys, data.keypad_flag);
            t.modes.set(.cursor_keys, data.keypad_cursor_flag);
            t.modes.set(.origin, data.origin_flag);
            t.modes.set(.mouse_event_any, data.mouse_all_flag);
            t.modes.set(.mouse_event_button, data.mouse_button_flag);
            t.modes.set(.mouse_event_normal, data.mouse_standard_flag);
            t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
            t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);
            t.modes.set(.focus_event, data.focus_flag);
            t.modes.set(.bracketed_paste, data.bracketed_paste);
            scroll: {
                const scroll_top = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_upper,
                ) orelse break :scroll;
                const scroll_bottom = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_lower,
                ) orelse break :scroll;
                if (scroll_top >= scroll_bottom or
                    scroll_bottom >= t.rows) break :scroll;
                t.scrolling_region.top = scroll_top;
                t.scrolling_region.bottom = scroll_bottom;
            }
            t.tabstops.reset(0);
            if (data.pane_tabs.len > 0) {
                var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
                while (tabs_it.next()) |tab_str| {
                    const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                    const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                    if (col_cell >= t.cols) continue;
                    t.tabstops.set(col_cell);
                }
            }
        }
    }
    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        const screen: *Screen = t.screens.active;
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }
    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
    }
    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const stream = try pane.outputStream(self.alloc);
        stream.nextSlice(data);
    }
    fn initLayout(
        io: std.Io,
        gpa_alloc: Allocator,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        io,
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },
            .pane => |id| pane: {
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;
                    break :pane;
                }
                var t: Terminal = try .init(io, gpa_alloc, .{
                    .cols = @intCast(layout.width),
                    .rows = @intCast(layout.height),
                });
                errdefer t.deinit(gpa_alloc);
                gop.value_ptr.* = .{
                    .terminal = t,
                };
            },
        }
    }
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| self.command_queue.appendAssumeCapacity(cmd);
        self.state = .command_queue;
        return self.singleAction(action);
    }
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }
    fn singleAction(self: *Viewer, action: Action) []const Action {
        self.action_single[0] = action;
        return &self.action_single;
    }
    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;
        return self.singleAction(.exit);
    }
};
const State = enum {
    startup_block,
    startup_session,
    defunct,
    command_queue,
};
const Command = union(enum) {
    list_windows,
    pane_history: CapturePane,
    pane_visible: CapturePane,
    pane_state,
    tmux_version,
    user: []const u8,
    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };
    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            => {},
            .user => |v| alloc.free(v),
        };
    }
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),
            .pane_history => |cap| try writer.print(
                "capture-pane -p -e -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),
            .pane_visible => |cap| try writer.print(
                "capture-pane -p -e -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),
            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -F '{s}'\n",
                .{comptime Format.list_panes.comptimeFormat()},
            )),
            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),
            .user => |v| try writer.writeAll(v),
        }
    }
};
const Format = struct {
    vars: []const output.Variable,
    delim: u8,
    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            .mouse_all_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            .focus_flag,
            .bracketed_paste,
            .scroll_region_upper,
            .scroll_region_lower,
            .pane_tabs,
        },
    };
    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_width,
            .window_height,
            .window_layout,
        },
    };
    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};
const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,
    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }
        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }
        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}
test "immediate exit" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .exit },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}
test "session changed resets state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                    for (actions) |action| switch (action) {
                        .windows => |windows| {
                            try testing.expectEqual(v.windows.items.ptr, windows.ptr);
                            try testing.expectEqual(v.windows.items.len, windows.len);
                            try testing.expectEqual(@as(usize, 0), windows[0].id);
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedWindowsAction;
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    try testing.expectEqual(0, v.windows.items.len);
                    try testing.expectEqual(0, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2 @1 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "initial flow" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 83 44 b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                \\prompt %
                ,
            } },
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;42;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;1;0;0;1;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        try testing.expect(t.modes.get(.mouse_event_button));
                        try testing.expect(!t.modes.get(.mouse_event_normal));
                        try testing.expect(t.modes.get(.mouse_format_sgr));
                    }
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}
test "tmux output state unsplit CSI" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    var terminal: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    viewer.panes.put(testing.allocator, 42, .{
        .terminal = terminal,
    }) catch |err| {
        terminal.deinit(testing.allocator);
        return err;
    };
    try viewer.receivedOutput(42, "\x1b[32mX");
    const entry = viewer.panes.getEntry(42) orelse return error.ExpectedPane42;
    const screen = entry.value_ptr.terminal.screens.active;
    const text = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("X", text);
}
test "tmux output state split CSI" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    var terminal: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    viewer.panes.put(testing.allocator, 42, .{
        .terminal = terminal,
    }) catch |err| {
        terminal.deinit(testing.allocator);
        return err;
    };
    try viewer.receivedOutput(42, "\x1b[32");
    try viewer.receivedOutput(42, "mX");
    const entry = viewer.panes.getEntry(42) orelse return error.ExpectedPane42;
    const screen = entry.value_ptr.terminal.screens.active;
    const text = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("X", text);
}
test "pane state ignores out of bounds scroll region" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end = "$0 @0 80 24 b25d,80x24,0,0,0",
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end = "%0;0;5;1;;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;60000;",
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    try testing.expectEqual(5, t.screens.active.cursor.y);
                    try testing.expectEqual(0, t.scrolling_region.top);
                    try testing.expectEqual(t.rows - 1, t.scrolling_region.bottom);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x0b" ** 30,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    try testing.expectEqual(t.rows - 1, t.screens.active.cursor.y);
                }
            }).check,
        },
    });
}
test "tmux raw startup selects primary screen" {
    try testRawStartupScreen(false);
}
test "tmux raw startup selects alternate screen" {
    try testRawStartupScreen(true);
}
fn testRawStartupScreen(comptime alternate_on: bool) !void {
    var parser: control.Parser = .{ .buffer = .init(testing.allocator) };
    defer parser.deinit();
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    const input =
        "%begin 1 1 0\n" ++
        "%end 1 1 0\n" ++
        "%session-changed $42 main\n" ++
        "%begin 2 2 0\n" ++
        "3.5a\n" ++
        "%end 2 2 0\n" ++
        "%begin 3 3 0\n" ++
        "$42 @0 80 24 d962,80x24,0,0,42\n" ++
        "%end 3 3 0\n" ++
        "%begin 4 4 0\n" ++
        "%end 4 4 0\n" ++
        "%begin 5 5 0\n" ++
        "%end 5 5 0\n" ++
        "%begin 6 6 0\n" ++
        "%end 6 6 0\n" ++
        "%begin 7 7 0\n" ++
        "%end 7 7 0\n" ++
        "%begin 8 8 0\n" ++
        "%42;0;0;1;block;default;0;" ++
        (if (alternate_on) "1;0;0;" else "0;0;0;") ++
        "0;1;0;0;0;" ++
        "0;0;0;0;0;" ++
        "0;0;0;23;8,16,24,32,40,48,56,64,72\n" ++
        "%end 8 8 0\n" ++
        "%output %42 hello\n";
    const expected_commands = [_][]const u8{
        "display-message",
        "list-windows",
        "capture-pane -p -e -q -S - -E -1 -t %42\n",
        "capture-pane -p -e -q -t %42\n",
        "capture-pane -p -e -q -a -S - -E -1 -t %42\n",
        "capture-pane -p -e -q -a -t %42\n",
        "list-panes",
    };
    var command_index: usize = 0;
    for (input) |byte| {
        if (try parser.put(byte)) |notification| {
            const actions = viewer.next(.{ .tmux = notification });
            for (actions) |action| {
                switch (action) {
                    .command => |command| {
                        try testing.expect(command_index < expected_commands.len);
                        const expected = expected_commands[command_index];
                        try testing.expect(
                            std.mem.startsWith(
                                u8,
                                command,
                                expected,
                            ),
                        );
                        command_index += 1;
                    },
                    .windows => {},
                    .exit => {
                        return error.UnexpectedViewerExit;
                    },
                }
            }
        }
    }
    try testing.expectEqual(expected_commands.len, command_index);
    try testing.expectEqual(@as(usize, 42), viewer.session_id);
    try testing.expectEqualStrings("3.5a", viewer.tmux_version);
    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
    try testing.expectEqual(@as(usize, 1), viewer.panes.count());
    try testing.expect(viewer.panes.contains(42));
    try testing.expect(viewer.command_queue.empty());
    const entry = viewer.panes.getEntry(42) orelse
        return error.ExpectedPane42;
    const pane = entry.value_ptr;
    const expected_key: ScreenSet.Key =
        if (alternate_on) .alternate else .primary;
    try testing.expectEqual(
        expected_key,
        pane.terminal.screens.active_key,
    );
    const screen = pane.terminal.screens.active;
    const text = try screen.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello", text);
    const other_key: ScreenSet.Key =
        if (alternate_on) .primary else .alternate;
    const other_screen = pane.terminal.screens.get(other_key) orelse
        return error.ExpectedOtherScreen;
    const other_text = try other_screen.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(other_text);
    try testing.expectEqualStrings("", other_text);
}
