import CoreGraphics
import Foundation

/// CGEvent によるキーボード・マウス入力。AX で操作できない場合の逃げ道。
public enum Input {
    static let source = CGEventSource(stateID: .hidSystemState)
    static let stepDelay: TimeInterval = 0.02

    /// イベントの送り方:
    ///  direct=true かつ pid あり → postToPid で対象プロセスへ直接送る (前面化しない)
    ///  それ以外 → HID タップに流す (最前面のアプリが受け取る。呼び出し側が withForeground で前面化しておく)
    static func post(_ e: CGEvent?, pid: pid_t? = nil, direct: Bool = false) {
        guard let e = e else { return }
        if direct, let pid = pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
        Thread.sleep(forTimeInterval: stepDelay)
    }

    // MARK: キーボード

    public static func pressKey(_ key: String, modifiers: [String] = [], pid: pid_t? = nil, direct: Bool = false) throws {
        guard let code = KeyCodes.code(for: key) else {
            throw HelperError.invalidParams("unknown key \(key)")
        }
        var flags = try KeyCodes.flags(modifiers)
        if key.count == 1, key != key.lowercased() { flags.insert(.maskShift) }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        post(down, pid: pid, direct: direct); post(up, pid: pid, direct: direct)
    }

    /// 任意の Unicode 文字列を打鍵として送る。改行は Return キーにする。
    public static func typeText(_ text: String, pid: pid_t? = nil, direct: Bool = false) {
        for ch in text {
            if ch == "\n" { try? pressKey("Enter", pid: pid, direct: direct); continue }
            let utf16 = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            utf16.withUnsafeBufferPointer { buf in
                down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            post(down, pid: pid, direct: direct); post(up, pid: pid, direct: direct)
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

    public static func move(to p: CGPoint, pid: pid_t? = nil) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left), pid: pid, direct: pid != nil)
    }

    /// pid を渡すと postToPid で対象プロセスへ直接送る (カーソルを動かさず、前面化もしない)
    public static func click(at p: CGPoint, button: String? = nil, count: Int = 1, modifiers: [String] = [], pid: pid_t? = nil) throws {
        let (btn, downT, upT, _) = try buttonSpec(button)
        let flags = try KeyCodes.flags(modifiers)
        if pid == nil { move(to: p) }
        for i in 1...max(count, 1) {
            let down = CGEvent(mouseEventSource: source, mouseType: downT, mouseCursorPosition: p, mouseButton: btn)
            let up = CGEvent(mouseEventSource: source, mouseType: upT, mouseCursorPosition: p, mouseButton: btn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down?.flags = flags; up?.flags = flags
            post(down, pid: pid, direct: pid != nil); post(up, pid: pid, direct: pid != nil)
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

    public static func scroll(at p: CGPoint, dx: Int, dy: Int, pid: pid_t? = nil) {
        if pid == nil { move(to: p) }
        // 正の dy = 下へスクロール。CGEvent は「上が正」なので符号を反転する
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
        e?.location = p
        post(e, pid: pid, direct: pid != nil)
    }
}
