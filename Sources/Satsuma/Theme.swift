import AppKit

struct Theme {
    let name: String
    let accent: NSColor
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
    ]

    static var current: Theme {
        get { all.first { $0.name == UserDefaults.standard.string(forKey: "theme") } ?? all[0] }
        set { UserDefaults.standard.set(newValue.name, forKey: "theme") }
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
