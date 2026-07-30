import Foundation
import SystemConfiguration
import os.log

/// Loads VPN configs from SystemConfiguration current network set (`scutil --nc list` scope).
@MainActor
final class VPNConfigurationLoader: VPNConfigurationLoaderProtocol {
    private static let vpnInterfaceTypes: Set<String> = ["VPN", "IPSec"]

    func loadConfigurations(completion: @escaping (Result<[VPNConnection], VPNError>) -> Void) {
        completion(.success(loadViaSystemConfiguration()))
    }

    private func loadViaSystemConfiguration() -> [VPNConnection] {
        guard let prefs = SCPreferencesCreate(nil, "VPNBar" as CFString, nil) else {
            Logger.vpn.error("SCPreferencesCreate failed")
            return []
        }

        let services: [SCNetworkService]
        if let currentSet = SCNetworkSetCopyCurrent(prefs),
           let setServices = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] {
            services = setServices
        } else if let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            services = all
        } else {
            return []
        }

        var result: [VPNConnection] = []
        for service in services {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  Self.vpnInterfaceTypes.contains(type),
                  let name = SCNetworkServiceGetName(service) as String?,
                  let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  !name.hasPrefix("com.apple.preferences."),
                  SCNetworkServiceGetEnabled(service) else {
                continue
            }

            result.append(VPNConnection(
                id: serviceID,
                name: name,
                serviceID: serviceID,
                status: .disconnected
            ))
        }
        return result.sorted { $0.name < $1.name }
    }
}
