import AppKit
import ApplicationServices
import Foundation

// window number 取得用の非公開 API (Accessibility Inspector 等も使用)。失敗時は 0。
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 非 GUI プロセスでは NSRunningApplication.isActive が更新されないので、frontmostApplication で判定する
func isFrontmost(_ pid: pid_t) -> Bool {
    frontmostPid() == pid
}

/// 前面化のポリシー。
///  background (既定): AX で完結する操作は前面化しない。キーは AX メニュー / postToPid で対象プロセスへ直接送る。
///                     前面化が避けられない操作 (実マウスクリック等) は、終わったら元の最前面アプリへ戻す
///  foreground: 従来通り、操作のたびに対象アプリを前面にする (CCCU_ACTIVATION=foreground)
///  restore: 操作のたびに前面化するが、終わったら元の最前面アプリへ戻す (CCCU_ACTIVATION=restore)
public enum ActivationPolicy: String { case background, restore, foreground }
public var activationPolicy: ActivationPolicy =
    ActivationPolicy(rawValue: ProcessInfo.processInfo.environment["CCCU_ACTIVATION"] ?? "") ?? .background

/// 合成キー/スクロールイベントを対象プロセスへ直接送る (postToPid) か。AppKit のアプリでは背面のまま届くが、
/// Chrome などは受け付けず黙って無効になるので既定では使わない (CCCU_DIRECT_INPUT=1 で有効化)
public var directInput = ProcessInfo.processInfo.environment["CCCU_DIRECT_INPUT"] == "1"

/// 操作を実行する。foreground=true (呼び出しごとの指定) またはポリシーが background 以外なら前面化して行う
func act<T>(_ pid: pid_t, window: AXElement? = nil, foreground: Bool, _ body: () throws -> T) rethrows -> T {
    if foreground || activationPolicy != .background { return try withForeground(pid, window: window, body) }
    return try body()
}
/// 前面化して操作するか (メソッド名の表示や direct 判定に使う)
func wantsForeground(_ flag: Bool) -> Bool { flag || activationPolicy != .background }

/// run loop を回しながら待つ (この間にフォーカス変更などの通知が処理される)
func spin(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.main.run(mode: .default, before: min(until, Date().addingTimeInterval(0.02))) }
}

/// 前面化が必要な操作を実行する。background ポリシーでは、終わったら元の最前面アプリに戻す
func withForeground<T>(_ pid: pid_t, window: AXElement? = nil, _ body: () throws -> T) rethrows -> T {
    let previous = frontmostPid()
    activate(pid)
    if let w = window, !w.isMainWindow { try? w.perform(kAXRaiseAction) }
    defer {
        if activationPolicy != .foreground, let prev = previous, prev != pid {
            spin(0.1)   // 送ったイベントが対象アプリで処理されるのを待ってから戻す
            var attempts = 0
            for _ in 0..<4 {
                attempts += 1
                activate(prev)
                spin(0.08)
                if frontmostPid() == prev { break }   // 奪い返されていたらやり直す
            }
            if ProcessInfo.processInfo.environment["CCCU_DEBUG"] != nil {
                Transport.log("restore focus: previous=\(prev) target=\(pid) attempts=\(attempts) frontmost now=\(frontmostPid().map(String.init) ?? "nil")")
            }
        } else if ProcessInfo.processInfo.environment["CCCU_DEBUG"] != nil {
            Transport.log("no restore: previous=\(previous.map(String.init) ?? "nil") target=\(pid) policy=\(activationPolicy.rawValue)")
        }
    }
    return try body()
}

/// アクティブなアプリ (キーボードフォーカスの持ち主) の pid。
/// NSWorkspace の値はメインキュー経由の通知で更新される。リクエストを run loop のブロックとして処理し、
/// 待機中は run loop を回す (spin) ことで、処理の途中でも最新の値が読める。
/// (ウィンドウの重なり順は背面アプリの新規ウィンドウでも上に来るので判定に使えない。
///  AX システム全体要素の AXFocusedApplication はこのプロセスからは取得できない)
func frontmostPid() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

