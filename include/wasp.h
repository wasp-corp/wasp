// Wasp's internal embedder API, a.k.a. "libwasp-internal".
//
// The only consumer of this API is the macOS app, and while it is fairly
// comprehensive, it is tailored to the needs of the macOS app and not designed
// for external use, hence why most functions are undocumented and some are
// macOS-specific (e.g. ones dealing with the Metal graphics API).
// 
// External embedders should instead use `libwasp-vt` or other related
// packages, which are extensively documented and designed from the ground up
// to be used in other software. Header files for which can be found in
// `include/wasp/`.
#ifndef WASP_H
#define WASP_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _MSC_VER
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#else
#include <sys/types.h>
#endif

//-------------------------------------------------------------------
// Macros

#define WASP_SUCCESS 0

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define WASP_STATIC
// before including this header to make this a no-op.
#ifndef WASP_API
#if defined(WASP_STATIC)
  #define WASP_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef WASP_BUILD_SHARED
    #define WASP_API __declspec(dllexport)
  #else
    #define WASP_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define WASP_API __attribute__((visibility("default")))
#else
  #define WASP_API
#endif
#endif

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* wasp_app_t;
typedef void* wasp_config_t;
typedef void* wasp_surface_t;
typedef void* wasp_inspector_t;

// All the types below are fully defined and must be kept in sync with
// their Zig counterparts. Any changes to these types MUST have an associated
// Zig change.
typedef enum {
  WASP_PLATFORM_INVALID,
  WASP_PLATFORM_MACOS,
  WASP_PLATFORM_IOS,
} wasp_platform_e;

typedef enum {
  WASP_CLIPBOARD_STANDARD,
  WASP_CLIPBOARD_SELECTION,
  WASP_CLIPBOARD_PRIMARY,
} wasp_clipboard_e;

// One representation of clipboard contents. The data is binary-safe with
// an explicit length; it is not necessarily null-terminated.
typedef struct {
  const char *mime;
  const char *data;
  size_t len;
} wasp_clipboard_content_s;

// The payload for completing a clipboard read request. See
// wasp_surface_complete_clipboard_request.
typedef struct {
  const wasp_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  bool confirmed;
  bool remember;
} wasp_clipboard_complete_s;

// The payload of a clipboard read confirmation request: the would-be
// completion contents plus the information shown in the permission
// prompt. See wasp_runtime_confirm_read_clipboard_cb.
typedef struct {
  const wasp_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  const char *name;
  bool can_remember;
} wasp_clipboard_confirm_s;

typedef enum {
  WASP_CLIPBOARD_REQUEST_PASTE,
  WASP_CLIPBOARD_REQUEST_OSC_52_READ,
  WASP_CLIPBOARD_REQUEST_OSC_52_WRITE,
  WASP_CLIPBOARD_REQUEST_KITTY_READ,
  WASP_CLIPBOARD_REQUEST_KITTY_WRITE,
  WASP_CLIPBOARD_REQUEST_LIST,
} wasp_clipboard_request_e;

// apprt.ClipboardReadResult
typedef enum {
  WASP_CLIPBOARD_READ_STARTED,
  WASP_CLIPBOARD_READ_UNAVAILABLE,
  WASP_CLIPBOARD_READ_UNSUPPORTED,
} wasp_clipboard_read_result_e;

typedef enum {
  WASP_MOUSE_RELEASE,
  WASP_MOUSE_PRESS,
} wasp_input_mouse_state_e;

typedef enum {
  WASP_MOUSE_UNKNOWN,
  WASP_MOUSE_LEFT,
  WASP_MOUSE_RIGHT,
  WASP_MOUSE_MIDDLE,
  WASP_MOUSE_FOUR,
  WASP_MOUSE_FIVE,
  WASP_MOUSE_SIX,
  WASP_MOUSE_SEVEN,
  WASP_MOUSE_EIGHT,
  WASP_MOUSE_NINE,
  WASP_MOUSE_TEN,
  WASP_MOUSE_ELEVEN,
} wasp_input_mouse_button_e;

typedef enum {
  WASP_MOUSE_MOMENTUM_NONE,
  WASP_MOUSE_MOMENTUM_BEGAN,
  WASP_MOUSE_MOMENTUM_STATIONARY,
  WASP_MOUSE_MOMENTUM_CHANGED,
  WASP_MOUSE_MOMENTUM_ENDED,
  WASP_MOUSE_MOMENTUM_CANCELLED,
  WASP_MOUSE_MOMENTUM_MAY_BEGIN,
} wasp_input_mouse_momentum_e;

typedef enum {
  WASP_COLOR_SCHEME_LIGHT = 0,
  WASP_COLOR_SCHEME_DARK = 1,
} wasp_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int wasp_input_scroll_mods_t;

typedef enum {
  WASP_MODS_NONE = 0,
  WASP_MODS_SHIFT = 1 << 0,
  WASP_MODS_CTRL = 1 << 1,
  WASP_MODS_ALT = 1 << 2,
  WASP_MODS_SUPER = 1 << 3,
  WASP_MODS_CAPS = 1 << 4,
  WASP_MODS_NUM = 1 << 5,
  WASP_MODS_SHIFT_RIGHT = 1 << 6,
  WASP_MODS_CTRL_RIGHT = 1 << 7,
  WASP_MODS_ALT_RIGHT = 1 << 8,
  WASP_MODS_SUPER_RIGHT = 1 << 9,
} wasp_input_mods_e;

