import AppKit

// MARK: Wasp Delegate

/// This implements the Wasp app delegate protocol which is used by the Wasp
/// APIs for app-global information.
extension AppDelegate: Wasp.Delegate {
    func waspSurface(id: UUID) -> Wasp.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }

            for surface in controller.surfaceTree where surface.id == id {
                return surface
            }
        }

        return nil
    }
}
