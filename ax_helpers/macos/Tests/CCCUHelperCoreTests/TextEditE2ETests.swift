import XCTest
@testable import CCCUHelperCore

/// TextEdit を実際に操作する E2E。画面を奪うので `CCCU_E2E=1 swift test` のときだけ走る。
final class TextEditE2ETests: XCTestCase {
    private let d = makeDispatcher(shutdown: {})

    private func call(_ method: String, _ params: JSONObject = [:], file: StaticString = #file, line: UInt = #line) throws -> JSONObject {
        switch d.handle(Request(json: ["id": 1, "method": method, "params": params])!) {
        case .result(_, let v): return v as! JSONObject
        case .error(_, let e): XCTFail("\(method): \(e.kind) \(e.message)", file: file, line: line); throw e
        case .notification: fatalError()
        }
    }

    private func refOf(_ role: String, title: String? = nil, in snap: JSONObject) -> JSONObject? {
        let needle = title.map { "\(role) \"\($0)\"" } ?? role
        for l in (snap["text"] as! String).split(separator: "\n") where l.contains("- " + needle) && l.contains("[ref=") {
            let ref = l.components(separatedBy: "[ref=")[1].components(separatedBy: "]")[0]
            return ["snapshot": snap["snapshot"]!, "ref": ref]
        }
        return nil
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CCCU_E2E"] == "1", "set CCCU_E2E=1 to run")
        try XCTSkipUnless(Trust.isTrusted, "Accessibility not trusted")
    }

    func testTypeIntoNewDocumentAndDiscard() throws {
        let pid = try call("app.activate", ["bundleId": "com.apple.TextEdit"])["pid"] as! Int
        Thread.sleep(forTimeInterval: 0.5)

        // AXObserver: 新規ウィンドウ作成の通知を受け取る
        var events: [JSONObject] = []
        ObserverRegistry.shared.emit = { if case .notification(_, let params) = $0 { events.append(params) } }
        defer { ObserverRegistry.shared.emit = { Transport.send($0) } }
        let subId = try call("ui.observe", ["pid": pid, "notifications": ["AXWindowCreated", "AXFocusedWindowChanged"]])["subscription"] as! String

        _ = try call("input.key", ["key": "n", "modifiers": ["cmd"], "pid": pid])
        let until = Date().addingTimeInterval(3)
        while Date() < until && !events.contains(where: { $0["notification"] as? String == "AXWindowCreated" }) {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let names = Set(events.compactMap { $0["notification"] as? String })
        XCTAssertTrue(names.contains("AXWindowCreated") || names.contains("AXFocusedWindowChanged"), "events: \(events)")
        XCTAssertEqual(events.first?["subscription"] as? String, subId)
        XCTAssertEqual((events.first?["element"] as? JSONObject)?["role"] as? String, "window")
        _ = try call("ui.unobserve", ["subscription": subId])

        // 新規書類の textarea が出るまで待つ
        let found = try call("ui.waitFor", ["scope": ["pid": pid], "condition": ["exists": ["role": "textarea"]], "timeoutMs": 5000])
        let area = try XCTUnwrap(refOf("textarea", in: found))

        _ = try call("input.type", ["ref": area, "text": "Hello from cccu\n", "clear": true])   // AXValue 経路
        _ = try call("input.type", ["text": "typed"])                                           // CGEvent 経路
        let attrs = try call("ui.attributes", ["ref": area, "names": ["AXValue"]])["attributes"] as! JSONObject
        XCTAssertEqual(attrs["AXValue"] as? String, "Hello from cccu\ntyped")

        // 閉じる → 保存シート → 削除 (AXPress で)
        _ = try call("input.key", ["key": "w", "modifiers": ["cmd"], "pid": pid])
        let sheet = try call("ui.waitFor", ["scope": ["pid": pid], "condition": ["exists": ["role": "sheet"]], "timeoutMs": 5000])
        let del = try XCTUnwrap(refOf("button", title: "削除", in: sheet) ?? refOf("button", title: "Delete", in: sheet))
        let clicked = try call("ui.click", ["ref": del])
        XCTAssertEqual(clicked["method"] as? String, "ax")

        _ = try call("ui.waitFor", ["scope": ["pid": pid], "condition": ["gone": ["role": "sheet"]], "timeoutMs": 5000])
        // 古い ref は STALE_REF
        if case .error(_, let e) = d.handle(Request(json: ["id": 1, "method": "ui.attributes", "params": ["ref": del]])!) {
            XCTAssertEqual(e.kind, .staleRef)
        } else { XCTFail("expected STALE_REF") }
    }
}
