import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// `cccu-helper --setup-permissions`: 必要な権限を一通り要求し、システム設定の該当ペインを開いて付与を待つ。
/// `cccu-helper --permissions`: 現在の状態を JSON で出す。
public enum PermissionSetup {
    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public static func status() -> [String: Bool] {
        ["accessibility": Trust.isTrusted, "screenRecording": CGPreflightScreenCaptureAccess()]
    }

    /// 戻り値: 全て付与済みなら 0
    public static func run(timeout: TimeInterval, wantScreen: Bool) -> Int32 {
        var st = status()
        print("cccu-helper permissions: accessibility=\(st["accessibility"]!) screenRecording=\(st["screenRecording"]!)")
        if st["accessibility"]! && (!wantScreen || st["screenRecording"]!) { print("all set"); return 0 }

        if !st["accessibility"]! {
            print("→ requesting Accessibility (a system dialog appears; allow \"cccu-helper\")")
            _ = Trust.request()
            openPane(accessibilityPane)
        }
        if wantScreen && !st["screenRecording"]! {
            print("→ requesting Screen Recording (needed only for desktop screenshots)")
            // 画面収録のプロンプトは WindowServer に接続したアプリを前提にしている可能性があるため、
            // セットアップ時は NSApplication を accessory (Dock 非表示) として初期化しておく
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
            let asked = CGRequestScreenCaptureAccess()
            print("  CGRequestScreenCaptureAccess -> \(asked), preflight -> \(CGPreflightScreenCaptureAccess())")
            // macOS 15 では ScreenCaptureKit 経由の要求で TCC に項目が登録される
            let done = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let e = error as NSError? { print("  SCShareableContent error: domain=\(e.domain) code=\(e.code) \(e.localizedDescription)") }
                else { print("  SCShareableContent ok: \(content?.displays.count ?? 0) displays, \(content?.windows.count ?? 0) windows") }
                done.signal()
            }
            let until = Date().addingTimeInterval(5)
            while done.wait(timeout: .now()) == .timedOut && Date() < until {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            let img = CGWindowListCreateImage(CGRect(x: 0, y: 0, width: 2, height: 2), .optionOnScreenOnly, kCGNullWindowID, [])
            print("  CGWindowListCreateImage -> \(img == nil ? "nil" : "\(img!.width)x\(img!.height)")")
            openPane(screenPane)
        }
        print("waiting up to \(Int(timeout))s for you to allow cccu-helper in System Settings…")
        let deadline = Date().addingTimeInterval(timeout)
        var lastLine = ""
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))
            st = status()
            let line = "  accessibility=\(st["accessibility"]!) screenRecording=\(st["screenRecording"]!)"
            if line != lastLine { print(line); lastLine = line }
            if st["accessibility"]! && (!wantScreen || st["screenRecording"]!) { print("all set"); return 0 }
        }
        print("still missing: " + (st["accessibility"]! ? "" : "Accessibility ") + (wantScreen && !st["screenRecording"]! ? "Screen Recording" : ""))
        print("you can grant later; nothing else needs restarting. Re-run: bin/cccu permissions")
        return 1
    }

    static func openPane(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
