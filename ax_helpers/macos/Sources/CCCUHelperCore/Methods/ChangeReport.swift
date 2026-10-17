import AppKit
import Foundation

/// 操作後の変化の報告。操作の前後でページ (webarea、無ければウィンドウ) のツリーを取り、追加・削除された行を結果に添える。
/// 1 問ごとに「クリック → find → 確認」と往復していた分を 1 回で済ませるため。
/// 差分が大きすぎる (ページ遷移など) ときは新しいツリー全体を返し、変化が無ければその旨を返す。
public enum ChangeReport {
    public static let settleMax: TimeInterval = 1.2      // 変化が現れるまで待つ上限
    static let fullThresholdRatio = 0.75                 // 追加行が全体のこの割合を超えたら (ほぼ別ページ) 全体を返す

    /// 操作を囲む。mode: "none" (既定: 何もしない) | "diff" | "full"
    static func wrap(_ p: Params, anchor: AXElement?, pid: pid_t?, _ body: () throws -> JSONObject) throws -> JSONObject {
        let mode = p.optString("report") ?? "none"
        guard mode == "diff" || mode == "full", let root = reportRoot(anchor: anchor, pid: pid) else { return try body() }
        var opts = SnapshotOptions()
        opts.maxNodes = 3000
        if let t = p.optInt("textLimit") { opts.valueLimit = max(10, t) }
        let before = SnapshotBuilder.build(root: root, options: opts).text
        let beforeKey = normalize(before)
        var result = try body()

        // 変化が現れ、かつ安定するまで待つ (アニメーションやフィードバックの挿入が終わるまで)。待ち時間は呼び出し側が延ばせる
        // (単語カードのように数秒後に変わるステップ用)
        let wait = p.optInt("reportWaitMs").map { TimeInterval(max(200, min($0, 15000))) / 1000 } ?? settleMax
        let deadline = Date().addingTimeInterval(wait)
        spin(0.2)
        var after = SnapshotBuilder.build(root: root, options: opts)
        var last = normalize(after.text)
        var stable = 0
        while Date() < deadline {
            spin(0.12)
            after = SnapshotBuilder.build(root: root, options: opts)
            let key = normalize(after.text)
            if key == last { if key != beforeKey { stable += 1; if stable >= 1 { break } } }
            else { stable = 0 }
            last = key
        }
        let id = RefTable.shared.register(after.refs)
        var changes: JSONObject = ["snapshot": id, "refCount": after.refs.count]
        if normalize(after.text) == beforeKey {
            changes["changed"] = false
        } else {
            let (added, removed) = diff(before: before, after: after.text)
            let afterLines = after.text.split(separator: "\n").count
            // 差分が全体より長いか、ほぼ全部入れ替わったときだけ全体を返す (スクロールやフィードバック挿入では差分の方が短い)
            let tooBig = added.count + removed.count > afterLines || Double(added.count) > Double(max(afterLines, 1)) * fullThresholdRatio
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

    /// 行の多重集合の差 (順序は after / before の出現順)。比較は正規化した行で行う:
    /// ref 番号 (振り直される)、`[offscreen]` / `[focused]` / `[at x,y wxh]` (スクロールやフォーカス移動で変わるだけで内容の変化ではない) を除く
    static func diff(before: String, after: String) -> (added: [String], removed: [String]) {
        let b = before.split(separator: "\n").map(String.init)
        let a = after.split(separator: "\n").map(String.init)
        var counts: [String: Int] = [:]
        for l in b { counts[normalizeLine(l), default: 0] += 1 }
        var added: [String] = []
        for l in a {
            let k = normalizeLine(l)
            if let n = counts[k], n > 0 { counts[k] = n - 1 } else { added.append(l) }
        }
        var removed: [String] = []
        var acounts: [String: Int] = [:]
        for l in a { acounts[normalizeLine(l), default: 0] += 1 }
        for l in b {
            let k = normalizeLine(l)
            if let n = acounts[k], n > 0 { acounts[k] = n - 1 } else { removed.append(l) }
        }
        return (added, removed)
    }

    static let noise = try! NSRegularExpression(pattern: #" \[(ref=e\d+|offscreen|focused|at -?\d+,-?\d+ \d+x\d+)\]"#)
    static func normalizeLine(_ line: String) -> String {
        noise.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }
    static func normalize(_ text: String) -> String { text.split(separator: "\n").map { normalizeLine(String($0)) }.joined(separator: "\n") }
    static func stripRefs(_ line: String) -> String {
        line.replacingOccurrences(of: #" \[ref=e\d+\]"#, with: "", options: .regularExpression)
    }
}
