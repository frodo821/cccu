import AppKit
import Foundation

/// 操作後の変化の報告。操作の前後でページ (webarea、無ければウィンドウ) のツリーを取り、追加・削除された行を結果に添える。
/// 1 問ごとに「クリック → find → 確認」と往復していた分を 1 回で済ませるため。
/// 差分が大きすぎる (ページ遷移など) ときは新しいツリー全体を返し、変化が無ければその旨を返す。
public enum ChangeReport {
    public static let settleMax: TimeInterval = 1.2      // 変化が現れるまで待つ上限
    static let fullThresholdRatio = 0.5                  // 追加行が全体のこの割合を超えたら (別のステップ) 全体を返す

    /// 操作要素 (ref 付き) や状態フラグを含む行があるか。無ければテキストの再分割などの雑音とみなす
    static func substantive(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("[ref=") || $0.contains("[disabled]") || $0.contains("[selected]") || $0.contains("[checked]") || $0.contains("[expanded]") }
    }

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
            if key == last, key != beforeKey {
                // 変化が止まった。ただし静的テキストの並びが変わっただけ (スクロールで画面外のテキストが再分割される) なら、
                // 本命の変化 (操作要素や状態) が後から来ることがあるので期限まで待ち続ける
                stable += 1
                if stable >= 1 {
                    let (a, r) = diff(before: before, after: after.text)
                    if substantive(a + r) { break }
                }
            } else { stable = 0 }
            last = key
        }
        let id = RefTable.shared.register(after.refs, paths: after.paths)
        var changes: JSONObject = ["snapshot": id, "refCount": after.refs.count, "waitMs": Int(wait * 1000)]
        if normalize(after.text) == beforeKey {
            changes["changed"] = false
        } else {
            let (added, removed) = dropTextRechunking(diff(before: before, after: after.text))
            let afterLines = after.text.split(separator: "\n").count
            // 差分が全体より長いか、半分以上が新しい行 (ステップ遷移) なら全体を返す。フィードバックの挿入やスクロールでは差分の方が短い
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

    /// 行の差分 (順序は after / before の出現順)。比較は正規化した行で行う:
    /// ref 番号 (振り直される)、`[offscreen]` / `[focused]` / `[at x,y wxh]` (スクロールやフォーカス移動で変わるだけで内容の変化ではない) を除く。
    /// 位置を考慮する LCS で対応付ける (多重集合の差だと、前のステップと同じ文言の選択肢が離れた行と対応してしまい、新しい ref が差分から抜けた)。
    /// 大きすぎるときは多重集合の差に落とす
    static func diff(before: String, after: String) -> (added: [String], removed: [String]) {
        let b = before.split(separator: "\n").map(String.init)
        let a = after.split(separator: "\n").map(String.init)
        let bk = b.map(normalizeLine), ak = a.map(normalizeLine)
        if b.count * a.count > 4_000_000 { return multisetDiff(a: a, ak: ak, b: b, bk: bk) }
        // LCS 表 (後ろから)
        let n = b.count, m = a.count
        var dp = [Int](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { dp[i * (m + 1) + j] }
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i * (m + 1) + j] = bk[i] == ak[j] ? at(i + 1, j + 1) + 1 : max(at(i + 1, j), at(i, j + 1))
                }
            }
        }
        var added: [String] = [], removed: [String] = []
        var i = 0, j = 0
        while i < n && j < m {
            if bk[i] == ak[j] { i += 1; j += 1 }
            else if at(i + 1, j) > at(i, j + 1) { removed.append(b[i]); i += 1 }
            else if at(i + 1, j) < at(i, j + 1) { added.append(a[j]); j += 1 }
            else { removed.append(b[i]); added.append(a[j]); i += 1; j += 1 }   // 同点なら同じ位置の行が変わったとみなす

        }
        while i < n { removed.append(b[i]); i += 1 }
        while j < m { added.append(a[j]); j += 1 }
        return (added, removed)
    }

    static func multisetDiff(a: [String], ak: [String], b: [String], bk: [String]) -> (added: [String], removed: [String]) {
        var counts: [String: Int] = [:]
        for k in bk { counts[k, default: 0] += 1 }
        var added: [String] = []
        for (l, k) in zip(a, ak) { if let n = counts[k], n > 0 { counts[k] = n - 1 } else { added.append(l) } }
        var acounts: [String: Int] = [:]
        for k in ak { acounts[k, default: 0] += 1 }
        var removed: [String] = []
        for (l, k) in zip(b, bk) { if let n = acounts[k], n > 0 { acounts[k] = n - 1 } else { removed.append(l) } }
        return (added, removed)
    }

    /// スクロールで画面外の静的テキストが結合・分割されただけの行を落とす: 追加された text の内容が、削除された text 群を
    /// 連結したものに含まれる (またはその逆) なら両方とも雑音
    static func dropTextRechunking(_ d: (added: [String], removed: [String])) -> (added: [String], removed: [String]) {
        func textContent(_ l: String) -> String? {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- text \""), let end = t.lastIndex(of: "\"") , t.count > 9 else { return nil }
            return String(t[t.index(t.startIndex, offsetBy: 8)..<end]).replacingOccurrences(of: " ", with: "")
        }
        let addedTexts = d.added.compactMap(textContent), removedTexts = d.removed.compactMap(textContent)
        guard !addedTexts.isEmpty, !removedTexts.isEmpty else { return d }
        let addedJoined = addedTexts.joined(), removedJoined = removedTexts.joined()
        let added = d.added.filter { l in textContent(l).map { !removedJoined.contains($0) } ?? true }
        let removed = d.removed.filter { l in textContent(l).map { !addedJoined.contains($0) } ?? true }
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
