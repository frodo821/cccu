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

    func testCleanNameStripsInvisibleAndIconGlyphs() {
        XCTAssertEqual(SnapshotBuilder.cleanName("\u{F10A} Item 42"), "Item 42")   // 私用領域のアイコン + 空白
        XCTAssertEqual(SnapshotBuilder.cleanName("\u{200B}\u{FEFF}"), "")
        XCTAssertEqual(SnapshotBuilder.cleanName("  Save\u{00A0}"), "Save")
    }

    func testMatchCountPrefersLeaves() {
        let el = AXElement.systemWide
        func node(_ role: String, _ title: String?, _ children: [Node] = []) -> Node {
            let n = Node(element: el, role: role, title: title, value: nil, states: [], actionable: false)
            n.children = children
            return n
        }
        // 正解フィードバックが group > text で入っている形。group は blockText で、text は title で一致する
        let tree = node("webarea", nil, [
            node("group", nil, [node("text", "正解は"), node("text", " May I")]),
            node("group", nil, [node("text", "正解は"), node("text", " Could you")]),
            node("text", "正解は"),
        ])
        let q: (Node) -> Bool = { ($0.title ?? "").contains("正解は") || (!$0.children.isEmpty && $0.blockText.contains("正解は")) }
        XCTAssertEqual(SnapshotBuilder.markMatches(tree, q), 3)
        XCTAssertTrue(tree.children[0].matched, "親にも印は付く (ref を取れるように)")
        XCTAssertTrue(tree.children[0].children[0].matched)
        // 子に一致がなく親だけ一致するときは親を数える
        let only = node("group", "正解は", [node("text", "x")])
        XCTAssertEqual(SnapshotBuilder.markMatches(only, q), 1)
    }

    func testSessionIsInactiveByDefaultAndRequiresMaxSeconds() throws {
        XCTAssertFalse(Session.isActive)
        XCTAssertEqual(Session.status["active"] as? Bool, false)
        let d = Dispatcher()
        registerSessionMethods(d)
        XCTAssertTrue(d.capabilities.contains("session.begin") && d.capabilities.contains("session.end"))
        // maxSeconds を宣言しない begin は受け付けない (閉じ込め防止)
        let r = d.handle(Request(json: ["jsonrpc": "2.0", "id": 1, "method": "session.begin", "params": ["pid": Int(ProcessInfo.processInfo.processIdentifier)]])!)
        if case .error(_, let e) = r { XCTAssertTrue([.invalidParams, .notTrusted].contains(e.kind)) } else { XCTFail("expected an error") }
        XCTAssertEqual(UserActivity.mode, .block)
    }

    func testDiagFormattingNeverTrapsOnNullRects() {
        XCTAssertEqual(Diag.fmt(CGRect.null), "null")
        XCTAssertEqual(Diag.fmt(CGRect.infinite), "null")
        XCTAssertEqual(Diag.fmt(CGRect(x: 1.4, y: 2.6, width: 3, height: 4)), "1,3 3x4")
        XCTAssertEqual(Diag.fmt(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)), "nan,nan")
        XCTAssertEqual(Diag.fmt("multi\nline"), "\"multi line\"")
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

final class ActivationTests: XCTestCase {
    func testMenuShortcutModifierMask() {
        XCTAssertNil(MenuShortcut.modifierMask([]))                 // cmd を含まないものは対象外
        XCTAssertNil(MenuShortcut.modifierMask(["shift"]))
        XCTAssertEqual(MenuShortcut.modifierMask(["cmd"]), 0)
        XCTAssertEqual(MenuShortcut.modifierMask(["cmd", "shift"]), 1)
        XCTAssertEqual(MenuShortcut.modifierMask(["cmd", "alt"]), 2)
        XCTAssertEqual(MenuShortcut.modifierMask(["cmd", "shift", "alt", "ctrl"]), 7)
    }

    func testActivationPolicyParsing() {
        XCTAssertEqual(ActivationPolicy(rawValue: "background"), .background)
        XCTAssertEqual(ActivationPolicy(rawValue: "restore"), .restore)
        XCTAssertEqual(ActivationPolicy(rawValue: "foreground"), .foreground)
        XCTAssertNil(ActivationPolicy(rawValue: "nope"))
    }

    func testAppLaunchRequiresBundleIdAndRejectsUnknown() {
        let d = makeDispatcher(shutdown: {})
        if case .error(_, let e) = d.handle(Request(json: ["id": 1, "method": "app.launch", "params": [:]])!) {
            XCTAssertEqual(e.kind, .invalidParams)
        } else { XCTFail() }
        if case .error(_, let e) = d.handle(Request(json: ["id": 1, "method": "app.launch", "params": ["bundleId": "invalid.does.not.exist"]])!) {
            XCTAssertEqual(e.kind, .notFound)
        } else { XCTFail() }
        XCTAssertTrue(d.capabilities.contains("app.launch"))
    }
}

