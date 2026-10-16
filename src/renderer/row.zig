const terminal = @import("../terminal/main.zig");
pub fn neverExtendBg(
    row: terminal.page.Row,
    cells: []const terminal.page.Cell,
    styles: []const terminal.Style,
    palette: *const terminal.color.Palette,
    default_background: terminal.color.RGB,
) bool {
    switch (row.semantic_prompt) {
        .prompt, .prompt_continuation => return true,
        .none => {},
    }
    for (0.., cells) |x, *cell| {
        switch (cell.content_tag) {
            .bg_color_palette, .bg_color_rgb => {
                const s: terminal.Style = if (cell.hasStyling()) styles[x] else .{};
                const bg = s.bg(cell, palette) orelse return true;
                if (bg.eql(default_background)) return true;
            },
            .codepoint, .codepoint_grapheme => {
                switch (cell.codepoint()) {
                    0xE0B0...0xE0C8,
                    0xE0CA,
                    0xE0CC...0xE0D2,
                    0xE0D4,
                    => return true,
                    else => {},
                }
                const s: terminal.Style = if (cell.hasStyling()) styles[x] else .{};
                const bg = s.bg(cell, palette) orelse return true;
                if (bg.eql(default_background)) return true;
            },
        }
    }
    return false;
}
