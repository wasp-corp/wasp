#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wasp/vt.h>

//! [kitty-graphics-decode-png]
/**
 * Minimal PNG decoder callback for the sys interface.
 *
 * A real implementation would use a PNG library (libpng, stb_image, etc.)
 * to decode the PNG data. This example uses a hardcoded 1x1 red pixel
 * since we know exactly what image we're sending.
 *
 * WARNING: This is only an example for providing a callback, it DOES NOT 
 * actually decode the PNG it is passed. It hardcodes a response.
 */
bool decode_png(void* userdata,
                const WaspAllocator* allocator,
                const uint8_t* data,
                size_t data_len,
                WaspSysImage* out) {
  int* count = (int*)userdata;
  (*count)++;
  printf("  decode_png called (size=%zu, call #%d)\n", data_len, *count);

  /* Allocate RGBA pixel data through the provided allocator. */
  const size_t pixel_len = 4;  /* 1x1 RGBA */
  uint8_t* pixels = wasp_alloc(allocator, pixel_len);
  if (!pixels) return false;

  /* Fill with red (R=255, G=0, B=0, A=255). */
  pixels[0] = 255;
  pixels[1] = 0;
  pixels[2] = 0;
  pixels[3] = 255;

  out->width = 1;
  out->height = 1;
  out->data = pixels;
  out->data_len = pixel_len;
  return true;
}
//! [kitty-graphics-decode-png]

//! [kitty-graphics-write-pty]
/**
 * write_pty callback to capture terminal responses.
 *
 * The Kitty graphics protocol sends an APC response back to the pty
 * when an image is loaded (unless suppressed with q=2).
 */
void on_write_pty(WaspTerminal terminal,
                  void* userdata,
                  const uint8_t* data,
                  size_t len) {
  (void)terminal;
  (void)userdata;
  printf("  response (%zu bytes): ", len);
  fwrite(data, 1, len, stdout);
  printf("\n");
}
//! [kitty-graphics-write-pty]

