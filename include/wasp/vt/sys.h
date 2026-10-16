/**
 * @file sys.h
 *
 * System interface - runtime-swappable implementations for external dependencies.
 */

#ifndef WASP_VT_SYS_H
#define WASP_VT_SYS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wasp/vt/types.h>
#include <wasp/vt/allocator.h>

/** @defgroup sys System Interface
 *
 * Runtime-swappable function pointers for operations that depend on
 * external implementations (e.g. image decoding).
 *
 * These are process-global settings that must be configured at startup
 * before any terminal functionality that depends on them is used.
 * Setting these enables various optional features of the terminal. For
 * example, setting a PNG decoder enables PNG image support in the Kitty
 * Graphics Protocol.
 *
 * Use wasp_sys_set() with a `WaspSysOption` to install or clear
 * an implementation. Passing NULL as the value clears the implementation
 * and disables the corresponding feature.
 *
 * ## Example
 *
 * ### Defining a PNG decode callback
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-decode-png
 *
 * ### Installing the callback and sending a PNG image
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-main
 *
 * @{
 */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * A decoded image, filled in by a decode callback such as
 * WaspSysDecodePngFn.
 *
 * Pixels are 8-bit RGBA: four bytes per pixel, stored row by row starting
 * at the top-left corner, with no padding between rows. A complete image
 * is therefore `width * height * 4` bytes long.
 *
 * The pixel buffer must be allocated with the allocator passed to the
 * decode callback. When the callback returns true, the library takes
 * ownership of the buffer and frees it with that same allocator.
 */
typedef struct {
    /** Image width in pixels. */
    uint32_t width;

    /** Image height in pixels. */
    uint32_t height;

    /**
     * The decoded RGBA pixels, allocated with the allocator passed to
     * the decode callback.
     */
    uint8_t* data;

    /**
     * Length of `data` in bytes. This must be the exact size that was
     * requested from the allocator, because the library uses it to free
     * the buffer.
     */
    size_t data_len;
} WaspSysImage;

/**
 * Log severity levels for the log callback.
 */
