import ApplicationServices
import Foundation

/// AX ツリーを走査して PROTOCOL.md §6 のテキスト記法と ref 表を作る。
public struct SnapshotOptions {
    public var maxDepth = 40
    public var maxNodes = 800
    public var interestingOnly = true
    public var valueLimit = 80
    public init() {}
}

public struct SnapshotOutput {
    public let text: String
    public let refs: [String: AXElement]
    public let truncated: Bool
}

/// 走査で得た中間ノード
final class Node {
    let element: AXElement
    let role: String          // "button" など (AX を除いた小文字)
    let title: String?
    let value: Any?
    let states: [String]
    let actionable: Bool
    var children: [Node] = []
    var matched = false       // ui.find 用
    var ref: String?

    init(element: AXElement, role: String, title: String?, value: Any?, states: [String], actionable: Bool) {
        self.element = element; self.role = role; self.title = title
        self.value = value; self.states = states; self.actionable = actionable
    }
}

public enum SnapshotBuilder {
    /// ref を付けるロール。これ以外でもアクションを持つか値が設定可能なら付ける
    static let refRoles: Set<String> = [
        "window", "sheet", "drawer", "button", "popupbutton", "menubutton", "checkbox", "radiobutton",
        "textfield", "textarea", "securetextfield", "searchfield", "combobox", "slider", "incrementor",
        "link", "menuitem", "menubaritem", "menu", "tab", "row", "cell", "disclosuretriangle", "scrollbar",
        "toolbar", "tabgroup", "table", "outline", "list", "webarea", "image", "colorwell", "datepicker",
    ]
    /// expanded / collapsed を表示する意味があるロール (Chrome は多くのノードに AXExpanded=false を付ける)
    static let expandableRoles: Set<String> = [
        "disclosuretriangle", "combobox", "popupbutton", "menubutton", "row", "outlinerow", "menubaritem", "menu", "menuitem", "tab", "treeitem", "button",
    ]
    /// 子をたどらないロール (巨大になりがち、または中身が意味を持たない)
    static let leafRoles: Set<String> = ["menubar", "ruler"]   // メニューはタイトル行だけ、ルーラーは中身を出さない
    static let skipRoles: Set<String> = ["unknown", "listmarker"]

    // MARK: 走査

    static func build(root: AXElement, options: SnapshotOptions, match: ((Node) -> Bool)? = nil) -> SnapshotOutput {
        var count = 0
        var truncated = false

        func walk(_ el: AXElement, depth: Int) -> Node? {
            if count >= options.maxNodes { truncated = true; return nil }
            guard let rawRole = el.role else { return nil }
            let role = normalizeRole(rawRole, subrole: el.subrole)
            if skipRoles.contains(role) { return nil }
            count += 1

            let node = makeNode(el, role: role, options: options)
            node.matched = match?(node) ?? false

            if depth < options.maxDepth && !leafRoles.contains(role) {
                for child in el.children {
                    if let n = walk(child, depth: depth + 1) { node.children.append(n) }
                    if count >= options.maxNodes { truncated = true; break }
                }
            } else if depth >= options.maxDepth && !el.children.isEmpty {
                truncated = true
            }
            if role == "menubar" {   // メニューバーは項目名まで
                for child in el.children {
                    if let r = child.role { node.children.append(makeNode(child, role: normalizeRole(r, subrole: nil), options: options)) }
                }
            }
            return node
        }

        guard let tree = walk(root, depth: 0) else {
            return SnapshotOutput(text: "", refs: [:], truncated: truncated)
        }
        let forest: [Node]
        if let _ = match {
            forest = prune(tree).map { [$0] } ?? []
        } else if options.interestingOnly {
            forest = collapse(tree)
        } else {
            forest = [tree]
        }
        var refs: [String: AXElement] = [:]
        var lines: [String] = []
        var refCounter = 0
        for n in forest { render(n, indent: 0, lines: &lines, refs: &refs, counter: &refCounter, options: options) }
        return SnapshotOutput(text: lines.joined(separator: "\n"), refs: refs, truncated: truncated)
    }

    static func makeNode(_ el: AXElement, role: String, options: SnapshotOptions) -> Node {
        var title = el.title
        if title == nil || title!.isEmpty { title = el.descriptionText }
        if (title == nil || title!.isEmpty), role == "link" || role == "image" { title = el.string("AXHelp") }
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) { title = t.isEmpty ? nil : t }

