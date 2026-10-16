/**
 * @file selection.h
 *
 * Selection range type for specifying a region of terminal content.
 */

#ifndef WASP_VT_SELECTION_H
#define WASP_VT_SELECTION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wasp/vt/allocator.h>
#include <wasp/vt/grid_ref.h>
#include <wasp/vt/point.h>
#include <wasp/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup selection Selection
 *
 * A snapshot selection range defined by two grid references that identifies
 * a contiguous or rectangular region of terminal content.
 *
 * The start and end values are WaspGridRef values. They are therefore
 * untracked grid references and inherit the same lifetime rules: they are
 * only safe to use until the next mutating operation on the terminal that
 * produced them, including freeing the terminal. To keep a selection valid
 * across terminal mutations, callers must maintain tracked grid references
 * for the endpoints and reconstruct a WaspSelection from fresh snapshots
 * when needed.
 *
 * Selection gestures provide a reusable state machine for turning UI pointer
 * interactions into selection snapshots. A caller creates one
 * WaspSelectionGesture per active gesture stream, reuses typed
 * WaspSelectionGestureEvent objects for synthetic press, drag, release,
 * autoscroll tick, and deep-press events, and applies each event with
 * wasp_selection_gesture_event(). The returned WaspSelection is a
 * snapshot; the embedder decides whether to render it, format/copy it, or
 * install it as the terminal's active selection.
 *
 * ## Examples
 *
 * @snippet c-vt-selection/src/main.c selection-main
 * @snippet c-vt-selection-gesture/src/main.c selection-gesture-main
 *
 * @{
 */

/**
 * Opaque handle to state for interpreting terminal selection gestures.
 *
 * The gesture owns only the state required to interpret pointer events. Calls
 * that use a gesture are not concurrency-safe and must be serialized with
 * terminal mutations.
 *
 * @ingroup selection
 */
typedef struct WaspSelectionGestureImpl* WaspSelectionGesture;

/**
 * Opaque handle to reusable input data for selection gesture operations.
 *
 * Event options are set with wasp_selection_gesture_event_set(). Individual
 * gesture operations document which options are required or optional.
 *
 * @ingroup selection
 */
typedef struct WaspSelectionGestureEventImpl* WaspSelectionGestureEvent;

/**
 * A snapshot selection range defined by two grid references.
 *
 * Both endpoints are inclusive. The endpoints preserve selection direction
 * and may be reversed; callers must not assume that start is the top-left
 * endpoint or that end is the bottom-right endpoint.
 *
 * When rectangle is false, the endpoints describe a linear selection. When
 * rectangle is true, the same endpoints are interpreted as opposite corners
 * of a rectangular/block selection.
 *
 * The start and end values are untracked WaspGridRef snapshots and are
 * only valid until the next mutating operation on the terminal that produced
 * them unless the selection is reconstructed from tracked references.
 *
 * This is a sized struct. Use WASP_INIT_SIZED() to initialize it.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(WaspSelection). */
  size_t size;

  /**
   * Start of the selection range (inclusive).
   *
   * This may be after end in terminal order. It is an untracked
   * WaspGridRef snapshot and follows untracked grid-ref lifetime rules.
   */
  WaspGridRef start;

  /**
   * End of the selection range (inclusive).
   *
   * This may be before start in terminal order. It is an untracked
   * WaspGridRef snapshot and follows untracked grid-ref lifetime rules.
   */
  WaspGridRef end;

  /**
   * Whether the endpoints are interpreted as a rectangular/block selection
   * rather than a linear selection.
   */
  bool rectangle;
} WaspSelection;

/**
 * A caller-provided buffer of selections.
 *
 * This follows the same conventions as WaspBuffer: ptr may be NULL with
 * cap 0 to query the required capacity. APIs that fill this type set len to
 * the number of entries written on WASP_SUCCESS, or to the required entry
 * capacity on WASP_OUT_OF_SPACE.
 *
 * @ingroup selection
 */
typedef struct {
  /** Destination buffer for selections. May be NULL when cap is 0 to query
   * the required capacity. */
  WaspSelection* ptr;

  /** Capacity of ptr in entries. */
  size_t cap;

  /** Entries written on success, or required entry capacity on
   * WASP_OUT_OF_SPACE. */
  size_t len;
} WaspSelectionBuffer;

