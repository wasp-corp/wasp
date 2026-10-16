import WaspKit

extension FullscreenMode {
    /// Initialize from a Wasp fullscreen action.
    static func from(wasp: wasp_action_fullscreen_e) -> Self? {
        return switch wasp {
        case WASP_FULLSCREEN_NATIVE:
                .native

        case WASP_FULLSCREEN_MACOS_NON_NATIVE:
                .nonNative

        case WASP_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU:
                .nonNativeVisibleMenu

        case WASP_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH:
                .nonNativePaddedNotch

        default:
            nil
        }
    }
}
