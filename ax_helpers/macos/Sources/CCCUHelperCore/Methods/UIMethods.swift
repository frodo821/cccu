import AppKit
import ApplicationServices
import Foundation

public func registerUIMethods(_ d: Dispatcher) {
    d.register("ui.snapshot") { p in
        try Trust.require()
        let root = try p.scopeRoot()
        waitForAXReady(root)
        return snapshotResult(SnapshotBuilder.build(root: root, options: p.snapshotOptions()))
    }

    d.register("ui.find") { p in
        try Trust.require()
        let root = try p.scopeRoot()
        waitForAXReady(root)
        let match = try p.findQuery()
        var opts = p.snapshotOptions()
        opts.maxNodes = p.optInt("maxNodes") ?? 5000
        let out = SnapshotBuilder.build(root: root, options: opts, match: match)
        return snapshotResult(out)
    }

    // CSS セレクタ風の構造クエリ。結果の形は ui.find と同じ
    d.register("ui.query") { p in
        try Trust.require()
        let root = try p.scopeRoot()
        waitForAXReady(root)
        let sel = try Query.parse(try p.string("selector"))
        var opts = p.snapshotOptions()
        opts.maxNodes = p.optInt("maxNodes") ?? 5000
        let out = SnapshotBuilder.build(root: root, options: opts, match: { sel.matches($0) })
        return snapshotResult(out)
    }

    d.register("ui.attributes") { p in
        let el = try p.ref()
        let names = (p.raw["names"] as? [String]) ?? el.attributeNames()
        var attrs: JSONObject = [:]
        for n in names {
            if let v = el.attribute(n) { attrs[n] = AXJSON.fromCF(v) }
        }
        attrs["_actions"] = el.actionNames()
        return ["attributes": attrs] as JSONObject
    }

    d.register("ui.focus") { p in
        let el = try p.ref()
        try focus(el)
        return [:] as JSONObject
    }

    d.register("ui.click") { p in
        try Trust.require()
        let anchor = try p.optRef()
        return try ChangeReport.wrap(p, anchor: anchor, pid: anchor?.pid) { try clickBody(p) }
    }

    d.register("ui.setAttribute") { p in
        let el = try p.ref()
        let name = try p.string("name")
        guard let value = p.raw["value"] else { throw HelperError.invalidParams("value required") }
        return try ChangeReport.wrap(p, anchor: el, pid: el.pid) { try el.set(name, try AXJSON.toCF(value)); return [:] as JSONObject }
    }

    d.register("ui.performAction") { p in
        let el = try p.ref()
        return try ChangeReport.wrap(p, anchor: el, pid: el.pid) { try el.perform(try p.string("action")); return [:] as JSONObject }
    }
}