typedef enum {
  WASP_BINDING_FLAGS_CONSUMED = 1 << 0,
  WASP_BINDING_FLAGS_ALL = 1 << 1,
  WASP_BINDING_FLAGS_GLOBAL = 1 << 2,
  WASP_BINDING_FLAGS_PERFORMABLE = 1 << 3,
} wasp_binding_flags_e;

typedef enum {
  WASP_ACTION_RELEASE,
  WASP_ACTION_PRESS,
  WASP_ACTION_REPEAT,
} wasp_input_action_e;

// Based on: https://www.w3.org/TR/uievents-code/
typedef enum {
  WASP_KEY_UNIDENTIFIED,

  // "Writing System Keys" § 3.1.1
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

  // "Functional Keys" § 3.1.2
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

  // "Control Pad Section" § 3.2
  WASP_KEY_DELETE,
  WASP_KEY_END,
  WASP_KEY_HELP,
  WASP_KEY_HOME,
  WASP_KEY_INSERT,
  WASP_KEY_PAGE_DOWN,
  WASP_KEY_PAGE_UP,

  // "Arrow Pad Section" § 3.3
  WASP_KEY_ARROW_DOWN,
  WASP_KEY_ARROW_LEFT,
  WASP_KEY_ARROW_RIGHT,
  WASP_KEY_ARROW_UP,

  // "Numpad Section" § 3.4
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

  // "Function Section" § 3.5
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

  // "Media Keys" § 3.6
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

  // "Legacy, Non-standard, and Special Keys" § 3.7
  WASP_KEY_COPY,
  WASP_KEY_CUT,
  WASP_KEY_PASTE,
} wasp_input_key_e;

typedef struct {
  wasp_input_action_e action;
  wasp_input_mods_e mods;
  wasp_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} wasp_input_key_s;

typedef enum {
  WASP_TRIGGER_PHYSICAL,
  WASP_TRIGGER_UNICODE,
  WASP_TRIGGER_CATCH_ALL,
} wasp_input_trigger_tag_e;

typedef union {
  wasp_input_key_e physical;
  uint32_t unicode;
  // catch_all has no payload
} wasp_input_trigger_key_u;

typedef struct {
  wasp_input_trigger_tag_e tag;
  wasp_input_trigger_key_u key;
  wasp_input_mods_e mods;
} wasp_input_trigger_s;

typedef struct {
  const char* action_key;
  const char* action;
  const char* title;
  const char* description;
} wasp_command_s;

typedef enum {
  WASP_BUILD_MODE_DEBUG,
  WASP_BUILD_MODE_RELEASE_SAFE,
  WASP_BUILD_MODE_RELEASE_FAST,
  WASP_BUILD_MODE_RELEASE_SMALL,
} wasp_build_mode_e;

typedef struct {
  wasp_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} wasp_info_s;

typedef struct {
  const char* message;
} wasp_diagnostic_s;

typedef struct {
  const char* ptr;
  uintptr_t len;
  bool sentinel;
} wasp_string_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} wasp_text_s;

typedef enum {
  WASP_POINT_ACTIVE,
  WASP_POINT_VIEWPORT,
  WASP_POINT_SCREEN,
  WASP_POINT_SURFACE,
} wasp_point_tag_e;

typedef enum {
  WASP_POINT_COORD_EXACT,
  WASP_POINT_COORD_TOP_LEFT,
  WASP_POINT_COORD_BOTTOM_RIGHT,
} wasp_point_coord_e;

typedef struct {
  wasp_point_tag_e tag;
  wasp_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} wasp_point_s;

typedef struct {
  wasp_point_s top_left;
  wasp_point_s bottom_right;
  bool rectangle;
} wasp_selection_s;

typedef struct {
  const char* key;
  const char* value;
} wasp_env_var_s;

typedef struct {
  void* nsview;
} wasp_platform_macos_s;

typedef struct {
  void* uiview;
} wasp_platform_ios_s;

typedef union {
  wasp_platform_macos_s macos;
  wasp_platform_ios_s ios;
} wasp_platform_u;

typedef enum {
  WASP_SURFACE_CONTEXT_WINDOW = 0,
  WASP_SURFACE_CONTEXT_TAB = 1,
  WASP_SURFACE_CONTEXT_SPLIT = 2,
} wasp_surface_context_e;

typedef struct {
  wasp_platform_e platform_tag;
  wasp_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  wasp_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  wasp_surface_context_e context;
} wasp_surface_config_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} wasp_surface_size_s;

// Config types

// config.Path
typedef struct {
  const char* path;
  bool optional;
} wasp_config_path_s;

// config.Color
typedef struct {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} wasp_config_color_s;

// config.ColorList
typedef struct {
  const wasp_config_color_s* colors;
  size_t len;
} wasp_config_color_list_s;

