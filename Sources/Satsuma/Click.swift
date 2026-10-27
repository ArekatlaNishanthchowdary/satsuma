import AppKit

/// The little mechanical "tick" when the pointer moves onto a slice, plus a light trackpad tap.
/// Synthesized, so there is no audio asset.
enum Click {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "clickSound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clickSound") }
    }

    private static let sound = NSSound(data: wav())

    static func play() {
        guard enabled else { return }
        sound?.stop()
        sound?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A mouse-switch click: a sharp noise transient with a damped high "ping" and a low body,
    /// then a quieter release click 9 ms later. 30 ms, 16-bit mono. Same recipe as the Windows build.
    static func wav() -> Data {
        let rate = 44100, n = rate * 30 / 1000
        var seed: UInt32 = 22222
        func noise() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed >> 8) / Double(1 << 24) * 2 - 1 }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + n * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(n * 2))
        for i in 0..<n {
            let t = Double(i) / Double(rate), t2 = t - 0.009
            var s = noise() * exp(-t / 0.0012) * 0.6
                + sin(2 * .pi * 3200 * t) * exp(-t / 0.002) * 0.35
                + sin(2 * .pi * 900 * t) * exp(-t / 0.004) * 0.25
            if t2 >= 0 { s += noise() * exp(-t2 / 0.0008) * 0.3 + sin(2 * .pi * 4100 * t2) * exp(-t2 / 0.0015) * 0.2 }
            put(Int16(max(-1, min(1, s * 0.5)) * Double(Int16.max)))
        }
        return data
    }
}
