import Foundation
import SystemConfiguration
import Darwin
import os.log

/// Manages VPN connections, responsible for loading configurations and managing sessions.
@MainActor
class VPNManager: VPNManagerProtocol {
    static let shared: VPNManager = {
        let statusHandler: @Sendable (String, SCNetworkConnectionStatus) -> Void = { connectionID, status in
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .vpnConnectionStatusDidUpdate,
                    object: nil,
                    userInfo: [
                        "connectionID": connectionID,
                        "status": status
                    ]
                )
            }
        }

        return VPNManager(
            configurationLoader: VPNConfigurationLoader(),
            sessionManager: VPNSessionManager(statusUpdateHandler: statusHandler)
        )
    }()

    @Published var connections: [VPNConnection] = []
    @Published var hasActiveConnection: Bool = false
    @Published var loadingError: VPNError?

    private let configurationLoader: VPNConfigurationLoaderProtocol
    private var sessionManager: any VPNSessionManagerProtocol
    private var updateTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var loadRequestID: UInt64 = 0
    private var disconnectTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// In-flight connect/retry work, cancelled on disconnect or cleanup.
    private var connectTasks: [String: Task<Void, Never>] = [:]
    private var pendingConnectionID: String?
    private var statusObserverToken: NSObjectProtocol?

    var updateInterval: TimeInterval {
        get { SettingsManager.shared.updateInterval }
        set {
            SettingsManager.shared.updateInterval = newValue
            restartMonitoring()
        }
    }

    private var lastFullReload: Date = .distantPast
    private let connectionsListReloadInterval: TimeInterval = AppConstants.connectionsListReloadInterval

    init(
        configurationLoader: VPNConfigurationLoaderProtocol? = nil,
        sessionManager: (any VPNSessionManagerProtocol)? = nil
    ) {
        self.configurationLoader = configurationLoader ?? VPNConfigurationLoader()

        if let manager = sessionManager {
            self.sessionManager = manager
        } else {
            let statusHandler: @Sendable (String, SCNetworkConnectionStatus) -> Void = { connectionID, status in
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .vpnConnectionStatusDidUpdate,
                        object: nil,
                        userInfo: [
                            "connectionID": connectionID,
                            "status": status
                        ]
                    )
                }
            }
            self.sessionManager = VPNSessionManager(statusUpdateHandler: statusHandler)
        }

        statusObserverToken = NotificationCenter.default.addObserver(
            forName: .vpnConnectionStatusDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let connectionID = notification.userInfo?["connectionID"] as? String,
                  let status = notification.userInfo?["status"] as? SCNetworkConnectionStatus else {
                return
            }
            Task { @MainActor in
                self.handleStatusUpdate(connectionID: connectionID, scStatus: status)
            }
        }

        loadConnections(forceReload: true)
        startMonitoring()
    }

    deinit {
        updateTimer?.invalidate()
        updateTimer = nil
        if let token = statusObserverToken {
            NotificationCenter.default.removeObserver(token)
            statusObserverToken = nil
        }
    }

    /// Loads available VPN configurations.
    /// - Parameter forceReload: When false, only refreshes session status for known connections.
    func loadConnections(forceReload: Bool = false) {
        if !forceReload, !connections.isEmpty {
            refreshAllStatuses()
            return
        }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.reloadConnectionsAsync()
        }
    }

    /// Full configuration reload; awaits processing so callers (e.g. menu) see an up-to-date list.
    func reloadConnectionsAsync() async {
        lastFullReload = Date()
        loadRequestID &+= 1
        let currentRequestID = loadRequestID
        loadingError = nil

        let result: Result<[VPNConnection], VPNError> = await withCheckedContinuation { continuation in
            configurationLoader.loadConfigurations { result in
                continuation.resume(returning: result)
            }
        }

        guard !Task.isCancelled, currentRequestID == loadRequestID else { return }

        switch result {
        case .success(let loadedConnections):
            await processLoadedConnections(loadedConnections, requestID: currentRequestID)
        case .failure(let error):
            handleLoadError(error)
        }
    }

    func connect(to connectionID: String, retryCount: Int = AppConstants.defaultRetryCount) {
        guard connections.contains(where: { $0.id == connectionID }) else {
            loadingError = .connectionNotFound(id: connectionID)
            return
        }

        connectTasks[connectionID]?.cancel()
        connectTasks[connectionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectTasks[connectionID] = nil }
            await self.connectWithRetry(to: connectionID, retryCount: retryCount, attempt: 1)
        }
    }

    private func connectWithRetry(to connectionID: String, retryCount: Int, attempt: Int) async {
        guard !Task.isCancelled else { return }
        guard connections.contains(where: { $0.id == connectionID }) else {
            loadingError = .connectionNotFound(id: connectionID)
            return
        }

        let hasSession = await sessionManager.hasSession(for: connectionID)
        if !hasSession {
            guard let uuid = UUID(uuidString: connectionID) else {
                loadingError = .sessionNotFound(id: connectionID)
                resetConnectionToDisconnected(connectionID: connectionID)
                return
            }
            await sessionManager.getOrCreateSession(for: uuid as NSUUID)
            guard !Task.isCancelled else { return }

            let created = await sessionManager.hasSession(for: connectionID)
            guard created else {
                await handleConnectionFailure(connectionID: connectionID, retryCount: retryCount, attempt: attempt)
                return
            }
        }

        do {
            guard !Task.isCancelled else { return }
            try await sessionManager.startConnection(connectionID: connectionID)
            guard !Task.isCancelled else { return }
            updateConnectionToConnecting(connectionID: connectionID)
        } catch {
            Logger.vpn.error("Failed to start connection: \(error.localizedDescription)")
            if attempt < retryCount {
                let delay = AppConstants.retryBaseDelay * pow(2.0, Double(attempt - 1))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await connectWithRetry(to: connectionID, retryCount: retryCount, attempt: attempt + 1)
            } else {
                loadingError = error as? VPNError ?? .connectionFailed(underlying: error.localizedDescription)
                resetConnectionToDisconnected(connectionID: connectionID)
            }
        }
    }

    private func handleConnectionFailure(connectionID: String, retryCount: Int, attempt: Int) async {
        if attempt < retryCount {
            let delay = AppConstants.retryBaseDelay * pow(2.0, Double(attempt - 1))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await connectWithRetry(to: connectionID, retryCount: retryCount, attempt: attempt + 1)
        } else {
            Logger.vpn.error("Session creation failed after \(retryCount) attempts")
            loadingError = .sessionCreationFailed(id: connectionID)
            resetConnectionToDisconnected(connectionID: connectionID)
        }
    }

    private func setConnectionStatus(id: String, status: VPNConnection.VPNStatus) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        guard connections[index].status != status else { return }

        var updated = connections
        updated[index].status = status
        connections = updated
        updateActiveStatus()
    }

    private func updateConnectionToConnecting(connectionID: String) {
        setConnectionStatus(id: connectionID, status: .connecting)
    }

    private func resetConnectionToDisconnected(connectionID: String) {
        setConnectionStatus(id: connectionID, status: .disconnected)
    }

    func disconnect(from connectionID: String) {
        Logger.vpn.info("Disconnecting from VPN: \(connectionID, privacy: .private)")
        guard connections.contains(where: { $0.id == connectionID }) else {
            loadingError = .connectionNotFound(id: connectionID)
            return
        }

        // Cancel any pending connect/retry so it cannot reconnect after user disconnect.
        connectTasks[connectionID]?.cancel()
        connectTasks.removeValue(forKey: connectionID)
        if pendingConnectionID == connectionID {
            pendingConnectionID = nil
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasSession = await sessionManager.hasSession(for: connectionID)
            guard hasSession else {
                loadingError = .sessionNotFound(id: connectionID)
                return
            }

            setConnectionStatus(id: connectionID, status: .disconnecting)
            disconnectTimeoutTasks[connectionID]?.cancel()

            disconnectTimeoutTasks[connectionID] = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(AppConstants.connectionTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }

                // Re-query real status instead of blindly marking disconnected.
                await sessionManager.getSessionStatus(connectionID: connectionID) { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        self.disconnectTimeoutTasks.removeValue(forKey: connectionID)
                        if status != .disconnected && status != .invalid {
                            self.loadingError = .connectionFailed(
                                underlying: "Disconnection timeout after \(AppConstants.connectionTimeout) seconds"
                            )
                        }
                        self.handleStatusUpdate(connectionID: connectionID, scStatus: status)
                        self.checkAndConnectPending()
                    }
                }
            }

            do {
                try await sessionManager.stopConnection(connectionID: connectionID)
                await sessionManager.getSessionStatus(connectionID: connectionID) { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        self.disconnectTimeoutTasks[connectionID]?.cancel()
                        self.disconnectTimeoutTasks.removeValue(forKey: connectionID)

                        if status == .disconnected {
                            SoundFeedbackManager.shared.play(.disconnection)
                        }
                        self.handleStatusUpdate(connectionID: connectionID, scStatus: status)
                    }
                }
            } catch {
                disconnectTimeoutTasks[connectionID]?.cancel()
                disconnectTimeoutTasks.removeValue(forKey: connectionID)
                Logger.vpn.error("Disconnection failed: \(connectionID, privacy: .private)")
                loadingError = .connectionFailed(underlying: error.localizedDescription)
                handleStatusUpdate(connectionID: connectionID, scStatus: .disconnected)
            }
        }
    }

    func toggleConnection(_ connectionID: String) {
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
            return
        }

        SettingsManager.shared.lastUsedConnectionID = connectionID

        if connection.status.isActive {
            pendingConnectionID = nil
            disconnect(from: connectionID)
        } else {
            let activeOthers = connections.filter { $0.id != connectionID && $0.status.isActive }
            if activeOthers.isEmpty {
                connect(to: connectionID, retryCount: AppConstants.defaultRetryCount)
            } else {
                pendingConnectionID = connectionID
                for active in activeOthers {
                    disconnect(from: active.id)
                }
            }
        }
    }

    private func checkAndConnectPending() {
        guard let pending = pendingConnectionID else { return }
        guard connections.contains(where: { $0.id == pending }) else {
            pendingConnectionID = nil
            return
        }
        let allOthersDisconnected = connections.allSatisfy {
            $0.id == pending || $0.status == .disconnected
        }
        guard allOthersDisconnected else { return }
        pendingConnectionID = nil
        connect(to: pending, retryCount: AppConstants.defaultRetryCount)
    }

    private func handleStatusUpdate(connectionID: String, scStatus: SCNetworkConnectionStatus) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else {
            return
        }

        let vpnStatus = convertToVPNStatus(from: scStatus)
        let oldStatus = connections[index].status

        if oldStatus != vpnStatus {
            var updated = connections
            updated[index].status = vpnStatus
            connections = updated
            updateActiveStatus()

            if oldStatus != .connected && vpnStatus == .connected {
                SoundFeedbackManager.shared.play(.connectionSuccess)
            }
        }

        checkAndConnectPending()
    }

    private func getCachedConnectionStatus(for identifier: String) async -> VPNConnection.VPNStatus {
        let scStatus = await sessionManager.getCachedStatus(for: identifier)
        return convertToVPNStatus(from: scStatus)
    }

    private func convertToVPNStatus(from scStatus: SCNetworkConnectionStatus) -> VPNConnection.VPNStatus {
        switch scStatus {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .disconnected, .invalid: return .disconnected
        @unknown default: return .disconnected
        }
    }

    private func processLoadedConnections(_ loadedConnections: [VPNConnection], requestID: UInt64) async {
        guard requestID == loadRequestID else { return }

        // Create sessions only for listed connections (needed for status + control).
        await withTaskGroup(of: Void.self) { group in
            for connection in loadedConnections {
                group.addTask { [sessionManager] in
                    let hasSession = await sessionManager.hasSession(for: connection.id)
                    if !hasSession, let uuid = UUID(uuidString: connection.id) {
                        await sessionManager.getOrCreateSession(for: uuid as NSUUID)
                    }
                }
            }
            await group.waitForAll()
        }

        guard requestID == loadRequestID else { return }

        let keptIDs = Set(loadedConnections.map(\.id))
        await sessionManager.pruneSessions(keeping: keptIDs)

        var processed: [VPNConnection] = []
        for connection in loadedConnections {
            let status = await getCachedConnectionStatus(for: connection.id)
            processed.append(VPNConnection(
                id: connection.id,
                name: connection.name,
                serviceID: connection.id,
                status: status
            ))
        }

        guard requestID == loadRequestID else { return }

        let sorted = processed.sorted { $0.name < $1.name }
        // Avoid @Published fan-out when nothing changed.
        if sorted != connections {
            connections = sorted
        }

        loadingError = connections.isEmpty ? .noConfigurations : nil
        updateActiveStatus()
        pruneStaleSettings(validIDs: keptIDs)
    }

    /// Clears last-used ID and hotkeys for VPNs that no longer exist.
    private func pruneStaleSettings(validIDs: Set<String>) {
        let settings = SettingsManager.shared
        if let last = settings.lastUsedConnectionID, !validIDs.contains(last) {
            settings.lastUsedConnectionID = nil
        }

        let staleHotkeys = settings.connectionHotkeys.filter { !validIDs.contains($0.connectionID) }
        if !staleHotkeys.isEmpty {
            settings.connectionHotkeys = settings.connectionHotkeys.filter { validIDs.contains($0.connectionID) }
        }

        if let pending = pendingConnectionID, !validIDs.contains(pending) {
            pendingConnectionID = nil
        }
    }

    private func handleLoadError(_ error: VPNError) {
        loadingError = error
        if !connections.isEmpty {
            connections = []
        }
        updateActiveStatus()
    }

    private func refreshAllStatuses() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for connection in connections {
                // Ensure session exists so status can be read after lazy paths.
                if !(await sessionManager.hasSession(for: connection.id)),
                   let uuid = UUID(uuidString: connection.id) {
                    await sessionManager.getOrCreateSession(for: uuid as NSUUID)
                }
                await sessionManager.getSessionStatus(connectionID: connection.id) { [weak self] status in
                    Task { @MainActor in
                        self?.handleStatusUpdate(connectionID: connection.id, scStatus: status)
                    }
                }
            }
        }
    }

    private func startMonitoring() {
        stopMonitoring()

        let effectiveInterval = max(AppConstants.minUpdateInterval, updateInterval)
        let timer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let needsFullReload = Date().timeIntervalSince(self.lastFullReload) >= self.connectionsListReloadInterval
                self.loadConnections(forceReload: needsFullReload)
            }
        }
        updateTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    private func restartMonitoring() {
        startMonitoring()
    }

    private func stopMonitoring() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateActiveStatus() {
        hasActiveConnection = connections.contains { $0.status.isActive }
    }

    func cleanup() {
        stopMonitoring()
        loadTask?.cancel()
        loadTask = nil
        for task in connectTasks.values { task.cancel() }
        connectTasks.removeAll()
        for task in disconnectTimeoutTasks.values { task.cancel() }
        disconnectTimeoutTasks.removeAll()
        pendingConnectionID = nil
        if let token = statusObserverToken {
            NotificationCenter.default.removeObserver(token)
            statusObserverToken = nil
        }
        Task {
            await sessionManager.cleanup()
        }
    }
}
