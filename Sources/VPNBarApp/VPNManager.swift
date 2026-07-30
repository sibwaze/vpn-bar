import Foundation
import SystemConfiguration
import os.log

/// Manages VPN connections: list, connect/disconnect, event-driven status.
@MainActor
class VPNManager: VPNManagerProtocol {
    static let shared: VPNManager = {
        let statusHandler: @Sendable (String, SCNetworkConnectionStatus) -> Void = { connectionID, status in
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .vpnConnectionStatusDidUpdate,
                    object: nil,
                    userInfo: ["connectionID": connectionID, "status": status]
                )
            }
        }
        return VPNManager(
            configurationLoader: VPNConfigurationLoader(),
            sessionManager: VPNSessionManager(statusUpdateHandler: statusHandler)
        )
    }()

    @Published var connections: [VPNConnection] = []
    @Published var hasActiveConnection = false
    @Published var loadingError: VPNError?

    private let configurationLoader: VPNConfigurationLoaderProtocol
    private var sessionManager: any VPNSessionManagerProtocol
    private var loadTask: Task<Void, Never>?
    private var loadRequestID: UInt64 = 0
    private var disconnectTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var connectTasks: [String: Task<Void, Never>] = [:]
    private var pendingConnectionID: String?
    private var statusObserverToken: NSObjectProtocol?
    private var lastFullReload: Date = .distantPast

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
                        userInfo: ["connectionID": connectionID, "status": status]
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
                  let status = notification.userInfo?["status"] as? SCNetworkConnectionStatus else { return }
            Task { @MainActor in
                self.handleStatusUpdate(connectionID: connectionID, scStatus: status)
            }
        }

        loadConnections(forceReload: true)
    }

    deinit {
        if let token = statusObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func loadConnections(forceReload: Bool = false) {
        // No idle polling: non-force only refreshes statuses of existing sessions.
        if !forceReload {
            refreshExistingSessionStatuses()
            return
        }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.reloadConnectionsAsync()
        }
    }

    func reloadConnectionsAsync() async {
        // Throttle full reloads (menu open can call often).
        if Date().timeIntervalSince(lastFullReload) < 2, !connections.isEmpty {
            return
        }
        lastFullReload = Date()
        loadRequestID &+= 1
        let currentRequestID = loadRequestID
        loadingError = nil

        let result: Result<[VPNConnection], VPNError> = await withCheckedContinuation { continuation in
            configurationLoader.loadConfigurations { continuation.resume(returning: $0) }
        }

        guard !Task.isCancelled, currentRequestID == loadRequestID else { return }

        switch result {
        case .success(let loaded):
            await processLoadedConnections(loaded, requestID: currentRequestID)
        case .failure(let error):
            loadingError = error
            connections = []
            hasActiveConnection = false
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
            await self.performConnect(connectionID: connectionID, retriesLeft: max(1, retryCount))
        }
    }

    private func performConnect(connectionID: String, retriesLeft: Int) async {
        guard !Task.isCancelled else { return }

        if !(await sessionManager.hasSession(for: connectionID)) {
            guard let uuid = UUID(uuidString: connectionID) else {
                loadingError = .sessionNotFound(id: connectionID)
                setStatus(connectionID, .disconnected)
                return
            }
            await sessionManager.getOrCreateSession(for: uuid as NSUUID)
            guard await sessionManager.hasSession(for: connectionID) else {
                if retriesLeft > 1 {
                    try? await Task.sleep(nanoseconds: UInt64(AppConstants.retryBaseDelay * 1_000_000_000))
                    await performConnect(connectionID: connectionID, retriesLeft: retriesLeft - 1)
                } else {
                    loadingError = .sessionCreationFailed(id: connectionID)
                    setStatus(connectionID, .disconnected)
                }
                return
            }
        }

        do {
            try await sessionManager.startConnection(connectionID: connectionID)
            setStatus(connectionID, .connecting)
        } catch {
            if retriesLeft > 1 {
                try? await Task.sleep(nanoseconds: UInt64(AppConstants.retryBaseDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await performConnect(connectionID: connectionID, retriesLeft: retriesLeft - 1)
            } else {
                loadingError = .connectionFailed(underlying: error.localizedDescription)
                setStatus(connectionID, .disconnected)
            }
        }
    }

    func disconnect(from connectionID: String) {
        guard connections.contains(where: { $0.id == connectionID }) else {
            loadingError = .connectionNotFound(id: connectionID)
            return
        }
        connectTasks[connectionID]?.cancel()
        connectTasks.removeValue(forKey: connectionID)
        if pendingConnectionID == connectionID { pendingConnectionID = nil }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await sessionManager.hasSession(for: connectionID) else {
                loadingError = .sessionNotFound(id: connectionID)
                return
            }
            setStatus(connectionID, .disconnecting)

            disconnectTimeoutTasks[connectionID]?.cancel()
            disconnectTimeoutTasks[connectionID] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(AppConstants.connectionTimeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.sessionManager.getSessionStatus(connectionID: connectionID) { [weak self] status in
                    Task { @MainActor in
                        self?.disconnectTimeoutTasks.removeValue(forKey: connectionID)
                        self?.handleStatusUpdate(connectionID: connectionID, scStatus: status)
                        self?.checkAndConnectPending()
                    }
                }
            }

            do {
                try await sessionManager.stopConnection(connectionID: connectionID)
                await sessionManager.getSessionStatus(connectionID: connectionID) { [weak self] status in
                    Task { @MainActor in
                        self?.disconnectTimeoutTasks[connectionID]?.cancel()
                        self?.disconnectTimeoutTasks.removeValue(forKey: connectionID)
                        self?.handleStatusUpdate(connectionID: connectionID, scStatus: status)
                    }
                }
            } catch {
                disconnectTimeoutTasks[connectionID]?.cancel()
                disconnectTimeoutTasks.removeValue(forKey: connectionID)
                loadingError = .connectionFailed(underlying: error.localizedDescription)
                handleStatusUpdate(connectionID: connectionID, scStatus: .disconnected)
            }
        }
    }

    func toggleConnection(_ connectionID: String) {
        guard let connection = connections.first(where: { $0.id == connectionID }) else { return }
        SettingsManager.shared.lastUsedConnectionID = connectionID

        if connection.status.isActive {
            pendingConnectionID = nil
            disconnect(from: connectionID)
        } else {
            let activeOthers = connections.filter { $0.id != connectionID && $0.status.isActive }
            if activeOthers.isEmpty {
                connect(to: connectionID)
            } else {
                pendingConnectionID = connectionID
                for active in activeOthers { disconnect(from: active.id) }
            }
        }
    }

    private func checkAndConnectPending() {
        guard let pending = pendingConnectionID else { return }
        guard connections.contains(where: { $0.id == pending }) else {
            pendingConnectionID = nil
            return
        }
        guard connections.allSatisfy({ $0.id == pending || $0.status == .disconnected }) else { return }
        pendingConnectionID = nil
        connect(to: pending)
    }

    private func handleStatusUpdate(connectionID: String, scStatus: SCNetworkConnectionStatus) {
        setStatus(connectionID, convertToVPNStatus(from: scStatus))
        checkAndConnectPending()
    }

    private func setStatus(_ id: String, _ status: VPNConnection.VPNStatus) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        guard connections[index].status != status else { return }
        var updated = connections
        updated[index].status = status
        connections = updated
        hasActiveConnection = connections.contains { $0.status.isActive }
    }

    private func convertToVPNStatus(from scStatus: SCNetworkConnectionStatus) -> VPNConnection.VPNStatus {
        switch scStatus {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        default: return .disconnected
        }
    }

    private func processLoadedConnections(_ loaded: [VPNConnection], requestID: UInt64) async {
        guard requestID == loadRequestID else { return }

        let keptIDs = Set(loaded.map(\.id))
        await sessionManager.pruneSessions(keeping: keptIDs)

        // Lazy sessions: only attach to previously known-active or last-used; rest stay disconnected
        // until connect. At load, create session only to read status (needed for icon accuracy).
        var processed: [VPNConnection] = []
        for connection in loaded {
            if let uuid = UUID(uuidString: connection.id),
               !(await sessionManager.hasSession(for: connection.id)) {
                await sessionManager.getOrCreateSession(for: uuid as NSUUID)
            }
            let sc = await sessionManager.getCachedStatus(for: connection.id)
            processed.append(VPNConnection(
                id: connection.id,
                name: connection.name,
                status: convertToVPNStatus(from: sc)
            ))
        }

        guard requestID == loadRequestID else { return }

        let sorted = processed.sorted { $0.name < $1.name }
        if sorted != connections {
            connections = sorted
        }
        loadingError = connections.isEmpty ? .noConfigurations : nil
        hasActiveConnection = connections.contains { $0.status.isActive }

        if let last = SettingsManager.shared.lastUsedConnectionID, !keptIDs.contains(last) {
            SettingsManager.shared.lastUsedConnectionID = nil
        }
        if let pending = pendingConnectionID, !keptIDs.contains(pending) {
            pendingConnectionID = nil
        }
    }

    private func refreshExistingSessionStatuses() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for connection in connections where await sessionManager.hasSession(for: connection.id) {
                await sessionManager.getSessionStatus(connectionID: connection.id) { [weak self] status in
                    Task { @MainActor in
                        self?.handleStatusUpdate(connectionID: connection.id, scStatus: status)
                    }
                }
            }
        }
    }

    func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        connectTasks.values.forEach { $0.cancel() }
        connectTasks.removeAll()
        disconnectTimeoutTasks.values.forEach { $0.cancel() }
        disconnectTimeoutTasks.removeAll()
        pendingConnectionID = nil
        if let token = statusObserverToken {
            NotificationCenter.default.removeObserver(token)
            statusObserverToken = nil
        }
        Task { await sessionManager.cleanup() }
    }
}
