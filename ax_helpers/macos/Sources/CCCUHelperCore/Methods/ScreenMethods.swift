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
                                     "hint": "System Settings > Privacy & Security > Screen Recording: allow \"cccu-helper\" (no terminal restart needed)"])
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
        var scaled = downscale(image, maxWidth: maxWidth)
        // 座標グリッド: AX ツリーが壊れているときに、画像から画面座標を読み取ってクリックするためのフォールバック
        if let grid = p.optInt("grid"), grid >= 20 {
            scaled = drawGrid(on: scaled, frame: frame, spacing: CGFloat(grid))
        }
        guard let png = pngData(scaled) else { throw HelperError(.internalError, "PNG encoding failed") }
        return [
            "pngBase64": png.base64EncodedString(),
            "scale": frame.width > 0 ? Double(scaled.width) / Double(frame.width) : 1,
            "frame": AXJSON.rect(frame),
            "width": scaled.width, "height": scaled.height,
        ] as JSONObject
    }
}

/// 画面座標のグリッド線とラベルを描く。`frame` は画像が写している画面領域、ラベルは画面座標 (スナップショットの `[at x,y]` と同じ系)
func drawGrid(on image: CGImage, frame: CGRect, spacing: CGFloat) -> CGImage {
    let w = image.width, h = image.height
    guard frame.width > 0, frame.height > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let sx = CGFloat(w) / frame.width, sy = CGFloat(h) / frame.height
    // CGContext は左下原点。画面座標 (左上原点) の y を画像の y に変換する
    func ix(_ x: CGFloat) -> CGFloat { (x - frame.minX) * sx }
    func iy(_ y: CGFloat) -> CGFloat { CGFloat(h) - (y - frame.minY) * sy }
    ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.8, alpha: 0.55))
    ctx.setLineWidth(1)
    let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
    // CTLineDraw はコンテキストの状態を変え、その後の線が描かれなくなるので、ラベルは状態を保存して描き、線を先に全部描く
    func label(_ text: String, at p: CGPoint) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.setFillColor(CGColor(red: 0.6, green: 0, blue: 0.5, alpha: 0.85))
        ctx.fill(CGRect(x: p.x, y: p.y - 2, width: bounds.width + 4, height: bounds.height + 3))
        ctx.textPosition = CGPoint(x: p.x + 2, y: p.y)
        CTLineDraw(line, ctx)
    }
    let x0 = (frame.minX / spacing).rounded(.up) * spacing
    let y0 = (frame.minY / spacing).rounded(.up) * spacing
    var x = x0
    while x <= frame.maxX { ctx.move(to: CGPoint(x: ix(x), y: 0)); ctx.addLine(to: CGPoint(x: ix(x), y: CGFloat(h))); ctx.strokePath(); x += spacing }
    var y = y0
    while y <= frame.maxY { ctx.move(to: CGPoint(x: 0, y: iy(y))); ctx.addLine(to: CGPoint(x: CGFloat(w), y: iy(y))); ctx.strokePath(); y += spacing }
    x = x0
    while x <= frame.maxX { label("\(Int(x))", at: CGPoint(x: ix(x) + 1, y: CGFloat(h) - 14)); x += spacing }
    y = y0
    while y <= frame.maxY { label("\(Int(y))", at: CGPoint(x: 1, y: iy(y) - 13)); y += spacing }
    return ctx.makeImage() ?? image
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
