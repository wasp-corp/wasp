import Foundation
import WaspVt

// Create a terminal with a small grid
var terminal: WaspTerminal?
let result = wasp_terminal_new(nil, &terminal, 80, 24)
guard result == WASP_SUCCESS, let terminal else {
    fatalError("Failed to create terminal")
}

// Write some VT-encoded content
let text = "Hello from \u{1b}[1mSwift\u{1b}[0m via xcframework!\r\n"
text.withCString { ptr in
    wasp_terminal_vt_write(terminal, ptr, strlen(ptr))
}

// Format the terminal contents as plain text
var fmtOpts = WaspFormatterTerminalOptions()
fmtOpts.size = MemoryLayout<WaspFormatterTerminalOptions>.size
fmtOpts.emit = WASP_FORMATTER_FORMAT_PLAIN
fmtOpts.trim = true

var formatter: WaspFormatter?
let fmtResult = wasp_formatter_terminal_new(nil, &formatter, terminal, fmtOpts)
guard fmtResult == WASP_SUCCESS, let formatter else {
    fatalError("Failed to create formatter")
}

var buf: UnsafeMutablePointer<UInt8>?
var len: Int = 0
let allocResult = wasp_formatter_format_alloc(formatter, nil, &buf, &len)
guard allocResult == WASP_SUCCESS, let buf else {
    fatalError("Failed to format")
}

print("Plain text (\(len) bytes):")
let data = Data(bytes: buf, count: len)
print(String(data: data, encoding: .utf8) ?? "<invalid UTF-8>")

wasp_free(nil, buf, len)
wasp_formatter_free(formatter)
wasp_terminal_free(terminal)
