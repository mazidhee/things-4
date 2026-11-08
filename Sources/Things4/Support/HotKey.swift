import AppKit
import Carbon

/// A system-wide keyboard shortcut registered through Carbon. Unlike
/// NSEvent global monitors this needs no Accessibility permission.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private let handler: () -> Void
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.registry[id] = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.registry[hotKeyID.id]?.handler()
            return noErr
        }, 1, &eventType, nil, &handlerReference)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5448_3447), id: id) // "TH4G"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
        reference = nil
        handlerReference = nil
        HotKey.registry[id] = nil
    }

    deinit { unregister() }
}
