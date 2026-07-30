import AppKit

/// Lazy settings window (built on first open).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var generalView: GeneralSettingsView?
    private var hotkeyView: HotkeySettingsView?
    private let vpnManager = VPNManager.shared
    private let settingsManager = SettingsManager.shared

    private init() {}

    func showWindow() {
        if window == nil { buildWindow() }
        generalView?.syncUI()
        hotkeyView?.syncUI()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("settings.title.preferences", comment: "")
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let general = GeneralSettingsView(settingsManager: settingsManager, vpnManager: vpnManager)
        generalView = general
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = NSLocalizedString("settings.tab.general", comment: "")
        generalTab.view = general
        tabView.addTabViewItem(generalTab)

        let hotkey = HotkeySettingsView(settingsManager: settingsManager, vpnManager: vpnManager)
        hotkey.onHotkeyChanged = { [weak self] in self?.registerHotkey() }
        hotkeyView = hotkey
        let hotkeyTab = NSTabViewItem(identifier: "hotkeys")
        hotkeyTab.label = NSLocalizedString("settings.tab.hotkeys", comment: "")
        hotkeyTab.view = hotkey
        tabView.addTabViewItem(hotkeyTab)

        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = NSLocalizedString("settings.tab.about", comment: "")
        aboutTab.view = AboutSettingsView()
        tabView.addTabViewItem(aboutTab)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        window.contentView = contentView
        self.window = window
    }

    private func registerHotkey() {
        guard let keyCode = settingsManager.hotkeyKeyCode,
              let modifiers = settingsManager.hotkeyModifiers else {
            HotkeyManager.shared.unregisterHotkey()
            return
        }
        HotkeyManager.shared.registerHotkey(keyCode: keyCode, modifiers: modifiers) {
            StatusBarController.shared?.toggleVPNConnection()
        }
    }
}
