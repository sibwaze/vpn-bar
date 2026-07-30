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
        static let requestTimeout: TimeInterval = 3.5
    }

    enum URLs {
        static let repository = URL(string: "https://github.com/borzov/vpn-bar")!
        static let networkPreferences = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
    }
}
