#include <stdio.h>
#include <wasp/vt.h>

//! [focus-encode]
int main() {
  char buf[8];
  size_t written = 0;

  WaspResult result = wasp_focus_encode(
      WASP_FOCUS_GAINED, buf, sizeof(buf), &written);

  if (result == WASP_SUCCESS) {
    printf("Encoded %zu bytes: ", written);
    fwrite(buf, 1, written, stdout);
    printf("\n");
  }

  return 0;
}
//! [focus-encode]