// config.RepeatableCommand
typedef struct {
  const wasp_command_s* commands;
  size_t len;
} wasp_config_command_list_s;

// config.Palette
typedef struct {
  wasp_config_color_s colors[256];
} wasp_config_palette_s;

// config.QuickTerminalSize
typedef enum {
  WASP_QUICK_TERMINAL_SIZE_NONE,
  WASP_QUICK_TERMINAL_SIZE_PERCENTAGE,
  WASP_QUICK_TERMINAL_SIZE_PIXELS,
} wasp_quick_terminal_size_tag_e;

typedef union {
  float percentage;
  uint32_t pixels;
} wasp_quick_terminal_size_value_u;

typedef struct {
  wasp_quick_terminal_size_tag_e tag;
  wasp_quick_terminal_size_value_u value;
} wasp_quick_terminal_size_s;

typedef struct {
  wasp_quick_terminal_size_s primary;
  wasp_quick_terminal_size_s secondary;
} wasp_config_quick_terminal_size_s;

// config.Fullscreen
typedef enum {
  WASP_CONFIG_FULLSCREEN_FALSE,
  WASP_CONFIG_FULLSCREEN_TRUE,
  WASP_CONFIG_FULLSCREEN_NON_NATIVE,
  WASP_CONFIG_FULLSCREEN_NON_NATIVE_VISIBLE_MENU,
  WASP_CONFIG_FULLSCREEN_NON_NATIVE_PADDED_NOTCH,
} wasp_config_fullscreen_e;

// apprt.Target.Key
typedef enum {
  WASP_TARGET_APP,
  WASP_TARGET_SURFACE,
} wasp_target_tag_e;

typedef union {
  wasp_surface_t surface;
} wasp_target_u;

typedef struct {
  wasp_target_tag_e tag;
  wasp_target_u target;
} wasp_target_s;

// apprt.action.SplitDirection
typedef enum {
  WASP_SPLIT_DIRECTION_RIGHT,
  WASP_SPLIT_DIRECTION_DOWN,
  WASP_SPLIT_DIRECTION_LEFT,
  WASP_SPLIT_DIRECTION_UP,
} wasp_action_split_direction_e;

// apprt.action.GotoSplit
typedef enum {
  WASP_GOTO_SPLIT_PREVIOUS,
  WASP_GOTO_SPLIT_NEXT,
  WASP_GOTO_SPLIT_UP,
  WASP_GOTO_SPLIT_LEFT,
  WASP_GOTO_SPLIT_DOWN,
  WASP_GOTO_SPLIT_RIGHT,
} wasp_action_goto_split_e;

// apprt.action.GotoWindow
typedef enum {
  WASP_GOTO_WINDOW_PREVIOUS,
  WASP_GOTO_WINDOW_NEXT,
} wasp_action_goto_window_e;

// apprt.action.ResizeSplit.Direction
typedef enum {
  WASP_RESIZE_SPLIT_UP,
  WASP_RESIZE_SPLIT_DOWN,
  WASP_RESIZE_SPLIT_LEFT,
  WASP_RESIZE_SPLIT_RIGHT,
} wasp_action_resize_split_direction_e;

// apprt.action.ResizeSplit
typedef struct {
  uint16_t amount;
  wasp_action_resize_split_direction_e direction;
} wasp_action_resize_split_s;

// apprt.action.MoveTab
typedef struct {
  ssize_t amount;
} wasp_action_move_tab_s;

// apprt.action.GotoTab
typedef enum {
  WASP_GOTO_TAB_PREVIOUS = -1,
  WASP_GOTO_TAB_NEXT = -2,
  WASP_GOTO_TAB_LAST = -3,
} wasp_action_goto_tab_e;

// apprt.action.Fullscreen
typedef enum {
  WASP_FULLSCREEN_NATIVE,
  WASP_FULLSCREEN_MACOS_NON_NATIVE,
  WASP_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU,
  WASP_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH,
} wasp_action_fullscreen_e;

// apprt.action.FloatWindow
typedef enum {
  WASP_FLOAT_WINDOW_ON,
  WASP_FLOAT_WINDOW_OFF,
  WASP_FLOAT_WINDOW_TOGGLE,
} wasp_action_float_window_e;

// apprt.action.SecureInput
typedef enum {
  WASP_SECURE_INPUT_ON,
  WASP_SECURE_INPUT_OFF,
  WASP_SECURE_INPUT_TOGGLE,
} wasp_action_secure_input_e;

// apprt.action.Inspector
typedef enum {
  WASP_INSPECTOR_TOGGLE,
  WASP_INSPECTOR_SHOW,
  WASP_INSPECTOR_HIDE,
} wasp_action_inspector_e;

// apprt.action.ExportTerminalIO.C
typedef struct {
  const char* contents;
  size_t len;
} wasp_action_export_terminal_io_s;

// apprt.action.QuitTimer
typedef enum {
  WASP_QUIT_TIMER_START,
  WASP_QUIT_TIMER_STOP,
} wasp_action_quit_timer_e;

// apprt.action.Readonly
typedef enum {
  WASP_READONLY_OFF,
  WASP_READONLY_ON,
} wasp_action_readonly_e;