        var value: Any? = nil
        var states: [String] = []
        let v = el.value
        switch role {
        case "checkbox", "radiobutton", "menuitem":
            if let n = v as? Double { states.append(n == 0 ? "unchecked" : "checked") }
            else if let b = v as? Bool { states.append(b ? "checked" : "unchecked") }
        case "text":
            // 静的テキストは title がなければ value を title 扱いにする
            if title == nil, let s = v as? String { title = s }
        default:
            if let s = v as? String { if !s.isEmpty { value = s } }
            else if let n = v as? Double { value = n == n.rounded() ? Int(n) : n }
            else if let b = v as? Bool { value = b }
        }
        if role == "window" ? el.isMainWindow : el.isFocused { states.append("focused") }
        if !el.isEnabled { states.append("disabled") }
        if el.bool(kAXSelectedAttribute) == true { states.append("selected") }
        if expandableRoles.contains(role), let ex = el.bool(kAXExpandedAttribute) { states.append(ex ? "expanded" : "collapsed") }
        if el.bool(kAXMinimizedAttribute) == true { states.append("minimized") }

        let actions = el.actionNames()
        let container = ["group", "generic", "unknown", "splitgroup", "layoutarea", "layoutitem"].contains(role)
        let actionable = refRoles.contains(role)
            || actions.contains(where: { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" && !(container && $0 == "AXPress") })
            || (el.isSettable(kAXValueAttribute) && !container)
            || (el.isSettable(kAXFocusedAttribute) && !container)   // Chrome は全 group にフォーカス設定可を付ける
        return Node(element: el, role: role, title: title, value: value, states: states, actionable: actionable)
    }

    public static func normalizeRole(_ raw: String, subrole: String?) -> String {
        var r = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
        if let s = subrole, s.hasPrefix("AX"), !s.isEmpty {
            // 意味のあるサブロールはロール名として使う
            let sub = String(s.dropFirst(2))
            switch sub {
            case "SearchField", "SecureTextField", "CloseButton", "MinimizeButton", "ZoomButton",
                 "FullScreenButton", "ToolbarButton", "TabButton", "OutlineRow", "TableRow", "Dialog", "SystemDialog":
                r = sub
            default: break
            }
        }
        r = r.lowercased()
        if r == "statictext" { r = "text" }
        return r
    }

    // MARK: 整形

    /// interestingOnly: title/value/ref のない group/generic は子を親に繰り上げる
    static func collapse(_ node: Node) -> [Node] {
        node.children = node.children.flatMap(collapse)
        if let t = node.title {
            node.children.removeAll { $0.role == "text" && $0.title == t && !$0.matched && $0.children.isEmpty }
        }
        let boring = ["group", "generic", "splitgroup", "layoutarea", "layoutitem", "unknown"].contains(node.role)
        if boring && node.title == nil && node.value == nil && !node.actionable && !node.matched {
            return node.children
        }
        return [node]
    }

    /// ui.find: 一致ノード (とその子孫) と、そこへ至る祖先だけを残す
    static func prune(_ node: Node) -> Node? {
        if node.matched { node.children = node.children.flatMap(collapse); return node }
        node.children = node.children.compactMap(prune)
        return node.children.isEmpty ? nil : node
    }

    static func render(_ node: Node, indent: Int, lines: inout [String], refs: inout [String: AXElement], counter: inout Int, options: SnapshotOptions) {
        var line = String(repeating: "  ", count: indent) + "- " + node.role
        if let t = node.title { line += " " + quote(t, limit: options.valueLimit) }
        if node.actionable || node.matched {
            counter += 1
            let ref = "e\(counter)"
            node.ref = ref
            refs[ref] = node.element
            line += " [ref=\(ref)]"
        }
        for s in node.states { line += " [\(s)]" }
        if let v = node.value {
            if let s = v as? String { line += ": " + quote(s, limit: options.valueLimit) }
            else { line += ": \(v)" }
        }
        lines.append(line)
        for c in node.children { render(c, indent: indent + 1, lines: &lines, refs: &refs, counter: &counter, options: options) }
    }

    static func quote(_ s: String, limit: Int) -> String {
        var t = s.replacingOccurrences(of: "\n", with: "⏎")
        if t.count > limit { t = String(t.prefix(limit)) + "…" }
        return "\"" + t.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
