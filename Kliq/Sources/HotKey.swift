import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored in UserDefaults.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value (command, option, control, shift only).
    var modifiers: UInt
    /// The key's label, e.g. "K" or "Space".
    var key: String

    static let `default` = Shortcut(keyCode: UInt16(kVK_ANSI_K),
                                    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
                                    key: "K")

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// For example "⌃⌥K".
    var displayString: String {
        let flags = modifierFlags
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    fileprivate var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Builds a shortcut from a key press, or nil if it has no command,
    /// option or control modifier (plain keys would fire while typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: flags.rawValue, key: Self.label(for: event))
    }

    init(keyCode: UInt16, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func label(for event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Registers one system-wide hot key with Carbon's `RegisterEventHotKey`,
/// which needs no extra permission. Call from the main thread.
final class HotKey {
    static let shared = HotKey()

    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register(_ shortcut: Shortcut?) {
        unregister()
        guard let shortcut else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4B4C4951), id: 1) // "KLIQ"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.app.error("Couldn't register shortcut \(shortcut.displayString, privacy: .public): \(status)")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.onPress?() }
            return noErr
        }, 1, &type, nil, &handlerRef)
    }
}
