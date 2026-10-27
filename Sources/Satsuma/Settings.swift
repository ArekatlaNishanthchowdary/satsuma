import AppKit

/// The user's order and hidden slices for each wheel, one defaults key per kind and mode:
/// ["PNG", "JPG", "-GIF"] lists titles in order, a leading "-" hides one. Slices not listed keep their place at the end.
enum Layout {
    static func key(_ kind: Kind, _ mode: Mode) -> String { mode == .actions ? "wheel.actions" : "wheel.\(kind.rawValue).\(mode.title)" }

    static func get(_ kind: Kind, _ mode: Mode) -> [(title: String, hidden: Bool)]? {
        (UserDefaults.standard.stringArray(forKey: key(kind, mode)))?.map { $0.hasPrefix("-") ? (String($0.dropFirst()), true) : ($0, false) }
    }

    static func set(_ kind: Kind, _ mode: Mode, _ items: [(title: String, hidden: Bool)]) {
        UserDefaults.standard.set(items.map { ($0.hidden ? "-" : "") + $0.title }, forKey: key(kind, mode))
    }

    static func reset(_ kind: Kind, _ mode: Mode) { UserDefaults.standard.removeObject(forKey: key(kind, mode)) }

    static func apply(_ ops: [Op], _ kind: Kind, _ mode: Mode) -> [Op] {
        guard let saved = get(kind, mode) else { return ops }
        func rank(_ o: Op) -> Int { saved.firstIndex { $0.title == o.title } ?? .max }
        return ops.filter { o in !saved.contains { $0.hidden && $0.title == o.title } }
            .enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// "Customize Wheel…": tick slices on or off and drag them into order, with the wheel previewed beside the list.
final class Customizer: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: Customizer?
    private static let kinds: [Kind] = [.image, .video, .audio, .pdf, .document, .sheet, .slides, .subtitle, .archive, .data, .font, .other]
    private static let rowType = NSPasteboard.PasteboardType("app.satsuma.wheel-row")

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let kindPop = NSPopUpButton(), modePop = NSPopUpButton()
    private let table = NSTableView()
    private let preview = NSImageView()
    private var rows: [(title: String, shown: Bool)] = []

    static func show() {
        if open == nil { open = Customizer() }
        NSApp.activate(ignoringOtherApps: true)
        open!.window.makeKeyAndOrderFront(nil)
    }

    /// For README screenshots: the window's content drawn off-screen with the PDF tools wheel picked.
    static func snapshot() -> NSBitmapImageRep {
        let c = Customizer()
        c.kindPop.selectItem(at: kinds.firstIndex(of: .pdf)!)
        c.modePop.selectItem(at: 1)
        c.load()
        let view = c.window.contentView!
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    override init() {
        super.init()
        window.title = "Customize Wheel"
        window.isReleasedWhenClosed = false
        window.center()
        kindPop.addItems(withTitles: Self.kinds.map { $0 == .other ? "Any file" : $0.rawValue.capitalized })
        modePop.addItems(withTitles: Mode.allCases.map(\.title))
        for pop in [kindPop, modePop] { pop.target = self; pop.action = #selector(load) }

        let column = NSTableColumn(identifier: .init("slice"))
        column.width = 210
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let hint = NSTextField(labelWithString: "Tick to show, drag to reorder.")
        hint.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Reset this wheel", target: self, action: #selector(resetWheel))
        let pops = NSStackView(views: [kindPop, modePop])
        let left = NSStackView(views: [pops, hint, scroll, reset])
        left.orientation = .vertical
        left.alignment = .leading
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 340).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 340).isActive = true
        let body = NSStackView(views: [left, preview])
        body.alignment = .top
        body.spacing = 20
        body.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = body
        load()
    }

    private var selected: (Kind, Mode) { (Self.kinds[max(kindPop.indexOfSelectedItem, 0)], Mode.allCases[max(modePop.indexOfSelectedItem, 0)]) }

    @objc private func load() {
        let (kind, mode) = selected
        let all = Catalog.allTitles(kind, mode)
        let saved = Layout.get(kind, mode) ?? []
        rows = saved.filter { all.contains($0.title) }.map { ($0.title, !$0.hidden) } + all.filter { t in !saved.contains { $0.title == t } }.map { ($0, true) }
        table.reloadData()
        render()
    }

    @objc private func resetWheel() { Layout.reset(selected.0, selected.1); load() }

    private func save() {
        Layout.set(selected.0, selected.1, rows.map { ($0.title, !$0.shown) })
        render()
    }

    private func render() {
        let (kind, mode) = selected
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: WheelPanel.size, height: WheelPanel.size))
        view.theme = Theme.current.isGlass ? Theme.all.first { $0.name == "Midnight" }! : Theme.current
        view.mode = mode
        view.ops = Layout.apply(Catalog.allTitles(kind, mode).map { Op(title: $0) { _ in [] } }, kind, mode)
        view.sizeText = "2.4 MB"
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        preview.image = image
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let box = NSButton(checkboxWithTitle: rows[row].title, target: self, action: #selector(toggled(_:)))
        box.state = rows[row].shown ? .on : .off
        box.tag = row
        return box
    }

