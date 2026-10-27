import AppKit
import AVFoundation
import CoreImage
import PDFKit
import Quartz
import UniformTypeIdentifiers

struct Fail: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Shell

enum Shell {
    static func find(_ name: String) -> String? {
        // ~/.local/bin holds standalone builds installed without admin rights (Homebrew no longer ships Intel bottles).
        [NSHomeDirectory() + "/.local/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/bin/"].map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static let ffmpeg = find("ffmpeg")
    static let pandoc = find("pandoc")

    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Drain stderr on another thread so a chatty tool can't fill the pipe and stall.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Fail("\((exe as NSString).lastPathComponent) failed: \(String(msg.suffix(400)))")
        }
        return data
    }

    static func ffmpeg(_ args: [String]) throws {
        guard let ffmpeg else { throw Fail("This needs ffmpeg. Install it with: brew install ffmpeg") }
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args)
    }
}

// MARK: - Output paths

/// A free path beside `src`: "name<suffix>.ext", then "name<suffix> 2.ext", …
func output(for src: URL, ext: String, suffix: String = "") -> URL {
    let dir = src.deletingLastPathComponent()
    var base = src.deletingPathExtension().lastPathComponent
    if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
    base += suffix
    func make(_ name: String) -> URL { dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)") }
    var url = make(base), n = 2
    while FileManager.default.fileExists(atPath: url.path) { url = make("\(base) \(n)"); n += 1 }
    return url
}

func outputFolder(for src: URL, suffix: String = "") throws -> URL {
    let url = output(for: src, ext: "", suffix: suffix)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func onMain<T>(_ f: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try f() }
    return try DispatchQueue.main.sync(execute: f)
}

enum Convert {
    static func run(_ src: URL, to ext: String) throws -> URL {
        switch Kind.of(src) {
        case .image: return try Img.convert(src, to: ext)
        case .audio, .video: return try AV.convert(src, to: ext)
        case .pdf: return try PDFs.convert(src, to: ext)
        case .document: return try Docs.convert(src, to: ext)
        case .sheet: return try Sheets.convert(src, to: ext)
        case .subtitle: return try Subs.convert(src, to: ext)
        case .archive: return try Archive.convert(src, to: ext)
        case .slides: return try Slides.convert(src, to: ext)
        case .data: return try DataFiles.convert(src, to: ext)
        case .font: return try Fonts.convert(src, to: ext)
        case .other: throw Fail("Satsuma doesn't know how to convert \(src.lastPathComponent)")
        }
    }
}

// MARK: - Images

enum Img {
    static let context = CIContext()
    static let writable: Set = ["jpg", "png", "heic", "tiff", "bmp", "gif"]

    static func load(_ url: URL) throws -> CGImage {
        if let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
           let cg = context.createCGImage(ci, from: ci.extent) { return cg }
        // SVG and friends: let AppKit rasterise.
        if let ns = NSImage(contentsOf: url), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        if Shell.ffmpeg != nil {
            let png = try tempDir().appendingPathComponent("frame.png")
            try Shell.ffmpeg(["-i", url.path, png.path])
            return try load(png)
        }
        throw Fail("Can't read the image \(url.lastPathComponent)")
    }

    static func write(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "webp", "avif":
            let png = try tempDir().appendingPathComponent("in.png")
            try write(image, to: png)
            try Shell.ffmpeg(["-i", png.path, url.path])
        case "pdf":
            let doc = PDFDocument()
            guard let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else { throw Fail("Couldn't make a PDF page") }
            doc.insert(page, at: 0)
            guard doc.write(to: url) else { throw Fail("Couldn't write \(url.lastPathComponent)") }
        case "docx":
            try DocxImage.write(image, to: url)
        case "ico", "icns":
            try IconFile.write(image, to: url)
        default:
            guard let type = UTType(filenameExtension: ext),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
            else { throw Fail("Can't write \(ext.uppercased()) images") }
            let opaque = ext == "jpg" || ext == "jpeg" || ext == "bmp"
            let img = opaque ? try flatten(image) : image
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw Fail("Couldn't write \(url.lastPathComponent)") }
        }
    }

    /// Put transparent images on white so JPEG doesn't turn the background black.
    static func flatten(_ image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Fail("Out of memory") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()!
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = output(for: src, ext: ext)
        try write(load(src), to: out)
        return out
    }

    /// Same format as the source when we can write it, else PNG.
    static func sameFormat(_ src: URL) -> String {
        let e = normExt(src)
        return writable.contains(e) || (Shell.ffmpeg != nil && (e == "webp" || e == "avif")) ? e : "png"
    }

    static func transform(_ src: URL, suffix: String, _ f: (CIImage) -> CIImage) throws -> URL {
        let result = f(CIImage(cgImage: try load(src)))
        guard let cg = context.createCGImage(result, from: result.extent) else { throw Fail("Couldn't process the image") }
        let out = output(for: src, ext: sameFormat(src), suffix: suffix)
        try write(cg, to: out, quality: 0.92)
        return out
    }

    static func readQR(_ urls: [URL]) throws {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        var found: [String] = []
        for url in urls {
            let features = detector?.features(in: CIImage(cgImage: try load(url))) ?? []
            found += features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }
        guard !found.isEmpty else { throw Fail("No QR code found.") }
        let text = found.joined(separator: "\n")
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notify("QR code copied", text)
        }
    }

    static func makePDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            guard let page = PDFPage(image: NSImage(cgImage: try load(url), size: .zero)) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        let out = output(for: urls[0], ext: "pdf", suffix: " images")
        guard doc.write(to: out) else { throw Fail("Couldn't write the PDF") }
        return out
    }
}

