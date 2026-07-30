import Foundation
import AppKit
import ServiceManagement
import os.log

/// Manages application user settings.
@MainActor
class SettingsManager: SettingsManagerProtocol {
    static let shared = SettingsManager()

    private let userDefaults: UserDefaults
    private let updateIntervalKey = "updateInterval"
    private let hotkeyKeyCodeKey = "hotkeyKeyCode"
    private let hotkeyModifiersKey = "hotkeyModifiers"
    private let showNotificationsKey = "showNotifications"
    private let showConnectionNameKey = "showConnectionName"
    private let launchAtLoginKey = "launchAtLogin"
    private let lastUsedConnectionIDKey = "lastUsedConnectionID"

    private init() {
        self.userDefaults = UserDefaults.standard
    }

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    var updateInterval: TimeInterval {
        get {
            let saved = userDefaults.double(forKey: updateIntervalKey)
            return saved > 0 ? saved : AppConstants.defaultUpdateInterval
        }
        set {
            let validated = min(max(newValue, AppConstants.minUpdateInterval), AppConstants.maxUpdateInterval)
            userDefaults.set(validated, forKey: updateIntervalKey)
            NotificationCenter.default.post(name: .updateIntervalDidChange, object: nil)
        }
    }

    var hotkeyKeyCode: UInt32? {
        get {
            let value = userDefaults.integer(forKey: hotkeyKeyCodeKey)
            return value > 0 ? UInt32(value) : nil
        }
        set {
            if let value = newValue {
                userDefaults.set(Int(value), forKey: hotkeyKeyCodeKey)
            } else {
                userDefaults.removeObject(forKey: hotkeyKeyCodeKey)
            }
            NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        }
    }

    var hotkeyModifiers: UInt32? {
        get {
            let value = userDefaults.integer(forKey: hotkeyModifiersKey)
            return value > 0 ? UInt32(value) : nil
        }
        set {
            if let value = newValue {
                userDefaults.set(Int(value), forKey: hotkeyModifiersKey)
            } else {
                userDefaults.removeObject(forKey: hotkeyModifiersKey)
            }
            NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        }
    }

    func saveHotkey(keyCode: UInt32?, modifiers: UInt32?) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
    }

    var showNotifications: Bool {
        get {
            if userDefaults.object(forKey: showNotificationsKey) == nil { return true }
            return userDefaults.bool(forKey: showNotificationsKey)
        }
        set { userDefaults.set(newValue, forKey: showNotificationsKey) }
    }

    var showConnectionName: Bool {
        get {
            if userDefaults.object(forKey: showConnectionNameKey) == nil { return false }
            return userDefaults.bool(forKey: showConnectionNameKey)
        }
        set {
            userDefaults.set(newValue, forKey: showConnectionNameKey)
            NotificationCenter.default.post(name: .showConnectionNameDidChange, object: nil)
        }
    }

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return userDefaults.bool(forKey: launchAtLoginKey)
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                        }
                    } else if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                    userDefaults.set(newValue, forKey: launchAtLoginKey)
                } catch {
                    Logger(subsystem: AppConstants.bundleIdentifier, category: "Settings")
                        .error("Launch at login failed: \(error.localizedDescription)")
                }
            } else {
                userDefaults.set(newValue, forKey: launchAtLoginKey)
            }
        }
    }

    var isLaunchAtLoginAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    var lastUsedConnectionID: String? {
        get { userDefaults.string(forKey: lastUsedConnectionIDKey) }
        set {
            if let value = newValue {
                userDefaults.set(value, forKey: lastUsedConnectionIDKey)
            } else {
                userDefaults.removeObject(forKey: lastUsedConnectionIDKey)
            }
        }
    }
}
