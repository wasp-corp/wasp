#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [key-encode]
int main() {
  // Create encoder
  WaspKeyEncoder encoder;
  WaspResult result = wasp_key_encoder_new(NULL, &encoder);
  assert(result == WASP_SUCCESS);

  // Enable Kitty keyboard protocol with all features
  wasp_key_encoder_setopt(encoder, WASP_KEY_ENCODER_OPT_KITTY_FLAGS,
                             &(uint8_t){WASP_KITTY_KEY_ALL});

  // Create and configure key event for Ctrl+C press
  WaspKeyEvent event;
  result = wasp_key_event_new(NULL, &event);
  assert(result == WASP_SUCCESS);
  wasp_key_event_set_action(event, WASP_KEY_ACTION_PRESS);
  wasp_key_event_set_key(event, WASP_KEY_C);
  wasp_key_event_set_mods(event, WASP_MODS_CTRL);

  // Encode the key event
  char buf[128];
  size_t written = 0;
  result = wasp_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
  assert(result == WASP_SUCCESS);

  // Use the encoded sequence (e.g., write to terminal)
  fwrite(buf, 1, written, stdout);

  // Cleanup
  wasp_key_event_free(event);
  wasp_key_encoder_free(encoder);
  return 0;
}
//! [key-encode]