/**
 * Options for deriving a word selection from a terminal grid reference.
 *
 * This is a sized struct. Use WASP_INIT_SIZED() to initialize it.
 * If boundary_codepoints is NULL and boundary_codepoints_len is 0, Wasp's
 * default word-boundary codepoints are used. If boundary_codepoints_len is
 * non-zero, boundary_codepoints must not be NULL.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(WaspTerminalSelectWordOptions). */
  size_t size;

  /** Grid reference under which to derive the word selection. */
  WaspGridRef ref;

  /** Optional word-boundary codepoints as uint32_t scalar values. */
  const uint32_t* boundary_codepoints;

  /** Number of entries in boundary_codepoints. */
  size_t boundary_codepoints_len;
} WaspTerminalSelectWordOptions;

/**
 * Options for deriving the nearest word selection between two grid references.
 *
 * This is a sized struct. Use WASP_INIT_SIZED() to initialize it.
 * If boundary_codepoints is NULL and boundary_codepoints_len is 0, Wasp's
 * default word-boundary codepoints are used. If boundary_codepoints_len is
 * non-zero, boundary_codepoints must not be NULL.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(WaspTerminalSelectWordBetweenOptions). */
  size_t size;

  /** Starting grid reference for the inclusive search range. */
  WaspGridRef start;

  /** Ending grid reference for the inclusive search range. */
  WaspGridRef end;

  /** Optional word-boundary codepoints as uint32_t scalar values. */
  const uint32_t* boundary_codepoints;

  /** Number of entries in boundary_codepoints. */
  size_t boundary_codepoints_len;
} WaspTerminalSelectWordBetweenOptions;

/**
 * Options for deriving a line selection from a terminal grid reference.
 *
 * This is a sized struct. Use WASP_INIT_SIZED() to initialize it.
 * If whitespace is NULL and whitespace_len is 0, Wasp's default line-trim
 * whitespace codepoints are used. If whitespace_len is non-zero, whitespace
 * must not be NULL.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(WaspTerminalSelectLineOptions). */
  size_t size;

  /** Grid reference under which to derive the line selection. */
  WaspGridRef ref;

  /** Optional codepoints to trim from the start and end of the line. */
  const uint32_t* whitespace;

  /** Number of entries in whitespace. */
  size_t whitespace_len;

  /** Whether semantic prompt state changes should bound the line selection. */
  bool semantic_prompt_boundary;
} WaspTerminalSelectLineOptions;

/**
 * Options for one-shot formatting of a terminal selection.
 *
 * This is a sized struct. Use WASP_INIT_SIZED() to initialize it.
 *
 * If selection is NULL, the terminal's current active selection is used.
 * If selection is non-NULL, that caller-provided snapshot selection is used.
 *
 * The selection is formatted from the terminal's active screen using the same
 * formatting semantics as WaspFormatter. For copy/clipboard behavior
 * matching Wasp's Screen.selectionString(), use plain output with unwrap
 * and trim both set to true.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(WaspTerminalSelectionFormatOptions). */
  size_t size;

  /** Output format to emit. */
  WaspFormatterFormat emit;

  /** Whether to unwrap soft-wrapped lines. */
  bool unwrap;

  /** Whether to trim trailing whitespace on non-blank lines. */
  bool trim;

  /**
   * Optional selection to format.
   *
   * If NULL, the terminal's current active selection is used. If the terminal
   * has no active selection, formatting returns WASP_NO_VALUE.
   *
   * If non-NULL, the pointed-to selection must be a valid snapshot selection
   * for this terminal and must obey WaspSelection lifetime rules.
   */
  const WaspSelection *selection;
} WaspTerminalSelectionFormatOptions;

/**
 * Ordering of a selection's endpoints in terminal coordinates.
 *
 * Mirrored orders are only produced by rectangular selections whose start
 * and end endpoints are on opposite diagonal corners that are not simple
 * top-left-to-bottom-right or bottom-right-to-top-left orderings.
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /** Start is before end in top-left to bottom-right order. */
  WASP_SELECTION_ORDER_FORWARD = 0,

  /** End is before start in top-left to bottom-right order. */
  WASP_SELECTION_ORDER_REVERSE = 1,

  /** Rectangular selection from top-right to bottom-left. */
  WASP_SELECTION_ORDER_MIRRORED_FORWARD = 2,

  /** Rectangular selection from bottom-left to top-right. */
  WASP_SELECTION_ORDER_MIRRORED_REVERSE = 3,

  WASP_SELECTION_ORDER_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionOrder;

