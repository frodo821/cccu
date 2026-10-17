import CoreGraphics
import Foundation

/// ユーザーの実入力 (キーボード・マウス) との競合対策。
///
/// エージェントの操作とユーザーの操作が重なると、前面化した一瞬にユーザーの打鍵が対象アプリへ入ったり、
/// ポインタの綱引きで別の場所を押したりする。そこで合成入力を伴う操作の間だけ、ユーザーの入力を遮断する:
///  - 合成イベントは `.combinedSessionState` のソースで送り、ハードウェア入力 (`.hidSystemState`) と区別する
///  - 操作中はセッションのイベントタップでハードウェア由来のイベントを捨てる (キー・マウス・ホイール)
///  - 始める前にボタンや修飾キーが押されたままなら、離されるまで (最大 `maxWait`) 待つ。押下中に遮断すると離す側のイベントだけが消える
///  - 遮断した入力があれば結果に警告を付け、エージェントは結果を確かめ直す
/// CCCU_USER_GUARD=block (既定) | wait (遮断せず静止を待つだけ) | off
public enum UserActivity {
    public enum Mode: String { case block, wait, off }
    public static var mode: Mode = Mode(rawValue: ProcessInfo.processInfo.environment["CCCU_USER_GUARD"] ?? "") ?? .block
    /// wait モード: ユーザー入力がこの秒数以上止まってから合成入力を始める
    public static var minIdle: TimeInterval = 0.4
    /// 静まるのを待つ上限。超えたら BUSY
    public static var maxWait: TimeInterval = 8

    static let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                       .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .otherMouseDown]

    /// 最後のハードウェア入力からの経過秒
    public static func idleSeconds() -> TimeInterval {
        types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// 何かのマウスボタンや修飾キーが押されたままか
    static func inputHeld() -> Bool {
        let buttons = (0..<3).contains { CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: UInt32($0))!) }
        let mods = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return buttons || !mods.isEmpty
    }

    // MARK: 遮断

    private static let lock = NSLock()
    private static var blocking = false
    private static var blockedCount = 0
    private static var tap: CFMachPort?
    static var escapes: [Date] = []
    private static var tapThread: Thread?

    /// 遮断用のイベントタップを専用スレッドで立てる (メインスレッドは操作中 sleep するので、そこでは捌けない)
    private static func ensureTap() {
        lock.lock(); defer { lock.unlock() }
        if tap != nil { return }
        let mask: CGEventMask = types.reduce(0) { $0 | (1 << $1.rawValue) } | (1 << CGEventType.otherMouseUp.rawValue) | (1 << CGEventType.otherMouseDragged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, _ in
                                               if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                                                   if let t = UserActivity.tap { CGEvent.tapEnable(tap: t, enable: true) }
                                                   return Unmanaged.passUnretained(event)
                                               }
                                               // 合成イベント (セッション状態のソース) は通し、ハードウェア由来 (HID 状態) だけを捨てる
                                               let hid = event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
                                               UserActivity.lock.lock(); let drop = UserActivity.blocking && hid; if drop { UserActivity.blockedCount += 1 }; UserActivity.lock.unlock()
                                               // 逃げ道: 遮断中にユーザーが Escape を 1.5 秒以内に 3 回押したら、セッションを終えて遮断を解く
                                               if drop, type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                                                   let now = Date()
                                                   UserActivity.escapes = UserActivity.escapes.filter { now.timeIntervalSince($0) < 1.5 } + [now]
                                                   if UserActivity.escapes.count >= 3 {
                                                       UserActivity.escapes = []
                                                       Session.endFromTap(reason: "the user pressed Escape three times: the session was ended and input unblocked")
                                                   }
                                               }
                                               return drop ? nil : Unmanaged.passUnretained(event)
                                           }, userInfo: nil) else {
            Transport.log("user guard: could not create event tap (needs Accessibility); falling back to wait mode")
            mode = .wait
            return
        }
        tap = port
        let thread = Thread {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "cccu.user-guard"
        thread.start()
        tapThread = thread
    }

    /// セッション (session.begin) の間ずっと遮断する
    static func beginBlocking() {
        ensureTap()
        lock.lock(); blocking = true; blockedCount = 0; lock.unlock()
    }
    /// 遮断を解き、捨てたイベント数を返す
    @discardableResult
    static func endBlocking() -> Int {
        lock.lock(); blocking = false; let n = blockedCount; blockedCount = 0; lock.unlock()
        return n
    }

    /// 合成入力を伴う操作を囲む。block: 操作中のユーザー入力を捨てる。wait: 静止を待つだけ。
    /// セッション中は既に前面・遮断済みなのでそのまま実行する
    public static func guarded<T>(_ body: () throws -> T) throws -> T {
        if Session.isActive { return try body() }
        switch mode {
        case .off:
            return try body()
        case .wait:
            try waitUntil(minIdle: minIdle)
            let start = Date()
            let r = try body()
            if idleSeconds() < Date().timeIntervalSince(start) { note("user input (keyboard/mouse) overlapped this action; verify the result") }
            return r
        case .block:
            ensureTap()
            if mode != .block { return try guarded(body) }   // タップが作れなかった
            try waitUntil(minIdle: 0.05)   // 押下中・打鍵の途中なら離されるまで待つ
            lock.lock(); blocking = true; blockedCount = 0; lock.unlock()
            defer {
                lock.lock(); blocking = false; let n = blockedCount; lock.unlock()
                if n > 0 { note("blocked \(n) user input event(s) (keyboard/mouse) during this action; the user may have been interrupted") }
            }
            return try body()
        }
    }

    /// ユーザー入力が止まる (離される) まで待つ。待ちきれなければ BUSY
    static func waitUntil(minIdle: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(maxWait)
        while inputHeld() || idleSeconds() < minIdle {
            if Date() >= deadline {
                throw HelperError(.busy, "the user is using the keyboard or mouse; wait and retry", data: ["idleMs": Int(idleSeconds() * 1000)])
            }
            spin(0.05)
        }
    }

    // MARK: 結果への警告

    private static var warning: String?
    static func note(_ w: String) { warning = w }
    /// 結果に付ける警告。あれば返してクリアする (Dispatcher が呼ぶ)
    static func takeWarning() -> String? { defer { warning = nil }; return warning }
}
