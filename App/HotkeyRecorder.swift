import AppKit
import SwiftUI
import Carbon.HIToolbox

/// A keyboard-shortcut value: a keyCode + a set of NSEvent modifier
/// flags. Persisted to UserDefaults as JSON. Empty = unset (no hotkey
/// registered).
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    /// Stored as the raw `NSEvent.ModifierFlags` bitfield. Translated
    /// to Carbon flags by `HotkeyManager` at registration time.
    var rawModifierFlags: UInt

    static let empty = HotkeyConfig(keyCode: 0, rawModifierFlags: 0)
    var isEmpty: Bool { keyCode == 0 && rawModifierFlags == 0 }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawModifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }
}

/// Persistence helper. Reads/writes a `HotkeyConfig` to a UserDefaults
/// key as JSON-encoded bytes.
enum HotkeyStore {
    static func read(_ key: String) -> HotkeyConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg  = try? JSONDecoder().decode(HotkeyConfig.self, from: data)
        else { return .empty }
        return cfg
    }
    static func write(_ key: String, _ cfg: HotkeyConfig) {
        if cfg.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// SwiftUI-friendly recorder field. Shows current shortcut as a glyph
/// string (e.g. "⌘⌥⇧R"), or "Click to set" when empty. Click enters
/// recording mode; the next keyDown captures the shortcut.
struct HotkeyRecorderView: NSViewRepresentable {

    let storageKey: String
    let onChange: (HotkeyConfig) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        HotkeyRecorderNSView(storageKey: storageKey, onChange: onChange)
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.refreshLabel()
    }
}

final class HotkeyRecorderNSView: NSView {

    private let storageKey: String
    private let onChange: (HotkeyConfig) -> Void
    private var label: NSTextField!
    private var clearButton: NSButton!
    private var monitor: Any?
    private var recording = false {
        didSet { refreshLabel() }
    }

    init(storageKey: String, onChange: @escaping (HotkeyConfig) -> Void) {
        self.storageKey = storageKey
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        addSubview(label)

        clearButton = NSButton(title: "✕", target: self, action: #selector(clearShortcut))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 11)
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -4),
        ])
        refreshLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if !recording { startRecording() }
    }

    private func startRecording() {
        recording = true
        // Local monitor so we capture keys destined for our window
        // (the settings window is key when the user clicks the field).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event: event)
            return nil  // swallow — don't propagate to text fields etc.
        }
    }

    private func handle(event: NSEvent) {
        guard recording else { return }
        // Ignore pure modifier presses; require a real keyCode.
        if event.type == .flagsChanged { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require at least one modifier — a bare letter is too easy
        // to trigger accidentally.
        guard !mods.intersection([.command, .option, .control, .shift]).isEmpty else { return }
        let cfg = HotkeyConfig(keyCode: UInt16(event.keyCode), rawModifierFlags: mods.rawValue)
        HotkeyStore.write(storageKey, cfg)
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        onChange(cfg)
    }

    @objc private func clearShortcut() {
        HotkeyStore.write(storageKey, .empty)
        onChange(.empty)
        refreshLabel()
    }

    func refreshLabel() {
        if recording {
            label.stringValue = "Press a shortcut…"
            label.textColor = .secondaryLabelColor
        } else {
            let cfg = HotkeyStore.read(storageKey)
            if cfg.isEmpty {
                label.stringValue = "Click to set"
                label.textColor = .secondaryLabelColor
            } else {
                label.stringValue = HotkeyFormatter.glyphs(for: cfg)
                label.textColor = .labelColor
            }
        }
    }
}

/// Formats a HotkeyConfig as the standard glyph string (⌘⌥⇧K).
enum HotkeyFormatter {
    static func glyphs(for cfg: HotkeyConfig) -> String {
        var s = ""
        let m = cfg.modifierFlags
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += KeyCodeNames.name(for: cfg.keyCode)
        return s
    }
}

/// Best-effort mapping from virtual key codes to display strings.
/// Covers the keys most people will pick for shortcuts; falls back
/// to "Key N" for anything obscure.
enum KeyCodeNames {
    static func name(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        default: return "Key \(keyCode)"
        }
    }
}
