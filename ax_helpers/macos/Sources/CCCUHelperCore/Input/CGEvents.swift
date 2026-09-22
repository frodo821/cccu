import CoreGraphics
import Foundation

/// CGEvent によるキーボード・マウス入力。AX で操作できない場合の逃げ道。
public enum Input {
    static let source = CGEventSource(stateID: .hidSystemState)
    static let stepDelay: TimeInterval = 0.02

    /// `pid` は「そのアプリが受け取れる状態にしてから送る」という意味。前面化してから HID タップに流す。
    /// (postToPid はメニューショートカットや一部のキー処理に届かないため使わない)
    static func post(_ e: CGEvent?, pid: pid_t? = nil) {
        guard let e = e else { return }
        if let pid = pid { activate(pid) }
        e.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: stepDelay)
    }

    // MARK: キーボード

    public static func pressKey(_ key: String, modifiers: [String] = [], pid: pid_t? = nil) throws {
        guard let code = KeyCodes.code(for: key) else {
            throw HelperError.invalidParams("unknown key \(key)")
        }
        var flags = try KeyCodes.flags(modifiers)
        if key.count == 1, key != key.lowercased() { flags.insert(.maskShift) }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        post(down, pid: pid); post(up, pid: pid)
    }

    /// 任意の Unicode 文字列を打鍵として送る。改行は Return キーにする。
    public static func typeText(_ text: String, pid: pid_t? = nil) {
        for ch in text {
            if ch == "\n" { try? pressKey("Enter", pid: pid); continue }
            let utf16 = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            utf16.withUnsafeBufferPointer { buf in
                down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            post(down, pid: pid); post(up, pid: pid)
        }
    }

    // MARK: マウス

    static func buttonSpec(_ name: String?) throws -> (CGMouseButton, CGEventType, CGEventType, CGEventType) {
        switch name ?? "left" {
        case "left": return (.left, .leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case "right": return (.right, .rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: throw HelperError.invalidParams("button must be left or right")
        }
    }

    public static func move(to p: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    }

    public static func click(at p: CGPoint, button: String? = nil, count: Int = 1, modifiers: [String] = []) throws {
        let (btn, downT, upT, _) = try buttonSpec(button)
        let flags = try KeyCodes.flags(modifiers)
        move(to: p)
        for i in 1...max(count, 1) {
            let down = CGEvent(mouseEventSource: source, mouseType: downT, mouseCursorPosition: p, mouseButton: btn)
            let up = CGEvent(mouseEventSource: source, mouseType: upT, mouseCursorPosition: p, mouseButton: btn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down?.flags = flags; up?.flags = flags
            post(down); post(up)
        }
    }

    public static func mouse(action: String, at p: CGPoint, to: CGPoint?, button: String?) throws {
        let (btn, downT, upT, dragT) = try buttonSpec(button)
        switch action {
        case "move": move(to: p)
        case "down": move(to: p); post(CGEvent(mouseEventSource: source, mouseType: downT, mouseCursorPosition: p, mouseButton: btn))
        case "up": post(CGEvent(mouseEventSource: source, mouseType: upT, mouseCursorPosition: p, mouseButton: btn))
        case "drag":
            guard let to = to else { throw HelperError.invalidParams("drag requires 'to'") }
            move(to: p)
            post(CGEvent(mouseEventSource: source, mouseType: downT, mouseCursorPosition: p, mouseButton: btn))
            let steps = 12
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let q = CGPoint(x: p.x + (to.x - p.x) * t, y: p.y + (to.y - p.y) * t)
                post(CGEvent(mouseEventSource: source, mouseType: dragT, mouseCursorPosition: q, mouseButton: btn))
            }
            post(CGEvent(mouseEventSource: source, mouseType: upT, mouseCursorPosition: to, mouseButton: btn))
        default: throw HelperError.invalidParams("unknown mouse action \(action)")
        }
    }

    public static func scroll(at p: CGPoint, dx: Int, dy: Int) {
        move(to: p)
        // 正の dy = 下へスクロール。CGEvent は「上が正」なので符号を反転する
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0))
    }
}
