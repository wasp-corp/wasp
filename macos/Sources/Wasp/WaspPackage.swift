import os
import SwiftUI
import WaspKit

// MARK: C Extensions

extension Wasp {
    // The user notification category identifier
    static let userNotificationCategory = "com.mitchellh.wasp.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "com.mitchellh.wasp.userNotification.Show"
}

// MARK: Build Info

extension Wasp {
    struct Info {
        var mode: wasp_build_mode_e
        var version: String
    }

    static var info: Info {
        let raw = wasp_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) ?? "unknown"

        return Info(mode: raw.build_mode, version: String(version))
    }
}

// MARK: General Helpers

extension Wasp {
    enum LaunchSource: String {
        case cli
        case app
        case zig_run
    }

    /// Returns the mechanism that launched the app. This is based on an env var so
    /// its up to the env var being set in the correct circumstance.
    static var launchSource: LaunchSource {
        guard let envValue = ProcessInfo.processInfo.environment["WASP_MAC_LAUNCH_SOURCE"] else {
            // We default to the CLI because the app bundle always sets the
            // source. If its unset we assume we're in a CLI environment.
            return .cli
        }

        // If the env var is set but its unknown then we default back to the app.
        return LaunchSource(rawValue: envValue) ?? .app
    }
}

// MARK: Swift Types for C Types

extension Wasp {
    class AllocatedString {
        private let cString: wasp_string_s

        init(_ c: wasp_string_s) {
            self.cString = c
        }

        var string: String {
            guard let ptr = cString.ptr else { return "" }
            let data = Data(bytes: ptr, count: Int(cString.len))
            return String(data: data, encoding: .utf8) ?? ""
        }

        deinit {
            wasp_string_free(cString)
        }
    }
}

extension Wasp {
    enum SetFloatWIndow {
        case on
        case off
        case toggle

