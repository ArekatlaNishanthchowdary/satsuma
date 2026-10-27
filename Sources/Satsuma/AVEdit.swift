import AppKit

struct MediaInfo {
    var duration: Double, hasVideo: Bool, hasAudio: Bool, width: Int, height: Int
}

enum ChannelMode: String, CaseIterable { case stereo = "Stereo", mono = "Mono", left = "Left", right = "Right", swap = "Swap" }
enum WaveStyle: String, CaseIterable { case wave = "Wave", bars = "Bars", spectrum = "Spectrum" }

/// The audio and video editors' work, all done by ffmpeg. Times are seconds; boxes are video pixels.
enum AVEdit {
    static func n(_ v: Double) -> String { String(format: "%.3f", v) }
    static func hex(_ c: NSColor) -> String {
        let c = c.usingColorSpace(.sRGB) ?? c
        return String(format: "0x%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    private static var ff: String { get throws { guard let f = Shell.ffmpeg else { throw Fail("This needs ffmpeg") }; return f } }

    /// Reads ffmpeg's own banner (`ffmpeg -i` exits 1 without an output), so no ffprobe is needed.
    static func probe(_ src: URL) throws -> MediaInfo {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try ff)
        p.arguments = ["-hide_banner", "-nostdin", "-i", src.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ banner: String) -> MediaInfo {
        func groups(_ pattern: String) -> [String]? {
            let re = try! NSRegularExpression(pattern: pattern)
            guard let m = re.firstMatch(in: banner, range: NSRange(banner.startIndex..., in: banner)) else { return nil }
            return (1..<m.numberOfRanges).map { String(banner[Range(m.range(at: $0), in: banner)!]) }
        }
        let d = groups(#"Duration: (\d+):(\d+):([\d.]+)"#).map { Double($0[0])! * 3600 + Double($0[1])! * 60 + Double($0[2])! } ?? 0
        // Cover art shows up as a one-frame "Video:" stream; it isn't a video.
        let v = groups(#"Video: (?!.*attached pic).*?(\d{2,5})x(\d{2,5})"#)
        return MediaInfo(duration: d, hasVideo: v != nil, hasAudio: banner.contains("Audio:"), width: v.map { Int($0[0])! } ?? 0, height: v.map { Int($0[1])! } ?? 0)
    }

    private static func picture(_ args: [String]) throws -> CGImage {
        let png = try tempDir().appendingPathComponent("pic.png")
        try Shell.ffmpeg(args + ["-frames:v", "1", png.path])
        return try Img.load(png)
    }

    private static func wave(_ src: URL, _ color: NSColor, _ height: Int) throws -> CGImage {
        try picture(["-i", src.path, "-filter_complex", "aformat=channel_layouts=mono,showwavespic=s=1600x\(height):scale=sqrt:colors=\(hex(color))"])
    }

    /// What the editor shows, 1600 px across the whole duration: the waveform, under a strip of frames for video.
    static func picture(_ src: URL, _ m: MediaInfo, _ color: NSColor) throws -> CGImage {
        if !m.hasVideo { return try wave(src, color, 520) }
        let strip = try picture(["-i", src.path, "-vf", "fps=\(n(8 / max(m.duration, 0.1))),scale=200:-2,tile=8x1"])
        if !m.hasAudio { return strip }
        let w = try wave(src, color, 300)
        let ctx = try ImageEdit.canvas(1600, strip.height + 12 + w.height)
        ctx.draw(w, in: CGRect(x: 0, y: 0, width: 1600, height: w.height))
        ctx.draw(strip, in: CGRect(x: 0, y: w.height + 12, width: 1600, height: strip.height))
        return ctx.makeImage()!
    }

    /// One frame at native size, for video Crop and Redact.
    static func frame(_ src: URL, _ m: MediaInfo) throws -> CGImage { try picture(["-ss", n(min(1, m.duration / 2)), "-i", src.path]) }

    private static func out(_ src: URL, _ suffix: String, _ ext: String? = nil) -> URL { output(for: src, ext: ext ?? normExt(src), suffix: suffix) }

    @discardableResult
    private static func run(_ src: URL, _ dest: URL, before: [String] = [], _ args: [String]) throws -> URL {
        try Shell.ffmpeg(before + ["-i", src.path] + args + [dest.path])
        return dest
    }

    // ponytail: re-encodes for frame-accurate cuts; a stream-copy fast path would land on keyframes instead.
    static func trim(_ src: URL, from: Double, to: Double) throws -> URL {
        try run(src, out(src, " trimmed"), before: ["-ss", n(from), "-to", n(to)], [])
    }

    static func enable(_ ranges: [(Double, Double)]) -> String { ranges.map { "between(t\\,\(n($0.0))\\,\(n($0.1)))" }.joined(separator: "+") }

    /// Silences the ranges and lays a 1 kHz tone over them; video, if any, is copied untouched.
    static func bleep(_ src: URL, _ ranges: [(Double, Double)]) throws -> URL {
        guard !ranges.isEmpty else { throw Fail("Drag over the parts to bleep first.") }
        let on = enable(ranges)
        return try run(src, out(src, " bleeped"), ["-filter_complex",
            "[0:a]volume=0:enable='\(on)'[muted];sine=frequency=1000:sample_rate=48000,volume=0.3,volume=0:enable='not(\(on))'[tone];[muted][tone]amix=inputs=2:duration=first:normalize=0[out]",
            "-map", "0:v?", "-map", "[out]", "-c:v", "copy"])
    }

    static func channelFilter(_ mode: ChannelMode, _ l: Double, _ r: Double) -> String {
        "aformat=channel_layouts=stereo," + {
            switch mode {
            case .mono: return "pan=mono|c0=\(n(l / 2))*c0+\(n(r / 2))*c1"
            case .left: return "pan=mono|c0=\(n(l))*c0"
            case .right: return "pan=mono|c0=\(n(r))*c1"
            case .swap: return "pan=stereo|c0=\(n(l))*c1|c1=\(n(r))*c0"
            case .stereo: return "pan=stereo|c0=\(n(l))*c0|c1=\(n(r))*c1"
            }
        }()
    }

    /// Gains are 0…2 (1 = unchanged).
    static func channels(_ src: URL, _ mode: ChannelMode, _ l: Double, _ r: Double) throws -> URL {
        try run(src, out(src, " " + mode.rawValue.lowercased()), ["-af", channelFilter(mode, l, r), "-c:v", "copy"])
    }

    static func visualize(_ src: URL, _ style: WaveStyle, _ color: NSColor) throws -> URL {
        let draw: String
        switch style {
        case .spectrum: draw = "showspectrum=s=1280x720:mode=combined:slide=scroll:color=intensity"
        case .bars: draw = "showfreqs=s=1280x720:mode=bar:ascale=sqrt:colors=\(hex(color))"
        case .wave: draw = "showwaves=s=1280x720:mode=cline:rate=30:colors=\(hex(color))"
        }
        return try run(src, out(src, " visualized", "mp4"), ["-filter_complex", "[0:a]\(draw),format=yuv420p[v]",
            "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-c:a", "aac", "-b:a", "192k", "-shortest"])
    }

    /// Cuts at the given times (or into equal parts) into a folder of numbered files.
    static func split(_ src: URL, _ m: MediaInfo, cuts: [Double], parts: Int) throws -> URL {
        let p = max(2, parts)
        let all = cuts.isEmpty ? (1..<p).map { m.duration * Double($0) / Double(p) } : cuts
        let times = all.filter { $0 > 0.05 && $0 < m.duration - 0.05 }.sorted().map(n).joined(separator: ",")
        let dir = try outputFolder(for: src, suffix: " parts")
        let pattern = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "%", with: "%%") + " %d." + normExt(src))
        var args = ["-f", "segment", "-segment_times", times, "-segment_start_number", "1", "-reset_timestamps", "1"]
        if m.hasVideo { args += ["-force_key_frames", times] }  // so each part starts exactly at its cut
        try run(src, pattern, args)
        return dir
    }

    /// atempo only takes 0.5–2, so bigger changes chain several.
    static func atempo(_ factor: Double) -> String {
        var f = factor, parts: [String] = []
        while f > 2 { parts.append("atempo=2"); f /= 2 }
        while f < 0.5 { parts.append("atempo=0.5"); f /= 0.5 }
        parts.append("atempo=\(String(format: "%g", f))")
        return parts.joined(separator: ",")
    }

    static func speed(_ src: URL, _ m: MediaInfo, _ f: Double) throws -> URL {
        var args: [String] = []
        if m.hasVideo { args += ["-filter:v", "setpts=PTS/\(n(f))"] }
        if m.hasAudio { args += ["-filter:a", atempo(f)] }
        return try run(src, out(src, " \(String(format: "%g", f))x"), args)
    }

    static func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    static func cropVideo(_ src: URL, _ r: CGRect) throws -> URL {
        try run(src, out(src, " cropped"), ["-vf", "crop=\(even(r.width)):\(even(r.height)):\(even(r.minX)):\(even(r.minY))", "-c:a", "copy"])
    }

    static func redactFilter(_ boxes: [CGRect], _ style: RedactStyle) -> String {
        var steps: [String] = [], cur = "0:v"
        for (i, b) in boxes.enumerated() {
            let x = even(b.minX), y = even(b.minY), w = even(b.width), h = even(b.height), next = "v\(i)"
            if style == .black {
                steps.append("[\(cur)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill[\(next)]")
            } else {
                let hide = style == .blur ? "boxblur=luma_radius=\(max(2, min(w, h) / 5)):luma_power=3"
                    : "scale=\(max(1, w / 14)):\(max(1, h / 14)),scale=\(w):\(h):flags=neighbor"
                steps.append("[\(cur)]split[a\(i)][b\(i)];[b\(i)]crop=\(w):\(h):\(x):\(y),\(hide)[c\(i)];[a\(i)][c\(i)]overlay=\(x):\(y)[\(next)]")
            }
            cur = next
        }
        return steps.joined(separator: ";") + (steps.isEmpty ? "" : ";[\(cur)]format=yuv420p[out]")
    }

    static func redactVideo(_ src: URL, _ boxes: [CGRect], _ style: RedactStyle) throws -> URL {
        guard !boxes.isEmpty else { throw Fail("Drag over what to hide first.") }
        return try run(src, out(src, " redacted"), ["-filter_complex", redactFilter(boxes, style), "-map", "[out]", "-map", "0:a?", "-c:a", "copy"])
    }

    /// Bitrate maths: the whole file's bits over its duration, minus the audio's share, with 5% headroom.
    static func compress(_ src: URL, target: Int) throws -> URL {
        let m = try probe(src)
        guard m.duration > 0 else { throw Fail("Couldn't read the length of \(src.lastPathComponent)") }
        let total = Double(target) * 8 * 0.95 / m.duration
        if !m.hasVideo {
            let ab = Int(min(max(total, 24_000), 320_000))
            return try run(src, out(src, " compressed", "m4a"), ["-vn", "-c:a", "aac", "-b:a", "\(ab)"])
        }
        let audio = m.hasAudio ? Int(min(max(total * 0.1, 48_000), 128_000)) : 0
        let video = Int(total) - audio
        guard video >= 50_000 else {
            throw Fail("\(ByteCountFormatter.string(fromByteCount: Int64(target), countStyle: .file)) is too small for \(Int(m.duration)) seconds of video.")
        }
        return try run(src, out(src, " compressed", "mp4"), ["-c:v", "libx264", "-b:v", "\(video)", "-maxrate", "\(video)", "-bufsize", "\(video * 2)",
            "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(max(audio, 48_000))"])
    }

    static func clock(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t / 60), t.truncatingRemainder(dividingBy: 60)) }
}
