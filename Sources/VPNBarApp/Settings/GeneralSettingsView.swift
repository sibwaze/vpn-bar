import AppKit

/// General settings: startup, notifications, display.
@MainActor
final class GeneralSettingsView: NSView {
    private var settingsManager: SettingsManagerProtocol
    private let vpnManager: VPNManagerProtocol

    var showNotificationsCheckbox: NSButton?
    var showConnectionNameCheckbox: NSButton?
    var launchAtLoginCheckbox: NSButton?

    init(
        settingsManager: SettingsManagerProtocol,
        vpnManager: VPNManagerProtocol,
        frame: NSRect = .zero
    ) {
        self.settingsManager = settingsManager
        self.vpnManager = vpnManager
        super.init(frame: frame)
        _ = vpnManager
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func syncUI() {
        showNotificationsCheckbox?.state = settingsManager.showNotifications ? .on : .off
        showConnectionNameCheckbox?.state = settingsManager.showConnectionName ? .on : .off
        launchAtLoginCheckbox?.state = settingsManager.launchAtLogin ? .on : .off
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        mainStack.addArrangedSubview(createStartupSection())
        mainStack.addArrangedSubview(makeDivider())
        mainStack.addArrangedSubview(createNotificationsSection())
        mainStack.addArrangedSubview(makeDivider())
        mainStack.addArrangedSubview(createDisplaySection())

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            widthAnchor.constraint(equalToConstant: 556)
        ])
    }

    private func createNotificationsSection() -> NSView {
        let section = sectionStack(titleKey: "settings.notifications.title")
        let checkbox = NSButton(
            checkboxWithTitle: NSLocalizedString("settings.notifications.toggle", comment: ""),
            target: self,
            action: #selector(showNotificationsChanged(_:))
        )
        checkbox.state = settingsManager.showNotifications ? .on : .off
        checkbox.font = .systemFont(ofSize: 13)
        showNotificationsCheckbox = checkbox
        section.addArrangedSubview(checkbox)
        section.addArrangedSubview(descriptionLabel("settings.notifications.description"))
        return section
    }

    private func createDisplaySection() -> NSView {
        let section = sectionStack(titleKey: "settings.display.title")
        let checkbox = NSButton(
            checkboxWithTitle: NSLocalizedString("settings.display.showName", comment: ""),
            target: self,
            action: #selector(showConnectionNameChanged(_:))
        )
        checkbox.state = settingsManager.showConnectionName ? .on : .off
        checkbox.font = .systemFont(ofSize: 13)
        showConnectionNameCheckbox = checkbox
        section.addArrangedSubview(checkbox)
        section.addArrangedSubview(descriptionLabel("settings.display.description"))
        return section
    }

    private func createStartupSection() -> NSView {
        let section = sectionStack(titleKey: "settings.startup.title")
        let checkbox = NSButton(
            checkboxWithTitle: NSLocalizedString("settings.startup.launchAtLogin", comment: ""),
            target: self,
            action: #selector(launchAtLoginChanged(_:))
        )
        checkbox.state = settingsManager.launchAtLogin ? .on : .off
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.isEnabled = settingsManager.isLaunchAtLoginAvailable
        launchAtLoginCheckbox = checkbox
        section.addArrangedSubview(checkbox)

        var text = NSLocalizedString("settings.startup.description", comment: "")
        if !settingsManager.isLaunchAtLoginAvailable {
            text += " " + NSLocalizedString("settings.startup.requires13", comment: "")
        }
        let desc = NSTextField(wrappingLabelWithString: text)
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 524
        section.addArrangedSubview(desc)
        return section
    }

    private func sectionStack(titleKey: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let label = NSTextField(labelWithString: NSLocalizedString(titleKey, comment: ""))
        label.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(label)
        return stack
    }

    private func descriptionLabel(_ key: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: NSLocalizedString(key, comment: ""))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 524
        return label
    }

    private func makeDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    @objc private func showNotificationsChanged(_ sender: NSButton) {
        settingsManager.showNotifications = sender.state == .on
    }

    @objc private func showConnectionNameChanged(_ sender: NSButton) {
        settingsManager.showConnectionName = sender.state == .on
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        settingsManager.launchAtLogin = sender.state == .on
    }
}
