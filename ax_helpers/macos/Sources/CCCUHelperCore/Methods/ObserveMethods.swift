import AppKit
import ApplicationServices
import Foundation

/// ui.observe / ui.unobserve: AXObserver で通知を購読し、`ax.event` として stdout に流す (PROTOCOL.md §8)。
public let defaultNotifications = [
    kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXSheetCreatedNotification,
    kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification, kAXMenuOpenedNotification,
    kAXMenuClosedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
]

final class Subscription {
    let id: String
    let pid: pid_t
    let observer: AXObserver
    let element: AXUIElement
    var notifications: [String] = []
    init(id: String, pid: pid_t, observer: AXObserver, element: AXUIElement) {
        self.id = id; self.pid = pid; self.observer = observer; self.element = element
    }
}

public final class ObserverRegistry {
    public static let shared = ObserverRegistry()
    private var subs: [String: Subscription] = [:]
    private var counter = 0
    /// 通知の送り先。既定は Transport (テストで差し替える)
    public var emit: (Response) -> Void = { Transport.send($0) }

    public func observe(pid: pid_t, notifications: [String], element: AXElement?) throws -> (id: String, accepted: [String]) {
        guard NSRunningApplication(processIdentifier: pid) != nil else { throw HelperError.notFound("pid \(pid)") }
        var obs: AXObserver?
        let err = AXObserverCreate(pid, observerCallback, &obs)
        guard err == .success, let observer = obs else {
            throw HelperError(.axError, "AXObserverCreate failed (\(err.rawValue))", data: ["axError": Int(err.rawValue)])
        }
        counter += 1
        let id = "o\(counter)"
        let target = element?.raw ?? AXUIElementCreateApplication(pid)
        let sub = Subscription(id: id, pid: pid, observer: observer, element: target)
        let ctx = Unmanaged.passUnretained(sub).toOpaque()
        var accepted: [String] = []
        for n in notifications {
            if AXObserverAddNotification(observer, target, n as CFString, ctx) == .success { accepted.append(n) }
        }
        guard !accepted.isEmpty else { throw HelperError(.unsupported, "none of the notifications could be registered") }
        sub.notifications = accepted
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        subs[id] = sub
        return (id, accepted)
    }

    public func unobserve(_ id: String) throws {
        guard let sub = subs.removeValue(forKey: id) else { throw HelperError.notFound("subscription \(id)") }
        for n in sub.notifications { AXObserverRemoveNotification(sub.observer, sub.element, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(sub.observer), .defaultMode)
    }

    public var active: [String] { subs.keys.sorted() }

    fileprivate func fire(_ sub: Subscription, _ notification: String, _ element: AXUIElement) {
        guard subs[sub.id] != nil else { return }
        let el = AXElement(element)
        var info: JSONObject = [:]
        if let r = el.role { info["role"] = SnapshotBuilder.normalizeRole(r, subrole: el.subrole) }
        if let t = el.title ?? el.descriptionText, !t.isEmpty { info["title"] = t }
        if let v = el.value as? String { info["value"] = String(v.prefix(80)) }
        else if let v = el.value { info["value"] = v }
        emit(.notification(method: "ax.event", params: [
            "subscription": sub.id, "pid": Int(sub.pid), "notification": notification, "element": info,
            "time": Date().timeIntervalSince1970,
        ]))
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon = refcon else { return }
    let sub = Unmanaged<Subscription>.fromOpaque(refcon).takeUnretainedValue()
    ObserverRegistry.shared.fire(sub, notification as String, element)
}

public func registerObserveMethods(_ d: Dispatcher) {
    d.register("ui.observe") { p in
        try Trust.require()
        let pid = pid_t(try p.int("pid"))
        let names = (p.raw["notifications"] as? [String]) ?? defaultNotifications
        let el = try p.optRef()
        let (id, accepted) = try ObserverRegistry.shared.observe(pid: pid, notifications: names, element: el)
        return ["subscription": id, "notifications": accepted] as JSONObject
    }
    d.register("ui.unobserve") { p in
        try ObserverRegistry.shared.unobserve(try p.string("subscription"))
        return [:] as JSONObject
    }
}
