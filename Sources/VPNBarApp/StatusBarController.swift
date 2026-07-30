import AppKit
import Combine
import os.log

/// Menu bar icon, clicks, and connection toggle.
@MainActor
final class StatusBarController {
    static var shared: StatusBarController?

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let vpnManager: VPNManager
    private let settingsManager: SettingsManager

    init(
        vpnManager: VPNManager = .shared,
        settingsManager: SettingsManager = .shared
    ) {
        self.vpnManager = vpnManager
        self.settingsManager = settingsManager
        StatusBarController.shared = self
        setupStatusBar()
        bindVPNState()
        applyIconState()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(NSLocalizedString("status.accessibility.label", comment: ""))
        button.setAccessibilityHelp(NSLocalizedString("status.accessibility.help", comment: ""))
        button.setAccessibilityRole(.button)
    }

    private func bindVPNState() {
        vpnManager.$connections
            .sink { [weak self] _ in self?.applyIconState() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .showConnectionNameDidChange)
            .sink { [weak self] _ in self?.applyIconState() }
            .store(in: &cancellables)
    }

    private func applyIconState() {
        guard let button = statusItem?.button else { return }
        let connections = vpnManager.connections

        let isBusy = connections.contains { $0.status == .connecting || $0.status == .disconnecting }
        if isBusy {
            button.image = Self.symbol("network")
            button.title = ""
            let tip = NSLocalizedString("status.tooltip.connecting", comment: "")
            button.toolTip = tip
            button.setAccessibilityValue(tip)
            return
        }

        if let active = connections.first(where: { $0.status.isActive }) {
            button.image = Self.symbol("network.badge.shield.half.filled")
            button.title = ""
            if settingsManager.showConnectionName {
                button.toolTip = active.name
                button.setAccessibilityValue(String(
                    format: NSLocalizedString("status.tooltip.connectedTo", comment: ""),
                    active.name
                ))
            } else {
                let tip = NSLocalizedString("status.tooltip.connected", comment: "")
                button.toolTip = tip
                button.setAccessibilityValue(tip)
            }
            return
        }

        button.image = Self.disconnectedImage()
        button.title = ""
        let tip = NSLocalizedString("status.tooltip.disconnected", comment: "")
        button.toolTip = tip
        button.setAccessibilityValue(tip)
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private static var cachedDisconnected: NSImage?
    private static func disconnectedImage() -> NSImage? {
        if let cachedDisconnected { return cachedDisconnected }
        guard let base = NSImage(systemSymbolName: "network", accessibilityDescription: nil) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        image.isTemplate = true
        cachedDisconnected = image
        return image
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            MenuController.shared.showMenu(for: statusItem)
        } else if event?.type == .leftMouseUp {
            toggleVPNConnection()
        }
    }

    func toggleVPNConnection() {
        let connections = vpnManager.connections
        guard !connections.isEmpty else { return }

        let wasActive = vpnManager.hasActiveConnection
        let target: (id: String, name: String)?

        if let active = connections.first(where: { $0.status.isActive }) {
            target = (active.id, active.name)
        } else if let lastID = settingsManager.lastUsedConnectionID,
                  let last = connections.first(where: { $0.id == lastID }) {
            target = (last.id, last.name)
        } else if connections.count == 1, let only = connections.first {
            target = (only.id, only.name)
        } else {
            MenuController.shared.showMenu(for: statusItem)
            return
        }

        guard let target else { return }
        vpnManager.toggleConnection(target.id)

        if settingsManager.showNotifications {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(AppConstants.notificationDelay * 1_000_000_000))
                let nowActive = self.vpnManager.hasActiveConnection
                if wasActive != nowActive {
                    NotificationManager.shared.sendVPNNotification(
                        isConnected: nowActive,
                        connectionName: target.name
                    )
                }
            }
        }
    }

    func cleanup() {
        cancellables.removeAll()
    }
}