// apprt.action.DesktopNotification.C
typedef struct {
  const char* title;
  const char* body;
} wasp_action_desktop_notification_s;

// apprt.action.SetTitle.C
typedef struct {
  const char* title;
} wasp_action_set_title_s;

// apprt.action.PromptTitle
typedef enum {
  WASP_PROMPT_TITLE_SURFACE,
  WASP_PROMPT_TITLE_TAB,
  WASP_PROMPT_TITLE_WINDOW,
} wasp_action_prompt_title_e;

// apprt.action.Pwd.C
typedef struct {
  const char* pwd;
} wasp_action_pwd_s;

// apprt.action.OpenConfig
typedef enum {
  // Open the config in the OS default editor.
  WASP_ACTION_OPEN_CONFIG_OS_OPEN,
  // Open the config in a new window using $EDITOR or $VISUAL
  WASP_ACTION_OPEN_CONFIG_NEW_WINDOW,
} wasp_action_open_config_e;

// terminal.MouseShape
typedef enum {
  WASP_MOUSE_SHAPE_DEFAULT,
  WASP_MOUSE_SHAPE_CONTEXT_MENU,
  WASP_MOUSE_SHAPE_HELP,
  WASP_MOUSE_SHAPE_POINTER,
  WASP_MOUSE_SHAPE_PROGRESS,
  WASP_MOUSE_SHAPE_WAIT,
  WASP_MOUSE_SHAPE_CELL,
  WASP_MOUSE_SHAPE_CROSSHAIR,
  WASP_MOUSE_SHAPE_TEXT,
  WASP_MOUSE_SHAPE_VERTICAL_TEXT,
  WASP_MOUSE_SHAPE_ALIAS,
  WASP_MOUSE_SHAPE_COPY,
  WASP_MOUSE_SHAPE_MOVE,
  WASP_MOUSE_SHAPE_NO_DROP,
  WASP_MOUSE_SHAPE_NOT_ALLOWED,
  WASP_MOUSE_SHAPE_GRAB,
  WASP_MOUSE_SHAPE_GRABBING,
  WASP_MOUSE_SHAPE_ALL_SCROLL,
  WASP_MOUSE_SHAPE_COL_RESIZE,
  WASP_MOUSE_SHAPE_ROW_RESIZE,
  WASP_MOUSE_SHAPE_N_RESIZE,
  WASP_MOUSE_SHAPE_E_RESIZE,
  WASP_MOUSE_SHAPE_S_RESIZE,
  WASP_MOUSE_SHAPE_W_RESIZE,
  WASP_MOUSE_SHAPE_NE_RESIZE,
  WASP_MOUSE_SHAPE_NW_RESIZE,
  WASP_MOUSE_SHAPE_SE_RESIZE,
  WASP_MOUSE_SHAPE_SW_RESIZE,
  WASP_MOUSE_SHAPE_EW_RESIZE,
  WASP_MOUSE_SHAPE_NS_RESIZE,
  WASP_MOUSE_SHAPE_NESW_RESIZE,
  WASP_MOUSE_SHAPE_NWSE_RESIZE,
  WASP_MOUSE_SHAPE_ZOOM_IN,
  WASP_MOUSE_SHAPE_ZOOM_OUT,
} wasp_action_mouse_shape_e;

// apprt.action.MouseVisibility
typedef enum {
  WASP_MOUSE_VISIBLE,
  WASP_MOUSE_HIDDEN,
} wasp_action_mouse_visibility_e;

// apprt.action.MouseOverLink
typedef struct {
  const char* url;
  size_t len;
} wasp_action_mouse_over_link_s;

// apprt.action.SizeLimit
typedef struct {
  uint32_t min_width;
  uint32_t min_height;
  uint32_t max_width;
  uint32_t max_height;
} wasp_action_size_limit_s;

// apprt.action.InitialSize
typedef struct {
  uint32_t width;
  uint32_t height;
} wasp_action_initial_size_s;

// apprt.action.ResizeWindow
typedef struct {
  uint32_t width;
  uint32_t height;
} wasp_action_resize_window_s;

// apprt.action.CellSize
typedef struct {
  uint32_t width;
  uint32_t height;
} wasp_action_cell_size_s;

// renderer.Health
typedef enum {
  WASP_RENDERER_HEALTH_HEALTHY,
  WASP_RENDERER_HEALTH_UNHEALTHY,
} wasp_action_renderer_health_e;

// apprt.action.KeySequence
typedef struct {
  bool active;
  wasp_input_trigger_s trigger;
} wasp_action_key_sequence_s;

// apprt.action.KeyTable.Tag
typedef enum {
  WASP_KEY_TABLE_ACTIVATE,
  WASP_KEY_TABLE_DEACTIVATE,
  WASP_KEY_TABLE_DEACTIVATE_ALL,
} wasp_action_key_table_tag_e;

// apprt.action.KeyTable.CValue
typedef union {
  struct {
    const char *name;
    size_t len;
  } activate;
} wasp_action_key_table_u;

