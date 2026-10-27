import AppKit
import PDFKit

/// `Satsuma --selftest`: round-trips one file of each native format through the real ops.
enum SelfTest {
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

            let png = dir.appendingPathComponent("i.png")
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            try Img.write(ctx.makeImage()!, to: png)
            check(try Img.load(Convert.run(png, to: "jpg")).width == 64, "png → jpg")
            check(PDFDocument(url: try Convert.run(png, to: "pdf"))?.pageCount == 1, "png → pdf")
            check(try Img.load(tool("Resize 50%", [png])[0]).width == 32, "resize 50%")

            let zip = try tool("Zip", [csv])[0]
            let unpacked = try tool("Extract", [zip])[0]
            check(try String(contentsOf: unpacked.appendingPathComponent("t.csv")) == String(contentsOf: csv), "zip → extract")

            if Shell.ffmpeg != nil {
                let webp = try Convert.run(Convert.run(png, to: "jpg"), to: "webp")
                check(FileManager.default.fileExists(atPath: webp.path), "jpg → webp (ffmpeg)")
            }
            if Shell.pandoc != nil {
                let md = dir.appendingPathComponent("m.md")
                try "# Title\n\nSome *text*.".write(to: md, atomically: true, encoding: .utf8)
                check(try Docs.read(Convert.run(md, to: "docx")).string.contains("Title"), "md → docx (pandoc)")
            }

            print("SELFTEST OK (ffmpeg: \(Shell.ffmpeg ?? "none"), pandoc: \(Shell.pandoc ?? "none"))")
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}
