#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

int main() {
  WaspOscParser parser;
  if (wasp_osc_new(NULL, &parser) != WASP_SUCCESS) {
    return 1;
  }
  
  // Setup change window title command to change the title to "hello"
  wasp_osc_next(parser, '0');
  wasp_osc_next(parser, ';');
  const char *title = "hello";
  for (size_t i = 0; i < strlen(title); i++) {
    wasp_osc_next(parser, title[i]);
  }
  
  // End parsing and get command
  WaspOscCommand command = wasp_osc_end(parser, 0);
  
  // Get and print command type
  WaspOscCommandType type = wasp_osc_command_type(command);
  printf("Command type: %d\n", type);
  
  // Extract and print the title
  if (wasp_osc_command_data(command, WASP_OSC_DATA_CHANGE_WINDOW_TITLE_STR, &title)) {
    printf("Extracted title: %s\n", title);
  } else {
    printf("Failed to extract title\n");
  }
  
  wasp_osc_free(parser);
  return 0;
}
