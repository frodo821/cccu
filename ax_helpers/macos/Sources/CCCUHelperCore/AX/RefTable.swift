import ApplicationServices
import Foundation

/// ref が指す要素の「ルートからの経路」。ブラウザが DOM を再描画すると AX ノードが入れ替わり、保持していた AXUIElement は
/// 1x1 の仮 frame を返す死んだノードになることがある。そのとき同じ経路 (子インデックスと role / 名前) で要素を引き直す
public struct RefPath {
    public let root: AXElement
    public let indices: [Int]      // ルートからの子インデックス
    public let role: String        // 正規化前の AX ロール
    public let title: String?      // 要素名 (照合用)

    /// 経路をたどって要素を引き直す。各段で role が一致する子を、記録したインデックスの前後 ±2 まで探す
    public func resolve() -> AXElement? {
        var cur = root
        for (depth, idx) in indices.enumerated() {
            let kids = cur.children
            guard !kids.isEmpty else { return nil }
            let last = depth == indices.count - 1
            func ok(_ k: AXElement) -> Bool { !last || (k.role == role && (title == nil || k.title == title || k.descriptionText == title)) }
            var next: AXElement? = nil
            for d in [0, -1, 1, -2, 2] {
                let i = idx + d
                if i >= 0, i < kids.count, ok(kids[i]) { next = kids[i]; break }
            }
            guard let n = next else { return nil }
            cur = n
        }
        return cur
    }
}

/// スナップショット id と ref → AXElement の対応表。直近 N スナップショットだけ保持する (PROTOCOL.md §7)。
public final class RefTable {
    public static let shared = RefTable()
    public var capacity = 200   // cu_find / cu_wait も 1 回ごとにスナップショットを作る。1 レッスン分 (150 回程度) は保持する

    private var counter = 0
    private var order: [String] = []
    private var tables: [String: [String: AXElement]] = [:]
    private var paths: [String: [String: RefPath]] = [:]

    public init() {}

    /// 新しいスナップショット id を発行し、表を登録する
    public func register(_ refs: [String: AXElement], paths refPaths: [String: RefPath] = [:]) -> String {
        counter += 1
        let id = "s\(counter)"
        tables[id] = refs
        paths[id] = refPaths
        order.append(id)
        while order.count > capacity {
            let old = order.removeFirst()
            tables.removeValue(forKey: old)
            paths.removeValue(forKey: old)
        }
        return id
    }

    public func resolve(snapshot: String, ref: String) throws -> AXElement {
        guard let table = tables[snapshot] else {
            throw HelperError(.staleRef, "snapshot \(snapshot) is no longer available (keep the latest \(capacity))")
        }
        guard let el = table[ref] else {
            throw HelperError(.notFound, "ref \(ref) not in snapshot \(snapshot)")
        }
        guard el.isAlive else {
            throw HelperError(.staleRef, "\(snapshot)/\(ref) no longer exists; take a new snapshot")
        }
        return el
    }

    public func path(snapshot: String, ref: String) -> RefPath? { paths[snapshot]?[ref] }

    public var liveSnapshots: [String] { order }
}
