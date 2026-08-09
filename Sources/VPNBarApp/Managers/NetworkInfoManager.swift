import Foundation
import os.log
import Darwin
import SystemConfiguration

/// Manages network information: public IP, geolocation, and VPN interfaces.
@MainActor
final class NetworkInfoManager: NetworkInfoManagerProtocol {
    static let shared = NetworkInfoManager()

    @Published private(set) var networkInfo: NetworkInfo?
    @Published private(set) var isLoading = false
    /// Becomes true when a GeoIP attempt completes (success or failure). Cleared on disconnect / new connect.
    private(set) var hasFinishedFetch = false

    private var lastFetchDate: Date?
    /// Single in-flight fetch; joined by concurrent callers (never "join" a finished task while isLoading was re-set).
    private var inFlightFetch: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var statusObserverToken: NSObjectProtocol?

    /// Dedicated session: short timeout, no shared cookie/cache interference.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AppConstants.NetworkInfo.requestTimeout
        config.timeoutIntervalForResource = AppConstants.NetworkInfo.requestTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {
        observeVPNStatusChanges()
    }

    func refresh(force: Bool = false) {
        // Show “fetching…” immediately — Task scheduling alone would leave a frame of stale UI.
        if force || networkInfo?.publicIP == nil {
            setLoadingState(true)
        }
        Task { @MainActor in
            await refreshAndWait(force: force)
        }
    }