// MARK: - Audio & video

enum AV {
    static let audioExts: Set = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    // What AVFoundation and afconvert can open; MKV, WebM, AVI, WMV, OGG… need ffmpeg.
    static let nativeExts: Set = ["mp4", "mov", "m4v", "3gp", "m4a", "mp3", "wav", "aiff", "aif", "aifc", "caf", "flac", "aac"]

    static func requireNative(_ src: URL) throws {
        let ext = src.pathExtension.lowercased()
        guard !nativeExts.contains(ext) else { return }
        throw Fail("macOS can't read \(ext.uppercased()) files by itself. Put ffmpeg in ~/.local/bin or /usr/local/bin, then reopen Satsuma.")
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = output(for: src, ext: ext)
        let isVideo = Kind.of(src) == .video
        if Shell.ffmpeg != nil {
            var args = ["-i", src.path]
            if ext == "gif" { args += ["-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos", "-loop", "0"] }
            if ext == "mp4" { args += ["-pix_fmt", "yuv420p"] }
            if isVideo && audioExts.contains(ext) { args += ["-vn"] }
            try Shell.ffmpeg(args + [out.path])
        } else if isVideo {
            try requireNative(src)
            try avconvert(src, out, preset: ext == "m4a" ? "PresetAppleM4A" : "PresetHighestQuality")
        } else {
            let fmt = ["m4a": ["-f", "m4af", "-d", "aac"], "wav": ["-f", "WAVE", "-d", "LEI16"],
                       "aiff": ["-f", "AIFF", "-d", "BEI16"], "flac": ["-f", "flac", "-d", "flac"]][ext] ?? []
            try requireNative(src)
            try Shell.run("/usr/bin/afconvert", fmt + [src.path, out.path])
        }
        return out
    }

    static func avconvert(_ src: URL, _ out: URL, preset: String) throws {
        try requireNative(src)
        try Shell.run("/usr/bin/avconvert", ["--source", src.path, "--output", out.path, "--preset", preset, "--replace"])
    }

    static func ff(_ src: URL, ext: String? = nil, suffix: String, _ args: [String]) throws -> URL {
        let out = output(for: src, ext: ext ?? normExt(src), suffix: suffix)
        try Shell.ffmpeg(["-i", src.path] + args + [out.path])
        return out
    }

