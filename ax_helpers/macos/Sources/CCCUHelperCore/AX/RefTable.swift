import Foundation

/// スナップショット id と ref → AXElement の対応表。直近 N スナップショットだけ保持する (PROTOCOL.md §7)。
public final class RefTable {
    public static let shared = RefTable()
    public var capacity = 8

    private var counter = 0
    private var order: [String] = []
    private var tables: [String: [String: AXElement]] = [:]

    public init() {}

    /// 新しいスナップショット id を発行し、表を登録する
    public func register(_ refs: [String: AXElement]) -> String {
        counter += 1
        let id = "s\(counter)"
        tables[id] = refs
        order.append(id)
        while order.count > capacity {
            tables.removeValue(forKey: order.removeFirst())
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

    public var liveSnapshots: [String] { order }
}
