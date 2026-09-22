import AppKit
import ApplicationServices
import Foundation

// window number 取得用の非公開 API (Accessibility Inspector 等も使用)。失敗時は 0。
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 非 GUI プロセスでは NSRunningApplication.isActive が更新されないので、frontmostApplication で判定する
func isFrontmost(_ pid: pid_t) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}

/// アプリを前面にし、切り替わるまで短く待つ。
/// 非 GUI プロセスからの NSRunningApplication.activate は macOS 14 以降無視されるので、
/// AX の AXFrontmost 属性 → NSWorkspace.openApplication (再オープン = activate) の順に試す。
func activate(_ pid: pid_t) {
    if isFrontmost(pid) { return }
    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
    let ax = AXElement.application(pid: pid)
    _ = try? ax.set(kAXFrontmostAttribute, kCFBooleanTrue)
    if waitFrontmost(pid, timeout: 0.5) { return }
    if let url = app.bundleURL {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        _ = waitFrontmost(pid, timeout: 1.5)
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

extension AXElement {
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
        guard NSRunningApplication(processIdentifier: pid) != nil else { throw HelperError.notFound("pid \(pid)") }
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
        if role == nil && title == nil && value == nil { throw HelperError.invalidParams("query needs role, title or value") }
        func matches(_ s: String?, _ q: String) -> Bool {
            guard let s = s else { return false }
            return exact ? s == q : s.localizedCaseInsensitiveContains(q)
        }
        return { n in
            if let r = role, n.role != r { return false }
            if let t = title, !matches(n.title, t) { return false }
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
        return o
    }
}

func snapshotResult(_ out: SnapshotOutput) -> JSONObject {
    let id = RefTable.shared.register(out.refs)
    return ["snapshot": id, "text": out.text, "refCount": out.refs.count, "truncated": out.truncated]
}
