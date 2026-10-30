// Eye.swift: a picture found on the screen. find.py ported to Swift, so the eye needs no Python and no OpenCV.
// The same method (LESSONS 25, 26): a fast coarse pass on a downscaled grey copy of the screen, then the one candidate
// it likes is verified at full resolution in a small neighbourhood, and only the verified score counts. The picture is
// tried at its own size first, then half and double (a picture cut on a screen of another DPI); the first scale whose
// verified score clears the bar wins, and across screens the highest verified score wins.
// The score is TM_CCOEFF_NORMED on grey: 1.0 the same, 0 nothing alike.
import AppKit
import Accelerate
import ScreenCaptureKit

struct Grey {
    var w: Int, h: Int, px: [Float]
    // a CGImage drawn into a grey float buffer of the given size (scaled as it is drawn)
    init?(_ img: CGImage, width: Int? = nil, height: Int? = nil) {
        let W = width ?? img.width, H = height ?? img.height
        guard W > 0, H > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: W * H)
        let ok = bytes.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return nil }
        w = W; h = H
        px = [Float](repeating: 0, count: W * H)
        vDSP_vfltu8(bytes, 1, &px, 1, vDSP_Length(W * H))
    }
    init(w: Int, h: Int, px: [Float]) { self.w = w; self.h = h; self.px = px }
}

enum Eye {
    static let WORK_WIDTH = 1600.0

    // the correlation of a template at one place (x, y) of the image: TM_CCOEFF_NORMED
    static func score(_ img: Grey, _ t: Grey, _ x: Int, _ y: Int) -> Float {
        guard x >= 0, y >= 0, x + t.w <= img.w, y + t.h <= img.h else { return 0 }
        let n = Float(t.w * t.h)
        var tm: Float = 0; vDSP_meanv(t.px, 1, &tm, vDSP_Length(t.px.count))
        var si: Float = 0, sii: Float = 0, sit: Float = 0, stt: Float = 0
        for j in 0..<t.h {
            let row = (y + j) * img.w + x, trow = j * t.w
            for i in 0..<t.w {
                let a = img.px[row + i], b = t.px[trow + i] - tm
                si += a; sii += a * a; sit += a * b; stt += b * b
            }
        }
        let vi = sii - si * si / n
        guard vi > 1e-3, stt > 1e-3 else { return 0 }
        return min(1, sit / (vi * stt).squareRoot())
    }

