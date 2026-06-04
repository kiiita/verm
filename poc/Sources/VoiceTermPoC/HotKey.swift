import AppKit
import Carbon.HIToolbox

// Global hotkey via Carbon RegisterEventHotKey: fires even when the app isn't
// focused AND consumes the event (does not bubble to the front app), with no
// Accessibility / Input Monitoring permission required.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let handler: () -> Void
    private let idNum: UInt32
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        self.handler = handler
        idNum = HotKey.nextID; HotKey.nextID += 1
        HotKey.installHandlerIfNeeded()
        HotKey.registry[idNum] = self
        let hkID = EventHotKeyID(signature: OSType(0x56544B59), id: idNum) // 'VTKY'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    // Unregister + release so the key is free for the front app again (dynamic
    // hotkeys are only claimed while there's voice work to do).
    func invalidate() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        HotKey.registry.removeValue(forKey: idNum)
    }

    deinit { invalidate() }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { HotKey.registry[hkID.id]?.handler() }
            return noErr   // consume
        }, 1, &spec, nil, nil)
    }
}
