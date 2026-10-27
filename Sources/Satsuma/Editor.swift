import AppKit

enum EditTool: String, CaseIterable {
    case edit = "Edit", crop = "Crop", redact = "Redact", annotate = "Annotate", background = "Add Background"
}

/// Closure target for AppKit controls; kept alive by the editor that owns the control.
private final class Handler: NSObject {
    let f: (Any?) -> Void
    init(_ f: @escaping (Any?) -> Void) { self.f = f }
    @objc func fire(_ sender: Any?) { f(sender) }
}

/// Cmd+S saves, Cmd+Z undoes, Esc closes.
private final class EditorWindow: NSWindow {
    var keys: [String: () -> Void] = [:]
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), let f = keys[e.charactersIgnoringModifiers ?? ""] { f(); return true }
        return super.performKeyEquivalent(with: e)
    }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// The picture, aspect-fitted with a margin, plus the crop frame / live box drawn over it. Top-left coordinates.
private final class Stage: NSView {
    var image: CGImage?
    var frameRect: CGRect?   // in shown-image pixels
    var liveRect: CGRect?
    var accent = NSColor.orange
    var onDrag: ((CGPoint, CGPoint, Bool) -> Void)?
    private var from: CGPoint?

    override var isFlipped: Bool { true }

    var fitted: CGRect {
        guard let image else { return .zero }
        let area = bounds.insetBy(dx: 18, dy: 18)
        let k = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let w = CGFloat(image.width) * k, h = CGFloat(image.height) * k
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }
    private var k: CGFloat { image.map { fitted.width / CGFloat($0.width) } ?? 1 }
    private func toView(_ r: CGRect) -> CGRect { CGRect(x: fitted.minX + r.minX * k, y: fitted.minY + r.minY * k, width: r.width * k, height: r.height * k) }
    private func toImage(_ p: CGPoint) -> CGPoint {
        guard let image else { return .zero }
        return CGPoint(x: min(max((p.x - fitted.minX) / k, 0), CGFloat(image.width)), y: min(max((p.y - fitted.minY) / k, 0), CGFloat(image.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        guard let image else { return }
        NSImage(cgImage: image, size: .zero).draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let f = frameRect {
            let dim = NSBezierPath(rect: fitted)
            dim.append(NSBezierPath(rect: toView(f)))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
            accent.setStroke()
            let edge = NSBezierPath(rect: toView(f)); edge.lineWidth = 2; edge.stroke()
        }
        if let l = liveRect {
            accent.setStroke()
            let edge = NSBezierPath(rect: toView(l)); edge.lineWidth = 2
            edge.setLineDash([5, 4], count: 2, phase: 0)
            edge.stroke()
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = toImage(convert(e.locationInWindow, from: nil))
        from = p
        onDrag?(p, p, false)
    }
    override func mouseDragged(with e: NSEvent) { if let a = from { onDrag?(a, toImage(convert(e.locationInWindow, from: nil)), false) } }
    override func mouseUp(with e: NSEvent) {
        if let a = from { from = nil; onDrag?(a, toImage(convert(e.locationInWindow, from: nil)), true) }
    }
}

/// One window for every image tool: live preview (a downscaled copy) on the left, controls on the right; Save writes the
/// full-size result beside the original. Geometry is kept in full-image pixels and scaled for the preview.
final class Editor: NSObject, NSWindowDelegate {
    private static var open: [Editor] = []

    let url: URL
    let tool: EditTool
    private let full: CGImage, small: CGImage, s: CGFloat
    private let theme = Theme.current
    private let window: EditorWindow
    private let stage = Stage()
    private let panel = NSStackView()
    private var handlers: [Handler] = [], resets: [() -> Void] = []

    // Tool state, all in full-image pixels.
    private var adjust = Adjustments()
    private var crop: CGRect?, cropRatio: CGFloat = 0
    private var boxes: [CGRect] = [], live: CGRect?, redactStyle = RedactStyle.pixelate
    private var marks: [Mark] = [], current: Mark?, markKind = MarkKind.arrow
    private var markColor = NSColor.systemRed, markWidth: CGFloat = 6
    private let textField = NSTextField(string: "Note")
    private var backdrop: BackgroundStyle

    static func open(_ url: URL, _ tool: EditTool) throws {
        let e = try Editor(url, tool)
        open.append(e)
        NSApp.activate(ignoringOtherApps: true)
        e.window.makeKeyAndOrderFront(nil)
    }

    init(_ url: URL, _ tool: EditTool) throws {
        self.url = url
        self.tool = tool
        full = try Img.load(url)
        (small, s) = try ImageEdit.shrink(full, maxSide: 1400)
        backdrop = BackgroundStyle(from: theme.accent, to: theme.accent.blended(withFraction: 0.55, of: .black)!)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "\(tool.rawValue): \(url.lastPathComponent)"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let solid = theme.solid {
            window.backgroundColor = solid.withAlphaComponent(1)
            window.appearance = NSAppearance(named: solid.brightnessComponent < 0.5 ? .darkAqua : .aqua)
        }
        window.keys = ["s": { [weak self] in self?.save() }, "z": { [weak self] in self?.undo() }]
        window.center()

        stage.accent = theme.accent
        stage.onDrag = { [weak self] a, b, done in self?.drag(a, b, done) }

        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 6
        panel.distribution = .fill  // the default gravity areas spread controls down the whole column
        panel.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        buildControls()

        let reset = button("Reset", primary: false) { [weak self] in self?.reset() }
        let save = button("Save", primary: true) { [weak self] in self?.save() }
        let actions = NSStackView(views: [reset, save])
        actions.distribution = .fillEqually
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 18, right: 18)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let right = NSStackView(views: [panel, spacer, actions])
        right.orientation = .vertical
        right.distribution = .fill
        right.setHuggingPriority(.defaultLow, for: .vertical)
        right.widthAnchor.constraint(equalToConstant: 280).isActive = true
        panel.setContentHuggingPriority(.required, for: .vertical)

        let root = NSStackView(views: [stage, right])
        root.orientation = .horizontal
        root.alignment = .top
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 0, right: 0)
        root.spacing = 0
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -32).isActive = true
        right.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        window.contentView = root
        refresh()
    }

    func windowWillClose(_ notification: Notification) { Editor.open.removeAll { $0 === self } }

    // MARK: controls

    private func add(_ v: NSView) { panel.addArrangedSubview(v) }
    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = theme.textColor.withAlphaComponent(alpha)
        t.preferredMaxLayoutWidth = 244
        return t
    }
    private func label(_ s: String) { add(text(s.uppercased(), size: 10.5, weight: .semibold, alpha: 0.6)) }
    private func hint(_ s: String) { add(text(s, size: 12, weight: .regular, alpha: 0.75)) }
    private func gap() {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true  // fixed, or the stack would stretch it
        add(v)
    }

