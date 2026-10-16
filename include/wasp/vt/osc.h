/**
 * @file osc.h
 *
 * OSC (Operating System Command) sequence parser and command handling.
 */

#ifndef WASP_VT_OSC_H
#define WASP_VT_OSC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wasp/vt/types.h>
#include <wasp/vt/allocator.h>

/** @defgroup osc OSC Parser
 *
 * OSC (Operating System Command) sequence parser and command handling.
 *
 * The parser operates in a streaming fashion, processing input byte-by-byte
 * to handle OSC sequences that may arrive in fragments across multiple reads.
 * This interface makes it easy to integrate into most environments and avoids
 * over-allocating buffers.
 *
 * ## Basic Usage
 *
 * 1. Create a parser instance with wasp_osc_new()
 * 2. Feed bytes to the parser using wasp_osc_next() 
 * 3. Finalize parsing with wasp_osc_end() to get the command
 * 4. Query command type and extract data using wasp_osc_command_type()
 *    and wasp_osc_command_data()
 * 5. Call wasp_osc_reset() before parsing the next sequence
 * 6. Free the parser with wasp_osc_free() when done
 *
 * ## Ending a Sequence
 *
 * An OSC sequence normally ends with BEL (0x07) or ST (ESC followed by a
 * backslash). A program can also cancel a sequence partway through by
 * sending CAN (0x18) or SUB (0x1A) instead. A cancelled sequence has no
 * effect, even if the bytes before the cancel form a complete command.
 *
 * In every case, pass the byte that ended the sequence to
 * wasp_osc_end(). For CAN or SUB, it discards the sequence and returns
 * NULL:
 *
 * @code{.c}
 * // The program sent "ESC ] 2 ; hello" to set the window title, then
 * // sent CAN instead of a terminator.
 * const char* input = "2;hello";
 * for (size_t i = 0; input[i] != '\0'; i++) {
 *   wasp_osc_next(parser, (uint8_t)input[i]);
 * }
 *
 * WaspOscCommand command = wasp_osc_end(parser, 0x18);
 * // command is NULL, so the window title does not change.
 *
 * wasp_osc_reset(parser);
 * @endcode
 *
 * ## Unknown Commands
 *
 * Every OSC sequence starts with a number that says what it is, such as
 * 2 for the window title or 8 for a hyperlink. By default, a sequence whose
 * number the parser does not implement produces
 * WASP_OSC_COMMAND_INVALID, and its data is discarded.
 *
 * To implement such a sequence yourself, set
 * WASP_OSC_OPT_UNKNOWN_MAX_BYTES with wasp_osc_set(). The parser
 * then produces WASP_OSC_COMMAND_UNKNOWN for these sequences, and you
 * can read the raw sequence with WASP_OSC_DATA_UNKNOWN_CONTENT.
 *
 * @code{.c}
 * WaspOscParser parser;
 * wasp_osc_new(NULL, &parser);
 *
 * // Keep up to 1 KiB of each unknown sequence.
 * size_t max_bytes = 1024;
 * wasp_osc_set(parser, WASP_OSC_OPT_UNKNOWN_MAX_BYTES, &max_bytes);
 *
 * // Feed the bytes between ESC ] and the terminator. OSC 7400 is made up
 * // for this example, so the parser does not implement it.
 * const char* input = "7400;status=busy";
 * for (size_t i = 0; input[i] != '\0'; i++) {
 *   wasp_osc_next(parser, (uint8_t)input[i]);
 * }
 *
 * // This sequence ended with BEL (0x07).
 * WaspOscCommand command = wasp_osc_end(parser, 0x07);
 * if (wasp_osc_command_type(command) == WASP_OSC_COMMAND_UNKNOWN) {
 *   WaspString content;
 *   wasp_osc_command_data(command, WASP_OSC_DATA_UNKNOWN_CONTENT,
 *                            &content);
 *   // content now holds "7400;status=busy".
 * }
 *
 * wasp_osc_free(parser);
 * @endcode
 *
 * Only numbers the parser does not implement are reported this way. A
 * sequence with a number the parser does implement stays
 * WASP_OSC_COMMAND_INVALID when its contents are malformed.
 *
 * @{
 */

