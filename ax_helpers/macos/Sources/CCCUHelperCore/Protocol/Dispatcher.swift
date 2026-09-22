import Foundation

public typealias Handler = (Params) throws -> Any

/// メソッド名 → ハンドラの表。`capabilities` はここから自動生成される。
public final class Dispatcher {
    public init() {}
    private var handlers: [String: Handler] = [:]

    public func register(_ method: String, _ handler: @escaping Handler) {
        handlers[method] = handler
    }

    public var capabilities: [String] { handlers.keys.sorted() }

    public func handle(_ request: Request) -> Response {
        guard let handler = handlers[request.method] else {
            return .error(id: request.id, error: HelperError(.methodNotFound, "unknown method: \(request.method)"))
        }
        do {
            let result = try handler(Params(raw: request.params))
            return .result(id: request.id, value: result)
        } catch let e as HelperError {
            return .error(id: request.id, error: e)
        } catch {
            return .error(id: request.id, error: HelperError(.internalError, "\(error)"))
        }
    }
}
