import ApplicationServices
import Foundation

/// キーボードショートカットに対応するメニュー項目を AX のメニューバーから探す。
/// 見つかれば AXPress で実行できるので、アプリを前面にせずにショートカットを発火できる。
public enum MenuShortcut {
    /// AXMenuItemCmdModifiers のビット: 1 = shift, 2 = option, 4 = control, 8 = command 無し
    static func modifierMask(_ modifiers: [String]) -> Int? {
        guard modifiers.contains("cmd") else { return nil }   // cmd を含むショートカットだけを対象にする
        var m = 0
        if modifiers.contains("shift") { m |= 1 }
        if modifiers.contains("alt") { m |= 2 }
        if modifiers.contains("ctrl") { m |= 4 }
        return m
    }

    public static func find(pid: pid_t, key: String, modifiers: [String]) -> AXElement? {
        guard key.count == 1, let want = modifierMask(modifiers) else { return nil }
        let char = key.uppercased()
        guard let bar = AXElement.application(pid: pid).element(kAXMenuBarAttribute) else { return nil }
        for barItem in bar.children {
            for menu in barItem.children {
                if let hit = search(menu, char: char, mask: want, depth: 0) { return hit }
            }
        }
        return nil
    }

    private static func search(_ menu: AXElement, char: String, mask: Int, depth: Int) -> AXElement? {
        for item in menu.children {
            if let c = item.string("AXMenuItemCmdChar"), c.uppercased() == char,
               Int(item.number("AXMenuItemCmdModifiers") ?? -1) == mask {
                return item   // 有効/無効は呼び出し側で判断する
            }
            if depth < 2 {
                for sub in item.children where sub.role == kAXMenuRole {
                    if let hit = search(sub, char: char, mask: mask, depth: depth + 1) { return hit }
                }
            }
        }
        return nil
    }
}
