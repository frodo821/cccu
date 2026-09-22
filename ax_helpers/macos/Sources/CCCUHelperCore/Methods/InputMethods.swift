import ApplicationServices
import Foundation

public func registerInputMethods(_ d: Dispatcher) {
    d.register("input.type") { p in
        try Trust.require()
        let text = try p.string("text")
        let clear = p.optBool("clear") ?? false
        let submit = p.optBool("submit") ?? false
        // 対象: ref があればそれ、なければシステム全体のフォーカス要素
        let target: AXElement?
        if let el = try p.optRef() {
            try focus(el)
            target = el
        } else {
            target = AXElement.systemWide.element(kAXFocusedUIElementAttribute)
        }
        let pid = target?.pid
        // method: "auto" (既定) | "keys" | "ax"。submit 時は既定で実打鍵にする:
        // AX で挿入した文字列は、アプリによっては「ユーザー入力」として扱われず Enter が効かない (Chrome のアドレスバーなど)
        let mode = p.optString("method") ?? (submit ? "keys" : "auto")
        var method = try typeInto(target, text: text, clear: clear, forceKeys: mode == "keys")
        if mode == "keys", let el = target {
            Thread.sleep(forTimeInterval: 0.05)
            if let v = el.value as? String, !v.hasSuffix(text) {
                // 打鍵が落ちた場合 (新規ウィンドウ直後など) は AX で入れ直す
                method = try typeInto(el, text: text, clear: true) + "(fallback)"
            }
        }
        if submit { try Input.pressKey("Enter", pid: pid) }
        return ["method": method] as JSONObject
    }

    d.register("input.key") { p in
        try Trust.require()
        try Input.pressKey(try p.string("key"), modifiers: p.modifiers(), pid: p.optInt("pid").map { pid_t($0) })
        return [:] as JSONObject
    }

    d.register("input.scroll") { p in
        try Trust.require()
        let dx = try p.int("dx"), dy = try p.int("dy")
        let point: CGPoint
        if let el = try p.optRef() {
            guard let c = el.center else { throw HelperError(.unsupported, "element has no frame") }
            bringToFront(el)
            point = c
        } else if let pt = try p.optPoint("point") {
            point = pt
        } else {
            throw HelperError.invalidParams("ref or point required")
        }
        Input.scroll(at: point, dx: dx, dy: dy)
        return [:] as JSONObject
    }

    d.register("input.mouse") { p in
        try Trust.require()
        try Input.mouse(action: try p.string("action"), at: try p.point("point"), to: try p.optPoint("to"), button: p.optString("button"))
        return [:] as JSONObject
    }
}

/// テキスト入力の戦略 (上から順に試す):
///  1. AXSelectedText の設定 = キャレット位置への挿入。Cocoa のテキストビューや Web の入力欄で動き、IME の影響を受けない
///  2. AXValue の設定 = 既存値 + text で置き換え
///  3. CGEvent の Unicode 打鍵 (アプリがどちらの属性も受け付けない場合)
/// 戻り値は使った経路 ("selectedText" | "value" | "keys")
func typeInto(_ el: AXElement?, text: String, clear: Bool, forceKeys: Bool = false) throws -> String {
    if let el = el, !forceKeys {
        if clear, el.isSettable(kAXValueAttribute) { try el.set(kAXValueAttribute, "" as CFString) }
        if el.isSettable(kAXSelectedTextAttribute), el.string(kAXSelectedTextAttribute) != nil {
            if clear, !el.isSettable(kAXValueAttribute) { try Input.pressKey("a", modifiers: ["cmd"], pid: el.pid) }
            try el.set(kAXSelectedTextAttribute, text as CFString)
            return "selectedText"
        }
        if el.isSettable(kAXValueAttribute), el.value is String || el.value == nil {
            let current = (el.value as? String) ?? ""
            try el.set(kAXValueAttribute, (current + text) as CFString)
            return "value"
        }
    }
    let pid = el?.pid
    if clear { try Input.pressKey("a", modifiers: ["cmd"], pid: pid); try Input.pressKey("Backspace", pid: pid) }
    Input.typeText(text, pid: pid)
    return "keys"
}
