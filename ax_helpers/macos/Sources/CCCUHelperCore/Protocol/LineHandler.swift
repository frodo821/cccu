import Foundation

/// 1 行の NDJSON を処理して応答 (通知リクエストなら nil) を返す。main.swift とテストの両方から使う。
public func handleLine(_ line: String, dispatcher: Dispatcher) -> Response? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
        return .error(id: nil, error: HelperError(.parseError, "invalid JSON"))
    }
    guard let req = Request(json: obj) else {
        return .error(id: obj["id"], error: HelperError(.invalidParams, "missing method"))
    }
    let response = dispatcher.handle(req)
    return req.id == nil ? nil : response
}

/// 標準構成のディスパッチャ (全メソッド登録済み)
public func makeDispatcher(shutdown: @escaping () -> Void) -> Dispatcher {
    let d = Dispatcher()
    registerSysMethods(d, shutdown: shutdown)
    registerAppMethods(d)
    return d
}