/**
 * Operation used to adjust a selection endpoint.
 *
 * Adjustment mutates the selection's logical end endpoint, not whichever
 * endpoint is visually bottom/right. This preserves keyboard and drag
 * behavior for both forward and reversed selections.
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /** Move left to the previous non-empty cell, wrapping upward. */
  WASP_SELECTION_ADJUST_LEFT = 0,

  /** Move right to the next non-empty cell, wrapping downward. */
  WASP_SELECTION_ADJUST_RIGHT = 1,

  /**
   * Move up one row at the current column, or to the beginning of the
   * line if already at the top.
   */
  WASP_SELECTION_ADJUST_UP = 2,

  /**
   * Move down to the next non-blank row at the current column, or to the
   * end of the line if none exists.
   */
  WASP_SELECTION_ADJUST_DOWN = 3,

  /** Move to the top-left cell of the screen. */
  WASP_SELECTION_ADJUST_HOME = 4,

  /** Move to the right edge of the last non-blank row on the screen. */
  WASP_SELECTION_ADJUST_END = 5,

  /**
   * Move up by one terminal page height, or to home if that would move
   * past the top.
   */
  WASP_SELECTION_ADJUST_PAGE_UP = 6,

  /**
   * Move down by one terminal page height, or to end if that would move
   * past the bottom.
   */
  WASP_SELECTION_ADJUST_PAGE_DOWN = 7,

  /** Move to the left edge of the current line. */
  WASP_SELECTION_ADJUST_BEGINNING_OF_LINE = 8,

  /** Move to the right edge of the current line. */
  WASP_SELECTION_ADJUST_END_OF_LINE = 9,

  WASP_SELECTION_ADJUST_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionAdjust;

/**
 * Selection behavior chosen for a gesture's click sequence.
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /** Cell-granular drag selection. */
  WASP_SELECTION_GESTURE_BEHAVIOR_CELL = 0,

  /** Word selection on press and word-granular drag selection. */
  WASP_SELECTION_GESTURE_BEHAVIOR_WORD = 1,

  /** Line selection on press and line-granular drag selection. */
  WASP_SELECTION_GESTURE_BEHAVIOR_LINE = 2,

  /** Semantic command output selection on press and drag. */
  WASP_SELECTION_GESTURE_BEHAVIOR_OUTPUT = 3,

  WASP_SELECTION_GESTURE_BEHAVIOR_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionGestureBehavior;

/**
 * Selection behaviors for single-, double-, and triple-click gestures.
 *
 * @ingroup selection
 */
typedef struct {
  /** Behavior for single-click selection gestures. */
  WaspSelectionGestureBehavior single_click;

  /** Behavior for double-click selection gestures. */
  WaspSelectionGestureBehavior double_click;

  /** Behavior for triple-click selection gestures. */
  WaspSelectionGestureBehavior triple_click;
} WaspSelectionGestureBehaviors;

/**
 * Display geometry used to interpret selection gesture drag events.
 *
 * @ingroup selection
 */
typedef struct {
  /** Number of columns in the rendered terminal grid. Must be non-zero. */
  uint32_t columns;

  /** Width of one terminal cell in surface pixels. Must be non-zero. */
  uint32_t cell_width;

  /** Left padding before the terminal grid begins in surface pixels. */
  uint32_t padding_left;

  /** Height of the rendered terminal surface in surface pixels. Must be non-zero. */
  uint32_t screen_height;
} WaspSelectionGestureGeometry;

/**
 * Current autoscroll direction for an active selection drag gesture.
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /** No selection autoscroll is requested. */
  WASP_SELECTION_GESTURE_AUTOSCROLL_NONE = 0,

  /** Selection dragging should autoscroll the viewport upward. */
  WASP_SELECTION_GESTURE_AUTOSCROLL_UP = 1,

  /** Selection dragging should autoscroll the viewport downward. */
  WASP_SELECTION_GESTURE_AUTOSCROLL_DOWN = 2,

  WASP_SELECTION_GESTURE_AUTOSCROLL_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionGestureAutoscroll;