// apprt.action.KeyTable.C
typedef struct {
  wasp_action_key_table_tag_e tag;
  wasp_action_key_table_u value;
} wasp_action_key_table_s;

// apprt.action.ColorKind
typedef enum {
  WASP_ACTION_COLOR_KIND_FOREGROUND = -1,
  WASP_ACTION_COLOR_KIND_BACKGROUND = -2,
  WASP_ACTION_COLOR_KIND_CURSOR = -3,
} wasp_action_color_kind_e;

// apprt.action.ColorChange
typedef struct {
  wasp_action_color_kind_e kind;
  uint8_t r;
  uint8_t g;
  uint8_t b;
} wasp_action_color_change_s;

// apprt.action.ConfigChange
typedef struct {
  wasp_config_t config;
} wasp_action_config_change_s;

// apprt.action.ReloadConfig
typedef struct {
  bool soft;
} wasp_action_reload_config_s;

// apprt.action.OpenUrlKind
typedef enum {
  WASP_ACTION_OPEN_URL_KIND_UNKNOWN,
  WASP_ACTION_OPEN_URL_KIND_TEXT,
  WASP_ACTION_OPEN_URL_KIND_HTML,
  WASP_ACTION_OPEN_URL_KIND_OSC8,
} wasp_action_open_url_kind_e;

// apprt.action.OpenUrl.C
typedef struct {
  wasp_action_open_url_kind_e kind;
  const char* url;
  uintptr_t len;
} wasp_action_open_url_s;

// apprt.action.CloseTabMode
typedef enum {
  WASP_ACTION_CLOSE_TAB_MODE_THIS,
  WASP_ACTION_CLOSE_TAB_MODE_OTHER,
  WASP_ACTION_CLOSE_TAB_MODE_RIGHT,
} wasp_action_close_tab_mode_e;

// apprt.surface.Message.ChildExited
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} wasp_surface_message_childexited_s;

// terminal.osc.Command.ProgressReport.State
typedef enum {
  WASP_PROGRESS_STATE_REMOVE,
  WASP_PROGRESS_STATE_SET,
  WASP_PROGRESS_STATE_ERROR,
  WASP_PROGRESS_STATE_INDETERMINATE,
  WASP_PROGRESS_STATE_PAUSE,
} wasp_action_progress_report_state_e;

// terminal.osc.Command.ProgressReport.C
typedef struct {
  wasp_action_progress_report_state_e state;
  // -1 if no progress was reported, otherwise 0-100 indicating percent
  // completeness.
  int8_t progress;
} wasp_action_progress_report_s;

// apprt.action.CommandFinished.C
typedef struct {
  // -1 if no exit code was reported, otherwise 0-255
  int16_t exit_code;
  // number of nanoseconds that command was running for
  uint64_t duration;
} wasp_action_command_finished_s;

// apprt.action.StartSearch.C
typedef struct {
  const char* needle;
} wasp_action_start_search_s;

// apprt.action.SearchTotal
typedef struct {
  ssize_t total;
} wasp_action_search_total_s;

// apprt.action.SearchSelected
typedef struct {
  ssize_t selected;
} wasp_action_search_selected_s;

// terminal.Scrollbar
typedef struct {
  uint64_t total;
  uint64_t offset;
  uint64_t len;
} wasp_action_scrollbar_s;

