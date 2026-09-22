import AppKit
import ApplicationServices
import Foundation

public func registerUIMethods(_ d: Dispatcher) {
    d.register("ui.snapshot") { p in
        try Trust.require()
        let root = try p.scopeRoot()
        return snapshotResult(SnapshotBuilder.build(root: root, options: p.snapshotOptions()))
    }

    d.register("ui.find") { p in
        try Trust.require()
        let root = try p.scopeRoot()
        let match = try p.findQuery()
        var opts = p.snapshotOptions()
        opts.maxNodes = p.optInt("maxNodes") ?? 5000
        let out = SnapshotBuilder.build(root: root, options: opts, match: match)
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

    d.register("ui.setAttribute") { p in
        let el = try p.ref()
        let name = try p.string("name")
        guard let value = p.raw["value"] else { throw HelperError.invalidParams("value required") }
        try el.set(name, try AXJSON.toCF(value))
        return [:] as JSONObject
    }

    d.register("ui.performAction") { p in
        let el = try p.ref()
        try el.perform(try p.string("action"))
        return [:] as JSONObject
    }

    d.register("ui.focus") { p in
        let el = try p.ref()
        try focus(el)
        return [:] as JSONObject
    }

    d.register("ui.click") { p in
        try Trust.require()
        let button = p.optString("button")
        let count = p.optInt("count") ?? 1
        let mods = p.modifiers()
        if let el = try p.optRef() {
            let plain = (button ?? "left") == "left" && count == 1 && mods.isEmpty
            if plain, el.actionNames().contains(kAXPressAction) {
                bringToFront(el)
                try el.perform(kAXPressAction)
                return ["method": "ax"] as JSONObject
            }
            guard let c = el.center else { throw HelperError(.unsupported, "element has no frame to click") }
            bringToFront(el)
            try Input.click(at: c, button: button, count: count, modifiers: mods)
            return ["method": "cg"] as JSONObject
        }
        guard let pt = try p.optPoint("point") else { throw HelperError.invalidParams("ref or point required") }
        try Input.click(at: pt, button: button, count: count, modifiers: mods)
        return ["method": "cg"] as JSONObject
    }

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
            throw HelperError(.timeout, "UI did not settle within \(Int(timeout * 1000))ms")
        }
        let wantExists = cond.raw["exists"] != nil
        guard wantExists || cond.raw["gone"] != nil else { throw HelperError.invalidParams("condition needs exists, gone or stable") }
        let match = try cond.findQuery(wantExists ? "exists" : "gone")
        opts.maxNodes = 5000
        while true {
            let out = SnapshotBuilder.build(root: root, options: opts, match: match)
            let found = !out.refs.isEmpty
            if found == wantExists {
                return snapshotResult(wantExists ? out : SnapshotBuilder.build(root: root, options: p.snapshotOptions()))
            }
            if Date() >= deadline { throw HelperError(.timeout, "condition not met within \(Int(timeout * 1000))ms") }
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
    bringToFront(el)
    if el.isSettable(kAXFocusedAttribute) {
        try el.set(kAXFocusedAttribute, kCFBooleanTrue)
    } else if let c = el.center {
        try Input.click(at: c)
    } else {
        throw HelperError(.unsupported, "element cannot be focused")
    }
}