    @objc private func toggled(_ box: NSButton) {
        rows[box.tag].shown = box.state == .on
        save()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType), let from = Int(s) else { return false }
        let moved = rows.remove(at: from)
        rows.insert(moved, at: from < row ? row - 1 : row)
        tableView.reloadData()
        save()
        return true
    }
}

/// Watch folders: every new file that lands in one is converted to that folder's format, beside the original.
/// ponytail: polls every 2 s instead of FSEvents; fine for a handful of folders.
enum Watch {
    static var failed: ((URL, Error) -> Void)?
    private static var known: [String: Set<String>] = [:]
    private static var sizes: [String: Int] = [:]
    private static var timer: Timer?

    /// Folder path → lower-case target extension.
    static var all: [String: String] { UserDefaults.standard.dictionary(forKey: "watch") as? [String: String] ?? [:] }

    static func add(_ dir: String, _ ext: String) { var a = all; a[dir] = ext; UserDefaults.standard.set(a, forKey: "watch"); start() }
    static func remove(_ dir: String) { var a = all; a[dir] = nil; UserDefaults.standard.set(a, forKey: "watch"); known[dir] = nil }

    /// Every target format, for the "convert to…" choice.
    static var formats: [String] {
        var list: [String] = []
        for k in Kind.allCases { for t in Catalog.targets(k) where !list.contains(t) { list.append(t) } }
        return list
    }

    static func addInteractively() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Watch"
        panel.message = "Convert every new file in this folder"
        guard panel.runModal() == .OK, let dir = panel.url,
              let ext = Prompt.choose("Watch folder", "Convert new files in \(dir.lastPathComponent) to:", formats.map { $0.uppercased() }) else { return }
        add(dir.path, ext.lowercased())
    }

    static func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// The first look at a folder only remembers what's there. After that, a new file is converted once its size holds still for a tick.
    static func tick() {
        let fm = FileManager.default
        for (dir, ext) in all {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            guard var seen = known[dir] else { known[dir] = Set(names); continue }
            for name in names where !seen.contains(name) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                let kind = Kind.of(url)
                if name.hasPrefix(".") || normExt(url) == ext || !(kind == .font ? Fonts.targets(url) : Catalog.targets(kind)).contains(ext) {
                    seen.insert(name)
                    continue
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                guard size > 0, sizes[url.path] == size else { sizes[url.path] = size; continue }
                sizes[url.path] = nil
                seen.insert(name)
                DispatchQueue.global(qos: .utility).async {
                    do { _ = try Convert.run(url, to: ext) } catch { DispatchQueue.main.async { failed?(url, error) } }
                }
            }
            known[dir] = seen
        }
    }
}
