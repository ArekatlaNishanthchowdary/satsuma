import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

// MARK: - Subtitles

/// Subtitles as timed cues: SRT, WebVTT, ASS/SSA, LRC (lyrics) and SBV (YouTube) in; the same, minus SSA, plus TXT out.
enum Subs {
    struct Cue { var start: Int, end: Int, text: String }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let cues = try parse(String(contentsOf: src), normExt(src))
        guard !cues.isEmpty else { throw Fail("No subtitles found in \(src.lastPathComponent)") }
        let out = output(for: src, ext: ext)
        try write(cues, ext).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func write(_ cues: [Cue], _ ext: String) -> String {
        switch ext {
        case "srt": return cues.enumerated().map { "\($0 + 1)\n\(clock($1.start, ",")) --> \(clock($1.end, ","))\n\($1.text)\n" }.joined(separator: "\n")
        case "vtt": return "WEBVTT\n\n" + cues.map { "\(clock($0.start, ".")) --> \(clock($0.end, "."))\n\($0.text)\n" }.joined(separator: "\n")
        case "sbv": return cues.map { "\(clock($0.start, ".").dropFirst()),\(clock($0.end, ".").dropFirst())\n\($0.text)\n" }.joined(separator: "\n")
        case "lrc":
            return cues.map { String(format: "[%02d:%02d.%02d]", $0.start / 60000, $0.start / 1000 % 60, $0.start / 10 % 100)
                + plain($0.text).replacingOccurrences(of: "\n", with: " ") + "\n" }.joined()
        case "ass":
            return assHeader + cues.map { "Dialogue: 0,\(cs($0.start)),\(cs($0.end)),Default,,0,0,0,,\($0.text.replacingOccurrences(of: "\n", with: "\\N"))\n" }.joined()
        default: return cues.map { plain($0.text) }.joined(separator: "\n") + "\n"
        }
    }

