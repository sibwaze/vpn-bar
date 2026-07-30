import os.log

extension Logger {
    static let vpn = Logger(subsystem: AppConstants.bundleIdentifier, category: "VPN")
    static let hotkey = Logger(subsystem: AppConstants.bundleIdentifier, category: "Hotkey")
}


