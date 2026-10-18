import AppKit
import Foundation

/// セッション中にユーザーへ知らせる小さなオーバーレイ。
/// 「エージェントがこのアプリを操作中で、キーボード・マウスは遮断されている。Escape を 3 回で止められる」を
/// 画面右下に出し、残り時間を毎秒更新する。クリックは透過し、キーウィンドウにならない (操作対象の邪魔をしない)。
/// 毎秒のタイマーは期限切れ判定 (`Session.expiredNow`) も兼ねる: エージェントが止まって要求が来なくなっても、
/// 宣言した上限時間で遮断が確実に解ける。
/// CCCU_SESSION_OVERLAY=off で無効。`session.begin {overlay: false}` でも出さない
public enum SessionOverlay {
    public static var enabled: Bool = ProcessInfo.processInfo.environment["CCCU_SESSION_OVERLAY"] != "off"

    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var timer: Timer?
    private static var appInitialized = false

    /// 表示文。純粋関数 (テストから確認する)
    public static func text(appName: String, remainingSeconds: Int, blocking: Bool) -> String {
        let r = max(0, remainingSeconds)
        let clock = r >= 3600 ? String(format: "%d:%02d:%02d", r / 3600, r / 60 % 60, r % 60) : String(format: "%d:%02d", r / 60, r % 60)
        var parts = ["cccu が \(appName) を操作中", "残り \(clock)"]
        if blocking { parts.append("キーボード・マウスは遮断中") }
        parts.append("Esc を 3 回押すと中断")
        return parts.joined(separator: "  ·  ")
    }

    /// セッション開始時に呼ぶ (メインスレッド)
    static func show() {
        guard enabled, Thread.isMainThread else { return }
        ensureApp()
        if panel == nil { build() }
        refresh()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in tick() }
        // spin() は .default モードで run loop を回すので、common modes に載せれば操作中も更新される
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// セッション終了時に呼ぶ
    static func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    /// 目に入らないように一時的に隠す (画面キャプチャ用)。body の間だけ
    static func withHidden<T>(_ body: () throws -> T) rethrows -> T {
        guard let p = panel, p.isVisible else { return try body() }
        p.orderOut(nil)
        // WindowServer に反映されるまで一拍
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        defer { p.orderFrontRegardless() }
        return try body()
    }

    static var windowNumber: Int? { panel.map { $0.windowNumber } }

    private static func tick() {
        // isActive が期限切れを検出すると Session.end → hide が呼ばれる
        guard Session.isActive else { hide(); return }
        refresh()
    }

    private static func refresh() {
        guard let p = panel, let l = label, let pid = Session.pid else { return }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let remaining = Int(max(0, Session.deadline?.timeIntervalSinceNow ?? 0))
        l.stringValue = text(appName: name, remainingSeconds: remaining, blocking: Session.blocking)
        l.sizeToFit()
        let size = NSSize(width: l.frame.width + 28, height: l.frame.height + 16)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // 右下 (Dock の上)。中央や上部は操作対象のボタンに被りやすい
        let v = screen.visibleFrame
        let origin = NSPoint(x: v.maxX - size.width - 16, y: v.minY + 16)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        l.frame = NSRect(x: 14, y: 8, width: l.frame.width, height: l.frame.height)
    }

    private static func ensureApp() {
        if appInitialized { return }
        appInitialized = true
        // ウィンドウを出すには NSApplication が要る。accessory (Dock 非表示、メニューバー無し) として初期化する。
        // 自分はアクティブにならず、キーウィンドウも持たないので、対象アプリのフォーカスを奪わない
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
    }

    private static func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true           // クリックは下のウィンドウへ通す
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        p.title = "cccu session"

        let content = NSView(frame: p.contentRect(forFrameRect: p.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.75, green: 0.1, blue: 0.1, alpha: 0.92).cgColor
        content.layer?.cornerRadius = 10
        content.autoresizingMask = [.width, .height]
        content.setAccessibilityElement(false)   // AX のヒットテストから外す (下の要素を隠さない)

        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = .clear
        l.isBezeled = false
        l.drawsBackground = false
        l.setAccessibilityElement(false)
        content.addSubview(l)

        p.contentView = content
        p.setAccessibilityElement(false)
        panel = p; label = l
    }
}
