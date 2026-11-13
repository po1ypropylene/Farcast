import AppKit

/// Apple keypads type numbers without a Num Lock toggle. Identify physical keys:
/// AppKit also sets numericPad on the separate arrow keys.
enum NumericKeypad {
    private static let standardKeyCodes: [UInt16: UInt16] = [
        82: 29, 83: 18, 84: 19, 85: 20, 86: 21, 87: 23, 88: 22, 89: 26, 91: 28, 92: 25,
        65: 47, 95: 43, 67: 28, 69: 24, 75: 44, 78: 27, 81: 24, 76: 36,
    ]

    static func printableText(for event: NSEvent) -> String? {
        guard event.keyCode != 76, standardKeyCodes[event.keyCode] != nil,
            let text = event.characters, !text.isEmpty,
            text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 && $0.value != 127 })
        else { return nil }
        return text
    }

    /// Keep SwiftTerm's text, modifiers, repeat and enhanced-keyboard handling,
    /// while preventing application-keypad mode from turning digits into SS3 keys.
    static func standardEvent(for event: NSEvent) -> NSEvent {
        guard let keyCode = standardKeyCodes[event.keyCode] else { return event }
        let enter = event.keyCode == 76
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting([.numericPad, .function]),
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: enter ? "\r" : event.characters ?? "",
            charactersIgnoringModifiers: enter ? "\r" : event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: keyCode) ?? event
    }
}
