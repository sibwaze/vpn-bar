import Foundation

enum AppConstants {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.borzov.VPNBar"

    static let defaultRetryCount: Int = 2
    static let retryBaseDelay: TimeInterval = 0.8
    static let connectionTimeout: TimeInterval = 25.0
    static let notificationDelay: TimeInterval = 0.4

    static let networkInfoCacheDuration: TimeInterval = 90.0
    static let networkInfoRefreshDelay: TimeInterval = 1.0

    enum NetworkInfo {
        /// BrowserLeaks returns a full HTML page; allow a bit more than pure JSON APIs.
        static let requestTimeout: TimeInterval = 6.0
    }

    enum URLs {
        static let repository = URL(string: "https://github.com/borzov/vpn-bar")!
        static let networkPreferences = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
        /// Source page for public IP / geo (parsed by NetworkInfoManager).
        static let browserLeaksIP = URL(string: "https://browserleaks.com/ip")!
    }
}