    private func target(_ f: @escaping (Any?) -> Void) -> Handler { let h = Handler(f); handlers.append(h); return h }

    /// Name and value on one line, slider below; Reset puts it back.
    private func slider(_ name: String, _ min: Double, _ max: Double, _ value: Double, _ changed: @escaping (Double) -> Void) {
        let val = text(String(format: "%.0f", value), size: 12, weight: .regular, alpha: 0.7)
        let head = NSStackView(views: [text(name, size: 12, weight: .semibold), NSView(), val])
        head.widthAnchor.constraint(equalToConstant: 244).isActive = true
        let sl = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        sl.trackFillColor = theme.accent
        sl.isContinuous = true
        let h = target { _ in val.stringValue = String(format: "%.0f", sl.doubleValue); changed(sl.doubleValue) }
        (sl.target, sl.action) = (h, #selector(Handler.fire(_:)))
        sl.widthAnchor.constraint(equalToConstant: 244).isActive = true
        add(head); add(sl); gap()
        resets.append { sl.doubleValue = value; val.stringValue = String(format: "%.0f", value) }
    }

    private func choice<T>(_ name: String, _ options: [(String, T)], _ pick: @escaping (T) -> Void) {
        label(name)
        let seg = NSSegmentedControl(labels: options.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = 0
        seg.selectedSegmentBezelColor = theme.accent
        let h = target { _ in pick(options[seg.selectedSegment].1) }
        (seg.target, seg.action) = (h, #selector(Handler.fire(_:)))
        add(seg); gap()
        resets.append { seg.selectedSegment = 0; pick(options[0].1) }
    }

    private func swatches(_ name: String, _ fills: [NSColor], gradientTo: [NSColor]? = nil, _ pick: @escaping (Int) -> Void) {
        label(name)
        var buttons: [NSButton] = []
        for (i, c) in fills.enumerated() {
            let b = NSButton(title: "", target: nil, action: nil)
            b.isBordered = false
            b.wantsLayer = true
            let size: CGFloat = gradientTo == nil ? 28 : 34
            b.widthAnchor.constraint(equalToConstant: size).isActive = true
            b.heightAnchor.constraint(equalToConstant: size).isActive = true
            if let to = gradientTo?[i] {
                let g = CAGradientLayer()
                g.colors = [c.cgColor, to.cgColor]
                g.startPoint = CGPoint(x: 0, y: 1); g.endPoint = CGPoint(x: 1, y: 0)
                g.frame = CGRect(x: 0, y: 0, width: size, height: size)
                b.layer?.addSublayer(g)
            } else { b.layer?.backgroundColor = c.cgColor }
            b.layer?.cornerRadius = size / 2
            b.layer?.masksToBounds = true
            b.layer?.borderColor = theme.accent.cgColor
            let h = target { [weak b] _ in buttons.forEach { $0.layer?.borderWidth = 0 }; b?.layer?.borderWidth = 3; pick(i) }
            (b.target, b.action) = (h, #selector(Handler.fire(_:)))
            buttons.append(b)
        }
        buttons.first?.layer?.borderWidth = 3
        let row = NSStackView(views: buttons)
        row.spacing = 8
        add(row); gap()
    }

    private func button(_ title: String, primary: Bool, _ f: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if primary { b.bezelColor = theme.accent; b.keyEquivalent = "\r" }
        let h = target { _ in f() }
        (b.target, b.action) = (h, #selector(Handler.fire(_:)))
        return b
    }

    private func buildControls() {
        add(text(tool.rawValue, size: 20, weight: .bold))
        gap()
        switch tool {
        case .edit:
            let rows: [(String, WritableKeyPath<Adjustments, Double>)] = [
                ("Exposure", \.exposure), ("Brightness", \.brightness), ("Contrast", \.contrast), ("Saturation", \.saturation),
                ("Temperature", \.temperature), ("Highlights", \.highlights), ("Shadows", \.shadows),
            ]
            for (name, key) in rows { slider(name, -100, 100, adjust[keyPath: key]) { [weak self] v in self?.adjust[keyPath: key] = v; self?.refresh() } }
        case .crop:
            hint("Drag on the picture to choose the area.")
            choice("Ratio", [("Free", 0), ("1:1", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("4:5", 0.8)] as [(String, CGFloat)]) { [weak self] r in
                self?.cropRatio = r; self?.crop = nil; self?.refresh()
            }
        case .redact:
            hint("Drag over anything you want hidden. ⌘Z removes the last box.")
            choice("Style", RedactStyle.allCases.map { ($0.rawValue, $0) }) { [weak self] v in self?.redactStyle = v; self?.refresh() }
        case .annotate:
            hint("Drag on the picture to draw; for text, click where it goes. ⌘Z removes the last mark.")
            choice("Draw", MarkKind.allCases.map { ($0.rawValue, $0) }) { [weak self] v in self?.markKind = v }
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]
            swatches("Colour", colors) { [weak self] i in self?.markColor = colors[i] }
            slider("Width", 1, 30, markWidth) { [weak self] v in self?.markWidth = v }
            label("Text")
            textField.widthAnchor.constraint(equalToConstant: 244).isActive = true
            add(textField)
        case .background:
            let pairs: [(NSColor, NSColor)] = [
                (theme.accent, theme.accent.blended(withFraction: 0.55, of: .black)!),
                (Theme.rgb(255, 179, 71), Theme.rgb(214, 51, 108)), (Theme.rgb(94, 234, 212), Theme.rgb(59, 130, 246)),
                (Theme.rgb(196, 181, 253), Theme.rgb(91, 33, 182)), (Theme.rgb(241, 245, 249), Theme.rgb(203, 213, 225)),
                (Theme.rgb(39, 39, 42), Theme.rgb(9, 9, 11)),
            ]
            swatches("Backdrop", pairs.map(\.0), gradientTo: pairs.map(\.1)) { [weak self] i in
                self?.backdrop.from = pairs[i].0; self?.backdrop.to = pairs[i].1; self?.refresh()
            }
            slider("Padding", 0, 40, Double(backdrop.padding * 100)) { [weak self] v in self?.backdrop.padding = v / 100; self?.refresh() }
            slider("Corners", 0, 20, Double(backdrop.corner * 100)) { [weak self] v in self?.backdrop.corner = v / 100; self?.refresh() }
            let shadow = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
            shadow.state = .on
            let h = target { [weak self] _ in self?.backdrop.shadow = shadow.state == .on; self?.refresh() }
            (shadow.target, shadow.action) = (h, #selector(Handler.fire(_:)))
            add(shadow); gap()
            resets.append { shadow.state = .on }
            choice("Ratio", [("Auto", 0), ("1:1", 1), ("16:9", 16.0 / 9), ("4:5", 0.8)] as [(String, CGFloat)]) { [weak self] r in
                self?.backdrop.ratio = r; self?.refresh()
            }
        }
    }

    // MARK: interaction

    private func drag(_ a0: CGPoint, _ b0: CGPoint, _ done: Bool) {
        // The stage reports shown-image pixels; state lives in full-image pixels.
        let a = CGPoint(x: a0.x / s, y: a0.y / s), b = CGPoint(x: b0.x / s, y: b0.y / s)
        var r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch tool {
        case .crop:
            if cropRatio > 0 {
                // Keep the ratio: the drag's larger extent wins, anchored at the start point.
                let w = max(r.width, r.height * cropRatio), h = w / cropRatio
                r = CGRect(x: b.x < a.x ? a.x - w : a.x, y: b.y < a.y ? a.y - h : a.y, width: w, height: h)
            }
            crop = r.width > 2 && r.height > 2 ? r : nil
        case .redact:
            if done { if r.width > 2 && r.height > 2 { boxes.append(r) }; live = nil } else { live = r }
        case .annotate:
            if markKind == .pen {
                if current == nil { current = Mark(kind: .pen, points: [a], color: markColor, width: markWidth) }
                current?.points.append(b)
            } else {
                current = Mark(kind: markKind, points: [a, b], color: markColor, width: markWidth, text: textField.stringValue)
            }
            if done, let m = current {
                if m.kind == .text || m.kind == .pen || hypot(b.x - a.x, b.y - a.y) > 2 { marks.append(m) }
                current = nil
            }
        default:
            return
        }
        refresh()
    }

    private func undo() {
        if tool == .redact, !boxes.isEmpty { boxes.removeLast() }
        if tool == .annotate, !marks.isEmpty { marks.removeLast() }
        refresh()
    }

    private func reset() {
        (adjust, crop, current, live) = (Adjustments(), nil, nil, nil)
        boxes.removeAll(); marks.removeAll()
        backdrop = BackgroundStyle(from: theme.accent, to: theme.accent.blended(withFraction: 0.55, of: .black)!)
        resets.forEach { $0() }
        refresh()
    }

    // MARK: rendering

    private func scaled(_ r: CGRect, _ k: CGFloat) -> CGRect { CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k) }

    private func apply(_ img: CGImage, _ k: CGFloat, final: Bool) throws -> CGImage {
        switch tool {
        case .edit: return try ImageEdit.adjust(img, adjust)
        case .crop: return final && crop != nil ? try ImageEdit.crop(img, crop!) : img  // the preview shows the frame instead
        case .redact: return boxes.isEmpty ? img : try ImageEdit.redact(img, boxes.map { scaled($0, k) }, redactStyle)
        case .annotate:
            return try ImageEdit.annotate(img, (marks + [current].compactMap { $0 }).map { m in
                var m = m; m.points = m.points.map { CGPoint(x: $0.x * k, y: $0.y * k) }; m.width *= k; return m
            })
        case .background: return try ImageEdit.addBackground(img, backdrop)
        }
    }

    private func refresh() {
        stage.image = (try? apply(small, s, final: false)) ?? small
        stage.frameRect = tool == .crop ? crop.map { scaled($0, s) } : nil
        stage.liveRect = live.map { scaled($0, s) }
        stage.needsDisplay = true
    }

    private func save() {
        do {
            if tool == .crop && crop == nil { throw Fail("Drag on the picture to choose what to keep first.") }
            let suffix = [EditTool.edit: " edited", .crop: " cropped", .redact: " redacted", .annotate: " annotated", .background: " background"][tool]!
            let out = output(for: url, ext: Img.sameFormat(url), suffix: suffix)
            try Img.write(apply(full, 1, final: true), to: out, quality: 0.92)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            window.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    /// For `--shot editor-<tool>`: the window's content as a picture, with a little demo state.
    static func snapshot(_ url: URL, _ tool: EditTool) throws -> NSBitmapImageRep {
        let e = try Editor(url, tool)
        let w = CGFloat(e.full.width), h = CGFloat(e.full.height)
        switch tool {
        case .edit: e.adjust = Adjustments(exposure: 15, contrast: 20, saturation: 25, temperature: 30)
        case .crop: e.crop = CGRect(x: w * 0.15, y: h * 0.1, width: w * 0.6, height: h * 0.7)
        case .redact: e.boxes = [CGRect(x: w * 0.55, y: h * 0.2, width: w * 0.3, height: h * 0.25)]
        case .annotate:
            e.marks = [Mark(kind: .arrow, points: [CGPoint(x: w * 0.2, y: h * 0.8), CGPoint(x: w * 0.5, y: h * 0.45)], color: .systemRed, width: max(4, w / 150)),
                       Mark(kind: .text, points: [CGPoint(x: w * 0.08, y: h * 0.82)], color: .systemRed, width: max(4, w / 150), text: "Look here")]
        case .background: break
        }
        e.refresh()
        let view = e.window.contentView!
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// Asks for a target size in bytes, or nil when cancelled. Main thread only.
enum SizePrompt {
    static func ask(_ file: URL) -> Int? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Compress to size"
        alert.informativeText = "Make \(file.lastPathComponent) at most:"
        let sizes = [("100 KB", 100_000), ("250 KB", 250_000), ("500 KB", 500_000), ("1 MB", 1_000_000), ("2 MB", 2_000_000), ("5 MB", 5_000_000)]
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
        pop.addItems(withTitles: sizes.map(\.0))
        pop.selectItem(at: 3)
        alert.accessoryView = pop
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? sizes[pop.indexOfSelectedItem].1 : nil
    }
}