// apprt.Action.Key
typedef enum {
  WASP_ACTION_QUIT,
  WASP_ACTION_NEW_WINDOW,
  WASP_ACTION_NEW_TAB,
  WASP_ACTION_CLOSE_TAB,
  WASP_ACTION_NEW_SPLIT,
  WASP_ACTION_CLOSE_ALL_WINDOWS,
  WASP_ACTION_TOGGLE_MAXIMIZE,
  WASP_ACTION_TOGGLE_FULLSCREEN,
  WASP_ACTION_TOGGLE_TAB_OVERVIEW,
  WASP_ACTION_TOGGLE_WINDOW_DECORATIONS,
  WASP_ACTION_TOGGLE_QUICK_TERMINAL,
  WASP_ACTION_TOGGLE_COMMAND_PALETTE,
  WASP_ACTION_TOGGLE_VISIBILITY,
  WASP_ACTION_TOGGLE_BACKGROUND_OPACITY,
  WASP_ACTION_MOVE_TAB,
  WASP_ACTION_GOTO_TAB,
  WASP_ACTION_GOTO_SPLIT,
  WASP_ACTION_GOTO_WINDOW,
  WASP_ACTION_RESIZE_SPLIT,
  WASP_ACTION_EQUALIZE_SPLITS,
  WASP_ACTION_TOGGLE_SPLIT_ZOOM,
  WASP_ACTION_PRESENT_TERMINAL,
  WASP_ACTION_SIZE_LIMIT,
  WASP_ACTION_RESET_WINDOW_SIZE,
  WASP_ACTION_INITIAL_SIZE,
  WASP_ACTION_CELL_SIZE,
  WASP_ACTION_SCROLLBAR,
  WASP_ACTION_RENDER,
  WASP_ACTION_INSPECTOR,
  WASP_ACTION_SHOW_GTK_INSPECTOR,
  WASP_ACTION_RENDER_INSPECTOR,
  WASP_ACTION_EXPORT_TERMINAL_IO,
  WASP_ACTION_DESKTOP_NOTIFICATION,
  WASP_ACTION_SET_TITLE,
  WASP_ACTION_SET_TAB_TITLE,
  WASP_ACTION_SET_WINDOW_TITLE,
  WASP_ACTION_PROMPT_TITLE,
  WASP_ACTION_PWD,
  WASP_ACTION_MOUSE_SHAPE,
  WASP_ACTION_MOUSE_VISIBILITY,
  WASP_ACTION_MOUSE_OVER_LINK,
  WASP_ACTION_RENDERER_HEALTH,
  WASP_ACTION_OPEN_CONFIG,
  WASP_ACTION_QUIT_TIMER,
  WASP_ACTION_FLOAT_WINDOW,
  WASP_ACTION_SECURE_INPUT,
  WASP_ACTION_KEY_SEQUENCE,
  WASP_ACTION_KEY_TABLE,
  WASP_ACTION_COLOR_CHANGE,
  WASP_ACTION_RELOAD_CONFIG,
  WASP_ACTION_CONFIG_CHANGE,
  WASP_ACTION_CLOSE_WINDOW,
  WASP_ACTION_RING_BELL,
  WASP_ACTION_SELECTION_CHANGED,
  WASP_ACTION_UNDO,
  WASP_ACTION_REDO,
  WASP_ACTION_CHECK_FOR_UPDATES,
  WASP_ACTION_OPEN_URL,
  WASP_ACTION_SHOW_CHILD_EXITED,
  WASP_ACTION_PROGRESS_REPORT,
  WASP_ACTION_SHOW_ON_SCREEN_KEYBOARD,
  WASP_ACTION_COMMAND_FINISHED,
  WASP_ACTION_START_SEARCH,
  WASP_ACTION_END_SEARCH,
  WASP_ACTION_SEARCH_TOTAL,
  WASP_ACTION_SEARCH_SELECTED,
  WASP_ACTION_READONLY,
  WASP_ACTION_COPY_TITLE_TO_CLIPBOARD,
  WASP_ACTION_MOVE_TAB_TO_NEW_WINDOW,
  WASP_ACTION_RESIZE_WINDOW,
} wasp_action_tag_e;

typedef union {
  wasp_action_split_direction_e new_split;
  wasp_action_fullscreen_e toggle_fullscreen;
  wasp_action_move_tab_s move_tab;
  wasp_action_goto_tab_e goto_tab;
  wasp_action_goto_split_e goto_split;
  wasp_action_goto_window_e goto_window;
  wasp_action_resize_split_s resize_split;
  wasp_action_size_limit_s size_limit;
  wasp_action_initial_size_s initial_size;
  wasp_action_resize_window_s resize_window;
  wasp_action_cell_size_s cell_size;
  wasp_action_scrollbar_s scrollbar;
  wasp_action_inspector_e inspector;
  wasp_action_export_terminal_io_s export_terminal_io;
  wasp_action_desktop_notification_s desktop_notification;
  wasp_action_set_title_s set_title;
  wasp_action_set_title_s set_tab_title;
  wasp_action_prompt_title_e prompt_title;
  wasp_action_pwd_s pwd;
  wasp_action_mouse_shape_e mouse_shape;
  wasp_action_mouse_visibility_e mouse_visibility;
  wasp_action_mouse_over_link_s mouse_over_link;
  wasp_action_renderer_health_e renderer_health;
  wasp_action_quit_timer_e quit_timer;
  wasp_action_float_window_e float_window;
  wasp_action_secure_input_e secure_input;
  wasp_action_key_sequence_s key_sequence;
  wasp_action_key_table_s key_table;
  wasp_action_color_change_s color_change;
  wasp_action_reload_config_s reload_config;
  wasp_action_config_change_s config_change;
  wasp_action_open_url_s open_url;
  wasp_action_close_tab_mode_e close_tab_mode;
  wasp_surface_message_childexited_s child_exited;
  wasp_action_progress_report_s progress_report;
  wasp_action_command_finished_s command_finished;
  wasp_action_start_search_s start_search;
  wasp_action_search_total_s search_total;
  wasp_action_search_selected_s search_selected;
  wasp_action_readonly_e readonly;
  wasp_action_open_config_e open_config;
} wasp_action_u;

typedef struct {
  wasp_action_tag_e tag;
  wasp_action_u action;
} wasp_action_s;

typedef void (*wasp_runtime_wakeup_cb)(void*);
typedef wasp_clipboard_read_result_e (*wasp_runtime_read_clipboard_cb)(
    void*,
    wasp_clipboard_e,
    void*,
    const char* const*,
    size_t,
    bool);
typedef void (*wasp_runtime_confirm_read_clipboard_cb)(
    void*,
    const wasp_clipboard_confirm_s*,
    void*,
    wasp_clipboard_request_e);
typedef void (*wasp_runtime_write_clipboard_cb)(void*,
                                                   wasp_clipboard_e,
                                                   const wasp_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*wasp_runtime_close_surface_cb)(void*, bool);
