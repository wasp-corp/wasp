#include <cassert>
#include <cstdio>
#include <cstring>
#include <wasp/vt.h>

int main() {
  // Create a terminal
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(nullptr, &terminal, 80, 24);
  assert(result == WASP_SUCCESS);

  // Feed VT data into the terminal
  const char *text = "Hello from C++!\r\n";
  wasp_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  text = "\x1b[1;32mGreen Text\x1b[0m\r\n";
  wasp_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  text = "\x1b[1;1HTop-left corner\r\n";
  wasp_terminal_vt_write(terminal, reinterpret_cast<const uint8_t *>(text), std::strlen(text));

  // Get the final terminal state as a plain string
  WaspFormatterTerminalOptions fmt_opts =
      WASP_INIT_SIZED(WaspFormatterTerminalOptions);
  fmt_opts.emit = WASP_FORMATTER_FORMAT_PLAIN;
  fmt_opts.trim = true;

  WaspFormatter formatter;
  result = wasp_formatter_terminal_new(nullptr, &formatter, terminal, fmt_opts);
  assert(result == WASP_SUCCESS);

  uint8_t *buf = nullptr;
  size_t len = 0;
  result = wasp_formatter_format_alloc(formatter, nullptr, &buf, &len);
  assert(result == WASP_SUCCESS);

  std::fwrite(buf, 1, len, stdout);
  std::printf("\n");

  wasp_free(nullptr, buf, len);
  wasp_formatter_free(formatter);
  wasp_terminal_free(terminal);
  return 0;
}