/**
 * OSC command types.
 *
 * @ingroup osc
 */
typedef enum WASP_ENUM_TYPED {
  WASP_OSC_COMMAND_INVALID = 0,
  WASP_OSC_COMMAND_CHANGE_WINDOW_TITLE = 1,
  WASP_OSC_COMMAND_CHANGE_WINDOW_ICON = 2,
  WASP_OSC_COMMAND_SEMANTIC_PROMPT = 3,
  WASP_OSC_COMMAND_CLIPBOARD_CONTENTS = 4,
  WASP_OSC_COMMAND_REPORT_PWD = 5,
  WASP_OSC_COMMAND_MOUSE_SHAPE = 6,
  WASP_OSC_COMMAND_COLOR_OPERATION = 7,
  WASP_OSC_COMMAND_KITTY_COLOR_PROTOCOL = 8,
  WASP_OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION = 9,
  WASP_OSC_COMMAND_HYPERLINK_START = 10,
  WASP_OSC_COMMAND_HYPERLINK_END = 11,
  WASP_OSC_COMMAND_CONEMU_SLEEP = 12,
  WASP_OSC_COMMAND_CONEMU_SHOW_MESSAGE_BOX = 13,
  WASP_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE = 14,
  WASP_OSC_COMMAND_CONEMU_PROGRESS_REPORT = 15,
  WASP_OSC_COMMAND_CONEMU_WAIT_INPUT = 16,
  WASP_OSC_COMMAND_CONEMU_GUIMACRO = 17,
  WASP_OSC_COMMAND_CONEMU_RUN_PROCESS = 18,
  WASP_OSC_COMMAND_CONEMU_OUTPUT_ENVIRONMENT_VARIABLE = 19,
  WASP_OSC_COMMAND_CONEMU_XTERM_EMULATION = 20,
  WASP_OSC_COMMAND_CONEMU_COMMENT = 21,
  WASP_OSC_COMMAND_KITTY_TEXT_SIZING = 22,
  WASP_OSC_COMMAND_KITTY_CLIPBOARD_PROTOCOL = 23,
  WASP_OSC_COMMAND_KITTY_DND_PROTOCOL = 24,
  WASP_OSC_COMMAND_HIERARCHICAL_CONTEXT = 25,
  WASP_OSC_COMMAND_KITTY_DESKTOP_NOTIFICATION = 26,

  /**
   * An OSC sequence whose number the parser does not implement. Read it
   * with the WASP_OSC_DATA_UNKNOWN_* data types.
   *
   * Only produced when WASP_OSC_OPT_UNKNOWN_MAX_BYTES is nonzero.
   * Otherwise these sequences are WASP_OSC_COMMAND_INVALID.
   */
  WASP_OSC_COMMAND_UNKNOWN = 27,

  /**
   * A program status report or support query (OSC 7501), which a program
   * sends to say what it is doing, such as working or waiting on the user.
   *
   * The OSC parser only identifies this command. To receive the report's
   * contents, use a terminal with WASP_TERMINAL_OPT_PROGRAM_STATUS
   * instead (see WaspTerminalProgramStatus).
   */
  WASP_OSC_COMMAND_PROGRAM_STATUS = 28,
  WASP_OSC_COMMAND_TYPE_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspOscCommandType;

/**
 * How an OSC sequence was ended.
 *
 * Programs can end an OSC sequence in two ways. When you reply to a
 * sequence, end the reply the same way the program ended its request.
 * Some programs only recognize replies that match.
 *
 * @ingroup osc
 */
typedef enum WASP_ENUM_TYPED {
  /** The string terminator (ST): ESC followed by a backslash (0x1B 0x5C). */
  WASP_OSC_TERMINATOR_ST = 0,

  /** The bell character, BEL (byte 0x07). */
  WASP_OSC_TERMINATOR_BEL = 1,
  WASP_OSC_TERMINATOR_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspOscTerminator;

/**
 * OSC parser options, set with wasp_osc_set().
 *
 * @ingroup osc
 */
typedef enum WASP_ENUM_TYPED {
  /**
   * The most bytes to keep from each OSC sequence whose number the parser
   * does not implement.
   *
   * Zero, the default, discards these sequences and they produce
   * WASP_OSC_COMMAND_INVALID. Any other value makes them produce
   * WASP_OSC_COMMAND_UNKNOWN. A NULL value pointer sets the limit back
   * to zero.
   *
   * A sequence longer than the limit is still reported. Its content holds
   * the first bytes up to the limit, and WASP_OSC_DATA_UNKNOWN_TRUNCATED
   * is true.
   *
   * Limits up to 2048 bytes use a buffer the parser already owns and never
   * allocate memory. Larger limits allocate memory from the parser's
   * allocator for each unknown sequence.
   *
   * Input type: size_t*
   */
  WASP_OSC_OPT_UNKNOWN_MAX_BYTES = 0,
  WASP_OSC_OPT_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspOscOption;

/**
 * OSC command data types.
 * 
 * These values specify what type of data to extract from an OSC command
 * using `wasp_osc_command_data`.
 *
 * @ingroup osc
 */
typedef enum WASP_ENUM_TYPED {
  /** Invalid data type. Never results in any data extraction. */
  WASP_OSC_DATA_INVALID = 0,
  
  /** 
   * Window title string data.
   *
   * Valid for: WASP_OSC_COMMAND_CHANGE_WINDOW_TITLE
   *
   * Output type: const char ** (pointer to null-terminated string)
   *
   * Lifetime: Valid until the next call to any wasp_osc_* function with 
   * the same parser instance. Memory is owned by the parser.
   */
  WASP_OSC_DATA_CHANGE_WINDOW_TITLE_STR = 1,

  /**
   * The raw bytes of an unknown sequence: everything that was passed to
   * wasp_osc_next(), including the number at the start. For example,
   * the sequence `ESC ] 7400;status=busy BEL` gives
   * `7400;status=busy`. The bytes are not null-terminated.
   *
   * Valid for: WASP_OSC_COMMAND_UNKNOWN
   *
   * Output type: WaspString *
   *
   * Lifetime: Valid until the next call to any wasp_osc_* function with
   * the same parser instance. Memory is owned by the parser.
   */
  WASP_OSC_DATA_UNKNOWN_CONTENT = 2,

  /**
   * True if the unknown sequence was longer than
   * WASP_OSC_OPT_UNKNOWN_MAX_BYTES, or memory ran out while reading it.
   * In that case the content holds only the beginning of the sequence.
   *
   * Valid for: WASP_OSC_COMMAND_UNKNOWN
   *
   * Output type: bool *
   */
  WASP_OSC_DATA_UNKNOWN_TRUNCATED = 3,

  /**
   * How the unknown sequence was ended, based on the terminator passed to
   * wasp_osc_end(). If you reply to the sequence, end the reply the same
   * way.
   *
   * Valid for: WASP_OSC_COMMAND_UNKNOWN
   *
   * Output type: WaspOscTerminator *
   */
  WASP_OSC_DATA_UNKNOWN_TERMINATOR = 4,
  WASP_OSC_DATA_MAX_VALUE = WASP_ENUM_MAX_VALUE,
} WaspOscCommandData;

/**
 * Create a new OSC parser instance.
 * 
 * Creates a new OSC (Operating System Command) parser using the provided
 * allocator. The parser must be freed using wasp_vt_osc_free() when
 * no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param parser Pointer to store the created parser handle
 * @return WASP_SUCCESS on success, or an error code on failure
 * 
 * @ingroup osc
 */
WASP_API WaspResult wasp_osc_new(const WaspAllocator *allocator, WaspOscParser *parser);

/**
 * Free an OSC parser instance.
 * 
 * Releases all resources associated with the OSC parser. After this call,
 * the parser handle becomes invalid and must not be used.
 * 
 * @param parser The parser handle to free (may be NULL)
 * 
 * @ingroup osc
 */
WASP_API void wasp_osc_free(WaspOscParser parser);

/**
 * Reset an OSC parser instance to its initial state.
 * 
 * Resets the parser state, clearing any partially parsed OSC sequences
 * and returning the parser to its initial state. This is useful for
 * reusing a parser instance or recovering from parse errors.
 * 
 * @param parser The parser handle to reset, must not be null.
 * 
 * @ingroup osc
 */
WASP_API void wasp_osc_reset(WaspOscParser parser);

/**
 * Set an option on an OSC parser.
 *
 * `value` points to the option's input type, which is listed in the
 * documentation for each WaspOscOption value. Pass NULL to restore the
 * option's default.
 *
 * Options stay set across wasp_osc_reset(). You can change an option
 * at any time, but a sequence that is already being parsed may keep the
 * old setting. It is simplest to set options before the first sequence.
 *
 * @param parser The parser handle
 * @param option The option to set
 * @param value Pointer to the new value, or NULL to restore the default
 * @return WASP_SUCCESS on success, or WASP_INVALID_VALUE if the parser
 *         is NULL
 *
 * @ingroup osc
 */
WASP_API WaspResult wasp_osc_set(WaspOscParser parser,
                                          WaspOscOption option,
                                          const void* value);

/**
 * Parse the next byte in an OSC sequence.
 * 
 * Processes a single byte as part of an OSC sequence. The parser maintains
 * internal state to track the progress through the sequence. Call this
 * function for each byte in the sequence data.
 *
 * When finished pumping the parser with bytes, call wasp_osc_end
 * to get the final result.
 * 
 * @param parser The parser handle, must not be null.
 * @param byte The next byte to parse
 * 
 * @ingroup osc
 */
WASP_API void wasp_osc_next(WaspOscParser parser, uint8_t byte);

/**
 * Finalize OSC parsing and retrieve the parsed command.
 * 
 * Call this after feeding every byte of the sequence to wasp_osc_next(),
 * except the byte that ended it. Pass that byte here as the terminator.
 *
 * If the sequence is not a valid command, this returns NULL. You don't need
 * to check for NULL before calling wasp_osc_command_type(), which
 * returns WASP_OSC_COMMAND_INVALID for it.
 *
 * Commands that reply to the program, such as color queries, end their
 * reply the same way the request ended. A terminator of 0x07 (BEL) gets a
 * BEL reply, and any other byte gets an ST reply. Commands that don't
 * reply ignore the terminator.
 *
 * If the program cancelled the sequence with CAN (0x18) or SUB (0x1A),
 * pass that byte as the terminator. The sequence is then discarded and
 * this returns NULL, whatever command it contained. This matches xterm.
 * The "Ending a Sequence" section of the overview has an example.
 * 
 * The returned command handle is valid until the next call to any 
 * `wasp_osc_*` function with the same parser instance with the exception
 * of command introspection functions such as `wasp_osc_command_type`.
 * 
 * @param parser The parser handle, must not be null.
 * @param terminator The byte that ended the OSC sequence: 0x07 for BEL,
 *        0x5C for ST, or 0x18 (CAN) or 0x1A (SUB) if it was cancelled
 * @return Handle to the parsed OSC command, or NULL if the sequence is not
 *         a valid command or was cancelled
 * 
 * @ingroup osc
 */
WASP_API WaspOscCommand wasp_osc_end(WaspOscParser parser, uint8_t terminator);

/**
 * Get the type of an OSC command.
 * 
 * Returns the type identifier for the given OSC command. This can be used
 * to determine what kind of command was parsed and what data might be
 * available from it.
 * 
 * @param command The OSC command handle to query (may be NULL)
 * @return The command type, or WASP_OSC_COMMAND_INVALID if command is NULL
 * 
 * @ingroup osc
 */
WASP_API WaspOscCommandType wasp_osc_command_type(WaspOscCommand command);

/**
 * Extract data from an OSC command.
 * 
 * Extracts typed data from the given OSC command based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid command types, output types, and memory
 * safety information are documented in the `WaspOscCommandData` enum.
 *
 * @param command The OSC command handle to query (may be NULL)
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return true if data extraction was successful, false otherwise
 * 
 * @ingroup osc
 */
WASP_API bool wasp_osc_command_data(WaspOscCommand command, WaspOscCommandData data, void *out);

/** @} */

#endif /* WASP_VT_OSC_H */
