/**
 * @file color.h
 *
 * Color types and utilities.
 */

#ifndef WASP_VT_COLOR_H
#define WASP_VT_COLOR_H

/** @defgroup color Color Utilities
 *
 * Color parsing, palette generation, color math, and X11 color name
 * utilities shared by libwasp-vt.
 *
 * These APIs expose Wasp's color semantics directly to embedders. Use
 * them when an application needs to parse the same color strings as Wasp
 * config and theme files, generate the same 256-color palette used by the
 * terminal, list supported X11 color names, or make UI decisions from
 * luminance and contrast values.
 *
 * ## Parsing Colors
 *
 * wasp_color_parse() accepts the flexible syntax used by Wasp for
 * terminal colors:
 *
 * - X11 color names, matched ASCII case-insensitively.
 * - 3- or 6-digit hex colors, with or without a leading `#`.
 * - 9- or 12-digit hex colors, with a leading `#`.
 * - XParseColor-style `rgb:<red>/<green>/<blue>` values.
 * - XParseColor-style `rgbi:<red>/<green>/<blue>` values.
 *
 * Leading and trailing spaces and tabs are ignored. Use
 * wasp_color_parse_x11() when only X11 names should be accepted.
 *
 * @code{.c}
 * WaspColorRgb color;
 *
 * if (wasp_color_parse(
 *         "ForestGreen",
 *         sizeof("ForestGreen") - 1,
 *         &color) != WASP_SUCCESS) {
 *   // Handle invalid color input.
 * }
 *
 * wasp_color_parse("#abc", sizeof("#abc") - 1, &color);
 * wasp_color_parse("rgb:12/34/56", sizeof("rgb:12/34/56") - 1, &color);
 * @endcode
 *
 * ## Palette Entries
 *
 * wasp_color_parse_palette_entry() parses a single Wasp palette
 * override in `INDEX=COLOR` form. The index may be decimal or use a `0x`,
 * `0o`, or `0b` prefix. The color side uses wasp_color_parse().
 *
 * @code{.c}
 * WaspColorRgb palette[256];
 * wasp_color_palette_default(palette);
 *
 * uint8_t index;
 * WaspColorRgb rgb;
 *
 * if (wasp_color_parse_palette_entry(
 *         "0x10=#282c34",
 *         sizeof("0x10=#282c34") - 1,
 *         &index,
 *         &rgb) == WASP_SUCCESS) {
 *   palette[index] = rgb;
 * }
 * @endcode
 *
 * ## Palette Generation
 *
 * wasp_color_palette_generate() derives the 216-color cube and grayscale
 * ramp from a base palette, background, and foreground. Set bits in
 * WaspColorPaletteMask preserve specific indices from the base palette.
 * The output may alias the base input.
 *
 * @code{.c}
 * WaspColorRgb palette[256];
 * wasp_color_palette_default(palette);
 *
 * WaspColorPaletteMask skip = {0};
 * WASP_COLOR_PALETTE_MASK_SET(&skip, 16);
 *
 * WaspColorRgb background = {40, 44, 52};
 * WaspColorRgb foreground = {220, 223, 228};
 *
 * wasp_color_palette_generate(
 *     palette,
 *     &skip,
 *     &background,
 *     &foreground,
 *     true,
 *     palette);
 * @endcode
 *
 * ## X11 Color Names
 *
 * The X11 name table is static program-lifetime memory. Entries are in
 * rgb.txt order and are terminated by an entry with `name == NULL`.
 * wasp_color_x11_name_count() returns the number of non-terminator
 * entries.
 *
 * @code{.c}
 * const WaspColorX11Entry* names = wasp_color_x11_names();
 * size_t count = wasp_color_x11_name_count();
 *
 * for (size_t i = 0; i < count; i++) {
 *   // names[i].name and names[i].color are valid here.
 * }
 * @endcode
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wasp/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * RGB color value.
 *
 * @ingroup color
 */
