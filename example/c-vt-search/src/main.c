#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [search-main]
int main() {
  // Create a terminal and fill it with some content to search.
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(NULL, &terminal, 80, 24);
  assert(result == WASP_SUCCESS);

  const char *lines[] = {
    "$ make test\r\n",
    "compiling module A... ok\r\n",
    "compiling module B... error: missing semicolon\r\n",
    "linking... error: undefined symbol\r\n",
    "$ grep -n ERROR build.log\r\n",
  };
  for (size_t i = 0; i < sizeof(lines) / sizeof(lines[0]); i++) {
    wasp_terminal_vt_write(terminal, (const uint8_t *)lines[i],
                              strlen(lines[i]));
  }

  // The user opened the find bar, so create a search bound to the
  // terminal. It starts idle until it has a needle.
  WaspSearch search;
  result = wasp_search_new(NULL, &search, terminal);
  assert(result == WASP_SUCCESS);

  // The user typed a query. Matching is byte-exact except ASCII
  // letters, which compare case-insensitively, so "error" also finds
  // "ERROR". Retyping just sets the needle again: a changed needle
  // restarts the search and an unchanged one keeps its results.
  WaspString needle = { (const uint8_t *)"error", 5 };
  result = wasp_search_set(search, WASP_SEARCH_OPT_NEEDLE, &needle);
  assert(result == WASP_SUCCESS);

  // Drive the search. Interactive embedders interleave
  // wasp_search_tick() and wasp_search_feed() with their event
  // loop, but for a one-shot search we can just run it to completion.
  result = wasp_search_run(search);
  assert(result == WASP_SUCCESS);

  // The total match count, for find bar text like "1 of 3".
  size_t total = 0;
  result = wasp_search_get(search, WASP_SEARCH_DATA_TOTAL_MATCHES,
                              &total);
  assert(result == WASP_SUCCESS);
  printf("%zu matches for \"error\"\n", total);

  // The user pressed Enter, so select the next match. Selection starts
  // at the newest match, moves toward older content, and wraps around.
  // This scrolls the viewport to the match if it isn't visible, per
  // the WASP_SEARCH_OPT_SELECT_SCROLL policy.
  while (true) {
    result = wasp_search_set(search, WASP_SEARCH_OPT_SELECT_NEXT, NULL);
    if (result != WASP_SUCCESS) break;

    // Read the selection state in one call. Index 0 is the newest
    // match, so a "k of n" find bar renders index + 1.
    size_t idx = 0;
    WaspSelection match = WASP_INIT_SIZED(WaspSelection);
    const WaspSearchData keys[] = {
      WASP_SEARCH_DATA_SELECTED_INDEX,
      WASP_SEARCH_DATA_SELECTED_MATCH,
    };
    void *values[] = { &idx, &match };
    result = wasp_search_get_multi(
        search, sizeof(keys) / sizeof(keys[0]), keys, values, NULL);
    assert(result == WASP_SUCCESS);
    printf("selected %zu of %zu\n", idx + 1, total);

    // Wrapped back around to the first match: stop.
    if (idx + 1 == total) break;
  }

  // Each frame while the find bar is open, feed to catch up with any
  // terminal changes and then read the viewport matches to draw
  // highlights. The list can include matches just past the viewport
  // when they share a page with it, so convert each endpoint to
  // viewport coordinates and skip matches outside the visible rows.
  result = wasp_search_feed(search);
  assert(result == WASP_SUCCESS);

  WaspSelection viewport_storage[64];
  WaspSelectionBuffer viewport = {
    .ptr = viewport_storage,
    .cap = sizeof(viewport_storage) / sizeof(viewport_storage[0]),
  };
  result = wasp_search_get(search, WASP_SEARCH_DATA_VIEWPORT_MATCHES,
                              &viewport);
  assert(result == WASP_SUCCESS);
  for (size_t i = 0; i < viewport.len; i++) {
    WaspPointCoordinate start, end;
    if (wasp_terminal_point_from_grid_ref(
            terminal, &viewport_storage[i].start, WASP_POINT_TAG_VIEWPORT,
            &start) != WASP_SUCCESS) continue;
    if (wasp_terminal_point_from_grid_ref(
            terminal, &viewport_storage[i].end, WASP_POINT_TAG_VIEWPORT,
            &end) != WASP_SUCCESS) continue;
    if (start.y >= 24 || end.y >= 24) continue;

    // A real embedder draws a highlight rect from start to end here.
    printf("highlight rows %u-%u, cols %u-%u\n",
           (unsigned)start.y, (unsigned)end.y,
           (unsigned)start.x, (unsigned)end.x);
  }

  // Closing the find bar. The search borrows the terminal, but the
  // two can be freed in either order.
  wasp_search_free(search);
  wasp_terminal_free(terminal);
  return 0;
}
//! [search-main]