final class QueryTests: XCTestCase {
    let el = AXElement.systemWide
    func node(_ role: String, _ title: String? = nil, states: [String] = [], _ children: [Node] = []) -> Node {
        let n = Node(element: el, role: role, title: title, value: nil, states: states, actionable: false)
        n.children = children
        children.forEach { $0.parent = n }
        return n
    }
    func tree() -> Node {
        node("webarea", "Lesson", [
            node("heading", "Q1"),
            node("group", nil, [node("text", "正解は"), node("text", " May I"), node("button", "確認", states: ["disabled"])]),
            node("heading", "Q2"),
            node("group", nil, [node("button", "Could you"), node("button", "確認")]),
            node("link", "文法 レベル5 スタート"),
        ])
    }
    func names(_ sel: String, _ root: Node) throws -> [String] {
        let s = try Query.parse(sel)
        var out: [String] = []
        func walk(_ n: Node) { if s.matches(n) { out.append("\(n.role):\(n.title ?? "")") }; n.children.forEach(walk) }
        walk(root)
        return out
    }
    func testRoleAttributeAndPseudo() throws {
        let t = tree()
        XCTAssertEqual(try names("button", t).count, 3)
        XCTAssertEqual(try names("button:enabled", t), ["button:Could you", "button:確認"])
        XCTAssertEqual(try names("button[name=確認]:disabled", t), ["button:確認"])
        XCTAssertEqual(try names("link[name$=スタート]", t), ["link:文法 レベル5 スタート"])
        XCTAssertEqual(try names("[name^=\"Q\"]", t), ["heading:Q1", "heading:Q2"])
        XCTAssertEqual(try names("\"正解は\"", t), ["group:", "text:正解は"], "文字列は名前か子テキストの連結に一致")
    }
    func testCombinators() throws {
        let t = tree()
        XCTAssertEqual(try names("group:has(\"正解は\") > button", t), ["button:確認"])
        XCTAssertEqual(try names("group:has(\"正解は\") button:disabled", t), ["button:確認"])
        XCTAssertEqual(try names("heading[name=Q2] + group button", t), ["button:Could you", "button:確認"])
        XCTAssertEqual(try names("heading[name=Q1] ~ link", t), ["link:文法 レベル5 スタート"])
        XCTAssertEqual(try names("webarea >> text", t).count, 2)
        XCTAssertEqual(try names("group:not(:has(\"正解は\")) > button:not([name=確認])", t), ["button:Could you"])
        XCTAssertEqual(try names("heading, link", t).count, 3)
        XCTAssertEqual(try names("group:has(> text) > button", t), ["button:確認"], ":has(> X) は直接の子")
        XCTAssertEqual(try names("heading:has(+ group:has(\"正解は\"))", t), ["heading:Q1"], ":has(+ X) は次の兄弟")
        XCTAssertEqual(try names("heading:has(~ link)", t).count, 2)
    }
    func testParseErrors() {
        XCTAssertThrowsError(try Query.parse("button["))
        XCTAssertThrowsError(try Query.parse("button:nope"))
        XCTAssertThrowsError(try Query.parse("\"unterminated"))
        XCTAssertThrowsError(try Query.parse(""))
    }
}

final class ChangeReportTests: XCTestCase {
    func testDiffIgnoresRefNumbersAndKeepsOrder() {
        let before = "- webarea \"L\" [ref=e1]\n  - heading \"Q1\"\n  - button \"確認\" [ref=e2] [disabled]\n  - button \"A\" [ref=e3]"
        let after = "- webarea \"L\" [ref=e1]\n  - heading \"Q1\"\n  - text \"正解は A\"\n  - button \"確認\" [ref=e4] [disabled]\n  - button \"A\" [ref=e5] [focused]\n  - button \"次へ進む\" [ref=e6]"
        let (added, removed) = ChangeReport.diff(before: before, after: after)
        XCTAssertEqual(added, ["  - text \"正解は A\"", "  - button \"A\" [ref=e5] [focused]", "  - button \"次へ進む\" [ref=e6]"])
        XCTAssertEqual(removed, ["  - button \"A\" [ref=e3]"])
        XCTAssertEqual(ChangeReport.stripRefs("- button \"x\" [ref=e12] [disabled]"), "- button \"x\" [disabled]")
    }
}
