import Foundation

/// params からの型付き取り出し。欠落・型不一致は INVALID_PARAMS。
public struct Params {
    public let raw: JSONObject
    public init(raw: JSONObject) { self.raw = raw }

    public func string(_ key: String) throws -> String {
        guard let v = raw[key] as? String else { throw HelperError.invalidParams("\(key) (string) required") }
        return v
    }
    public func optString(_ key: String) -> String? { raw[key] as? String }

    public func int(_ key: String) throws -> Int {
        guard let v = intValue(raw[key]) else { throw HelperError.invalidParams("\(key) (int) required") }
        return v
    }
    public func optInt(_ key: String) -> Int? { intValue(raw[key]) }

    public func optBool(_ key: String) -> Bool? { raw[key] as? Bool }

    public func optObject(_ key: String) -> Params? {
        (raw[key] as? JSONObject).map(Params.init(raw:))
    }
    public func object(_ key: String) throws -> Params {
        guard let o = optObject(key) else { throw HelperError.invalidParams("\(key) (object) required") }
        return o
    }

    /// JSON 由来の数値を Int として解釈する。真偽値と非整数は拒否する。
    private func intValue(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }
}
