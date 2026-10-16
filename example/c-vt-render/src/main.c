#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

/// Helper: resolve a style color to an RGB value using the palette.
static WaspColorRgb resolve_color(WaspStyleColor color,
                                     const WaspRenderStateColors* colors,
                                     WaspColorRgb fallback) {
  switch (color.tag) {
    case WASP_STYLE_COLOR_RGB:
      return color.value.rgb;
    case WASP_STYLE_COLOR_PALETTE:
      return colors->palette[color.value.palette];
    default:
      return fallback;
  }
}

int main(void) {
  WaspResult result;

  //! [render-state-update]
  // Create a terminal and render state, then update the render state
  // from the terminal. The render state captures a snapshot of everything
  // needed to draw a frame.
  WaspTerminal terminal = NULL;
  result = wasp_terminal_new(NULL, &terminal, 40, 5);
  assert(result == WASP_SUCCESS);

  WaspRenderState render_state = NULL;
  result = wasp_render_state_new(NULL, &render_state);
  assert(result == WASP_SUCCESS);

  // Feed some styled content into the terminal.
  const char* content =
      "Hello, \033[1;32mworld\033[0m!\r\n"     // bold green "world"
      "\033[4munderlined\033[0m text\r\n"       // underlined text
      "\033[38;2;255;128;0morange\033[0m\r\n";  // 24-bit orange fg
  wasp_terminal_vt_write(
      terminal, (const uint8_t*)content, strlen(content));

  // Select "underlined" on the second row. Render state exposes this
  // later as a row-local selected cell range.
  WaspGridRef selection_start = WASP_INIT_SIZED(WaspGridRef);
  WaspPoint selection_start_pt = {
      .tag = WASP_POINT_TAG_ACTIVE,
      .value = { .coordinate = { .x = 0, .y = 1 } },
  };
  result = wasp_terminal_grid_ref(
      terminal, selection_start_pt, &selection_start);
  assert(result == WASP_SUCCESS);

  WaspGridRef selection_end = WASP_INIT_SIZED(WaspGridRef);
  WaspPoint selection_end_pt = {
      .tag = WASP_POINT_TAG_ACTIVE,
      .value = { .coordinate = { .x = 9, .y = 1 } },
  };
  result = wasp_terminal_grid_ref(terminal, selection_end_pt, &selection_end);
  assert(result == WASP_SUCCESS);

  WaspSelection selection = WASP_INIT_SIZED(WaspSelection);
  selection.start = selection_start;
  selection.end = selection_end;
  result = wasp_terminal_set(
      terminal, WASP_TERMINAL_OPT_SELECTION, &selection);
  assert(result == WASP_SUCCESS);

  result = wasp_render_state_update(render_state, terminal);
  assert(result == WASP_SUCCESS);
  //! [render-state-update]

  //! [render-dirty-check]
  // Check the global dirty state to decide how much work the renderer
  // needs to do. After rendering, reset it to false.
  WaspRenderStateDirty dirty;
  result = wasp_render_state_get(
      render_state, WASP_RENDER_STATE_DATA_DIRTY, &dirty);
  assert(result == WASP_SUCCESS);

  switch (dirty) {
    case WASP_RENDER_STATE_DIRTY_FALSE:
      printf("Frame is clean, nothing to draw.\n");
      break;
    case WASP_RENDER_STATE_DIRTY_PARTIAL:
      printf("Partial redraw needed.\n");
      break;
    case WASP_RENDER_STATE_DIRTY_FULL:
      printf("Full redraw needed.\n");
      break;
  }
  //! [render-dirty-check]

  //! [render-colors]
  // Retrieve colors (background, foreground, palette) from the render
  // state. These are needed to resolve palette-indexed cell colors.
  WaspRenderStateColors colors =
      WASP_INIT_SIZED(WaspRenderStateColors);
  result = wasp_render_state_get(
      render_state, WASP_RENDER_STATE_DATA_COLORS, &colors);
  assert(result == WASP_SUCCESS);

  printf("Background: #%02x%02x%02x\n",
         colors.background.r, colors.background.g, colors.background.b);
  printf("Foreground: #%02x%02x%02x\n",
         colors.foreground.r, colors.foreground.g, colors.foreground.b);
  //! [render-colors]

  //! [render-cursor]
  // Read all cursor state in one call.
  WaspRenderStateCursor cursor =
      WASP_INIT_SIZED(WaspRenderStateCursor);
  result = wasp_render_state_get(
      render_state, WASP_RENDER_STATE_DATA_CURSOR, &cursor);
  assert(result == WASP_SUCCESS);

  if (cursor.visible && cursor.viewport_has_value) {
    const char* style_name = "unknown";
    switch (cursor.visual_style) {
      case WASP_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
        style_name = "bar";
        break;
      case WASP_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
        style_name = "block";
        break;
      case WASP_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
        style_name = "underline";
        break;
      case WASP_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
        style_name = "hollow";
        break;
    }
    printf("Cursor at (%u, %u), style: %s\n",
           cursor.viewport_x, cursor.viewport_y, style_name);
  }
  //! [render-cursor]

  //! [render-row-iterate]
  // Iterate rows via the row iterator. For each dirty row, iterate its
  // cells, read codepoints/graphemes and styles, and emit ANSI-colored
  // output as a simple "renderer".
  WaspRenderStateRowIterator row_iter = NULL;
  result = wasp_render_state_row_iterator_new(NULL, &row_iter);
  assert(result == WASP_SUCCESS);

  result = wasp_render_state_get(
      render_state, WASP_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter);
  assert(result == WASP_SUCCESS);

  WaspRenderStateRowCells cells = NULL;
  result = wasp_render_state_row_cells_new(NULL, &cells);
  assert(result == WASP_SUCCESS);

  uint16_t row_y = 0;
  while (wasp_render_state_row_iterator_next_dirty(row_iter, &row_y)) {
    printf("Row %2u [dirty]: ", row_y);

    // Query the row-local selection range. Rows without a selection return
    // WASP_NO_VALUE; selected rows return inclusive start/end columns.
    WaspRenderStateRowSelection row_selection =
        WASP_INIT_SIZED(WaspRenderStateRowSelection);
    result = wasp_render_state_row_get(
        row_iter, WASP_RENDER_STATE_ROW_DATA_SELECTION, &row_selection);
    assert(result == WASP_SUCCESS || result == WASP_NO_VALUE);
    if (result == WASP_SUCCESS) {
      printf("selection=%u..%u ",
             row_selection.start_x, row_selection.end_x);
    }

    // Get cells for this row (reuses the same cells handle).
    result = wasp_render_state_row_get(
        row_iter, WASP_RENDER_STATE_ROW_DATA_CELLS, &cells);
    assert(result == WASP_SUCCESS);

    while (wasp_render_state_row_cells_next(cells)) {
      // Get the grapheme length; 0 means the cell is empty.
      uint32_t grapheme_len = 0;
      wasp_render_state_row_cells_get(
          cells, WASP_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
          &grapheme_len);

      if (grapheme_len == 0) {
        putchar(' ');
        continue;
      }

      // Read the style for this cell. Returns the default style for
      // cells that have no explicit styling.
      WaspStyle style = WASP_INIT_SIZED(WaspStyle);
      wasp_render_state_row_cells_get(
          cells, WASP_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

      // Resolve foreground color for this cell.
      WaspColorRgb fg =
          resolve_color(style.fg_color, &colors, colors.foreground);

      // Emit ANSI true-color escape for the foreground.
      printf("\033[38;2;%u;%u;%um", fg.r, fg.g, fg.b);
      if (style.bold) printf("\033[1m");
      if (style.underline) printf("\033[4m");

      // Read grapheme codepoints into a buffer and print them.
      // The buffer must be at least grapheme_len elements.
      uint32_t codepoints[16];
      uint32_t len = grapheme_len < 16 ? grapheme_len : 16;
      wasp_render_state_row_cells_get(
          cells, WASP_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
          codepoints);

      for (uint32_t i = 0; i < len; i++) {
        // Simple ASCII print; a real renderer would handle UTF-8.
        if (codepoints[i] < 128)
          putchar((char)codepoints[i]);
        else
          printf("U+%04X", codepoints[i]);
      }

      printf("\033[0m");  // Reset style after each cell.
    }

    printf("\n");
  }
  //! [render-row-iterate]

  //! [render-dirty-reset]
  // After successfully rendering the complete frame, clear both the global
  // and per-row dirty state in one call.
  result = wasp_render_state_clean(render_state);
  assert(result == WASP_SUCCESS);
  //! [render-dirty-reset]

  // Cleanup
  wasp_render_state_row_cells_free(cells);
  wasp_render_state_row_iterator_free(row_iter);
  wasp_render_state_free(render_state);
  wasp_terminal_free(terminal);
  return 0;
}
