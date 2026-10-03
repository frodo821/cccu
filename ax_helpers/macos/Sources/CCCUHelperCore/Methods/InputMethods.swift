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
        let fg = wantsForeground(p.optBool("foreground") ?? false)
        // 実キーを使うか: 打鍵モード、または Enter を送る必要があるとき。実キーは HID へ流すので前面化が要る
        // (CCCU_DIRECT_INPUT=1 のときは対象プロセスへ直送し、前面化しない)
        let needsKeys = mode == "keys" || submit
        let direct = directInput && !fg && pid != nil
        var method = ""
        let work: () throws -> Void = {
            // 打鍵モードでは、打つ前の値から期待値を決めておき、打鍵が落ちたら期待値を AX で設定して補正する
            let before = (target?.value as? String) ?? ""
            let expected = (clear ? "" : before) + text
            if mode == "keys" { spin(0.12) }   // 前面化や AX での値設定の直後は Unicode 打鍵が落ちやすいので少し待つ
            method = try typeInto(target, text: text, clear: clear, forceKeys: mode == "keys", direct: direct)
            if mode == "keys", let el = target, el.value is String {
                spin(0.08)
                if (el.value as? String) != expected, el.isSettable(kAXValueAttribute) {
                    try el.set(kAXValueAttribute, expected as CFString)
                    method += "(corrected)"
                }
            }
            if submit { try Input.pressKey("Enter", pid: pid, direct: direct) }
        }
        if let pid = pid, fg || (needsKeys && !direct) {
            try withForeground(pid, window: target?.window, work)
            if activationPolicy != .foreground { method += "+restore" }
        } else {
            try work()
        }
        return ["method": method] as JSONObject
    }

    d.register("input.key") { p in
        try Trust.require()
        let key = try p.string("key")
        let mods = p.modifiers()
        let foreground = wantsForeground(p.optBool("foreground") ?? false)
        guard let pid = p.optInt("pid").map({ pid_t($0) }) else {
            try Input.pressKey(key, modifiers: mods)          // 対象指定なし: 最前面のアプリへ
            return ["method": "hid"] as JSONObject
        }
        if !foreground {
            let isShortcut = mods.contains("cmd") || mods.contains("ctrl")
            // 1. ショートカットは AX のメニュー項目として実行する (前面化不要)。
            //    背面のアプリにはキーウィンドウが無く、ウィンドウ対象の項目 (閉じる・保存など) は無効になるので、その場合は 3 へ
            if isShortcut, let item = MenuShortcut.find(pid: pid, key: key, modifiers: mods), item.isEnabled {
                try item.perform(kAXPressAction)
                return ["method": "menu", "item": item.title ?? ""] as JSONObject
            }
            // 2. CCCU_DIRECT_INPUT=1 のときだけ、修飾なしのキーを対象プロセスへ直送する
            if directInput, !isShortcut {
                try Input.pressKey(key, modifiers: mods, pid: pid, direct: true)
                return ["method": "pid"] as JSONObject
            }
            // 3. 一瞬だけ前面化して実キーを送り、元のアプリへ戻す
        }
        try withForeground(pid) { try Input.pressKey(key, modifiers: mods) }
        return ["method": activationPolicy == .foreground ? "hid" : "hid+restore"] as JSONObject
    }

    d.register("input.scroll") { p in
        try Trust.require()
        let dx = try p.int("dx"), dy = try p.int("dy")
        if let el = try p.optRef() {
            guard let c = el.center else { throw HelperError(.unsupported, "element has no frame") }
            if directInput, !wantsForeground(p.optBool("foreground") ?? false) {
                Input.scroll(at: c, dx: dx, dy: dy, pid: el.pid)   // 対象プロセスへ直接 (前面化しない)
                return ["method": "pid"] as JSONObject
            }
            withForeground(el.pid, window: el.window) { Input.scroll(at: c, dx: dx, dy: dy) }
            return ["method": activationPolicy == .foreground ? "hid" : "hid+restore"] as JSONObject
        }
        guard let pt = try p.optPoint("point") else { throw HelperError.invalidParams("ref or point required") }
        Input.scroll(at: pt, dx: dx, dy: dy)
        return ["method": "hid"] as JSONObject
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
func typeInto(_ el: AXElement?, text: String, clear: Bool, forceKeys: Bool = false, direct: Bool = false) throws -> String {
    if let el = el, !forceKeys {
        if clear, el.isSettable(kAXValueAttribute) { try el.set(kAXValueAttribute, "" as CFString) }
        if el.isSettable(kAXSelectedTextAttribute), el.string(kAXSelectedTextAttribute) != nil {
            if clear, !el.isSettable(kAXValueAttribute) { try Input.pressKey("a", modifiers: ["cmd"], pid: el.pid, direct: direct) }
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
    if clear {
        // 打鍵モードではクリアもキー操作で行う。AX で値を設定した直後は Unicode 打鍵が落ちることがあり、
        // Chrome のアドレスバーでは AX で入れた値が「ユーザー入力」として扱われないため
        try Input.pressKey("a", modifiers: ["cmd"], pid: pid, direct: direct)
        try Input.pressKey("Backspace", pid: pid, direct: direct)
    }
    Input.typeText(text, pid: pid, direct: direct)
    return direct ? "keys(pid)" : "keys"
}
