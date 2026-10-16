#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [selection-main]
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
  WaspFormatterTerminalOptions opts = WASP_INIT_SIZED(WaspFormatterTerminalOptions);
  opts.emit = WASP_FORMATTER_FORMAT_PLAIN;
  opts.trim = true;
  opts.selection = selection;

  WaspFormatter formatter;
  WaspResult result = wasp_formatter_terminal_new(
      NULL, &formatter, terminal, opts);
  assert(result == WASP_SUCCESS);

  uint8_t *buf = NULL;
  size_t len = 0;
  result = wasp_formatter_format_alloc(formatter, NULL, &buf, &len);
  assert(result == WASP_SUCCESS);

  printf("%s: ", label);
  fwrite(buf, 1, len, stdout);
  printf("\n");

  wasp_free(NULL, buf, len);
  wasp_formatter_free(formatter);
}

int main() {
  WaspTerminal terminal;
  WaspResult result = wasp_terminal_new(NULL, &terminal, 80, 8);
  assert(result == WASP_SUCCESS);

  // A realistic shell transcript with OSC 133 semantic prompt markers.
  // Wasp uses these markers to distinguish prompt/input from command
  // output for semantic line and output selections.
  vt_write(terminal,
      "\033]133;A\007$ "           // Prompt starts: "$ "
      "\033]133;B\007git status"  // Input starts: "git status"
      "\033]133;C\007\r\n"        // Output starts after Enter
      "On branch main\r\n"
      "nothing to commit, working tree clean");

  WaspSelection selection = WASP_INIT_SIZED(WaspSelection);

  // Double-click style word selection under the cursor.
  WaspTerminalSelectWordOptions word = WASP_INIT_SIZED(WaspTerminalSelectWordOptions);
  word.ref = ref_at(terminal, 6, 0); // the "status" in "git status"
  result = wasp_terminal_select_word(terminal, &word, &selection);
  assert(result == WASP_SUCCESS);
  print_selection(terminal, "word", &selection);

  //! [selection-word-between]
  // Double-click-and-drag style selection. Suppose the user double-clicks
  // "git" and drags to "status". The pointer may pass over whitespace, so
  // select the nearest word between the original click and current drag point
  // in both directions, then combine the outer word bounds.
  WaspGridRef click_ref = ref_at(terminal, 2, 0); // the "git" in "git status"
  WaspGridRef drag_ref = ref_at(terminal, 6, 0);  // the "status" in "git status"

  WaspTerminalSelectWordBetweenOptions start_word_opts =
      WASP_INIT_SIZED(WaspTerminalSelectWordBetweenOptions);
  start_word_opts.start = click_ref;
  start_word_opts.end = drag_ref;

  WaspSelection start_word = WASP_INIT_SIZED(WaspSelection);
  result = wasp_terminal_select_word_between(
      terminal, &start_word_opts, &start_word);
  assert(result == WASP_SUCCESS);

  WaspTerminalSelectWordBetweenOptions end_word_opts =
      WASP_INIT_SIZED(WaspTerminalSelectWordBetweenOptions);
  end_word_opts.start = drag_ref;
  end_word_opts.end = click_ref;

  WaspSelection end_word = WASP_INIT_SIZED(WaspSelection);
  result = wasp_terminal_select_word_between(
      terminal, &end_word_opts, &end_word);
  assert(result == WASP_SUCCESS);

  WaspSelection drag_selection = WASP_INIT_SIZED(WaspSelection);
  drag_selection.start = start_word.start;
  drag_selection.end = end_word.end;
  print_selection(terminal, "double-click drag", &drag_selection);
  //! [selection-word-between]

  // Triple-click style line selection. With semantic prompt boundaries enabled,
  // this selects only the input area rather than the leading "$ " prompt.
  WaspTerminalSelectLineOptions line = WASP_INIT_SIZED(WaspTerminalSelectLineOptions);
  line.ref = ref_at(terminal, 2, 0); // the "git status" input area
  line.semantic_prompt_boundary = true;
  result = wasp_terminal_select_line(terminal, &line, &selection);
  assert(result == WASP_SUCCESS);
  print_selection(terminal, "line", &selection);

  // Select exactly the command output for the command under the cursor.
  result = wasp_terminal_select_output(
      terminal, ref_at(terminal, 0, 1), &selection);
  assert(result == WASP_SUCCESS);
  print_selection(terminal, "output", &selection);

  // Select all visible content.
  result = wasp_terminal_select_all(terminal, &selection);
  assert(result == WASP_SUCCESS);
  print_selection(terminal, "all", &selection);

  wasp_terminal_free(terminal);
  return 0;
}
//! [selection-main]
