import AppKit
import ApplicationServices
import Foundation

public func registerWindowMethods(_ d: Dispatcher) {
    d.register("window.list") { p in
        try Trust.require()
        let apps: [NSRunningApplication]
        if let pid = p.optInt("pid") {
            guard let a = NSRunningApplication(processIdentifier: pid_t(pid)) else { throw HelperError.notFound("pid \(pid)") }
            apps = [a]
        } else {
            apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        }
        var windows: [JSONObject] = []
        for app in apps {
            let ax = AXElement.application(pid: app.processIdentifier)
            let front = isFrontmost(app.processIdentifier)
            for w in ax.elements(kAXWindowsAttribute) {
                windows.append([
                    "pid": Int(app.processIdentifier),
                    "windowNumber": w.windowNumber,
                    "title": w.title ?? "",
                    "frame": w.frame.map(AXJSON.rect) ?? AXJSON.rect(.zero),
                    "focused": front && w.isMainWindow,
                    "minimized": w.bool(kAXMinimizedAttribute) ?? false,
                ])
            }
        }
        return ["windows": windows] as JSONObject
    }

    d.register("window.raise") { p in
        try Trust.require()
        let pid = pid_t(try p.int("pid"))
        let wn = try p.int("windowNumber")
        let app = AXElement.application(pid: pid)
        guard let w = app.elements(kAXWindowsAttribute).first(where: { $0.windowNumber == wn }) else {
            throw HelperError.notFound("window \(wn) in pid \(pid)")
        }
        if w.bool(kAXMinimizedAttribute) == true { try? w.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        try w.perform(kAXRaiseAction)
        activate(pid)
        return [:] as JSONObject
    }
}
