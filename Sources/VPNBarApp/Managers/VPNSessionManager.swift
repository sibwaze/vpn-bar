import Foundation
import SystemConfiguration
import os.log

/// Manages VPN sessions with thread-safe access using actor isolation.
actor VPNSessionManager: VPNSessionManagerProtocol {
    private var sessions: [String: ne_session_t] = [:]
    private var sessionStatuses: [String: SCNetworkConnectionStatus] = [:]
    /// Tracks in-flight creates to prevent reentrancy double-create / leak.
    private var creating: Set<String> = []
    private let sessionQueue = DispatchQueue(label: "VPNBarApp.sessionQueue")
    private var statusUpdateHandler: (@Sendable (String, SCNetworkConnectionStatus) -> Void)?

    init(statusUpdateHandler: (@Sendable (String, SCNetworkConnectionStatus) -> Void)? = nil) {
        self.statusUpdateHandler = statusUpdateHandler
    }

    func getOrCreateSession(for uuid: NSUUID) async {
        let identifier = uuid.uuidString

        if sessions[identifier] != nil { return }

        // Wait if another task is already creating this session.
        while creating.contains(identifier) {
            await Task.yield()
            if sessions[identifier] != nil { return }
        }
        if sessions[identifier] != nil { return }

        creating.insert(identifier)
        defer { creating.remove(identifier) }

        // Re-check after claiming create slot (reentrancy).
        if sessions[identifier] != nil { return }

        let session = await withCheckedContinuation { continuation in
            sessionQueue.async {
                var uuidBytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                uuid.getBytes(&uuidBytes)

                let session = withUnsafePointer(to: &uuidBytes) { uuidPtr in
                    ne_session_create(uuidPtr, NESessionTypeVPN) as ne_session_t?
                }

                continuation.resume(returning: session)
            }
        }

        guard let session else {
            Logger.vpn.error("Session creation failed for identifier: \(identifier, privacy: .private)")
            return
        }

        // Another waiter may have stored a session; release the duplicate.
        if sessions[identifier] != nil {
            ne_session_cancel(session)
            ne_session_release(session)
            return
        }

        sessions[identifier] = session

        ne_session_set_event_handler(session, sessionQueue) { [weak self] event, _ in
            Task {
                guard let self else { return }

                switch event {
                case 1:
                    Logger.vpn.info("Connection established: \(identifier, privacy: .private)")
                case 2:
                    Logger.vpn.error("Connection failed: \(identifier, privacy: .private)")
                default:
                    break
                }

                await self.refreshSessionStatus(for: identifier, session: session)
            }
        }

        await refreshSessionStatus(for: identifier, session: session)
    }

    func startConnection(connectionID: String) throws {
        guard let session = sessions[connectionID] else {
            throw VPNError.sessionNotFound(id: connectionID)
        }
        ne_session_start(session)
    }

    func stopConnection(connectionID: String) throws {
        guard let session = sessions[connectionID] else {
            throw VPNError.sessionNotFound(id: connectionID)
        }
        ne_session_stop(session)
    }

    func getSessionStatus(
        connectionID: String,
        completion: @escaping @Sendable (SCNetworkConnectionStatus) -> Void
    ) async {
        guard let session = sessions[connectionID] else {
            completion(.invalid)
            return
        }
        await refreshSessionStatus(for: connectionID, session: session, completion: completion)
    }

    func getCachedStatus(for connectionID: String) -> SCNetworkConnectionStatus {
        sessionStatuses[connectionID] ?? .invalid
    }

    func hasSession(for connectionID: String) -> Bool {
        sessions[connectionID] != nil
    }

    /// Releases sessions that are no longer present in the system VPN list.
    func pruneSessions(keeping ids: Set<String>) {
        let obsolete = sessions.keys.filter { !ids.contains($0) }
        for id in obsolete {
            if let session = sessions.removeValue(forKey: id) {
                ne_session_cancel(session)
                ne_session_release(session)
            }
            sessionStatuses.removeValue(forKey: id)
        }
        if !obsolete.isEmpty {
            Logger.vpn.info("Pruned \(obsolete.count) obsolete VPN session(s)")
        }
    }

    func cleanup() {
        for (_, session) in sessions {
            ne_session_cancel(session)
            ne_session_release(session)
        }
        sessions.removeAll()
        sessionStatuses.removeAll()
        creating.removeAll()
    }

    private func refreshSessionStatus(
        for identifier: String,
        session: ne_session_t,
        completion: (@Sendable (SCNetworkConnectionStatus) -> Void)? = nil
    ) async {
        await withCheckedContinuation { continuation in
            ne_session_get_status(session, sessionQueue) { [weak self] status in
                Task {
                    guard let self else {
                        continuation.resume()
                        return
                    }

                    let scStatus = SCNetworkConnectionGetStatusFromNEStatus(status)
                    let oldStatus = await self.sessionStatuses[identifier]
                    await self.updateStatus(identifier: identifier, status: scStatus)

                    if oldStatus != scStatus {
                        await self.notifyStatusChange(identifier: identifier, status: scStatus)
                    }

                    completion?(scStatus)
                    continuation.resume()
                }
            }
        }
    }

    private func updateStatus(identifier: String, status: SCNetworkConnectionStatus) {
        sessionStatuses[identifier] = status
    }

    private func notifyStatusChange(identifier: String, status: SCNetworkConnectionStatus) {
        statusUpdateHandler?(identifier, status)
    }
}
