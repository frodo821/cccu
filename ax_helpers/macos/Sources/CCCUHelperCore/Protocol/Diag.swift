import Foundation

/// 操作の診断ログ (`~/.cccu/helper.log`)。実クリックが「成功と報告したのに効かなかった」ケースを後から追えるように、
/// ref、frame の推移、ヒットテスト、押下座標、押下後のフォーカス状態を 1 行で残す。1 MB を超えたら .1 に回す
public enum Diag {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cccu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("helper.log")
    }()
    static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private static let lock = NSLock()

    public static func log(_ event: String, _ fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let body = fields.keys.sorted().map { "\($0)=\(fmt(fields[$0]!))" }.joined(separator: " ")
        let line = "\(formatter.string(from: Date())) \(event) \(body)\n"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.data(using: .utf8)!.write(to: url) }
    }

    static func fmt(_ v: Any) -> String {
        if let r = v as? CGRect { return "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))" }
        if let p = v as? CGPoint { return "\(Int(p.x)),\(Int(p.y))" }
        if let s = v as? String { return "\"" + s.replacingOccurrences(of: "\n", with: " ").prefix(40) + "\"" }
        return "\(v)"
    }
}
