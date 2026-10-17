import Foundation

/// AX ツリーに対する CSS セレクタ風のクエリ言語。
///
///   button[name*="確認"]:enabled              名前に「確認」を含む有効なボタン
///   group:has("正解は") button                「正解は」を含む group の子孫のボタン
///   heading[name^="Q3"] ~ group button        見出し Q3 の後続の兄弟 group 内のボタン
///   webarea >> link[name$="スタート"]          深さを問わない子孫 (空白と同じ)
///   "次へ進む"                                 名前 (または子テキストの連結) に含む要素
///
/// 文法:
///   selector  := complex ("," complex)*
///   complex   := compound ((">" | ">>" | "+" | "~" | 空白) compound)*
///   compound  := (role | "*" | 文字列)? ("[" attr op 文字列 "]")* (":" pseudo)*
///   attr      := name | value | role | text            (text = name または子テキストの連結)
///   op        := "=" (完全一致、大小無視) | "*=" (含む) | "^=" (前方) | "$=" (後方)
///   pseudo    := enabled | disabled | focused | selected | checked | unchecked | expanded | collapsed
///              | has(selector) | not(compound)
/// 評価はスナップショットの生ツリー (整形で畳まれる無名の group も含む) に対して行う。子セレクタ ">" は厳密な親子なので、
/// 通常は子孫セレクタ (空白 / ">>") を使う
public enum Query {
    public struct Selector {
        let alternatives: [Complex]
        func matches(_ n: Node) -> Bool { alternatives.contains { $0.matches(n) } }
    }
    enum Combinator { case descendant, child, next, subsequent }
    struct Complex {
        var parts: [(Combinator?, Compound)]   // 先頭の combinator は nil
        func matches(_ n: Node) -> Bool { matches(n, index: parts.count - 1) }
        private func matches(_ n: Node, index: Int) -> Bool {
            let (comb, compound) = parts[index]
            guard compound.matches(n) else { return false }
            guard index > 0, let c = comb else { return index == 0 }
            switch c {
            case .child:
                guard let p = n.parent else { return false }
                return matches(p, index: index - 1)
            case .descendant:
                var cur = n.parent
                while let p = cur { if matches(p, index: index - 1) { return true }; cur = p.parent }
                return false
            case .next:
                guard let s = n.previousSibling else { return false }
                return matches(s, index: index - 1)
            case .subsequent:
                var cur = n.previousSibling
                while let s = cur { if matches(s, index: index - 1) { return true }; cur = s.previousSibling }
                return false
            }
        }
    }
    enum Op { case equals, contains, prefix, suffix }
    indirect enum Pseudo {
        case state(String, Bool)   // ("disabled", true) など。states 配列との照合
        case has(Selector)
        case not(Compound)
    }
    struct Compound {
        var role: String?
        var attrs: [(String, Op, String)] = []
        var pseudos: [Pseudo] = []

        func matches(_ n: Node) -> Bool {
            if let r = role, r != "*", n.role != r { return false }
            for (attr, op, want) in attrs {
                let have: [String]
                switch attr {
                case "name", "title": have = [n.title ?? ""]
                case "value": have = [(n.value as? String) ?? n.value.map { "\($0)" } ?? ""]
                case "role": have = [n.role]
                case "text": have = [n.title ?? "", n.blockText]
                default: return false
                }
                if !have.contains(where: { Query.compare($0, op, want) }) { return false }
            }
            for p in pseudos {
                switch p {
                case .state(let s, let present): if n.states.contains(s) != present { return false }
                case .has(let sel): if !Query.anyDescendant(of: n, matches: sel) { return false }
                case .not(let c): if c.matches(n) { return false }
                }
            }
            return true
        }
    }

    static func compare(_ s: String, _ op: Op, _ q: String) -> Bool {
        switch op {
        case .equals: return s.caseInsensitiveCompare(q) == .orderedSame
        case .contains: return s.localizedCaseInsensitiveContains(q)
        case .prefix: return s.lowercased().hasPrefix(q.lowercased())
        case .suffix: return s.lowercased().hasSuffix(q.lowercased())
        }
    }
    static func anyDescendant(of n: Node, matches sel: Selector) -> Bool {
        for c in n.children { if sel.matches(c) || anyDescendant(of: c, matches: sel) { return true } }
        return false
    }

    // MARK: パーサ

    public static func parse(_ source: String) throws -> Selector {
        var p = Parser(Array(source))
        let sel = try p.selector()
        p.skipSpace()
        if !p.atEnd { throw HelperError.invalidParams("selector: unexpected '\(p.peek!)' at \(p.i)") }
        return sel
    }

