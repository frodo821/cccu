import ApplicationServices
import Foundation

/// CF 値 ⇄ JSON 値の変換。`ui.attributes` / `ui.setAttribute` の汎用パススルーを支える。
public enum AXJSON {
    public static func fromCF(_ v: CFTypeRef) -> Any {
        let id = CFGetTypeID(v)
        switch id {
        case CFStringGetTypeID(): return v as! String
        case CFAttributedStringGetTypeID(): return (v as! NSAttributedString).string
        case CFBooleanGetTypeID(): return CFBooleanGetValue((v as! CFBoolean))
        case CFNumberGetTypeID(): return (v as! NSNumber).doubleValue
        case CFURLGetTypeID(): return (v as! URL).absoluteString
        case CFArrayGetTypeID(): return ((v as? [AnyObject]) ?? []).map { fromCF($0) }
        case AXUIElementGetTypeID():
            let e = AXElement(v as! AXUIElement)
            var o: JSONObject = ["element": true]
            if let r = e.role { o["role"] = r }
            if let t = e.title { o["title"] = t }
            return o
        case AXValueGetTypeID():
            let ax = v as! AXValue
            switch AXValueGetType(ax) {
            case .cgPoint: var p = CGPoint.zero; AXValueGetValue(ax, .cgPoint, &p); return ["x": p.x, "y": p.y]
            case .cgSize: var s = CGSize.zero; AXValueGetValue(ax, .cgSize, &s); return ["w": s.width, "h": s.height]
            case .cgRect: var r = CGRect.zero; AXValueGetValue(ax, .cgRect, &r); return rect(r)
            case .cfRange: var r = CFRange(); AXValueGetValue(ax, .cfRange, &r); return ["location": r.location, "length": r.length]
            case .axError: var e = AXError.success; AXValueGetValue(ax, .axError, &e); return ["axError": Int(e.rawValue)]
            default: return NSNull()
            }
        default:
            return String(describing: v)
        }
    }

    public static func rect(_ r: CGRect) -> JSONObject {
        ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height]
    }

    /// JSON 値を AX 属性設定用の CF 値へ。{x,y} / {x,y,w,h} / {location,length} は AXValue になる。
    public static func toCF(_ v: Any) throws -> CFTypeRef {
        switch v {
        case let s as String: return s as CFString
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n }   // Bool
            return n
        case let o as JSONObject:
            func num(_ k: String) -> CGFloat? { (o[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
            if let x = num("x"), let y = num("y") {
                if let w = num("w"), let h = num("h") {
                    var r = CGRect(x: x, y: y, width: w, height: h)
                    return AXValueCreate(.cgRect, &r)!
                }
                var p = CGPoint(x: x, y: y)
                return AXValueCreate(.cgPoint, &p)!
            }
            if let loc = o["location"] as? NSNumber, let len = o["length"] as? NSNumber {
                var r = CFRange(location: loc.intValue, length: len.intValue)
                return AXValueCreate(.cfRange, &r)!
            }
            throw HelperError.invalidParams("unsupported object value for attribute")
        default:
            throw HelperError.invalidParams("unsupported value type \(type(of: v))")
        }
    }
}
