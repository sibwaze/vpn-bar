import Foundation
@testable import VPNBarApp

@MainActor
final class MockNetworkInfoManager: NetworkInfoManagerProtocol {
    var networkInfo: NetworkInfo?
    var isLoading = false
    var hasFinishedFetch = false
    var refreshCalled = false
    var refreshForce = false
    var cleanupCalled = false
    var refreshAndWaitCalled = false

    func refresh(force: Bool) {
        refreshCalled = true
        refreshForce = force
        if networkInfo?.publicIP == nil {
            isLoading = true
            hasFinishedFetch = false
        }
    }

    func refreshAndWait(force: Bool, timeout: TimeInterval?) async -> NetworkInfo? {
        refreshAndWaitCalled = true
        refreshCalled = true
        refreshForce = force
        isLoading = false
        hasFinishedFetch = true
        return networkInfo
    }

    func cleanup() {
        cleanupCalled = true
    }

    func reset() {
        networkInfo = nil
        isLoading = false
        hasFinishedFetch = false
        refreshCalled = false
        refreshForce = false
        cleanupCalled = false
        refreshAndWaitCalled = false
    }
}
