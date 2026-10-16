/**
 * @file grid_ref_tracked.h
 *
 * Tracked terminal grid references.
 */

#ifndef WASP_VT_GRID_REF_TRACKED_H
#define WASP_VT_GRID_REF_TRACKED_H

#include <stdbool.h>
#include <wasp/vt/types.h>
#include <wasp/vt/grid_ref.h>
#include <wasp/vt/point.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Tracked grid references are owned grid references that move with the
 * terminal. See @ref grid_ref for the full overview of tracked and untracked
 * grid reference behavior.
 *
 * @ingroup grid_ref
 */

/**
 * Free a tracked grid reference.
 *
 * Passing NULL is allowed and has no effect. A tracked reference may be freed
 * after the terminal that created it is freed.
 *
 * @param ref Tracked grid reference to free.
 *
 * @ingroup grid_ref
 */
WASP_API void wasp_tracked_grid_ref_free(WaspTrackedGridRef ref);

/**
 * Return whether a tracked grid reference currently has a meaningful value.
 *
 * If the terminal that created the tracked reference has been freed, this
 * returns false.
 *
 * @param ref Tracked grid reference.
 * @return true if the reference currently has a meaningful value.
 *
 * @ingroup grid_ref
 */
WASP_API bool wasp_tracked_grid_ref_has_value(
    WaspTrackedGridRef ref);

/**
 * Convert a tracked grid reference to a point in the requested coordinate
 * space.
 *
 * This is the tracked equivalent of wasp_terminal_point_from_grid_ref().
 * Unlike snapshotting, this does not expose an intermediate untracked
 * WaspGridRef.
 *
 * A tracked reference is resolved against the terminal screen/page-list that
 * currently owns the reference. If the terminal has switched between primary
 * and alternate screens since the reference was created or last set, this may
 * be different from the terminal's currently active screen.
 *
 * If the tracked reference no longer has a meaningful value, this returns
 * WASP_NO_VALUE. WASP_NO_VALUE is also returned when the reference cannot
 * be represented in the requested coordinate space, including after the
 * terminal that created the tracked reference has been freed.
 *
 * @param ref Tracked grid reference.
 * @param tag Coordinate space to convert into.
 * @param[out] out_point On success, receives the coordinate. May be NULL.
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if ref is invalid,
 *         or WASP_NO_VALUE if there is no representable value.
 *
 * @ingroup grid_ref
 */
WASP_API WaspResult wasp_tracked_grid_ref_point(
    WaspTrackedGridRef ref,
    WaspPointTag tag,
    WaspPointCoordinate *out_point);

/**
 * Move an existing tracked grid reference to a new terminal point.
 *
 * On success, the tracked reference begins tracking the new point and any prior
 * "no value" state is cleared. On WASP_OUT_OF_MEMORY, the original tracked
 * reference is left unchanged.
 *
 * The terminal must be the same terminal that created the tracked reference.
 * The point is resolved against the terminal screen/page-list that is active at
 * the time this function is called. If the terminal has switched between
 * primary and alternate screens, this may move the tracked reference from one
 * screen/page-list to the other.
 *
 * @param ref Tracked grid reference.
 * @param terminal Terminal instance that owns the reference.
 * @param point New point to track.
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if ref, terminal,
 *         or point is invalid, or WASP_OUT_OF_MEMORY if allocation fails.
 *
 * @ingroup grid_ref
 */
WASP_API WaspResult wasp_tracked_grid_ref_set(
    WaspTrackedGridRef ref,
    WaspTerminal terminal,
    WaspPoint point);

/**
 * Snapshot a tracked grid reference into a regular WaspGridRef.
 *
 * The returned WaspGridRef is an untracked snapshot and has the same
 * lifetime rules as wasp_terminal_grid_ref(): it is only valid until the
 * next terminal update. Snapshot immediately before calling
 * wasp_grid_ref_cell(), wasp_grid_ref_row(),
 * wasp_grid_ref_graphemes(), wasp_grid_ref_hyperlink_uri(), or
 * wasp_grid_ref_style().
 *
 * If the tracked reference no longer has a meaningful value, this returns
 * WASP_NO_VALUE. This includes references whose owning terminal has been
 * freed.
 *
 * @param ref Tracked grid reference.
 * @param[out] out_ref On success, receives an untracked snapshot. May be NULL.
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if ref is invalid,
 *         or WASP_NO_VALUE if the tracked location was discarded.
 *
 * @ingroup grid_ref
 */
WASP_API WaspResult wasp_tracked_grid_ref_snapshot(
    WaspTrackedGridRef ref,
    WaspGridRef *out_ref);

#ifdef __cplusplus
}
#endif

#endif /* WASP_VT_GRID_REF_TRACKED_H */
