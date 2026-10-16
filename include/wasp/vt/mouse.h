/**
 * @file mouse.h
 *
 * Mouse support module - encode mouse events and provide pointer shapes.
 */

#ifndef WASP_VT_MOUSE_H
#define WASP_VT_MOUSE_H

/** @defgroup mouse Mouse Support
 *
 * Utilities for encoding mouse events into terminal escape sequences,
 * supporting X10, UTF-8, SGR, URxvt, and SGR-Pixels mouse protocols.
 *
 * ## Basic Usage
 *
 * 1. Create an encoder instance with wasp_mouse_encoder_new().
 * 2. Configure encoder options with wasp_mouse_encoder_setopt() or
 *    wasp_mouse_encoder_setopt_from_terminal().
 * 3. For each mouse event:
 *    - Create a mouse event with wasp_mouse_event_new().
 *    - Set event properties (action, button, modifiers, position).
 *    - Encode with wasp_mouse_encoder_encode().
 *    - Free the event with wasp_mouse_event_free() or reuse it.
 * 4. Free the encoder with wasp_mouse_encoder_free() when done.
 *
 * For a complete working example, see example/c-vt-encode-mouse in the
 * repository.
 *
 * ## Example
 *
 * @snippet c-vt-encode-mouse/src/main.c mouse-encode
 *
 * ## Example: Encoding with Terminal State
 *
 * When you have a WaspTerminal, you can sync its tracking mode and
 * output format into the encoder automatically:
 *
 * @code{.c}
 * // Create a terminal and feed it some VT data that enables mouse tracking
 * WaspTerminal terminal;
 * wasp_terminal_new(NULL, &terminal, 80, 24);
 *
 * // Application might write data that enables mouse reporting, etc.
 * wasp_terminal_vt_write(terminal, vt_data, vt_len);
 *
 * // Create an encoder and sync its options from the terminal
 * WaspMouseEncoder encoder;
 * wasp_mouse_encoder_new(NULL, &encoder);
 * wasp_mouse_encoder_setopt_from_terminal(encoder, terminal);
 *
 * // Encode a mouse event using the terminal-derived options
 * char buf[128];
 * size_t written = 0;
 * wasp_mouse_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *
 * wasp_mouse_encoder_free(encoder);
 * wasp_terminal_free(terminal);
 * @endcode
 *
 * @{
 */

#include <wasp/vt/types.h>
#include <wasp/vt/mouse/event.h>
#include <wasp/vt/mouse/encoder.h>

/**
 * Mouse pointer shapes based on the W3C cursor names.
 *
 * Hosts map these values to their native pointer shapes; not every platform
 * supports every shape. These are pointer shapes, not terminal text cursors.
 *
 * @ingroup mouse
 */
typedef enum WASP_ENUM_TYPED {
  WASP_MOUSE_SHAPE_DEFAULT = 0,
  WASP_MOUSE_SHAPE_CONTEXT_MENU = 1,
  WASP_MOUSE_SHAPE_HELP = 2,
  WASP_MOUSE_SHAPE_POINTER = 3,
  WASP_MOUSE_SHAPE_PROGRESS = 4,
  WASP_MOUSE_SHAPE_WAIT = 5,
  WASP_MOUSE_SHAPE_CELL = 6,
  WASP_MOUSE_SHAPE_CROSSHAIR = 7,
  WASP_MOUSE_SHAPE_TEXT = 8,
  WASP_MOUSE_SHAPE_VERTICAL_TEXT = 9,
  WASP_MOUSE_SHAPE_ALIAS = 10,
  WASP_MOUSE_SHAPE_COPY = 11,
  WASP_MOUSE_SHAPE_MOVE = 12,
  WASP_MOUSE_SHAPE_NO_DROP = 13,
  WASP_MOUSE_SHAPE_NOT_ALLOWED = 14,
  WASP_MOUSE_SHAPE_GRAB = 15,
  WASP_MOUSE_SHAPE_GRABBING = 16,
  WASP_MOUSE_SHAPE_ALL_SCROLL = 17,
  WASP_MOUSE_SHAPE_COL_RESIZE = 18,
  WASP_MOUSE_SHAPE_ROW_RESIZE = 19,
  WASP_MOUSE_SHAPE_N_RESIZE = 20,
  WASP_MOUSE_SHAPE_E_RESIZE = 21,
  WASP_MOUSE_SHAPE_S_RESIZE = 22,
  WASP_MOUSE_SHAPE_W_RESIZE = 23,
  WASP_MOUSE_SHAPE_NE_RESIZE = 24,
  WASP_MOUSE_SHAPE_NW_RESIZE = 25,
  WASP_MOUSE_SHAPE_SE_RESIZE = 26,
  WASP_MOUSE_SHAPE_SW_RESIZE = 27,
  WASP_MOUSE_SHAPE_EW_RESIZE = 28,
  WASP_MOUSE_SHAPE_NS_RESIZE = 29,
  WASP_MOUSE_SHAPE_NESW_RESIZE = 30,
  WASP_MOUSE_SHAPE_NWSE_RESIZE = 31,
  WASP_MOUSE_SHAPE_ZOOM_IN = 32,
  WASP_MOUSE_SHAPE_ZOOM_OUT = 33,
  WASP_MOUSE_SHAPE_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspMouseShape;

/** @} */

#endif /* WASP_VT_MOUSE_H */
