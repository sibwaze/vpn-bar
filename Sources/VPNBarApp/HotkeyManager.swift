import AppKit
import Carbon
import os.log

/// Global hotkey registration (single app-wide toggle).
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalHotKeyRef: EventHotKeyRef?
    private var globalHotKeyID = EventHotKeyID(signature: FourCharCode(fromString: "VPNT"), id: 1)
    private var isRegistered = false
    private var callback: (() -> Void)?
    private var eventHandler: EventHandlerRef?
    private var isSetup = false
    private var isValid = true
    private var isRetainedForEventHandler = false

    private init() {
        setupEventHandler()
    }

    deinit {
        isValid = false
        cleanup()
    }

    private func setupEventHandler() {
        guard !isSetup else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passRetained(self).toOpaque()
        isRetainedForEventHandler = true

        let eventHandlerUPP: EventHandlerUPP = { (_, theEvent, userData) -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard err == noErr else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            guard manager.isValid else { return OSStatus(eventNotHandledErr) }

            if hotKeyID.id == manager.globalHotKeyID.id,
               hotKeyID.signature == manager.globalHotKeyID.signature {
                if let callback = manager.callback {
                    DispatchQueue.main.async {
                        guard manager.isValid else { return }
                        callback()
                    }
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }

        var handlerRef: EventHandlerRef?
        if InstallEventHandler(GetApplicationEventTarget(), eventHandlerUPP, 1, &eventSpec, userData, &handlerRef) == noErr {
            eventHandler = handlerRef
            isSetup = true
        }
    }

    func registerHotkey(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        unregisterHotkey()
        self.callback = callback

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, globalHotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr, let ref = hotKeyRef {
            globalHotKeyRef = ref
            isRegistered = true
        } else {
            self.callback = nil
            Logger.hotkey.error("Failed to register global hotkey: status=\(status)")
        }
    }

    func unregisterHotkey() {
        if let ref = globalHotKeyRef, isRegistered {
            UnregisterEventHotKey(ref)
            globalHotKeyRef = nil
            isRegistered = false
        }
        callback = nil
    }

    func cleanup() {
        guard isValid else { return }
        isValid = false
        unregisterHotkey()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            if isRetainedForEventHandler {
                Unmanaged.passUnretained(self).release()
                isRetainedForEventHandler = false
            }
            eventHandler = nil
        }
        isSetup = false
    }
}

extension FourCharCode {
    init(fromString string: String) {
        var result: FourCharCode = 0
        for (index, char) in string.utf8.prefix(4).enumerated() {
            result |= FourCharCode(char) << (8 * (3 - index))
        }
        self = result
    }
}