/// アプリを前面にし、切り替わるまで短く待つ。
/// 非 GUI プロセスからの NSRunningApplication.activate は macOS 14 以降無視されるので、
/// AX の AXFrontmost 属性 → NSWorkspace.openApplication (再オープン = activate) の順に試す。
func activate(_ pid: pid_t) {
    if isFrontmost(pid) { return }
    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
    let debug = ProcessInfo.processInfo.environment["CCCU_DEBUG"] != nil
    let t0 = Date()
    // 1. AX の AXFrontmost (効くアプリでは数十 ms)
    let ax = AXElement.application(pid: pid)
    _ = try? ax.set(kAXFrontmostAttribute, kCFBooleanTrue)
    if waitFrontmost(pid, timeout: 0.12) {
        if debug { Transport.log("activate \(pid): AXFrontmost took \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        return
    }
    // 2. AXFrontmost が効かないアプリ (TextEdit など) は LaunchServices で再オープンする。
    //    NSRunningApplication.activate は GUI を持たないプロセスからは無視される
    if let url = app.bundleURL {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        let ok = waitFrontmost(pid, timeout: 2.0)
        if debug { Transport.log("activate \(pid): fallback openApplication -> \(ok) after \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
    }
}

/// NSWorkspace の状態はメインの run loop で更新されるので、待つ間は run loop を回す
func waitFrontmost(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if isFrontmost(pid) { return true }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
    }
    return isFrontmost(pid)
}

/// 画面座標にある要素 (システム全体のヒットテスト)
func elementAt(_ p: CGPoint) -> AXElement? {
    var out: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &out) == .success, let e = out else { return nil }
    return AXElement(e)
}

extension AXElement {
    /// この要素と other が同じか、どちらかがもう一方の祖先か (ヒットテストは内側のテキストやアイコンを返すことがある)
    func isRelated(to other: AXElement, maxDepth: Int = 12) -> Bool {
        if CFEqual(raw, other.raw) { return true }
        var cur: AXElement? = other
        for _ in 0..<maxDepth { guard let c = cur?.element(kAXParentAttribute) else { break }; if CFEqual(c.raw, raw) { return true }; cur = c }
        cur = self
        for _ in 0..<maxDepth { guard let c = cur?.element(kAXParentAttribute) else { break }; if CFEqual(c.raw, other.raw) { return true }; cur = c }
        // ブラウザ UI (タブ、ツールバー) ではヒットテストが親子関係の辿れない無名の group を返すことがある。
        // 相手の frame がこの要素の frame に収まっていれば、自分の一部 (装飾や内側のコンテナ) とみなす。モーダルのスクリムは要素より大きいので誤判定しない
        if let f = frame, let of = other.frame, f.width > 2, f.height > 2, of.width > 0, of.height > 0,
           f.insetBy(dx: -2, dy: -2).contains(of) { return true }
        return false
    }
    /// 最寄りのダイアログ/シート (モーダル) の要素
    var enclosingDialog: AXElement? {
        var cur: AXElement? = self
        for _ in 0..<20 {
            guard let c = cur else { return nil }
            if let r = c.role, ["AXSheet", "AXDialog", "AXAlertDialog"].contains(r) || (c.subrole.map { ["AXDialog", "AXSystemDialog"].contains($0) } ?? false) { return c }
            if c.role == kAXWindowRole { return nil }
            cur = c.element(kAXParentAttribute)
        }
        return nil
    }

    /// 実クリックや実打鍵の前に、要素を可視領域に入れる。ウェブ内容などは AXScrollToVisible を持つ。
    /// 戻り値はスクロール後の中心座標
    func ensureVisibleCenter() -> CGPoint? {
        guard var f = frame else { return nil }
        // Chrome の AX の frame はレイアウト変更 (フィードバックの挿入、スクロール) より遅れて更新される。短く待って読み直し、動いていなければ使う
        for _ in 0..<6 {
            spin(0.05)
            guard let now = frame else { break }
            if now.origin == f.origin && now.size == f.size { break }
            f = now
        }
        let visible = window?.frame?.insetBy(dx: 2, dy: 2)
        // スクロールコンテナの表示範囲外にある要素は、Chrome が 1x1 の仮の frame で報告する。それも不可視として扱う
        func usable(_ r: CGRect) -> Bool {
            r.width > 2 && r.height > 2 && (visible.map { $0.contains(CGPoint(x: r.midX, y: r.midY)) } ?? true)
        }
        if !usable(f), actionNames().contains("AXScrollToVisible") {
            try? perform("AXScrollToVisible")
            // スムーズスクロールが終わるまで待つ (frame が実寸になり、位置が安定するまで)
            // 連続する 2 回の読み取りで位置が変わらなくなるまで待つ (1 回だけだとスムーズスクロールの途中で止まることがある)
            var last = f
            var stable = 0
            for _ in 0..<20 {
                spin(0.08)
                guard let now = frame else { break }
                if usable(now), now.origin == last.origin { stable += 1; if stable >= 2 { f = now; break } }
                else { stable = 0 }
                last = now; f = now
            }
        }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// スクロールの基点として使える座標。要素自身が可視領域外 (1x1 の仮 frame やウィンドウ外) なら、frame が使える祖先 (スクロール領域など) の中心を使う。
    /// 戻り値は (座標, 代わりに使った祖先のロール or nil)
    func scrollAnchor() -> (CGPoint, String?)? {
        let visible = window?.frame?.insetBy(dx: 2, dy: 2)
        func usable(_ r: CGRect) -> Bool { r.width > 2 && r.height > 2 && (visible.map { $0.contains(CGPoint(x: r.midX, y: r.midY)) } ?? true) }
        if let f = frame, usable(f) { return (CGPoint(x: f.midX, y: f.midY), nil) }
        var cur: AXElement? = element(kAXParentAttribute)
        for _ in 0..<30 {
            guard let c = cur else { break }
            if let f = c.frame, usable(f) { return (CGPoint(x: f.midX, y: f.midY), c.role.map { SnapshotBuilder.normalizeRole($0, subrole: c.subrole) } ?? "unknown") }
            if c.role == kAXWindowRole { break }
            cur = c.element(kAXParentAttribute)
        }
        return center.map { ($0, nil) }
    }
    var isMainWindow: Bool { bool(kAXMainAttribute) ?? false }
    var windowNumber: Int {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(raw, &id) == .success ? Int(id) : 0
    }
    var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }
    /// ブラウザのウェブ内容 (AXWebArea の子孫) か。Chrome は AXPress を受け付けても実行しないことがあるので、実クリックに切り替える判定に使う
    var isWebContent: Bool {
        var cur: AXElement? = self
        for _ in 0..<40 {
            guard let c = cur else { return false }
            if c.role == "AXWebArea" { return true }
            if c.role == kAXWindowRole || c.role == kAXApplicationRole { return false }
            cur = c.element(kAXParentAttribute)
        }
        return false
    }
    /// 自分を含む最寄りのウィンドウ要素
    var window: AXElement? {
        if role == kAXWindowRole { return self }
        return element(kAXWindowAttribute)
    }
}

extension Params {
    func ref(_ key: String = "ref") throws -> AXElement {
        let r = try object(key)
        return try RefTable.shared.resolve(snapshot: try r.string("snapshot"), ref: try r.string("ref"))
    }
    func optRef(_ key: String = "ref") throws -> AXElement? {
        raw[key] == nil ? nil : try ref(key)
    }
    func point(_ key: String) throws -> CGPoint {
        let p = try object(key)
        guard let x = p.raw["x"] as? NSNumber, let y = p.raw["y"] as? NSNumber else {
            throw HelperError.invalidParams("\(key) needs x and y")
        }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }
    func optPoint(_ key: String) throws -> CGPoint? { raw[key] == nil ? nil : try point(key) }
    func modifiers() -> [String] { (raw["modifiers"] as? [String]) ?? [] }

    /// Scope → 走査ルート要素
    func scopeRoot(_ key: String = "scope") throws -> AXElement {
        let s = try object(key)
        if s.raw["ref"] != nil { return try s.ref("ref") }
        let pid = pid_t(try s.int("pid"))
        // NSRunningApplication の照会は前面化の直後などに一時的に失敗することがあるので、プロセスの存在は kill(0) で見る
        guard kill(pid, 0) == 0 || errno == EPERM else { throw HelperError.notFound("pid \(pid)") }
        let app = AXElement.application(pid: pid)
        if let wn = s.optInt("windowNumber") {
            guard let w = app.elements(kAXWindowsAttribute).first(where: { $0.windowNumber == wn }) else {
                throw HelperError.notFound("window \(wn) in pid \(pid)")
            }
            return w
        }
        return app
    }

    func findQuery(_ key: String = "query") throws -> (Node) -> Bool {
        let q = try object(key)
        let role = q.optString("role")?.lowercased()
        let title = q.optString("title")
        let value = q.optString("value")
        let exact = q.optBool("exact") ?? false
        let enabled = q.optBool("enabled")
        if role == nil && title == nil && value == nil && enabled == nil { throw HelperError.invalidParams("query needs role, title, value or enabled") }
        func matches(_ s: String?, _ q: String) -> Bool {
            guard let s = s else { return false }
            return exact ? s == q : s.localizedCaseInsensitiveContains(q)
        }
        return { n in
            if let e = enabled, n.states.contains("disabled") == e { return false }
            if let r = role, n.role != r { return false }
            // title は要素名、または (role 指定なしなら) 分割された子テキストを連結したブロック文字列にも一致させる
            if let t = title, !matches(n.title, t), !(role == nil && !n.children.isEmpty && matches(n.blockText, t)) { return false }
            if let v = value {
                let sv: String? = (n.value as? String) ?? n.value.map { "\($0)" }
                if !matches(sv, v) { return false }
            }
            return true
        }
    }

    func snapshotOptions() -> SnapshotOptions {
        var o = SnapshotOptions()
        if let d = optInt("maxDepth") { o.maxDepth = d }
        if let n = optInt("maxNodes") { o.maxNodes = n }
        if let i = optBool("interestingOnly") { o.interestingOnly = i }
        if let t = optInt("textLimit") { o.valueLimit = max(10, t) }   // 長文を読むときは上げる (既定 80)
        return o
    }
}

func snapshotResult(_ out: SnapshotOutput) -> JSONObject {
    let id = RefTable.shared.register(out.refs)
    var r: JSONObject = ["snapshot": id, "text": out.text, "refCount": out.refs.count, "truncated": out.truncated, "matches": out.matches]
    if let by = out.truncatedBy { r["truncatedBy"] = by }
    return r
}