typedef enum WASP_ENUM_TYPED {
    WASP_SYS_LOG_LEVEL_ERROR = 0,
    WASP_SYS_LOG_LEVEL_WARNING = 1,
    WASP_SYS_LOG_LEVEL_INFO = 2,
    WASP_SYS_LOG_LEVEL_DEBUG = 3,
    WASP_SYS_LOG_LEVEL_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSysLogLevel;

/**
 * Callback type for logging.
 *
 * When installed, internal library log messages are delivered through
 * this callback instead of being discarded. The embedder is responsible
 * for formatting and routing log output.
 *
 * @p scope is the log scope name as UTF-8 bytes (e.g. "osc", "kitty").
 * When the log is unscoped (default scope), @p scope_len is 0.
 *
 * All pointer arguments are only valid for the duration of the callback.
 * The callback must be safe to call from any thread.
 *
 * @param userdata    The userdata pointer set via WASP_SYS_OPT_USERDATA
 * @param level       The severity level of the log message
 * @param scope       Pointer to the scope name bytes
 * @param scope_len   Length of the scope name in bytes
 * @param message     Pointer to the log message bytes
 * @param message_len Length of the log message in bytes
 */
typedef void (*WaspSysLogFn)(
    void* userdata,
    WaspSysLogLevel level,
    const uint8_t* scope,
    size_t scope_len,
    const uint8_t* message,
    size_t message_len);

/**
 * Callback type for PNG decoding.
 *
 * The library calls this when it receives a PNG image and needs the raw
 * pixels. The callback decodes the PNG bytes in @p data and describes
 * the result in @p out. See the example in the @ref sys overview for a
 * complete callback.
 *
 * ### On success
 *
 * Allocate the pixel buffer with wasp_alloc() and @p allocator, write
 * the decoded pixels into it, set all four fields of @p out, and return
 * true. The library then owns the buffer and frees it with the same
 * allocator. See WaspSysImage for the expected pixel layout.
 *
 * The allocator limits how much memory a single image may use, so
 * wasp_alloc() can return NULL for very large images. Treat that as
 * a failure.
 *
 * ### On failure
 *
 * Free anything that was allocated and return false. The library does
 * not read @p out in this case, and the image is rejected.
 *
 * ### The output struct starts zeroed
 *
 * The library sets every field of @p out to zero before it calls the
 * callback. This has two practical effects:
 *
 * - If the callback returns true but `data` is still NULL, the library
 *   treats the call as a failure.
 * - Language bindings can store a pointer into @p out directly. Some
 *   runtimes, such as Go, require memory to be initialized before a
 *   pointer is written into it, and this guarantee satisfies that
 *   requirement.
 *
 * Only @p out is zeroed. Memory returned by wasp_alloc() is not.
 *
 * @p data and @p allocator are only valid for the duration of the
 * callback.
 *
 * @param userdata  The userdata pointer set via WASP_SYS_OPT_USERDATA
 * @param allocator The allocator to use for the output pixel buffer
 * @param data      Pointer to the raw PNG data
 * @param data_len  Length of the raw PNG data in bytes
 * @param[out] out  The decoded image. Zeroed by the library before the
 *                  call, and filled in by the callback on success.
 * @return true if the image was decoded and @p out was filled in,
 *         false on failure
 */
typedef bool (*WaspSysDecodePngFn)(
    void* userdata,
    const WaspAllocator* allocator,
    const uint8_t* data,
    size_t data_len,
    WaspSysImage* out);

/**
 * Callback type for secure random bytes.
 *
 * Fills @p buf with @p len cryptographically secure random bytes. The
 * library uses this for secrets, so it must be a real CSPRNG (getrandom,
 * arc4random_buf, BCryptGenRandom, crypto.getRandomValues, ...); a
 * predictable source is a security hole.
 *
 * @param userdata The userdata pointer set via WASP_SYS_OPT_USERDATA
 * @param buf      Buffer to fill
 * @param len      Number of bytes to fill
 * @return true if the buffer was filled, false if no entropy is available
 */
typedef bool (*WaspSysRandomSecureFn)(
    void* userdata,
    uint8_t* buf,
    size_t len);

/**
 * System option identifiers for wasp_sys_set().
 */
typedef enum WASP_ENUM_TYPED {
    /**
     * Set the userdata pointer passed to all sys callbacks.
     *
     * Input type: void* (or NULL)
     */
    WASP_SYS_OPT_USERDATA = 0,

    /**
     * Set the PNG decode function.
     *
     * When set, the terminal can accept PNG images via the Kitty
     * Graphics Protocol. When cleared (NULL value), PNG decoding is
     * unsupported and PNG image data will be rejected.
     *
     * Input type: WaspSysDecodePngFn (function pointer, or NULL)
     */
    WASP_SYS_OPT_DECODE_PNG = 1,

    /**
     * Set the log callback.
     *
     * When set, internal library log messages are delivered to this
     * callback. When cleared (NULL value), log messages are silently
     * discarded.
     *
     * Use wasp_sys_log_stderr as a convenience callback that
     * writes formatted messages to stderr.
     *
     * Which log levels are emitted depends on the build mode of the
     * library and is not configurable at runtime. Debug builds emit
     * all levels (debug and above). Release builds emit info and
     * above; debug-level messages are compiled out entirely and will
     * never reach the callback.
     *
     * Input type: WaspSysLogFn (function pointer, or NULL)
     */
    WASP_SYS_OPT_LOG = 2,

    /**
     * Override the secure random source.
     *
     * By default the library draws secure random bytes from the
     * platform (getrandom or arc4random_buf on POSIX, CNG on Windows).
     * Targets without one, such as wasm32-freestanding, have no default
     * and operations that need entropy fail with WASP_IO_ERROR until
     * this is set. When set,
     * it is used instead of the platform source on every target. When
     * cleared (NULL value), the platform default is restored.
     *
     * Input type: WaspSysRandomSecureFn (function pointer, or NULL)
     */
    WASP_SYS_OPT_RANDOM_SECURE = 3,
    WASP_SYS_OPT_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspSysOption;

/**
 * Set a system-level option.
 *
 * Configures a process-global implementation function. These should be
 * set once at startup before using any terminal functionality that
 * depends on them.
 *
 * @param option The option to set
 * @param value  Pointer to the value (type depends on the option),
 *               or NULL to clear it
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the
 *         option is not recognized
 */
WASP_API WaspResult wasp_sys_set(WaspSysOption option,
                                           const void* value);

/**
 * Built-in log callback that writes to stderr.
 *
 * Formats each message as "[level](scope): message\n".
 * Can be passed directly to wasp_sys_set():
 *
 * @code
 * wasp_sys_set(WASP_SYS_OPT_LOG, &wasp_sys_log_stderr);
 * @endcode
 */
WASP_API void wasp_sys_log_stderr(void* userdata,
                                         WaspSysLogLevel level,
                                         const uint8_t* scope,
                                         size_t scope_len,
                                         const uint8_t* message,
                                         size_t message_len);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* WASP_VT_SYS_H */
