import Foundation
import SystemConfiguration
import Darwin
import os.log

/// Loads VPN configurations from the system.
@MainActor
final class VPNConfigurationLoader: VPNConfigurationLoaderProtocol {
    private let sessionQueue = DispatchQueue(label: "VPNBarApp.configurationLoader")
    private var networkExtensionFrameworkLoaded = false
    /// Flag to prevent recursive calls to loadConfigurationsAlternative.
    /// Set to true when entering the alternative loading path and reset via defer.
    /// Prevents infinite recursion if the alternative path attempts to call loadConfigurations again.
    private var isLoadingAlternative = false

    /// Interface types that represent VPN (or VPN-like) network services.
    /// Values match `SCNetworkInterfaceGetInterfaceType` (C constants like
    /// `kSCNetworkInterfaceTypeVPN` are not always imported into Swift).
    /// Keep PPP out of the default set to avoid PPPoE broadband services.
    private static let vpnInterfaceTypes: Set<String> = [
        "VPN",
        "IPSec"
    ]

    func loadConfigurations(completion: @escaping (Result<[VPNConnection], VPNError>) -> Void) {
        loadNetworkExtensionFrameworkIfNeeded()

        let managerClass: AnyClass? = NSClassFromString("NEConfigurationManager")

        guard let managerType = managerClass as? NSObject.Type else {
            loadConfigurationsAlternative(completion: completion)
            return
        }

        loadConfigurationsWithManagerType(managerType, completion: completion)
    }

    private func loadConfigurationsAlternative(completion: @escaping (Result<[VPNConnection], VPNError>) -> Void) {
        // Prevent infinite recursion
        guard !isLoadingAlternative else {
            Logger.vpn.warning("Preventing recursive call to loadConfigurationsAlternative")
            // Last resort: SystemConfiguration may still work when NE is unavailable.
            completeWithSystemConfigurationFallback(preferredError: .frameworkLoadFailed(reason: "Recursive configuration loading detected"), completion: completion)
            return
        }

        isLoadingAlternative = true
        defer { isLoadingAlternative = false }

        let frameworkPath = "/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension"
        guard let framework = dlopen(frameworkPath, RTLD_LAZY) else {
            let error = String(cString: dlerror())
            Logger.vpn.warning("dlopen NetworkExtension failed: \(error); using SystemConfiguration fallback")
            completeWithSystemConfigurationFallback(
                preferredError: .frameworkLoadFailed(reason: error),
                completion: completion
            )
            return
        }

        defer { dlclose(framework) }

        guard let managerClass = NSClassFromString("NEConfigurationManager") as? NSObject.Type else {
            // Class not available even after loading framework — fall back to SC.
            Logger.vpn.warning("NEConfigurationManager class not available after loading framework; using SystemConfiguration fallback")
            completeWithSystemConfigurationFallback(preferredError: nil, completion: completion)
            return
        }

        loadConfigurationsWithManagerType(managerClass, completion: completion)
    }
    
