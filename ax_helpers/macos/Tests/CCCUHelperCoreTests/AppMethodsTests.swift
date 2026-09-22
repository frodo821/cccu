import XCTest
@testable import CCCUHelperCore

/// app.* は NSWorkspace を使うので実環境依存。壊れにくい性質だけを検証する。
final class AppMethodsTests: XCTestCase {
    private let d = makeDispatcher(shutdown: {})

    private func call(_ method: String, _ params: JSONObject = [:]) -> Response {
        d.handle(Request(json: ["id": 1, "method": method, "params": params])!)
    }

    func testAppListShapes() throws {
        guard case .result(_, let v) = call("app.list") else { return XCTFail("expected result") }
        let apps = (v as! JSONObject)["apps"] as! [JSONObject]
        XCTAssertFalse(apps.isEmpty)
        for a in apps {
            XCTAssertNotNil(a["pid"] as? Int)
            XCTAssertNotNil(a["name"] as? String)
            XCTAssertNotNil(a["frontmost"] as? Bool)
            XCTAssertNotNil(a["hidden"] as? Bool)
        }
        // 結果は JSON にシリアライズ可能でなければならない
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: v))
    }

    func testActivateRequiresPidOrBundleId() {
        guard case .error(_, let e) = call("app.activate") else { return XCTFail("expected error") }
        XCTAssertEqual(e.kind, .invalidParams)
    }

    func testActivateUnknownPidIsNotFound() {
        guard case .error(_, let e) = call("app.activate", ["pid": 1]) else { return XCTFail("expected error") }
        XCTAssertEqual(e.kind, .notFound)   // pid 1 (launchd) は NSRunningApplication にならない
    }

    func testActivateUnknownBundleIsNotFound() {
        guard case .error(_, let e) = call("app.activate", ["bundleId": "invalid.bundle.does.not.exist"]) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(e.kind, .notFound)
    }
}
