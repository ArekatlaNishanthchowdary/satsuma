import AppKit

/// The ring of options that appears under the pointer mid-drag. Files are dropped onto a slice.
final class WheelPanel: NSPanel {
    static let size: CGFloat = 380
    let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    var mode: Mode { wheel.mode }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = wheel
    }

    func show(_ mode: Mode, files: [URL], at point: NSPoint) {
        wheel.mode = mode
        wheel.files = files
        wheel.ops = Catalog.ops(mode, files)
        wheel.hover = nil
        if !isVisible { setFrameOrigin(NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)) }
        wheel.needsDisplay = true
        orderFrontRegardless()
    }
}

final class WheelView: NSView {
    var mode = Mode.convert
    var files: [URL] = []
    var ops: [Op] = []
    var hover: Int?
    var onPick: ((Op, [URL], Mode) -> Void)?

    private let inner: CGFloat = 58, outer: CGFloat = 170
    private let accent = NSColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)

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
        if i != hover { hover = i; needsDisplay = true }
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
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        ring.append(NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)))
        ring.windingRule = .evenOdd
        NSColor(white: 0.08, alpha: 0.88).setFill()
        ring.fill()

        for (i, op) in ops.enumerated() {
            let a0 = CGFloat(i) * step, a1 = a0 + step
            // AppKit arcs are counter-clockwise from 3 o'clock, in degrees.
            let d0 = 90 - a0 * 180 / .pi, d1 = 90 - a1 * 180 / .pi
            let slice = NSBezierPath()
            slice.appendArc(withCenter: center, radius: outer, startAngle: d0, endAngle: d1, clockwise: true)
            slice.appendArc(withCenter: center, radius: inner, startAngle: d1, endAngle: d0, clockwise: false)
            slice.close()
            if hover == i { accent.setFill(); slice.fill() }
            NSColor(white: 1, alpha: 0.12).setStroke()
            slice.lineWidth = 1
            slice.stroke()

            let mid = a0 + step / 2, r = (inner + outer) / 2
            let fontSize: CGFloat = ops.count > 10 || op.title.count > 9 ? 10.5 : 12.5
            label(op.title, at: CGPoint(x: center.x + sin(mid) * r, y: center.y + cos(mid) * r),
                  font: .systemFont(ofSize: fontSize, weight: .semibold), color: .white)
        }

        NSColor(white: 0.14, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - inner + 4, y: center.y - inner + 4, width: (inner - 4) * 2, height: (inner - 4) * 2)).fill()
        let title = hover.map { ops[$0].title } ?? (ops.isEmpty ? "Nothing here" : mode.title)
        label(title, at: CGPoint(x: center.x, y: center.y + 9), font: .systemFont(ofSize: 13, weight: .bold),
              color: hover == nil ? .white : accent)
        let keys: [(String, Mode)] = [("⇧", .convert), ("⌘", .tools), ("⌃", .actions)]
        for (k, (sym, m)) in keys.enumerated() {
            label(sym, at: CGPoint(x: center.x + CGFloat(k - 1) * 20, y: center.y - 13), font: .systemFont(ofSize: 12, weight: .medium),
                  color: m == mode ? accent : NSColor(white: 1, alpha: 0.45))
        }
    }

    private func label(_ text: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = s.size()
        s.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
    }
}