        static func from(_ c: wasp_action_float_window_e) -> Self? {
            switch c {
            case WASP_FLOAT_WINDOW_ON:
                return .on

            case WASP_FLOAT_WINDOW_OFF:
                return .off

            case WASP_FLOAT_WINDOW_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    enum SetSecureInput {
        case on
        case off
        case toggle

        static func from(_ c: wasp_action_secure_input_e) -> Self? {
            switch c {
            case WASP_SECURE_INPUT_ON:
                return .on

            case WASP_SECURE_INPUT_OFF:
                return .off

            case WASP_SECURE_INPUT_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    /// An enum that is used for the directions that a split focus event can change.
    enum SplitFocusDirection {
        case previous, next, up, down, left, right

        /// Initialize from a Wasp API enum.
        static func from(direction: wasp_action_goto_split_e) -> Self? {
            switch direction {
            case WASP_GOTO_SPLIT_PREVIOUS:
                return .previous

            case WASP_GOTO_SPLIT_NEXT:
                return .next

            case WASP_GOTO_SPLIT_UP:
                return .up

            case WASP_GOTO_SPLIT_DOWN:
                return .down

            case WASP_GOTO_SPLIT_LEFT:
                return .left

            case WASP_GOTO_SPLIT_RIGHT:
                return .right

            default:
                return nil
            }
        }

        func toNative() -> wasp_action_goto_split_e {
            switch self {
            case .previous:
                return WASP_GOTO_SPLIT_PREVIOUS

            case .next:
                return WASP_GOTO_SPLIT_NEXT

            case .up:
                return WASP_GOTO_SPLIT_UP

            case .down:
                return WASP_GOTO_SPLIT_DOWN

            case .left:
                return WASP_GOTO_SPLIT_LEFT

            case .right:
                return WASP_GOTO_SPLIT_RIGHT
            }
        }
    }

    /// Enum used for resizing splits. This is the direction the split divider will move.
    enum SplitResizeDirection {
        case up, down, left, right

        static func from(direction: wasp_action_resize_split_direction_e) -> Self? {
            switch direction {
            case WASP_RESIZE_SPLIT_UP:
                return .up
            case WASP_RESIZE_SPLIT_DOWN:
                return .down
            case WASP_RESIZE_SPLIT_LEFT:
                return .left
            case WASP_RESIZE_SPLIT_RIGHT:
                return .right
            default:
                return nil
            }
        }

        func toNative() -> wasp_action_resize_split_direction_e {
            switch self {
            case .up:
                return WASP_RESIZE_SPLIT_UP
            case .down:
                return WASP_RESIZE_SPLIT_DOWN
            case .left:
                return WASP_RESIZE_SPLIT_LEFT
            case .right:
                return WASP_RESIZE_SPLIT_RIGHT
            }
        }
    }
}

// MARK: SplitFocusDirection Extensions

extension Wasp.SplitFocusDirection {
    /// Convert to a SplitTree.FocusDirection for the given ViewType.
    func toSplitTreeFocusDirection<ViewType>() -> SplitTree<ViewType>.FocusDirection {
        switch self {
        case .previous:
            return .previous

        case .next:
            return .next

        case .up:
            return .spatial(.up)

        case .down:
            return .spatial(.down)

        case .left:
            return .spatial(.left)

        case .right:
            return .spatial(.right)
        }
    }
}

extension Wasp {
    /// One representation of clipboard contents. The data is binary-safe;
    /// textual consumers use `string`.
    struct ClipboardContent {
        let mime: String
        let data: Data

        /// The data as text, if it is valid UTF-8.
        var string: String? { String(data: data, encoding: .utf8) }

        static func from(content: wasp_clipboard_content_s) -> ClipboardContent? {
            guard let mimePtr = content.mime,
                  let dataPtr = content.data else {
                return nil
            }

            let data: Data = if content.len > 0 {
                Data(bytes: dataPtr, count: content.len)
            } else {
                Data()
            }

            return ClipboardContent(
                mime: String(cString: mimePtr),
                data: data
            )
        }
    }

    /// Enum for the macos-window-buttons config option
    enum MacOSWindowButtons: String {
        case visible
        case hidden
    }

    /// Enum for the macos-titlebar-proxy-icon config option
    enum MacOSTitlebarProxyIcon: String {
        case visible
        case hidden
    }

    /// Enum for auto-update-channel config option
    enum AutoUpdateChannel: String {
        case tip
        case stable
    }
}

// MARK: Surface Notification

extension Notification.Name {
    /// Configuration change. If the object is nil then it is app-wide. Otherwise its surface-specific.
    static let waspConfigDidChange = Notification.Name("com.mitchellh.wasp.configDidChange")
    static let WaspConfigChangeKey = waspConfigDidChange.rawValue

    /// Color change. Object is the surface changing.
    static let waspColorDidChange = Notification.Name("com.mitchellh.wasp.waspColorDidChange")
    static let WaspColorChangeKey = waspColorDidChange.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let waspMoveTab = Notification.Name("com.mitchellh.wasp.moveTab")
    static let WaspMoveTabKey = waspMoveTab.rawValue

    /// Close tab
    static let waspCloseTab = Notification.Name("com.mitchellh.wasp.closeTab")

    /// Close other tabs
    static let waspCloseOtherTabs = Notification.Name("com.mitchellh.wasp.closeOtherTabs")

    /// Close tabs to the right of the focused tab
    static let waspCloseTabsOnTheRight = Notification.Name("com.mitchellh.wasp.closeTabsOnTheRight")

    /// Close window
    static let waspCloseWindow = Notification.Name("com.mitchellh.wasp.closeWindow")

    /// Resize the window to a default size.
    static let waspResetWindowSize = Notification.Name("com.mitchellh.wasp.resetWindowSize")

    /// Ring the bell
    static let waspBellDidRing = Notification.Name("com.mitchellh.wasp.waspBellDidRing")

    /// The active selection changed
    static let waspSelectionDidChange = Notification.Name("com.mitchellh.wasp.waspSelectionDidChange")

    /// Readonly mode changed
    static let waspDidChangeReadonly = Notification.Name("com.mitchellh.wasp.didChangeReadonly")
    static let ReadonlyKey = waspDidChangeReadonly.rawValue + ".readonly"
    static let waspCommandPaletteDidToggle = Notification.Name("com.mitchellh.wasp.commandPaletteDidToggle")

    /// Toggle maximize of current window
    static let waspMaximizeDidToggle = Notification.Name("com.mitchellh.wasp.maximizeDidToggle")

    /// Notification sent when scrollbar updates
    static let waspDidUpdateScrollbar = Notification.Name("com.mitchellh.wasp.didUpdateScrollbar")
    static let ScrollbarKey = waspDidUpdateScrollbar.rawValue + ".scrollbar"

    /// Focus the search field
    static let waspSearchFocus = Notification.Name("com.mitchellh.wasp.searchFocus")
}

// NOTE: I am moving all of these to Notification.Name extensions over time. This
// namespace was the old namespace.
extension Wasp.Notification {
    /// Used to pass a configuration along when creating a new tab/window/split.
    static let NewSurfaceConfigKey = "com.mitchellh.wasp.newSurfaceConfig"

    /// Posted when a new split is requested. The sending object will be the surface that had focus. The
    /// userdata has one key "direction" with the direction to split to.
    static let waspNewSplit = Notification.Name("com.mitchellh.wasp.newSplit")

    /// Close the calling surface.
    static let waspCloseSurface = Notification.Name("com.mitchellh.wasp.closeSurface")

    /// Focus previous/next split. Has a SplitFocusDirection in the userinfo.
    static let waspFocusSplit = Notification.Name("com.mitchellh.wasp.focusSplit")
    static let SplitDirectionKey = waspFocusSplit.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let waspGotoTab = Notification.Name("com.mitchellh.wasp.gotoTab")
    static let GotoTabKey = waspGotoTab.rawValue

    /// New tab. Has base surface config requested in userinfo.
    static let waspNewTab = Notification.Name("com.mitchellh.wasp.newTab")

    /// New window. Has base surface config requested in userinfo.
    static let waspNewWindow = Notification.Name("com.mitchellh.wasp.newWindow")

    /// Present terminal. Bring the surface's window to focus without activating the app.
    static let waspPresentTerminal = Notification.Name("com.mitchellh.wasp.presentTerminal")

    /// Toggle fullscreen of current window
    static let waspToggleFullscreen = Notification.Name("com.mitchellh.wasp.toggleFullscreen")
    static let FullscreenModeKey = waspToggleFullscreen.rawValue

    /// Notification sent to toggle split maximize/unmaximize.
    static let didToggleSplitZoom = Notification.Name("com.mitchellh.wasp.didToggleSplitZoom")

    /// Notification
    static let didReceiveInitialWindowFrame = Notification.Name("com.mitchellh.wasp.didReceiveInitialWindowFrame")
    static let FrameKey = "com.mitchellh.wasp.frame"

    /// Notification to render the inspector for a surface
    static let inspectorNeedsDisplay = Notification.Name("com.mitchellh.wasp.inspectorNeedsDisplay")

    /// Notification to show/hide the inspector
    static let didControlInspector = Notification.Name("com.mitchellh.wasp.didControlInspector")

    /// Notification sent to the active split view to resize the split.
    static let didResizeSplit = Notification.Name("com.mitchellh.wasp.didResizeSplit")
    static let ResizeSplitDirectionKey = didResizeSplit.rawValue + ".direction"
    static let ResizeSplitAmountKey = didResizeSplit.rawValue + ".amount"

    /// Notification sent to the split root to equalize split sizes
    static let didEqualizeSplits = Notification.Name("com.mitchellh.wasp.didEqualizeSplits")

    /// Notification that renderer health changed
    static let didUpdateRendererHealth = Notification.Name("com.mitchellh.wasp.didUpdateRendererHealth")

    /// Notifications related to key sequences
    static let didContinueKeySequence = Notification.Name("com.mitchellh.wasp.didContinueKeySequence")
    static let didEndKeySequence = Notification.Name("com.mitchellh.wasp.didEndKeySequence")
    static let KeySequenceKey = didContinueKeySequence.rawValue + ".key"

    /// Notifications related to key tables
    static let didChangeKeyTable = Notification.Name("com.mitchellh.wasp.didChangeKeyTable")
    static let KeyTableKey = didChangeKeyTable.rawValue + ".action"
}

// Make the input enum hashable.
extension wasp_input_key_e: @retroactive Hashable {}
