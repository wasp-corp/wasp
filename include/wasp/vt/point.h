/**
 * @file point.h
 *
 * Terminal point types for referencing locations in the terminal grid.
 */

#ifndef WASP_VT_POINT_H
#define WASP_VT_POINT_H

#include <stdint.h>

#include <wasp/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup point Point
 *
 * Types for referencing x/y positions in the terminal grid under
 * different coordinate systems (active area, viewport, full screen,
 * scrollback history).
 *
 * @{
 */

/**
 * A coordinate in the terminal grid.
 *
 * @ingroup point
 */
typedef struct {
  /** Column (0-indexed). */
  uint16_t x;

  /** Row (0-indexed). May exceed page size for screen/history tags. */
  uint32_t y;
} WaspPointCoordinate;

/**
 * Point reference tag.
 *
 * Determines which coordinate system a point uses.
 *
 * @ingroup point
 */
typedef enum WASP_ENUM_TYPED {
  /** Active area where the cursor can move. */
  WASP_POINT_TAG_ACTIVE = 0,

  /** Visible viewport (changes when scrolled). */
  WASP_POINT_TAG_VIEWPORT = 1,

  /** Full screen including scrollback. */
  WASP_POINT_TAG_SCREEN = 2,

  /** Scrollback history only (before active area). */
  WASP_POINT_TAG_HISTORY = 3,
  WASP_POINT_TAG_MAX_VALUE = WASP_ENUM_MAX_VALUE,
  } WaspPointTag;

/**
 * Point value union.
 *
 * @ingroup point
 */
typedef union {
  /** Coordinate (used for all tag variants). */
  WaspPointCoordinate coordinate;

  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[2];
} WaspPointValue;

/**
 * Tagged union for a point in the terminal grid.
 *
 * @ingroup point
 */
typedef struct {
  WaspPointTag tag;
  WaspPointValue value;
} WaspPoint;

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* WASP_VT_POINT_H */
