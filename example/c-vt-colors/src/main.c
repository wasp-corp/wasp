#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [colors-set-defaults]
/// Set up a dark color theme with custom palette entries.
void set_color_theme(WaspTerminal terminal) {
  // Set default foreground (light gray) and background (dark)
  WaspColorRgb fg = { .r = 0xDD, .g = 0xDD, .b = 0xDD };
  WaspColorRgb bg = { .r = 0x1E, .g = 0x1E, .b = 0x2E };
  WaspColorRgb cursor = { .r = 0xF5, .g = 0xE0, .b = 0xDC };

  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_COLOR_CURSOR, &cursor);

  // Set a custom palette — start from the built-in default and override
  // the first 8 entries with a custom dark theme.
  WaspColorRgb palette[256];
  wasp_terminal_get(terminal, WASP_TERMINAL_DATA_COLOR_PALETTE, palette);

  palette[WASP_COLOR_NAMED_BLACK]   = (WaspColorRgb){ 0x45, 0x47, 0x5A };
  palette[WASP_COLOR_NAMED_RED]     = (WaspColorRgb){ 0xF3, 0x8B, 0xA8 };
  palette[WASP_COLOR_NAMED_GREEN]   = (WaspColorRgb){ 0xA6, 0xE3, 0xA1 };
  palette[WASP_COLOR_NAMED_YELLOW]  = (WaspColorRgb){ 0xF9, 0xE2, 0xAF };
  palette[WASP_COLOR_NAMED_BLUE]    = (WaspColorRgb){ 0x89, 0xB4, 0xFA };
  palette[WASP_COLOR_NAMED_MAGENTA] = (WaspColorRgb){ 0xF5, 0xC2, 0xE7 };
  palette[WASP_COLOR_NAMED_CYAN]    = (WaspColorRgb){ 0x94, 0xE2, 0xD5 };
  palette[WASP_COLOR_NAMED_WHITE]   = (WaspColorRgb){ 0xBA, 0xC2, 0xDE };

  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_COLOR_PALETTE, palette);
}
//! [colors-set-defaults]

//! [colors-read]
/// Print the effective and default values for a color, showing how
/// OSC overrides layer on top of defaults.
void print_color(WaspTerminal terminal,
                 const char* name,
                 WaspTerminalData effective_data,
                 WaspTerminalData default_data) {
  WaspColorRgb color;

  WaspResult res = wasp_terminal_get(terminal, effective_data, &color);
  if (res == WASP_SUCCESS) {
    printf("  %-12s effective: #%02X%02X%02X", name, color.r, color.g, color.b);
  } else {
    printf("  %-12s effective: (not set)", name);
  }

  res = wasp_terminal_get(terminal, default_data, &color);
  if (res == WASP_SUCCESS) {
    printf("  default: #%02X%02X%02X\n", color.r, color.g, color.b);
  } else {
    printf("  default: (not set)\n");
  }
}

void print_all_colors(WaspTerminal terminal, const char* label) {
  printf("%s:\n", label);
  print_color(terminal, "foreground",
      WASP_TERMINAL_DATA_COLOR_FOREGROUND,
      WASP_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT);
  print_color(terminal, "background",
      WASP_TERMINAL_DATA_COLOR_BACKGROUND,
      WASP_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT);
  print_color(terminal, "cursor",
      WASP_TERMINAL_DATA_COLOR_CURSOR,
      WASP_TERMINAL_DATA_COLOR_CURSOR_DEFAULT);

  // Show palette index 0 (black) as an example
  WaspColorRgb palette[256];
  wasp_terminal_get(terminal, WASP_TERMINAL_DATA_COLOR_PALETTE, palette);
  printf("  %-12s effective: #%02X%02X%02X", "palette[0]",
      palette[0].r, palette[0].g, palette[0].b);

  wasp_terminal_get(terminal, WASP_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
      palette);
  printf("  default: #%02X%02X%02X\n", palette[0].r, palette[0].g, palette[0].b);
}
//! [colors-read]

//! [colors-main]
int main() {
  // Create a terminal
  WaspTerminal terminal = NULL;
  if (wasp_terminal_new(NULL, &terminal, 80, 24) != WASP_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  // Before setting any colors, everything is unset
  print_all_colors(terminal, "Before setting defaults");

  // Set our color theme defaults
  set_color_theme(terminal);
  print_all_colors(terminal, "\nAfter setting defaults");

  // Simulate an OSC override (e.g. a program running inside the
  // terminal changes the foreground via OSC 10)
  const char* osc_fg = "\x1B]10;rgb:FF/00/00\x1B\\";
  wasp_terminal_vt_write(terminal, (const uint8_t*)osc_fg,
                            strlen(osc_fg));
  print_all_colors(terminal, "\nAfter OSC foreground override");

  // Clear the foreground default — the OSC override is still active
  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_COLOR_FOREGROUND, NULL);
  print_all_colors(terminal, "\nAfter clearing foreground default");

  wasp_terminal_free(terminal);
  return 0;
}
//! [colors-main]
