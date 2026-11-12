import Carbon.HIToolbox

/// ⌃⌥⌘⎋ anywhere: stop FreeRetina on every monitor. Carbon hotkeys need no Accessibility
/// permission and keep working when no FreeRetina window is focused.
final class EmergencyHotkey {
    static let description = "⌃⌥⌘⎋"

    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return OSStatus(eventNotHandledErr) }
            Unmanaged<EmergencyHotkey>.fromOpaque(user).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x4652_4554), id: 1),  // 'FRET'
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
