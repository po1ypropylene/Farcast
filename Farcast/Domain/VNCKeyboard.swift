import Foundation

/// RFB uses X11 keysyms, rather than RDP's physical scan codes.
enum VNCKeyboard {
    static func keySym(scanCode: Int, extended: Bool) -> UInt32? {
        if extended { return extendedKeys[scanCode] }
        if (0x3B...0x44).contains(scanCode) { return UInt32(0xFFBE + scanCode - 0x3B) }
        if scanCode == 0x57 { return 0xFFC8 }
        if scanCode == 0x58 { return 0xFFC9 }
        return keys[scanCode]
    }
    /// AppKit characters keep shortcuts and function keys independent of the US
    /// scan-code map. JIS language keys do not necessarily carry characters.
    static func keySym(keyCode: UInt16, characters: String) -> UInt32? {
        if keyCode == 102 { return 0xFF30 }  // Eisu toggle.
        if keyCode == 104 { return 0xFF27 }  // Hiragana/Katakana.
        if keyCode == 71 { return 0xFF7F }  // Clear/Num Lock on extended keyboards.
        guard let scalar = characters.unicodeScalars.first else { return nil }
        if (0xF704...0xF726).contains(scalar.value) { return 0xFFBE + scalar.value - 0xF704 }
        if let key = functionKeys[scalar.value] { return key }
        if characters.unicodeScalars.count == 1, scalar.value >= 32, scalar.value != 127, scalar.value < 0xF700 {
            return scalar.value <= 255 ? scalar.value : 0x0100_0000 | scalar.value
        }
        return nil
    }
    private static let functionKeys: [UInt32: UInt32] = [
        0xF72E: 0xFF61,  // Print Screen.
        0xF72F: 0xFF14,  // Scroll Lock.
        0xF730: 0xFF13,  // Pause (E1 cannot be represented by the RDP E0 boolean).
        0xF732: 0xFF6B,  // Break.
        0xF731: 0xFF15,  // System request.
        0xF743: 0xFF65,  // Undo.
        0xF744: 0xFF66,  // Redo.
        0xF735: 0xFF67,  // Menu.
        0xF741: 0xFF60,  // Select.
        0xF742: 0xFF62,  // Execute.
        0xF746: 0xFF6A,  // Help.
        0xF745: 0xFF68,  // Find.
        0xF747: 0xFF7E,  // Mode switch.
    ]
    private static let extendedKeys: [Int: UInt32] = [
        0x1C: 0xFF8D, 0x1D: 0xFFE4, 0x38: 0xFFEA, 0x35: 0xFFAF,
        0x47: 0xFF50, 0x48: 0xFF52, 0x49: 0xFF55, 0x4B: 0xFF51,
        0x4D: 0xFF53, 0x4F: 0xFF57, 0x50: 0xFF54, 0x51: 0xFF56,
        0x52: 0xFF63, 0x53: 0xFFFF, 0x5B: 0xFFEB, 0x5C: 0xFFEC,
        0x37: 0xFF61, 0x5D: 0xFF67,
    ]
    private static let keys: [Int: UInt32] = {
        var result: [Int: UInt32] = [

            0x01: 0xFF1B, 0x0E: 0xFF08, 0x0F: 0xFF09, 0x1C: 0xFF0D,
            0x1D: 0xFFE3, 0x2A: 0xFFE1, 0x36: 0xFFE2, 0x38: 0xFFE9,
            0x3A: 0xFFE5, 0x37: 0xFFAA, 0x4A: 0xFFAD, 0x4E: 0xFFAB,
            0x47: 0xFFB7, 0x48: 0xFFB8, 0x49: 0xFFB9, 0x4B: 0xFFB4,
            0x4C: 0xFFB5, 0x4D: 0xFFB6, 0x4F: 0xFFB1, 0x50: 0xFFB2,
            0x51: 0xFFB3, 0x52: 0xFFB0, 0x53: 0xFFAE,
            0x45: 0xFF7F, 0x46: 0xFF14, 0x56: 0x003C,
        ]
        let rows: [(Int, String)] = [
            (0x02, "1234567890-="), (0x10, "qwertyuiop[]"),
            (0x1E, "asdfghjkl;'`"), (0x2B, "\\zxcvbnm,./"),
        ]
        result[0x39] = 32
        for (start, text) in rows {
            let keys = Array(text.unicodeScalars)
            for (offset, scalar) in keys.enumerated() { result[start + offset] = scalar.value }
        }
        return result
    }()
}
