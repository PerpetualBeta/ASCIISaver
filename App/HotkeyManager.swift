import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys via Carbon's `RegisterEventHotKey`. Carbon is the
/// only path on macOS to install a system-wide hotkey from an app that isn't
/// a login item or accessibility client. The Swift surface is small, so we
/// wrap it cleanly.
///
/// Single instance owned by AppDelegate. Call `register(_:slot:handler:)` to
/// install a hotkey for an internal slot id; calling again with the same slot
/// replaces it. Pass an empty config to remove.
final class HotkeyManager {

    /// Internal slot identifiers; keep stable so re-registrations supersede
    /// previous installs cleanly.
    enum Slot: UInt32 {
        case activate   = 1
        case screenshot = 2
    }

    private struct Registered {
        let ref: EventHotKeyRef
        let handler: () -> Void
        /// Kept so a suspended hotkey can be registered again unchanged.
        let cfg: HotkeyConfig
    }
    private var slots: [Slot: Registered] = [:]
    /// What was registered before recording suspended it.
    private var suspendedSlots: [Slot: Registered] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        if let h = eventHandler { RemoveEventHandler(h) }
        for (_, r) in slots { UnregisterEventHotKey(r.ref) }
    }

    /// Unregisters every hotkey while a shortcut recorder is listening, and
    /// puts them back afterwards.
    ///
    /// Carbon hands a registered hotkey to its handler before the keystroke
    /// reaches the app, so without this the shortcut already set fires the
    /// action instead of being recorded — and can never be changed, because the
    /// recorder never sees the keys.
    func setRecordingSuspended(_ suspended: Bool) {
        if suspended {
            guard suspendedSlots.isEmpty else { return }
            for (_, r) in slots { UnregisterEventHotKey(r.ref) }
            suspendedSlots = slots
            slots = [:]
        } else {
            let restore = suspendedSlots
            suspendedSlots = [:]
            for (slot, r) in restore { register(r.cfg, slot: slot, handler: r.handler) }
        }
    }

    func register(_ cfg: HotkeyConfig, slot: Slot, handler: @escaping () -> Void) {
        // Remove any previous registration for this slot first.
        if let prev = slots.removeValue(forKey: slot) {
            UnregisterEventHotKey(prev.ref)
        }
        guard !cfg.isEmpty else { return }

        let modifiers = carbonModifiers(from: cfg.modifierFlags)
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x41534859),  // 'ASHY'
                                     id: slot.rawValue)
        let status = RegisterEventHotKey(UInt32(cfg.keyCode),
                                         modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr, let ref = hotKeyRef else {
            asLog("HotkeyManager: register failed status=\(status) slot=\(slot.rawValue)")
            return
        }
        slots[slot] = Registered(ref: ref, handler: handler, cfg: cfg)
        asLog("HotkeyManager: registered slot=\(slot.rawValue) keyCode=\(cfg.keyCode) mods=\(modifiers)")
    }

    // MARK: - Carbon plumbing

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(),
                            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) in
                                guard let event = event, let userData = userData else { return noErr }
                                let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                var hkID = EventHotKeyID()
                                GetEventParameter(event,
                                                  EventParamName(kEventParamDirectObject),
                                                  EventParamType(typeEventHotKeyID),
                                                  nil,
                                                  MemoryLayout<EventHotKeyID>.size,
                                                  nil,
                                                  &hkID)
                                if let slot = Slot(rawValue: hkID.id),
                                   let reg = me.slots[slot] {
                                    DispatchQueue.main.async { reg.handler() }
                                }
                                return noErr
                            },
                            1,
                            &spec,
                            context,
                            &eventHandler)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
}