typedef struct {
  uint8_t r; /**< Red component (0-255) */
  uint8_t g; /**< Green component (0-255) */
  uint8_t b; /**< Blue component (0-255) */
} WaspColorRgb;

/**
 * Palette color index (0-255).
 *
 * @ingroup color
 */
typedef uint8_t WaspColorPaletteIndex;

/**
 * A 256-bit mask of palette indices.
 *
 * Index i is set iff `(bits[i >> 6] >> (i & 63)) & 1` is 1.
 * The mask is typically initialized to zero and then populated with
 * WASP_COLOR_PALETTE_MASK_SET().
 *
 * @code{.c}
 * WaspColorPaletteMask mask = {0};
 * WASP_COLOR_PALETTE_MASK_SET(&mask, 20);
 * if (WASP_COLOR_PALETTE_MASK_IS_SET(&mask, 20)) {
 *   // Index 20 will be preserved.
 * }
 * @endcode
 *
 * @ingroup color
 */
typedef struct {
  uint64_t bits[4];
} WaspColorPaletteMask;

/**
 * An entry in Wasp's X11 color name table.
 *
 * @ingroup color
 */
typedef struct {
  /** Null-terminated color name. NULL marks the end of the table. */
  const char* name;
  /** The RGB value of the color. */
  WaspColorRgb color;
} WaspColorX11Entry;

/**
 * Return the storage word for a palette mask index.
 *
 * @param index The palette index (0-255)
 *
 * @ingroup color
 */
#define WASP_COLOR_PALETTE_MASK_WORD(index) ((index) >> 6)

/**
 * Return the storage bit for a palette mask index.
 *
 * @param index The palette index (0-255)
 *
 * @ingroup color
 */
#define WASP_COLOR_PALETTE_MASK_BIT(index) (UINT64_C(1) << ((index) & 63))

/**
 * Set a palette mask index.
 *
 * @param mask Pointer to a WaspColorPaletteMask
 * @param index The palette index (0-255)
 *
 * @ingroup color
 */
#define WASP_COLOR_PALETTE_MASK_SET(mask, index) \
  ((mask)->bits[WASP_COLOR_PALETTE_MASK_WORD(index)] |= WASP_COLOR_PALETTE_MASK_BIT(index))

/**
 * Clear a palette mask index.
 *
 * @param mask Pointer to a WaspColorPaletteMask
 * @param index The palette index (0-255)
 *
 * @ingroup color
 */
#define WASP_COLOR_PALETTE_MASK_UNSET(mask, index) \
  ((mask)->bits[WASP_COLOR_PALETTE_MASK_WORD(index)] &= ~WASP_COLOR_PALETTE_MASK_BIT(index))

/**
 * Test whether a palette mask index is set.
 *
 * @param mask Pointer to a WaspColorPaletteMask
 * @param index The palette index (0-255)
 * @return true if the palette index is set, false otherwise
 *
 * @ingroup color
 */
#define WASP_COLOR_PALETTE_MASK_IS_SET(mask, index) \
  (((mask)->bits[WASP_COLOR_PALETTE_MASK_WORD(index)] & WASP_COLOR_PALETTE_MASK_BIT(index)) != 0)

/** Black color (0) @ingroup color */
#define WASP_COLOR_NAMED_BLACK 0
/** Red color (1) @ingroup color */
#define WASP_COLOR_NAMED_RED 1
/** Green color (2) @ingroup color */
#define WASP_COLOR_NAMED_GREEN 2
/** Yellow color (3) @ingroup color */
#define WASP_COLOR_NAMED_YELLOW 3
/** Blue color (4) @ingroup color */
#define WASP_COLOR_NAMED_BLUE 4
/** Magenta color (5) @ingroup color */
#define WASP_COLOR_NAMED_MAGENTA 5
/** Cyan color (6) @ingroup color */
#define WASP_COLOR_NAMED_CYAN 6
/** White color (7) @ingroup color */
#define WASP_COLOR_NAMED_WHITE 7
/** Bright black color (8) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_BLACK 8
/** Bright red color (9) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_RED 9
/** Bright green color (10) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_GREEN 10
/** Bright yellow color (11) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_YELLOW 11
/** Bright blue color (12) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_BLUE 12
/** Bright magenta color (13) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_MAGENTA 13
/** Bright cyan color (14) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_CYAN 14
/** Bright white color (15) @ingroup color */
#define WASP_COLOR_NAMED_BRIGHT_WHITE 15

