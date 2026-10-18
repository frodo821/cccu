import AppKit
import Foundation

/// 操作セッション: エージェントが「これから一連の操作をする」と宣言し、終わったら「終わった」と宣言する。
/// セッション中は対象アプリを前面に保ち (操作ごとの前面化と復帰をしない)、ユーザーの実入力を遮断する。
/// 終了時に元の最前面アプリへ戻す。閉じ込め事故を防ぐため、上限時間を過ぎるか、ユーザーが Escape を 3 連打すると終わる。
public enum Session {
    static var pid: pid_t?
    static var previous: pid_t?
    static var deadline: Date?
    static var blocking = false
    static var startedAt: Date?
    /// ユーザー (Escape 3 連打) や期限切れで終わった旨。次の応答に警告として付ける
    static var endedReason: String?

    public static var isActive: Bool { pid != nil && !expiredNow() }

    static func expiredNow() -> Bool {
        guard pid != nil, let d = deadline, Date() >= d else { return false }
        end(reason: "session expired after its maxSeconds; focus was returned to the previous app")
        return true
    }

    static func begin(pid p: pid_t, block: Bool, maxSeconds: TimeInterval, overlay: Bool = true) -> JSONObject {
        if pid != nil { _ = end(reason: nil) }
        previous = frontmostPid()
        pid = p; blocking = block; startedAt = Date(); deadline = Date().addingTimeInterval(maxSeconds); endedReason = nil
        activate(p)
        if block { UserActivity.beginBlocking() }
        // ユーザーへの表示: 操作中であること、入力が遮断されていること、残り時間、Escape 3 回で止められること
        let shown = overlay && SessionOverlay.enabled
        if shown { SessionOverlay.show() }
        return ["pid": Int(p), "previousPid": previous.map { Int($0) } as Any, "blocking": block, "maxSeconds": Int(maxSeconds), "overlay": shown]
    }

    /// セッションを終える。reason があれば次の応答に警告として付ける。戻り値は遮断した入力の数など
    @discardableResult
    static func end(reason: String?) -> JSONObject {
        guard let p = pid else { return ["active": false] }
        SessionOverlay.hide()
        let blocked = blocking ? UserActivity.endBlocking() : 0
        let dur = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if let prev = previous, prev != p, activationPolicy != .foreground {
            let now = frontmostPid()
            if now == nil || now == p { activate(prev) }   // ユーザーが自分で切り替えていたらそのまま
        }
        pid = nil; previous = nil; deadline = nil; blocking = false; startedAt = nil
        if let r = reason { endedReason = r }
        return ["active": false, "blockedInputs": blocked, "seconds": Int(dur)]
    }

    /// イベントタップのスレッドから (Escape 3 連打)。復帰はメインの run loop で行う
    static func endFromTap(reason: String) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { _ = end(reason: reason) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    static func takeWarning() -> String? { defer { endedReason = nil }; return endedReason }

    static var status: JSONObject {
        guard let p = pid, !expiredNow() else { return ["active": false] }
        return ["active": true, "pid": Int(p), "blocking": blocking, "remainingSeconds": Int(max(0, deadline?.timeIntervalSinceNow ?? 0))]
    }
}

public func registerSessionMethods(_ d: Dispatcher) {
    d.register("session.begin") { p in
        try Trust.require()
        let pid: pid_t
        if let n = p.optInt("pid") { pid = pid_t(n) }
        else if let b = p.optString("bundleId") {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { throw HelperError(.notFound, "app not running: \(b)") }
            pid = app.processIdentifier
        } else { throw HelperError.invalidParams("pid or bundleId required") }
        let block = p.optBool("blockInput") ?? true
        // 上限時間は宣言必須: エージェントが止まったときにユーザーが閉じ込められないように
        let max = TimeInterval(try p.int("maxSeconds"))
        guard max > 0, max <= 3600 else { throw HelperError.invalidParams("maxSeconds must be 1...3600") }
        return Session.begin(pid: pid, block: block, maxSeconds: max, overlay: p.optBool("overlay") ?? true)
    }
    d.register("session.extend") { p in
        guard Session.isActive else { throw HelperError(.notFound, "no active session") }
        let max = TimeInterval(try p.int("maxSeconds"))
        guard max > 0, max <= 3600 else { throw HelperError.invalidParams("maxSeconds must be 1...3600") }
        Session.deadline = Date().addingTimeInterval(max)
        return Session.status
    }
    d.register("session.end") { _ in Session.end(reason: nil) }
    d.register("session.status") { _ in Session.status }
}
