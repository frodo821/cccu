import ApplicationServices
import Foundation

/// AX ツリーを走査して PROTOCOL.md §6 のテキスト記法と ref 表を作る。
public struct SnapshotOptions {
    public var maxDepth = 80
    public var maxNodes = 800
    public var interestingOnly = true
    public var valueLimit = 80
    public var skipWebContent = false   // ブラウザ UI だけが要るとき、webarea の中身を出さない (ページが巨大だと予算を食い潰すため)
    public init() {}
}

public struct SnapshotOutput {
    public let text: String
    public let refs: [String: AXElement]
    public let truncated: Bool
    public var matches: Int = 0   // ui.find での一致数 (祖先の ref は含まない)
    public var truncatedBy: String? = nil   // "nodes" (maxNodes 到達) か "depth" (maxDepth で子孫を省いた)
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
    var rawTitle: String?     // 静的テキストの元の文字列 (前後の空白を保持)。隣の断片と結合するときの区切り判定用
    var ref: String?
    /// 子の葉テキストを連結した文字列 (装飾で分割された文に対する検索用)
    var blockText: String { children.filter { $0.role == "text" && $0.children.isEmpty }.compactMap { $0.title }.joined() }

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
        "disclosuretriangle", "combobox", "popupbutton", "menubutton", "row", "outlinerow", "menubaritem", "menu", "menuitem", "tab", "treeitem",
    ]
    /// 子をたどらないロール (巨大になりがち、または中身が意味を持たない)
    static let leafRoles: Set<String> = ["menubar", "ruler"]   // メニューはタイトル行だけ、ルーラーは中身を出さない
    static let skipRoles: Set<String> = ["unknown", "listmarker"]

    // MARK: 走査

    static func build(root: AXElement, options: SnapshotOptions, match: ((Node) -> Bool)? = nil) -> SnapshotOutput {
        var count = 0
        var truncated = false
        var depthCut = false   // maxDepth で切った (maxNodes ではなく)

        func walk(_ el: AXElement, depth: Int) -> Node? {
            if count >= options.maxNodes { truncated = true; return nil }
            guard let rawRole = el.role else { return nil }
            let role = normalizeRole(rawRole, subrole: el.subrole)
            if skipRoles.contains(role) { return nil }
            count += 1

            let node = makeNode(el, role: role, options: options)
            // 名前のない静的テキスト (アイコンフォントのグリフ、空文字列) は情報がないので出さない
            if role == "text", node.title == nil, node.value == nil, !node.actionable { return nil }

            if depth < options.maxDepth && !leafRoles.contains(role) && !(options.skipWebContent && role == "webarea") {
                for child in el.children {
                    if let n = walk(child, depth: depth + 1) { node.children.append(n) }
                    if count >= options.maxNodes { truncated = true; break }
                }
            } else if depth >= options.maxDepth && !el.children.isEmpty {
                truncated = true; depthCut = true
            }
            if role == "menubar" {   // メニューバーは項目名まで
                for child in el.children {
                    if let r = child.role { node.children.append(makeNode(child, role: normalizeRole(r, subrole: nil), options: options)) }
                }
            }
            return node
        }

        guard let tree = walk(root, depth: 0) else {
            return SnapshotOutput(text: "", refs: [:], truncated: truncated, truncatedBy: truncated ? (depthCut ? "depth" : "nodes") : nil)
        }
        // 一致判定はツリーが組み上がってから (子テキストを連結したブロック文字列にも一致させるため)
        var matchCount = 0
        if let match = match { matchCount = markMatches(tree, match) }
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
        return SnapshotOutput(text: lines.joined(separator: "\n"), refs: refs, truncated: truncated, matches: matchCount,
                              truncatedBy: truncated ? (depthCut && count < options.maxNodes ? "depth" : "nodes") : nil)
    }

    /// 一致ノードに印を付け、一致数を返す。一致数は末端優先: 子孫にも一致があれば親 (ブロック文字列で一致した group など) は数えない。
    /// count 待ちで同じ文言が 2 倍に数えられないようにするため
    @discardableResult
    static func markMatches(_ tree: Node, _ match: (Node) -> Bool) -> Int {
        var total = 0
        @discardableResult func mark(_ n: Node) -> Bool {
            n.matched = match(n)
            var childHit = false
            for c in n.children { if mark(c) { childHit = true } }
            if n.matched && !childHit { total += 1 }
            return n.matched || childHit
        }
        mark(tree)
        return total
    }

    static func makeNode(_ el: AXElement, role: String, options: SnapshotOptions) -> Node {
        var rawTitle: String? = nil
        var title = el.title
        if title == nil || title!.isEmpty { title = el.descriptionText }
        if (title == nil || title!.isEmpty), role == "link" || role == "image" { title = el.string("AXHelp") }
        if let t = title.map(cleanName) { title = t.isEmpty ? nil : t }

        var value: Any? = nil
        var states: [String] = []
        let v = el.value
        switch role {
        case "checkbox", "radiobutton", "menuitem":
            if let n = v as? Double { states.append(n == 0 ? "unchecked" : "checked") }
            else if let b = v as? Bool { states.append(b ? "checked" : "unchecked") }
        case "text":
            // 静的テキストは title がなければ value を title 扱いにする (アイコングリフだけなら無名のまま)
            if title == nil, let s = v as? String { let c = cleanName(s); title = c.isEmpty ? nil : c; rawTitle = c.isEmpty ? nil : stripInvisible(s) }
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
        let node = Node(element: el, role: role, title: title, value: value, states: states, actionable: actionable)
        node.rawTitle = rawTitle
        return node
    }

    /// 不可視文字だけを除く (空白はそのまま)
    static func stripInvisible(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !invisible.contains($0) }))
    }

    /// 名前から不可視文字 (ゼロ幅スペース、BOM、単語結合子、NBSP など) と前後の空白を取り除く。
    /// アイコンフォントのボタンは名前がこれらだけで構成されていることが多く、空扱いにしないと「無名」と判定できない
    static let invisible: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00A0}")
        set.insert(charactersIn: Unicode.Scalar(0xE000)!...Unicode.Scalar(0xF8FF)!)   // 私用領域 (アイコンフォント)
        return set
    }()
    public static func cleanName(_ s: String) -> String {
        stripInvisible(s).trimmingCharacters(in: .whitespacesAndNewlines)
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
        // 無名で値も子も持たない静的テキスト (アイコンフォントなど) は情報が無いので落とす
        node.children.removeAll { $0.role == "text" && $0.title == nil && $0.value == nil && $0.children.isEmpty && !$0.matched }
        if let t = node.title {
            // 親の名前と同じ、または親の名前 (子テキストの連結であることが多い) に含まれる静的テキストの子は冗長なので落とす
            node.children.removeAll { $0.role == "text" && !$0.matched && $0.children.isEmpty && ($0.title == t || (t.count > 20 && $0.title.map { t.contains($0) } == true)) }
        }
        node.children = mergeTextRuns(node.children)
        let boring = ["group", "generic", "splitgroup", "layoutarea", "layoutitem", "unknown"].contains(node.role)
        if boring && node.title == nil && node.value == nil && !node.actionable && !node.matched {
            return node.children
        }
        return [node]
    }

    /// 連続する葉の静的テキスト (インライン装飾で分割された文の断片) を 1 ノードに結合する。
    /// 断片は元の文字列の部分文字列なので区切りを入れずにつなぐ
    static func mergeTextRuns(_ children: [Node]) -> [Node] {
        var out: [Node] = []
        var lastFrame: CGRect? = nil
        for c in children {
            let isFragment = c.role == "text" && c.children.isEmpty && !c.matched && c.value == nil && c.title != nil
            let frame = isFragment ? c.element.frame : nil
            // 同じ行にある (縦方向に重なる) 断片だけを結合する。別の段落や見出し (下の行) は結合しない
            if isFragment, let f = frame, let lf = lastFrame, let last = out.last, last.role == "text", last.children.isEmpty, !last.matched,
               last.value == nil, let lt = last.title, let ct = c.title,
               f.minY < lf.maxY, f.maxY > lf.minY, f.minX >= lf.minX - 2 {
                // 元の文字列のどちらかが空白で接していれば語の切れ目。そうでなくても横に隙間があれば別の語 (インライン装飾で分割された "may" + "disagree")
                let gap = f.minX - lf.maxX
                let touchesSpace = (last.rawTitle ?? lt).last.map { $0.isWhitespace } ?? false || (c.rawTitle ?? ct).first.map { $0.isWhitespace } ?? false
                // 高さ (文字サイズ) が明らかに違う断片は別の要素 (見出しと副題など) なので空白で区切る
                let sizeDiffers = abs(f.height - lf.height) > max(f.height, lf.height) * 0.2
                let sep = (touchesSpace || sizeDiffers || gap > 2) ? " " : ""
                let merged = Node(element: last.element, role: "text", title: lt + sep + ct, value: nil, states: [], actionable: false)
                merged.rawTitle = (last.rawTitle ?? lt) + sep + (c.rawTitle ?? ct)
                out[out.count - 1] = merged
                lastFrame = lf.union(f)
            } else {
                out.append(c)
                lastFrame = frame
            }
        }
        return out
    }

    /// ui.find: 一致ノード (とその子孫) と、そこへ至る祖先だけを残す。
    /// 葉の静的テキストだけが一致した場合は、前後の断片や隣の要素も必要なので親を一致として扱う
    static func prune(_ node: Node) -> Node? {
        if !node.matched, node.children.contains(where: { $0.matched && $0.role == "text" && $0.children.isEmpty }),
           ["group", "generic", "paragraph", "cell", "row", "listitem", "list", "heading"].contains(node.role) || node.title == nil {
            node.matched = true
        }
        if node.matched { node.children = node.children.flatMap(collapse); return node }
        // 一致した子の直前の見出し (同じ親の中) は設問番号などの文脈なので残す
        var kept: [Node] = []
        var lastHeading: Node? = nil
        for c in node.children {
            if c.role == "heading" { lastHeading = c }
            if let p = prune(c) {
                if let h = lastHeading, p.role != "heading", !(kept.last.map { $0 === h } ?? false) { kept.append(h) }
                kept.append(p); lastHeading = nil
            }
        }
        node.children = kept
        return node.children.isEmpty ? nil : node
    }

    static func render(_ node: Node, indent: Int, lines: inout [String], refs: inout [String: AXElement], counter: inout Int, options: SnapshotOptions) {
        var line = String(repeating: "  ", count: indent) + "- " + node.role
        if let t = node.title { line += " " + quote(t, limit: node.role == "text" ? options.valueLimit : max(options.valueLimit, 120)) }   // textLimit は本文用。要素名 (リンク名など) は 120 未満に切らない
        if node.actionable || node.matched {
            counter += 1
            let ref = "e\(counter)"
            node.ref = ref
            refs[ref] = node.element
            line += " [ref=\(ref)]"
        }
        for s in node.states { line += " [\(s)]" }
        if node.actionable, let f = node.element.frame {
            if f.width <= 2 || f.height <= 2 {
                // 可視領域外の要素は Chrome が幅または高さ 0 の仮の frame で報告する。クリックすれば自動でスクロールされる
                line += " [offscreen]"
            } else if node.title == nil, node.value == nil {
                // 無名の操作要素はスクリーンショットと座標で照合するしかないので、画面座標を添える
                line += " [at \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))]"
            }
        }
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
