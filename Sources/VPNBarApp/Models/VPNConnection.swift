import Foundation

/// VPN connection model used for displaying and managing status.
struct VPNConnection: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    var status: VPNStatus

    enum VPNStatus: Equatable, Hashable {
        case disconnected
        case connecting
        case connected
        case disconnecting

        var isActive: Bool {
            self == .connected || self == .connecting
        }

        var localizedDescription: String {
            switch self {
            case .connected:
                return NSLocalizedString("menu.status.connected", comment: "")
            case .connecting:
                return NSLocalizedString("menu.status.connecting", comment: "")
            case .disconnecting:
                return NSLocalizedString("menu.status.disconnecting", comment: "")
            case .disconnected:
                return NSLocalizedString("menu.status.disconnected", comment: "")
            }
        }
    }
}
