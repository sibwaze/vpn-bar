import Foundation
import SystemConfiguration
import Darwin
import os.log

/// Loads VPN configurations from the system.
///
/// Prefers SystemConfiguration **current network set** (same scope as `scutil --nc list`).
/// Falls back to private `NEConfigurationManager` only when SC finds nothing, so macOS 26/27
/// `IPC failed` does not break the menu or leave orphaned services from the full prefs database.
@MainActor
final class VPNConfigurationLoader: VPNConfigurationLoaderProtocol {
    private let sessionQueue = DispatchQueue(label: "VPNBarApp.configurationLoader")
    private var networkExtensionFrameworkLoaded = false
    /// Once NE fails with IPC, skip it for the process lifetime (SC is authoritative).
    private var networkExtensionUnavailable = false

    /// Interface types that represent VPN (or VPN-like) network services.
    private static let vpnInterfaceTypes: Set<String> = [
        "VPN",
        "IPSec"
    ]

    func loadConfigurations(completion: @escaping (Result<[VPNConnection], VPNError>) -> Void) {
        // Prefer SC current set: correct membership, no private IPC, cheap.
        let scConnections = loadConfigurationsViaSystemConfiguration()
        if !scConnections.isEmpty {
            completion(.success(scConnections))
            return
        }

        if networkExtensionUnavailable {
            completion(.success([]))
            return
        }

        loadNetworkExtensionFrameworkIfNeeded()

        guard let managerType = NSClassFromString("NEConfigurationManager") as? NSObject.Type else {
            completion(.success([]))
            return
        }

        loadConfigurationsWithManagerType(managerType, completion: completion)
    }

    private func loadConfigurationsWithManagerType(
        _ managerType: NSObject.Type,
        completion: @escaping (Result<[VPNConnection], VPNError>) -> Void
    ) {
        let sharedManagerSelector = NSSelectorFromString("sharedManager")
        guard managerType.responds(to: sharedManagerSelector),
              let manager = managerType.perform(sharedManagerSelector)?.takeUnretainedValue() as? NSObject else {
            networkExtensionUnavailable = true
            completion(.success([]))
            return
        }

        let selector = NSSelectorFromString("loadConfigurationsWithCompletionQueue:handler:")
        guard manager.responds(to: selector), let imp = manager.method(for: selector) else {
            networkExtensionUnavailable = true
            completion(.success([]))
            return
        }

        let handler: @convention(block) (NSArray?, NSError?) -> Void = { [weak self] configurations, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    // NEConfigurationErrorDomain 11 "IPC failed" on macOS 26/27 beta.
                    self.networkExtensionUnavailable = true
                    Logger.vpn.warning(
                        "NEConfigurationManager unavailable (\(error.localizedDescription)); using SystemConfiguration only"
                    )
                    // SC already returned empty above; surface noConfigurations via empty success.
                    completion(.success(self.loadConfigurationsViaSystemConfiguration()))
                    return
                }

                guard let nsArray = configurations as NSArray? else {
                    completion(.success([]))
                    return
                }

                // Intersect NE configs with SC current-set IDs so deleted services cannot linger.
                let scIDs = Set(self.loadConfigurationsViaSystemConfiguration().map(\.id))
                var connections = self.processConfigurations(nsArray)
                if !scIDs.isEmpty {
                    connections = connections.filter { scIDs.contains($0.id) }
                }
                completion(.success(connections))
            }
        }

        let block = unsafeBitCast(handler, to: AnyObject.self)
        typealias MethodType = @convention(c) (AnyObject, Selector, DispatchQueue, AnyObject) -> Void
        let method = unsafeBitCast(imp, to: MethodType.self)
        method(manager, selector, sessionQueue, block)
    }

    private func processConfigurations(_ configurations: NSArray) -> [VPNConnection] {
        var processedConnections: [VPNConnection] = []

        for index in 0..<configurations.count {
            guard let config = configurations[index] as? NSObject else { continue }

            let name = config.value(forKey: "name") as? String
            let identifier = config.value(forKey: "identifier") as? NSUUID

            guard let name, let identifier,
                  !name.hasPrefix("com.apple.preferences.") else {
                continue
            }

            let identifierString = identifier.uuidString
            processedConnections.append(VPNConnection(
                id: identifierString,
                name: name,
                serviceID: identifierString,
                status: .disconnected
            ))
        }

        return processedConnections.sorted { $0.name < $1.name }
    }

    /// Enumerates VPN services in the **current** network set (matches `scutil --nc list`).
    private func loadConfigurationsViaSystemConfiguration() -> [VPNConnection] {
        guard let prefs = SCPreferencesCreate(nil, "VPNBar" as CFString, nil) else {
            Logger.vpn.error("SCPreferencesCreate failed")
            return []
        }

        // Current set only — SCNetworkServiceCopyAll also returns orphaned prefs services.
        let services: [SCNetworkService]
        if let currentSet = SCNetworkSetCopyCurrent(prefs),
           let setServices = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] {
            services = setServices
        } else if let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            Logger.vpn.warning("SCNetworkSetCopyCurrent unavailable; falling back to CopyAll")
            services = all
        } else {
            Logger.vpn.error("No network services available from SystemConfiguration")
            return []
        }

        var processedConnections: [VPNConnection] = []

        for service in services {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  Self.vpnInterfaceTypes.contains(interfaceType) else {
                continue
            }

            guard let name = SCNetworkServiceGetName(service) as String?,
                  let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  !name.hasPrefix("com.apple.preferences.") else {
                continue
            }

            if !SCNetworkServiceGetEnabled(service) {
                continue
            }

            processedConnections.append(VPNConnection(
                id: serviceID,
                name: name,
                serviceID: serviceID,
                status: .disconnected
            ))
        }

        return processedConnections.sorted { $0.name < $1.name }
    }

    private func loadNetworkExtensionFrameworkIfNeeded() {
        if networkExtensionFrameworkLoaded { return }

        let possiblePaths = [
            "/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension",
            "/System/Library/Frameworks/NetworkExtension.framework/Versions/A/NetworkExtension",
            "/System/Library/Frameworks/NetworkExtension.framework"
        ]

        for frameworkPath in possiblePaths {
            if dlopen(frameworkPath, RTLD_LAZY | RTLD_GLOBAL) != nil {
                networkExtensionFrameworkLoaded = true
                return
            }
        }

        if Bundle(identifier: "com.apple.NetworkExtension") != nil {
            networkExtensionFrameworkLoaded = true
        }
    }
}