    struct Parser {
        let s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }
        var atEnd: Bool { i >= s.count }
        var peek: Character? { atEnd ? nil : s[i] }
        mutating func skipSpace() { while let c = peek, c.isWhitespace { i += 1 } }
        mutating func take(_ str: String) -> Bool {
            let cs = Array(str)
            guard i + cs.count <= s.count, Array(s[i..<i + cs.count]) == cs else { return false }
            i += cs.count; return true
        }

        mutating func selector() throws -> Selector {
            var alts = [try complex()]
            skipSpace()
            while take(",") { alts.append(try complex()); skipSpace() }
            return Selector(alternatives: alts)
        }
        mutating func complex() throws -> Complex {
            skipSpace()
            var parts: [(Combinator?, Compound)] = [(nil, try compound())]
            while true {
                let hadSpace = peek?.isWhitespace ?? false
                skipSpace()
                guard let c = peek, c != "," , c != ")" else { break }
                var comb: Combinator
                if take(">>") { comb = .descendant }
                else if take(">") { comb = .child }
                else if take("+") { comb = .next }
                else if take("~") { comb = .subsequent }
                else if hadSpace { comb = .descendant }
                else { throw HelperError.invalidParams("selector: unexpected '\(c)' at \(i)") }
                skipSpace()
                parts.append((comb, try compound()))
            }
            return Complex(parts: parts)
        }
        mutating func compound() throws -> Compound {
            var c = Compound()
            var any = false
            if peek == "*" { i += 1; c.role = "*"; any = true }
            else if let q = try quoted() { c.attrs.append(("text", .contains, q)); any = true }
            else if let id = ident() { c.role = id.lowercased(); any = true }
            while let ch = peek {
                if ch == "[" {
                    i += 1; skipSpace()
                    guard let attr = ident() else { throw HelperError.invalidParams("selector: attribute name expected at \(i)") }
                    skipSpace()
                    let op: Op
                    if take("*=") { op = .contains } else if take("^=") { op = .prefix } else if take("$=") { op = .suffix }
                    else if take("=") { op = .equals } else { throw HelperError.invalidParams("selector: operator expected after [\(attr) at \(i)") }
                    skipSpace()
                    let val: String
                    if let q = try quoted() { val = q } else if let id = ident() { val = id } else { throw HelperError.invalidParams("selector: value expected at \(i)") }
                    skipSpace()
                    guard take("]") else { throw HelperError.invalidParams("selector: ']' expected at \(i)") }
                    c.attrs.append((attr.lowercased(), op, val)); any = true
                } else if ch == ":" {
                    i += 1
                    guard let name = ident()?.lowercased() else { throw HelperError.invalidParams("selector: pseudo-class name expected at \(i)") }
                    switch name {
                    case "enabled": c.pseudos.append(.state("disabled", false))
                    case "disabled", "focused", "selected", "checked", "expanded", "collapsed": c.pseudos.append(.state(name, true))
                    case "unchecked": c.pseudos.append(.state("checked", false))
                    case "has":
                        guard take("(") else { throw HelperError.invalidParams("selector: '(' expected after :has") }
                        let inner = try selector(); skipSpace()
                        guard take(")") else { throw HelperError.invalidParams("selector: ')' expected at \(i)") }
                        c.pseudos.append(.has(inner))
                    case "not":
                        guard take("(") else { throw HelperError.invalidParams("selector: '(' expected after :not") }
                        skipSpace(); let inner = try compound(); skipSpace()
                        guard take(")") else { throw HelperError.invalidParams("selector: ')' expected at \(i)") }
                        c.pseudos.append(.not(inner))
                    default: throw HelperError.invalidParams("selector: unknown pseudo-class :\(name)")
                    }
                    any = true
                } else { break }
            }
            guard any else { throw HelperError.invalidParams("selector: element expected at \(i)") }
            return c
        }
        mutating func ident() -> String? {
            var out = ""
            while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" { out.append(c); i += 1 }
            return out.isEmpty ? nil : out
        }
        mutating func quoted() throws -> String? {
            guard let q = peek, q == "\"" || q == "'" else { return nil }
            i += 1
            var out = ""
            while let c = peek {
                i += 1
                if c == "\\", let n = peek { out.append(n); i += 1; continue }
                if c == q { return out }
                out.append(c)
            }
            throw HelperError.invalidParams("selector: unterminated string")
        }
    }
}
