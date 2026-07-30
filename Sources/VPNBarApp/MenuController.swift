import AppKit

/// Status bar menu controller.
@MainActor
class MenuController {
    static let shared = MenuController(vpnManager: VPNManager.shared)

    // MARK: - Cached Images

    private var menu: NSMenu?
    private var statusItem: NSStatusItem?
    private let vpnManager: VPNManagerProtocol

    private let networkInfoManager: NetworkInfoManagerProtocol
    private var showMenuTask: Task<Void, Never>?

    init(vpnManager: VPNManagerProtocol, networkInfoManager: NetworkInfoManagerProtocol? = nil) {
        self.vpnManager = vpnManager
        self.networkInfoManager = networkInfoManager ?? NetworkInfoManager.shared
        // Menu is built only when shown — no continuous rebuild on $connections.
    }

    /// Shows menu for the specified status bar item.
    /// - Parameter statusItem: Status bar item for which to build the menu.
    func showMenu(for statusItem: NSStatusItem?) {
        self.statusItem = statusItem
        // Open immediately with current state — never block on network/SC reload.
        buildMenu()
        popUpMenu()

        // Refresh list + network info in the background for next open.
        showMenuTask?.cancel()
        showMenuTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let manager = self.vpnManager as? VPNManager {
                await manager.reloadConnectionsAsync()
            } else {
                self.vpnManager.loadConnections(forceReload: true)
            }
            guard !Task.isCancelled else { return }
            if self.vpnManager.hasActiveConnection {
                _ = await self.networkInfoManager.refreshAndWait(force: false, timeout: nil)
            }
        }
    }

    private func popUpMenu() {
        guard let statusItem = statusItem,
              let button = statusItem.button,
              let window = button.window else { return }

        let buttonFrame = button.convert(button.bounds, to: nil)
        let pointInWindow = button.superview?.convert(buttonFrame.origin, to: nil) ?? buttonFrame.origin
        let screenPoint = window.convertPoint(toScreen: NSPoint(x: pointInWindow.x, y: pointInWindow.y + buttonFrame.height))

        menu?.popUp(positioning: nil, at: screenPoint, in: nil)
    }
    
    /// Rebuilds menu with current data (only useful while testing or after an action).
    func updateMenu() {
        buildMenu()
    }
    
    /// Creates menu for the specified NSMenu (for testing). Builds directly into the given menu to avoid reusing items across menus.
    func buildMenu(menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(into: menu)
    }

    private func buildMenu() {
        let newMenu = NSMenu()
        if NSApp != nil {
            newMenu.appearance = NSApp.effectiveAppearance
        }
        buildMenu(into: newMenu)
        self.menu = newMenu
    }

    private func buildMenu(into targetMenu: NSMenu) {
        addNetworkInfoSection(to: targetMenu)

        if let error = vpnManager.loadingError {
            let errorItem = NSMenuItem(title: error.errorDescription ?? "", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            errorItem.image = MenuController.errorImage()
            targetMenu.addItem(errorItem)

            let openNetworkPrefsItem = NSMenuItem(
                title: NSLocalizedString(
                    "menu.action.openNetworkPreferences",
                    comment: "Menu action to open macOS Network preferences"
                ),
                action: #selector(openNetworkPreferences(_:)),
                keyEquivalent: ""
            )
            openNetworkPrefsItem.target = self
            targetMenu.addItem(openNetworkPrefsItem)
        } else if vpnManager.connections.isEmpty {
            let noConnectionsItem = NSMenuItem(
                title: NSLocalizedString(
                    "menu.empty.noConnections",
                    comment: "Shown when there are no VPN configurations"
                ),
                action: nil,
                keyEquivalent: ""
            )
            noConnectionsItem.isEnabled = false
            targetMenu.addItem(noConnectionsItem)
        } else {
            for connection in vpnManager.connections {
                let menuItem = NSMenuItem(
                    title: connection.name,
                    action: #selector(vpnConnectionToggled(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = connection.id

                if connection.status.isActive {
                    menuItem.image = MenuController.activeImage()
                } else {
                    menuItem.image = MenuController.inactiveImage()
                }

                var title = connection.name
                if connection.status != .disconnected {
                    title += " (\(connection.status.localizedDescription))"
                }
                menuItem.title = title

                menuItem.setAccessibilityLabel("\(connection.name), \(connection.status.localizedDescription)")
                menuItem.setAccessibilityHelp(
                    NSLocalizedString(
                        "menu.accessibility.toggleConnection",
                        comment: "Accessibility help for toggling a VPN connection from menu"
                    )
                )

                targetMenu.addItem(menuItem)
            }
        }

        targetMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("menu.action.settings", comment: "Menu item to open settings"),
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        targetMenu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: NSLocalizedString("menu.action.quit", comment: "Menu item to quit the app"),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        targetMenu.addItem(quitItem)
    }
    
    @objc func vpnConnectionToggled(_ sender: NSMenuItem) {
        guard let connectionID = sender.representedObject as? String else { return }
        vpnManager.toggleConnection(connectionID)
    }
    
    @objc private func showSettings(_ sender: NSMenuItem) {
        SettingsWindowController.shared.showWindow()
    }
    
    @objc private func quitApplication(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func openNetworkPreferences(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(AppConstants.URLs.networkPreferences)
    }
    
    // MARK: - Network Info

    private func addNetworkInfoSection(to menu: NSMenu) {
        guard vpnManager.hasActiveConnection else { return }

        if let info = networkInfoManager.networkInfo {
            if let location = info.formattedLocation {
                let locationItem = NSMenuItem(title: location, action: nil, keyEquivalent: "")
                locationItem.isEnabled = false
                menu.addItem(locationItem)
            }

            if let ip = info.publicIP {
                let ipItem = NSMenuItem(
                    title: "IP: \(ip)",
                    action: #selector(copyIPAddress(_:)),
                    keyEquivalent: ""
                )
                ipItem.target = self
                ipItem.representedObject = ip
                ipItem.toolTip = NSLocalizedString(
                    "menu.networkInfo.copyIP",
                    comment: "Tooltip for copying IP address"
                )
                menu.addItem(ipItem)
            } else if networkInfoManager.isLoading {
                let fetchingItem = NSMenuItem(
                    title: NSLocalizedString(
                        "menu.networkInfo.fetching",
                        comment: "Placeholder while loading network info"
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                fetchingItem.isEnabled = false
                menu.addItem(fetchingItem)
            } else {
                let unavailableItem = NSMenuItem(
                    title: NSLocalizedString(
                        "menu.networkInfo.unavailable",
                        comment: "Shown when network info could not be loaded"
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                unavailableItem.isEnabled = false
                menu.addItem(unavailableItem)
            }

            for iface in info.vpnInterfaces {
                let ifaceTitle = NSLocalizedString(
                    "menu.networkInfo.interface",
                    comment: "VPN interface label"
                ) + ": \(iface.name) (\(iface.address))"
                let ifaceItem = NSMenuItem(title: ifaceTitle, action: nil, keyEquivalent: "")
                ifaceItem.isEnabled = false
                menu.addItem(ifaceItem)
            }
        } else if networkInfoManager.isLoading {
            let fetchingItem = NSMenuItem(
                title: NSLocalizedString(
                    "menu.networkInfo.fetching",
                    comment: "Placeholder while loading network info"
                ),
                action: nil,
                keyEquivalent: ""
            )
            fetchingItem.isEnabled = false
            menu.addItem(fetchingItem)
        } else {
            let unavailableItem = NSMenuItem(
                title: NSLocalizedString(
                    "menu.networkInfo.unavailable",
                    comment: "Shown when network info could not be loaded"
                ),
                action: nil,
                keyEquivalent: ""
            )
            unavailableItem.isEnabled = false
            menu.addItem(unavailableItem)
        }

        menu.addItem(NSMenuItem.separator())
    }

    @objc private func copyIPAddress(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    // MARK: - Cached Image Helpers
    
    private static func activeImage() -> NSImage? {
        symbol("checkmark.circle.fill")
    }

    private static func inactiveImage() -> NSImage? {
        symbol("circle")
    }

    private static func errorImage() -> NSImage? {
        symbol("exclamationmark.triangle")
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
