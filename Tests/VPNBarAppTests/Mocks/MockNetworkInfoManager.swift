import Foundation
@testable import VPNBarApp

@MainActor
final class MockNetworkInfoManager: NetworkInfoManagerProtocol {
    var networkInfo: NetworkInfo?
    var isLoading = false
    var refreshCalled = false
    var refreshForce = false
    var cleanupCalled = false
    var refreshAndWaitCalled = false

    func refresh(force: Bool) {
        refreshCalled = true
        refreshForce = force
    }

    func refreshAndWait(force: Bool, timeout: TimeInterval?) async -> NetworkInfo? {
        refreshAndWaitCalled = true
        refreshCalled = true
        refreshForce = force
        return networkInfo
    }

    func cleanup() {
        cleanupCalled = true
    }

    func reset() {
        networkInfo = nil
        isLoading = false
        refreshCalled = false
        refreshForce = false
        cleanupCalled = false
        refreshAndWaitCalled = false
    }
}