    /// Fetches network info and waits for completion (or cache hit / timeout).
    @discardableResult
    func refreshAndWait(force: Bool = false, timeout: TimeInterval? = nil) async -> NetworkInfo? {
        if !force,
           let lastFetch = lastFetchDate,
           let info = networkInfo,
           info.publicIP != nil,
           Date().timeIntervalSince(lastFetch) < AppConstants.networkInfoCacheDuration {
            finishLoading(hasFinished: true)
            return info
        }

        // Join a truly in-flight fetch only (not a completed task after isLoading was re-armed).
        if let inFlightFetch {
            if let timeout, timeout > 0 {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await inFlightFetch.value }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    }
                    await group.next()
                    group.cancelAll()
                }
            } else {
                await inFlightFetch.value
            }
            if !force {
                return networkInfo
            }
            // force: previous finished; fall through to a new attempt.
        }

        setLoadingState(true)

        let task = Task { @MainActor in
            await self.fetchNetworkInfo()
        }
        inFlightFetch = task

        if let timeout, timeout > 0 {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                }
                await group.next()
                group.cancelAll()
            }
        } else {
            await task.value
        }

        if inFlightFetch == task {
            inFlightFetch = nil
        }

        // If the wait timed out but work is still running, keep isLoading true for live UI;
        // fetchNetworkInfo's defer will clear it and post networkInfoDidChange.
        return networkInfo
    }

    func cleanup() {
        inFlightFetch?.cancel()
        inFlightFetch = nil
        debounceTask?.cancel()
        debounceTask = nil
        finishLoading(hasFinished: false)
        if let token = statusObserverToken {
            NotificationCenter.default.removeObserver(token)
            statusObserverToken = nil
        }
        session.invalidateAndCancel()
    }

    private func setLoadingState(_ loading: Bool) {
        let changed = isLoading != loading || (loading && hasFinishedFetch)
        isLoading = loading
        if loading {
            hasFinishedFetch = false
        }
        if changed {
            postNetworkInfoDidChange()
        }
    }

    private func finishLoading(hasFinished: Bool) {
        let changed = isLoading || hasFinishedFetch != hasFinished
        isLoading = false
        hasFinishedFetch = hasFinished
        if changed {
            postNetworkInfoDidChange()
        }
    }

    private func postNetworkInfoDidChange() {
        NotificationCenter.default.post(name: .networkInfoDidChange, object: self)
    }

    private func observeVPNStatusChanges() {
        statusObserverToken = NotificationCenter.default.addObserver(
            forName: .vpnConnectionStatusDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let status = notification.userInfo?["status"] as? SCNetworkConnectionStatus else {
                    return
                }

                switch status {
                case .disconnected, .invalid:
                    self.networkInfo = nil
                    self.lastFetchDate = nil
                    self.inFlightFetch?.cancel()
                    self.inFlightFetch = nil
                    self.finishLoading(hasFinished: false)
                    self.postNetworkInfoDidChange()
                case .connected:
                    // Publish local interfaces immediately; then fetch public IP once (debounced).
                    self.hasFinishedFetch = false
                    let ifaces = self.detectVPNInterfaces()
                    if self.networkInfo == nil || self.networkInfo?.publicIP == nil {
                        self.networkInfo = NetworkInfo(
                            publicIP: nil,
                            country: nil,
                            countryCode: nil,
                            city: nil,
                            vpnInterfaces: ifaces,
                            lastUpdated: Date()
                        )
                    }
                    self.postNetworkInfoDidChange()
                    self.scheduleRefresh(force: true)
                default:
                    break
                }
            }
        }
    }

    private func scheduleRefresh(force: Bool) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppConstants.networkInfoRefreshDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshAndWait(force: force)
        }
    }

    private func fetchNetworkInfo() async {
        isLoading = true
        hasFinishedFetch = false
        postNetworkInfoDidChange()

        defer {
            isLoading = false
            hasFinishedFetch = true
            postNetworkInfoDidChange()
        }

        guard !Task.isCancelled else { return }

        let vpnInterfaces = detectVPNInterfaces()
        // Show interfaces right away so the menu is never empty while geo loads.
        if networkInfo == nil || networkInfo?.publicIP == nil {
            networkInfo = NetworkInfo(
                publicIP: networkInfo?.publicIP,
                country: networkInfo?.country,
                countryCode: networkInfo?.countryCode,
                city: networkInfo?.city,
                vpnInterfaces: vpnInterfaces,
                lastUpdated: Date()
            )
            postNetworkInfoDidChange()
        }

        let geoInfo = await fetchGeoIPWithFallbacks()
        guard !Task.isCancelled else { return }

        if let geo = geoInfo {
            networkInfo = NetworkInfo(
                publicIP: geo.ip,
                country: geo.country,
                countryCode: geo.countryCode,
                city: geo.city,
                vpnInterfaces: vpnInterfaces,
                lastUpdated: Date()
            )
            lastFetchDate = Date()
        } else if networkInfo?.publicIP == nil {
            // Keep interfaces; mark as "attempted" so we don't spin forever as "fetching".
            networkInfo = NetworkInfo(
                publicIP: nil,
                country: nil,
                countryCode: nil,
                city: nil,
                vpnInterfaces: vpnInterfaces,
                lastUpdated: Date()
            )
            // Short negative cache so rapid re-opens don't hammer endpoints.
            lastFetchDate = Date().addingTimeInterval(-(AppConstants.networkInfoCacheDuration - 5))
        }
        // networkInfo change is followed by defer's postNetworkInfoDidChange
    }

    // MARK: - GeoIP

    private struct GeoInfo {
        let ip: String?
        let country: String?
        let countryCode: String?
        let city: String?
    }

    private func fetchGeoIPWithFallbacks() async -> GeoInfo? {
        // Prefer browserleaks.com/ip: many split-tunnel VPN profiles send
        // ifconfig.co / Cloudflare (and similar "what is my IP" APIs) direct,
        // which shows the ISP address instead of the VPN exit.
        if let info = await fetchBrowserLeaksIP(), info.ip != nil || info.country != nil {
            return info
        }
        Logger.vpn.warning("GeoIP provider (browserleaks.com/ip) failed")
        return nil
    }

    private func data(for url: URL, accept: String) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConstants.NetworkInfo.requestTimeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // BrowserLeaks serves a normal HTML page; a browser-like UA avoids empty/blocked responses.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            Logger.vpn.debug("GeoIP request failed for \(url.host ?? "?"): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// https://browserleaks.com/ip — server-rendered IP + geo in HTML attributes/table.
    private func fetchBrowserLeaksIP() async -> GeoInfo? {
        guard let url = URL(string: "https://browserleaks.com/ip"),
              let data = await data(for: url, accept: "text/html,application/xhtml+xml,*/*"),
              let html = String(data: data, encoding: .utf8),
              let parsed = BrowserLeaksIPParser.parse(html) else { return nil }

        return GeoInfo(
            ip: parsed.ip,
            country: parsed.country,
            countryCode: parsed.countryCode,
            city: parsed.city
        )
    }

    // MARK: - VPN Interface Detection

    private static let vpnInterfacePrefixes = ["utun", "ppp", "ipsec", "tap", "tun", "gpd", "wg"]

    private func detectVPNInterfaces() -> [VPNInterface] {
        var interfaces: [VPNInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return interfaces
        }
        defer { freeifaddrs(ifaddr) }

        var currentAddr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = currentAddr {
            let flags = Int32(addr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0

            if isUp && isRunning,
               addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: addr.pointee.ifa_name)

                if Self.vpnInterfacePrefixes.contains(where: { name.hasPrefix($0) }) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr.pointee.ifa_addr,
                        socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil, 0,
                        NI_NUMERICHOST
                    ) == 0 {
                        interfaces.append(VPNInterface(name: name, address: String(cString: hostname)))
                    }
                }
            }
            currentAddr = addr.pointee.ifa_next
        }

        return interfaces
    }
}
