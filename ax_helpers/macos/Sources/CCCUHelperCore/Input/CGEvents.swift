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

    public static var currentLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// 目標へ移動する。human モードではフィッツの法則に基づく軌跡を 120 Hz で送る
    public static func move(to p: CGPoint, pid: pid_t? = nil, targetWidth: CGFloat = 16, mode: PointerMode = pointerMode) {
        let direct = pid != nil
        if mode == .warp || direct {
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left), pid: pid, direct: direct)
            return
        }
        let from = currentLocation
        let dist = hypot(p.x - from.x, p.y - from.y)
        guard dist > 0.5 else { return }
        var rng = SystemRandomNumberGenerator()
        let duration = Fitts.duration(distance: dist, targetWidth: targetWidth)
        let start = Date()
        for (pt, t) in Fitts.path(from: from, to: p, duration: duration, rng: &rng) {
            let wait = t - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: Double.random(in: 0.03...0.07, using: &rng))   // 押す前の静止
    }

    /// 操作後にカーソルを元の位置へ戻す (ユーザーのカーソルを奪ったままにしない)。瞬間移動でよい
    public static func restorePointer(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// pid を渡すと postToPid で対象プロセスへ直接送る (カーソルを動かさず、前面化もしない)。
    /// size を渡すと着地点に小さな散らばりを入れ、フィッツの法則の目標幅として使う
    public static func click(at p: CGPoint, size: CGSize? = nil, button: String? = nil, count: Int = 1, modifiers: [String] = [], pid: pid_t? = nil, mode: PointerMode = pointerMode) throws {
        let (btn, downT, upT, _) = try buttonSpec(button)
        let flags = try KeyCodes.flags(modifiers)
        var rng = SystemRandomNumberGenerator()
        let origin = currentLocation
        let human = pid == nil && mode == .human
        let target = human ? Fitts.landing(center: p, size: size, rng: &rng) : p
        if pid == nil { move(to: target, targetWidth: min(size?.width ?? 16, size?.height ?? 16), mode: mode) }
        for i in 1...max(count, 1) {
            let down = CGEvent(mouseEventSource: source, mouseType: downT, mouseCursorPosition: target, mouseButton: btn)
            let up = CGEvent(mouseEventSource: source, mouseType: upT, mouseCursorPosition: target, mouseButton: btn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down?.flags = flags; up?.flags = flags
            post(down, pid: pid, direct: pid != nil)
            if human { Thread.sleep(forTimeInterval: Double.random(in: 0.04...0.09, using: &rng)) }   // 押下時間
            post(up, pid: pid, direct: pid != nil)
        }
        if human {
            Thread.sleep(forTimeInterval: 0.05)
            restorePointer(to: origin)
            if ProcessInfo.processInfo.environment["CCCU_DEBUG"] != nil {
                Transport.log("pointer: origin=\(origin) target=\(target) now=\(currentLocation)")
            }
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
            Thread.sleep(forTimeInterval: 0.08)
            var rng = SystemRandomNumberGenerator()
            let duration = max(Fitts.duration(distance: hypot(to.x - p.x, to.y - p.y), targetWidth: 16), 0.25)
            let start = Date()
            for (q, t) in Fitts.path(from: p, to: to, duration: duration, rng: &rng) {
                let wait = t - Date().timeIntervalSince(start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                CGEvent(mouseEventSource: source, mouseType: dragT, mouseCursorPosition: q, mouseButton: btn)?.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.06)
            post(CGEvent(mouseEventSource: source, mouseType: upT, mouseCursorPosition: to, mouseButton: btn))
        default: throw HelperError.invalidParams("unknown mouse action \(action)")
        }
    }

    /// スクロール。human モードでは減速する一連の pixel 差分にトラックパッド風の phase を付けて送る
    public static func scroll(at p: CGPoint, dx: Int, dy: Int, pid: pid_t? = nil, mode: PointerMode = pointerMode) {
        let direct = pid != nil
        let origin = currentLocation
        if !direct { move(to: p, mode: mode) }
        // 正の dy = 下へスクロール。CGEvent は「上が正」なので符号を反転する
        if mode == .warp || direct {
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
            e?.location = p
            post(e, pid: pid, direct: direct)
            return
        }
        let ys = Fitts.scrollSteps(total: -dy), xs = Fitts.scrollSteps(total: -dx)
        let n = max(ys.count, xs.count)
        for i in 0..<n {
            let y = i < ys.count ? ys[i] : 0, x = i < xs.count ? xs[i] : 0
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0)
            e?.location = p
            e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)                                    // トラックパッド風
            e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : (i == n - 1 ? 4 : 2))    // began / changed / ended
            e?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        Thread.sleep(forTimeInterval: 0.05)
        restorePointer(to: origin)
    }
}