/**
 * Data fields readable from a selection gesture with
 * wasp_selection_gesture_get().
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /** Current click count: uint8_t*. 0 means inactive. */
  WASP_SELECTION_GESTURE_DATA_CLICK_COUNT = 0,

  /** Whether the current/last left-click gesture has dragged: bool*. */
  WASP_SELECTION_GESTURE_DATA_DRAGGED = 1,

  /** Current autoscroll request: WaspSelectionGestureAutoscroll*. */
  WASP_SELECTION_GESTURE_DATA_AUTOSCROLL = 2,

  /** Current gesture behavior: WaspSelectionGestureBehavior*. */
  WASP_SELECTION_GESTURE_DATA_BEHAVIOR = 3,

  /**
   * Current left-click anchor: WaspGridRef*.
   *
   * Returns WASP_NO_VALUE if there is no valid active anchor. On success,
   * writes an untracked WaspGridRef snapshot with normal WaspGridRef
   * lifetime rules.
   */
  WASP_SELECTION_GESTURE_DATA_ANCHOR = 4,

  WASP_SELECTION_GESTURE_DATA_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionGestureData;

/**
 * Selection gesture event type.
 *
 * The event type is fixed when the event is created. Each event type documents
 * which options are valid and which options are required by gesture operations.
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /** Press event for wasp_selection_gesture_event(). */
  WASP_SELECTION_GESTURE_EVENT_TYPE_PRESS = 0,

  /** Release event for wasp_selection_gesture_event(). */
  WASP_SELECTION_GESTURE_EVENT_TYPE_RELEASE = 1,

  /** Drag event for wasp_selection_gesture_event(). */
  WASP_SELECTION_GESTURE_EVENT_TYPE_DRAG = 2,

  /** Autoscroll tick event for wasp_selection_gesture_event(). */
  WASP_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK = 3,

  /** Deep press event for wasp_selection_gesture_event(). */
  WASP_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS = 4,

  WASP_SELECTION_GESTURE_EVENT_TYPE_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionGestureEventType;

/**
 * Options stored on a reusable selection gesture event.
 *
 * Passing NULL as the value to wasp_selection_gesture_event_set() clears the
 * corresponding option.
 *
 * @ingroup selection
 */
