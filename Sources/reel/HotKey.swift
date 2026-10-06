import Carbon.HIToolbox

/// Global hotkey via Carbon, which (unlike event taps) needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private nonisolated(unsafe) static var handlers: [UInt32: () -> Void] = [:]
    private nonisolated(unsafe) static var nextID: UInt32 = 1
    private nonisolated(unsafe) static var installed = false

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        let hkID = EventHotKeyID(signature: OSType(0x5245_454C), id: id) // 'REEL'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID
            )
            DispatchQueue.main.async { HotKey.handlers[hkID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
