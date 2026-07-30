import AppKit
import Carbon

/// Global hotkey settings (single toggle shortcut).
@MainActor
final class HotkeySettingsView: NSView {
    private let settingsManager: SettingsManagerProtocol
    var hotkeyButton: NSButton?
    var clearHotkeyButton: NSButton?
    var isRecordingHotkey = false
    private var monitors: [Any] = []
    var onHotkeyChanged: (() -> Void)?

    init(settingsManager: SettingsManagerProtocol, vpnManager: VPNManagerProtocol = VPNManager.shared, frame: NSRect = .zero) {
        self.settingsManager = settingsManager
        super.init(frame: frame)
        _ = vpnManager
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    func syncUI() { updateButtonTitle() }
    func hotkeyDidChange() { updateButtonTitle() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: NSLocalizedString("settings.hotkey.title", comment: ""))
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let button = NSButton()
        button.bezelStyle = .recessed
        button.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.cgColor
        button.target = self
        button.action = #selector(startRecording)
        hotkeyButton = button
        row.addArrangedSubview(button)

        let clear = NSButton()
        clear.isBordered = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clear.imagePosition = .imageOnly
        clear.contentTintColor = .secondaryLabelColor
        clear.target = self
        clear.action = #selector(clearHotkey)
        clear.isHidden = settingsManager.hotkeyKeyCode == nil
        clearHotkeyButton = clear
        row.addArrangedSubview(clear)
        stack.addArrangedSubview(row)

        let desc = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.hotkey.description", comment: ""))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(desc)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            widthAnchor.constraint(equalToConstant: 556),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        updateButtonTitle()
    }

    @objc private func startRecording() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        hotkeyButton?.title = NSLocalizedString("settings.hotkey.pressKeys", comment: "")
        hotkeyButton?.contentTintColor = .controlAccentColor

        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handle(e); return nil
        }) {
            monitors.append(l)
        }
    }

    private func handle(_ event: NSEvent) {
        guard isRecordingHotkey else { return }
        let keyCode = UInt32(event.keyCode)
        if keyCode == KeyCode.escape.rawValue {
            stopRecording()
            updateButtonTitle()
            return
        }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        guard (mods & UInt32(cmdKey | controlKey | optionKey)) != 0 else { return }

        stopRecording()
        settingsManager.saveHotkey(keyCode: keyCode, modifiers: mods)
        clearHotkeyButton?.isHidden = false
        updateButtonTitle()
        onHotkeyChanged?()
    }

    @objc private func clearHotkey() {
        settingsManager.saveHotkey(keyCode: nil, modifiers: nil)
        clearHotkeyButton?.isHidden = true
        updateButtonTitle()
        onHotkeyChanged?()
    }

    private func stopRecording() {
        isRecordingHotkey = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func updateButtonTitle() {
        guard let button = hotkeyButton else { return }
        if let code = settingsManager.hotkeyKeyCode, let mods = settingsManager.hotkeyModifiers {
            button.title = format(code: code, mods: mods)
            button.contentTintColor = .labelColor
        } else {
            button.title = NSLocalizedString("settings.hotkey.record", comment: "")
            button.contentTintColor = .secondaryLabelColor
        }
        clearHotkeyButton?.isHidden = settingsManager.hotkeyKeyCode == nil
    }

    private func format(code: UInt32, mods: UInt32) -> String {
        var p: [String] = []
        if mods & UInt32(controlKey) != 0 { p.append("⌃") }
        if mods & UInt32(optionKey) != 0 { p.append("⌥") }
        if mods & UInt32(shiftKey) != 0 { p.append("⇧") }
        if mods & UInt32(cmdKey) != 0 { p.append("⌘") }
        if let k = KeyCode(rawValue: code)?.stringValue { p.append(k) }
        return p.joined()
    }
}
