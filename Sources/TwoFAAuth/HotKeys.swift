// System-wide shortcuts through Carbon's RegisterEventHotKey: no Accessibility permission needed.
import Carbon.HIToolbox
import Foundation

final class HotKeys {
    struct Key {
        let keyCode: Int
        let modifiers: Int
        let action: () -> Void
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []

    init(_ keys: [Key]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)

        for (index, key) in keys.enumerated() {
            let id = UInt32(index + 1)
            HotKeys.actions[id] = key.action
            var ref: EventHotKeyRef?
            // "2FAA"; a shortcut already taken by another app simply does not register.
            let hotKeyID = EventHotKeyID(signature: OSType(0x3246_4141), id: id)
            if RegisterEventHotKey(UInt32(key.keyCode), UInt32(key.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
    }
}