    // the best place of a template in an image, every position: the correlation by vImage, the normalisation by
    // integral images. Returns (score, x, y) of the top-left corner.
    static func bestMatch(_ img: Grey, _ t: Grey) -> (Float, Int, Int)? {
        guard t.w >= 3, t.h >= 3, t.w <= img.w, t.h <= img.h else { return nil }
        // the kernel must be odd: pad the zero-mean template with a column / row of zeros
        let kw = t.w | 1, kh = t.h | 1
        var tm: Float = 0; vDSP_meanv(t.px, 1, &tm, vDSP_Length(t.px.count))
        var k = [Float](repeating: 0, count: kw * kh)
        var stt: Float = 0
        for j in 0..<t.h { for i in 0..<t.w { let v = t.px[j * t.w + i] - tm; k[j * kw + i] = v; stt += v * v } }
        guard stt > 1e-3 else { return nil }
        var src = img.px, out = [Float](repeating: 0, count: img.w * img.h)
        let err = src.withUnsafeMutableBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
            var bs = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(img.h), width: vImagePixelCount(img.w), rowBytes: img.w * 4)
            var bo = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(img.h), width: vImagePixelCount(img.w), rowBytes: img.w * 4)
            return vImageConvolve_PlanarF(&bs, &bo, nil, 0, 0, k, UInt32(kh), UInt32(kw), 0, vImage_Flags(kvImageEdgeExtend))
        } }
        guard err == kvImageNoError else { return nil }
        // integral images of the value and its square, one row and column of zeros in front
        let W = img.w + 1
        var s1 = [Double](repeating: 0, count: W * (img.h + 1)), s2 = s1
        for y in 0..<img.h {
            var r1 = 0.0, r2 = 0.0
            for x in 0..<img.w {
                let v = Double(img.px[y * img.w + x]); r1 += v; r2 += v * v
                s1[(y + 1) * W + x + 1] = s1[y * W + x + 1] + r1
                s2[(y + 1) * W + x + 1] = s2[y * W + x + 1] + r2
            }
        }
        let n = Double(t.w * t.h), ax = kw / 2, ay = kh / 2
        var best: (Float, Int, Int)? = nil
        for y in 0...(img.h - t.h) {
            for x in 0...(img.w - t.w) {
                let a = s1[(y + t.h) * W + x + t.w] - s1[y * W + x + t.w] - s1[(y + t.h) * W + x] + s1[y * W + x]
                let b = s2[(y + t.h) * W + x + t.w] - s2[y * W + x + t.w] - s2[(y + t.h) * W + x] + s2[y * W + x]
                let vi = b - a * a / n
                guard vi > 1e-3 else { continue }
                // vImage puts the kernel's centre on the output pixel: the top-left x sits at output x + ax
                let num = Double(out[(y + ay) * img.w + x + ax])
                let sc = Float(num / (vi * Double(stt)).squareRoot())
                if best == nil || sc > best!.0 { best = (sc, x, y) }
            }
        }
        return best
    }

    // find.py's main: the screen and the template as CGImages, pixels in, pixels out
    static func find(screen: CGImage, template: CGImage, threshold: Float) -> (x: Int, y: Int, w: Int, h: Int, score: Float)? {
        guard let full = Grey(screen) else { return nil }
        let sw = Double(screen.width), sh = Double(screen.height)
        var work = min(1.0, WORK_WIDTH / sw)
        // a big template at 1600 px is still thousands of kernel taps per pixel: keep the coarse pass quick
        let area = Double(template.width * template.height) * work * work
        if area > 2500 { work *= (2500 / area).squareRoot() }
        guard let small = Grey(screen, width: max(1, Int(sw * work)), height: max(1, Int(sh * work))) else { return nil }
        var best: (Float, Int, Int, Int, Int)? = nil
        for scale in [1.0, 0.5, 2.0] {
            let f = work * scale
            guard let t = Grey(template, width: max(3, Int(Double(template.width) * f)), height: max(3, Int(Double(template.height) * f))),
                  let m = bestMatch(small, t), m.0 >= 0.55 else { continue }
            // verify at full resolution around the coarse place: the template at this scale, a step of the coarse grid around
            let fw = max(3, Int(Double(template.width) * scale)), fh = max(3, Int(Double(template.height) * scale))
            guard let tf = scale == 1.0 ? Grey(template) : Grey(template, width: fw, height: fh) else { continue }
            let cx = Int((Double(m.1) / work).rounded()), cy = Int((Double(m.2) / work).rounded())
            let r = Int(ceil(1 / work)) + 1
            var v: (Float, Int, Int) = (0, cx, cy)
            for dy in -r...r { for dx in -r...r {
                let s = score(full, tf, cx + dx, cy + dy)
                if s > v.0 { v = (s, cx + dx, cy + dy) }
            } }
            if best == nil || v.0 > best!.0 { best = (v.0, v.1, v.2, tf.w, tf.h) }
            if v.0 >= threshold { break }     // a real match at this scale; no other scale may steal it
        }
        guard let b = best, b.0 >= threshold else { return nil }
        return (b.1, b.2, b.3, b.4, b.0)
    }

    // MARK: the screens

    // every display with its frame in global points (top-left origin, the coordinates clicks use)
    static func displays() -> [(id: CGDirectDisplayID, frame: CGRect)] {
        var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n)); CGGetActiveDisplayList(n, &ids, &n)
        return ids.map { ($0, CGDisplayBounds($0)) }
    }

    // a shot of a rectangle in global points, at the screen's own pixels. Blocks the calling thread (not the main one).
    static func shot(_ rect: CGRect) -> CGImage? {
        guard let d = displays().first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) ?? displays().first else { return nil }
        let local = rect.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY).intersection(CGRect(origin: .zero, size: d.frame.size))
        guard !local.isEmpty else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var out: CGImage?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let disp = content?.displays.first(where: { $0.displayID == d.id }) else { sem.signal(); return }
            let filter = SCContentFilter(display: disp, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let ps = CGDisplayCopyDisplayMode(d.id).map { Double($0.pixelWidth) / Double(d.frame.width) } ?? 2
            cfg.sourceRect = local
            cfg.width = max(1, Int(local.width * ps)); cfg.height = max(1, Int(local.height * ps))
            cfg.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in out = img; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    static func load(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // SEARCH THE SCREENS for a template file: one rectangle, or every screen. The best across the screens, in points.
    static func search(_ path: String, region: CGRect?, threshold: Float = 0.85) -> ImageHit? {
        guard let tpl = load(path) else { return nil }
        let rects = region.map { [$0] } ?? displays().map { $0.frame }
        var best: ImageHit?
        for r in rects {
            guard let img = shot(r), let m = find(screen: img, template: tpl, threshold: threshold) else { continue }
            let s = Double(img.width) / r.width            // pixels over points (LESSONS 17)
            let hit = ImageHit(x: (r.minX + Double(m.x) / s).rounded(), y: (r.minY + Double(m.y) / s).rounded(),
                               w: (Double(m.w) / s).rounded(), h: (Double(m.h) / s).rounded(), score: Double(m.score))
            if best == nil || hit.score > best!.score { best = hit }
        }
        return best
    }

    // the colour of one point, "0xRRGGBB"
    static func pixel(_ x: Double, _ y: Double) -> String {
        guard let img = shot(CGRect(x: x, y: y, width: 1, height: 1)) else { return "0x000000" }
        var p = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "0x000000" }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "0x%02X%02X%02X", p[0], p[1], p[2])
    }
}