/// ui.click の本体 (ChangeReport.wrap から呼ぶ)
private func clickBody(_ p: Params) throws -> JSONObject {
        let button = p.optString("button")
        let count = p.optInt("count") ?? 1
        let mods = p.modifiers()
        let fg = wantsForeground(p.optBool("foreground") ?? false)
        if let el = try p.optRef() {
            let plain = (button ?? "left") == "left" && count == 1 && mods.isEmpty
            if plain, !el.isWebContent, el.actionNames().contains(kAXPressAction) {
                // AXPress は多くの場合アプリが背面のままでも動く。ただしキーウィンドウに依存する操作 (書式の切り替えなど) は
                // 背面だと黙って無効になるので、効かなければ foreground: true で再試行する
                try act(el.pid, window: el.window, foreground: fg) { try el.perform(kAXPressAction) }
                return ["method": fg ? "ax+foreground" : "ax"] as JSONObject
            }
            let refName = (try? p.object("ref")).map { "\((try? $0.string("snapshot")) ?? "?")/\((try? $0.string("ref")) ?? "?")" } ?? "?"
            let frame0 = el.frame
            guard var c = el.ensureVisibleCenter() else { throw HelperError(.unsupported, "element has no frame to click") }
            let frame1 = el.frame
            let pointer = PointerMode(rawValue: p.optString("pointer") ?? "") ?? pointerMode
            let force = p.optBool("force") ?? false
            var retried = false
            var diag: [String: Any] = ["ref": refName, "role": el.role ?? "?", "name": el.title ?? el.descriptionText ?? "", "frame0": frame0 ?? "nil", "frame1": frame1 ?? "nil", "center": c]
            // 実マウスクリックはウィンドウが前面にある必要がある。終わったら元のアプリへ戻す
            try withForeground(el.pid, window: el.window) {
                // 前面に出した状態で、座標に実際にあるものを確認する。Chrome の AX の frame はスクロールやレイアウト変更より
                // 遅れて更新されるので、対象が見つかるまで frame を読み直して再試行する。それでも別の要素なら (モーダルのスクリムなど) 知らせる
                var hit = elementAt(c)
                var tries = 0
                diag["hit0"] = hit.map { "\($0.role ?? "?") \($0.title ?? "")" } ?? "nil"
                while !force, let h = hit, !h.isRelated(to: el), tries < 12 {
                    tries += 1
                    spin(0.08)
                    if let f = el.frame, f.width > 2, f.height > 2 { c = CGPoint(x: f.midX, y: f.midY) }
                    hit = elementAt(c)
                }
                if !force, let hit = hit, !hit.isRelated(to: el) {
                    let hitRole = hit.role.map { SnapshotBuilder.normalizeRole($0, subrole: hit.subrole) } ?? "unknown"
                    let hitName = hit.title ?? hit.descriptionText ?? ""
                    var data: JSONObject = ["obstructedBy": ["role": hitRole, "title": hitName] as JSONObject, "point": ["x": c.x, "y": c.y] as JSONObject]
                    if let d = hit.enclosingDialog { data["dialog"] = ["role": d.role.map { SnapshotBuilder.normalizeRole($0, subrole: d.subrole) } ?? "", "title": d.title ?? ""] as JSONObject }
                    throw HelperError(.obstructed, "click point is covered by \(hitRole) \"\(hitName)\"\(hit.enclosingDialog != nil ? " inside a dialog" : ""); snapshot again and act on what covers it, or pass force: true", data: data)
                }
                // ポインタの移動中に前の操作のスクロールが続いていると押下位置がずれるので、移動後にもう一度確かめ、動いていれば追従する
                let recheck: (CGPoint) -> CGPoint? = { pt in
                    if let h = elementAt(pt), h.isRelated(to: el) { return nil }
                    guard let f = el.frame, f.width > 2, f.height > 2 else { return nil }
                    let c2 = CGPoint(x: f.midX, y: f.midY)
                    return hypot(c2.x - pt.x, c2.y - pt.y) > 2 ? c2 : nil
                }
                var pressed = c
                let recheckLogged: (CGPoint) -> CGPoint? = { pt in let r = recheck(pt); if let r = r { pressed = r; diag["recheckMoved"] = true }; return r }
                let framePress = el.frame
                diag["hitTries"] = tries; diag["frame2"] = framePress ?? "nil"
                try Input.click(at: c, size: framePress?.size, button: button, count: count, modifiers: mods, mode: pointer, recheck: recheckLogged)
                // 押下後の確認: AX の frame はスクロール直後に描画より遅れて更新されるので、押した点が (更新後の) frame の外に
                // 出ていたら、押下は別の場所に落ちている。その場合だけ新しい中心でもう 1 回押す
                spin(0.15)
                diag["pressed"] = pressed
                let after = el.frame
                diag["frame3"] = after ?? "nil"
                diag["focusedAfter"] = el.isFocused || (el.element(kAXParentAttribute)?.isFocused ?? false)
                diag["hitAfter"] = elementAt(pressed).map { "\($0.role ?? "?") \($0.title ?? "")" } ?? "nil"
                // 判定: 押下後に frame が動いていて、かつ押下点が (3px 内側まで含めて) frame に入っていないか、押下点のヒットテストが対象と無関係。
                // 端ぎりぎり (下端から 2px) に押していて frame の中には入っていたが、実際は別の要素に落ちていたケースがあった
                let moved = after.map { a in framePress.map { hypot(a.origin.x - $0.origin.x, a.origin.y - $0.origin.y) > 1 } ?? true } ?? false
                let outside = after.map { !$0.insetBy(dx: 3, dy: 3).contains(pressed) } ?? false
                let hitUnrelated = elementAt(pressed).map { !$0.isRelated(to: el) } ?? false
                diag["moved"] = moved
                if let a = after, a.width > 2, a.height > 2, moved, outside || hitUnrelated, count == 1 {
                    let c2 = CGPoint(x: a.midX, y: a.midY)
                    if let h = elementAt(c2), h.isRelated(to: el) {
                        try Input.click(at: c2, size: a.size, button: button, count: 1, modifiers: mods, mode: pointer)
                        diag["retried"] = c2
                        retried = true
                    }
                }
            }
            Diag.log("click", diag)
            let base = activationPolicy == .foreground || Session.isActive ? "cg" : "cg+restore"
            return ["method": retried ? base + " (element moved after scrolling; pressed again at its new position)" : base] as JSONObject
        }
        guard let pt = try p.optPoint("point") else { throw HelperError.invalidParams("ref or point required") }
        try UserActivity.guarded { try Input.click(at: pt, button: button, count: count, modifiers: mods, mode: PointerMode(rawValue: p.optString("pointer") ?? "") ?? pointerMode) }
        return ["method": "cg"] as JSONObject
}

