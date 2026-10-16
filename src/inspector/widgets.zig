const cimgui = @import("dcimgui");
pub const page = @import("widgets/page.zig");
pub const pagelist = @import("widgets/pagelist.zig");
pub const key = @import("widgets/key.zig");
pub const renderer = @import("widgets/renderer.zig");
pub const screen = @import("widgets/screen.zig");
pub const style = @import("widgets/style.zig");
pub const surface = @import("widgets/surface.zig");
pub const terminal = @import("widgets/terminal.zig");
pub const termio = @import("widgets/termio.zig");
pub fn helpMarker(text: [:0]const u8) void {
    cimgui.c.ImGui_TextDisabled("(?)");
    if (!cimgui.c.ImGui_BeginItemTooltip()) return;
    defer cimgui.c.ImGui_EndTooltip();
    cimgui.c.ImGui_PushTextWrapPos(cimgui.c.ImGui_GetFontSize() * 35.0);
    defer cimgui.c.ImGui_PopTextWrapPos();
    cimgui.c.ImGui_TextUnformatted(text.ptr);
}
pub const DetachableHeader = struct {
    detached: bool = false,
    dock: bool = true,
    window_first: bool = true,
    pub fn windowEnd(self: *DetachableHeader) void {
        _ = self;
        cimgui.c.ImGui_End();
    }
    pub fn window(
        self: *DetachableHeader,
        label: [:0]const u8,
    ) ?bool {
        if (!self.detached) {
            self.window_first = true;
            return null;
        }
        if (self.window_first) dock: {
            self.window_first = false;
            if (!self.dock) break :dock;
            const dock_id = cimgui.c.ImGui_GetWindowDockID();
            if (dock_id == 0) break :dock;
            var dock_id_right: cimgui.c.ImGuiID = 0;
            var dock_id_left: cimgui.c.ImGuiID = 0;
            _ = cimgui.ImGui_DockBuilderSplitNode(
                dock_id,
                cimgui.c.ImGuiDir_Right,
                0.4,
                &dock_id_right,
                &dock_id_left,
            );
            cimgui.ImGui_DockBuilderDockWindow(label, dock_id_right);
            cimgui.ImGui_DockBuilderFinish(dock_id);
        }
        return cimgui.c.ImGui_Begin(
            label,
            &self.detached,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        );
    }
    pub fn header(
        self: *DetachableHeader,
        label: [:0]const u8,
    ) bool {
        if (self.detached) return false;
        cimgui.c.ImGui_PushID(label);
        defer cimgui.c.ImGui_PopID();
        cimgui.c.ImGui_SetNextItemAllowOverlap();
        const is_open = cimgui.c.ImGui_CollapsingHeader(
            label,
            cimgui.c.ImGuiTreeNodeFlags_None,
        );
        const header_max = cimgui.c.ImGui_GetItemRectMax();
        const header_min = cimgui.c.ImGui_GetItemRectMin();
        const frame_height = cimgui.c.ImGui_GetFrameHeight();
        const button_size = frame_height - 4;
        const padding = 4;
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_SetCursorScreenPos(.{
            .x = header_max.x - button_size - padding,
            .y = header_min.y + 2,
        });
        {
            cimgui.c.ImGui_PushStyleVarImVec2(
                cimgui.c.ImGuiStyleVar_FramePadding,
                .{ .x = 0, .y = 0 },
            );
            defer cimgui.c.ImGui_PopStyleVar();
            if (cimgui.c.ImGui_ButtonEx(
                ">>##detach",
                .{ .x = button_size, .y = button_size },
            )) {
                self.detached = true;
            }
        }
        if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
            cimgui.c.ImGui_SetTooltip("Detach into separate window");
        }
        return is_open;
    }
};
