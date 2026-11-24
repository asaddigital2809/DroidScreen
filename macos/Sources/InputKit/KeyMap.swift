import CoreGraphics

/// Android KeyEvent codes → macOS virtual key codes (ANSI layout positions, Carbon kVK_*).
/// Keys not listed are typed by their Unicode character instead.
public enum KeyMap {
    public static let androidToMac: [Int: CGKeyCode] = {
        var map: [Int: CGKeyCode] = [:]
        // Letters: Android KEYCODE_A = 29 … KEYCODE_Z = 54.
        let letters: [CGKeyCode] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // A–M
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // N–Z
        ]
        for (i, code) in letters.enumerated() { map[29 + i] = code }
        // Digits: KEYCODE_0 = 7 … KEYCODE_9 = 16.
        let digits: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (i, code) in digits.enumerated() { map[7 + i] = code }
        // Function keys: KEYCODE_F1 = 131 … KEYCODE_F12 = 142.
        let functions: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in functions.enumerated() { map[131 + i] = code }
        let named: [Int: CGKeyCode] = [
            62: 0x31,  // SPACE
            66: 0x24,  // ENTER → Return
            160: 0x4C, // NUMPAD_ENTER
            61: 0x30,  // TAB
            67: 0x33,  // DEL (backspace) → Delete
            112: 0x75, // FORWARD_DEL
            111: 0x35, // ESCAPE
            19: 0x7E, 20: 0x7D, 21: 0x7B, 22: 0x7C, // DPAD up, down, left, right
            122: 0x73, 123: 0x77, // MOVE_HOME, MOVE_END
            92: 0x74, 93: 0x79,   // PAGE_UP, PAGE_DOWN
            69: 0x1B, 70: 0x18,   // MINUS, EQUALS
            71: 0x21, 72: 0x1E,   // LEFT_BRACKET, RIGHT_BRACKET
            73: 0x2A, 74: 0x29,   // BACKSLASH, SEMICOLON
            75: 0x27, 76: 0x2C,   // APOSTROPHE, SLASH
            55: 0x2B, 56: 0x2F,   // COMMA, PERIOD
            68: 0x32,             // GRAVE
        ]
        map.merge(named) { $1 }
        return map
    }()

    /// Android modifier key codes (shift, ctrl, alt, meta, caps lock, fn). They only change
    /// `metaState` on other keys and are not sent as separate key events.
    public static let modifierKeyCodes: Set<Int> = [59, 60, 113, 114, 57, 58, 117, 118, 115, 119]

    /// Android KeyEvent meta state → Quartz flags. Android META ↔ Command, ALT ↔ Option.
    public static func flags(androidMetaState meta: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if meta & 0x1 != 0 { flags.insert(.maskShift) }           // META_SHIFT_ON
        if meta & 0x2 != 0 { flags.insert(.maskAlternate) }       // META_ALT_ON
        if meta & 0x1000 != 0 { flags.insert(.maskControl) }      // META_CTRL_ON
        if meta & 0x10000 != 0 { flags.insert(.maskCommand) }     // META_META_ON
        if meta & 0x100000 != 0 { flags.insert(.maskAlphaShift) } // META_CAPS_LOCK_ON
        return flags
    }
}