    static func snapshot(_ src: URL) throws -> URL {
        if Shell.ffmpeg != nil {
            let mid = ((try? AVEdit.probe(src).duration) ?? 0) / 2
            let out = output(for: src, ext: "png", suffix: " snapshot")
            try Shell.ffmpeg(["-ss", String(format: "%.2f", mid), "-i", src.path, "-frames:v", "1", out.path])
            return out
        }
        try requireNative(src)
        let asset = AVURLAsset(url: src)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: asset.duration.seconds / 2, preferredTimescale: 600)
        let image = try gen.copyCGImage(at: time, actualTime: nil)
        let out = output(for: src, ext: "png", suffix: " snapshot")
        try Img.write(image, to: out)
        return out
    }

    static func compressVideo(_ src: URL) throws -> URL {
        if Shell.ffmpeg != nil {
            return try ff(src, ext: "mp4", suffix: " compressed",
                          ["-c:v", "libx264", "-crf", "28", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k"])
        }
        let out = output(for: src, ext: "mp4", suffix: " compressed")
        try avconvert(src, out, preset: "Preset1280x720")
        return out
    }

    static func extractAudio(_ src: URL) throws -> URL {
        if Shell.ffmpeg != nil { return try ff(src, ext: "m4a", suffix: "", ["-vn", "-c:a", "aac", "-b:a", "192k"]) }
        let out = output(for: src, ext: "m4a")
        try avconvert(src, out, preset: "PresetAppleM4A")
        return out
    }

    static func monoNative(_ src: URL) throws -> URL {
        let out = output(for: src, ext: "m4a", suffix: " mono")
        try requireNative(src)
        try Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-c", "1", src.path, out.path])
        return out
    }

    // ponytail: stream copy, so the files must share codecs; re-encode if mixed sources become common.
    static func join(_ urls: [URL]) throws -> URL {
        let list = try tempDir().appendingPathComponent("list.txt")
        try urls.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let out = output(for: urls[0], ext: normExt(urls[0]), suffix: " joined")
        try Shell.ffmpeg(["-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", out.path])
        return out
    }
}

// MARK: - PDF

enum PDFs {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw Fail("Can't open \(url.lastPathComponent)") }
        return doc
    }

    static func save(_ doc: PDFDocument, _ url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else { throw Fail("Couldn't write \(url.lastPathComponent)") }
    }

    /// `near` names the output when `src` is an intermediate temp PDF.
    static func convert(_ src: URL, to ext: String, near: URL? = nil) throws -> URL {
        let doc = try open(src)
        let base = near ?? src
        switch ext {
        case "png", "jpg":
            if doc.pageCount == 1 {
                let out = output(for: base, ext: ext)
                try Img.write(render(doc.page(at: 0)!), to: out)
                return out
            }
            let dir = try outputFolder(for: base, suffix: " pages")
            for i in 0..<doc.pageCount {
                try Img.write(render(doc.page(at: i)!), to: dir.appendingPathComponent("page \(i + 1).\(ext)"))
            }
            return dir
        case "txt", "md":
            let out = output(for: base, ext: ext)
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        case "pptx":
            let out = output(for: base, ext: ext)
            try FileManager.default.moveItem(at: Shell.office(src, to: "pptx", infilter: "impress_pdf_import"), to: out)
            return out
        case "xlsx":
            // ponytail: one row per text line, columns split on runs of 2+ spaces; real table detection is a layout-analysis project.
            let rows = (doc.string ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { $0.replacingOccurrences(of: "\\s{2,}|\t", with: "\u{1F}", options: .regularExpression).components(separatedBy: "\u{1F}") }
            let out = output(for: base, ext: ext)
            try Sheets.write(rows, to: out)
            return out
        default:
            let text = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let a = doc.page(at: i)?.attributedString { text.append(a) }
                text.append(NSAttributedString(string: "\n\n"))
            }
            let out = output(for: base, ext: ext)
            try Docs.write(text, to: out)
            return out
        }
    }

    /// One page at 300 DPI on white.
    static func render(_ page: PDFPage) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300 / 72
        guard let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Fail("Page too large to render") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()!
    }

    static func compress(_ src: URL) throws -> URL {
        let doc = try open(src)
        let out = output(for: src, ext: "pdf", suffix: " compressed")
        let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
        try save(doc, out, options: filter.map { [PDFDocumentWriteOption(rawValue: "QuartzFilter"): $0] } ?? [:])
        return out
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = output(for: urls[0], ext: "pdf", suffix: " merged")
        try save(merged, out)
        return out
    }

    static func split(_ src: URL) throws -> URL {
        let doc = try open(src)
        let dir = try outputFolder(for: src, suffix: " pages")
        let base = src.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            try save(single, dir.appendingPathComponent("\(base) \(i + 1).pdf"))
        }
        return dir
    }

    static func rotate(_ src: URL) throws -> URL {
        let doc = try open(src)
        for i in 0..<doc.pageCount { doc.page(at: i)!.rotation = (doc.page(at: i)!.rotation + 90) % 360 }
        let out = output(for: src, ext: "pdf", suffix: " rotated")
        try save(doc, out)
        return out
    }

    static func strip(_ src: URL) throws -> URL {
        let doc = try open(src)
        doc.documentAttributes = [:]
        let out = output(for: src, ext: "pdf", suffix: " clean")
        try save(doc, out)
        return out
    }
}

// MARK: - Documents

