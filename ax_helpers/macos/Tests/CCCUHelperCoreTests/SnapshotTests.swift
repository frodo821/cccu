import AppKit
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

    func testScreenCaptureReturnsPNGOrPermissionError() {
        let d = makeDispatcher(shutdown: {})
        switch d.handle(Request(json: ["id": 1, "method": "screen.capture", "params": ["maxWidth": 200]])!) {
        case .result(_, let v):
            let o = v as! JSONObject
            let data = Data(base64Encoded: o["pngBase64"] as! String)!
            XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])   // PNG シグネチャ
            XCTAssertLessThanOrEqual(o["width"] as! Int, 200)
        case .error(_, let e):
            XCTAssertEqual(e.kind, .notTrusted)   // Screen Recording 未許可の環境
            XCTAssertEqual(e.data["permission"] as? String, "screenRecording")
        case .notification: XCTFail()
        }
    }

    func testDownscaleKeepsAspect() {
        let ctx = CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let small = downscale(img, maxWidth: 100)
        XCTAssertEqual(small.width, 100); XCTAssertEqual(small.height, 25)
        XCTAssertEqual(downscale(img, maxWidth: 1000).width, 400)
        XCTAssertNotNil(pngData(small))
    }

    func testObserveErrors() {
        let d = makeDispatcher(shutdown: {})
        if case .error(_, let e) = d.handle(Request(json: ["id": 1, "method": "ui.observe", "params": ["pid": 1]])!) {
            XCTAssertEqual(e.kind, .notFound)
        } else { XCTFail("expected NOT_FOUND for pid 1") }
        if case .error(_, let e) = d.handle(Request(json: ["id": 1, "method": "ui.unobserve", "params": ["subscription": "o99"]])!) {
            XCTAssertEqual(e.kind, .notFound)
        } else { XCTFail("expected NOT_FOUND") }
    }

    func testObserveFinderRegistersAndUnregisters() throws {
        try XCTSkipUnless(Trust.isTrusted)
        guard let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else { throw XCTSkip("no Finder") }
        let d = makeDispatcher(shutdown: {})
        guard case .result(_, let v) = d.handle(Request(json: ["id": 1, "method": "ui.observe", "params": ["pid": Int(finder.processIdentifier)]])!) else { return XCTFail() }
        let o = v as! JSONObject
        let id = o["subscription"] as! String
        XCTAssertFalse((o["notifications"] as! [String]).isEmpty)
        XCTAssertTrue(ObserverRegistry.shared.active.contains(id))
        guard case .result = d.handle(Request(json: ["id": 2, "method": "ui.unobserve", "params": ["subscription": id]])!) else { return XCTFail() }
        XCTAssertFalse(ObserverRegistry.shared.active.contains(id))
    }

    func testCapabilitiesCoverProtocolV1() {
        let d = makeDispatcher(shutdown: {})
        let expected = [
            "sys.hello", "sys.requestTrust", "sys.shutdown", "app.list", "app.activate", "window.list", "window.raise",
            "ui.snapshot", "ui.find", "ui.attributes", "ui.setAttribute", "ui.performAction", "ui.click", "ui.focus", "ui.waitFor",
            "input.type", "input.key", "input.scroll", "input.mouse", "screen.capture", "ui.observe", "ui.unobserve",
        ]
        for m in expected { XCTAssertTrue(d.capabilities.contains(m), "missing \(m)") }
    }
}
