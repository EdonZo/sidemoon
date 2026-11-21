import AppKit
import Carbon.HIToolbox
import SidemoonCompanion

/// Global hotkeys through Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKeyCenter {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    /// Returns false when macOS refused the combination (for example, another app already owns it).
    @discardableResult
    func register(_ spec: HotKeySpec, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: CompanionConstants.HotKeys.signature, id: spec.id)
        let status = RegisterEventHotKey(spec.keyCode, Self.carbonModifiers(spec.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[spec.id] = ref
        actions[spec.id] = action
        return true
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    static func carbonModifiers(_ m: HotKeySpec.Modifiers) -> UInt32 {
        var r = 0
        if m.contains(.control) { r |= controlKey }
        if m.contains(.option) { r |= optionKey }
        if m.contains(.shift) { r |= shiftKey }
        if m.contains(.command) { r |= cmdKey }
        return UInt32(r)
    }

    static func eventModifiers(_ m: HotKeySpec.Modifiers) -> NSEvent.ModifierFlags {
        var r: NSEvent.ModifierFlags = []
        if m.contains(.control) { r.insert(.control) }
        if m.contains(.option) { r.insert(.option) }
        if m.contains(.shift) { r.insert(.shift) }
        if m.contains(.command) { r.insert(.command) }
        return r
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == CompanionConstants.HotKeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { center.fire(hotKey.id) }
            return noErr
        }, 1, &type, context, &handlerRef)
    }
}