enum Docs {
    static let pandocReadable: Set = ["md", "txt", "docx", "odt", "html", "rtf", "epub"]

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = output(for: src, ext: ext)
        let srcExt = normExt(src)
        if ext == "epub", let pandoc = Shell.pandoc {
            var input = src
            if !pandocReadable.contains(srcExt) {
                input = try tempDir().appendingPathComponent("in.html")
                try write(read(src), to: input)
            }
            try Shell.run(pandoc, [input.path, "-o", out.path])
        } else {
            try write(read(src), to: out)
        }
        return out
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = normExt(url)
        // With pandoc, Markdown keeps its headings and lists; EPUB needs it outright.
        if let pandoc = Shell.pandoc, ext == "md" || ext == "epub" {
            let html = try tempDir().appendingPathComponent("doc.html")
            try Shell.run(pandoc, [url.path, "-s", "-o", html.path])
            return try read(html)
        }
        switch ext {
        case "txt":
            return NSAttributedString(string: try String(contentsOf: url))
        case "md":
            let md = try AttributedString(markdown: try String(contentsOf: url),
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return NSAttributedString(md)
        default:
            // HTML import uses WebKit, which wants the main thread.
            return try onMain { try NSAttributedString(url: url, options: [:], documentAttributes: nil) }
        }
    }

    static func write(_ text: NSAttributedString, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "md":
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            try onMain { try printPDF(text, to: url) }
        case "epub":
            guard let pandoc = Shell.pandoc else { throw Fail("EPUB needs pandoc") }
            let html = try tempDir().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".html")
            try write(text, to: html)
            try Shell.run(pandoc, [html.path, "-o", url.path, "--metadata", "title=" + url.deletingPathExtension().lastPathComponent])
        default:
            let types: [String: NSAttributedString.DocumentType] =
                ["docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat]
            guard let type = types[ext] else { throw Fail("Can't write \(ext.uppercased()) documents") }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            try data.write(to: url)
        }
    }

    /// Lays the text out on US Letter pages and "prints" straight to a file.
    static func printPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 72; info.bottomMargin = 72; info.leftMargin = 72; info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 144, height: 792 - 144))
        view.appearance = NSAppearance(named: .aqua)
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw Fail("Couldn't make the PDF") }
    }
}

// MARK: - Spreadsheets

