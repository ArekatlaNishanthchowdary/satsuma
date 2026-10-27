import AppKit
import PDFKit
import QuickLookThumbnailing

// MARK: - LibreOffice (optional engine, like ffmpeg and pandoc)

extension Shell {
    static let soffice = ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                          NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// LibreOffice headless into a temp folder; returns the converted file there.
    static func office(_ src: URL, to ext: String, infilter: String? = nil) throws -> URL {
        guard let soffice else { throw Fail("This needs LibreOffice: https://www.libreoffice.org/download") }
        let dir = try tempDir()
        // A private profile, so a LibreOffice window the user has open doesn't swallow the job.
        var args = ["--headless", "--norestore", "-env:UserInstallation=\(dir.appendingPathComponent("profile").absoluteString)"]
        if let infilter { args.append("--infilter=\(infilter)") }
        try run(soffice, args + ["--convert-to", ext, "--outdir", dir.path, src.path])
        guard let out = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == ext })
        else { throw Fail("LibreOffice couldn't convert \(src.lastPathComponent)") }
        return out
    }
}

/// Writes a zip from in-memory parts. "mimetype" goes first and uncompressed, as ODF requires.
func writeZip(_ url: URL, _ parts: [String: Data]) throws {
    let dir = try tempDir()
    for (path, data) in parts {
        let file = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    if parts["mimetype"] != nil { try Shell.run("/usr/bin/zip", ["-X", "-0", "-q", url.path, "mimetype"], cwd: dir) }
    try Shell.run("/usr/bin/zip", ["-X", "-r", "-q", url.path, ".", "-x", "mimetype", "./mimetype"], cwd: dir)
}

private func xmlPart(_ s: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + s).utf8) }

// MARK: - Image → DOCX

