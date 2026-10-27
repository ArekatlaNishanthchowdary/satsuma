import AppKit
import UniformTypeIdentifiers

/// Slider values, each −100…100; all zero leaves the picture untouched.
struct Adjustments: Equatable {
    var exposure = 0.0, brightness = 0.0, contrast = 0.0, saturation = 0.0, temperature = 0.0, highlights = 0.0, shadows = 0.0
    var isIdentity: Bool { self == Adjustments() }
}

enum RedactStyle: String, CaseIterable { case pixelate = "Pixelate", blur = "Blur", black = "Black" }
enum MarkKind: String, CaseIterable { case arrow = "Arrow", box = "Box", pen = "Pen", text = "Text" }

/// One annotation in image pixels (top-left origin). Pen uses every point, the others the first and last.
struct Mark {
    var kind: MarkKind
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
}

/// ratio 0 = fit the picture; padding and corner are fractions of the picture's longer side.
struct BackgroundStyle {
    var from: NSColor, to: NSColor
    var padding: CGFloat = 0.08, corner: CGFloat = 0.03, shadow = true, ratio: CGFloat = 0
}

/// Pure image edits behind the editor windows. Geometry is in the image's own pixels, origin top-left.
enum ImageEdit {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An RGBA8 canvas whose memory starts at the top row; `flipped` makes drawing use top-left coordinates too.
    static func canvas(_ w: Int, _ h: Int, flipped: Bool = false) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Fail("Out of memory") }
        if flipped { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) }
        return ctx
    }

    static func pixels(_ image: CGImage) throws -> (CGContext, UnsafeMutablePointer<UInt8>) {
        let ctx = try canvas(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (ctx, ctx.data!.assumingMemoryBound(to: UInt8.self))
    }

    static func shrink(_ image: CGImage, maxSide: Int) throws -> (CGImage, CGFloat) {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        if scale >= 1 { return (image, 1) }
        let ctx = try canvas(Int(CGFloat(image.width) * scale), Int(CGFloat(image.height) * scale))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return (ctx.makeImage()!, scale)
    }

    static func adjust(_ image: CGImage, _ a: Adjustments) throws -> CGImage {
        if a.isIdentity { return image }
        let (ctx, px) = try pixels(image)
        let gain = pow(2, a.exposure / 50), lift = a.brightness / 250, contrast = 1 + a.contrast / 100
        let sat = 1 + a.saturation / 100, warm = a.temperature / 1000, hi = a.highlights / 330, lo = a.shadows / 330
        func clamp(_ v: Double) -> UInt8 { UInt8((min(1, max(0, v)) * 255).rounded()) }
        DispatchQueue.concurrentPerform(iterations: image.height) { y in
            for i in stride(from: y * image.width * 4, to: (y + 1) * image.width * 4, by: 4) {
                let alpha = Double(px[i + 3]) / 255
                guard alpha > 0 else { continue }
                // Un-premultiply so the maths matches the Windows version, which works on straight alpha.
                var r = Double(px[i]) / 255 / alpha, g = Double(px[i + 1]) / 255 / alpha, b = Double(px[i + 2]) / 255 / alpha
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                // Highlights/shadows push the bright/dark end; the squared weight leaves midtones mostly alone.
                let tone = lift + hi * l * l + lo * (1 - l) * (1 - l)
                func t(_ v: Double) -> Double { ((v * gain + tone) - 0.5) * contrast + 0.5 }
                (r, g, b) = (t(r) + warm, t(g), t(b) - warm)
                let gray = 0.2126 * r + 0.7152 * g + 0.0722 * b
                px[i] = clamp((gray + (r - gray) * sat) * alpha)
                px[i + 1] = clamp((gray + (g - gray) * sat) * alpha)
                px[i + 2] = clamp((gray + (b - gray) * sat) * alpha)
            }
        }
        return ctx.makeImage()!
    }

    static func clampRect(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
        let r = r.standardized.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return r.isNull || r.width < 1 || r.height < 1 ? CGRect(x: 0, y: 0, width: 1, height: 1) : r
    }

    static func crop(_ image: CGImage, _ r: CGRect) throws -> CGImage {
        guard let c = image.cropping(to: clampRect(r, image.width, image.height)) else { throw Fail("Couldn't crop") }
        return c
    }

    static func redact(_ image: CGImage, _ boxes: [CGRect], _ style: RedactStyle) throws -> CGImage {
        let (ctx, px) = try pixels(image)
        let w = image.width, block = max(6, max(w, image.height) / 60)
        for box in boxes {
            let r = clampRect(box, w, image.height)
            let x0 = Int(r.minX), y0 = Int(r.minY), x1 = Int(r.maxX), y1 = Int(r.maxY)
            switch style {
            case .black:
                for y in y0..<y1 { for x in x0..<x1 { let i = (y * w + x) * 4; px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 255 } }
            case .blur:
                for _ in 0..<3 { boxBlur(px, w, x0, y0, x1, y1, block, horizontal: true); boxBlur(px, w, x0, y0, x1, y1, block, horizontal: false) }
            case .pixelate:
                for by in stride(from: y0, to: y1, by: block) {
                    for bx in stride(from: x0, to: x1, by: block) {
                        let ex = min(bx + block, x1), ey = min(by + block, y1), n = (ex - bx) * (ey - by)
                        var sum = [Int](repeating: 0, count: 4)
                        for y in by..<ey { for x in bx..<ex { for c in 0..<4 { sum[c] += Int(px[(y * w + x) * 4 + c]) } } }
                        for y in by..<ey { for x in bx..<ex { for c in 0..<4 { px[(y * w + x) * 4 + c] = UInt8(sum[c] / n) } } }
                    }
                }
            }
        }
        return ctx.makeImage()!
    }

    /// One running-sum pass along rows or columns, kept inside the box so nothing outside leaks in.
    private static func boxBlur(_ px: UnsafeMutablePointer<UInt8>, _ w: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ radius: Int, horizontal: Bool) {
        let lines = horizontal ? y1 - y0 : x1 - x0, len = horizontal ? x1 - x0 : y1 - y0
        guard len > 0 else { return }
        func index(_ l: Int, _ k: Int) -> Int { horizontal ? ((y0 + l) * w + x0 + k) * 4 : ((y0 + k) * w + x0 + l) * 4 }
        var line = [UInt8](repeating: 0, count: len * 4)
        for l in 0..<lines {
            for k in 0..<len { for c in 0..<4 { line[k * 4 + c] = px[index(l, k) + c] } }
            for c in 0..<4 {
                var sum = 0
                for k in -radius...radius { sum += Int(line[min(max(k, 0), len - 1) * 4 + c]) }
                for k in 0..<len {
                    px[index(l, k) + c] = UInt8(sum / (2 * radius + 1))
                    sum += Int(line[min(k + radius + 1, len - 1) * 4 + c]) - Int(line[max(k - radius, 0) * 4 + c])
                }
            }
        }
    }

    static func annotate(_ image: CGImage, _ marks: [Mark]) throws -> CGImage {
        let ctx = try canvas(image.width, image.height, flipped: true)
        // Images draw upside down in a flipped context, so flip them back locally.
        ctx.saveGState(); ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        marks.forEach(draw)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// Draws into the current (flipped, top-left) graphics context.
    static func draw(_ m: Mark) {
        guard let a = m.points.first, let b = m.points.last else { return }
        m.color.set()
        let path = NSBezierPath()
        path.lineWidth = m.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch m.kind {
        case .pen:
            path.move(to: a)
            m.points.dropFirst().forEach(path.line)
        case .box:
            path.appendRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .arrow:
            path.move(to: a); path.line(to: b)
            let len = hypot(a.x - b.x, a.y - b.y)
            if len >= 1 {
                let dx = (a.x - b.x) / len, dy = (a.y - b.y) / len, head = max(10, m.width * 4)
                for turn in [CGFloat.pi * 28 / 180, -.pi * 28 / 180] {
                    path.move(to: b)
                    path.line(to: CGPoint(x: b.x + (dx * cos(turn) - dy * sin(turn)) * head, y: b.y + (dx * sin(turn) + dy * cos(turn)) * head))
                }
            }
        case .text:
            NSAttributedString(string: m.text, attributes: [.font: NSFont.systemFont(ofSize: max(12, m.width * 6), weight: .bold),
                                                            .foregroundColor: m.color]).draw(at: a)
            return
        }
        path.stroke()
    }

    static func addBackground(_ image: CGImage, _ bg: BackgroundStyle) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height), side = max(w, h)
        let pad = side * bg.padding, corner = side * bg.corner
        var cw = w + 2 * pad, ch = h + 2 * pad
        if bg.ratio > 0 { if cw / ch < bg.ratio { cw = ch * bg.ratio } else { ch = cw / bg.ratio } }
        let ctx = try canvas(Int(cw.rounded()), Int(ch.rounded()))
        let full = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let gradient = CGGradient(colorsSpace: srgb, colors: [bg.from.cgColor, bg.to.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: full.height), end: CGPoint(x: full.width, y: 0), options: [])
        let rect = CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h)
        let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        if bg.shadow {
            // Core Graphics blurs shadows for real, unlike the stacked plates on Windows.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.015), blur: side * 0.04, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(shape); ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()!
    }

    /// JPEG bytes no bigger than `target`: binary-search the quality, then shrink if even 0.1 is too big.
    static func encodeUnder(_ image: CGImage, target: Int) throws -> Data {
        func encode(_ img: CGImage, _ q: Double) -> Data {
            let data = NSMutableData()
            let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return data as Data
        }
        var img = try Img.flatten(image)
        for _ in 0..<12 {
            var best: Data?, lo = 10, hi = 95
            while lo <= hi {
                let q = (lo + hi) / 2, data = encode(img, Double(q) / 100)
                if data.count <= target { best = data; lo = q + 1 } else { hi = q - 1 }
            }
            if let best { return best }
            img = try shrink(img, maxSide: Int(Double(max(img.width, img.height)) * 0.75)).0
        }
        throw Fail("Couldn't get the picture under \(ByteCountFormatter.string(fromByteCount: Int64(target), countStyle: .file))")
    }

    static func compress(_ src: URL, target: Int) throws -> URL {
        let out = output(for: src, ext: "jpg", suffix: " compressed")
        try encodeUnder(Img.load(src), target: target).write(to: out)
        return out
    }
}
