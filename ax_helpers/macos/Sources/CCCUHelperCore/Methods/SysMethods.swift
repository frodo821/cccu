import Foundation
import ApplicationServices

public let protocolVersion = "1.0"
public let helperVersion = "0.1.0"

public enum Trust {
    public static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }
    public static func request() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    /// AX を触るメソッドの先頭で呼ぶ
    public static func require() throws {
        if !isTrusted { throw HelperError.notTrusted }
    }
}

public func registerSysMethods(_ d: Dispatcher, shutdown: @escaping () -> Void) {
    d.register("sys.hello") { _ in
        [
            "protocolVersion": protocolVersion,
            "helperVersion": helperVersion,
            "platform": "macos",
            "trusted": Trust.isTrusted,
            "capabilities": d.capabilities,
        ] as JSONObject
    }
    d.register("sys.requestTrust") { _ in
        ["trusted": Trust.request()] as JSONObject
    }
    d.register("sys.shutdown") { _ in
        DispatchQueue.main.async { shutdown() }
        return [:] as JSONObject
    }
}
