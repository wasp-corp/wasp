/**
 * @file event.h
 *
 * Mouse event representation and manipulation.
 */

#ifndef WASP_VT_MOUSE_EVENT_H
#define WASP_VT_MOUSE_EVENT_H

#include <stdbool.h>
#include <wasp/vt/allocator.h>
#include <wasp/vt/key/event.h>
#include <wasp/vt/types.h>

/**
 * Opaque handle to a mouse event.
 *
 * This handle represents a normalized mouse input event containing
 * action, button, modifiers, and surface-space position.
 *
 * @ingroup mouse
 */
typedef struct WaspMouseEventImpl *WaspMouseEvent;

/**
 * Mouse event action type.
 *
 * @ingroup mouse
 */
typedef enum WASP_ENUM_TYPED {
  /** Mouse button was pressed. */
  WASP_MOUSE_ACTION_PRESS = 0,

  /** Mouse button was released. */
  WASP_MOUSE_ACTION_RELEASE = 1,

  /** Mouse moved. */
  WASP_MOUSE_ACTION_MOTION = 2,
  WASP_MOUSE_ACTION_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspMouseAction;

/**
 * Mouse button identity.
 *
 * @ingroup mouse
 */
typedef enum WASP_ENUM_TYPED {
  WASP_MOUSE_BUTTON_UNKNOWN = 0,
  WASP_MOUSE_BUTTON_LEFT = 1,
  WASP_MOUSE_BUTTON_RIGHT = 2,
  WASP_MOUSE_BUTTON_MIDDLE = 3,
  WASP_MOUSE_BUTTON_FOUR = 4,
  WASP_MOUSE_BUTTON_FIVE = 5,
  WASP_MOUSE_BUTTON_SIX = 6,
  WASP_MOUSE_BUTTON_SEVEN = 7,
  WASP_MOUSE_BUTTON_EIGHT = 8,
  WASP_MOUSE_BUTTON_NINE = 9,
  WASP_MOUSE_BUTTON_TEN = 10,
  WASP_MOUSE_BUTTON_ELEVEN = 11,
  WASP_MOUSE_BUTTON_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspMouseButton;

/**
 * Mouse position in surface-space pixels.
 *
 * @ingroup mouse
 */
typedef struct {
  float x;
  float y;
} WaspMousePosition;

/**
 * Create a new mouse event instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param event Pointer to store the created event handle
 * @return WASP_SUCCESS on success, or an error code on failure
 *
 * @ingroup mouse
 */
WASP_API WaspResult wasp_mouse_event_new(const WaspAllocator *allocator,
                                      WaspMouseEvent *event);

/**
 * Free a mouse event instance.
 *
 * @param event The mouse event handle to free (may be NULL)
 *
 * @ingroup mouse
 */
WASP_API void wasp_mouse_event_free(WaspMouseEvent event);

/**
 * Set the event action.
 *
 * @param event The event handle, must not be NULL
 * @param action The action to set
 *
 * @ingroup mouse
 */
WASP_API void wasp_mouse_event_set_action(WaspMouseEvent event,
                                    WaspMouseAction action);

/**
 * Get the event action.
 *
 * @param event The event handle, must not be NULL
 * @return The event action
 *
 * @ingroup mouse
 */
WASP_API WaspMouseAction wasp_mouse_event_get_action(WaspMouseEvent event);

/**
 * Set the event button.
 *
 * This sets a concrete button identity for the event.
 * To represent "no button" (for motion events), use
 * wasp_mouse_event_clear_button().
 *
 * @param event The event handle, must not be NULL
 * @param button The button to set
 *
 * @ingroup mouse
 */
WASP_API void wasp_mouse_event_set_button(WaspMouseEvent event,
                                    WaspMouseButton button);

/**
 * Clear the event button.
 *
 * This sets the event button to "none".
 *
 * @param event The event handle, must not be NULL
 *
 * @ingroup mouse
 */
WASP_API void wasp_mouse_event_clear_button(WaspMouseEvent event);

/**
 * Get the event button.
 *
 * @param event The event handle, must not be NULL
 * @param out_button Output pointer for the button value (may be NULL)
 * @return true if a button is set, false if no button is set
 *
 * @ingroup mouse
 */
WASP_API bool wasp_mouse_event_get_button(WaspMouseEvent event,
                                    WaspMouseButton *out_button);

/**
 * Set keyboard modifiers held during the event.
 *
 * @param event The event handle, must not be NULL
 * @param mods Modifier bitmask
 *
 * @ingroup mouse
 */
WASP_API void wasp_mouse_event_set_mods(WaspMouseEvent event,
                                  WaspMods mods);

/**
 * Get keyboard modifiers held during the event.
 *
 * @param event The event handle, must not be NULL
 * @return Modifier bitmask
 *
 * @ingroup mouse
 */
WASP_API WaspMods wasp_mouse_event_get_mods(WaspMouseEvent event);

/**
 * Set the event position in surface-space pixels.
 *
 * @param event The event handle, must not be NULL
 * @param position The position to set
 *
 * @ingroup mouse
 */
WASP_API void wasp_mouse_event_set_position(WaspMouseEvent event,
                                      WaspMousePosition position);

/**
 * Get the event position in surface-space pixels.
 *
 * @param event The event handle, must not be NULL
 * @return The current event position
 *
 * @ingroup mouse
 */
WASP_API WaspMousePosition wasp_mouse_event_get_position(WaspMouseEvent event);

#endif /* WASP_VT_MOUSE_EVENT_H */
