#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

int main(void) {
  //! [vt-stream-init]
  // Create a terminal
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(NULL, &terminal, 80, 24);
  assert(result == WASP_SUCCESS);
  //! [vt-stream-init]

  //! [vt-stream-write]
  // Feed VT data into the terminal
  const char *text = "Hello, World!\r\n";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // ANSI color codes: ESC[1;32m = bold green, ESC[0m = reset
  text = "\x1b[1;32mGreen Text\x1b[0m\r\n";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Cursor positioning: ESC[1;1H = move to row 1, column 1
  text = "\x1b[1;1HTop-left corner\r\n";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Cursor movement: ESC[5B = move down 5 lines
  text = "\x1b[5B";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
  text = "Moved down!\r\n";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Erase line: ESC[2K = clear entire line
  text = "\x1b[2K";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
  text = "New content\r\n";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Multiple lines
  text = "Line A\r\nLine B\r\nLine C\r\n";
  wasp_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
  //! [vt-stream-write]

  //! [vt-stream-read]
  // Get the final terminal state as a plain string using the formatter
  WaspFormatterTerminalOptions fmt_opts =
      WASP_INIT_SIZED(WaspFormatterTerminalOptions);
  fmt_opts.emit = WASP_FORMATTER_FORMAT_PLAIN;
  fmt_opts.trim = true;

  WaspFormatter formatter;
  result = wasp_formatter_terminal_new(NULL, &formatter, terminal, fmt_opts);
  assert(result == WASP_SUCCESS);

  uint8_t *buf = NULL;
  size_t len = 0;
  result = wasp_formatter_format_alloc(formatter, NULL, &buf, &len);
  assert(result == WASP_SUCCESS);

  fwrite(buf, 1, len, stdout);
  printf("\n");

  wasp_free(NULL, buf, len);
  wasp_formatter_free(formatter);
  //! [vt-stream-read]

  wasp_terminal_free(terminal);
  return 0;
}
