#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [mouse-encode]
int main() {
  // Create encoder
  WaspMouseEncoder encoder;
  WaspResult result = wasp_mouse_encoder_new(NULL, &encoder);
  assert(result == WASP_SUCCESS);

  // Configure SGR format with normal tracking
  wasp_mouse_encoder_setopt(encoder, WASP_MOUSE_ENCODER_OPT_EVENT,
      &(WaspMouseTrackingMode){WASP_MOUSE_TRACKING_NORMAL});
  wasp_mouse_encoder_setopt(encoder, WASP_MOUSE_ENCODER_OPT_FORMAT,
      &(WaspMouseFormat){WASP_MOUSE_FORMAT_SGR});

  // Set terminal geometry for coordinate mapping
  wasp_mouse_encoder_setopt(encoder, WASP_MOUSE_ENCODER_OPT_SIZE,
      &(WaspMouseEncoderSize){
          .size = sizeof(WaspMouseEncoderSize),
          .screen_width = 800, .screen_height = 600,
          .cell_width = 10, .cell_height = 20,
      });

  // Create and configure a left button press event
  WaspMouseEvent event;
  result = wasp_mouse_event_new(NULL, &event);
  assert(result == WASP_SUCCESS);
  wasp_mouse_event_set_action(event, WASP_MOUSE_ACTION_PRESS);
  wasp_mouse_event_set_button(event, WASP_MOUSE_BUTTON_LEFT);
  wasp_mouse_event_set_position(event,
      (WaspMousePosition){.x = 50.0f, .y = 40.0f});

  // Encode the mouse event
  char buf[128];
  size_t written = 0;
  result = wasp_mouse_encoder_encode(encoder, event,
      buf, sizeof(buf), &written);
  assert(result == WASP_SUCCESS);

  // Use the encoded sequence (e.g., write to terminal)
  fwrite(buf, 1, written, stdout);

  // Cleanup
  wasp_mouse_event_free(event);
  wasp_mouse_encoder_free(encoder);
  return 0;
}
//! [mouse-encode]
