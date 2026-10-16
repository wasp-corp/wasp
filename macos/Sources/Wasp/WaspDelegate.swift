import Foundation

extension Wasp {
    /// This is a delegate that should be applied to your global app delegate for WaspKit
    /// to perform app-global operations.
    protocol Delegate {
        /// Look up a surface within the application by ID.
        func waspSurface(id: UUID) -> SurfaceView?
    }
}
