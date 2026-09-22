import ApplicationServices
import Foundation

/// AXUIElement の薄いラッパー。属性の読み書きとアクション実行、生存確認を提供する。
public struct AXElement {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }
    public static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    public var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(raw, &p)
        return p
    }

    // MARK: 属性

    public func attribute(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, name as CFString, &v)
        return err == .success ? v : nil
    }

    public func attributeNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(raw, name as CFString, &settable) == .success && settable.boolValue
    }

    public func string(_ name: String) -> String? {
        guard let v = attribute(name) else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() { return v as? String }
        if CFGetTypeID(v) == CFAttributedStringGetTypeID() { return (v as? NSAttributedString)?.string }
        return nil
    }
    public func bool(_ name: String) -> Bool? {
        guard let v = attribute(name), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }
    public func number(_ name: String) -> Double? {
        guard let v = attribute(name), CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
        return (v as? NSNumber)?.doubleValue
    }
    public func element(_ name: String) -> AXElement? {
        guard let v = attribute(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXElement(v as! AXUIElement)
    }
    public func elements(_ name: String) -> [AXElement] {
        guard let v = attribute(name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return ((v as? [AnyObject]) ?? []).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? AXElement($0 as! AXUIElement) : nil }
    }
    public func rect(_ name: String) -> CGRect? {
        guard let v = attribute(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue((v as! AXValue), .cgRect, &r) ? r : nil
    }

    // よく使う属性
    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var descriptionText: String? { string(kAXDescriptionAttribute) }
    public var children: [AXElement] { elements(kAXChildrenAttribute) }
    public var frame: CGRect? { rect("AXFrame") }
    public var isEnabled: Bool { bool(kAXEnabledAttribute) ?? true }
    public var isFocused: Bool { bool(kAXFocusedAttribute) ?? false }

    /// AXValue を JSON 化した値 (String / Bool / Double / nil)
    public var value: Any? { attribute(kAXValueAttribute).map(AXJSON.fromCF) }

    // MARK: 生存確認

    /// 要素がまだ存在するか。AXRole の取得結果で判定する。
    public var isAlive: Bool {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &v)
        return err != .invalidUIElement && err != .cannotComplete
    }

    // MARK: 操作

    public func perform(_ action: String) throws {
        let err = AXUIElementPerformAction(raw, action as CFString)
        try AXErrorMapper.check(err, context: "perform \(action)")
    }

    public func set(_ name: String, _ value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(raw, name as CFString, value)
        try AXErrorMapper.check(err, context: "set \(name)")
    }
}

enum AXErrorMapper {
    static func check(_ err: AXError, context: String) throws {
        switch err {
        case .success: return
        case .invalidUIElement: throw HelperError(.staleRef, "\(context): element no longer exists")
        case .actionUnsupported, .attributeUnsupported, .illegalArgument:
            throw HelperError(.unsupported, "\(context): unsupported (\(err.rawValue))", data: ["axError": Int(err.rawValue)])
        case .apiDisabled, .notImplemented:
            throw HelperError(.notTrusted, "\(context): accessibility API disabled", data: ["axError": Int(err.rawValue)])
        default:
            throw HelperError(.axError, "\(context): AXError \(err.rawValue)", data: ["axError": Int(err.rawValue)])
        }
    }
}