    private func loadConfigurationsWithManagerType(_ managerType: NSObject.Type, completion: @escaping (Result<[VPNConnection], VPNError>) -> Void) {
        let sharedManagerSelector = NSSelectorFromString("sharedManager")
        guard managerType.responds(to: sharedManagerSelector) else {
            completeWithSystemConfigurationFallback(
                preferredError: .sharedManagerUnavailable,
                completion: completion
            )
            return
        }
        
        let sharedManagerResult = managerType.perform(sharedManagerSelector)
        guard let manager = sharedManagerResult?.takeUnretainedValue() as? NSObject else {
            completeWithSystemConfigurationFallback(
                preferredError: .sharedManagerUnavailable,
                completion: completion
            )
            return
        }
        
        let selector = NSSelectorFromString("loadConfigurationsWithCompletionQueue:handler:")
        guard manager.responds(to: selector) else {
            completeWithSystemConfigurationFallback(
                preferredError: .sharedManagerUnavailable,
                completion: completion
            )
            return
        }
        
        // Create handler block with proper signature
        let handler: @convention(block) (NSArray?, NSError?) -> Void = { [weak self] configurations, error in
            guard let self = self else { return }
            Task { @MainActor in
                if let error = error {
                    // On macOS 26+/27 beta, NEConfigurationManager often fails with
                    // NEConfigurationErrorDomain code 11 ("IPC failed"). SystemConfiguration
                    // still enumerates the same VPN services with matching UUIDs.
                    Logger.vpn.warning(
                        "NEConfigurationManager failed (\(error.domain) \(error.code): \(error.localizedDescription)); using SystemConfiguration fallback"
                    )
                    self.completeWithSystemConfigurationFallback(
                        preferredError: .frameworkLoadFailed(reason: error.localizedDescription),
                        completion: completion
                    )
                    return
                }
                
                guard let nsArray = configurations as NSArray? else {
                    self.completeWithSystemConfigurationFallback(preferredError: nil, completion: completion)
                    return
                }
                
                let connections = self.processConfigurations(nsArray)
                if connections.isEmpty {
                    // NE succeeded but returned nothing — SC may still see services
                    // (e.g. some system VPN entries only visible via SCPreferences).
                    let fallback = self.loadConfigurationsViaSystemConfiguration()
                    completion(.success(fallback.isEmpty ? connections : fallback))
                } else {
                    completion(.success(connections))
                }
            }
        }
        
        // Get method implementation and call directly (same approach as v0.6.0)
        // The block is automatically retained by Objective-C runtime when passed
        guard let imp = manager.method(for: selector) else {
            completeWithSystemConfigurationFallback(
                preferredError: .sharedManagerUnavailable,
                completion: completion
            )
            return
        }
        
        // Convert block to AnyObject for passing to Objective-C
        // Note: This is safe because @convention(block) closures are automatically
        // retained by Objective-C runtime when passed as parameters
        let block = unsafeBitCast(handler, to: AnyObject.self)
        let queue = self.sessionQueue
        
        typealias MethodType = @convention(c) (AnyObject, Selector, DispatchQueue, AnyObject) -> Void
        let method = unsafeBitCast(imp, to: MethodType.self)
        
        method(manager, selector, queue, block)
    }
    
    private func processConfigurations(_ configurations: NSArray) -> [VPNConnection] {
        var processedConnections: [VPNConnection] = []
        
        for index in 0..<configurations.count {
            guard let config = configurations[index] as? NSObject else {
                continue
            }
            
            let name = config.value(forKey: "name") as? String
            let identifier = config.value(forKey: "identifier") as? NSUUID
            
            guard let name = name, let identifier = identifier,
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

    /// Completes with SystemConfiguration results when possible; otherwise surfaces `preferredError`
    /// (or success with an empty list if no preferred error was provided).
    private func completeWithSystemConfigurationFallback(
        preferredError: VPNError?,
        completion: @escaping (Result<[VPNConnection], VPNError>) -> Void
    ) {
        let fallback = loadConfigurationsViaSystemConfiguration()
        if !fallback.isEmpty {
            Logger.vpn.info("Loaded \(fallback.count) VPN configuration(s) via SystemConfiguration")
            completion(.success(fallback))
            return
        }
        if let preferredError {
            completion(.failure(preferredError))
        } else {
            completion(.success([]))
        }
    }

    /// Enumerates VPN network services via SystemConfiguration (SCPreferences).
    ///
    /// Service IDs match the UUIDs used by `ne_session_*` / `scutil --nc`, so connect/status
    /// continue to work even when `NEConfigurationManager` IPC is broken (observed on macOS 27 beta).
    private func loadConfigurationsViaSystemConfiguration() -> [VPNConnection] {
        guard let prefs = SCPreferencesCreate(nil, "VPNBar" as CFString, nil) else {
            Logger.vpn.error("SCPreferencesCreate failed")
            return []
        }

        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            Logger.vpn.error("SCNetworkServiceCopyAll returned nil")
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

            // Skip disabled services — scutil marks them without "*", and connect would fail.
            if !SCNetworkServiceGetEnabled(service) {
                Logger.vpn.debug("Skipping disabled VPN service: \(name)")
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
        if networkExtensionFrameworkLoaded {
            return
        }
        
        let possiblePaths = [
            "/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension",
            "/System/Library/Frameworks/NetworkExtension.framework/Versions/A/NetworkExtension",
            "/System/Library/Frameworks/NetworkExtension.framework"
        ]
        
        var frameworkLoaded = false
        for frameworkPath in possiblePaths {
            if dlopen(frameworkPath, RTLD_LAZY | RTLD_GLOBAL) != nil {
                frameworkLoaded = true
                break
            }
        }
        
        if !frameworkLoaded {
            if Bundle(identifier: "com.apple.NetworkExtension") != nil {
                frameworkLoaded = true
            }
        }
        
        networkExtensionFrameworkLoaded = frameworkLoaded
    }
}
