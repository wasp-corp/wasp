/**
 * @file event.h
 *
 * Key event representation and manipulation.
 */

#ifndef WASP_VT_KEY_EVENT_H
#define WASP_VT_KEY_EVENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wasp/vt/types.h>
#include <wasp/vt/allocator.h>

/**
 * Opaque handle to a key event.
 * 
 * This handle represents a keyboard input event containing information about
 * the physical key pressed, modifiers, and generated text.
 *
 * @ingroup key
 */
typedef struct WaspKeyEventImpl *WaspKeyEvent;

/**
 * Keyboard input event types.
 *
 * @ingroup key
 */
typedef enum WASP_ENUM_TYPED {
    /** Key was released */
    WASP_KEY_ACTION_RELEASE = 0,
    /** Key was pressed */
    WASP_KEY_ACTION_PRESS = 1,
    /** Key is being repeated (held down) */
    WASP_KEY_ACTION_REPEAT = 2,
    WASP_KEY_ACTION_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspKeyAction;

/**
 * Keyboard modifier keys bitmask.
 *
 * A bitmask representing all keyboard modifiers. This tracks which modifier keys 
 * are pressed and, where supported by the platform, which side (left or right) 
 * of each modifier is active.
 *
 * Use the WASP_MODS_* constants to test and set individual modifiers.
 *
 * Modifier side bits are only meaningful when the corresponding modifier bit is set.
 * Not all platforms support distinguishing between left and right modifier 
 * keys and Wasp is built to expect that some platforms may not provide this
 * information.
 *
 * @ingroup key
 */
typedef uint16_t WaspMods;

/** Shift key is pressed */
#define WASP_MODS_SHIFT (1 << 0)
/** Control key is pressed */
#define WASP_MODS_CTRL (1 << 1)
/** Alt/Option key is pressed */
#define WASP_MODS_ALT (1 << 2)
/** Super/Command/Windows key is pressed */
#define WASP_MODS_SUPER (1 << 3)
/** Caps Lock is active */
#define WASP_MODS_CAPS_LOCK (1 << 4)
/** Num Lock is active */
#define WASP_MODS_NUM_LOCK (1 << 5)

/**
 * Right shift is pressed (0 = left, 1 = right).
 * Only meaningful when WASP_MODS_SHIFT is set.
 */
#define WASP_MODS_SHIFT_SIDE (1 << 6)
/**
 * Right ctrl is pressed (0 = left, 1 = right).
 * Only meaningful when WASP_MODS_CTRL is set.
 */
#define WASP_MODS_CTRL_SIDE (1 << 7)
/**
 * Right alt is pressed (0 = left, 1 = right).
 * Only meaningful when WASP_MODS_ALT is set.
 */
#define WASP_MODS_ALT_SIDE (1 << 8)
/**
 * Right super is pressed (0 = left, 1 = right).
 * Only meaningful when WASP_MODS_SUPER is set.
 */
#define WASP_MODS_SUPER_SIDE (1 << 9)

/**
 * Physical key codes.
 *
 * The set of key codes that Wasp is aware of. These represent physical keys 
 * on the keyboard and are layout-independent. For example, the "a" key on a US 
 * keyboard is the same as the "ф" key on a Russian keyboard, but both will 
 * report the same key_a value.
 *
 * Layout-dependent strings are provided separately as UTF-8 text and are produced 
 * by the platform. These values are based on the W3C UI Events KeyboardEvent code 
 * standard. See: https://www.w3.org/TR/uievents-code
 *
 * @ingroup key
 */
typedef enum WASP_ENUM_TYPED {
    WASP_KEY_UNIDENTIFIED = 0,

    // Writing System Keys (W3C § 3.1.1)
    WASP_KEY_BACKQUOTE,
    WASP_KEY_BACKSLASH,
    WASP_KEY_BRACKET_LEFT,
    WASP_KEY_BRACKET_RIGHT,
    WASP_KEY_COMMA,
    WASP_KEY_DIGIT_0,
    WASP_KEY_DIGIT_1,
    WASP_KEY_DIGIT_2,
    WASP_KEY_DIGIT_3,
    WASP_KEY_DIGIT_4,
    WASP_KEY_DIGIT_5,
    WASP_KEY_DIGIT_6,
    WASP_KEY_DIGIT_7,
    WASP_KEY_DIGIT_8,
    WASP_KEY_DIGIT_9,
    WASP_KEY_EQUAL,
    WASP_KEY_INTL_BACKSLASH,
    WASP_KEY_INTL_RO,
    WASP_KEY_INTL_YEN,
    WASP_KEY_A,
    WASP_KEY_B,
    WASP_KEY_C,
    WASP_KEY_D,
    WASP_KEY_E,
    WASP_KEY_F,
    WASP_KEY_G,
    WASP_KEY_H,
    WASP_KEY_I,
    WASP_KEY_J,
    WASP_KEY_K,
    WASP_KEY_L,
    WASP_KEY_M,
    WASP_KEY_N,
    WASP_KEY_O,
    WASP_KEY_P,
    WASP_KEY_Q,
    WASP_KEY_R,
    WASP_KEY_S,
    WASP_KEY_T,
    WASP_KEY_U,
    WASP_KEY_V,
    WASP_KEY_W,
    WASP_KEY_X,
    WASP_KEY_Y,
    WASP_KEY_Z,
    WASP_KEY_MINUS,
    WASP_KEY_PERIOD,
    WASP_KEY_QUOTE,
    WASP_KEY_SEMICOLON,
    WASP_KEY_SLASH,

    // Functional Keys (W3C § 3.1.2)
    WASP_KEY_ALT_LEFT,
    WASP_KEY_ALT_RIGHT,
    WASP_KEY_BACKSPACE,
    WASP_KEY_CAPS_LOCK,
    WASP_KEY_CONTEXT_MENU,
    WASP_KEY_CONTROL_LEFT,
    WASP_KEY_CONTROL_RIGHT,
    WASP_KEY_ENTER,
    WASP_KEY_META_LEFT,
    WASP_KEY_META_RIGHT,
    WASP_KEY_SHIFT_LEFT,
    WASP_KEY_SHIFT_RIGHT,
    WASP_KEY_SPACE,
    WASP_KEY_TAB,
    WASP_KEY_CONVERT,
    WASP_KEY_KANA_MODE,
    WASP_KEY_NON_CONVERT,

    // Control Pad Section (W3C § 3.2)
    WASP_KEY_DELETE,
    WASP_KEY_END,
    WASP_KEY_HELP,
    WASP_KEY_HOME,
    WASP_KEY_INSERT,
    WASP_KEY_PAGE_DOWN,
    WASP_KEY_PAGE_UP,

    // Arrow Pad Section (W3C § 3.3)
    WASP_KEY_ARROW_DOWN,
    WASP_KEY_ARROW_LEFT,
    WASP_KEY_ARROW_RIGHT,
    WASP_KEY_ARROW_UP,

    // Numpad Section (W3C § 3.4)
    WASP_KEY_NUM_LOCK,
    WASP_KEY_NUMPAD_0,
    WASP_KEY_NUMPAD_1,
    WASP_KEY_NUMPAD_2,
    WASP_KEY_NUMPAD_3,
    WASP_KEY_NUMPAD_4,
    WASP_KEY_NUMPAD_5,
    WASP_KEY_NUMPAD_6,
    WASP_KEY_NUMPAD_7,
    WASP_KEY_NUMPAD_8,
    WASP_KEY_NUMPAD_9,
    WASP_KEY_NUMPAD_ADD,
    WASP_KEY_NUMPAD_BACKSPACE,
    WASP_KEY_NUMPAD_CLEAR,
    WASP_KEY_NUMPAD_CLEAR_ENTRY,
    WASP_KEY_NUMPAD_COMMA,
    WASP_KEY_NUMPAD_DECIMAL,
    WASP_KEY_NUMPAD_DIVIDE,
    WASP_KEY_NUMPAD_ENTER,
    WASP_KEY_NUMPAD_EQUAL,
    WASP_KEY_NUMPAD_MEMORY_ADD,
    WASP_KEY_NUMPAD_MEMORY_CLEAR,
    WASP_KEY_NUMPAD_MEMORY_RECALL,
    WASP_KEY_NUMPAD_MEMORY_STORE,
    WASP_KEY_NUMPAD_MEMORY_SUBTRACT,
    WASP_KEY_NUMPAD_MULTIPLY,
    WASP_KEY_NUMPAD_PAREN_LEFT,
    WASP_KEY_NUMPAD_PAREN_RIGHT,
    WASP_KEY_NUMPAD_SUBTRACT,
    WASP_KEY_NUMPAD_SEPARATOR,
    WASP_KEY_NUMPAD_UP,
    WASP_KEY_NUMPAD_DOWN,
    WASP_KEY_NUMPAD_RIGHT,
    WASP_KEY_NUMPAD_LEFT,
    WASP_KEY_NUMPAD_BEGIN,
    WASP_KEY_NUMPAD_HOME,
    WASP_KEY_NUMPAD_END,
    WASP_KEY_NUMPAD_INSERT,
    WASP_KEY_NUMPAD_DELETE,
    WASP_KEY_NUMPAD_PAGE_UP,
    WASP_KEY_NUMPAD_PAGE_DOWN,

    // Function Section (W3C § 3.5)
    WASP_KEY_ESCAPE,
    WASP_KEY_F1,
    WASP_KEY_F2,
    WASP_KEY_F3,
    WASP_KEY_F4,
    WASP_KEY_F5,
    WASP_KEY_F6,
    WASP_KEY_F7,
    WASP_KEY_F8,
    WASP_KEY_F9,
    WASP_KEY_F10,
    WASP_KEY_F11,
    WASP_KEY_F12,
    WASP_KEY_F13,
    WASP_KEY_F14,
    WASP_KEY_F15,
    WASP_KEY_F16,
    WASP_KEY_F17,
    WASP_KEY_F18,
    WASP_KEY_F19,
    WASP_KEY_F20,
    WASP_KEY_F21,
    WASP_KEY_F22,
    WASP_KEY_F23,
    WASP_KEY_F24,
    WASP_KEY_F25,
    WASP_KEY_FN,
    WASP_KEY_FN_LOCK,
    WASP_KEY_PRINT_SCREEN,
    WASP_KEY_SCROLL_LOCK,
    WASP_KEY_PAUSE,

    // Media Keys (W3C § 3.6)
    WASP_KEY_BROWSER_BACK,
    WASP_KEY_BROWSER_FAVORITES,
    WASP_KEY_BROWSER_FORWARD,
    WASP_KEY_BROWSER_HOME,
    WASP_KEY_BROWSER_REFRESH,
    WASP_KEY_BROWSER_SEARCH,
    WASP_KEY_BROWSER_STOP,
    WASP_KEY_EJECT,
    WASP_KEY_LAUNCH_APP_1,
    WASP_KEY_LAUNCH_APP_2,
    WASP_KEY_LAUNCH_MAIL,
    WASP_KEY_MEDIA_PLAY_PAUSE,
    WASP_KEY_MEDIA_SELECT,
    WASP_KEY_MEDIA_STOP,
    WASP_KEY_MEDIA_TRACK_NEXT,
    WASP_KEY_MEDIA_TRACK_PREVIOUS,
    WASP_KEY_POWER,
    WASP_KEY_SLEEP,
    WASP_KEY_AUDIO_VOLUME_DOWN,
    WASP_KEY_AUDIO_VOLUME_MUTE,
    WASP_KEY_AUDIO_VOLUME_UP,
    WASP_KEY_WAKE_UP,

    // Legacy, Non-standard, and Special Keys (W3C § 3.7)
    WASP_KEY_COPY,
    WASP_KEY_CUT,
    WASP_KEY_PASTE,
    WASP_KEY_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspKey;

/**
 * Create a new key event instance.
 * 
 * Creates a new key event with default values. The event must be freed using
 * wasp_key_event_free() when no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param event Pointer to store the created key event handle
 * @return WASP_SUCCESS on success, or an error code on failure
 * 
 * @ingroup key
 */
WASP_API WaspResult wasp_key_event_new(const WaspAllocator *allocator, WaspKeyEvent *event);

/**
 * Free a key event instance.
 * 
 * Releases all resources associated with the key event. After this call,
 * the event handle becomes invalid and must not be used.
 * 
 * @param event The key event handle to free (may be NULL)
 * 
 * @ingroup key
 */
WASP_API void wasp_key_event_free(WaspKeyEvent event);

/**
 * Set the key action (press, release, repeat).
 *
 * @param event The key event handle, must not be NULL
 * @param action The action to set
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_action(WaspKeyEvent event, WaspKeyAction action);

/**
 * Get the key action (press, release, repeat).
 *
 * @param event The key event handle, must not be NULL
 * @return The key action
 *
 * @ingroup key
 */
WASP_API WaspKeyAction wasp_key_event_get_action(WaspKeyEvent event);

/**
 * Set the physical key code.
 *
 * @param event The key event handle, must not be NULL
 * @param key The physical key code to set
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_key(WaspKeyEvent event, WaspKey key);

/**
 * Get the physical key code.
 *
 * @param event The key event handle, must not be NULL
 * @return The physical key code
 *
 * @ingroup key
 */
WASP_API WaspKey wasp_key_event_get_key(WaspKeyEvent event);

/**
 * Set the modifier keys bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @param mods The modifier keys bitmask to set
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_mods(WaspKeyEvent event, WaspMods mods);

/**
 * Get the modifier keys bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @return The modifier keys bitmask
 *
 * @ingroup key
 */
WASP_API WaspMods wasp_key_event_get_mods(WaspKeyEvent event);

/**
 * Set the consumed modifiers bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @param consumed_mods The consumed modifiers bitmask to set
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_consumed_mods(WaspKeyEvent event, WaspMods consumed_mods);

/**
 * Get the consumed modifiers bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @return The consumed modifiers bitmask
 *
 * @ingroup key
 */
WASP_API WaspMods wasp_key_event_get_consumed_mods(WaspKeyEvent event);

/**
 * Set whether the key event is part of a composition sequence.
 *
 * @param event The key event handle, must not be NULL
 * @param composing Whether the key event is part of a composition sequence
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_composing(WaspKeyEvent event, bool composing);

/**
 * Get whether the key event is part of a composition sequence.
 *
 * @param event The key event handle, must not be NULL
 * @return Whether the key event is part of a composition sequence
 *
 * @ingroup key
 */
WASP_API bool wasp_key_event_get_composing(WaspKeyEvent event);

/**
 * Set the UTF-8 text generated by the key for the current keyboard layout.
 *
 * Must contain the unmodified character before any Ctrl/Meta transformations.
 * The encoder derives modifier sequences from the logical key and mods
 * bitmask, not from this text. Do not pass C0 control characters
 * (U+0000-U+001F, U+007F) or platform function key codes (e.g. macOS PUA
 * U+F700-U+F8FF); pass NULL instead and let the encoder use the logical key.
 *
 * The key event does NOT take ownership of the text pointer. The caller
 * must ensure the string remains valid for the lifetime needed by the event.
 *
 * @param event The key event handle, must not be NULL
 * @param utf8 The UTF-8 text to set (or NULL for empty)
 * @param len Length of the UTF-8 text in bytes
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_utf8(WaspKeyEvent event, const char *utf8, size_t len);

/**
 * Get the UTF-8 text generated by the key event.
 *
 * The returned pointer is valid until the event is freed or the UTF-8 text is modified.
 *
 * @param event The key event handle, must not be NULL
 * @param len Pointer to store the length of the UTF-8 text in bytes (may be NULL)
 * @return The UTF-8 text (or NULL for empty)
 *
 * @ingroup key
 */
WASP_API const char *wasp_key_event_get_utf8(WaspKeyEvent event, size_t *len);

/**
 * Set the unshifted Unicode codepoint.
 *
 * @param event The key event handle, must not be NULL
 * @param codepoint The unshifted Unicode codepoint to set
 *
 * @ingroup key
 */
WASP_API void wasp_key_event_set_unshifted_codepoint(WaspKeyEvent event, uint32_t codepoint);

/**
 * Get the unshifted Unicode codepoint.
 *
 * @param event The key event handle, must not be NULL
 * @return The unshifted Unicode codepoint
 *
 * @ingroup key
 */
WASP_API uint32_t wasp_key_event_get_unshifted_codepoint(WaspKeyEvent event);

#endif /* WASP_VT_KEY_EVENT_H */
