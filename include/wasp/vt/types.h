/**
 * @file types.h
 *
 * Common types, macros, and utilities for libwasp-vt.
 */

#ifndef WASP_VT_TYPES_H
#define WASP_VT_TYPES_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define WASP_STATIC
// before including this header to make this a no-op.
#ifndef WASP_API
#if defined(WASP_STATIC)
  #define WASP_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef WASP_BUILD_SHARED
    #define WASP_API __declspec(dllexport)
  #else
    #define WASP_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define WASP_API __attribute__((visibility("default")))
#else
  #define WASP_API
#endif
#endif

/**
 * Enum int-sizing helpers.
 *
 * The Zig side backs all C enums with c_int, so the C declarations
 * must use int as their underlying type to maintain ABI compatibility.
 *
 * C++11 and C23 support explicit enum underlying types with
 * `enum : int { ... }`. Clang and GCC 13+ also support this syntax as
 * an extension in older C language modes, so use it when available.
 *
 * Other pre-C23 C compilers are free to choose any type that can
 * represent all values (C11 §6.7.2.2). For those compilers, we add an
 * INT_MAX sentinel as the last entry so the compatible type must be
 * able to represent INT_MAX. The exact compatible type and its
 * signedness remain implementation-defined in this fallback.
 *
 * INT_MAX is used rather than a fixed constant like 0xFFFFFFFF
 * because enum constants must have type int in pre-C23 C. Values above
 * INT_MAX are a constraint violation there; compilers that accept them
 * may interpret them as negative values via two's complement, which can
 * collide with legitimate negative enum values.
 *
 * Usage:
 * @code
 * typedef enum WASP_ENUM_TYPED {
 *     FOO_A = 0,
 *     FOO_B = 1,
 *     FOO_MAX_VALUE = WASP_ENUM_MAX_VALUE,
 * } Foo;
 * @endcode
 */
#if defined(__cplusplus) && \
    (__cplusplus >= 201103L || (defined(_MSC_VER) && _MSC_VER >= 1700))
#define WASP_ENUM_TYPED : int
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define WASP_ENUM_TYPED : int
#elif defined(__clang__)
  #if __has_extension(c_fixed_enum)
    #define WASP_ENUM_TYPED : int
  #else
    #define WASP_ENUM_TYPED
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 13
#define WASP_ENUM_TYPED : int
#else
#define WASP_ENUM_TYPED
#endif
#define WASP_ENUM_MAX_VALUE INT_MAX

/**
 * Result codes for libwasp-vt operations.
 */
