import AppKit

/// The ring of options that appears under the pointer mid-drag. Files are dropped onto a slice.
final class WheelPanel: NSPanel {
    static let size: CGFloat = 380
    let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    var mode: Mode { wheel.mode }
    private var themeName = ""

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func applyTheme() {
        let theme = Theme.current
        alphaValue = Theme.opacity
        let key = theme.name + theme.accent.description
        guard key != themeName else { return }
        themeName = key
        wheel.theme = theme
        wheel.removeFromSuperview()
        wheel.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        contentView = Backdrop.wrap(wheel, radius: Self.size / 2, theme: theme, drawsOwnSolid: true)
        hasShadow = theme.isGlass
    }

    func show(_ mode: Mode, files: [URL], at point: NSPoint) {
        applyTheme()
        wheel.mode = mode
        if files != wheel.files || wheel.sizeText.isEmpty {
            wheel.thumb = nil
            wheel.sizeText = Thumbs.describe(files)
            if let first = files.first {
                Thumbs.get(first, size: 96) { [weak wheel] image in
                    guard let wheel, wheel.files.first == first else { return }
                    wheel.thumb = image
                    wheel.needsDisplay = true
                }
            }
        }
        wheel.files = files
        wheel.ops = Catalog.ops(mode, files)
        wheel.hover = nil
        if !isVisible { setFrameOrigin(NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)) }
        wheel.needsDisplay = true
        orderFrontRegardless()
        watchScroll()
    }

    /// Turns to the next wheel (Convert, Tools, Actions), or back with dir = -1. Like Filee's donut flip.
    func flip(_ dir: Int) {
        guard isVisible else { return }
        show(Mode.allCases[(mode.rawValue + dir + 3) % 3], files: wheel.files, at: .zero)
        Click.play()
    }

    // The scroll wheel flips too. Mid-drag Finder owns the mouse, so a global monitor hears it; mouse monitors need no permission.
    private var monitors: [Any] = []
    private var scrolled: CGFloat = 0

    private func watchScroll() {
        guard monitors.isEmpty else { return }
        scrolled = 0
        let handle: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            self.scrolled += e.scrollingDeltaY
            let step: CGFloat = e.hasPreciseScrollingDeltas ? 40 : 1
            if abs(self.scrolled) >= step { let dir = self.scrolled < 0 ? 1 : -1; self.scrolled = 0; self.flip(dir) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handle) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { handle($0); return nil }) { monitors.append(l) }
    }

    override func orderOut(_ sender: Any?) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        super.orderOut(sender)
    }
}

final class WheelView: NSView {
    var mode = Mode.convert
    var files: [URL] = []
    var ops: [Op] = []
    var hover: Int?
    var thumb: NSImage?
    var sizeText = ""
    var onPick: ((Op, [URL], Mode) -> Void)?
    var theme = Theme.current

    private let inner: CGFloat = 58, outer: CGFloat = 182
    private var accent: NSColor { theme.accent }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var step: CGFloat { 2 * .pi / CGFloat(max(ops.count, 1)) }

