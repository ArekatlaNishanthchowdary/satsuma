import AppKit
import PDFKit

extension PDFs {
    /// Writes the pages in the given order (0-based indexes, others dropped), each turned by an extra multiple of 90°.
    static func organize(_ src: URL, _ pages: [(index: Int, turn: Int)]) throws -> URL {
        if pages.isEmpty { throw Fail("Keep at least one page.") }
        let doc = try open(src), result = PDFDocument()
        for (i, turn) in pages {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + turn) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        let out = output(for: src, ext: "pdf", suffix: " organized")
        try save(result, out)
        return out
    }
}

extension ImageEdit {
    /// A near-square grid on white: every cell the same size (the median picture's aspect), pictures fitted and centred.
    static func collage(_ pics: [CGImage], cell: Int = 800, gap: Int = 24) throws -> CGImage {
        let cols = Int(ceil(sqrt(Double(pics.count)))), rows = (pics.count + cols - 1) / cols
        let aspect = pics.map { Double($0.width) / Double($0.height) }.sorted()[pics.count / 2]
        let cw = aspect >= 1 ? cell : Int(Double(cell) * aspect), ch = aspect >= 1 ? Int(Double(cell) / aspect) : cell
        let ctx = try canvas(gap + cols * (cw + gap), gap + rows * (ch + gap), flipped: true)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        for (i, p) in pics.enumerated() {
            let k = min(Double(cw) / Double(p.width), Double(ch) / Double(p.height)), w = Double(p.width) * k, h = Double(p.height) * k
            let x = Double(gap + i % cols * (cw + gap)) + (Double(cw) - w) / 2, y = Double(gap + i / cols * (ch + gap)) + (Double(ch) - h) / 2
            // The canvas is flipped, so draw each picture upside down within its own box to land upright.
            ctx.saveGState()
            ctx.translateBy(x: x, y: y + h); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(p, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    static func collage(_ urls: [URL]) throws -> URL {
        let out = output(for: urls[0], ext: "jpg", suffix: " collage")
        try Img.write(collage(urls.prefix(36).map(Img.load)), to: out)
        return out
    }
}

/// Tiles laid out left to right, wrapping at the scroll view's width.
private final class TileGrid: NSView {
    static let tile = NSSize(width: 236, height: 290)
    override var isFlipped: Bool { true }
    override func setFrameSize(_ size: NSSize) {
        let cols = max(1, Int((size.width - 12) / (Self.tile.width + 12)))
        for (i, v) in subviews.enumerated() {
            v.frame = NSRect(x: 12 + CGFloat(i % cols) * (Self.tile.width + 12), y: 12 + CGFloat(i / cols) * (Self.tile.height + 12),
                             width: Self.tile.width, height: Self.tile.height)
        }
        let rows = (subviews.count + cols - 1) / cols
        super.setFrameSize(NSSize(width: size.width, height: max(CGFloat(rows) * (Self.tile.height + 12) + 12, superview?.bounds.height ?? 0)))
    }
}

/// PDF Organize: a grid of page thumbnails to reorder, turn and delete; Save writes "name organized.pdf".
final class Organizer: NSObject, NSWindowDelegate {
    private static var open: [Organizer] = []
    private let url: URL
    private let thumbs: [NSImage]
    private var pages: [(index: Int, turn: Int)]
    private var history: [[(index: Int, turn: Int)]] = []
    private let theme = Theme.current
    private let window: EditorWindow
    private let grid = TileGrid()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private var handlers: [Handler] = [], barHandlers: [Handler] = []

    static func open(_ url: URL) throws {
        let o = try Organizer(url)
        open.append(o)
        NSApp.activate(ignoringOtherApps: true)
        o.window.makeKeyAndOrderFront(nil)
    }

    init(_ url: URL) throws {
        self.url = url
        let doc = try PDFs.open(url)
        thumbs = (0..<doc.pageCount).map { doc.page(at: $0)!.thumbnail(of: NSSize(width: 400, height: 400), for: .mediaBox) }
        pages = thumbs.indices.map { ($0, 0) }
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Organize: \(url.lastPathComponent)"
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let solid = theme.solid {
            window.backgroundColor = solid.withAlphaComponent(1)
            window.appearance = NSAppearance(named: solid.brightnessComponent < 0.5 ? .darkAqua : .aqua)
        }
        window.keys = ["s": { [weak self] in self?.save() }, "z": { [weak self] in self?.undo() }]
        window.center()

        scroll.documentView = grid
        grid.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        let reset = button("Reset", primary: false) { [weak self] in guard let self else { return }; self.change(self.thumbs.indices.map { ($0, 0) }) }
        let save = button("Save", primary: true) { [weak self] in self?.save() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [status, spacer, reset, save])
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 16, right: 18)
        let root = NSStackView(views: [scroll, bar])
        root.orientation = .vertical
        root.spacing = 0
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.contentView = root
        build()
    }

    func windowWillClose(_ notification: Notification) { Organizer.open.removeAll { $0 === self } }

    private func change(_ next: [(index: Int, turn: Int)]) {
        history.append(pages)
        pages = next
        build()
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        pages = last
        build()
    }

    private func move(_ at: Int, _ by: Int) {
        var next = pages
        next.swapAt(at, at + by)
        change(next)
    }

    // ponytail: arrow buttons rather than drag-to-reorder; add NSDraggingSource on the tiles if long documents make this tedious.
    private func build() {
        handlers.removeAll()
        grid.subviews.forEach { $0.removeFromSuperview() }
        for (at, page) in pages.enumerated() {
            // The tile is not flipped, so y counts up from the bottom: buttons, then label, then the page.
            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 12
            tile.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            let paper = NSImageView(frame: NSRect(x: 13, y: 70, width: 210, height: 210))
            paper.wantsLayer = true
            paper.layer?.backgroundColor = NSColor.white.cgColor
            paper.layer?.cornerRadius = 6
            paper.imageScaling = .scaleProportionallyUpOrDown
            paper.image = rotated(thumbs[page.index], page.turn)
            tile.addSubview(paper)
            let label = NSTextField(labelWithString: page.index == at ? "\(at + 1)" : "\(at + 1)  (was \(page.index + 1))")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: 44, width: TileGrid.tile.width, height: 18)
            tile.addSubview(label)
            let icons: [(String, String, Bool, () -> Void)] = [
                ("chevron.left", "Move earlier", at > 0, { [weak self] in self?.move(at, -1) }),
                ("rotate.right", "Turn 90°", true, { [weak self] in guard let self else { return }
                    var next = self.pages; next[at].turn = (next[at].turn + 90) % 360; self.change(next) }),
                ("trash", "Delete page", pages.count > 1, { [weak self] in guard let self else { return }
                    var next = self.pages; next.remove(at: at); self.change(next) }),
                ("chevron.right", "Move later", at < pages.count - 1, { [weak self] in self?.move(at, 1) }),
            ]
            for (i, (symbol, tip, enabled, f)) in icons.enumerated() {
                let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
                b.bezelStyle = .rounded
                b.toolTip = tip
                b.isHidden = !enabled
                b.frame = NSRect(x: 10 + CGFloat(i) * 54, y: 10, width: 50, height: 28)
                let h = Handler { _ in f() }
                handlers.append(h)
                (b.target, b.action) = (h, #selector(Handler.fire(_:)))
                tile.addSubview(b)
            }
            grid.addSubview(tile)
        }
        grid.setFrameSize(NSSize(width: scroll.contentSize.width, height: 0))
        let dropped = thumbs.count - pages.count
        status.stringValue = "\(pages.count) page\(pages.count == 1 ? "" : "s")" + (dropped > 0 ? " · \(dropped) removed" : "")
    }

    private func rotated(_ image: NSImage, _ turn: Int) -> NSImage {
        if turn == 0 { return image }
        let s = image.size, size = turn % 180 == 0 ? s : NSSize(width: s.height, height: s.width)
        return NSImage(size: size, flipped: false) { _ in
            let t = NSAffineTransform()
            t.translateX(by: size.width / 2, yBy: size.height / 2)
            t.rotate(byDegrees: -CGFloat(turn))
            t.translateX(by: -s.width / 2, yBy: -s.height / 2)
            t.concat()
            image.draw(in: NSRect(origin: .zero, size: s))
            return true
        }
    }

    private func save() {
        do {
            let out = try PDFs.organize(url, pages)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            window.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    private func button(_ title: String, primary: Bool, _ f: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if primary { b.bezelColor = theme.accent; b.keyEquivalent = "\r" }
        let h = Handler { _ in f() }
        barHandlers.append(h)  // targets are weak; build() clears `handlers`
        (b.target, b.action) = (h, #selector(Handler.fire(_:)))
        return b
    }

    /// For `--shot organize`: the window after a few edits (last two pages swapped, page 1 turned).
    static func snapshot(_ url: URL) throws -> NSBitmapImageRep {
        let o = try Organizer(url)
        o.window.setContentSize(NSSize(width: 780, height: 420))
        if o.pages.count > 1 { o.move(o.pages.count - 2, 1) }
        o.pages[0].turn = 90
        o.build()
        let view = o.window.contentView!
        view.layoutSubtreeIfNeeded()
        o.build()  // again, now that the scroll view has its width
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
