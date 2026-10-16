#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [grid-ref-tracked]
static uint32_t codepoint_at_tracked_ref(WaspTrackedGridRef tracked) {
  WaspGridRef snapshot = WASP_INIT_SIZED(WaspGridRef);
  WaspResult result = wasp_tracked_grid_ref_snapshot(tracked, &snapshot);
  assert(result == WASP_SUCCESS);

  WaspCell cell;
  result = wasp_grid_ref_cell(&snapshot, &cell);
  assert(result == WASP_SUCCESS);

  bool has_text = false;
  wasp_cell_get(cell, WASP_CELL_DATA_HAS_TEXT, &has_text);
  assert(has_text);

  uint32_t codepoint = 0;
  wasp_cell_get(cell, WASP_CELL_DATA_CODEPOINT, &codepoint);
  return codepoint;
}

int main() {
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(NULL, &terminal, 8, 3);
  assert(result == WASP_SUCCESS);

  const char *text = "alpha\r\n"
                     "bravo\r\n"
                     "charlie";
  wasp_terminal_vt_write(
      terminal, (const uint8_t *)text, strlen(text));

  WaspTrackedGridRef tracked = NULL;
  WaspPoint alpha = {
    .tag = WASP_POINT_TAG_ACTIVE,
    .value = { .coordinate = { .x = 0, .y = 0 } },
  };
  result = wasp_terminal_grid_ref_track(terminal, alpha, &tracked);
  assert(result == WASP_SUCCESS);

  // Writing another line scrolls the original "alpha" row into scrollback.
  // The tracked ref still follows the same cell.
  const char *more = "\r\ndelta";
  wasp_terminal_vt_write(
      terminal, (const uint8_t *)more, strlen(more));

  assert(wasp_tracked_grid_ref_has_value(tracked));
  printf("tracked codepoint after scroll: %c\n",
      (char)codepoint_at_tracked_ref(tracked));

  WaspPointCoordinate screen = {0};
  result = wasp_tracked_grid_ref_point(
      tracked, WASP_POINT_TAG_SCREEN, &screen);
  assert(result == WASP_SUCCESS);
  printf("tracked screen point: %u,%u\n", screen.x, screen.y);

  // Resetting the terminal discards the old grid contents. The tracked
  // handle remains valid, but no longer has a meaningful location.
  wasp_terminal_reset(terminal);
  assert(!wasp_tracked_grid_ref_has_value(tracked));

  WaspGridRef discarded = WASP_INIT_SIZED(WaspGridRef);
  result = wasp_tracked_grid_ref_snapshot(tracked, &discarded);
  assert(result == WASP_NO_VALUE);

  // The same handle can be moved to a new point after it loses its value.
  const char *replacement = "echo";
  wasp_terminal_vt_write(
      terminal, (const uint8_t *)replacement, strlen(replacement));

  WaspPoint echo = {
    .tag = WASP_POINT_TAG_ACTIVE,
    .value = { .coordinate = { .x = 0, .y = 0 } },
  };
  result = wasp_tracked_grid_ref_set(tracked, terminal, echo);
  assert(result == WASP_SUCCESS);
  assert(wasp_tracked_grid_ref_has_value(tracked));
  printf("tracked codepoint after reset/set: %c\n",
      (char)codepoint_at_tracked_ref(tracked));

  wasp_tracked_grid_ref_free(tracked);
  wasp_terminal_free(terminal);
  return 0;
}
//! [grid-ref-tracked]
