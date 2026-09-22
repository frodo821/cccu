import XCTest
@testable import CCCUHelperCore

/// AX に触れない純粋関数のテスト。
final class SnapshotTests: XCTestCase {
    func testNormalizeRoleStripsPrefixAndLowercases() {
        XCTAssertEqual(SnapshotBuilder.normalizeRole("AXButton", subrole: nil), "button")
        XCTAssertEqual(SnapshotBuilder.normalizeRole("AXStaticText", subrole: nil), "text")
        XCTAssertEqual(SnapshotBuilder.normalizeRole("AXTextField", subrole: "AXSearchField"), "searchfield")
        XCTAssertEqual(SnapshotBuilder.normalizeRole("AXButton", subrole: "AXCloseButton"), "closebutton")
        XCTAssertEqual(SnapshotBuilder.normalizeRole("AXGroup", subrole: "AXUnknown"), "group")   // 無意味なサブロールは無視
    }

    func testQuoteTruncatesAndEscapes() {
        XCTAssertEqual(SnapshotBuilder.quote("a\"b\nc", limit: 80), "\"a\\\"b⏎c\"")
        XCTAssertEqual(SnapshotBuilder.quote(String(repeating: "x", count: 100), limit: 5), "\"xxxxx…\"")
    }

    func testKeyCodes() {
        XCTAssertEqual(KeyCodes.code(for: "Enter"), 36)
        XCTAssertEqual(KeyCodes.code(for: "a"), 0)
        XCTAssertEqual(KeyCodes.code(for: "A"), 0)
        XCTAssertEqual(KeyCodes.code(for: " "), 49)
        XCTAssertNil(KeyCodes.code(for: "Nope"))
        XCTAssertNil(KeyCodes.code(for: "あ"))
    }

    func testModifierFlags() throws {
        let f = try KeyCodes.flags(["cmd", "shift"])
        XCTAssertTrue(f.contains(.maskCommand) && f.contains(.maskShift))
        XCTAssertThrowsError(try KeyCodes.flags(["super"]))
    }

    func testRefTableEvictsOldSnapshots() throws {
        let t = RefTable()
        t.capacity = 2
        let el = AXElement.systemWide
        let s1 = t.register(["e1": el])
        let s2 = t.register(["e1": el])
        let s3 = t.register(["e1": el])
        XCTAssertEqual([s1, s2, s3], ["s1", "s2", "s3"])
        XCTAssertEqual(t.liveSnapshots, ["s2", "s3"])
        XCTAssertThrowsError(try t.resolve(snapshot: "s1", ref: "e1")) { XCTAssertEqual(($0 as? HelperError)?.kind, .staleRef) }
        XCTAssertThrowsError(try t.resolve(snapshot: "s3", ref: "e9")) { XCTAssertEqual(($0 as? HelperError)?.kind, .notFound) }
        XCTAssertNoThrow(try t.resolve(snapshot: "s3", ref: "e1"))
    }

    func testAXJSONRoundtripForGeometry() throws {
        let rect = try AXJSON.toCF(["x": 1, "y": 2, "w": 3, "h": 4] as JSONObject)
        XCTAssertEqual(AXJSON.fromCF(rect) as? [String: CGFloat], ["x": 1, "y": 2, "w": 3, "h": 4])
        let point = try AXJSON.toCF(["x": 5, "y": 6] as JSONObject)
        XCTAssertEqual(AXJSON.fromCF(point) as? [String: CGFloat], ["x": 5, "y": 6])
        XCTAssertEqual(AXJSON.fromCF(try AXJSON.toCF("s")) as? String, "s")
        XCTAssertEqual(AXJSON.fromCF(try AXJSON.toCF(true)) as? Bool, true)
        XCTAssertThrowsError(try AXJSON.toCF([1, 2]))
    }

    func testFindQueryRequiresSomeCriterion() {
        XCTAssertThrowsError(try Params(raw: ["query": [:] as JSONObject]).findQuery())
        XCTAssertNoThrow(try Params(raw: ["query": ["role": "button"] as JSONObject]).findQuery())
    }

    func testCapabilitiesCoverProtocolV1() {
        let d = makeDispatcher(shutdown: {})
        let expected = [
            "sys.hello", "sys.requestTrust", "sys.shutdown", "app.list", "app.activate", "window.list", "window.raise",
            "ui.snapshot", "ui.find", "ui.attributes", "ui.setAttribute", "ui.performAction", "ui.click", "ui.focus", "ui.waitFor",
            "input.type", "input.key", "input.scroll", "input.mouse",
        ]
        for m in expected { XCTAssertTrue(d.capabilities.contains(m), "missing \(m)") }
    }
}
