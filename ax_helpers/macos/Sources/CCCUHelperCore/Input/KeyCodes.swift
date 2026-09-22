import Carbon.HIToolbox
import CoreGraphics

/// W3C KeyboardEvent.key 名 → macOS 仮想キーコード (US 配列)。
public enum KeyCodes {
    static let special: [String: CGKeyCode] = [
        "Enter": CGKeyCode(kVK_Return), "Return": CGKeyCode(kVK_Return), "Tab": CGKeyCode(kVK_Tab),
        "Escape": CGKeyCode(kVK_Escape), "Backspace": CGKeyCode(kVK_Delete), "Delete": CGKeyCode(kVK_ForwardDelete),
        " ": CGKeyCode(kVK_Space), "Space": CGKeyCode(kVK_Space),
        "ArrowUp": CGKeyCode(kVK_UpArrow), "ArrowDown": CGKeyCode(kVK_DownArrow),
        "ArrowLeft": CGKeyCode(kVK_LeftArrow), "ArrowRight": CGKeyCode(kVK_RightArrow),
        "Home": CGKeyCode(kVK_Home), "End": CGKeyCode(kVK_End), "PageUp": CGKeyCode(kVK_PageUp), "PageDown": CGKeyCode(kVK_PageDown),
        "F1": CGKeyCode(kVK_F1), "F2": CGKeyCode(kVK_F2), "F3": CGKeyCode(kVK_F3), "F4": CGKeyCode(kVK_F4),
        "F5": CGKeyCode(kVK_F5), "F6": CGKeyCode(kVK_F6), "F7": CGKeyCode(kVK_F7), "F8": CGKeyCode(kVK_F8),
        "F9": CGKeyCode(kVK_F9), "F10": CGKeyCode(kVK_F10), "F11": CGKeyCode(kVK_F11), "F12": CGKeyCode(kVK_F12),
        "CapsLock": CGKeyCode(kVK_CapsLock),
    ]
    static let ascii: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// 名前からキーコードを引く。大文字 1 文字は小文字扱い (shift は呼び出し側で付ける)。
    public static func code(for key: String) -> CGKeyCode? {
        if let c = special[key] { return c }
        if key.count == 1, let ch = key.lowercased().first { return ascii[ch] }
        return nil
    }

    public static func flags(_ modifiers: [String]) throws -> CGEventFlags {
        var f = CGEventFlags()
        for m in modifiers {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt": f.insert(.maskAlternate)
            case "ctrl": f.insert(.maskControl)
            case "fn": f.insert(.maskSecondaryFn)
            default: throw HelperError.invalidParams("unknown modifier \(m)")
            }
        }
        return f
    }
}
