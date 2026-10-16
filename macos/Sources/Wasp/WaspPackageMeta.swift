import Foundation
import os

// This defines the minimal information required so all other files can do
// `extension Wasp` to add more to it. This purposely has minimal
// dependencies so things like our dock tile plugin can use it.
enum Wasp {
    // The primary logger used by the WaspKit libraries.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "wasp"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}
}
