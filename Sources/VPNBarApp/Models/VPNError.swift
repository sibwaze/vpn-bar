import Foundation

/// Typed errors for VPN manager.
enum VPNError: LocalizedError, Equatable {
    case noConfigurations
    case connectionNotFound(id: String)
    case sessionNotFound(id: String)
    case sessionCreationFailed(id: String)
    case connectionFailed(underlying: String?)

    var errorDescription: String? {
        switch self {
        case .noConfigurations:
            return NSLocalizedString("error.vpn.noConfigurations", comment: "")
        case .connectionNotFound(let id):
            return Self.format(key: "error.vpn.connectionNotFound", param: id)
        case .sessionNotFound(let id):
            return Self.format(key: "error.vpn.sessionNotFound", param: id)
        case .sessionCreationFailed(let id):
            return Self.format(key: "error.vpn.sessionCreateFailed", param: id)
        case .connectionFailed(let underlying):
            return underlying ?? NSLocalizedString("error.vpn.connectionFailed", comment: "")
        }
    }

    private static func format(key: String, param: String) -> String {
        let fmt = NSLocalizedString(key, comment: "")
        return fmt.contains("%@") ? String(format: fmt, param) : "\(fmt) \(param)"
    }
}
