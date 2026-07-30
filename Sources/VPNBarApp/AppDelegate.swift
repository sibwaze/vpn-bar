import AppKit
import os.log

/// Application delegate responsible for initialization and lifecycle management.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger(subsystem: AppConstants.bundleIdentifier, category: "AppDelegate")
            .info("Application did finish launching")

        statusBarController = StatusBarController()
        registerHotkeyFromSettings()

        if SettingsManager.shared.showNotifications {
            Task { @MainActor in
                NotificationManager.shared.requestAuthorization()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: .hotkeyDidChange,
            object: nil
        )
    }

    @objc @MainActor private func hotkeyDidChange() {
        registerHotkeyFromSettings()
    }

    @MainActor
    private func registerHotkeyFromSettings() {
        let settings = SettingsManager.shared
        guard let keyCode = settings.hotkeyKeyCode, let modifiers = settings.hotkeyModifiers else {
            HotkeyManager.shared.unregisterHotkey()
            return
        }

        HotkeyManager.shared.registerHotkey(keyCode: keyCode, modifiers: modifiers) {
            Task { @MainActor in
                StatusBarController.shared?.toggleVPNConnection()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        HotkeyManager.shared.cleanup()
        Task { @MainActor in
            VPNManager.shared.cleanup()
            NetworkInfoManager.shared.cleanup()
            statusBarController?.cleanup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
