import AppKit
import CoreText
import PDFKit

/// `Satsuma --selftest`: round-trips one file of each native format through the real ops.
enum SelfTest {
    /// The audio/video editors' ffmpeg jobs, on a generated 4 s test video and a stereo tone.
    static func mediaChecks(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.25 }
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max }
        let v = dir.appendingPathComponent("v.mp4"), a = dir.appendingPathComponent("a.wav")
        try Shell.ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", v.path])
        try Shell.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-ac", "2", a.path])
        let m = try AVEdit.probe(v)
        check(near(m.duration, 4) && m.hasVideo && m.hasAudio && m.width == 320 && m.height == 240, "probe video")
        check(near(try AVEdit.probe(AVEdit.trim(v, from: 1, to: 3)).duration, 2), "trim 1–3 s")
        check(near(try AVEdit.probe(AVEdit.speed(v, m, 2)).duration, 2), "speed 2×")
        check(AVEdit.atempo(0.25) == "atempo=0.5,atempo=0.5" && AVEdit.atempo(4) == "atempo=2,atempo=2", "atempo chains past 0.5–2")
        let cropped = try AVEdit.probe(AVEdit.cropVideo(v, CGRect(x: 10, y: 10, width: 100, height: 80)))
        check(cropped.width == 100 && cropped.height == 80, "video crop")
        for style in RedactStyle.allCases {
            check(try AVEdit.probe(AVEdit.redactVideo(v, [CGRect(x: 20, y: 20, width: 120, height: 90), CGRect(x: 200, y: 100, width: 60, height: 60)], style)).width == 320,
                  "video redact (\(style.rawValue))")
        }
        let small = try AVEdit.compress(v, target: 100_000)
        check(size(small) <= 100_000, "compress video to 100 KB (\(size(small) / 1000) KB)")
        check(try AVEdit.picture(v, m, .orange).width == 1600, "video frame strip + waveform")
        let am = try AVEdit.probe(a)
        check(try AVEdit.picture(a, am, .orange).width == 1600, "waveform picture")
        check(near(try AVEdit.probe(AVEdit.bleep(a, [(1, 2), (2.5, 3)])).duration, 4), "bleep keeps the length")
        check(try Data(contentsOf: AVEdit.channels(a, .left, 1, 1))[22] == 1, "channels: left only is mono")
        check(try Data(contentsOf: AVEdit.channels(a, .swap, 1, 0.5))[22] == 2, "channels: swap stays stereo")
        let viz = try AVEdit.probe(AVEdit.visualize(a, .wave, .orange))
        check(viz.width == 1280 && viz.height == 720 && near(viz.duration, 4), "visualize → 1280×720 video")
        check(try FileManager.default.contentsOfDirectory(atPath: AVEdit.split(a, am, cuts: [], parts: 2).path).count == 2, "split into 2 equal parts")
        check(try FileManager.default.contentsOfDirectory(atPath: AVEdit.split(v, m, cuts: [1, 2.5], parts: 2).path).count == 3, "split video at 1 s and 2.5 s")
        check(size(try AVEdit.compress(a, target: 60_000)) <= 60_000, "compress audio to 60 KB")
        let mkv = try AV.ff(v, ext: "mkv", suffix: "", ["-c", "copy"])
        check(try Img.load(AV.snapshot(mkv)).width == 320, "snapshot of an MKV (ffmpeg)")
    }

    /// The pure functions behind the image editors (the windows themselves are checked by eye via --shot editor-…).
    static func editorChecks(_ img: CGImage, _ check: (Bool, String) -> Void) throws {
        func at(_ i: CGImage, _ x: Int, _ y: Int, _ c: Int) throws -> UInt8 {
            let (ctx, px) = try ImageEdit.pixels(i)
            return withExtendedLifetime(ctx) { px[(y * i.width + x) * 4 + c] }  // the pointer dies with its context
        }
        check(try ImageEdit.adjust(img, Adjustments()) === img, "edit: zero sliders leave the picture alone")
        check(try at(ImageEdit.adjust(img, Adjustments(exposure: 50)), 5, 5, 1) > at(img, 5, 5, 1), "edit: exposure brightens")
        let gray = try ImageEdit.adjust(img, Adjustments(saturation: -100))
        check(abs(Int(try at(gray, 5, 5, 0)) - Int(try at(gray, 5, 5, 2))) <= 1, "edit: saturation −100 is gray")
        let cropped = try ImageEdit.crop(img, CGRect(x: 10, y: 5, width: 20, height: 30))
        check(cropped.width == 20 && cropped.height == 30, "crop to rect")
        let black = try ImageEdit.redact(img, [CGRect(x: 0, y: 0, width: 16, height: 16)], .black)
        check(try at(black, 8, 8, 0) == 0 && at(black, 20, 20, 0) == at(img, 20, 20, 0), "redact black stays inside its box")
        let pix = try ImageEdit.redact(img, [CGRect(x: 24, y: 0, width: 16, height: 48)], .pixelate)
        check(try at(pix, 24, 0, 0) == at(pix, 29, 5, 0), "redact pixelate makes blocks")
        let blur = try ImageEdit.redact(img, [CGRect(x: 24, y: 0, width: 16, height: 48)], .blur)
        check(try (1...254).contains(at(blur, 31, 20, 0)) && at(blur, 50, 20, 0) == at(img, 50, 20, 0), "redact blur softens the edge only inside")
        let marked = try ImageEdit.annotate(img, [Mark(kind: .box, points: [CGPoint(x: 4, y: 4), CGPoint(x: 60, y: 44)], color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), width: 3)])
        check(try marked.width == 64 && at(marked, 4, 20, 1) > 200 && at(marked, 4, 20, 0) < 80, "annotate draws a box")
        let square = try ImageEdit.addBackground(img, BackgroundStyle(from: .orange, to: .purple, ratio: 1))
        check(square.width == square.height && square.width > 64, "add background, 1:1")
        // Noise compresses badly, so the size search has real work to do.
        let ctx = try ImageEdit.canvas(800, 600)
        var rng = SystemRandomNumberGenerator()
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(800 * 600 * 4) { px[i] = i % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &rng) }
        let jpg = try ImageEdit.encodeUnder(ctx.makeImage()!, target: 60_000)
        check(jpg.count <= 60_000 && jpg.count > 20_000, "compress to 60 KB (\(jpg.count / 1000) KB)")
    }

    /// The formats and tools that came over from Filee, plus wheel layouts and watch folders.
    static func extraChecks(_ dir: URL, png: URL, pdf: URL, _ check: (Bool, String) -> Void) throws {
        func f(_ name: String) -> URL { dir.appendingPathComponent(name) }
        func read(_ u: URL) throws -> String { try String(contentsOf: u) }

        let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello, there\nsecond line\n\n2\n00:01:03,050 --> 00:01:04,000\nWorld\n"
        try srt.write(to: f("x.srt"), atomically: true, encoding: .utf8)
        for via in ["ass", "sbv", "vtt"] {
            check(try read(Convert.run(Convert.run(f("x.srt"), to: via), to: "srt")) == srt, "srt → \(via) → srt")
        }
        let lrc = try read(Convert.run(f("x.srt"), to: "lrc"))
        check(lrc.contains("[00:01.00]Hello, there second line") && lrc.contains("[01:03.05]World"), "srt → lrc")
        try "[ar:Someone]\n[00:12.00][00:30.50]Chorus\n[00:20.00]Verse\n".write(to: f("y.lrc"), atomically: true, encoding: .utf8)
        let fromLrc = try read(Convert.run(f("y.lrc"), to: "srt"))
        check(fromLrc.contains("00:00:12,000 --> 00:00:20,000\nChorus") && fromLrc.contains("00:00:30,500 --> 00:00:34,500\nChorus"), "lrc (repeated tags) → srt")

        try #"[{"name": "Ann", "age": 31, "zip": "01234", "tags": ["a", "b"]}, {"name": "Bo", "ok": true}]"#.write(to: f("p.json"), atomically: true, encoding: .utf8)
        let rows = try Sheets.read(Convert.run(f("p.json"), to: "csv"))
        check(rows[0] == ["name", "age", "zip", "tags", "ok"] && rows[1][3] == #"["a","b"]"# && rows[2][4] == "true", "json → csv")
        let back = try JSON.parse(Data(contentsOf: Convert.run(Convert.run(f("p.json"), to: "csv"), to: "json")))
        check(back[0]?["age"] == .num("31") && back[0]?["zip"] == .str("01234") && back[1]?["ok"] == .bool(true), "csv → json keeps 31, \"01234\" and true")
        let xml = try Convert.run(f("p.json"), to: "xml")
        check(try XMLDocument(contentsOf: xml).rootElement()?.elements(forName: "item").count == 2, "json → xml")
        let again = try JSON.parse(Data(contentsOf: Convert.run(xml, to: "json")))
        check(again["root"]?["item"]?[0]?["tags"]?[1] == .str("b"), "xml → json")
        let yaml = try read(Convert.run(f("p.json"), to: "yaml"))
        check(yaml.hasPrefix("-\n  name: Ann\n  age: 31\n  zip: \"01234\"\n  tags:\n    - a\n") && yaml.contains("ok: true"), "json → yaml")
        check(try JSON.parse(Data(#"{"e": "é😀\n"}"#.utf8))["e"] == .str("é😀\n"), "json escapes and surrogate pairs")

        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf"), to: f("f.ttf"))
        check(Fonts.targets(f("f.ttf")) == ["woff"], "ttf offers woff")
        let woff = try Convert.run(f("f.ttf"), to: "woff")
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        check(Double(size(woff)) < Double(size(f("f.ttf"))) * 0.8 && Fonts.targets(woff) == ["ttf"], "ttf → woff is smaller, knows it holds a ttf")
        let ttf = try Convert.run(woff, to: "ttf")
        let family = (CTFontManagerCreateFontDescriptorsFromURL(ttf as CFURL) as? [CTFontDescriptor])?.first
            .flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        let rewoffed = try Fonts.toWoff([UInt8](Data(contentsOf: ttf))), original = [UInt8](try Data(contentsOf: woff))
        check(family == "Arial" && rewoffed == original, "woff → ttf loads as Arial, same tables")

        let ico = try Convert.run(png, to: "ico")
        let src = CGImageSourceCreateWithURL(ico as CFURL, nil)!
        check(CGImageSourceGetCount(src) == 7 && (0..<7).map { CGImageSourceCreateImageAtIndex(src, $0, nil)?.width ?? 0 }.max() == 256, "png → ico (16…256 px)")
        let icns = [UInt8](try Data(contentsOf: Convert.run(png, to: "icns")))
        check(String(decoding: icns[0..<4], as: UTF8.self) == "icns" && Int(Fonts.u32(icns, 4)) == icns.count && NSImage(data: Data(icns)) != nil, "png → icns")

        check(PDFDocument(url: try Stamp.watermark(pdf, "DRAFT"))?.string?.contains("DRAFT") == true, "pdf watermark")
        let numbered = try Catalog.ops(.tools, [pdf]).first { $0.title == "Page Numbers" }!.run([pdf])[0]
        check(PDFDocument(url: numbered)?.string?.contains("1 / 1") == true, "pdf page numbers")
        let locked = PDFDocument(url: try Stamp.protect(pdf, "s3cret"))!
        check(locked.isLocked && locked.unlock(withPassword: "s3cret") && locked.pageCount == 1, "pdf password")

        // Layouts and watch folders live in the user's defaults; leave them as they were.
        let savedLayout = Layout.get(.pdf, .tools)
        defer { if let savedLayout { Layout.set(.pdf, .tools, savedLayout) } else { Layout.reset(.pdf, .tools) } }
        Layout.set(.pdf, .tools, [("Merge", false), ("Compress", true)])
        let titles = Catalog.ops(.tools, [pdf, pdf]).map(\.title)
        check(titles.first == "Merge" && !titles.contains("Compress") && titles.contains("Watermark"), "wheel layout: reorder and hide")

        let inbox = f("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { Watch.remove(inbox.path) }
        Watch.add(inbox.path, "jpg")
        try FileManager.default.copyItem(at: png, to: inbox.appendingPathComponent("dropped.png"))
        let jpg = inbox.appendingPathComponent("dropped.jpg")
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: jpg.path) { Watch.tick(); Thread.sleep(forTimeInterval: 0.25) }
        check(FileManager.default.fileExists(atPath: jpg.path), "watch folder converts a new file")
    }

    static func run() {
        do {
            let dir = try tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            func check(_ ok: Bool, _ what: String) {
                print(ok ? "ok   \(what)" : "FAIL \(what)")
                if !ok { exit(1) }
            }
            func tool(_ title: String, _ urls: [URL]) throws -> [URL] {
                guard let op = Catalog.ops(.tools, urls).first(where: { $0.title == title }) else { throw Fail("no tool \(title)") }
                return try op.run(urls)
            }

            let csv = dir.appendingPathComponent("t.csv")
            let rows = [["name", "qty"], ["a, \"b\"", "3"], ["zip", "01234"]]
            try Sheets.format(rows, sep: ",").write(to: csv, atomically: true, encoding: .utf8)
            check(Sheets.parse(try String(contentsOf: csv), sep: ",") == rows, "csv quoting round-trip")
            let xlsx = try Convert.run(csv, to: "xlsx")
            check(try Sheets.read(xlsx) == rows, "csv → xlsx → rows")
            check(try Sheets.read(Convert.run(xlsx, to: "tsv")) == rows, "xlsx → tsv")
            let ods = try Convert.run(csv, to: "ods")
            check(try Sheets.read(ods) == rows, "csv → ods → rows")
            check(PDFDocument(url: try Convert.run(ods, to: "pdf"))?.string?.contains("qty") == true, "ods → pdf table")

            let srt = dir.appendingPathComponent("s.srt")
            try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n"
                .write(to: srt, atomically: true, encoding: .utf8)
            let vtt = try String(contentsOf: Convert.run(srt, to: "vtt"))
            check(vtt.hasPrefix("WEBVTT") && vtt.contains("00:00:01.000 --> 00:00:02.500"), "srt → vtt")

            let txt = dir.appendingPathComponent("d.txt")
            try "Hello Satsuma".write(to: txt, atomically: true, encoding: .utf8)
            let docx = try Convert.run(txt, to: "docx")
            check(try String(contentsOf: Convert.run(docx, to: "txt")).contains("Hello Satsuma"), "txt → docx → txt")
            let pdf = try Convert.run(txt, to: "pdf")
            check(PDFDocument(url: pdf)?.string?.contains("Hello Satsuma") == true, "txt → pdf")
            check(try Sheets.read(Convert.run(pdf, to: "xlsx")).contains { $0.contains("Hello Satsuma") }, "pdf → xlsx")
            if Shell.pandoc != nil {
                check(try Docs.read(Convert.run(pdf, to: "epub")).string.contains("Hello Satsuma"), "pdf → epub (pandoc)")
            }

            let png = dir.appendingPathComponent("i.png")
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            try Img.write(ctx.makeImage()!, to: png)
            check(try Img.load(Convert.run(png, to: "jpg")).width == 64, "png → jpg")
            let imgPdf = try Convert.run(png, to: "pdf")
            check(PDFDocument(url: imgPdf)?.pageCount == 1, "png → pdf")
            let merged = try PDFs.merge([pdf, imgPdf])
            let org = PDFDocument(url: try PDFs.organize(merged, [(1, 0), (0, 270)]))!
            check(org.pageCount == 2 && org.page(at: 1)!.rotation == 270
                  && org.page(at: 0)!.bounds(for: .mediaBox).width == PDFDocument(url: imgPdf)!.page(at: 0)!.bounds(for: .mediaBox).width, "organize: reorder + turn")
            check(PDFDocument(url: try PDFs.organize(merged, [(0, 0)]))?.pageCount == 1, "organize: delete")
            let collage = try Img.load(tool("Collage", [png, png, png])[0])
            check(collage.width == 24 + 2 * 824 && collage.height == 24 + 2 * 624, "collage 2×2 grid")
            check(try Img.load(tool("Resize 50%", [png])[0]).width == 32, "resize 50%")
            try editorChecks(Img.load(png), check)
            let imgDocx = try Convert.run(png, to: "docx")
            check(String(decoding: try Shell.run("/usr/bin/unzip", ["-Z1", imgDocx.path]), as: UTF8.self).contains("word/media/image1.png"), "png → docx")
            check(try Img.load(Convert.run(png, to: "heic")).width == 64, "png → heic")

            let zip = try tool("Zip", [csv])[0]
            let unpacked = try tool("Extract", [zip])[0]
            check(try String(contentsOf: unpacked.appendingPathComponent("t.csv")) == String(contentsOf: csv), "zip → extract")

            if Shell.ffmpeg != nil {
                let webp = try Convert.run(Convert.run(png, to: "jpg"), to: "webp")
                check(FileManager.default.fileExists(atPath: webp.path), "jpg → webp (ffmpeg)")
            }
            if Shell.ffmpeg != nil { try mediaChecks(dir, check) }
            check((try? AV.requireNative(dir.appendingPathComponent("x.mkv"))) == nil && (try? AV.requireNative(dir.appendingPathComponent("x.MP4"))) != nil,
                  "without ffmpeg, MKV is refused with a clear message")
            if Shell.pandoc != nil {
                let md = dir.appendingPathComponent("m.md")
                try "# Title\n\nSome *text*.".write(to: md, atomically: true, encoding: .utf8)
                check(try Docs.read(Convert.run(md, to: "docx")).string.contains("Title"), "md → docx (pandoc)")
            }

            if Shell.soffice != nil {
                check(try Sheets.read(Convert.run(Shell.office(ods, to: "xls"), to: "csv")) == rows, "xls → csv (LibreOffice)")
                let odp = try Shell.office(pdf, to: "odp", infilter: "impress_pdf_import")
                check(PDFDocument(url: try Convert.run(odp, to: "pdf"))?.string?.contains("Hello") == true, "slides → pdf (LibreOffice)")
                check((try Convert.run(pdf, to: "pptx").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1000, "pdf → pptx (LibreOffice)")
            } else { print("skip slides, xls, pdf → pptx (no LibreOffice)") }
            try extraChecks(dir, png: png, pdf: pdf, check)
            check(Thumbs.describe([csv]).hasSuffix("bytes") && Thumbs.describe([csv, png]).hasPrefix("2 items"), "size line")

            let missing = WheelView.symbols.filter { NSImage(systemSymbolName: $0.value, accessibilityDescription: nil) == nil }
            check(missing.isEmpty, "SF Symbols resolve \(missing.keys.sorted())")
            check(Click.wav().count == 44 + 1323 * 2, "click sound synthesized")

            print("SELFTEST OK (ffmpeg: \(Shell.ffmpeg ?? "none"), pandoc: \(Shell.pandoc ?? "none"), LibreOffice: \(Shell.soffice ?? "none"))")
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}