/**
 * Get the RGB color components.
 *
 * This function extracts the individual red, green, and blue components
 * from a WaspColorRgb value. Primarily useful in WebAssembly environments
 * where accessing struct fields directly is difficult.
 *
 * @param color Pointer to the RGB color value
 * @param r Pointer to store the red component (0-255)
 * @param g Pointer to store the green component (0-255)
 * @param b Pointer to store the blue component (0-255)
 *
 * @ingroup color
 */
WASP_API void wasp_color_rgb_get(const WaspColorRgb* color,
                           uint8_t* r,
                           uint8_t* g,
                           uint8_t* b);

/**
 * Parse an X11 color name.
 *
 * The color name is resolved from Wasp's embedded rgb.txt table.
 * Leading and trailing spaces and tabs are trimmed, and matching is
 * ASCII case-insensitive. Hex values are not accepted by this function.
 *
 * @param name The color name bytes (must not be NULL)
 * @param len The length of @p name in bytes
 * @param[out] out The parsed RGB color
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if no color
 * matches or @p name is NULL
 *
 * @ingroup color
 */
WASP_API WaspResult wasp_color_parse_x11(
    const char* name,
    size_t len,
    WaspColorRgb* out);

/**
 * Parse a flexible Wasp color value.
 *
 * Accepts Wasp's terminal color syntax: X11 color names, hex colors
 * in 3-, 6-, 9-, or 12-digit form (the leading # is optional for 3- and
 * 6-digit values), and rgb:<red>/<green>/<blue> or
 * rgbi:<red>/<green>/<blue> specifications. Leading and trailing spaces
 * and tabs are trimmed.
 *
 * @param value The color value bytes (must not be NULL)
 * @param len The length of @p value in bytes
 * @param[out] out The parsed RGB color
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if parsing
 * fails or @p value is NULL
 *
 * @ingroup color
 */
WASP_API WaspResult wasp_color_parse(
    const char* value,
    size_t len,
    WaspColorRgb* out);

/**
 * Parse a Wasp palette entry.
 *
 * Accepts Wasp palette config syntax: N=COLOR. N is a palette index
 * from 0 to 255 in decimal or in 0x, 0o, or 0b-prefixed form. Spaces and
 * tabs around N and COLOR are ignored. COLOR accepts the same syntax as
 * wasp_color_parse().
 *
 * @param value The palette entry bytes (must not be NULL)
 * @param len The length of @p value in bytes
 * @param[out] out_index The parsed palette index
 * @param[out] out_rgb The parsed RGB color
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE on any
 * failure, including index overflow
 *
 * @ingroup color
 */
WASP_API WaspResult wasp_color_parse_palette_entry(
    const char* value,
    size_t len,
    uint8_t* out_index,
    WaspColorRgb* out_rgb);

/**
 * Get Wasp's built-in default 256-color palette.
 *
 * Writes exactly 256 entries: Wasp's base16 defaults, the xterm
 * 6x6x6 color cube, and the grayscale ramp.
 *
 * @param[out] out The output palette, an array of exactly 256
 * WaspColorRgb values
 *
 * @ingroup color
 */
WASP_API void wasp_color_palette_default(WaspColorRgb* out);

