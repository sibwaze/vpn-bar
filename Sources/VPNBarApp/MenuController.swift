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
    /// True only while `popUp` is tracking — live menu rebuilds are gated on this.
    private var isMenuOpen = false
    private var networkInfoObserver: NSObjectProtocol?
    /// Coalesce multiple networkInfoDidChange events into one rebuild per run-loop turn.
    private var menuRebuildScheduled = false

    init(vpnManager: VPNManagerProtocol, networkInfoManager: NetworkInfoManagerProtocol? = nil) {
        self.vpnManager = vpnManager
        self.networkInfoManager = networkInfoManager ?? NetworkInfoManager.shared
        // Menu is built only when shown — no continuous rebuild / background polling.
    }

    /// Shows menu for the specified status bar item.
    /// - Parameter statusItem: Status bar item for which to build the menu.
    func showMenu(for statusItem: NSStatusItem?) {
        self.statusItem = statusItem
        isMenuOpen = true

        // Kick off GeoIP before the modal menu loop so “fetching…” is correct on first paint.
        if vpnManager.hasActiveConnection, networkInfoManager.networkInfo?.publicIP == nil {
            networkInfoManager.refresh(force: false)
        }

        // Subscribe BEFORE popUp: notifications fire when the fetch finishes during tracking.
        // No timers/polling — only event-driven rebuilds while the menu is open.
        startNetworkInfoObservation()

        // Start background work before popUp (which blocks the caller until dismiss).
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
            guard !Task.isCancelled, self.isMenuOpen else { return }
            self.rebuildOpenMenu()
        }

        rebuildOpenMenu()
        popUpMenu()

        // Menu dismissed — stop live updates; leave any in-flight GeoIP alone for cache.
        isMenuOpen = false
        stopNetworkInfoObservation()
        showMenuTask?.cancel()
        showMenuTask = nil
    }

    private func startNetworkInfoObservation() {
        stopNetworkInfoObservation()
        networkInfoObserver = NotificationCenter.default.addObserver(
            forName: .networkInfoDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRebuildOpenMenu()
            }
        }
    }

    /// One rebuild per run-loop turn while the menu is open (no timers, no background work).
    private func scheduleRebuildOpenMenu() {
        guard isMenuOpen, !menuRebuildScheduled else { return }
        menuRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuRebuildScheduled = false
            guard self.isMenuOpen else { return }
            self.rebuildOpenMenu()
        }
    }

    private func stopNetworkInfoObservation() {
        if let networkInfoObserver {
            NotificationCenter.default.removeObserver(networkInfoObserver)
            self.networkInfoObserver = nil
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
        rebuildOpenMenu()
    }

    /// Creates menu for the specified NSMenu (for testing). Builds directly into the given menu to avoid reusing items across menus.
    func buildMenu(menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(into: menu)
    }

    /// Rebuilds into the same `NSMenu` instance so an already-open popup updates in place.
    private func rebuildOpenMenu() {
        let target: NSMenu
        if let menu {
            target = menu
            target.removeAllItems()
        } else {
            target = NSMenu()
            if NSApp != nil {
                target.appearance = NSApp.effectiveAppearance
            }
            self.menu = target
        }
        buildMenu(into: target)
        // Force layout refresh while the menu is tracking (otherwise items can look stale).
        target.update()
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

        let info = networkInfoManager.networkInfo

        if let location = info?.formattedLocation {
            let locationItem = NSMenuItem(title: location, action: nil, keyEquivalent: "")
            locationItem.isEnabled = false
            menu.addItem(locationItem)
        }

        if let ip = info?.publicIP {
            let ipItem = NSMenuItem(
                title: "IP: \(ip)",
                action: #selector(openIPLookupPage(_:)),
                keyEquivalent: ""
            )
            ipItem.target = self
            ipItem.representedObject = ip
            menu.addItem(ipItem)
        } else if shouldShowNetworkInfoFetching {
            // Loading / not finished yet — never flash “unavailable” prematurely.
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

        if let interfaces = info?.vpnInterfaces {
            for iface in interfaces {
                let ifaceTitle = NSLocalizedString(
                    "menu.networkInfo.interface",
                    comment: "VPN interface label"
                ) + ": \(iface.name) (\(iface.address))"
                let ifaceItem = NSMenuItem(title: ifaceTitle, action: nil, keyEquivalent: "")
                ifaceItem.isEnabled = false
                menu.addItem(ifaceItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
    }

    /// Prefer “fetching…” until a GeoIP attempt has actually finished without an IP.
    private var shouldShowNetworkInfoFetching: Bool {
        if networkInfoManager.networkInfo?.publicIP != nil { return false }
        if networkInfoManager.isLoading { return true }
        return !networkInfoManager.hasFinishedFetch
    }

    @objc private func openIPLookupPage(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(AppConstants.URLs.browserLeaksIP)
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
