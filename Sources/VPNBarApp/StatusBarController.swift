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

    /// Match default menu-bar SF Symbol scale (avoid oversized glyphs).
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

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
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryLight)
        button.setAccessibilityLabel(NSLocalizedString("status.accessibility.label", comment: ""))
        button.setAccessibilityHelp(NSLocalizedString("status.accessibility.help", comment: ""))
        button.setAccessibilityRole(.button)
    }

    private func bindVPNState() {
        // Icon must follow both list membership and live session status.
        vpnManager.$connections
            .combineLatest(vpnManager.$hasActiveConnection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyIconState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .showConnectionNameDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyIconState()
            }
            .store(in: &cancellables)
    }

    private func applyIconState() {
        guard let button = statusItem?.button else { return }
        let connections = vpnManager.connections

        // Reset presentation so previous state never "sticks".
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.contentTintColor = nil
        button.alphaValue = 1.0
        button.appearsDisabled = false

        let isBusy = connections.contains {
            $0.status == .connecting || $0.status == .disconnecting
        }
        if isBusy {
            button.image = Self.templateSymbol("network")
            let tip = NSLocalizedString("status.tooltip.connecting", comment: "")
            button.toolTip = tip
            button.setAccessibilityValue(tip)
            // Slightly dim while connecting/disconnecting.
            button.alphaValue = 0.75
            return
        }

        if let active = connections.first(where: { $0.status == .connected }) {
            // Prefer shield glyph when available; fall back to network.
            button.image = Self.templateSymbol("network.badge.shield.half.filled")
                ?? Self.templateSymbol("network")
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

        // Disconnected: full-opacity template network icon, dimmed via alpha
        // (custom redraw of SF Symbols often renders blank in the menu bar).
        button.image = Self.templateSymbol("network")
        button.alphaValue = 0.45
        let tip = NSLocalizedString("status.tooltip.disconnected", comment: "")
        button.toolTip = tip
        button.setAccessibilityValue(tip)
    }

    /// Creates a menu-bar-ready template SF Symbol (copy so callers can mutate safely).
    private static func templateSymbol(_ name: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configured = base.withSymbolConfiguration(symbolConfig) ?? base
        // Always return a copy: NSStatusBarButton may retain/mutate the image.
        let image = configured.copy() as? NSImage ?? configured
        image.isTemplate = true
        // Compact menu-bar footprint (same ballpark as system status items).
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
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

        if let active = connections.first(where: { $0.status == .connected || $0.status == .connecting }) {
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
