import Foundation

/// JSON-RPC 2.0 の最小限の型。ペイロードは JSONSerialization の Any で扱う。
public typealias JSONObject = [String: Any]

public struct Request {
    public let id: Any?          // Int / String / nil (通知)
    public let method: String
    public let params: JSONObject

    public init?(json: JSONObject) {
        guard let method = json["method"] as? String else { return nil }
        self.method = method
        self.id = json["id"]
        self.params = json["params"] as? JSONObject ?? [:]
    }
}

public enum Response {
    case result(id: Any?, value: Any)
    case error(id: Any?, error: HelperError)
    case notification(method: String, params: JSONObject)

    public var json: JSONObject {
        switch self {
        case .result(let id, let value):
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
        case .error(let id, let error):
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error.json]
        case .notification(let method, let params):
            return ["jsonrpc": "2.0", "method": method, "params": params]
        }
    }
}

/// stdout に 1 行 1 メッセージで書き出す。stdout 以外にプロトコルを流さない。
public enum Transport {
    private static let stdout = FileHandle.standardOutput

    public static func send(_ response: Response) {
        do {
            var data = try JSONSerialization.data(withJSONObject: response.json, options: [.sortedKeys])
            data.append(0x0A)
            stdout.write(data)
        } catch {
            log("failed to serialize response: \(error)")
        }
    }

    public static func log(_ message: String) {
        FileHandle.standardError.write(("[cccu-helper] " + message + "\n").data(using: .utf8)!)
    }
}
