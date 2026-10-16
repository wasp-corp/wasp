#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [grid-ref-traverse]
int main() {
  // Create a small terminal
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(NULL, &terminal, 10, 3);
  assert(result == WASP_SUCCESS);

  // Write some content so the grid has interesting data
  const char *text = "Hello!\r\n"    // Row 0: H e l l o !
                     "World\r\n"     // Row 1: W o r l d
                     "\033[1mBold";   // Row 2: B o l d (bold style)
  wasp_terminal_vt_write(
      terminal, (const uint8_t *)text, strlen(text));

  // Get terminal dimensions
  uint16_t cols, rows;
  wasp_terminal_get(terminal, WASP_TERMINAL_DATA_COLS, &cols);
  wasp_terminal_get(terminal, WASP_TERMINAL_DATA_ROWS, &rows);

  // Traverse the entire grid using grid refs
  for (uint16_t row = 0; row < rows; row++) {
    printf("Row %u: ", row);
    for (uint16_t col = 0; col < cols; col++) {
      // Resolve the point to a grid reference
      WaspGridRef ref = WASP_INIT_SIZED(WaspGridRef);
      WaspPoint pt = {
        .tag = WASP_POINT_TAG_ACTIVE,
        .value = { .coordinate = { .x = col, .y = row } },
      };
      result = wasp_terminal_grid_ref(terminal, pt, &ref);
      assert(result == WASP_SUCCESS);

      // Read the cell from the grid ref
      WaspCell cell;
      result = wasp_grid_ref_cell(&ref, &cell);
      assert(result == WASP_SUCCESS);

      // Check if the cell has text
      bool has_text = false;
      wasp_cell_get(cell, WASP_CELL_DATA_HAS_TEXT, &has_text);

      if (has_text) {
        uint32_t codepoint = 0;
        wasp_cell_get(cell, WASP_CELL_DATA_CODEPOINT, &codepoint);
        printf("%c", (char)codepoint);
      } else {
        printf(".");
      }
    }

    // Also inspect the row for wrap state
    WaspGridRef ref = WASP_INIT_SIZED(WaspGridRef);
    WaspPoint pt = {
      .tag = WASP_POINT_TAG_ACTIVE,
      .value = { .coordinate = { .x = 0, .y = row } },
    };
    wasp_terminal_grid_ref(terminal, pt, &ref);

    WaspRow grid_row;
    wasp_grid_ref_row(&ref, &grid_row);

    bool wrap = false;
    wasp_row_get(grid_row, WASP_ROW_DATA_WRAP, &wrap);
    printf(" (wrap=%s", wrap ? "true" : "false");

    // Check the style of the first cell with text
    WaspStyle style = WASP_INIT_SIZED(WaspStyle);
    wasp_grid_ref_style(&ref, &style);
    printf(", bold=%s)\n", style.bold ? "true" : "false");
  }

  wasp_terminal_free(terminal);
  return 0;
}
//! [grid-ref-traverse]
