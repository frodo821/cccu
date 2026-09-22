import Foundation

/// PROTOCOL.md §4 のエラー。code と kind は 1:1。
public struct HelperError: Error {
    public enum Kind: String {
        case notTrusted = "NOT_TRUSTED"
        case staleRef = "STALE_REF"
        case notFound = "NOT_FOUND"
        case unsupported = "UNSUPPORTED"
        case axError = "AX_ERROR"
        case timeout = "TIMEOUT"
        case invalidParams = "INVALID_PARAMS"
        case methodNotFound = "METHOD_NOT_FOUND"
        case parseError = "PARSE_ERROR"
        case internalError = "INTERNAL"

        public var code: Int {
            switch self {
            case .notTrusted: return -32001
            case .staleRef: return -32002
            case .notFound: return -32003
            case .unsupported: return -32004
            case .axError: return -32005
            case .timeout: return -32006
            case .invalidParams: return -32602
            case .methodNotFound: return -32601
            case .parseError: return -32700
            case .internalError: return -32603
            }
        }
    }

    public let kind: Kind
    public let message: String
    public var data: JSONObject = [:]

    public init(_ kind: Kind, _ message: String, data: JSONObject = [:]) {
        self.kind = kind
        self.message = message
        self.data = data
    }

    public var json: JSONObject {
        var d = data
        d["kind"] = kind.rawValue
        return ["code": kind.code, "message": message, "data": d]
    }

    // よく使うコンストラクタ
    public static func invalidParams(_ what: String) -> HelperError {
        HelperError(.invalidParams, "invalid params: \(what)")
    }
    public static func notFound(_ what: String) -> HelperError {
        HelperError(.notFound, "\(what) not found")
    }
    public static var notTrusted: HelperError {
        HelperError(.notTrusted, "Accessibility not trusted",
                    data: ["hint": "System Settings > Privacy & Security > Accessibility: allow \"cccu-helper\" (no terminal restart needed)"])
    }
}
