import Foundation

extension Notification.Name {
    static let hotkeyDidChange = Notification.Name("HotkeyDidChange")
    static let showConnectionNameDidChange = Notification.Name("ShowConnectionNameDidChange")
    static let vpnConnectionStatusDidUpdate = Notification.Name("VPNConnectionStatusDidUpdate")
    /// Fired when public IP / geo fetch state changes (loading, success, failure). No polling.
    static let networkInfoDidChange = Notification.Name("NetworkInfoDidChange")
}