enum Sheets {
    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = output(for: src, ext: ext)
        try write(read(src), to: out)
        return out
    }

    static func read(_ url: URL) throws -> [[String]] {
        switch normExt(url) {
        case "xlsx": return try XLSX.read(url)
        case "ods": return try ODS.read(url)
        case "xls": return try XLSX.read(Shell.office(url, to: "xlsx"))
        case "tsv": return parse(try String(contentsOf: url), sep: "\t")
        default: return parse(try String(contentsOf: url), sep: ",")
        }
    }

    static func write(_ rows: [[String]], to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "xlsx": try XLSX.write(rows, to: url)
        case "ods": try ODS.write(rows, to: url)
        case "pdf": try TablePDF.write(rows, to: url)
        case "tsv": try format(rows, sep: "\t").write(to: url, atomically: true, encoding: .utf8)
        case "json": try DataFiles.writeRows(rows, to: url)
        default: try format(rows, sep: ",").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// RFC 4180: quoted fields may hold separators, newlines and doubled quotes.
    static func parse(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func format(_ rows: [[String]], sep: Character) -> String {
        rows.map { row in
            row.map { f in
                f.contains(sep) || f.contains("\"") || f.contains("\n") || f.contains("\r")
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: String(sep))
        }.joined(separator: "\n") + "\n"
    }
}

/// Just enough of Office Open XML for one sheet of values.
enum XLSX {
    static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { s = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + s; n = (n - 1) / 26 }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func isNumber(_ s: String) -> Bool {
        // Keep leading-zero codes ("01234") as text, like Excel's own CSV import would not.
        Double(s) != nil && (s == "0" || !s.hasPrefix("0") || s.hasPrefix("0."))
    }

    static func write(_ rows: [[String]], to url: URL) throws {
        let dir = try tempDir()
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let rels = "http://schemas.openxmlformats.org/package/2006/relationships"
        let docRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let sheetRows = rows.enumerated().map { r, row in
            "<row r=\"\(r + 1)\">" + row.enumerated().map { c, v in
                let ref = "\(column(c))\(r + 1)"
                return isNumber(v) ? "<c r=\"\(ref)\"><v>\(v)</v></c>"
                    : "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(v))</t></is></c>"
            }.joined() + "</row>"
        }.joined()
        let files = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>",
            "_rels/.rels": "<Relationships xmlns=\"\(rels)\"><Relationship Id=\"rId1\" Type=\"\(docRel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            "xl/workbook.xml": "<workbook xmlns=\"\(main)\" xmlns:r=\"\(docRel)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(rels)\"><Relationship Id=\"rId1\" Type=\"\(docRel)/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(main)\"><sheetData>\(sheetRows)</sheetData></worksheet>",
        ]
        for (path, xml) in files {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (head + xml).write(to: file, atomically: true, encoding: .utf8)
        }
        try Shell.run("/usr/bin/zip", ["-X", "-r", "-q", url.path, "."], cwd: dir)
    }

    // ponytail: first sheet only, values not formulas; dates come out as Excel serial numbers.
    static func read(_ url: URL) throws -> [[String]] {
        let entries = String(decoding: try Shell.run("/usr/bin/unzip", ["-Z1", url.path]), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard let sheet = entries.contains("xl/worksheets/sheet1.xml") ? "xl/worksheets/sheet1.xml"
                : entries.filter({ $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }).sorted().first
        else { throw Fail("No worksheet in \(url.lastPathComponent)") }
        let parser = SheetXML()
        if entries.contains("xl/sharedStrings.xml") {
            XMLParser(data: try Shell.run("/usr/bin/unzip", ["-p", url.path, "xl/sharedStrings.xml"])).delegate(parser).parse()
        }
        XMLParser(data: try Shell.run("/usr/bin/unzip", ["-p", url.path, sheet])).delegate(parser).parse()
        return parser.rows
    }
}

private extension XMLParser {
    func delegate(_ d: XMLParserDelegate) -> XMLParser { delegate = d; return self }
}

/// Reads both sharedStrings.xml (<si><t>) and a worksheet (<c><v>|<is><t>).
final class SheetXML: NSObject, XMLParserDelegate {
    var shared: [String] = []
    var rows: [[String]] = []
    private var text = "", capturing = false, item = "", ref = "", type = "", value = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "si": item = ""
        case "c": ref = attributes["r"] ?? ""; type = attributes["t"] ?? ""; value = ""
        case "t", "v": text = ""; capturing = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "t": capturing = false; item += text; value += text
        case "v": capturing = false; value = text
        case "si": shared.append(item)
        case "c": store()
        default: break
        }
    }

    private func store() {
        let letters = ref.prefix { $0.isLetter }, digits = ref.drop { $0.isLetter }
        guard let r = Int(digits) else { return }
        let c = letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        let v = type == "s" ? Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? "" : value
        while rows.count < r { rows.append([]) }
        while rows[r - 1].count <= c { rows[r - 1].append("") }
        rows[r - 1][c] = v
    }
}

// MARK: - Archives

enum Archive {
    /// macOS `tar` is bsdtar, which also reads zip, rar and 7z.
    static func extract(_ src: URL) throws -> URL {
        let dest = try outputFolder(for: src)
        let name = src.lastPathComponent.lowercased()
        if name.hasSuffix(".gz") && !name.hasSuffix(".tar.gz") {
            let data = try Shell.run("/usr/bin/gzip", ["-dc", src.path])
            try data.write(to: dest.appendingPathComponent(src.deletingPathExtension().lastPathComponent))
        } else {
            try Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", dest.path])
        }
        return dest
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let unpacked = try extract(src)
        let staged = tmp.appendingPathComponent("x")
        try FileManager.default.moveItem(at: unpacked, to: staged)
        let names = try FileManager.default.contentsOfDirectory(atPath: staged.path)
        let out = output(for: src, ext: ext)
        try pack(names, in: staged, to: out, ext: ext)
        return out
    }

    // ponytail: assumes the files share a folder (true for any Finder drag).
    static func zip(_ urls: [URL]) throws -> URL {
        let parent = urls[0].deletingLastPathComponent()
        let out = urls.count == 1 ? output(for: urls[0], ext: "zip") : output(for: parent.appendingPathComponent("Archive"), ext: "zip")
        try pack(urls.map(\.lastPathComponent), in: parent, to: out, ext: "zip")
        return out
    }

    static func pack(_ names: [String], in dir: URL, to out: URL, ext: String) throws {
        switch ext {
        case "zip": try Shell.run("/usr/bin/zip", ["-r", "-y", "-q", out.path] + names, cwd: dir)
        case "tar": try Shell.run("/usr/bin/tar", ["-cf", out.path] + names, cwd: dir)
        default: try Shell.run("/usr/bin/tar", ["-czf", out.path] + names, cwd: dir)
        }
    }
}