/// 待機系 (ui.waitFor)
public func registerUIWaitMethods(_ d: Dispatcher) {

    d.register("ui.waitFor") { p in
        try Trust.require()
        let root = try p.scopeRoot()
        let cond = try p.object("condition")
        let timeout = TimeInterval(try p.int("timeoutMs")) / 1000
        let deadline = Date().addingTimeInterval(timeout)
        var opts = p.snapshotOptions()

        if let stableMs = cond.optInt("stable") {
            var last = SnapshotBuilder.build(root: root, options: opts).text
            var stableSince = Date()
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                let now = SnapshotBuilder.build(root: root, options: opts).text
                if now != last { last = now; stableSince = Date() }
                else if Date().timeIntervalSince(stableSince) * 1000 >= Double(stableMs) {
                    return snapshotResult(SnapshotBuilder.build(root: root, options: opts))
                }
            }
            throw HelperError(.timeout, "UI did not settle within \(Int(timeout * 1000))ms", data: ["lastSnapshot": String(last.prefix(6000))])
        }
        let wantExists = cond.raw["exists"] != nil
        guard wantExists || cond.raw["gone"] != nil else { throw HelperError.invalidParams("condition needs exists, gone or stable") }
        let match = try cond.findQuery(wantExists ? "exists" : "gone")
        let minCount = cond.optInt("count") ?? 1   // N 個以上あれば「存在」とみなす (同じ文言が増えるのを待つ用)
        opts.maxNodes = 5000
        while true {
            let out = SnapshotBuilder.build(root: root, options: opts, match: match)
            let found = out.matches >= minCount   // 祖先に付く ref ではなく一致数で判定する
            if found == wantExists {
                return snapshotResult(wantExists ? out : SnapshotBuilder.build(root: root, options: p.snapshotOptions()))
            }
            if Date() >= deadline {
                // 何が見えていたかを添える (別途スナップショットを取らずに原因を判断できるように)。ref は登録しない
                let last = SnapshotBuilder.build(root: root, options: p.snapshotOptions()).text
                throw HelperError(.timeout, "condition not met within \(Int(timeout * 1000))ms (matches=\(out.matches))",
                                  data: ["matches": out.matches, "lastSnapshot": String(last.prefix(6000))])
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}

/// 要素の属するアプリとウィンドウを前面に出す
func bringToFront(_ el: AXElement) {
    activate(el.pid)
    if let w = el.window, !w.isMainWindow {
        try? w.perform(kAXRaiseAction)
    }
}

func focus(_ el: AXElement) throws {
    if el.isFocused { return }
    if el.isSettable(kAXFocusedAttribute) {
        try? el.set(kAXFocusedAttribute, kCFBooleanTrue)
        // Chrome のアドレスバーなどは設定を受け付けても実際にはフォーカスが移らない。確認して駄目ならクリックする
        Thread.sleep(forTimeInterval: 0.05)
        if el.isFocused { return }
    }
    guard let c = el.ensureVisibleCenter() else { throw HelperError(.unsupported, "element cannot be focused") }
    try withForeground(el.pid, window: el.window) {
        try Input.click(at: c, size: el.frame?.size)
        Thread.sleep(forTimeInterval: 0.05)
    }
}

/// アプリ要素の子が一時的に取れない (前面化・復帰の直後など) 場合に短く待つ
func waitForAXReady(_ root: AXElement) {
    guard root.role == kAXApplicationRole else { return }
    for _ in 0..<5 where root.children.isEmpty { spin(0.1) }
}
