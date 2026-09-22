import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// screen.capture: ウィンドウ / ディスプレイの PNG を返す。Screen Recording 権限が必要。
public func registerScreenMethods(_ d: Dispatcher) {
    d.register("screen.capture") { p in
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw HelperError(.notTrusted, "Screen Recording not permitted",
                              data: ["permission": "screenRecording",
                                     "hint": "System Settings > Privacy & Security > Screen Recording: allow the app that launched Claude Code"])
        }
        let maxWidth = p.optInt("maxWidth") ?? 1600
        let image: CGImage
        let frame: CGRect
        if let pid = p.optInt("pid") {
            let app = AXElement.application(pid: pid_t(pid))
            let windows = app.elements(kAXWindowsAttribute)
            let w: AXElement
            if let wn = p.optInt("windowNumber") {
                guard let found = windows.first(where: { $0.windowNumber == wn }) else { throw HelperError.notFound("window \(wn) in pid \(pid)") }
                w = found
            } else {
                guard let found = windows.first(where: { $0.isMainWindow }) ?? windows.first else { throw HelperError.notFound("window of pid \(pid)") }
                w = found
            }
            guard w.windowNumber != 0, let f = w.frame else { throw HelperError(.unsupported, "window has no capturable id") }
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                throw HelperError(.axError, "CGWindowListCreateImage failed")
            }
            image = img; frame = f
        } else {
            let displayID = p.optInt("display").map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
            guard let img = CGDisplayCreateImage(displayID) else { throw HelperError.notFound("display") }
            image = img; frame = CGDisplayBounds(displayID)
        }
        let scaled = downscale(image, maxWidth: maxWidth)
        guard let png = pngData(scaled) else { throw HelperError(.internalError, "PNG encoding failed") }
        return [
            "pngBase64": png.base64EncodedString(),
            "scale": frame.width > 0 ? Double(scaled.width) / Double(frame.width) : 1,
            "frame": AXJSON.rect(frame),
            "width": scaled.width, "height": scaled.height,
        ] as JSONObject
    }
}

func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
    guard image.width > maxWidth, maxWidth > 0 else { return image }
    let scale = Double(maxWidth) / Double(image.width)
    let w = maxWidth, h = Int(Double(image.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? image
}

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}
