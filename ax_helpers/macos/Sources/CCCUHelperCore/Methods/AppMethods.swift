import AppKit
import Foundation

public func registerAppMethods(_ d: Dispatcher) {
    d.register("app.list") { _ in
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app -> JSONObject in
                var o: JSONObject = [
                    "pid": Int(app.processIdentifier),
                    "name": app.localizedName ?? "",
                    "frontmost": isFrontmost(app.processIdentifier),
                    "hidden": app.isHidden,
                ]
                if let b = app.bundleIdentifier { o["bundleId"] = b }
                return o
            }
        return ["apps": apps] as JSONObject
    }

    d.register("app.activate") { p in
        let app: NSRunningApplication
        if let pid = p.optInt("pid") {
            guard let a = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                throw HelperError.notFound("pid \(pid)")
            }
            app = a
        } else if let bundleId = p.optString("bundleId") {
            if let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                app = a
            } else {
                app = try launch(bundleId: bundleId)
            }
        } else {
            throw HelperError.invalidParams("pid or bundleId required")
        }
        activate(app.processIdentifier)
        return ["pid": Int(app.processIdentifier)] as JSONObject
    }
}

/// bundleId からアプリを起動し、起動完了まで同期的に待つ (最大 10 秒)。
private func launch(bundleId: String) throws -> NSRunningApplication {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
        throw HelperError.notFound("application \(bundleId)")
    }
    let sem = DispatchSemaphore(value: 0)
    var result: Result<NSRunningApplication, Error>?
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
        if let app = app { result = .success(app) } else { result = .failure(error ?? HelperError(.internalError, "launch failed")) }
        sem.signal()
    }
    // openApplication の completion はメインとは別キューで来るので、メインスレッドで待ってもデッドロックしない
    if sem.wait(timeout: .now() + 10) == .timedOut {
        throw HelperError(.timeout, "launching \(bundleId) timed out")
    }
    switch result! {
    case .success(let app):
        // finishedLaunching を短く待つ
        let deadline = Date().addingTimeInterval(5)
        while !app.isFinishedLaunching && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return app
    case .failure(let e):
        throw HelperError(.internalError, "launch failed: \(e)")
    }
}