typedef bool (*wasp_runtime_action_cb)(wasp_app_t,
                                          wasp_target_s,
                                          wasp_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  wasp_runtime_wakeup_cb wakeup_cb;
  wasp_runtime_action_cb action_cb;
  wasp_runtime_read_clipboard_cb read_clipboard_cb;
  wasp_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  wasp_runtime_write_clipboard_cb write_clipboard_cb;
  wasp_runtime_close_surface_cb close_surface_cb;
} wasp_runtime_config_s;

// apprt.ipc.Target.Key
typedef enum {
  WASP_IPC_TARGET_CLASS,
  WASP_IPC_TARGET_DETECT,
} wasp_ipc_target_tag_e;

typedef union {
  char *klass;
} wasp_ipc_target_u;

typedef struct {
  wasp_ipc_target_tag_e tag;
  wasp_ipc_target_u target;
} chostty_ipc_target_s;

// apprt.ipc.Action.NewWindow
typedef struct {
  // This should be a null terminated list of strings.
  const char **arguments;
} wasp_ipc_action_new_window_s;

typedef union {
  wasp_ipc_action_new_window_s new_window;
} wasp_ipc_action_u;

// apprt.ipc.Action.Key
typedef enum {
  WASP_IPC_ACTION_NEW_WINDOW,
  WASP_IPC_ACTION_NEW_TAB,
  WASP_IPC_ACTION_TOGGLE_QUICK_TERMINAL,
} wasp_ipc_action_tag_e;

//-------------------------------------------------------------------
// Published API

WASP_API int wasp_init(uintptr_t, char**);
WASP_API void wasp_cli_try_action(void);
WASP_API wasp_info_s wasp_info(void);
WASP_API const char* wasp_translate(const char*);
WASP_API void wasp_string_free(wasp_string_s);

WASP_API wasp_config_t wasp_config_new();
WASP_API void wasp_config_free(wasp_config_t);
WASP_API wasp_config_t wasp_config_clone(wasp_config_t);
WASP_API void wasp_config_load_cli_args(wasp_config_t);
WASP_API void wasp_config_load_file(wasp_config_t, const char*);
WASP_API void wasp_config_load_default_files(wasp_config_t);
WASP_API void wasp_config_load_recursive_files(wasp_config_t);
WASP_API void wasp_config_finalize(wasp_config_t);
WASP_API bool wasp_config_get(wasp_config_t, void*, const char*, uintptr_t);
WASP_API wasp_input_trigger_s wasp_config_trigger(wasp_config_t,
                                                              const char*,
                                                              uintptr_t);
WASP_API bool wasp_config_key_is_binding(wasp_config_t, wasp_input_key_s);
WASP_API uint32_t wasp_config_diagnostics_count(wasp_config_t);
WASP_API wasp_diagnostic_s wasp_config_get_diagnostic(wasp_config_t, uint32_t);
WASP_API wasp_string_s wasp_config_open_path(void);

WASP_API wasp_app_t wasp_app_new(const wasp_runtime_config_s*,
                                             wasp_config_t);
WASP_API void wasp_app_free(wasp_app_t);
WASP_API void wasp_app_tick(wasp_app_t);
WASP_API void* wasp_app_userdata(wasp_app_t);
WASP_API void wasp_app_set_focus(wasp_app_t, bool);
WASP_API bool wasp_app_key(wasp_app_t, wasp_input_key_s);
WASP_API void wasp_app_keyboard_changed(wasp_app_t);
WASP_API void wasp_app_open_config(wasp_app_t);
WASP_API void wasp_app_update_config(wasp_app_t, wasp_config_t);
WASP_API bool wasp_app_needs_confirm_quit(wasp_app_t);
WASP_API bool wasp_app_has_global_keybinds(wasp_app_t);
WASP_API void wasp_app_set_color_scheme(wasp_app_t, wasp_color_scheme_e);

WASP_API wasp_surface_config_s wasp_surface_config_new();

WASP_API wasp_surface_t wasp_surface_new(wasp_app_t,
                                                     const wasp_surface_config_s*);
WASP_API void wasp_surface_free(wasp_surface_t);
WASP_API void* wasp_surface_userdata(wasp_surface_t);
WASP_API wasp_app_t wasp_surface_app(wasp_surface_t);
WASP_API wasp_surface_config_s wasp_surface_inherited_config(wasp_surface_t, wasp_surface_context_e);
WASP_API void wasp_surface_update_config(wasp_surface_t, wasp_config_t);
WASP_API bool wasp_surface_needs_confirm_quit(wasp_surface_t);
WASP_API bool wasp_surface_process_exited(wasp_surface_t);
WASP_API void wasp_surface_refresh(wasp_surface_t);
WASP_API void wasp_surface_draw(wasp_surface_t);
WASP_API void wasp_surface_set_content_scale(wasp_surface_t, double, double);
WASP_API void wasp_surface_set_focus(wasp_surface_t, bool);
WASP_API void wasp_surface_set_occlusion(wasp_surface_t, bool);
WASP_API void wasp_surface_set_size(wasp_surface_t, uint32_t, uint32_t);
WASP_API wasp_surface_size_s wasp_surface_size(wasp_surface_t);
WASP_API uint64_t wasp_surface_foreground_pid(wasp_surface_t);
WASP_API wasp_string_s wasp_surface_tty_name(wasp_surface_t);
WASP_API void wasp_surface_set_color_scheme(wasp_surface_t,
                                                     wasp_color_scheme_e);