    /// Slice under a point; angles run clockwise from 12 o'clock.
    private func index(at p: CGPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard !ops.isEmpty, r >= inner, r <= outer + 24 else { return nil }
        var a = atan2(dx, dy)
        if a < 0 { a += 2 * .pi }
        return Int(a / step) % ops.count
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let i = index(at: convert(sender.draggingLocation, from: nil))
        if i != hover {
            if i != nil { Click.play() }
            hover = i
            needsDisplay = true
        }
        return i == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = hover else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        onPick?(ops[i], urls?.isEmpty == false ? urls! : files, mode)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Glass themes get their surface from the backdrop; solid ones paint the ring here.
        if let solid = theme.solid {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            ring.append(NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)))
            ring.windingRule = .evenOdd
            solid.setFill()
            ring.fill()
        }
        let text = theme.textColor

        for (i, op) in ops.enumerated() {
            let a0 = CGFloat(i) * step, a1 = a0 + step
            // AppKit arcs are counter-clockwise from 3 o'clock, in degrees.
            let d0 = 90 - a0 * 180 / .pi, d1 = 90 - a1 * 180 / .pi
            let slice = NSBezierPath()
            slice.appendArc(withCenter: center, radius: outer, startAngle: d0, endAngle: d1, clockwise: true)
            slice.appendArc(withCenter: center, radius: inner, startAngle: d1, endAngle: d0, clockwise: false)
            slice.close()
            if hover == i { accent.withAlphaComponent(theme.isGlass ? 0.85 : 1).setFill(); slice.fill() }
            text.withAlphaComponent(0.14).setStroke()
            slice.lineWidth = 1
            slice.stroke()

            let mid = a0 + step / 2, r = (inner + outer) / 2
            let at = CGPoint(x: center.x + sin(mid) * r, y: center.y + cos(mid) * r)
            let color = hover == i ? NSColor.white : text
            if let name = Self.symbols[op.title],
               let icon = NSImage(systemSymbolName: name, accessibilityDescription: op.title)?
                   .withSymbolConfiguration(.init(pointSize: 17, weight: .medium).applying(.init(paletteColors: [color]))) {
                // Tools and actions: icon over a small caps label. Format slices stay text-only.
                let s = icon.size
                icon.draw(in: NSRect(x: at.x - s.width / 2, y: at.y + 10 - s.height / 2, width: s.width, height: s.height))
                // Crowded wheels put long two-word labels on two lines so neighbours don't touch.
                var caps = op.title.uppercased()
                let wrapped = ops.count > 8 && caps.count > 10 && caps.contains(" ")
                if wrapped { caps = caps.replacingOccurrences(of: " ", with: "\n") }
                label(caps, at: CGPoint(x: at.x, y: at.y - (wrapped ? 16 : 11)),
                      font: .systemFont(ofSize: caps.count > 11 && !wrapped ? 9 : 10, weight: .bold), color: color)
            } else {
                label(op.title, at: at, font: .systemFont(ofSize: ops.count > 10 ? 12 : 14.5, weight: .bold), color: color)
            }
        }

        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        (theme.solid.map { $0.blended(withFraction: 0.12, of: text) ?? $0 } ?? text.withAlphaComponent(0.08)).setFill()
        hub.fill()
        // Hub: the file's thumbnail (or the hovered option / mode name), its size, then the mode keys.
        let top = CGPoint(x: center.x, y: center.y + 15)
        if let h = hover {
            label(ops[h].title, at: top, font: .systemFont(ofSize: 13, weight: .bold), color: accent)
        } else if let thumb {
            let t: CGFloat = 34, s = thumb.size, scale = t / max(s.width, s.height, 1)
            let box = NSRect(x: top.x - s.width * scale / 2, y: top.y - s.height * scale / 2, width: s.width * scale, height: s.height * scale)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).addClip()
            thumb.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            label(ops.isEmpty && !files.isEmpty ? "Nothing here" : mode.title, at: top, font: .systemFont(ofSize: 13, weight: .bold), color: text)
        }
        label(sizeText, at: CGPoint(x: center.x, y: center.y - 9), font: .systemFont(ofSize: 10.5, weight: .semibold),
              color: text.withAlphaComponent(0.75))
        let keys: [(String, Mode)] = [("⇧", .convert), ("⌘", .tools), ("⌃", .actions)]
        if !files.isEmpty && hover == nil {
            label("⇥ ⇄", at: CGPoint(x: center.x, y: center.y - 42), font: .systemFont(ofSize: 9, weight: .semibold), color: text.withAlphaComponent(0.45))
        }
        for (k, (sym, m)) in keys.enumerated() {
            label(sym, at: CGPoint(x: center.x + CGFloat(k - 1) * 20, y: center.y - 27), font: .systemFont(ofSize: 11, weight: .medium),
                  color: m == mode ? accent : text.withAlphaComponent(0.45))
        }
    }

    /// SF Symbols for tool and action slices (all available on macOS 13).
    static let symbols: [String: String] = [
        "Compress": "arrow.down.right.and.arrow.up.left", "Edit": "slider.horizontal.3", "Crop": "crop",
        "Trim": "timeline.selection", "Bleep": "speaker.slash.circle", "Channels": "hifispeaker.2", "Visualize": "chart.bar.xaxis",
        "Split": "rectangle.split.3x1", "Speed": "gauge.with.dots.needle.67percent",
        "Redact": "eye.slash", "Annotate": "pencil.tip", "Add BG": "photo.on.rectangle", "Resize 50%": "arrow.up.left.and.arrow.down.right",
        "Rotate": "rotate.right", "Flip": "arrow.left.and.right.righttriangle.left.righttriangle.right",
        "Grayscale": "circle.lefthalf.filled", "Strip Metadata": "tag.slash", "Read QR Code": "qrcode.viewfinder",
        "Make PDF": "doc.richtext", "Zip": "doc.zipper", "Snapshot": "camera", "Extract Audio": "waveform",
        "Mute": "speaker.slash", "Speed 2×": "hare", "Join": "link", "Normalize": "speaker.wave.2",
        "Trim Silence": "scissors", "Mono": "hifispeaker", "Split Pages": "rectangle.split.2x1",
        "Merge": "rectangle.stack", "Extract": "archivebox", "Organize": "square.grid.2x2",
        "Watermark": "textformat", "Page Numbers": "number", "Password": "lock",
        "AirDrop": "dot.radiowaves.left.and.right", "Copy": "doc.on.doc", "Copy Path": "doc.text",
        "Terminal": "terminal", "Quick Look": "eye", "Float": "pip", "Move To…": "folder",
    ]

    private func label(_ text: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: centred])
        let size = s.size()
        s.draw(in: NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width + 1, height: size.height))
    }
}
