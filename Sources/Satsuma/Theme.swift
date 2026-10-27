import AppKit

struct Theme {
    let name: String
    var accent: NSColor
    /// Glass tint; ignored by solid themes.
    var tint: NSColor? = nil
    /// Clear glass is more see-through than regular.
    var clear = false
    /// Non-nil means a solid (non-glass) theme with this fill.
    var solid: NSColor? = nil
    /// nil follows the system label colour, which glass keeps readable on any background.
    var text: NSColor? = nil

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let all: [Theme] = [
        Theme(name: "Tangerine", accent: rgb(255, 140, 26), tint: rgb(255, 140, 26, 0.18)),
        Theme(name: "Clear Glass", accent: rgb(10, 132, 255), clear: true),
        Theme(name: "Lime", accent: rgb(132, 204, 22), tint: rgb(132, 204, 22, 0.18)),
        Theme(name: "Blueberry", accent: rgb(59, 110, 246), tint: rgb(59, 110, 246, 0.18)),
        Theme(name: "Grape", accent: rgb(147, 82, 230), tint: rgb(147, 82, 230, 0.18)),
        Theme(name: "Strawberry", accent: rgb(236, 64, 100), tint: rgb(236, 64, 100, 0.18)),
        Theme(name: "Mint", accent: rgb(20, 184, 166), tint: rgb(20, 184, 166, 0.18)),
        Theme(name: "Graphite", accent: rgb(142, 142, 147), tint: rgb(0, 0, 0, 0.22)),
        Theme(name: "Midnight", accent: rgb(255, 140, 26), solid: rgb(20, 20, 22, 0.92), text: .white),
        Theme(name: "Paper", accent: rgb(234, 88, 12), solid: rgb(250, 248, 244, 0.96), text: rgb(28, 25, 23)),
        Theme(name: "Neon", accent: rgb(255, 0, 170), solid: rgb(8, 6, 20, 0.94), text: rgb(0, 240, 255)),
        Theme(name: "Sunset", accent: rgb(251, 113, 133), solid: rgb(67, 20, 7, 0.92), text: rgb(254, 215, 170)),
        // Community palettes (MIT), the same four Filee ships as theme examples.
        Theme(name: "Catppuccin", accent: rgb(203, 166, 247), solid: rgb(30, 30, 46, 0.95), text: rgb(205, 214, 244)),
        Theme(name: "Dracula", accent: rgb(189, 147, 249), solid: rgb(40, 42, 54, 0.95), text: rgb(248, 248, 242)),
        Theme(name: "Nord", accent: rgb(136, 192, 208), solid: rgb(46, 52, 64, 0.95), text: rgb(236, 239, 244)),
        Theme(name: "Monokai", accent: rgb(166, 226, 46), solid: rgb(39, 40, 34, 0.95), text: rgb(248, 248, 242)),
    ]

    /// The chosen theme, with the user's own accent colour if they picked one.
    static var current: Theme {
        get {
            var t = all.first { $0.name == UserDefaults.standard.string(forKey: "theme") } ?? all[0]
            if let c = customAccent { t.accent = c; if t.tint != nil { t.tint = c.withAlphaComponent(0.18) } }
            return t
        }
        set { UserDefaults.standard.set(newValue.name, forKey: "theme") }
    }

    static var customAccent: NSColor? {
        get { (UserDefaults.standard.array(forKey: "accent") as? [Double]).map { rgb($0[0], $0[1], $0[2]) } }
        set {
            guard let c = newValue?.usingColorSpace(.sRGB) else { UserDefaults.standard.removeObject(forKey: "accent"); return }
            UserDefaults.standard.set([c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255].map(Double.init), forKey: "accent")
        }
    }

    /// How see-through the whole wheel is, 0.5 to 1.
    static var opacity: CGFloat {
        get { UserDefaults.standard.object(forKey: "opacity") == nil ? 1 : min(max(UserDefaults.standard.double(forKey: "opacity"), 0.5), 1) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "opacity") }
    }

    var isGlass: Bool { solid == nil }
    var textColor: NSColor { text ?? .labelColor }
}

enum Backdrop {
    /// Wraps `content` in the theme's surface: Liquid Glass on macOS 26, vibrancy blur before that,
    /// or a solid rounded fill. With `drawsOwnSolid`, solid themes return `content` untouched.
    static func wrap(_ content: NSView, radius: CGFloat, theme: Theme, drawsOwnSolid: Bool = false) -> NSView {
        let frame = content.frame
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        if let solid = theme.solid {
            if drawsOwnSolid { content.frame = frame; return content }
            let v = NSView(frame: frame)
            v.wantsLayer = true
            v.layer?.backgroundColor = solid.cgColor
            v.layer?.cornerRadius = radius
            v.addSubview(content)
            return v
        }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = radius
            glass.style = theme.clear ? .clear : .regular
            glass.tintColor = theme.tint
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.masksToBounds = true
        blur.addSubview(content)
        return blur
    }
}
