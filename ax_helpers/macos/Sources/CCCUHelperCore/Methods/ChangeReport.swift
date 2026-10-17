import AppKit
import Foundation

/// 操作後の変化の報告。操作の前後でページ (webarea、無ければウィンドウ) のツリーを取り、追加・削除された行を結果に添える。
/// 1 問ごとに「クリック → find → 確認」と往復していた分を 1 回で済ませるため。
/// 差分が大きすぎる (ページ遷移など) ときは新しいツリー全体を返し、変化が無ければその旨を返す。
public enum ChangeReport {
    public static let settleMax: TimeInterval = 1.2      // 変化が現れるまで待つ上限
    static let fullThresholdLines = 60                   // これより大きい差分は全体を返す
    static let fullThresholdRatio = 0.4

    /// 操作を囲む。mode: "none" (既定: 何もしない) | "diff" | "full"
    static func wrap(_ p: Params, anchor: AXElement?, pid: pid_t?, _ body: () throws -> JSONObject) throws -> JSONObject {
        let mode = p.optString("report") ?? "none"
        guard mode == "diff" || mode == "full", let root = reportRoot(anchor: anchor, pid: pid) else { return try body() }
        var opts = SnapshotOptions()
        opts.maxNodes = 3000
        if let t = p.optInt("textLimit") { opts.valueLimit = max(10, t) }
        let before = SnapshotBuilder.build(root: root, options: opts).text
        var result = try body()

        // 変化が現れ、かつ安定するまで待つ (アニメーションやフィードバックの挿入が終わるまで)
        let deadline = Date().addingTimeInterval(settleMax)
        spin(0.2)
        var after = SnapshotBuilder.build(root: root, options: opts)
        var last = after.text
        var stable = 0
        while Date() < deadline {
            spin(0.12)
            after = SnapshotBuilder.build(root: root, options: opts)
            if after.text == last { if after.text != before { stable += 1; if stable >= 1 { break } } }
            else { stable = 0 }
            last = after.text
        }
        let id = RefTable.shared.register(after.refs)
        var changes: JSONObject = ["snapshot": id, "refCount": after.refs.count]
        if after.text == before {
            changes["changed"] = false
        } else {
            let (added, removed) = diff(before: before, after: after.text)
            let afterLines = after.text.split(separator: "\n").count
            let tooBig = added.count + removed.count > fullThresholdLines || Double(added.count + removed.count) > Double(max(afterLines, 1)) * fullThresholdRatio
            changes["changed"] = true
            changes["added"] = added.count
            changes["removed"] = removed.count
            if mode == "full" || tooBig {
                changes["full"] = after.text
            } else {
                changes["addedLines"] = added
                changes["removedLines"] = removed.map { stripRefs($0) }
            }
        }
        result["changes"] = changes
        return result
    }

    /// 報告の対象: 要素の webarea 祖先 → 要素のウィンドウ → アプリの最前面 webarea → フォーカスウィンドウ
    static func reportRoot(anchor: AXElement?, pid: pid_t?) -> AXElement? {
        if let a = anchor {
            var cur: AXElement? = a
            for _ in 0..<40 {
                guard let c = cur else { break }
                if c.role == "AXWebArea" { return c }
                if c.role == kAXWindowRole { return c }
                cur = c.element(kAXParentAttribute)
            }
            if let w = a.window { return w }
        }
        if let pid = pid {
            let app = AXElement.application(pid: pid)
            return app.outermostWebArea() ?? app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)
        }
        return nil
    }

    /// 行の多重集合の差 (順序は after / before の出現順)。ref ラベルは比較から除く (番号が振り直されるため)
    static func diff(before: String, after: String) -> (added: [String], removed: [String]) {
        let b = before.split(separator: "\n").map(String.init)
        let a = after.split(separator: "\n").map(String.init)
        var counts: [String: Int] = [:]
        for l in b { counts[stripRefs(l), default: 0] += 1 }
        var added: [String] = []
        for l in a {
            let k = stripRefs(l)
            if let n = counts[k], n > 0 { counts[k] = n - 1 } else { added.append(l) }
        }
        var removed: [String] = []
        var acounts: [String: Int] = [:]
        for l in a { acounts[stripRefs(l), default: 0] += 1 }
        for l in b {
            let k = stripRefs(l)
            if let n = acounts[k], n > 0 { acounts[k] = n - 1 } else { removed.append(l) }
        }
        return (added, removed)
    }

    static func stripRefs(_ line: String) -> String {
        line.replacingOccurrences(of: #" \[ref=e\d+\]"#, with: "", options: .regularExpression)
    }
}
