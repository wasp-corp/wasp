/**
 * @file screen.h
 *
 * Terminal screen cell and row types.
 */

#ifndef WASP_VT_SCREEN_H
#define WASP_VT_SCREEN_H

#include <stdbool.h>
#include <stdint.h>
#include <wasp/vt/color.h>
#include <wasp/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup screen Screen
 *
 * Terminal screen cell and row types.
 *
 * These types represent the contents of a terminal screen. A WaspCell
 * is a single grid cell and a WaspRow is a single row. Cell fields can
 * be accessed via wasp_cell_get() or decoded from the packed layout in
 * wasp_type_json(). Rows are opaque and accessed via wasp_row_get().
 *
 * @{
 */

/**
 * Packed cell value.
 *
 * Represents a single terminal cell. Portable callers can query fields via
 * wasp_cell_get(). Boundary-sensitive callers can decode the packed value
 * using the WaspCell descriptor returned by wasp_type_json(). The
 * manifest is authoritative for the linked build; hardcoding bit positions
 * is unsupported.
 *
 * @ingroup screen
 */
typedef uint64_t WaspCell;

/**
 * Opaque row value.
 *
 * Represents a single terminal row. The internal layout is opaque and
 * must be queried via wasp_row_get(). Obtain row values from
 * terminal query APIs.
 *
 * @ingroup screen
 */
typedef uint64_t WaspRow;

/**
 * A borrowed view of contiguous raw cell values.
 *
 * The memory is not owned by this struct. The pointer is only valid
 * for the lifetime documented by the API that produces it. Each value
 * can be queried via wasp_cell_get() or decoded using the WaspCell
 * packed descriptor returned by wasp_type_json().
 *
 * @ingroup screen
 */
typedef struct {
  /** Pointer to len contiguous cell values. */
  const WaspCell* ptr;

  /** Number of cells. */
  size_t len;
} WaspCellsView;

/**
 * Cell content tag.
 *
 * Describes what kind of content a cell holds.
 *
 * @ingroup screen
 */
typedef enum WASP_ENUM_TYPED {
  /** A single codepoint (may be zero for empty). */
  WASP_CELL_CONTENT_CODEPOINT = 0,

  /** A codepoint that is part of a multi-codepoint grapheme cluster. */
  WASP_CELL_CONTENT_CODEPOINT_GRAPHEME = 1,

  /** No text; background color from palette. */
  WASP_CELL_CONTENT_BG_COLOR_PALETTE = 2,

  /** No text; background color as RGB. */
  WASP_CELL_CONTENT_BG_COLOR_RGB = 3,
  WASP_CELL_CONTENT_TAG_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspCellContentTag;

/**
 * Cell wide property.
 *
 * Describes the width behavior of a cell.
 *
 * @ingroup screen
 */
typedef enum WASP_ENUM_TYPED {
  /** Not a wide character, cell width 1. */
  WASP_CELL_WIDE_NARROW = 0,

  /** Wide character, cell width 2. */
  WASP_CELL_WIDE_WIDE = 1,

  /** Spacer after wide character. Do not render. */
  WASP_CELL_WIDE_SPACER_TAIL = 2,

  /** Spacer at end of soft-wrapped line for a wide character. */
  WASP_CELL_WIDE_SPACER_HEAD = 3,
  WASP_CELL_WIDE_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspCellWide;

/**
 * Semantic content type of a cell.
 *
 * Set by semantic prompt sequences (OSC 133) to distinguish between
 * command output, user input, and shell prompt text.
 *
 * @ingroup screen
 */
typedef enum WASP_ENUM_TYPED {
  /** Regular output content, such as command output. */
  WASP_CELL_SEMANTIC_OUTPUT = 0,

  /** Content that is part of user input. */
  WASP_CELL_SEMANTIC_INPUT = 1,

  /** Content that is part of a shell prompt. */
  WASP_CELL_SEMANTIC_PROMPT = 2,
  WASP_CELL_SEMANTIC_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspCellSemanticContent;

/**
 * Cell data types.
 *
 * These values specify what type of data to extract from a cell
 * using `wasp_cell_get`.
 *
 * @ingroup screen
 */
typedef enum WASP_ENUM_TYPED {
  /** Invalid data type. Never results in any data extraction. */
  WASP_CELL_DATA_INVALID = 0,

  /**
   * The codepoint of the cell (0 if empty or bg-color-only).
   *
   * Output type: uint32_t *
   */
  WASP_CELL_DATA_CODEPOINT = 1,

  /**
   * The content tag describing what kind of content is in the cell.
   *
   * Output type: WaspCellContentTag *
   */
  WASP_CELL_DATA_CONTENT_TAG = 2,

  /**
   * The wide property of the cell.
   *
   * Output type: WaspCellWide *
   */
  WASP_CELL_DATA_WIDE = 3,

  /**
   * Whether the cell has text to render.
   *
   * Output type: bool *
   */
  WASP_CELL_DATA_HAS_TEXT = 4,

  /**
   * Whether the cell has non-default styling.
   *
   * Output type: bool *
   */
  WASP_CELL_DATA_HAS_STYLING = 5,

  /**
   * The style ID for the cell (for use with style lookups).
   *
   * Output type: uint16_t *
   */
  WASP_CELL_DATA_STYLE_ID = 6,

  /**
   * Whether the cell has a hyperlink.
   *
   * Output type: bool *
   */
  WASP_CELL_DATA_HAS_HYPERLINK = 7,

  /**
   * Whether the cell is protected.
   *
   * Output type: bool *
   */
  WASP_CELL_DATA_PROTECTED = 8,

  /**
   * The semantic content type of the cell (from OSC 133).
   *
   * Output type: WaspCellSemanticContent *
   */
  WASP_CELL_DATA_SEMANTIC_CONTENT = 9,

  /**
   * The palette index for the cell's background color.
   * Only valid when content_tag is WASP_CELL_CONTENT_BG_COLOR_PALETTE.
   *
   * Output type: WaspColorPaletteIndex *
   */
  WASP_CELL_DATA_COLOR_PALETTE = 10,

  /**
   * The RGB value for the cell's background color.
   * Only valid when content_tag is WASP_CELL_CONTENT_BG_COLOR_RGB.
   *
   * Output type: WaspColorRgb *
   */
  WASP_CELL_DATA_COLOR_RGB = 11,
  WASP_CELL_DATA_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspCellData;

/**
 * Row semantic prompt state.
 *
 * Indicates whether any cells in a row are part of a shell prompt,
 * as reported by OSC 133 sequences.
 *
 * @ingroup screen
 */
typedef enum WASP_ENUM_TYPED {
  /** No prompt cells in this row. */
  WASP_ROW_SEMANTIC_NONE = 0,

  /** Prompt cells exist and this is a primary prompt line. */
  WASP_ROW_SEMANTIC_PROMPT = 1,

  /** Prompt cells exist and this is a continuation line. */
  WASP_ROW_SEMANTIC_PROMPT_CONTINUATION = 2,
  WASP_ROW_SEMANTIC_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspRowSemanticPrompt;

/**
 * Row data types.
 *
 * These values specify what type of data to extract from a row
 * using `wasp_row_get`.
 *
 * @ingroup screen
 */
typedef enum WASP_ENUM_TYPED {
  /** Invalid data type. Never results in any data extraction. */
  WASP_ROW_DATA_INVALID = 0,

  /**
   * Whether this row is soft-wrapped.
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_WRAP = 1,

  /**
   * Whether this row is a continuation of a soft-wrapped row.
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_WRAP_CONTINUATION = 2,

  /**
   * Whether any cells in this row have grapheme clusters.
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_GRAPHEME = 3,

  /**
   * Whether any cells in this row have styling (may have false positives).
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_STYLED = 4,

  /**
   * Whether any cells in this row have hyperlinks (may have false positives).
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_HYPERLINK = 5,

  /**
   * The semantic prompt state of this row.
   *
   * Output type: WaspRowSemanticPrompt *
   */
  WASP_ROW_DATA_SEMANTIC_PROMPT = 6,

  /**
   * Whether this row contains a Kitty virtual placeholder.
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER = 7,

  /**
   * Whether this row is dirty and requires a redraw.
   *
   * Output type: bool *
   */
  WASP_ROW_DATA_DIRTY = 8,
  WASP_ROW_DATA_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspRowData;

/**
 * Get data from a cell.
 *
 * Extracts typed data from the given cell based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid data types and output types are documented
 * in the `WaspCellData` enum.
 *
 * @param cell The cell value
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the
 *         data type is invalid
 *
 * @ingroup screen
 */
WASP_API WaspResult wasp_cell_get(WaspCell cell,
                                WaspCellData data,
                                void *out);

/**
 * Get multiple data fields from a cell in a single call.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param cell The cell value
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return WASP_SUCCESS if all queries succeed
 *
 * @ingroup screen
 */
WASP_API WaspResult wasp_cell_get_multi(WaspCell cell,
                                     size_t count,
                                     const WaspCellData* keys,
                                     void** values,
                                     size_t* out_written);

/**
 * Get data from a row.
 *
 * Extracts typed data from the given row based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid data types and output types are documented
 * in the `WaspRowData` enum.
 *
 * @param row The row value
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return WASP_SUCCESS on success, WASP_INVALID_VALUE if the
 *         data type is invalid
 *
 * @ingroup screen
 */
WASP_API WaspResult wasp_row_get(WaspRow row,
                               WaspRowData data,
                               void *out);

/**
 * Get multiple data fields from a row in a single call.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param row The row value
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return WASP_SUCCESS if all queries succeed
 *
 * @ingroup screen
 */
WASP_API WaspResult wasp_row_get_multi(WaspRow row,
                                    size_t count,
                                    const WaspRowData* keys,
                                    void** values,
                                    size_t* out_written);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* WASP_VT_SCREEN_H */
