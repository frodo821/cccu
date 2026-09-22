import XCTest
@testable import CCCUHelperCore

/// JSON-RPC 層 (Request / Response / HelperError / Params / Dispatcher / handleLine) の単体テスト。
/// AX API には触れないので Accessibility 権限なしで動く。
final class ProtocolTests: XCTestCase {

    private func dispatcher() -> Dispatcher {
        let d = Dispatcher()
        d.register("echo") { p in ["got": p.raw] as JSONObject }
        d.register("needInt") { p in ["n": try p.int("n")] as JSONObject }
        d.register("boom") { _ in throw HelperError(.notFound, "thing") }
        d.register("crash") { _ in throw NSError(domain: "x", code: 1) }
        return d
    }

    private func roundtrip(_ line: String, _ d: Dispatcher) -> JSONObject? {
        guard let r = handleLine(line, dispatcher: d) else { return nil }
        // Transport と同じ経路でシリアライズできることも確認する
        let data = try! JSONSerialization.data(withJSONObject: r.json)
        return try! JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    // MARK: Request parsing

    func testRequestParsesIdMethodParams() {
        let r = Request(json: ["jsonrpc": "2.0", "id": 7, "method": "m", "params": ["a": 1]])
        XCTAssertEqual(r?.id as? Int, 7)
        XCTAssertEqual(r?.method, "m")
        XCTAssertEqual(r?.params["a"] as? Int, 1)
    }

    func testRequestWithoutMethodIsNil() {
        XCTAssertNil(Request(json: ["id": 1]))
    }

    func testRequestParamsDefaultsToEmpty() {
        XCTAssertEqual(Request(json: ["method": "m"])?.params.count, 0)
    }

    // MARK: handleLine

    func testEmptyLineIsIgnored() {
        XCTAssertNil(handleLine("   \n", dispatcher: dispatcher()))
    }

    func testNotificationProducesNoResponse() {
        XCTAssertNil(handleLine(#"{"jsonrpc":"2.0","method":"echo","params":{}}"#, dispatcher: dispatcher()))
    }

    func testInvalidJSONIsParseError() {
        let r = roundtrip("{not json", dispatcher())!
        let err = r["error"] as! JSONObject
        XCTAssertEqual(err["code"] as? Int, -32700)
        XCTAssertEqual((err["data"] as! JSONObject)["kind"] as? String, "PARSE_ERROR")
        XCTAssertTrue(r["id"] is NSNull)
    }

    func testMissingMethodKeepsId() {
        let r = roundtrip(#"{"id":3}"#, dispatcher())!
        XCTAssertEqual(r["id"] as? Int, 3)
        XCTAssertEqual((r["error"] as! JSONObject)["code"] as? Int, -32602)
    }

    func testUnknownMethod() {
        let r = roundtrip(#"{"id":1,"method":"nope"}"#, dispatcher())!
        let err = r["error"] as! JSONObject
        XCTAssertEqual(err["code"] as? Int, -32601)
        XCTAssertEqual((err["data"] as! JSONObject)["kind"] as? String, "METHOD_NOT_FOUND")
    }

    func testSuccessResultEchoesParams() {
        let r = roundtrip(#"{"id":"abc","method":"echo","params":{"x":"y"}}"#, dispatcher())!
        XCTAssertEqual(r["id"] as? String, "abc")
        XCTAssertEqual(r["jsonrpc"] as? String, "2.0")
        let got = (r["result"] as! JSONObject)["got"] as! JSONObject
        XCTAssertEqual(got["x"] as? String, "y")
    }

    func testHelperErrorCarriesKindAndData() {
        let r = roundtrip(#"{"id":1,"method":"boom"}"#, dispatcher())!
        let err = r["error"] as! JSONObject
        XCTAssertEqual(err["code"] as? Int, -32003)
        XCTAssertEqual(err["message"] as? String, "thing")
        XCTAssertEqual((err["data"] as! JSONObject)["kind"] as? String, "NOT_FOUND")
    }

    func testForeignErrorBecomesInternal() {
        let r = roundtrip(#"{"id":1,"method":"crash"}"#, dispatcher())!
        let err = r["error"] as! JSONObject
        XCTAssertEqual(err["code"] as? Int, -32603)
        XCTAssertEqual((err["data"] as! JSONObject)["kind"] as? String, "INTERNAL")
    }

    // MARK: Params

    func testParamsIntAcceptsIntegralDouble() throws {
        XCTAssertEqual(try Params(raw: ["n": 5.0]).int("n"), 5)
        XCTAssertEqual(try Params(raw: ["n": 5]).int("n"), 5)
    }

    func testParamsIntRejectsFractionAndString() {
        XCTAssertThrowsError(try Params(raw: ["n": 5.5]).int("n")) { e in
            XCTAssertEqual((e as? HelperError)?.kind, .invalidParams)
        }
        XCTAssertThrowsError(try Params(raw: ["n": "5"]).int("n"))
        XCTAssertThrowsError(try Params(raw: ["n": true]).int("n"))
        XCTAssertThrowsError(try Params(raw: [:]).int("n"))
    }

    func testParamsInvalidSurfacesAsInvalidParamsError() {
        let r = roundtrip(#"{"id":1,"method":"needInt","params":{"n":"x"}}"#, dispatcher())!
        XCTAssertEqual((r["error"] as! JSONObject)["code"] as? Int, -32602)
    }

    func testParamsOptionalObject() throws {
        let p = Params(raw: ["scope": ["pid": 12]])
        XCTAssertEqual(try p.object("scope").int("pid"), 12)
        XCTAssertNil(p.optObject("missing"))
        XCTAssertThrowsError(try p.object("missing"))
    }

    // MARK: Errors

    func testErrorCodesMatchProtocolDoc() {
        let expected: [HelperError.Kind: Int] = [
            .notTrusted: -32001, .staleRef: -32002, .notFound: -32003, .unsupported: -32004,
            .axError: -32005, .timeout: -32006, .invalidParams: -32602, .methodNotFound: -32601,
            .parseError: -32700, .internalError: -32603,
        ]
        for (k, c) in expected { XCTAssertEqual(k.code, c, "\(k)") }
    }

    func testNotTrustedHasHint() {
        XCTAssertNotNil(HelperError.notTrusted.data["hint"])
    }

    // MARK: Dispatcher

    func testCapabilitiesAreSortedMethodNames() {
        let d = Dispatcher()
        d.register("b.two") { _ in [:] as JSONObject }
        d.register("a.one") { _ in [:] as JSONObject }
        XCTAssertEqual(d.capabilities, ["a.one", "b.two"])
    }

    func testStandardDispatcherExposesSysAndApp() {
        let d = makeDispatcher(shutdown: {})
        for m in ["sys.hello", "sys.requestTrust", "sys.shutdown", "app.list", "app.activate"] {
            XCTAssertTrue(d.capabilities.contains(m), m)
        }
    }

    func testHelloReportsVersionAndCapabilities() {
        let d = makeDispatcher(shutdown: {})
        let r = roundtrip(#"{"id":1,"method":"sys.hello","params":{"clientVersion":"0"}}"#, d)!
        let res = r["result"] as! JSONObject
        XCTAssertEqual(res["protocolVersion"] as? String, protocolVersion)
        XCTAssertEqual(res["platform"] as? String, "macos")
        XCTAssertNotNil(res["trusted"] as? Bool)
        XCTAssertEqual(res["capabilities"] as? [String], d.capabilities)
    }

    func testShutdownIsDeferredNotImmediate() {
        var called = false
        let d = makeDispatcher(shutdown: { called = true })
        _ = roundtrip(#"{"id":1,"method":"sys.shutdown"}"#, d)
        XCTAssertFalse(called, "shutdown must run after the response is written")
    }
}
