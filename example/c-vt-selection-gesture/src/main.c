#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [selection-gesture-main]
static void vt_write(WaspTerminal terminal, const char *s) {
  wasp_terminal_vt_write(terminal, (const uint8_t *)s, strlen(s));
}

static WaspGridRef ref_at(WaspTerminal terminal, uint16_t x, uint16_t y) {
  WaspGridRef ref = WASP_INIT_SIZED(WaspGridRef);
  WaspPoint point = {
    .tag = WASP_POINT_TAG_ACTIVE,
    .value = { .coordinate = { .x = x, .y = y } },
  };

  WaspResult result = wasp_terminal_grid_ref(terminal, point, &ref);
  assert(result == WASP_SUCCESS);
  return ref;
}

static void print_selection(
    WaspTerminal terminal,
    const char *label,
    const WaspSelection *selection) {
  WaspTerminalSelectionFormatOptions opts =
      WASP_INIT_SIZED(WaspTerminalSelectionFormatOptions);
  opts.emit = WASP_FORMATTER_FORMAT_PLAIN;
  opts.trim = true;
  opts.selection = selection;

  uint8_t *buf = NULL;
  size_t len = 0;
  WaspResult result = wasp_terminal_selection_format_alloc(
      terminal, NULL, opts, &buf, &len);
  assert(result == WASP_SUCCESS);

  printf("%s: ", label);
  fwrite(buf, 1, len, stdout);
  printf("\n");

  wasp_free(NULL, buf, len);
}

static WaspSelectionGestureEvent new_event(
    WaspSelectionGestureEventType type) {
  WaspSelectionGestureEvent event = NULL;
  WaspResult result = wasp_selection_gesture_event_new(NULL, &event, type);
  assert(result == WASP_SUCCESS);
  return event;
}

int main() {
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(NULL, &terminal, 20, 4);
  assert(result == WASP_SUCCESS);

  vt_write(terminal, "hello world\r\nsecond line");

  WaspSelectionGesture gesture = NULL;
  result = wasp_selection_gesture_new(NULL, &gesture);
  assert(result == WASP_SUCCESS);

  WaspSelectionGestureEvent press =
      new_event(WASP_SELECTION_GESTURE_EVENT_TYPE_PRESS);
  WaspSelectionGestureEvent drag =
      new_event(WASP_SELECTION_GESTURE_EVENT_TYPE_DRAG);
  WaspSelectionGestureEvent release =
      new_event(WASP_SELECTION_GESTURE_EVENT_TYPE_RELEASE);
  WaspSelectionGestureEvent deep_press =
      new_event(WASP_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS);

  WaspSelectionGestureGeometry geometry = {
    .columns = 20,
    .cell_width = 10,
    .padding_left = 0,
    .screen_height = 40,
  };

  // Press in the first cell. A normal single press records the click anchor but
  // doesn't produce a selection yet, so we discard the optional output.
  WaspGridRef press_ref = ref_at(terminal, 0, 0);
  result = wasp_selection_gesture_event_set(
      press, WASP_SELECTION_GESTURE_EVENT_OPT_REF, &press_ref);
  assert(result == WASP_SUCCESS);

  WaspSurfacePosition press_pos = { .x = 2, .y = 8 };
  result = wasp_selection_gesture_event_set(
      press, WASP_SELECTION_GESTURE_EVENT_OPT_POSITION, &press_pos);
  assert(result == WASP_SUCCESS);

  result = wasp_selection_gesture_event(
      gesture, terminal, press, NULL);
  assert(result == WASP_NO_VALUE);

  // Drag across "hello". The drag event returns a selection snapshot that the
  // embedder can apply to its UI, copy, or format immediately.
  WaspGridRef drag_ref = ref_at(terminal, 4, 0);
  result = wasp_selection_gesture_event_set(
      drag, WASP_SELECTION_GESTURE_EVENT_OPT_REF, &drag_ref);
  assert(result == WASP_SUCCESS);

  WaspSurfacePosition drag_pos = { .x = 46, .y = 8 };
  result = wasp_selection_gesture_event_set(
      drag, WASP_SELECTION_GESTURE_EVENT_OPT_POSITION, &drag_pos);
  assert(result == WASP_SUCCESS);

  result = wasp_selection_gesture_event_set(
      drag, WASP_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
  assert(result == WASP_SUCCESS);

  WaspSelection selection = WASP_INIT_SIZED(WaspSelection);
  result = wasp_selection_gesture_event(
      gesture, terminal, drag, &selection);
  assert(result == WASP_SUCCESS);
  print_selection(terminal, "drag", &selection);

  // Release updates gesture state but never produces a selection.
  result = wasp_selection_gesture_event_set(
      release, WASP_SELECTION_GESTURE_EVENT_OPT_REF, &drag_ref);
  assert(result == WASP_SUCCESS);
  result = wasp_selection_gesture_event(
      gesture, terminal, release, NULL);
  assert(result == WASP_NO_VALUE);

  bool dragged = false;
  result = wasp_selection_gesture_get(
      gesture, terminal, WASP_SELECTION_GESTURE_DATA_DRAGGED, &dragged);
  assert(result == WASP_SUCCESS);
  printf("dragged: %s\n", dragged ? "true" : "false");

  // Deep press uses the active click anchor to select the surrounding word.
  wasp_selection_gesture_reset(gesture, terminal);
  WaspGridRef world_ref = ref_at(terminal, 6, 0);
  result = wasp_selection_gesture_event_set(
      press, WASP_SELECTION_GESTURE_EVENT_OPT_REF, &world_ref);
  assert(result == WASP_SUCCESS);
  result = wasp_selection_gesture_event(
      gesture, terminal, press, NULL);
  assert(result == WASP_NO_VALUE);

  result = wasp_selection_gesture_event(
      gesture, terminal, deep_press, &selection);
  assert(result == WASP_SUCCESS);
  print_selection(terminal, "deep press", &selection);

  wasp_selection_gesture_event_free(deep_press);
  wasp_selection_gesture_event_free(release);
  wasp_selection_gesture_event_free(drag);
  wasp_selection_gesture_event_free(press);
  wasp_selection_gesture_free(gesture, terminal);
  wasp_terminal_free(terminal);
  return 0;
}
//! [selection-gesture-main]