enum DocxImage {
    /// A one-page DOCX holding the picture, scaled to fit 6.5" of text width.
    static func write(_ image: CGImage, to url: URL) throws {
        let png = try tempDir().appendingPathComponent("image1.png")
        try Img.write(image, to: png)
        let emuPerPx = 9525, maxCx = 5_943_600  // 96 DPI pixels → EMU
        var cx = image.width * emuPerPx, cy = image.height * emuPerPx
        if cx > maxCx { cy = cy * maxCx / cx; cx = maxCx }
        let rels = "http://schemas.openxmlformats.org/package/2006/relationships"
        let docRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        try writeZip(url, [
            "[Content_Types].xml": xmlPart("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
            "_rels/.rels": xmlPart("<Relationships xmlns=\"\(rels)\"><Relationship Id=\"rId1\" Type=\"\(docRel)/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
            "word/_rels/document.xml.rels": xmlPart("<Relationships xmlns=\"\(rels)\"><Relationship Id=\"rId1\" Type=\"\(docRel)/image\" Target=\"media/image1.png\"/></Relationships>"),
            "word/document.xml": xmlPart("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"\(docRel)\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body><w:p><w:r><w:drawing>"
                + "<wp:inline><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"1\" name=\"Picture 1\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
                + "<pic:nvPicPr><pic:cNvPr id=\"1\" name=\"image1.png\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline>"
                + "</w:drawing></w:r></w:p></w:body></w:document>"),
            "word/media/image1.png": try Data(contentsOf: png),
        ])
    }
}

// MARK: - ODS

/// OpenDocument spreadsheet: first table, values only, like `XLSX`.
enum ODS {
    static func write(_ rows: [[String]], to url: URL) throws {
        let cells = rows.map { row in
            "<table:table-row>" + row.map { v in
                (XLSX.isNumber(v) ? "<table:table-cell office:value-type=\"float\" office:value=\"\(v)\">" : "<table:table-cell office:value-type=\"string\">")
                    + v.components(separatedBy: "\n").map { "<text:p>\(XLSX.escape($0))</text:p>" }.joined() + "</table:table-cell>"
            }.joined() + "</table:table-row>"
        }.joined()
        try writeZip(url, [
            "mimetype": Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
            "META-INF/manifest.xml": xmlPart("<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"),
            "content.xml": xmlPart("<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet><table:table table:name=\"Sheet1\">\(cells)</table:table></office:spreadsheet></office:body></office:document-content>"),
        ])
    }

    static func read(_ url: URL) throws -> [[String]] {
        let parser = Reader()
        let xml = XMLParser(data: try Shell.run("/usr/bin/unzip", ["-p", url.path, "content.xml"]))
        xml.delegate = parser
        guard xml.parse() else { throw Fail("\(url.lastPathComponent) looks damaged") }
        return parser.rows
    }

    /// Repeated blank cells and rows (often a million of them) only count once something follows them.
    final class Reader: NSObject, XMLParserDelegate {
        var rows: [[String]] = []
        private var tables = 0, inFirst = false, blankRows = 0, rowRepeat = 1
        private var row: [String] = [], blankCells = 0, cellRepeat = 1, number: String?, paras: [String] = [], para: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            if name == "table:table" { tables += 1; inFirst = tables == 1 }
            guard inFirst else { return }
            switch name {
            case "table:table-row":
                row = []; blankCells = 0; rowRepeat = Int(a["table:number-rows-repeated"] ?? "") ?? 1
            case "table:table-cell", "table:covered-table-cell":
                paras = []; number = a["office:value"]; cellRepeat = Int(a["table:number-columns-repeated"] ?? "") ?? 1
            case "text:p": para = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { para? += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard inFirst else { return }
            switch name {
            case "table:table": inFirst = false
            case "text:p": paras.append(para ?? ""); para = nil
            case "table:table-cell", "table:covered-table-cell":
                var v = paras.joined(separator: "\n")
                if v.isEmpty { v = number ?? "" }
                if v.isEmpty { blankCells += cellRepeat; return }
                row += Array(repeating: "", count: blankCells) + Array(repeating: v, count: cellRepeat)
                blankCells = 0
            case "table:table-row":
                if row.isEmpty { blankRows += rowRepeat; return }
                rows += Array(repeating: [], count: blankRows) + Array(repeating: row, count: rowRepeat)
                blankRows = 0
            default: break
            }
        }
    }
}

// MARK: - Sheet → PDF

enum TablePDF {
    /// A ruled grid; the page widens to fit the columns instead of clipping them.
    static func write(_ rows: [[String]], to url: URL) throws {
        let font = NSFont.systemFont(ofSize: 9)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let margin: CGFloat = 36, height: CGFloat = 792, rowHeight: CGFloat = 16, pad: CGFloat = 4
        let cols = rows.map(\.count).max() ?? 0
        let widths = (0..<cols).map { c in
            min(240, rows.map { c < $0.count ? NSAttributedString(string: $0[c], attributes: attrs).size().width : 0 }.max() ?? 0) + 2 * pad
        }
        var box = CGRect(x: 0, y: 0, width: max(612, widths.reduce(0, +) + 2 * margin), height: height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw Fail("Couldn't write \(url.lastPathComponent)") }
        var y = height  // distance from the top of the page
        for row in rows.isEmpty ? [[]] : rows {
            if y + rowHeight > height - margin {
                if y < height { NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage() }
                ctx.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                y = margin
            }
            var x = margin
            for c in 0..<cols {
                let cell = CGRect(x: x, y: height - y - rowHeight, width: widths[c], height: rowHeight)
                ctx.setStrokeColor(NSColor.lightGray.cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(cell)
                if c < row.count {
                    let s = NSAttributedString(string: row[c].replacingOccurrences(of: "\n", with: " "), attributes: attrs)
                    ctx.saveGState()
                    ctx.clip(to: cell)
                    s.draw(at: CGPoint(x: x + pad, y: cell.midY - s.size().height / 2))
                    ctx.restoreGState()
                }
                x += widths[c]
            }
            y += rowHeight
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

// MARK: - Slides

/// Presentations go through LibreOffice to PDF, then out as PDF or page images.
enum Slides {
    static func convert(_ src: URL, to ext: String) throws -> URL {
        let pdf = try Shell.office(src, to: "pdf")
        if ext != "pdf" { return try PDFs.convert(pdf, to: ext, near: src) }
        let out = output(for: src, ext: "pdf")
        try FileManager.default.moveItem(at: pdf, to: out)
        return out
    }
}

// MARK: - Thumbnails and Float

enum Thumbs {
    /// Quick Look's thumbnail (falls back to the Finder icon), delivered on the main thread.
    static func get(_ url: URL, size: CGFloat, _ done: @escaping (NSImage) -> Void) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            DispatchQueue.main.async { done(rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)) }
        }
    }

    /// "2.4 MB", or "3 items · 7.1 MB"; folders aren't walked, so they add nothing.
    static func describe(_ urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        let bytes = urls.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        if urls.count == 1 { return urls[0].hasDirectoryPath ? "Folder" : size }
        return "\(urls.count) items · \(size)"
    }
}

/// An always-on-top preview of a file: the picture itself for images, the Quick Look thumbnail otherwise.
enum Float {
    private static var open: [NSPanel] = []

    // ponytail: still image only; video/audio playback would need an AVPlayerView.
    static func show(_ url: URL) {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = url.lastPathComponent
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        func fit(_ image: NSImage) {
            view.image = image
            let s = image.size, scale = min(1, 520 / max(s.width, s.height, 1))
            panel.setContentSize(NSSize(width: max(160, s.width * scale), height: max(120, s.height * scale)))
        }
        if Kind.of(url) == .image, let image = NSImage(contentsOf: url) { fit(image) }
        else { fit(NSWorkspace.shared.icon(forFile: url.path)); Thumbs.get(url, size: 512, fit) }
        panel.center()
        open.removeAll { !$0.isVisible }
        open.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
