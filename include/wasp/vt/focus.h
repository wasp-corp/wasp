/**
 * @file focus.h
 *
 * Focus encoding - encode focus in/out events into terminal escape sequences.
 */

#ifndef WASP_VT_FOCUS_H
#define WASP_VT_FOCUS_H

/** @defgroup focus Focus Encoding
 *
 * Utilities for encoding focus gained/lost events into terminal escape
 * sequences (CSI I / CSI O) for focus reporting mode (mode 1004).
 *
 * ## Basic Usage
 *
 * Use wasp_focus_encode() to encode a focus event into a caller-provided
 * buffer. If the buffer is too small, the function returns
 * WASP_OUT_OF_SPACE and sets the required size in the output parameter.
 *
 * ## Example
 *
 * @snippet c-vt-encode-focus/src/main.c focus-encode
 *
 * @{
 */

#include <stddef.h>
#include <wasp/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Focus event types for focus reporting mode (mode 1004).
 */
typedef enum WASP_ENUM_TYPED {
    /** Terminal window gained focus */
    WASP_FOCUS_GAINED = 0,
    /** Terminal window lost focus */
    WASP_FOCUS_LOST = 1,
    WASP_FOCUS_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspFocusEvent;

/**
 * Encode a focus event into a terminal escape sequence.
 *
 * Encodes a focus gained (CSI I) or focus lost (CSI O) report into the
 * provided buffer.
 *
 * If the buffer is too small, the function returns WASP_OUT_OF_SPACE
 * and writes the required buffer size to @p out_written. The caller can
 * then retry with a sufficiently sized buffer.
 *
 * @param event The focus event to encode
 * @param buf Output buffer to write the encoded sequence into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             WASP_OUT_OF_SPACE, the required buffer size.
 * @return WASP_SUCCESS on success, WASP_OUT_OF_SPACE if the buffer
 *         is too small
 */
WASP_API WaspResult wasp_focus_encode(
    WaspFocusEvent event,
    char* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* WASP_VT_FOCUS_H */
