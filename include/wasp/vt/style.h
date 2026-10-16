/**
 * @file style.h
 *
 * Terminal cell style types.
 */

#ifndef WASP_VT_STYLE_H
#define WASP_VT_STYLE_H

#include <wasp/vt/color.h>
#include <wasp/vt/types.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup style Style
 *
 * Terminal cell style attributes.
 *
 * A style describes the visual attributes of a terminal cell, including
 * foreground, background, and underline colors, as well as flags for
 * bold, italic, underline, and other text decorations.
 *
 * @{
 */

/**
 * Style identifier type.
 *
 * Used to look up the full style from a grid reference.
 * Obtain this from a cell via WASP_CELL_DATA_STYLE_ID.
 *
 * @ingroup style
 */
typedef uint16_t WaspStyleId;

/**
 * Style color tags.
 *
 * These values identify the type of color in a style color.
 * Use the tag to determine which field in the color value union to access.
 *
 * @ingroup style
 */
typedef enum WASP_ENUM_TYPED {
  WASP_STYLE_COLOR_NONE = 0,
  WASP_STYLE_COLOR_PALETTE = 1,
  WASP_STYLE_COLOR_RGB = 2,
  WASP_STYLE_COLOR_TAG_MAX_VALUE = WASP_ENUM_MAX_VALUE,
  } WaspStyleColorTag;

/**
 * Style color value union.
 *
 * Use the tag to determine which field is active.
 *
 * @ingroup style
 */
typedef union {
  WaspColorPaletteIndex palette;
  WaspColorRgb rgb;
  uint64_t _padding;
} WaspStyleColorValue;

/**
 * Style color (tagged union).
 *
 * A color used in a style attribute. Can be unset (none), a palette
 * index, or a direct RGB value.
 *
 * @ingroup style
 */
typedef struct {
  WaspStyleColorTag tag;
  WaspStyleColorValue value;
} WaspStyleColor;

/**
 * Terminal cell style.
 *
 * Describes the complete visual style for a terminal cell, including
 * foreground, background, and underline colors, as well as text
 * decoration flags. The underline field uses the same values as
 * WaspSgrUnderline.
 *
 * This is a sized struct. Use WASP_INIT_SIZED() to initialize it.
 *
 * @ingroup style
 */
typedef struct {
  size_t size;
  WaspStyleColor fg_color;
  WaspStyleColor bg_color;
  WaspStyleColor underline_color;
  bool bold;
  bool italic;
  bool faint;
  bool blink;
  bool inverse;
  bool invisible;
  bool strikethrough;
  bool overline;
  int underline; /**< One of WASP_SGR_UNDERLINE_* values */
} WaspStyle;

/**
 * Get the default style.
 *
 * Initializes the style to the default values (no colors, no flags).
 *
 * @param style Pointer to the style to initialize
 *
 * @ingroup style
 */
WASP_API void wasp_style_default(WaspStyle* style);

/**
 * Check if a style is the default style.
 *
 * Returns true if all colors are unset and all flags are off.
 *
 * @param style Pointer to the style to check
 * @return true if the style is the default style
 *
 * @ingroup style
 */
WASP_API bool wasp_style_is_default(const WaspStyle* style);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* WASP_VT_STYLE_H */
