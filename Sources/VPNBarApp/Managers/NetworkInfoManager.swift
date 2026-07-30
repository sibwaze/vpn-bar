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

    private var lastFetchDate: Date?
    private var fetchTask: Task<Void, Never>?
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
           Date().timeIntervalSince(lastFetch) < AppConstants.networkInfoCacheDuration {
            return info
        }

        // Coalesce concurrent callers onto one in-flight fetch.
        if let fetchTask, isLoading {
            await fetchTask.value
            return networkInfo
        }

        let task = Task { @MainActor in
            await self.fetchNetworkInfo()
        }
        fetchTask = task

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

        return networkInfo
    }

    func cleanup() {
        fetchTask?.cancel()
        fetchTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        isLoading = false
        if let token = statusObserverToken {
            NotificationCenter.default.removeObserver(token)
            statusObserverToken = nil
        }
        session.invalidateAndCancel()
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
                    self.isLoading = false
                case .connected:
                    // Publish local interfaces immediately; then fetch public IP.
                    let ifaces = self.detectVPNInterfaces()
                    if self.networkInfo == nil {
                        self.networkInfo = NetworkInfo(
                            publicIP: nil,
                            country: nil,
                            countryCode: nil,
                            city: nil,
                            vpnInterfaces: ifaces,
                            lastUpdated: Date()
                        )
                    }
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
        defer { isLoading = false }

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
    }

    // MARK: - GeoIP (multi-provider)

    private struct GeoInfo {
        let ip: String?
        let country: String?
        let countryCode: String?
        let city: String?
    }

    private func fetchGeoIPWithFallbacks() async -> GeoInfo? {
        // Primary + one fallback (ipwho.is often blocked).
        if let info = await fetchIfconfigCo(), info.ip != nil || info.country != nil {
            return info
        }
        if Task.isCancelled { return nil }
        if let info = await fetchCloudflareTrace(), info.ip != nil || info.country != nil {
            return info
        }
        Logger.vpn.warning("GeoIP providers failed")
        return nil
    }

    private func data(for url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConstants.NetworkInfo.requestTimeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
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

    /// https://ifconfig.co/json — IP + country + city.
    private func fetchIfconfigCo() async -> GeoInfo? {
        guard let url = URL(string: "https://ifconfig.co/json"),
              let data = await data(for: url) else { return nil }

        struct Response: Decodable {
            let ip: String?
            let country: String?
            let country_iso: String?
            let city: String?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let info = GeoInfo(
            ip: decoded.ip,
            country: decoded.country,
            countryCode: decoded.country_iso,
            city: decoded.city
        )
        return (info.ip != nil || info.country != nil) ? info : nil
    }

    /// Cloudflare trace — IP + country code (no city).
    private func fetchCloudflareTrace() async -> GeoInfo? {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace"),
              let data = await data(for: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var ip: String?
        var loc: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("ip=") {
                ip = String(line.dropFirst(3))
            } else if line.hasPrefix("loc=") {
                loc = String(line.dropFirst(4))
            }
        }
        guard ip != nil || loc != nil else { return nil }
        return GeoInfo(ip: ip, country: loc, countryCode: loc, city: nil)
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
