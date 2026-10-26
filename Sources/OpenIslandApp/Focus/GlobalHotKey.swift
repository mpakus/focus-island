import Carbon
import FocusCore
import Foundation

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    private let identifier: UInt32
    private let keyCode: UInt32

    init(hotKey: BoardHotKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        identifier = 1
        keyCode = UInt32(kVK_ANSI_B)
        installHandler()
        update(hotKey)
    }

    init(paletteEnabled: Bool, action: @escaping @MainActor () -> Void) {
        self.action = action
        identifier = 2
        keyCode = UInt32(kVK_ANSI_K)
        installHandler()
        updatePalette(enabled: paletteEnabled)
    }

    func updatePalette(enabled: Bool) {
        update(enabled ? .optionCommandB : .off)
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func update(_ hotKey: BoardHotKey) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let modifiers: UInt32
        switch hotKey {
        case .optionCommandB: modifiers = UInt32(optionKey | cmdKey)
        case .controlOptionB: modifiers = UInt32(controlKey | optionKey)
        case .off: return
        }
        let id = EventHotKeyID(signature: OSType(0x46_4F_43_53), id: identifier)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                guard id.signature == OSType(0x46_4F_43_53), id.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
                hotKey.action()
                return noErr
            }
        }, 1, &spec, context, &handlerRef)
    }
}
