import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Wasp -> DockTilePlugin
    static let waspIconDidChange = Notification.Name("com.mitchellh.wasp.iconDidChange")
}
