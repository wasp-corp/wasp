/**
 * @file search.h
 *
 * Search terminal contents, including scrollback, for a string.
 */

#ifndef WASP_VT_SEARCH_H
#define WASP_VT_SEARCH_H

#include <stddef.h>
#include <wasp/vt/allocator.h>
#include <wasp/vt/selection.h>
#include <wasp/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup search Search
 *
 * Search a terminal for a string, covering the active area and
 * scrollback of both the primary and alternate screens.
 *
 * A WaspSearch searches the terminal it was created with for a
 * needle set with WASP_SEARCH_OPT_NEEDLE. It handles the hard
 * parts of terminal search internally: results stay in sync with the
 * live screens, survive primary/alternate screen switches (entering
 * and leaving a fullscreen app such as vim does not restart a
 * scrollback search), and recover from resize, reflow, resets, and
 * scrollback pruning.
 *
 * A search starts idle. Setting the needle starts the search,
 * changing it restarts the search from scratch, and clearing it
 * returns the search to idle. Matching is byte-exact except ASCII
 * letters, which compare case-insensitively.
 *
 * ## Driving a search
 *
 * Searching a large scrollback takes time, so the work is split into
 * small steps the caller drives so that the caller can control
 * performance more directly:
 *
 * - wasp_search_tick() makes a bounded amount of progress on data
 *   the search has already copied. It never touches the terminal, 
 *   meaning it can be safely called from a thread.
 * - wasp_search_feed() reads the terminal to copy in more data and
 *   pick up terminal changes. Feeding is the only way the search
 *   learns that the terminal changed, so keep feeding periodically
 *   while the search is in use. This requires exclusive terminal access.
 * - wasp_search_run() is a blocking convenience that feeds and
 *   ticks until the search is caught up.
 *
 * WASP_SEARCH_STATUS_COMPLETE means the search is caught up with
 * the terminal as of the last feed. It never means finished forever,
 * since later terminal writes require another feed to be seen.
 *
 * ## Matches are selections
 *
 * Every match is returned as a WaspSelection snapshot with
 * rectangle set to false, so the existing selection APIs all work on
 * matches: wasp_terminal_selection_format_buf() to copy the
 * matched text, wasp_terminal_point_from_grid_ref() with
 * WASP_POINT_TAG_VIEWPORT to position highlight rectangles,
 * wasp_terminal_selection_contains() for hit testing, and
 * wasp_terminal_set() with WASP_TERMINAL_OPT_SELECTION to make
 * a match the terminal's selection.
 *
 * Returned matches follow the usual snapshot lifetime rules: they are
 * only valid until the next operation that modifies the terminal,
 * including wasp_terminal_vt_write(), resize, reset, and free.
 * Read matches after a feed, use them before the terminal changes
 * again, and re-read them rather than caching them. The selected
 * match is kept accurate internally across terminal changes, so the
 * safe way to follow a match is to re-read
 * WASP_SEARCH_DATA_SELECTED_MATCH after each feed.
 *
 * ## Lifetime
 *
 * The search borrows the terminal it was created with and never frees
 * it. Any number of searches, alongside other terminal readers such
 * as formatters and render states, may share one terminal.
 *
 * The search and its terminal can be freed in either order. Freeing
 * the search first releases tracked state it holds within the
 * terminal. If the terminal is freed first, the search detects this:
 * calls that need the terminal, and wasp_search_tick(), return
 * WASP_INVALID_VALUE, reads
 * return whatever the search last saw, and wasp_search_free()
 * releases only search-owned memory. A search cannot be rebound, so
 * searching another terminal means creating a new search.
 *
 * ## Threading
 *
 * The library creates no threads. Calls on one WaspSearch are not
 * safe to make concurrently with each other, so the caller must
 * serialize them.
 *
 * Functions that touch the terminal (wasp_search_new(),
 * wasp_search_feed(), wasp_search_run(), wasp_search_set()
 * with the needle and select options, and wasp_search_free()) must
 * also be serialized with all other access to the same terminal.
 *
 * Everything else (wasp_search_tick(), wasp_search_get(), and
 * wasp_search_get_multi()) only touches memory owned by the search
 * and is safe to call while another thread modifies the terminal.
 * This split is how Wasp runs search on a background thread: tick
 * freely, and take the terminal lock only to feed. Reading returned
 * match values is always safe, but passing them to APIs that take the
 * terminal follows the terminal serialization rule above.
 *
 * ## Example
 *
 * @snippet c-vt-search/src/main.c search-main
 *
 * @{
 */

/**
 * Progress state of a search.
 *
 * @ingroup search
 */
typedef enum WASP_ENUM_TYPED {
  /**
   * wasp_search_tick() can make progress without terminal access.
   */
  WASP_SEARCH_STATUS_RUNNING = 0,

  /**
   * Blocked until wasp_search_feed(). This is also the state right
   * after a needle is set, since the search has not yet seen the
   * terminal.
   */
  WASP_SEARCH_STATUS_FEED_REQUIRED = 1,

  /**
   * Caught up with the terminal state as of the last feed. This never
   * means finished forever, since later terminal writes require
   * another feed to be seen. A search with no needle set also reports
   * complete, since there is nothing to look for.
   */
  WASP_SEARCH_STATUS_COMPLETE = 2,

  WASP_SEARCH_STATUS_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSearchStatus;

/**
 * Scroll policy applied when a match becomes selected via
 * WASP_SEARCH_OPT_SELECT_NEXT or WASP_SEARCH_OPT_SELECT_PREV.
 *
 * @ingroup search
 */
typedef enum WASP_ENUM_TYPED {
  /** Scroll the viewport so the match is visible, only if it is not
   * already visible. This is the default. */
  WASP_SEARCH_SCROLL_IF_NEEDED = 0,

  /** Never scroll the viewport. */
  WASP_SEARCH_SCROLL_NONE = 1,

  WASP_SEARCH_SCROLL_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSearchScroll;

/**
 * Data fields readable with wasp_search_get(). The output value
 * type is documented per field.
 *
 * All reads reflect the terminal's active screen as of the last feed.
 * When the running application switches to the alternate screen, the
 * next feed switches counts, matches, and selection to that screen's
 * results. Primary screen results, including completed scrollback
 * searches, are retained and restored on the way back.
 *
 * @ingroup search
 */
typedef enum WASP_ENUM_TYPED {
  /** Current search status: WaspSearchStatus*. */
  WASP_SEARCH_DATA_STATUS = 0,

  /**
   * The needle this search is looking for: WaspString*. The bytes
   * are borrowed from the search and remain valid until the needle is
   * changed or the search is freed. Returns WASP_NO_VALUE when no
   * needle is set.
   */
  WASP_SEARCH_DATA_NEEDLE = 1,

  /**
   * Total matches found so far on the active screen: size_t*. Zero
   * until the first feed.
   */
  WASP_SEARCH_DATA_TOTAL_MATCHES = 2,

  /**
   * Index of the selected match: size_t*. This indexes the newest to
   * oldest ordering of WASP_SEARCH_DATA_MATCHES, where 0 is the
   * newest match, so a "k of n" find bar renders index + 1 of
   * WASP_SEARCH_DATA_TOTAL_MATCHES. Returns WASP_NO_VALUE when
   * nothing is selected.
   */
  WASP_SEARCH_DATA_SELECTED_INDEX = 3,

  /**
   * The selected match: WaspSelection*. This is an untracked
   * snapshot with standard WaspSelection lifetime rules. Returns
   * WASP_NO_VALUE when nothing is selected.
   */
  WASP_SEARCH_DATA_SELECTED_MATCH = 4,

  /**
   * All matches on the active screen, ordered newest to oldest, from
   * the bottom of the active area up through scrollback:
   * WaspSelectionBuffer*. Set ptr to NULL with cap 0 to query the
   * required capacity. An undersized buffer returns
   * WASP_OUT_OF_SPACE with the required capacity in len.
   */
  WASP_SEARCH_DATA_MATCHES = 5,

  /**
   * Matches on the pages covering the viewport, for drawing highlight
   * rectangles: WaspSelectionBuffer*. The list is computed during
   * feeds and cached, so it reflects the viewport as of the last
   * feed.
   *
   * Matches are found a page at a time, so the list can include
   * matches slightly outside the visible viewport when they share a
   * page with it. Wasp's own renderer behaves the same way.
   * Converting each match to viewport coordinates with
   * wasp_terminal_point_from_grid_ref() clips this naturally: skip
   * matches that fail the conversion or whose row is beyond the
   * visible row count.
   */
  WASP_SEARCH_DATA_VIEWPORT_MATCHES = 6,

  /** Current scroll policy: WaspSearchScroll*. */
  WASP_SEARCH_DATA_SELECT_SCROLL = 7,

  WASP_SEARCH_DATA_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSearchData;

/**
 * Options writable with wasp_search_set(). The value type, and
 * what a NULL value means, is documented per option.
 *
 * @ingroup search
 */
typedef enum WASP_ENUM_TYPED {
  /**
   * Set the needle to search for: const WaspString*. The bytes are
   * copied, so the caller's memory does not need to outlive the call.
   * Matching is byte-exact except ASCII letters, which compare
   * case-insensitively.
   *
   * Changing the needle restarts the search from scratch and drops
   * all results. As an exception, setting a needle equal to the current
   * one (compared the same way as matching) keeps existing results,
   * so find bars can resubmit freely. A NULL or empty value clears
   * the needle and returns the search to idle.
   *
   * Replacing or clearing a needle releases tracked state held
   * within the terminal, so the caller must serialize this with all
   * other access to the same terminal. Returns WASP_INVALID_VALUE
   * after the terminal was freed.
   */
  WASP_SEARCH_OPT_NEEDLE = 0,

  /**
   * Select the next match, moving toward older content: from the
   * bottom of the screen upward into history, the direction a search
   * from the prompt usually wants. Wraps around past the oldest
   * match.
   *
   * The value must be NULL. It is reserved for future use.
   *
   * This catches up with the terminal first, so it is safe to call at
   * any time relative to feeds. The viewport scrolls to the newly
   * selected match according to WASP_SEARCH_OPT_SELECT_SCROLL.
   * This reads the terminal, so the caller must serialize it with all
   * other access to the same terminal. Returns WASP_NO_VALUE when
   * there are no matches.
   */
  WASP_SEARCH_OPT_SELECT_NEXT = 1,

  /**
   * Select the previous match, moving toward newer content, wrapping
   * around past the newest match. Otherwise identical to
   * WASP_SEARCH_OPT_SELECT_NEXT.
   */
  WASP_SEARCH_OPT_SELECT_PREV = 2,

  /**
   * Set the scroll policy applied by the select options: const
   * WaspSearchScroll*. The policy persists until changed. A NULL
   * value resets it to WASP_SEARCH_SCROLL_IF_NEEDED. This only
   * modifies search-owned state and never reads the terminal.
   */
  WASP_SEARCH_OPT_SELECT_SCROLL = 3,

  WASP_SEARCH_OPT_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSearchOption;

/**
 * Create a search bound to a terminal.
 *
 * The search borrows the terminal and never frees it. The search and
 * the terminal can be freed in either order; see wasp_search_free().
 *
 * The search starts idle with no needle: it reports
 * WASP_SEARCH_STATUS_COMPLETE and finds nothing. Set
 * WASP_SEARCH_OPT_NEEDLE to start searching.
 *
 * Creation is cheap and does not read terminal contents, but it
 * registers the search with the terminal so the two can be freed in
 * any order. The caller must serialize this call with all other
 * access to the same terminal.
 *
 * @param allocator Allocator, or NULL for the default allocator
 * @param out_search Receives the created search handle
 * @param terminal Terminal to bind the search to
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if
 *         out_search or terminal is invalid, or WASP_OUT_OF_MEMORY
 *         if allocation fails
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_new(
                                    const WaspAllocator* allocator,
                                    WaspSearch* out_search,
                                    WaspTerminal terminal);

/**
 * Free a search.
 *
 * If the bound terminal is still alive, this releases tracked state
 * the search holds within it, so the caller must serialize this call
 * with all other access to the same terminal. If the terminal was
 * already freed, the search has been detached and this releases only
 * search-owned memory. Passing NULL is allowed and is a no-op.
 *
 * @param search Search handle to free
 *
 * @ingroup search
 */
WASP_API void wasp_search_free(WaspSearch search);

/**
 * Make a bounded amount of search progress.
 *
 * This only works on data the search has already copied and never
 * reads the terminal, so it is safe to call while another thread
 * modifies the terminal. Call it in a loop while the status is
 * WASP_SEARCH_STATUS_RUNNING. When the status becomes
 * WASP_SEARCH_STATUS_FEED_REQUIRED, call wasp_search_feed() to
 * unblock it.
 *
 * @param search Search handle (NULL returns WASP_INVALID_VALUE)
 * @param[out] out_status Receives the status after the tick (may be NULL)
 * @return WASP_SUCCESS on success, or WASP_INVALID_VALUE if
 *         search is NULL or the terminal was freed
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_tick(
                                    WaspSearch search,
                                    WaspSearchStatus* out_status);

/**
 * Read the terminal to update the search.
 *
 * Each feed catches the search up with the terminal: it reconciles
 * the tracked screens against the live ones, re-scans the active
 * area, refreshes the viewport match list, gives the scrollback
 * searcher its next chunk of data, and prunes results that scrollback
 * eviction invalidated. Feeding is also the only way the search
 * learns about terminal changes, so keep feeding periodically while
 * the search is in use, even after it reports complete.
 *
 * This reads the terminal, so the caller must serialize it with all
 * other access to the same terminal. Each call does a bounded amount
 * of work so that any caller-held terminal lock is held only briefly.
 *
 * @param search Search handle (NULL returns WASP_INVALID_VALUE)
 * @return WASP_SUCCESS on success, or WASP_INVALID_VALUE if
 *         search is NULL or the terminal was freed
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_feed(WaspSearch search);

/**
 * Feed and tick until the search is caught up with the terminal.
 *
 * This is a blocking convenience for one-shot and single-threaded
 * embedders. It always performs at least one feed, so it also picks
 * up any terminal changes since the last feed, then loops until the
 * status is WASP_SEARCH_STATUS_COMPLETE. Searching a large
 * scrollback can take a while, so interactive embedders should drive
 * wasp_search_tick() and wasp_search_feed() themselves.
 *
 * This reads the terminal for the entire call, so the caller must
 * serialize it with all other access to the same terminal.
 *
 * @param search Search handle (NULL returns WASP_INVALID_VALUE)
 * @return WASP_SUCCESS on success, or WASP_INVALID_VALUE if
 *         search is NULL or the terminal was freed
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_run(WaspSearch search);

/**
 * Write an option to a search.
 *
 * The value type, and what a NULL value means, depends on the option
 * and is documented by WaspSearchOption. The needle and select
 * options touch the terminal, so the caller must serialize those
 * calls with all other access to the same terminal.
 * WASP_SEARCH_OPT_SELECT_SCROLL only modifies search-owned state.
 *
 * @param search Search handle (NULL returns WASP_INVALID_VALUE)
 * @param option Option to write
 * @param value Pointer to the input value for the option. The meaning
 *              of NULL is documented per option.
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if a select
 *         option found no matches, WASP_OUT_OF_MEMORY if
 *         allocation fails, or WASP_INVALID_VALUE if search,
 *         option, or value is invalid or the option needs a terminal
 *         that was already freed
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_set(
                                    WaspSearch search,
                                    WaspSearchOption option,
                                    const void* value);

/**
 * Read a data field from a search.
 *
 * The output value type depends on data and is documented by
 * WaspSearchData. This never reads the terminal, so it is safe to
 * call while another thread modifies the terminal. Returned
 * selections are untracked snapshots with standard WaspSelection
 * lifetime rules.
 *
 * @param search Search handle (NULL returns WASP_INVALID_VALUE)
 * @param data Data field to read
 * @param value Output pointer whose type depends on data
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if the
 *         requested data has no value, WASP_OUT_OF_SPACE if a
 *         provided WaspSelectionBuffer is too small (required
 *         capacity in its len), WASP_OUT_OF_MEMORY if collecting
 *         viewport matches fails, or WASP_INVALID_VALUE if search,
 *         data, or value is invalid
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_get(
                                    WaspSearch search,
                                    WaspSearchData data,
                                    void* value);

/**
 * Read multiple data fields from a search in a single call.
 *
 * This is an optimization over calling wasp_search_get() multiple
 * times. Each entry in values must point to storage of the type
 * documented by the corresponding WaspSearchData key.
 *
 * If any individual read fails, the function returns that error and
 * writes the index of the failing key to out_written when out_written
 * is non-NULL. Earlier keys have already been written. On success,
 * out_written receives count when non-NULL. A too-small
 * WaspSelectionBuffer stops the batch with WASP_OUT_OF_SPACE at
 * that key's index with the required capacity in its len, so order
 * buffer-valued keys after scalar keys.
 *
 * @param search Search handle (NULL returns WASP_INVALID_VALUE)
 * @param count Number of data fields to read
 * @param keys Data fields to read (must not be NULL)
 * @param values Output pointers corresponding to keys (must not be NULL)
 * @param out_written Optional number of fields read, or failing index
 *                    on error
 * @return WASP_SUCCESS on success, or the first failing read's
 *         result
 *
 * @ingroup search
 */
WASP_API WaspResult wasp_search_get_multi(
                                    WaspSearch search,
                                    size_t count,
                                    const WaspSearchData* keys,
                                    void** values,
                                    size_t* out_written);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* WASP_VT_SEARCH_H */