WASP_API wasp_input_mods_e wasp_surface_key_translation_mods(wasp_surface_t,
                                                                         wasp_input_mods_e);
WASP_API bool wasp_surface_key(wasp_surface_t, wasp_input_key_s);
WASP_API bool wasp_surface_key_is_binding(wasp_surface_t,
                                                   wasp_input_key_s,
                                                   wasp_binding_flags_e*);
WASP_API void wasp_surface_text(wasp_surface_t, const char*, uintptr_t);
WASP_API void wasp_surface_paste_text(wasp_surface_t, const char*, uintptr_t);
WASP_API void wasp_surface_preedit(wasp_surface_t, const char*, uintptr_t);
WASP_API bool wasp_surface_mouse_captured(wasp_surface_t);
WASP_API bool wasp_surface_mouse_button(wasp_surface_t,
                                                 wasp_input_mouse_state_e,
                                                 wasp_input_mouse_button_e,
                                                 wasp_input_mods_e);
WASP_API void wasp_surface_mouse_pos(wasp_surface_t,
                                              double,
                                              double,
                                              wasp_input_mods_e);
WASP_API void wasp_surface_mouse_scroll(wasp_surface_t,
                                                 double,
                                                 double,
                                                 wasp_input_scroll_mods_t);
WASP_API void wasp_surface_mouse_pressure(wasp_surface_t, uint32_t, double);
WASP_API void wasp_surface_ime_point(wasp_surface_t, double*, double*, double*, double*);
WASP_API void wasp_surface_request_close(wasp_surface_t);
WASP_API void wasp_surface_split(wasp_surface_t, wasp_action_split_direction_e);
WASP_API void wasp_surface_split_focus(wasp_surface_t,
                                                wasp_action_goto_split_e);
WASP_API void wasp_surface_split_resize(wasp_surface_t,
                                                 wasp_action_resize_split_direction_e,
                                                 uint16_t);
WASP_API void wasp_surface_split_equalize(wasp_surface_t);
WASP_API bool wasp_surface_binding_action(wasp_surface_t, const char*, uintptr_t);
WASP_API void wasp_surface_complete_clipboard_request(
    wasp_surface_t,
    const wasp_clipboard_complete_s*,
    void*);
WASP_API void wasp_surface_deny_clipboard_request(wasp_surface_t,
                                                           void*);
WASP_API bool wasp_surface_has_selection(wasp_surface_t);
WASP_API bool wasp_surface_read_selection(wasp_surface_t, wasp_text_s*);
WASP_API bool wasp_surface_read_text(wasp_surface_t,
                                              wasp_selection_s,
                                              wasp_text_s*);
WASP_API void wasp_surface_free_text(wasp_surface_t, wasp_text_s*);

#ifdef __APPLE__
WASP_API void wasp_surface_set_display_id(wasp_surface_t, uint32_t);
WASP_API void* wasp_surface_quicklook_font(wasp_surface_t);
WASP_API bool wasp_surface_quicklook_word(wasp_surface_t, wasp_text_s*);
#endif

WASP_API wasp_inspector_t wasp_surface_inspector(wasp_surface_t);
WASP_API void wasp_inspector_free(wasp_surface_t);
WASP_API void wasp_inspector_set_focus(wasp_inspector_t, bool);
WASP_API void wasp_inspector_set_content_scale(wasp_inspector_t, double, double);
WASP_API void wasp_inspector_set_size(wasp_inspector_t, uint32_t, uint32_t);
WASP_API void wasp_inspector_mouse_button(wasp_inspector_t,
                                                   wasp_input_mouse_state_e,
                                                   wasp_input_mouse_button_e,
                                                   wasp_input_mods_e);
WASP_API void wasp_inspector_mouse_pos(wasp_inspector_t, double, double);
WASP_API void wasp_inspector_mouse_scroll(wasp_inspector_t,
                                                   double,
                                                   double,
                                                   wasp_input_scroll_mods_t);
WASP_API void wasp_inspector_key(wasp_inspector_t,
                                          wasp_input_action_e,
                                          wasp_input_key_e,
                                          wasp_input_mods_e);
WASP_API void wasp_inspector_text(wasp_inspector_t, const char*);

#ifdef __APPLE__
WASP_API bool wasp_inspector_metal_init(wasp_inspector_t, void*);
WASP_API void wasp_inspector_metal_render(wasp_inspector_t, void*, void*);
WASP_API bool wasp_inspector_metal_shutdown(wasp_inspector_t);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
WASP_API void wasp_set_window_background_blur(wasp_app_t, void*);

// Benchmark API, if available.
WASP_API bool wasp_benchmark_cli(const char*, const char*);

#ifdef __cplusplus
}
#endif

#endif /* WASP_H */
