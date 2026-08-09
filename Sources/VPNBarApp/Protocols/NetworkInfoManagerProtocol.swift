import Foundation

/// Protocol for managing network information (IP, geolocation, VPN interfaces).
@MainActor
protocol NetworkInfoManagerProtocol: AnyObject {
    /// Current network info, if available.
    var networkInfo: NetworkInfo? { get }

    /// Whether a fetch is currently in progress.
    var isLoading: Bool { get }

    /// True after a fetch attempt finished (success or failure). Reset when VPN connects / cache invalidated.
    /// Menu uses this so we show “fetching…” until the first attempt completes, not “unavailable”.
    var hasFinishedFetch: Bool { get }

    /// Refreshes network information (fire-and-forget).
    /// - Parameter force: If true, ignores cache and fetches fresh data.
    func refresh(force: Bool)

    /// Refreshes and waits for completion (or cache / timeout).
    @discardableResult
    func refreshAndWait(force: Bool, timeout: TimeInterval?) async -> NetworkInfo?

    /// Cleans up resources.
    func cleanup()
}