typedef enum WASP_ENUM_TYPED {
    /** Operation completed successfully */
    WASP_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    WASP_OUT_OF_MEMORY = -1,
    /** Operation failed due to invalid value */
    WASP_INVALID_VALUE = -2,
    /** Operation failed because the provided buffer was too small */
    WASP_OUT_OF_SPACE = -3,
    /** The requested value has no value */
    WASP_NO_VALUE = -4,
    /** Operation failed while reading from or writing to external I/O */
    WASP_IO_ERROR = -5,
    /** Operation failed because encoded input exceeded a configured limit */
    WASP_LIMIT_EXCEEDED = -6,
    /**
     * Operation was rejected by a safety check (e.g. pasted text that could
     * inject commands). Nothing was done. Confirm with the user and retry
     * with the operation's allow flag set.
     */
    WASP_REJECTED = -7,
    WASP_RESULT_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspResult;

/* ---- Opaque handles ---- */

/**
 * Opaque handle to a terminal instance.
 *
 * @ingroup terminal
 */
typedef struct WaspTerminalImpl* WaspTerminal;

/**
 * Opaque handle to an incremental terminal snapshot decoder.
 *
 * @ingroup snapshot
 */
typedef struct WaspSnapshotDecoderImpl* WaspSnapshotDecoder;

/**
 * Opaque handle to a tracked grid reference.
 *
 * A tracked grid reference is owned by the caller and must be freed with
 * wasp_tracked_grid_ref_free(). If the terminal that created it is freed
 * first, the handle remains valid only for tracked-grid-ref APIs: it reports no
 * value and can still be freed.
 *
 * @ingroup grid_ref
 */
typedef struct WaspTrackedGridRefImpl* WaspTrackedGridRef;

/**
 * Opaque handle to a Kitty graphics image storage.
 *
 * Obtained via wasp_terminal_get() with
 * WASP_TERMINAL_DATA_KITTY_GRAPHICS. The pointer is borrowed from
 * the terminal and remains valid until the next mutating terminal call
 * (e.g. wasp_terminal_vt_write() or wasp_terminal_reset()).
 *
 * @ingroup kitty_graphics
 */
typedef struct WaspKittyGraphicsImpl* WaspKittyGraphics;

/**
 * Opaque handle to a Kitty graphics image.
 *
 * Obtained via wasp_kitty_graphics_image() with an image ID. The
 * pointer is borrowed from the storage and remains valid until the next
 * mutating terminal call.
 *
 * @ingroup kitty_graphics
 */
typedef const struct WaspKittyGraphicsImageImpl* WaspKittyGraphicsImage;

/**
 * Opaque handle to a Kitty graphics placement iterator.
 *
 * @ingroup kitty_graphics
 */
typedef struct WaspKittyGraphicsPlacementIteratorImpl* WaspKittyGraphicsPlacementIterator;

/**
 * Opaque handle to a render state instance.
 *
 * @ingroup render
 */
typedef struct WaspRenderStateImpl* WaspRenderState;

/**
 * Opaque handle to a render-state row iterator.
 *
 * @ingroup render
 */
typedef struct WaspRenderStateRowIteratorImpl* WaspRenderStateRowIterator;

/**
 * Opaque handle to render-state row cells.
 *
 * @ingroup render
 */
typedef struct WaspRenderStateRowCellsImpl* WaspRenderStateRowCells;

/**
 * Opaque handle to a terminal search.
 *
 * A search is bound to the terminal it was created with. It borrows the
 * terminal, so it never frees it, and the search must be freed with
 * wasp_search_free(). If the terminal is freed first, the search
 * detects this: calls that need the terminal fail cleanly and the
 * search can still be freed.
 *
 * @ingroup search
 */
typedef struct WaspSearchImpl* WaspSearch;

/**
 * Opaque handle to an SGR parser instance.
 *
 * This handle represents an SGR (Select Graphic Rendition) parser that can
 * be used to parse SGR sequences and extract individual text attributes.
 *
 * @ingroup sgr
 */
typedef struct WaspSgrParserImpl* WaspSgrParser;

/**
 * Opaque handle to a formatter instance.
 *
 * @ingroup formatter
 */
typedef struct WaspFormatterImpl* WaspFormatter;

/**
 * Opaque handle to an OSC parser instance.
 *
 * This handle represents an OSC (Operating System Command) parser that can
 * be used to parse the contents of OSC sequences.
 *
 * @ingroup osc
 */
typedef struct WaspOscParserImpl* WaspOscParser;

/**
 * Opaque handle to a single OSC command.
 *
 * This handle represents a parsed OSC (Operating System Command) command.
 * The command can be queried for its type and associated data.
 *
 * @ingroup osc
 */
typedef struct WaspOscCommandImpl* WaspOscCommand;

/* ---- Common value types ---- */

/**
 * Terminal content output format.
 *
 * @ingroup formatter
 */
typedef enum WASP_ENUM_TYPED {
  /** Plain text (no escape sequences). */
  WASP_FORMATTER_FORMAT_PLAIN,

  /** VT sequences preserving colors, styles, URLs, etc. */
  WASP_FORMATTER_FORMAT_VT,

  /** HTML with inline styles. */
  WASP_FORMATTER_FORMAT_HTML,
  WASP_FORMATTER_FORMAT_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspFormatterFormat;

/**
 * A borrowed byte string (pointer + length).
 *
 * The memory is not owned by this struct. The pointer is only valid
 * for the lifetime documented by the API that produces or consumes it.
 * Empty strings produced by the library have a non-NULL pointer to valid
 * storage.
 */
typedef struct {
  /** Pointer to the string bytes. */
  const uint8_t* ptr;

  /** Length of the string in bytes. */
  size_t len;
} WaspString;

/**
 * A caller-provided byte buffer.
 *
 * APIs that write to this type use `len` for the number of bytes written on
 * WASP_SUCCESS and the required byte capacity on WASP_OUT_OF_SPACE.
 */
typedef struct {
  /** Destination buffer for bytes. May be NULL when cap is 0 to query required size. */
  uint8_t* ptr;

  /** Capacity of ptr in bytes. */
  size_t cap;

  /** Bytes written on success, or required byte capacity on WASP_OUT_OF_SPACE. */
  size_t len;
} WaspBuffer;

/**
 * A surface-space position in pixels.
 *
 * This is not a terminal grid coordinate. It represents an x/y position in the
 * rendered surface coordinate space, with (0, 0) at the top-left of the
 * surface.
 */
typedef struct {
  /** X position in surface pixels. */
  double x;

  /** Y position in surface pixels. */
  double y;
} WaspSurfacePosition;

/**
 * A borrowed list of Unicode scalar values.
 *
 * Values are encoded as uint32_t scalar values. The memory is not owned by this
 * struct. The pointer is only valid for the lifetime documented by the API that
 * consumes or produces it.
 *
 * APIs may document special handling for NULL + len 0, such as “use defaults”.
 */
typedef struct {
  /** Pointer to Unicode scalar values. */
  const uint32_t* ptr;

  /** Number of entries in ptr. */
  size_t len;
} WaspCodepoints;

/**
 * Initialize a sized struct to zero and set its size field.
 *
 * Sized structs use a `size` field as the first member for ABI
 * compatibility. This macro zero-initializes the struct and sets the
 * size field to `sizeof(type)`, which allows the library to detect
 * which version of the struct the caller was compiled against.
 *
 * @param type The struct type to initialize
 * @return A zero-initialized struct with the size field set
 *
 * Example:
 * @code
 * WaspFormatterTerminalOptions opts = WASP_INIT_SIZED(WaspFormatterTerminalOptions);
 * opts.emit = WASP_FORMATTER_FORMAT_PLAIN;
 * opts.trim = true;
 * @endcode
 */
#ifdef __cplusplus
#define WASP_INIT_SIZED(type)                                      \
  ([]() noexcept {                                                    \
    type value{};                                                     \
    value.size = sizeof(value);                                       \
    return value;                                                     \
  }())
#else
#define WASP_INIT_SIZED(type) \
  ((type){ .size = sizeof(type) })
#endif

/**
 * Return the versioned libwasp-vt C type manifest for the current target.
 *
 * The manifest defines all the public types available in the linked
 * build. The types contain their layouts, enum values, union fields, and more.
 *
 * Language bindings, such as WebAssembly hosts, should obtain offsets,
 * sizes, alignments, array shapes, enum constants, and tagged-union arms from
 * this manifest rather than hardcoding them. Consumers should reject unknown
 * schema versions and verify the descriptors they require at initialization.
 *
 * Packed type descriptors define fields using `lsb` and `width`. `lsb` is
 * relative to bit zero of the containing numerical value; for nested packed
 * layouts it is relative to the immediate containing field. Tagged packed
 * unions select an inline arm layout using the named tag field. These layouts
 * describe the current linked build and are not a cross-version stability
 * promise.
 *
 * The formal format is defined by the
 * <a href="types.schema.json">libwasp-vt ABI manifest JSON Schema</a>.
 *
 * Example (abbreviated):
 * @code{.json}
 * {
 *   "schema": 1,
 *   "abi": {
 *     "target": "wasm32", "os": "freestanding", "environment": "none",
 *     "pointer_size": 4, "usize_size": 4, "max_alignment": 16,
 *     "endian": "little"
 *   },
 *   "types": {
 *     "WaspRenderStateData": {
 *       "kind": "enum", "size": 4, "align": 4,
 *       "underlying": "i32", "prefix": "WASP_RENDER_STATE_DATA_",
 *       "values": { "INVALID": 0, "DIRTY": 3, "MAX_VALUE": 2147483647 }
 *     },
 *     "WaspStyleColor": {
 *       "kind": "struct", "size": 16, "align": 8,
 *       "fields": {
 *         "tag": { "offset": 0, "size": 4,
 *                  "type": "WaspStyleColorTag" },
 *         "value": { "offset": 8, "size": 8,
 *                    "type": "WaspStyleColorValue", "tag": "tag",
 *                    "arms": { "NONE": null, "PALETTE": "palette",
 *                              "RGB": "rgb" } }
 *       }
 *     }
 *   }
 * }
 * @endcode
 *
 * The returned pointer is valid for the lifetime of the process.
 *
 * @return Pointer to the null-terminated JSON string.
 */
WASP_API const char *wasp_type_json(void);

#endif /* WASP_VT_TYPES_H */