//! [kitty-graphics-main]
int main() {
  /* Install the PNG decoder via the sys interface. */
  int decode_count = 0;
  wasp_sys_set(WASP_SYS_OPT_USERDATA, &decode_count);
  wasp_sys_set(WASP_SYS_OPT_DECODE_PNG, (const void*)decode_png);

  /* Create a terminal with Kitty graphics enabled. */
  WaspTerminal terminal = NULL;
  if (wasp_terminal_new(NULL, &terminal, 80, 24) != WASP_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  /* Set cell pixel dimensions so kitty graphics can compute grid sizes. */
  wasp_terminal_resize(terminal, 80, 24, 8, 16);

  /* Set a storage limit to enable Kitty graphics. */
  uint64_t storage_limit = 64 * 1024 * 1024;  /* 64 MiB */
  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                       &storage_limit);

  /* Install write_pty to see the protocol response. */
  wasp_terminal_set(terminal, WASP_TERMINAL_OPT_WRITE_PTY,
                       (const void*)on_write_pty);

  /*
   * Send a Kitty graphics command with an inline 1x1 PNG image.
   *
   * The escape sequence is:
   *   ESC _G a=T,f=100,q=1; <base64 PNG data> ESC \
   *
   * Where:
   *   a=T   — transmit and display
   *   f=100 — PNG format
   *   q=1   — request a response (q=0 would suppress it)
   */
  printf("Sending Kitty graphics PNG image:\n");
  const char* kitty_cmd =
    "\x1b_Ga=T,f=100,q=1;"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA"
    "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    "\x1b\\";
  wasp_terminal_vt_write(terminal, (const uint8_t*)kitty_cmd,
                            strlen(kitty_cmd));

  printf("PNG decode calls: %d\n", decode_count);

  /* Query the kitty graphics storage to verify the image was stored. */
  WaspKittyGraphics graphics = NULL;
  if (wasp_terminal_get(terminal, WASP_TERMINAL_DATA_KITTY_GRAPHICS,
                           &graphics) != WASP_SUCCESS || !graphics) {
    fprintf(stderr, "Failed to get kitty graphics storage\n");
    return 1;
  }
  printf("\nKitty graphics storage is available.\n");

  /*
   * The storage-wide generation changes on every image/placement
   * mutation. Renderers can compare it against the value from the
   * previous frame: if unchanged, placement iteration and image
   * staleness checks can be skipped entirely.
   */
  uint64_t generation = 0;
  wasp_kitty_graphics_get(graphics, WASP_KITTY_GRAPHICS_DATA_GENERATION,
                             &generation);
  printf("Storage generation: %llu\n", (unsigned long long)generation);

  /* Iterate placements to find the image ID. */
  WaspKittyGraphicsPlacementIterator iter = NULL;
  if (wasp_kitty_graphics_placement_iterator_new(NULL, &iter) != WASP_SUCCESS) {
    fprintf(stderr, "Failed to create placement iterator\n");
    return 1;
  }
  if (wasp_kitty_graphics_get(graphics,
          WASP_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iter) != WASP_SUCCESS) {
    fprintf(stderr, "Failed to get placement iterator\n");
    return 1;
  }

  int placement_count = 0;
  while (wasp_kitty_graphics_placement_next(iter)) {
    placement_count++;
    uint32_t image_id = 0;
    uint32_t placement_id = 0;
    bool is_virtual = false;
    int32_t z = 0;

    wasp_kitty_graphics_placement_get_multi(iter, 4,
        (WaspKittyGraphicsPlacementData[]){
            WASP_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
            WASP_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
            WASP_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
            WASP_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
        },
        (void*[]){ &image_id, &placement_id, &is_virtual, &z },
        NULL);

    printf("  placement #%d: image_id=%u placement_id=%u virtual=%s z=%d\n",
           placement_count, image_id, placement_id,
           is_virtual ? "true" : "false", z);

    /* Look up the image and print its properties. */
    WaspKittyGraphicsImage image =
        wasp_kitty_graphics_image(graphics, image_id);
    if (!image) {
      fprintf(stderr, "Failed to look up image %u\n", image_id);
      return 1;
    }

    uint32_t width = 0, height = 0, number = 0;
    WaspKittyImageFormat format = 0;
    size_t data_len = 0;
    uint64_t image_generation = 0;

    /*
     * The per-image generation changes on every add/replace of this
     * image ID, so it detects retransmissions even when the size and
     * format are unchanged. Texture caches should key staleness on it.
     */
    wasp_kitty_graphics_image_get_multi(image, 6,
        (WaspKittyGraphicsImageData[]){
            WASP_KITTY_IMAGE_DATA_NUMBER,
            WASP_KITTY_IMAGE_DATA_WIDTH,
            WASP_KITTY_IMAGE_DATA_HEIGHT,
            WASP_KITTY_IMAGE_DATA_FORMAT,
            WASP_KITTY_IMAGE_DATA_DATA_LEN,
            WASP_KITTY_IMAGE_DATA_GENERATION,
        },
        (void*[]){ &number, &width, &height, &format, &data_len,
                   &image_generation },
        NULL);

    printf("    image: number=%u size=%ux%u format=%d data_len=%zu "
           "generation=%llu\n",
           number, width, height, format, data_len,
           (unsigned long long)image_generation);

    /* Compute the rendered pixel size and grid size. */
    uint32_t px_w = 0, px_h = 0, cols = 0, rows = 0;
    if (wasp_kitty_graphics_placement_pixel_size(iter, image, terminal,
            &px_w, &px_h) == WASP_SUCCESS) {
      printf("    rendered pixel size: %ux%u\n", px_w, px_h);
    }
    if (wasp_kitty_graphics_placement_grid_size(iter, image, terminal,
            &cols, &rows) == WASP_SUCCESS) {
      printf("    grid size: %u cols x %u rows\n", cols, rows);
    }
  }
  printf("Total placements: %d\n", placement_count);
  wasp_kitty_graphics_placement_iterator_free(iter);

  /* Clean up. */
  wasp_terminal_free(terminal);

  /* Clear the sys callbacks. */
  wasp_sys_set(WASP_SYS_OPT_DECODE_PNG, NULL);
  wasp_sys_set(WASP_SYS_OPT_USERDATA, NULL);

  return 0;
}
//! [kitty-graphics-main]