typedef enum WASP_ENUM_TYPED {
  /**
   * Grid reference under the pointer: WaspGridRef*.
   *
   * Required for PRESS and DRAG events. Optional for RELEASE events; when unset
   * or cleared, release records that the pointer did not map to a valid cell.
   */
  WASP_SELECTION_GESTURE_EVENT_OPT_REF = 0,

  /**
   * Surface-space pointer position: WaspSurfacePosition*.
   *
   * Valid for PRESS, DRAG, and AUTOSCROLL_TICK.
   */
  WASP_SELECTION_GESTURE_EVENT_OPT_POSITION = 1,

  /** Maximum repeat-click distance in pixels: double*. */
  WASP_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE = 2,

  /**
   * Optional monotonic event time in nanoseconds: uint64_t*.
   *
   * If unset, press treats the event as untimed and only single-click behavior
   * is available.
   */
  WASP_SELECTION_GESTURE_EVENT_OPT_TIME_NS = 3,

  /** Maximum interval between repeat clicks in nanoseconds: uint64_t*. */
  WASP_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS = 4,

  /**
   * Word-boundary codepoints: WaspCodepoints*.
   *
   * The codepoints are copied into event-owned storage when set. If unset,
   * operations that need word boundaries use Wasp's defaults.
   *
   * Valid for PRESS, DRAG, AUTOSCROLL_TICK, and DEEP_PRESS.
   */
  WASP_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS = 5,

  /**
   * Selection behavior table: WaspSelectionGestureBehaviors*.
   *
   * If unset, press uses the default behavior table: cell, word, line.
   */
  WASP_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS = 6,

  /** Whether a drag or autoscroll tick should produce a rectangular selection: bool*. */
  WASP_SELECTION_GESTURE_EVENT_OPT_RECTANGLE = 7,

  /** Drag display geometry: WaspSelectionGestureGeometry*. Required for DRAG and AUTOSCROLL_TICK. */
  WASP_SELECTION_GESTURE_EVENT_OPT_GEOMETRY = 8,

  /** Viewport coordinate for an autoscroll tick: WaspPointCoordinate*. Required for AUTOSCROLL_TICK. */
  WASP_SELECTION_GESTURE_EVENT_OPT_VIEWPORT = 9,

  WASP_SELECTION_GESTURE_EVENT_OPT_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSelectionGestureEventOption;

/**
 * Create a reusable selection gesture event object.
 *
 * @param allocator Allocator, or NULL for the default allocator
 * @param out_event Receives the created event handle
 * @param type Event type. This is fixed for the lifetime of the event.
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if out_event is
 *         NULL or type is invalid, or WASP_OUT_OF_MEMORY if allocation fails
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_selection_gesture_event_new(
                                    const WaspAllocator* allocator,
                                    WaspSelectionGestureEvent* out_event,
                                    WaspSelectionGestureEventType type);

/**
 * Free a selection gesture event object.
 *
 * Passing NULL is allowed and is a no-op.
 *
 * @param event Selection gesture event handle to free
 *
 * @ingroup selection
 */
WASP_API void wasp_selection_gesture_event_free(
                                    WaspSelectionGestureEvent event);

/**
 * Set or clear an option on a selection gesture event.
 *
 * The value type depends on option and is documented by
 * WaspSelectionGestureEventOption. Passing NULL for value clears the option.
 *
 * @param event Selection gesture event handle (NULL returns WASP_INVALID_VALUE)
 * @param option Event option to set or clear
 * @param value Pointer to the input value for option, or NULL to clear
 * @return WASP_SUCCESS on success, WASP_OUT_OF_MEMORY if copying
 *         event-owned data fails, or WASP_INVALID_VALUE if event, option, or
 *         value is invalid
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_selection_gesture_event_set(
                                    WaspSelectionGestureEvent event,
                                    WaspSelectionGestureEventOption option,
                                    const void* value);

/**
 * Apply a selection gesture event and return the resulting selection snapshot.
 *
 * This dispatches to the gesture operation matching the event's fixed type.
 * For WASP_SELECTION_GESTURE_EVENT_TYPE_PRESS, the event must have
 * WASP_SELECTION_GESTURE_EVENT_OPT_REF set before calling this function.
 * All other press options use their initialized defaults when unset or cleared.
 *
 * For WASP_SELECTION_GESTURE_EVENT_TYPE_RELEASE, only
 * WASP_SELECTION_GESTURE_EVENT_OPT_REF is valid. It is optional; if unset or
 * cleared, release records that the pointer did not map to a valid cell. Release
 * events update gesture state but do not produce a selection, so this function
 * returns WASP_NO_VALUE after applying them.
 *
 * For WASP_SELECTION_GESTURE_EVENT_TYPE_DRAG,
 * WASP_SELECTION_GESTURE_EVENT_OPT_REF and
 * WASP_SELECTION_GESTURE_EVENT_OPT_GEOMETRY are required. Position,
 * rectangle, and word-boundary codepoints are optional and use initialized
 * defaults when unset or cleared.
 *
 * For WASP_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
 * WASP_SELECTION_GESTURE_EVENT_OPT_VIEWPORT and
 * WASP_SELECTION_GESTURE_EVENT_OPT_GEOMETRY are required. Position,
 * rectangle, and word-boundary codepoints are optional and use initialized
 * defaults when unset or cleared.
 *
 * For WASP_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS, only
 * WASP_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS is valid. It is
 * optional and uses initialized defaults when unset or cleared.
 *
 * The returned selection is not installed as the terminal's current selection.
 * It is a snapshot with the same lifetime rules as WaspSelection.
 *
 * @param gesture Selection gesture handle (NULL returns WASP_INVALID_VALUE)
 * @param terminal Terminal used to interpret and update gesture state
 * @param event Selection gesture event handle (NULL returns WASP_INVALID_VALUE)
 * @param[out] out_selection On success, receives the resulting selection. May
 *             be NULL to apply the event and discard the selection result.
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if the event does not
 *         currently produce a selection, WASP_OUT_OF_MEMORY if tracking
 *         gesture state fails, or WASP_INVALID_VALUE if gesture, terminal,
 *         event, or required event data is invalid
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_selection_gesture_event(
                                    WaspSelectionGesture gesture,
                                    WaspTerminal terminal,
                                    WaspSelectionGestureEvent event,
                                    WaspSelection* out_selection);

/**
 * Create a selection gesture object.
 *
 * The gesture stores mutable state for terminal text selection gestures. The
 * gesture is not bound to a terminal at creation time; terminal-dependent APIs
 * take the terminal explicitly.
 *
 * @param allocator Allocator, or NULL for the default allocator
 * @param out_gesture Receives the created gesture handle
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if out_gesture is
 *         NULL, or WASP_OUT_OF_MEMORY if allocation fails
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_selection_gesture_new(
                                    const WaspAllocator* allocator,
                                    WaspSelectionGesture* out_gesture);

/**
 * Free a selection gesture object.
 *
 * This releases any tracked terminal references owned by the gesture using the
 * provided terminal, then frees the gesture object. Passing NULL for gesture is
 * allowed and is a no-op.
 *
 * If the terminal is still alive, pass the terminal most recently used with the
 * gesture so any tracked terminal references can be released correctly. If the
 * terminal has already been freed, pass NULL for terminal; the terminal's page
 * storage has already released the underlying tracked references, so the
 * gesture wrapper can be safely discarded without touching the stale terminal
 * state.
 *
 * @param gesture Selection gesture handle to free
 * @param terminal Terminal used to release tracked gesture state, or NULL if
 *                 the terminal has already been freed
 *
 * @ingroup selection
 */
WASP_API void wasp_selection_gesture_free(
                                    WaspSelectionGesture gesture,
                                    WaspTerminal terminal);

/**
 * Reset any active selection gesture state.
 *
 * This cancels the active click sequence and releases any tracked terminal
 * references owned by the gesture without freeing the gesture object.
 * Passing NULL is allowed and is a no-op.
 *
 * @param gesture Selection gesture handle to reset
 * @param terminal Terminal used to release tracked gesture state
 *
 * @ingroup selection
 */
WASP_API void wasp_selection_gesture_reset(
                                    WaspSelectionGesture gesture,
                                    WaspTerminal terminal);

/**
 * Read data from a selection gesture.
 *
 * The type of value depends on data and is documented by
 * WaspSelectionGestureData. For WASP_SELECTION_GESTURE_DATA_ANCHOR,
 * the returned WaspGridRef is an untracked snapshot with normal grid-ref
 * lifetime rules.
 *
 * @param gesture Selection gesture handle (NULL returns WASP_INVALID_VALUE)
 * @param terminal Terminal used to validate terminal-backed gesture state
 * @param data Data field to read
 * @param value Output pointer whose type depends on data
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if the requested data
 *         has no value, or WASP_INVALID_VALUE if gesture, terminal, data, or
 *         value is invalid
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_selection_gesture_get(
                                    WaspSelectionGesture gesture,
                                    WaspTerminal terminal,
                                    WaspSelectionGestureData data,
                                    void* value);

/**
 * Read multiple data fields from a selection gesture in a single call.
 *
 * This is an optimization over calling wasp_selection_gesture_get() multiple
 * times. Each entry in values must point to storage of the type documented by
 * the corresponding WaspSelectionGestureData key.
 *
 * If any individual read fails, the function returns that error and writes the
 * index of the failing key to out_written when out_written is non-NULL. On
 * success, out_written receives count when non-NULL.
 *
 * @param gesture Selection gesture handle (NULL returns WASP_INVALID_VALUE)
 * @param terminal Terminal used to validate terminal-backed gesture state
 * @param count Number of data fields to read
 * @param keys Data fields to read (must not be NULL)
 * @param values Output pointers corresponding to keys (must not be NULL)
 * @param out_written Optional number of fields read, or failing index on error
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if a requested data
 *         field has no value, or WASP_INVALID_VALUE if gesture, terminal,
 *         keys, values, or a value pointer is invalid
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_selection_gesture_get_multi(
                                    WaspSelectionGesture gesture,
                                    WaspTerminal terminal,
                                    size_t count,
                                    const WaspSelectionGestureData* keys,
                                    void** values,
                                    size_t* out_written);

/**
 * Derive a word selection snapshot from a terminal grid reference.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as WaspSelection.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param options Word-selection options
 * @param[out] out_selection On success, receives the derived selection
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if the valid ref has
 *         no selectable word content, or WASP_INVALID_VALUE if the
 *         terminal, options, ref, codepoint pointer, or output pointer are
 *         invalid.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_select_word(
                                    WaspTerminal terminal,
                                    const WaspTerminalSelectWordOptions* options,
                                    WaspSelection* out_selection);

/**
 * Derive the nearest word selection snapshot between two terminal grid refs.
 *
 * Starting at options->start, this searches toward options->end (inclusive)
 * and returns the first selectable word found using Wasp's word-selection
 * rules.
 *
 * This is useful for implementing double-click-and-drag selection in a UI. If
 * a user double-clicks one word and drags across spaces or punctuation toward
 * another word, selecting only the word directly under the current pointer can
 * flicker or collapse when the pointer is between words. Instead, ask for the
 * nearest word between the original click and the drag point, ask again in the
 * reverse direction, and combine the two word bounds into the drag selection.
 *
 * @snippet c-vt-selection/src/main.c selection-word-between
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as WaspSelection.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param options Word-between-selection options
 * @param[out] out_selection On success, receives the derived selection
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if there is no
 *         selectable word content between the valid refs, or
 *         WASP_INVALID_VALUE if the terminal, options, refs, codepoint
 *         pointer, or output pointer are invalid.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_select_word_between(
                                    WaspTerminal terminal,
                                    const WaspTerminalSelectWordBetweenOptions* options,
                                    WaspSelection* out_selection);

/**
 * Derive a line selection snapshot from a terminal grid reference.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as WaspSelection.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param options Line-selection options
 * @param[out] out_selection On success, receives the derived selection
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if the valid ref has
 *         no selectable line content, or WASP_INVALID_VALUE if the
 *         terminal, options, ref, codepoint pointer, or output pointer are
 *         invalid.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_select_line(
                                    WaspTerminal terminal,
                                    const WaspTerminalSelectLineOptions* options,
                                    WaspSelection* out_selection);

/**
 * Derive a selection snapshot covering all selectable terminal content.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as WaspSelection.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param[out] out_selection On success, receives the derived selection
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if there is no
 *         selectable content, or WASP_INVALID_VALUE if the terminal or
 *         output pointer is invalid.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_select_all(
                                    WaspTerminal terminal,
                                    WaspSelection* out_selection);

/**
 * Derive a command-output selection snapshot from a terminal grid reference.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as WaspSelection.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param ref Grid reference within command output to select
 * @param[out] out_selection On success, receives the derived selection
 * @return WASP_SUCCESS on success, WASP_NO_VALUE if the valid ref is
 *         not selectable command output, or WASP_INVALID_VALUE if the
 *         terminal, ref, or output pointer is invalid.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_select_output(
                                    WaspTerminal terminal,
                                    WaspGridRef ref,
                                    WaspSelection* out_selection);

/**
 * Format a terminal selection into a caller-provided buffer.
 *
 * This is a one-shot convenience API for formatting either the terminal's
 * active selection or a caller-provided WaspSelection without explicitly
 * creating a WaspFormatter.
 *
 * Pass NULL for buf to query the required output size. In that case,
 * out_written receives the required size and the function returns
 * WASP_OUT_OF_SPACE.
 *
 * If buf is too small, the function returns WASP_OUT_OF_SPACE and writes
 * the required size to out_written. The caller can then retry with a larger
 * buffer.
 *
 * If options.selection is NULL and the terminal has no active selection, the
 * function returns WASP_NO_VALUE.
 *
 * @param terminal The terminal to read from (must not be NULL)
 * @param options Selection formatting options
 * @param buf Output buffer, or NULL to query required size
 * @param buf_len Length of buf in bytes
 * @param out_written Number of bytes written, or required size on
 *                    WASP_OUT_OF_SPACE (must not be NULL)
 * @return WASP_SUCCESS on success, or an error code on failure
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_format_buf(
                                    WaspTerminal terminal,
                                    WaspTerminalSelectionFormatOptions options,
                                    uint8_t* buf,
                                    size_t buf_len,
                                    size_t* out_written);

/**
 * Format a terminal selection into an allocated buffer.
 *
 * This is a one-shot convenience API for formatting either the terminal's
 * active selection or a caller-provided WaspSelection without explicitly
 * creating a WaspFormatter.
 *
 * The returned buffer is allocated using allocator, or the default allocator
 * if NULL is passed. The caller owns the returned buffer and must free it with
 * wasp_free(), passing the same allocator and returned length.
 * Empty output returns WASP_SUCCESS with *out_ptr set to NULL and
 * *out_len set to zero. This result can be passed to wasp_free().
 *
 * The returned bytes are not NUL-terminated. This supports plain text, VT, and
 * HTML uniformly as byte output.
 *
 * If options.selection is NULL and the terminal has no active selection, the
 * function returns WASP_NO_VALUE and leaves out_ptr as NULL and out_len as 0.
 *
 * @param terminal The terminal to read from (must not be NULL)
 * @param allocator Allocator used for the returned buffer, or NULL for the default allocator
 * @param options Selection formatting options
 * @param out_ptr Receives the allocated output buffer (must not be NULL)
 * @param out_len Receives the output length in bytes (must not be NULL)
 * @return WASP_SUCCESS on success, or an error code on failure
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_format_alloc(
                                    WaspTerminal terminal,
                                    const WaspAllocator* allocator,
                                    WaspTerminalSelectionFormatOptions options,
                                    uint8_t** out_ptr,
                                    size_t* out_len);

/**
 * Adjust a selection snapshot using terminal selection semantics.
 *
 * This mutates the caller-provided WaspSelection in place. The logical end
 * endpoint is always moved, regardless of whether the selection is forward or
 * reversed visually. The input selection remains a snapshot: after adjustment,
 * call wasp_terminal_set() with WASP_TERMINAL_OPT_SELECTION to install it
 * as the terminal-owned selection if desired.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param selection Selection snapshot to adjust in place
 * @param adjustment The adjustment operation to apply
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the terminal,
 *         selection, or adjustment are invalid. Selection reference validity
 *         is a precondition and is not checked.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_adjust(
                                    WaspTerminal terminal,
                                    WaspSelection* selection,
                                    WaspSelectionAdjust adjustment);

/**
 * Get the current endpoint ordering of a selection snapshot.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param selection Selection snapshot to inspect
 * @param[out] out_order On success, receives the selection order
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the terminal,
 *         selection, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_order(
                                    WaspTerminal terminal,
                                    const WaspSelection* selection,
                                    WaspSelectionOrder* out_order);

/**
 * Return a selection snapshot with endpoints ordered as requested.
 *
 * Use WASP_SELECTION_ORDER_FORWARD to get top-left to bottom-right bounds,
 * and WASP_SELECTION_ORDER_REVERSE to get bottom-right to top-left bounds.
 * Mirrored desired orders are accepted but normalized the same as forward.
 * The output selection is a fresh untracked snapshot and is not installed as
 * the terminal's current selection.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param selection Selection snapshot to order
 * @param desired Desired endpoint order
 * @param[out] out_selection On success, receives the ordered selection
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the terminal,
 *         selection, desired order, or output pointer are invalid. Selection
 *         reference validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_ordered(
                                    WaspTerminal terminal,
                                    const WaspSelection* selection,
                                    WaspSelectionOrder desired,
                                    WaspSelection* out_selection);

/**
 * Test whether a terminal point is inside a selection snapshot.
 *
 * This uses the same selection semantics as the terminal, including
 * rectangular/block selections and linear selections spanning multiple rows.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param selection Selection snapshot to inspect
 * @param point Point to test for containment
 * @param[out] out_contains On success, receives whether point is inside selection
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the terminal,
 *         selection, point, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_contains(
                                    WaspTerminal terminal,
                                    const WaspSelection* selection,
                                    WaspPoint point,
                                    bool* out_contains);

/**
 * Test whether two selection snapshots are equal.
 *
 * Equality uses the terminal's internal selection semantics: both endpoint
 * pins must match and both selections must have the same rectangular/block
 * state. This avoids requiring callers to compare raw WaspGridRef internals.
 *
 * Both selections' start and end grid refs must be valid untracked snapshots
 * for the given terminal's currently active screen. In practice, they must
 * come from that terminal and screen, and no mutating terminal call may have
 * occurred since the refs were produced or reconstructed from tracked refs.
 * Passing refs from another terminal, another screen, or stale refs violates
 * this precondition.
 *
 * @param terminal The terminal handle (NULL returns WASP_INVALID_VALUE)
 * @param a First selection snapshot to compare
 * @param b Second selection snapshot to compare
 * @param[out] out_equal On success, receives whether the selections are equal
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the terminal,
 *         selections, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
WASP_API WaspResult wasp_terminal_selection_equal(
                                    WaspTerminal terminal,
                                    const WaspSelection* a,
                                    const WaspSelection* b,
                                    bool* out_equal);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* WASP_VT_SELECTION_H */