    static let assHeader = "[Script Info]\nScriptType: v4.00+\nPlayResX: 384\nPlayResY: 288\n\n[V4+ Styles]\n"
        + "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        + "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1\n\n[Events]\n"
        + "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"

    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
    static func clock(_ ms: Int, _ sep: String) -> String {
        String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, sep, ms % 1000)
    }
    static func cs(_ ms: Int) -> String { String(format: "%d:%02d:%02d.%02d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms / 10 % 100) }

    static func groups(_ s: String, _ pattern: String) -> [String?]? {
        guard let m = try! NSRegularExpression(pattern: pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    /// "01:02:03,450", "2:03.45" or "03.4": the fraction is read as a decimal, so .45 and .450 agree.
    static func ms(_ t: String) throws -> Int {
        guard let g = groups(t.trimmingCharacters(in: .whitespaces), #"^(?:(\d+):)?(?:(\d+):)?(\d+)(?:[.,](\d+))?$"#) else { throw Fail("Can't read the time \"\(t)\"") }
        var h = 0, m = 0
        if let b = g[2] { h = Int(g[1]!)!; m = Int(b)! } else if let a = g[1] { m = Int(a)! }
        let frac = g[4].map { Int(String(($0 + "00").prefix(3)))! } ?? 0
        return ((h * 60 + m) * 60 + Int(g[3]!)!) * 1000 + frac
    }

    static func parse(_ raw: String, _ ext: String) throws -> [Cue] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        switch ext {
        case "ass", "ssa":
            // Field order comes from the [Events] Format line; Text is always last and may hold commas.
            let format = lines.first { $0.hasPrefix("Format:") && $0.contains("Text") }
                .map { $0.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                ?? ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
            return try lines.filter { $0.hasPrefix("Dialogue:") }.map { line -> Cue in
                let f = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false).map(String.init)
                let body = f.last!.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                return Cue(start: try ms(f[format.firstIndex(of: "Start")!]), end: try ms(f[format.firstIndex(of: "End")!]), text: body)
            }.sorted { $0.start < $1.start }
        case "lrc":
            // A line may carry several time tags ("[00:12.00][01:30.00]chorus"); each cue ends where the next begins.
            let tag = try! NSRegularExpression(pattern: #"\[(\d+:\d+(?:[.:]\d+)?)\]"#)
            var hits: [(Int, String)] = []
            for line in lines {
                let body = line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { continue }
                for m in tag.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    var v = String(line[Range(m.range(at: 1), in: line)!])
                    // "[01:02:50]" is minutes:seconds:centiseconds in some players
                    if v.filter({ $0 == ":" }).count == 2, let last = v.lastIndex(of: ":") { v.replaceSubrange(last...last, with: ".") }
                    hits.append((try ms(v), body))
                }
            }
            hits.sort { $0.0 < $1.0 }
            return hits.enumerated().map { i, h in Cue(start: h.0, end: i + 1 < hits.count ? hits[i + 1].0 : h.0 + 4000, text: h.1) }
        default:
            // SRT and VTT time lines use "-->"; SBV puts "start,end" alone on the first line of a block.
            return try text.components(separatedBy: "\n\n").compactMap { block -> Cue? in
                let ls = block.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
                if let i = ls.firstIndex(where: { $0.contains("-->") }) {
                    let parts = ls[i].components(separatedBy: "-->")
                    let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                    return Cue(start: try ms(parts[0]), end: try ms(end), text: ls[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines))
                }
                guard let g = groups(ls[0], #"^(\d+:\d+:\d+\.\d+),(\d+:\d+:\d+\.\d+)$"#) else { return nil }
                return Cue(start: try ms(g[1]!), end: try ms(g[2]!), text: ls.dropFirst().joined(separator: "\n"))
            }
        }
    }
}

// MARK: - Data

/// JSON that keeps its key order (Foundation's JSONSerialization doesn't) and numbers exactly as written.
indirect enum JSON: Equatable {
    case null, bool(Bool), num(String), str(String), arr([JSON]), obj([(String, JSON)])

    static func == (a: JSON, b: JSON) -> Bool { a.text() == b.text() }

    var isContainer: Bool { if case .obj = self { return true }; if case .arr = self { return true }; return false }

    subscript(key: String) -> JSON? { if case .obj(let o) = self { return o.first { $0.0 == key }?.1 }; return nil }
    subscript(i: Int) -> JSON? { if case .arr(let a) = self, i < a.count { return a[i] }; return nil }

    static func parse(_ data: Data) throws -> JSON {
        var p = Parser(s: [UInt8](data))
        if p.s.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        let v = try p.value()
        p.ws()
        guard p.i == p.s.count else { throw Fail("Unexpected text after the JSON value") }
        return v
    }

    struct Parser {
        let s: [UInt8]
        var i = 0
        mutating func ws() { while i < s.count, [0x20, 0x0A, 0x0D, 0x09].contains(s[i]) { i += 1 } }
        mutating func eat(_ c: Character) -> Bool { ws(); if i < s.count, s[i] == c.asciiValue! { i += 1; return true }; return false }
        mutating func expect(_ c: Character) throws { guard eat(c) else { throw Fail("Malformed JSON near byte \(i)") } }

        mutating func value() throws -> JSON {
            ws()
            guard i < s.count else { throw Fail("The JSON ends too early") }
            switch s[i] {
            case UInt8(ascii: "{"):
                i += 1
                var o: [(String, JSON)] = []
                if eat("}") { return .obj(o) }
                repeat { ws(); let k = try string(); try expect(":"); o.append((k, try value())) } while eat(",")
                try expect("}")
                return .obj(o)
            case UInt8(ascii: "["):
                i += 1
                var a: [JSON] = []
                if eat("]") { return .arr(a) }
                repeat { a.append(try value()) } while eat(",")
                try expect("]")
                return .arr(a)
            case UInt8(ascii: "\""): return .str(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            default:
                let start = i
                while i < s.count, "+-.eE0123456789".utf8.contains(s[i]) { i += 1 }
                guard i > start else { throw Fail("Malformed JSON near byte \(i)") }
                return .num(String(decoding: s[start..<i], as: UTF8.self))
            }
        }

        mutating func word(_ w: String) throws {
            guard s[i...].starts(with: w.utf8) else { throw Fail("Malformed JSON near byte \(i)") }
            i += w.utf8.count
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 < s.count, let v = UInt32(String(decoding: s[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else { throw Fail("Bad \\u escape in JSON") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw Fail("Expected a string near byte \(i)") }
            i += 1
            var out: [UInt8] = []
            while i < s.count, s[i] != UInt8(ascii: "\"") {
                if s[i] == UInt8(ascii: "\\"), i + 1 < s.count {
                    i += 1
                    switch s[i] {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), i + 2 < s.count, s[i + 1] == UInt8(ascii: "\\"), s[i + 2] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + (code - 0xD800) << 10 + (low &- 0xDC00)
                        }
                        out += Array(String(Character(Unicode.Scalar(code) ?? "\u{FFFD}")).utf8)
                    default: out.append(s[i])  // \" \\ \/
                    }
                } else { out.append(s[i]) }
                i += 1
            }
            guard i < s.count else { throw Fail("A JSON string never ends") }
            i += 1
            return String(decoding: out, as: UTF8.self)
        }
    }

    static func quote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case _ where u.value < 0x20: o += String(format: "\\u%04X", u.value)
            default: o.unicodeScalars.append(u)
            }
        }
        return o + "\""
    }

    /// Compact (like a spreadsheet cell) or indented by two spaces.
    func text(pretty: Bool = false, _ indent: String = "") -> String {
        let inner = indent + "  ", nl = pretty ? "\n" : "", sep = pretty ? ": " : ":"
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .num(let n): return n
        case .str(let s): return Self.quote(s)
        case .arr(let a):
            if a.isEmpty { return "[]" }
            return "[" + nl + a.map { (pretty ? inner : "") + $0.text(pretty: pretty, inner) }.joined(separator: "," + nl) + nl + (pretty ? indent : "") + "]"
        case .obj(let o):
            if o.isEmpty { return "{}" }
            return "{" + nl + o.map { (pretty ? inner : "") + Self.quote($0.0) + sep + $0.1.text(pretty: pretty, inner) }.joined(separator: "," + nl) + nl + (pretty ? indent : "") + "}"
        }
    }
}

/// JSON and XML (in), plus JSON, XML, YAML and tables out. Tables reuse the spreadsheet writers.
enum DataFiles {
    static func convert(_ src: URL, to ext: String) throws -> URL {
        let node = try load(src)
        let out = output(for: src, ext: ext)
        switch ext {
        case "json": try (node.text(pretty: true) + "\n").write(to: out, atomically: true, encoding: .utf8)
        case "xml":
            let doc = XMLDocument(rootElement: toXML(node))
            doc.characterEncoding = "UTF-8"
            try doc.xmlData(options: [.nodePrettyPrint]).write(to: out)
        case "yaml": try yaml(node).write(to: out, atomically: true, encoding: .utf8)
        default: try Sheets.write(rows(node), to: out)
        }
        return out
    }

    static func load(_ url: URL) throws -> JSON {
        if normExt(url) == "xml" {
            guard let root = try XMLDocument(contentsOf: url).rootElement() else { throw Fail("\(url.lastPathComponent) has no XML in it") }
            return .obj([(root.localName ?? root.name ?? "root", fromXML(root))])
        }
        return try JSON.parse(Data(contentsOf: url))
    }

    /// Attributes become "@name", repeated children an array, mixed text "#text"; a bare element is just its text.
    static func fromXML(_ e: XMLElement) -> JSON {
        let attrs = (e.attributes ?? []).filter { !($0.name ?? "").hasPrefix("xmlns") }
        let kids = (e.children ?? []).compactMap { $0 as? XMLElement }
        if attrs.isEmpty && kids.isEmpty { return .str(e.stringValue ?? "") }
        var o: [(String, JSON)] = attrs.map { ("@" + ($0.localName ?? $0.name ?? ""), .str($0.stringValue ?? "")) }
        var order: [String] = [], groups: [String: [XMLElement]] = [:]
        for k in kids { let n = k.localName ?? k.name ?? ""; if groups[n] == nil { order.append(n) }; groups[n, default: []].append(k) }
        for n in order { let g = groups[n]!; o.append((n, g.count == 1 ? fromXML(g[0]) : .arr(g.map(fromXML)))) }
        let text = (e.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { o.append(("#text", .str(text))) }
        return .obj(o)
    }

    static func toXML(_ n: JSON) -> XMLElement {
        if case .obj(let o) = n, o.count == 1 { if case .arr = o[0].1 {} else { return element(o[0].0, o[0].1) } }
        return element("root", n)
    }

    static func element(_ name: String, _ n: JSON) -> XMLElement {
        let e = XMLElement(name: xmlName(name))
        switch n {
        case .obj(let o):
            for (k, v) in o {
                if k.hasPrefix("@") { e.addAttribute(XMLNode.attribute(withName: xmlName(String(k.dropFirst())), stringValue: cell(v)) as! XMLNode) }
                else if k == "#text" { e.addChild(XMLNode.text(withStringValue: cell(v)) as! XMLNode) }
                else if case .arr(let a) = v { a.forEach { e.addChild(element(k, $0)) } }
                else { e.addChild(element(k, v)) }
            }
        case .arr(let a): a.forEach { e.addChild(element("item", $0)) }
        case .null: break
        default: e.stringValue = cell(n)
        }
        return e
    }

    /// XML names can't start with a digit or hold spaces and most punctuation.
    static func xmlName(_ s: String) -> String {
        var n = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) ? Character($0) : "_" })
        if n.isEmpty || n.first!.isNumber || "-.".contains(n.first!) { n = "_" + n }
        return n
    }

    static func cell(_ n: JSON?) -> String {
        switch n {
        case nil, .null?: return ""
        case .str(let s)?: return s
        default: return n!.text()
        }
    }

    /// An array of objects becomes a header row plus one row per object. {"data": [...]} wrappers are looked through.
    static func rows(_ node: JSON) -> [[String]] {
        var n = node
        while case .obj(let o) = n, o.count == 1, o[0].1.isContainer { n = o[0].1 }
        let items: [JSON]
        if case .arr(let a) = n { items = a } else { items = [n] }
        let arrays = items.compactMap { item -> [JSON]? in if case .arr(let a) = item { return a }; return nil }
        if !items.isEmpty && arrays.count == items.count { return arrays.map { $0.map(cell) } }
        var keys: [String] = []
        for item in items { if case .obj(let o) = item { for (k, _) in o where !keys.contains(k) { keys.append(k) } } }
        if keys.isEmpty { return [["value"]] + items.map { [cell($0)] } }
        return [keys] + items.map { item in if case .obj = item { return keys.map { cell(item[$0]) } }; return [cell(item)] }
    }

    /// The first row names the fields. Numbers and true/false stay typed when they read back the same ("007" stays text).
    static func writeRows(_ rows: [[String]], to url: URL) throws {
        var head = (rows.first ?? []).enumerated().map { $1.isEmpty ? "column\($0 + 1)" : $1 }
        for i in head.indices { var n = 2; let base = head[i]; while head[..<i].contains(head[i]) { head[i] = "\(base) \(n)"; n += 1 } }
        let list = JSON.arr(rows.dropFirst().map { r in .obj(head.enumerated().map { i, h in (h, typed(i < r.count ? r[i] : "")) }) })
        try (list.text(pretty: true) + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func typed(_ s: String) -> JSON {
        if s == "true" || s == "false" { return .bool(s == "true") }
        return s.range(of: #"^-?(0|[1-9]\d{0,14})(\.\d*[1-9])?$"#, options: .regularExpression) != nil ? .num(s) : .str(s)
    }

    static let reserved: Set = ["true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"]

    static func yaml(_ n: JSON) -> String {
        var out = ""
        func scalar(_ v: JSON) -> String {
            switch v {
            case .obj: return "{}"
            case .arr: return "[]"
            case .str(let s): return key(s)
            default: return v.text()
            }
        }
        func isBlock(_ v: JSON) -> Bool {
            if case .obj(let o) = v { return !o.isEmpty }
            if case .arr(let a) = v { return !a.isEmpty }
            return false
        }
        func child(_ v: JSON, _ indent: Int) {
            if isBlock(v) { out += "\n"; emit(v, indent + 2) } else { out += " " + scalar(v) + "\n" }
        }
        func emit(_ v: JSON, _ indent: Int) {
            let pad = String(repeating: " ", count: indent)
            if case .obj(let o) = v { for (k, x) in o { out += pad + key(k) + ":"; child(x, indent) } }
            if case .arr(let a) = v { for x in a { out += pad + "-"; child(x, indent) } }
        }
        if isBlock(n) { emit(n, 0) } else { out = scalar(n) + "\n" }
        return out
    }

    /// Plain when it can't be misread as a number, bool or syntax; JSON-quoted (valid YAML) otherwise.
    static func key(_ s: String) -> String {
        s.range(of: #"^[A-Za-z_][\w .\-/]*$"#, options: .regularExpression) != nil && !s.hasSuffix(" ") && !reserved.contains(s.lowercased())
            ? s : JSON.quote(s)
    }
}

// MARK: - Fonts

/// TTF/OTF ↔ WOFF: the same tables, each zlib-compressed in WOFF.
enum Fonts {
    static let woff: UInt32 = 0x774F_4646, woff2: UInt32 = 0x774F_4632, otto: UInt32 = 0x4F54_544F, ttc: UInt32 = 0x7474_6366

    /// TTF and OTF go to WOFF; a WOFF goes back to whichever of the two it holds.
    static func targets(_ url: URL) -> [String] {
        guard normExt(url) == "woff" else { return ["woff"] }
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 8), head.count == 8 else { return ["ttf", "otf"] }
        return [u32([UInt8](head), 4) == otto ? "otf" : "ttf"]
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let b = [UInt8](try Data(contentsOf: src))
        let out = output(for: src, ext: ext)
        try Data(ext == "woff" ? toWoff(b) : fromWoff(b)).write(to: out)
        return out
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { b[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
    static func w32(_ o: inout [UInt8], _ v: UInt32) { o += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func w16(_ o: inout [UInt8], _ v: Int) { o += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func pad4(_ n: Int) -> Int { (n + 3) & ~3 }

    /// zlib = 2-byte header + raw DEFLATE (what Foundation's .zlib makes) + Adler-32.
    static func zlib(_ data: [UInt8]) throws -> [UInt8] {
        let deflated = try (Data(data) as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for x in data { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        var out: [UInt8] = [0x78, 0xDA] + deflated
        w32(&out, b << 16 | a)
        return out
    }

    static func unzlib(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 6 else { throw Fail("A WOFF table is damaged") }
        return [UInt8](try (Data(data[2..<data.count - 4]) as NSData).decompressed(using: .zlib) as Data)
    }

    static func toWoff(_ f: [UInt8]) throws -> [UInt8] {
        let flavor = u32(f, 0)
        if flavor == ttc { throw Fail("Font collections (.ttc) aren't supported.") }
        if flavor == woff || flavor == woff2 { throw Fail("This font is already a web font.") }
        let n = u16(f, 4)
        let tables = (0..<n).map { 12 + 16 * $0 }.map { e in
            (tag: u32(f, e), sum: u32(f, e + 4), data: Array(f[Int(u32(f, e + 8))..<Int(u32(f, e + 8)) + Int(u32(f, e + 12))]))
        }.sorted { $0.tag < $1.tag }
        let start = 44 + 20 * n
        var dir: [UInt8] = [], body: [UInt8] = []
        for t in tables {
            let z = try zlib(t.data)
            let data = z.count < t.data.count ? z : t.data  // the spec stores a table as-is when zlib doesn't help
            w32(&dir, t.tag); w32(&dir, UInt32(start + body.count)); w32(&dir, UInt32(data.count)); w32(&dir, UInt32(t.data.count)); w32(&dir, t.sum)
            body += data
            while body.count % 4 != 0 { body.append(0) }
        }
        var o: [UInt8] = []
        w32(&o, woff); w32(&o, flavor); w32(&o, UInt32(start + body.count)); w16(&o, n); w16(&o, 0)
        w32(&o, UInt32(12 + 16 * n + tables.reduce(0) { $0 + pad4($1.data.count) })); w16(&o, 1); w16(&o, 0)
        for _ in 0..<5 { w32(&o, 0) }  // no metadata or private block
        return o + dir + body
    }

    static func fromWoff(_ w: [UInt8]) throws -> [UInt8] {
        if u32(w, 0) == woff2 { throw Fail("WOFF2 fonts aren't supported yet, only WOFF.") }
        guard u32(w, 0) == woff else { throw Fail("This isn't a WOFF font.") }
        let n = u16(w, 12)
        let tables = try (0..<n).map { 44 + 20 * $0 }.map { e -> (tag: UInt32, sum: UInt32, data: [UInt8]) in
            let off = Int(u32(w, e + 4)), comp = Int(u32(w, e + 8)), orig = Int(u32(w, e + 12))
            let raw = Array(w[off..<off + comp])
            return (u32(w, e), u32(w, e + 16), comp == orig ? raw : try unzlib(raw))
        }
        let sel = Int(log2(Double(n))), range = 16 << sel
        var o: [UInt8] = []
        w32(&o, u32(w, 4)); w16(&o, n); w16(&o, range); w16(&o, sel); w16(&o, n * 16 - range)
        var offset = 12 + 16 * n
        for t in tables { w32(&o, t.tag); w32(&o, t.sum); w32(&o, UInt32(offset)); w32(&o, UInt32(t.data.count)); offset += pad4(t.data.count) }
        for t in tables { o += t.data; while o.count % 4 != 0 { o.append(0) } }
        return o
    }
}

// MARK: - Icons

/// Windows ICO and Apple ICNS, both as a stack of PNGs at the standard sizes.
enum IconFile {
    static let icoSizes = [16, 24, 32, 48, 64, 128, 256]
    static let icnsTypes = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]

    static func write(_ image: CGImage, to url: URL) throws {
        var o: [UInt8] = []
        if url.pathExtension.lowercased() == "icns" {
            // Up to 256 always; the larger Retina sizes only when the picture has the pixels for them.
            let biggest = max(256, image.width, image.height)
            let parts = try icnsTypes.filter { $0.1 <= biggest }.map { ($0.0, try square(image, $0.1)) }
            o += Array("icns".utf8)
            Fonts.w32(&o, UInt32(8 + parts.reduce(0) { $0 + 8 + $1.1.count }))
            for (type, png) in parts { o += Array(type.utf8); Fonts.w32(&o, UInt32(8 + png.count)); o += png }
        } else {
            let pngs = try icoSizes.map { try square(image, $0) }
            func le16(_ v: Int) { o += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
            func le32(_ v: Int) { o += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
            le16(0); le16(1); le16(pngs.count)
            var offset = 6 + 16 * pngs.count
            for (i, png) in pngs.enumerated() {
                let side = UInt8(icoSizes[i] == 256 ? 0 : icoSizes[i])
                o += [side, side, 0, 0]; le16(1); le16(32); le32(png.count); le32(offset)
                offset += png.count
            }
            pngs.forEach { o += $0 }
        }
        try Data(o).write(to: url)
    }

    /// The picture fitted, centred, into a transparent square.
    static func square(_ image: CGImage, _ size: Int) throws -> [UInt8] {
        let ctx = try ImageEdit.canvas(size, size)
        ctx.interpolationQuality = .high
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Fail("Couldn't encode PNG") }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw Fail("Couldn't encode PNG") }
        return [UInt8](data as Data)
    }
}

// MARK: - PDF stamps

/// Things stamped onto every page of a PDF, and a password.
enum Stamp {
    /// Redraws each page (upright, as it's viewed) into a new PDF and lets `draw` add to it.
    /// ponytail: the copy keeps text and vectors but not links, form fields or bookmarks.
    static func each(_ src: URL, suffix: String, _ draw: (CGContext, CGRect, Int, Int) -> Void) throws -> URL {
        guard let doc = CGPDFDocument(src as CFURL) else { throw Fail("Can't open \(src.lastPathComponent)") }
        if doc.isEncrypted && !doc.isUnlocked { throw Fail("\(src.lastPathComponent) is password-protected.") }
        let out = output(for: src, ext: "pdf", suffix: suffix)
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw Fail("Couldn't write \(out.lastPathComponent)") }
        let count = doc.numberOfPages
        for n in 1...max(count, 1) {
            guard let page = doc.page(at: n) else { continue }
            let crop = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            var box = CGRect(x: 0, y: 0, width: turned ? crop.height : crop.width, height: turned ? crop.width : crop.height)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            draw(ctx, box, n, count)
            ctx.endPage()
        }
        ctx.closePDF()
        return out
    }

    static func line(_ text: String, size: CGFloat, color: NSColor, bold: Bool = false) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]))
    }

    static func watermark(_ src: URL, _ text: String) throws -> URL {
        try each(src, suffix: " watermarked") { ctx, box, _, _ in
            // Corner to corner, sized so the text spans about 70% of the diagonal.
            let diagonal = hypot(box.width, box.height)
            let probe = CTLineGetTypographicBounds(line(text, size: 100, color: .gray, bold: true), nil, nil, nil)
            let size = min(max(100 * diagonal * 0.7 / max(probe, 1), 10), 160)
            let l = line(text, size: size, color: NSColor(white: 0.47, alpha: 0.22), bold: true)
            let w = CTLineGetTypographicBounds(l, nil, nil, nil)
            ctx.saveGState()
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: atan2(box.height, box.width))
            ctx.textPosition = CGPoint(x: -w / 2, y: -size * 0.35)
            CTLineDraw(l, ctx)
            ctx.restoreGState()
        }
    }

    static func number(_ src: URL) throws -> URL {
        try each(src, suffix: " numbered") { ctx, box, n, count in
            let l = line("\(n) / \(count)", size: 10, color: NSColor(white: 0.35, alpha: 1))
            ctx.textPosition = CGPoint(x: box.midX - CTLineGetTypographicBounds(l, nil, nil, nil) / 2, y: 20)
            CTLineDraw(l, ctx)
        }
    }

    /// The same password opens the file and lifts its restrictions.
    static func protect(_ src: URL, _ password: String) throws -> URL {
        let doc = try PDFs.open(src)
        let out = output(for: src, ext: "pdf", suffix: " locked")
        try PDFs.save(doc, out, options: [.userPasswordOption: password, .ownerPasswordOption: password])
        return out
    }
}

// MARK: - Prompts

/// Small modal questions: pick one of several, or type a line of text.
enum Prompt {
    static func choose(_ title: String, _ message: String, _ options: [String]) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        pop.addItems(withTitles: options)
        alert.accessoryView = pop
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? options[pop.indexOfSelectedItem] : nil
    }

    static func text(_ title: String, _ message: String, initial: String = "", secret: Bool = false) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = secret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }
}
