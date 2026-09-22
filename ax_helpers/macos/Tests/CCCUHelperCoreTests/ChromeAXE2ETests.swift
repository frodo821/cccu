import AppKit
import XCTest
@testable import CCCUHelperCore

/// 普段使いの Chrome (デバッグポート無し) を AX ツリーで操作する E2E。
/// ユーザーの Chrome にタブを開いて閉じるので `CCCU_E2E_CHROME=1` のときだけ走る。
final class ChromeAXE2ETests: XCTestCase {
    private let d = makeDispatcher(shutdown: {})

    private func call(_ method: String, _ params: JSONObject = [:], file: StaticString = #file, line: UInt = #line) throws -> JSONObject {
        switch d.handle(Request(json: ["id": 1, "method": method, "params": params])!) {
        case .result(_, let v): return v as! JSONObject
        case .error(_, let e): XCTFail("\(method): \(e.kind) \(e.message)", file: file, line: line); throw e
        case .notification: fatalError()
        }
    }
    private func refs(_ snap: JSONObject, _ needle: String) -> [JSONObject] {
        (snap["text"] as! String).split(separator: "\n")
            .filter { $0.contains(needle) && $0.contains("[ref=") }
            .map { ["snapshot": snap["snapshot"]!, "ref": $0.components(separatedBy: "[ref=")[1].components(separatedBy: "]")[0]] }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CCCU_E2E_CHROME"] == "1", "set CCCU_E2E_CHROME=1 to run")
        try XCTSkipUnless(Trust.isTrusted, "Accessibility not trusted")
        try XCTSkipUnless(NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.google.Chrome" }, "Chrome not running")
    }

    func testNavigateAndClickInUsersChrome() throws {
        let pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.google.Chrome" }!.processIdentifier
        _ = try call("app.activate", ["pid": Int(pid)])
        _ = try call("input.key", ["key": "t", "modifiers": ["cmd"], "pid": Int(pid)])
        Thread.sleep(forTimeInterval: 0.6)
        defer { _ = try? call("input.key", ["key": "w", "modifiers": ["cmd"], "pid": Int(pid)]) }

        // アドレスバー (名前はシステム言語に依存するので role と属性で探す)
        var bar = refs(try call("ui.find", ["scope": ["pid": Int(pid)], "query": ["role": "textfield", "title": "アドレス"]]), "textfield")
        if bar.isEmpty { bar = refs(try call("ui.find", ["scope": ["pid": Int(pid)], "query": ["role": "textfield", "title": "Address"]]), "textfield") }
        let addr = try XCTUnwrap(bar.first)
        let typed = try call("input.type", ["ref": addr, "text": "https://www.iana.org/", "clear": true, "submit": true])
        XCTAssertEqual(typed["method"] as? String, "keys")   // submit は実打鍵
        _ = try call("ui.waitFor", ["scope": ["pid": Int(pid)], "condition": ["exists": ["role": "webarea", "title": "Internet Assigned Numbers Authority"]], "timeoutMs": 10000])

        // webarea 配下だけのスナップショットにブラウザ UI が混ざらない
        let web = try XCTUnwrap(refs(try call("ui.find", ["scope": ["pid": Int(pid)], "query": ["role": "webarea"]]), "- webarea").first)
        let sub = try call("ui.snapshot", ["scope": ["ref": web]])
        XCTAssertFalse((sub["text"] as! String).contains("toolbar"))
        XCTAssertTrue((sub["text"] as! String).contains("link \"Domain Names\""))

        // ウェブ内容のリンクは実クリックで遷移する
        let link = try XCTUnwrap(refs(sub, "link \"Domain Names\"").first)
        XCTAssertEqual(try call("ui.click", ["ref": link])["method"] as? String, "cg")
        _ = try call("ui.waitFor", ["scope": ["pid": Int(pid)], "condition": ["gone": ["role": "webarea", "title": "Internet Assigned Numbers Authority"]], "timeoutMs": 10000])
    }
}