/**
 * Generate a 256-color palette from base colors.
 *
 * The base palette supplies indices 0-15, which are always preserved.
 * If @p base is NULL, Wasp's default palette is used. If @p skip is
 * NULL, no extra indices are skipped. Set bits in @p skip preserve those
 * indices from @p base. The 216-color cube at indices 16-231 is generated
 * with trilinear CIELAB interpolation, and the grayscale ramp at indices
 * 232-255 is interpolated from the background to the foreground.
 *
 * For light themes, @p harmonious controls whether the generated palette
 * keeps the background-to-foreground orientation. When false, Wasp
 * swaps the light background and dark foreground so the cube and ramp run
 * dark-to-light. The output palette may be the same pointer as @p base.
 *
 * @param base The base palette, an array of exactly 256 WaspColorRgb
 * values, or NULL to use Wasp's default palette
 * @param skip The palette indices to preserve from @p base, or NULL for
 * an empty mask
 * @param bg The terminal background color (must not be NULL)
 * @param fg The terminal foreground color (must not be NULL)
 * @param harmonious Whether light themes keep background-to-foreground
 * orientation
 * @param[out] out The output palette, an array of exactly 256
 * WaspColorRgb values
 *
 * @ingroup color
 */
WASP_API void wasp_color_palette_generate(
    const WaspColorRgb* base,
    const WaspColorPaletteMask* skip,
    const WaspColorRgb* bg,
    const WaspColorRgb* fg,
    bool harmonious,
    WaspColorRgb* out);

/**
 * Calculate W3C relative luminance for an RGB color.
 *
 * Returns a normalized value from 0.0 for black to 1.0 for white.
 * See https://www.w3.org/TR/WCAG20/#relativeluminancedef.
 *
 * @param color The RGB color (must not be NULL)
 * @return Relative luminance in the range 0.0 to 1.0
 *
 * @ingroup color
 */
WASP_API double wasp_color_luminance(const WaspColorRgb* color);

/**
 * Calculate perceived luminance for an RGB color.
 *
 * Returns a normalized value from 0.0 for black to 1.0 for white.
 * Wasp treats a background color as light when this exceeds 0.5.
 * This is not the metric used internally by
 * wasp_color_palette_generate(), which uses CIELAB lightness.
 *
 * @param color The RGB color (must not be NULL)
 * @return Perceived luminance in the range 0.0 to 1.0
 *
 * @ingroup color
 */
WASP_API double wasp_color_perceived_luminance(const WaspColorRgb* color);

/**
 * Calculate the WCAG contrast ratio between two RGB colors.
 *
 * The contrast ratio is symmetric and ranges from 1.0 for identical
 * colors to 21.0 for black and white.
 *
 * @param a The first RGB color (must not be NULL)
 * @param b The second RGB color (must not be NULL)
 * @return WCAG contrast ratio in the range 1.0 to 21.0
 *
 * @ingroup color
 */
WASP_API double wasp_color_contrast(const WaspColorRgb* a,
                              const WaspColorRgb* b);

/**
 * Get Wasp's X11 color name table.
 *
 * The returned pointer references static memory valid for the program
 * lifetime and is never NULL. Entries are in rgb.txt order and are
 * terminated by an entry with name == NULL. Aliases are separate entries,
 * such as "medium spring green" and "MediumSpringGreen". Names are the
 * exact supported spellings from rgb.txt; wasp_color_parse_x11() also
 * matches them case-insensitively.
 *
 * @code{.c}
 * for (const WaspColorX11Entry* e = wasp_color_x11_names();
 *      e->name != NULL;
 *      e++) {
 *   // e->name and e->color are valid here.
 * }
 * @endcode
 *
 * @return Pointer to the first X11 color entry
 *
 * @ingroup color
 */
WASP_API const WaspColorX11Entry* wasp_color_x11_names(void);

/**
 * Get the number of X11 color name entries.
 *
 * The returned count excludes the NULL terminator and is provided so
 * bindings can preallocate storage before reading wasp_color_x11_names().
 *
 * @return Number of X11 color name entries
 *
 * @ingroup color
 */
WASP_API size_t wasp_color_x11_name_count(void);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* WASP_VT_COLOR_H */
