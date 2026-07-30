import Foundation
import Combine

/// Protocol for managing VPN connections.
@MainActor
protocol VPNManagerProtocol: ObservableObject {
    var connections: [VPNConnection] { get }
    var hasActiveConnection: Bool { get }
    var loadingError: VPNError? { get }

    func loadConnections(forceReload: Bool)
    func connect(to connectionID: String, retryCount: Int)
    func disconnect(from connectionID: String)
    func toggleConnection(_ connectionID: String)
    func cleanup()
}

extension VPNManagerProtocol {
    func connect(to connectionID: String) {
        connect(to: connectionID, retryCount: AppConstants.defaultRetryCount)
    }
}
