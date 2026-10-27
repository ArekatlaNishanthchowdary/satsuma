import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--selftest") {
    _ = NSApplication.shared  // text → PDF printing needs an app object
    SelfTest.run()
    exit(0)
}

func notify(_ title: String, _ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.runModal()
}

/// Small floating "Working…" card while a job runs.
final class HUD {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var jobs = 0

    private let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))

    init() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 16, y: 18, width: 16, height: 16)
        label.frame = NSRect(x: 42, y: 17, width: 205, height: 18)
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(spinner)
        content.addSubview(label)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
    }

    func start(_ text: String) {
        jobs += 1
        let theme = Theme.current
        content.removeFromSuperview()
        content.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        panel.contentView = Backdrop.wrap(content, radius: 26, theme: theme)
        label.textColor = theme.textColor
        label.stringValue = text
        if let f = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: f.midX - 130, y: f.minY + 80)) }
        spinner.startAnimation(nil)
        panel.orderFrontRegardless()
    }

    func finish() {
        jobs -= 1
        if jobs == 0 { spinner.stopAnimation(nil); panel.orderOut(nil) }
    }
}

final class BlockItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { block() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let wheel = WheelPanel()
    private let hud = HUD()
    private let dragBoard = NSPasteboard(name: .drag)
    private var wasDown = false, downCount = 0, readCount = -1
    private var dragFiles: [URL] = []
    private var lastFlags: NSEvent.ModifierFlags = []

    func applicationDidFinishLaunching(_ note: Notification) {
        status.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Satsuma")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        wheel.wheel.onPick = { [weak self] op, urls, mode in
            self?.wheel.orderOut(nil)
            self?.perform(op, urls, mode)
        }
        // ponytail: polls the drag pasteboard at 30 Hz instead of an event tap, so no Accessibility
        // permission is needed. A drag started within one tick of mouse-down can be missed.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasDown { downCount = dragBoard.changeCount; dragFiles = [] }
        if !down && wasDown && wheel.isVisible {
            // Give the drop a moment to land before closing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.wheel.orderOut(nil) }
            }
        }
        wasDown = down
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control])
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        guard down, dragBoard.changeCount != downCount else { return }
        if readCount != dragBoard.changeCount {
            readCount = dragBoard.changeCount
            dragFiles = dragBoard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
        guard !dragFiles.isEmpty else { return }
        // Only a key tapped mid-drag opens the wheel, so ⌘-dragging in Finder still works normally.
        let mode: Mode? = pressed.contains(.shift) ? .convert : pressed.contains(.command) ? .tools
            : pressed.contains(.control) ? .actions : nil
        if let mode, !wheel.isVisible || wheel.mode != mode {
            wheel.show(mode, files: dragFiles, at: NSEvent.mouseLocation)
        }
    }

    func perform(_ op: Op, _ urls: [URL], _ mode: Mode) {
        if mode == .actions {
            do {
                let out = try op.run(urls)
                if !out.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(out) }
            } catch { notify("\(op.title) failed", error.localizedDescription) }
            return
        }
        hud.start("\(op.title): \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try op.run(urls) }
            DispatchQueue.main.async { [weak self] in
                self?.hud.finish()
                switch result {
                case .success(let out): if !out.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(out) }
                case .failure(let error): notify("\(op.title) failed", error.localizedDescription)
                }
            }
        }
    }

    // Rebuilt on every open so the ffmpeg / login state is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hint = NSMenuItem(title: "Drag a file, then tap ⇧ Convert · ⌘ Tools · ⌃ Actions", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(BlockItem("Choose Files…") { [weak self] in self?.chooseFiles() })
        menu.addItem(.separator())
        for (name, path) in [("ffmpeg", Shell.ffmpeg), ("pandoc", Shell.pandoc)] {
            let item = NSMenuItem(title: path == nil ? "\(name) not found — brew install \(name) for more formats" : "\(name) found ✓",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let themes = NSMenu()
        for theme in Theme.all {
            let item = BlockItem(theme.name + (theme.isGlass ? "" : " (solid)")) { [weak self] in
                Theme.current = theme
                self?.previewTheme()
            }
            item.state = theme.name == Theme.current.name ? .on : .off
            item.image = swatch(theme.accent)
            themes.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)
        menu.addItem(BlockItem("Preview Wheel") { [weak self] in self?.previewTheme() })
        let login = BlockItem("Open at Login") {
            let app = SMAppService.mainApp
            do { app.status == .enabled ? try app.unregister() : try app.register() } catch {
                notify("Couldn't change login item", error.localizedDescription)
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(BlockItem("Quit Satsuma") { NSApp.terminate(nil) })
    }

    /// Shows the wheel mid-screen for a moment, as if a photo were being dragged.
    private func previewTheme() {
        guard let screen = NSScreen.main?.frame else { return }
        wheel.show(.convert, files: [URL(fileURLWithPath: "/tmp/Preview.jpg")], at: NSPoint(x: screen.midX, y: screen.midY))
        wheel.wheel.hover = 1
        wheel.wheel.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.wheel.orderOut(nil) }
        }
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }

    /// Keyboard/mouse alternative to the drag wheel.
    private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let menu = NSMenu()
        for mode in [Mode.convert, .tools, .actions] {
            let sub = NSMenu()
            for op in Catalog.ops(mode, urls) { sub.addItem(BlockItem(op.title) { [weak self] in self?.perform(op, urls, mode) }) }
            let item = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
            item.submenu = sub
            item.isEnabled = !sub.items.isEmpty
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
