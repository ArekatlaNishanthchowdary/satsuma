using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media.Imaging;
using System.Xml.Linq;
using PdfSharp.Drawing;
using PdfSharp.Fonts;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;
using Windows.Storage;
using Windows.Storage.Streams;
using PigDocument = UglyToad.PdfPig.PdfDocument;
using WinPdf = Windows.Data.Pdf;

namespace Satsuma;

static class Pdfs
{
    static Pdfs() => GlobalFontSettings.UseWindowsFontsUnderWindows = true;

    /// <summary><paramref name="near"/> names the output when <paramref name="src"/> is an intermediate temp PDF.</summary>
    public static string Convert(string src, string ext, string near = null)
    {
        near ??= src;
        var outPath = Paths.Output(near, ext);
        switch (ext)
        {
            case "png" or "jpg":
                var pages = Render(src);
                if (pages.Count == 1) { Img.Save(pages[0], outPath); return outPath; }
                var dir = Paths.Folder(near, " pages");
                for (int i = 0; i < pages.Count; i++) Img.Save(pages[i], Path.Combine(dir, $"page {i + 1}.{ext}"));
                return dir;
            case "pptx":
                File.Move(Shell.Office(src, "pptx", "impress_pdf_import"), outPath);
                return outPath;
            case "xlsx":
                // ponytail: one row per text line, columns split on runs of 2+ spaces; real table detection is a layout-analysis project.
                Sheets.Write(Text(src).Where(l => l.Trim().Length > 0).Select(l => Regex.Split(l.Trim(), @"\s{2,}|\t").ToList()).ToList(), outPath);
                return outPath;
            default:
                Docs.Write(Text(src), outPath);
                return outPath;
        }
    }

    /// <summary>Every page at 300 DPI (or <paramref name="width"/> pixels wide), using Windows' built-in PDF renderer.</summary>
    public static List<BitmapSource> Render(string src, uint width = 0)
    {
        var file = StorageFile.GetFileFromPathAsync(Path.GetFullPath(src)).AsTask().GetAwaiter().GetResult();
        var doc = WinPdf.PdfDocument.LoadFromFileAsync(file).AsTask().GetAwaiter().GetResult();
        var result = new List<BitmapSource>();
        for (uint i = 0; i < doc.PageCount; i++)
        {
            using var page = doc.GetPage(i);
            using var ras = new InMemoryRandomAccessStream();
            var opts = new WinPdf.PdfPageRenderOptions { DestinationWidth = width > 0 ? width : (uint)(page.Size.Width * 300 / 96) };
            page.RenderToStreamAsync(ras, opts).AsTask().GetAwaiter().GetResult();
            ras.Seek(0);
            using var s = ras.AsStreamForRead();
            var frame = BitmapDecoder.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            frame.Freeze();
            result.Add(frame);
        }
        return result;
    }

    public static List<string> Text(string src)
    {
        using var doc = PigDocument.Open(src);
        return doc.GetPages().SelectMany(p => ContentOrderTextExtractor.GetText(p).Replace("\r\n", "\n").Split('\n').Append("")).ToList();
    }

    public static void FromImages(IEnumerable<BitmapSource> images, string outPath)
    {
        using var doc = new PdfDocument();
        foreach (var img in images)
        {
            var ms = new MemoryStream();
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(img));
            enc.Save(ms);
            ms.Position = 0;
            using var x = XImage.FromStream(ms);
            var page = doc.AddPage();
            page.Width = XUnit.FromPoint(img.PixelWidth * 0.75);
            page.Height = XUnit.FromPoint(img.PixelHeight * 0.75);
            using var g = XGraphics.FromPdfPage(page);
            g.DrawImage(x, 0, 0, page.Width.Point, page.Height.Point);
        }
        doc.Save(outPath);
    }

    public static string MakeFromImages(List<string> files)
    {
        var outPath = Paths.Output(files[0], "pdf", " images");
        FromImages(files.Select(Img.Load), outPath);
        return outPath;
    }

    /// <summary>Plain paragraphs on A4/Letter-ish pages, word-wrapped.</summary>
    public static void FromText(List<string> paragraphs, string outPath)
    {
        using var doc = new PdfDocument();
        var font = new XFont("Arial", 11);
        const double margin = 72, width = 612, height = 792, lineHeight = 15;
        XGraphics g = null;
        double y = height;
        void NewPage() { g?.Dispose(); var p = doc.AddPage(); p.Width = XUnit.FromPoint(width); p.Height = XUnit.FromPoint(height); g = XGraphics.FromPdfPage(p); y = margin; }
        void Line(string s) { if (y + lineHeight > height - margin) NewPage(); g.DrawString(s, font, XBrushes.Black, margin, y, XStringFormats.TopLeft); y += lineHeight; }
        NewPage();
        foreach (var para in paragraphs)
        {
            var line = "";
            foreach (var word in para.Split(' '))
            {
                var next = line.Length == 0 ? word : line + " " + word;
                if (line.Length > 0 && g.MeasureString(next, font).Width > width - 2 * margin) { Line(line); line = word; }
                else line = next;
            }
            Line(line);
        }
        g.Dispose();
        doc.Save(outPath);
    }

    /// <summary>A ruled grid; the page widens to fit the columns instead of clipping them.</summary>
    public static void FromTable(List<List<string>> rows, string outPath)
    {
        using var doc = new PdfDocument();
        var font = new XFont("Arial", 9);
        const double margin = 36, height = 792, rowHeight = 16, pad = 4;
        int cols = rows.Count == 0 ? 0 : rows.Max(r => r.Count);
        using (var probe = XGraphics.CreateMeasureContext(new XSize(1, 1), XGraphicsUnit.Point, XPageDirection.Downwards))
        {
            var widths = Enumerable.Range(0, cols).Select(c => Math.Min(240, rows.Max(r => c < r.Count ? probe.MeasureString(r[c], font).Width : 0)) + 2 * pad).ToArray();
            double width = Math.Max(612, widths.Sum() + 2 * margin);
            XGraphics g = null;
            double y = height;
            var pen = new XPen(XColors.LightGray, 0.5);
            foreach (var row in rows.DefaultIfEmpty(new()))
            {
                if (y + rowHeight > height - margin)
                {
                    g?.Dispose();
                    var p = doc.AddPage();
                    p.Width = XUnit.FromPoint(width); p.Height = XUnit.FromPoint(height);
                    g = XGraphics.FromPdfPage(p);
                    y = margin;
                }
                double x = margin;
                for (int c = 0; c < cols; c++)
                {
                    var cell = new XRect(x, y, widths[c], rowHeight);
                    g.DrawRectangle(pen, cell);
                    if (c < row.Count)
                    {
                        g.Save();
                        g.IntersectClip(cell);
                        g.DrawString(row[c].Replace('\n', ' '), font, XBrushes.Black, new XRect(x + pad, y, widths[c] - 2 * pad, rowHeight), XStringFormats.CenterLeft);
                        g.Restore();
                    }
                    x += widths[c];
                }
                y += rowHeight;
            }
            g.Dispose();
        }
        doc.Save(outPath);
    }

    static string Edit(string src, string suffix, PdfDocumentOpenMode mode, Action<PdfDocument> f)
    {
        using var doc = PdfReader.Open(src, mode);
        f(doc);
        var outPath = Paths.Output(src, "pdf", suffix);
        doc.Save(outPath);
        return outPath;
    }

    // ponytail: recompresses streams only; real image downsampling would need a renderer like Ghostscript.
    public static string Compress(string src) => Edit(src, " compressed", PdfDocumentOpenMode.Modify, d =>
    {
        d.Options.FlateEncodeMode = PdfFlateEncodeMode.BestCompression;
        d.Options.CompressContentStreams = true;
        d.Options.NoCompression = false;
    });

    public static string Rotate(string src) => Edit(src, " rotated", PdfDocumentOpenMode.Modify, d =>
    {
        foreach (var p in d.Pages) p.Rotate = (p.Rotate + 90) % 360;
    });

    /// <summary>Writes the pages in the given order (0-based indexes, others dropped), each turned by an extra multiple of 90°.</summary>
    public static string Organize(string src, List<(int Index, int Turn)> pages)
    {
        if (pages.Count == 0) throw new Fail("Keep at least one page.");
        using var doc = PdfReader.Open(src, PdfDocumentOpenMode.Import);
        using var result = new PdfDocument();
        foreach (var (i, turn) in pages)
        {
            var p = result.AddPage(doc.Pages[i]);
            p.Rotate = ((doc.Pages[i].Rotate + turn) % 360 + 360) % 360;
        }
        var outPath = Paths.Output(src, "pdf", " organized");
        result.Save(outPath);
        return outPath;
    }

    public static string Strip(string src) => Edit(src, " clean", PdfDocumentOpenMode.Modify, d => d.Info.Elements.Clear());

    public static string Merge(List<string> files)
    {
        using var merged = new PdfDocument();
        foreach (var f in files)
        {
            using var doc = PdfReader.Open(f, PdfDocumentOpenMode.Import);
            foreach (var p in doc.Pages) merged.AddPage(p);
        }
        var outPath = Paths.Output(files[0], "pdf", " merged");
        merged.Save(outPath);
        return outPath;
    }

    public static string Split(string src)
    {
        using var doc = PdfReader.Open(src, PdfDocumentOpenMode.Import);
        var dir = Paths.Folder(src, " pages");
        var stem = Path.GetFileNameWithoutExtension(src);
        for (int i = 0; i < doc.PageCount; i++)
        {
            using var one = new PdfDocument();
            one.AddPage(doc.Pages[i]);
            one.Save(Path.Combine(dir, $"{stem} {i + 1}.pdf"));
        }
        return dir;
    }
}

/// <summary>pandoc when installed (keeps formatting); otherwise a plain-paragraph round trip.</summary>
static class Docs
{
    static readonly HashSet<string> PandocFormats = new() { "md", "txt", "docx", "odt", "html", "rtf", "epub" };

    public static string Convert(string src, string ext)
    {
        var outPath = Paths.Output(src, ext);
        var srcExt = Catalog.NormExt(src);
        if (Shell.Pandoc != null && ext != "pdf" && PandocFormats.Contains(srcExt) && PandocFormats.Contains(ext))
        {
            var args = new List<string> { src, "-s", "-o", outPath };
            if (srcExt == "txt") args.AddRange(new[] { "-f", "markdown" });
            if (ext == "txt") args.AddRange(new[] { "-t", "plain" });
            Shell.Run(Shell.Pandoc, args);
        }
        else Write(Read(src), outPath);
        return outPath;
    }

    public static string NativeConvert(string src, string ext)
    {
        var outPath = Paths.Output(src, ext);
        Write(Read(src), outPath);
        return outPath;
    }

    static List<string> Lines(string s) => s.Replace("\r\n", "\n").Split('\n').ToList();

    public static List<string> Read(string path)
    {
        switch (Catalog.NormExt(path))
        {
            case "rtf":
                var fd = new FlowDocument();
                var range = new TextRange(fd.ContentStart, fd.ContentEnd);
                using (var fs = File.OpenRead(path)) range.Load(fs, DataFormats.Rtf);
                return Lines(range.Text.TrimEnd());
            case "docx":
                XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
                return ZipXml(path, "word/document.xml").Descendants(w + "p").Select(p => string.Concat(p.Descendants().Select(e =>
                    e.Name == w + "t" ? e.Value : e.Name == w + "tab" ? "\t" : e.Name == w + "br" ? "\n" : ""))).ToList();
            case "odt":
                XNamespace t = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
                return ZipXml(path, "content.xml").Descendants().Where(e => e.Name == t + "p" || e.Name == t + "h").Select(e => e.Value).ToList();
            case "html":
                var html = Regex.Replace(File.ReadAllText(path), @"<(script|style)[\s\S]*?</\1>", "", RegexOptions.IgnoreCase);
                html = Regex.Replace(html, @"<(br|/p|/div|/h\d|/li|/tr)[^>]*>", "\n", RegexOptions.IgnoreCase);
                return Lines(WebUtility.HtmlDecode(Regex.Replace(html, "<[^>]+>", ""))).Select(l => l.Trim()).ToList();
            case "epub":
                throw new Fail("EPUB needs pandoc: winget install pandoc");
            default:
                return Lines(File.ReadAllText(path));
        }
    }

    static XDocument ZipXml(string zip, string entry)
    {
        using var archive = ZipFile.OpenRead(zip);
        using var s = (archive.GetEntry(entry) ?? throw new Fail($"{Path.GetFileName(zip)} looks damaged")).Open();
        return XDocument.Load(s);
    }

    static string Esc(string s) => SecurityElement.Escape(s);

    public static void Write(List<string> paras, string path)
    {
        switch (Path.GetExtension(path).TrimStart('.').ToLowerInvariant())
        {
            case "pdf":
                Pdfs.FromText(paras, path);
                break;
            case "epub":
                var html = Path.Combine(Paths.Temp(), Path.GetFileNameWithoutExtension(path) + ".html");
                Write(paras, html);
                Shell.Run(Shell.Pandoc ?? throw new Fail("EPUB needs pandoc: winget install pandoc"),
                    new[] { html, "-o", path, "--metadata", "title=" + Path.GetFileNameWithoutExtension(path) });
                break;
            case "html":
                File.WriteAllText(path, "<!doctype html>\n<meta charset=\"utf-8\">\n<body>\n" +
                    string.Concat(paras.Select(p => $"<p>{WebUtility.HtmlEncode(p)}</p>\n")) + "</body>\n");
                break;
            case "rtf":
                var fd = new FlowDocument();
                foreach (var p in paras) fd.Blocks.Add(new Paragraph(new Run(p)));
                using (var fs = File.Create(path)) new TextRange(fd.ContentStart, fd.ContentEnd).Save(fs, DataFormats.Rtf);
                break;
            case "docx":
                WriteZip(path, new()
                {
                    ["[Content_Types].xml"] = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
                    ["_rels/.rels"] = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
                    ["word/document.xml"] = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" +
                        string.Concat(paras.Select(p => $"<w:p><w:r><w:t xml:space=\"preserve\">{Esc(p)}</w:t></w:r></w:p>")) + "</w:body></w:document>",
                });
                break;
            case "odt":
                WriteZip(path, new()
                {
                    ["mimetype"] = "application/vnd.oasis.opendocument.text",
                    ["META-INF/manifest.xml"] = "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>",
                    ["content.xml"] = "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:text>" +
                        string.Concat(paras.Select(p => $"<text:p>{Esc(p)}</text:p>")) + "</office:text></office:body></office:document-content>",
                });
                break;
            default:
                File.WriteAllText(path, string.Join(Environment.NewLine, paras));
                break;
        }
    }

    /// <summary>A one-page DOCX holding the picture, scaled to fit 6.5" of text width.</summary>
    public static void WriteImage(BitmapSource img, string path)
    {
        var png = new MemoryStream();
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(img));
        enc.Save(png);
        const long emuPerPx = 9525, maxCx = 5943600;  // 96 DPI pixels → EMU
        long cx = img.PixelWidth * emuPerPx, cy = img.PixelHeight * emuPerPx;
        if (cx > maxCx) (cx, cy) = (maxCx, cy * maxCx / cx);
        const string rels = "http://schemas.openxmlformats.org/package/2006/relationships";
        const string docRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        WriteZip(path, new()
        {
            ["[Content_Types].xml"] = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
            ["_rels/.rels"] = $"<Relationships xmlns=\"{rels}\"><Relationship Id=\"rId1\" Type=\"{docRel}/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            ["word/_rels/document.xml.rels"] = $"<Relationships xmlns=\"{rels}\"><Relationship Id=\"rId1\" Type=\"{docRel}/image\" Target=\"media/image1.png\"/></Relationships>",
            ["word/document.xml"] = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"" + docRel + "\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body><w:p><w:r><w:drawing>" +
                $"<wp:inline><wp:extent cx=\"{cx}\" cy=\"{cy}\"/><wp:docPr id=\"1\" name=\"Picture 1\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>" +
                "<pic:nvPicPr><pic:cNvPr id=\"1\" name=\"image1.png\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>" +
                $"<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{cx}\" cy=\"{cy}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline>" +
                "</w:drawing></w:r></w:p></w:body></w:document>",
            ["word/media/image1.png"] = png.ToArray(),
        });
    }

    /// <summary>Entries in insertion order: strings are XML parts, byte arrays are stored as-is. "mimetype" is stored uncompressed, as ODF requires.</summary>
    public static void WriteZip(string path, Dictionary<string, object> entries)
    {
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, body) in entries)
        {
            var e = zip.CreateEntry(name, name == "mimetype" ? CompressionLevel.NoCompression : CompressionLevel.Optimal);
            using var s = e.Open();
            if (body is byte[] bytes) { s.Write(bytes); continue; }
            using var w = new StreamWriter(s, new UTF8Encoding(false));
            w.Write(name == "mimetype" ? body : "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + body);
        }
    }
}

static class Sheets
{
    public static string Convert(string src, string ext)
    {
        var outPath = Paths.Output(src, ext);
        Write(Read(src), outPath);
        return outPath;
    }

    public static List<List<string>> Read(string path) => Catalog.NormExt(path) switch
    {
        "xlsx" => Xlsx.Read(path),
        "ods" => Ods.Read(path),
        "xls" => Xlsx.Read(Shell.Office(path, "xlsx")),
        "tsv" => Parse(File.ReadAllText(path), '\t'),
        _ => Parse(File.ReadAllText(path), ','),
    };

    public static void Write(List<List<string>> rows, string path)
    {
        switch (Path.GetExtension(path).ToLowerInvariant())
        {
            case ".xlsx": Xlsx.Write(rows, path); break;
            case ".ods": Ods.Write(rows, path); break;
            case ".pdf": Pdfs.FromTable(rows, path); break;
            case ".tsv": File.WriteAllText(path, Format(rows, '\t')); break;
            default: File.WriteAllText(path, Format(rows, ',')); break;
        }
    }

    /// <summary>RFC 4180: quoted fields may hold separators, newlines and doubled quotes.</summary>
    public static List<List<string>> Parse(string text, char sep)
    {
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (quoted)
            {
                if (c != '"') field.Append(c);
                else if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else quoted = false;
            }
            else if (c == '"') quoted = true;
            else if (c == sep) { row.Add(field.ToString()); field.Clear(); }
            else if (c == '\n' || c == '\r')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(field.ToString()); field.Clear(); rows.Add(row); row = new();
            }
            else field.Append(c);
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); rows.Add(row); }
        return rows;
    }

    public static string Format(List<List<string>> rows, char sep) => string.Join("\n", rows.Select(r => string.Join(sep, r.Select(f =>
        f.IndexOfAny(new[] { sep, '"', '\n', '\r' }) >= 0 ? "\"" + f.Replace("\"", "\"\"") + "\"" : f)))) + "\n";
}

/// <summary>Just enough of Office Open XML for one sheet of values.</summary>
static class Xlsx
{
    static readonly XNamespace Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";

    public static string Column(int i)
    {
        var s = "";
        for (int n = i + 1; n > 0; n = (n - 1) / 26) s = (char)('A' + (n - 1) % 26) + s;
        return s;
    }

    // Leading-zero codes ("01234") stay text.
    public static bool IsNumber(string s) => double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _)
        && (s == "0" || !s.StartsWith("0") || s.StartsWith("0."));

    public static void Write(List<List<string>> rows, string path)
    {
        const string rels = "http://schemas.openxmlformats.org/package/2006/relationships";
        const string docRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        var data = string.Concat(rows.Select((row, r) => $"<row r=\"{r + 1}\">" + string.Concat(row.Select((v, c) =>
            IsNumber(v) ? $"<c r=\"{Column(c)}{r + 1}\"><v>{v}</v></c>"
                : $"<c r=\"{Column(c)}{r + 1}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">{SecurityElement.Escape(v)}</t></is></c>")) + "</row>"));
        Docs.WriteZip(path, new()
        {
            ["[Content_Types].xml"] = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>",
            ["_rels/.rels"] = $"<Relationships xmlns=\"{rels}\"><Relationship Id=\"rId1\" Type=\"{docRel}/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            ["xl/workbook.xml"] = $"<workbook xmlns=\"{Main}\" xmlns:r=\"{docRel}\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            ["xl/_rels/workbook.xml.rels"] = $"<Relationships xmlns=\"{rels}\"><Relationship Id=\"rId1\" Type=\"{docRel}/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            ["xl/worksheets/sheet1.xml"] = $"<worksheet xmlns=\"{Main}\"><sheetData>{data}</sheetData></worksheet>",
        });
    }

    // ponytail: first sheet only, values not formulas; dates come out as Excel serial numbers.
    public static List<List<string>> Read(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        XDocument Load(ZipArchiveEntry e) { using var s = e.Open(); return XDocument.Load(s); }
        var shared = zip.GetEntry("xl/sharedStrings.xml") is { } ss
            ? Load(ss).Descendants(Main + "si").Select(si => string.Concat(si.Descendants(Main + "t").Select(t => t.Value))).ToList()
            : new List<string>();
        var sheet = zip.GetEntry("xl/worksheets/sheet1.xml")
            ?? zip.Entries.Where(e => e.FullName.StartsWith("xl/worksheets/") && e.FullName.EndsWith(".xml")).OrderBy(e => e.FullName).FirstOrDefault()
            ?? throw new Fail($"No worksheet in {Path.GetFileName(path)}");
        var rows = new List<List<string>>();
        foreach (var c in Load(sheet).Descendants(Main + "c"))
        {
            var cellRef = (string)c.Attribute("r") ?? "";
            var letters = new string(cellRef.TakeWhile(char.IsLetter).ToArray()).ToUpperInvariant();
            if (!int.TryParse(cellRef[letters.Length..], out var r)) continue;
            int col = letters.Aggregate(0, (acc, ch) => acc * 26 + ch - 'A' + 1) - 1;
            var type = (string)c.Attribute("t");
            var v = (string)c.Element(Main + "v") ?? "";
            var value = type == "s" ? (int.TryParse(v, out var k) && k < shared.Count ? shared[k] : "")
                : type == "inlineStr" ? string.Concat(c.Descendants(Main + "t").Select(t => t.Value)) : v;
            while (rows.Count < r) rows.Add(new());
            while (rows[r - 1].Count <= col) rows[r - 1].Add("");
            rows[r - 1][col] = value;
        }
        return rows;
    }
}

/// <summary>OpenDocument spreadsheet: first table, values only, like <see cref="Xlsx"/>.</summary>
static class Ods
{
    static readonly XNamespace Office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    static readonly XNamespace Table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    static readonly XNamespace Text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";

    public static void Write(List<List<string>> rows, string path)
    {
        string Esc(string s) => SecurityElement.Escape(s);
        var data = string.Concat(rows.Select(row => "<table:table-row>" + string.Concat(row.Select(v =>
            (Xlsx.IsNumber(v) ? $"<table:table-cell office:value-type=\"float\" office:value=\"{v}\">" : "<table:table-cell office:value-type=\"string\">") +
            string.Concat(v.Split('\n').Select(l => $"<text:p>{Esc(l)}</text:p>")) + "</table:table-cell>")) + "</table:table-row>"));
        Docs.WriteZip(path, new()
        {
            ["mimetype"] = "application/vnd.oasis.opendocument.spreadsheet",
            ["META-INF/manifest.xml"] = "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>",
            ["content.xml"] = $"<office:document-content xmlns:office=\"{Office}\" xmlns:table=\"{Table}\" xmlns:text=\"{Text}\" office:version=\"1.2\"><office:body><office:spreadsheet><table:table table:name=\"Sheet1\">{data}</table:table></office:spreadsheet></office:body></office:document-content>",
        });
    }

    /// <summary>Repeated blank cells and rows (often a million of them) only count once something follows them.</summary>
    public static List<List<string>> Read(string path)
    {
        XDocument content;
        using (var zip = ZipFile.OpenRead(path))
        using (var s = (zip.GetEntry("content.xml") ?? throw new Fail($"{Path.GetFileName(path)} looks damaged")).Open())
            content = XDocument.Load(s);
        var table = content.Descendants(Table + "table").FirstOrDefault() ?? throw new Fail($"No sheet in {Path.GetFileName(path)}");
        int Repeat(XElement e, string attr) => int.TryParse((string)e.Attribute(Table + attr), out var n) ? n : 1;
        var rows = new List<List<string>>();
        int blankRows = 0;
        foreach (var r in table.Descendants(Table + "table-row"))
        {
            var row = new List<string>();
            int blankCells = 0;
            foreach (var c in r.Elements().Where(e => e.Name == Table + "table-cell" || e.Name == Table + "covered-table-cell"))
            {
                var v = string.Join("\n", c.Elements(Text + "p").Select(p => p.Value));
                if (v.Length == 0 && c.Attribute(Office + "value") is { } num) v = num.Value;
                if (v.Length == 0) { blankCells += Repeat(c, "number-columns-repeated"); continue; }
                row.AddRange(Enumerable.Repeat("", blankCells));
                blankCells = 0;
                row.AddRange(Enumerable.Repeat(v, Repeat(c, "number-columns-repeated")));
            }
            if (row.Count == 0) { blankRows += Repeat(r, "number-rows-repeated"); continue; }
            for (; blankRows > 0; blankRows--) rows.Add(new());
            for (int n = Repeat(r, "number-rows-repeated"); n > 0; n--) rows.Add(row.ToList());
        }
        return rows;
    }
}

/// <summary>Presentations go through LibreOffice to PDF, then out as PDF or page images.</summary>
static class Slides
{
    public static string Convert(string src, string ext)
    {
        var pdf = Shell.Office(src, "pdf");
        if (ext != "pdf") return Pdfs.Convert(pdf, ext, near: src);
        var outPath = Paths.Output(src, "pdf");
        File.Move(pdf, outPath);
        return outPath;
    }
}

static class Subs
{
    record Cue(string Start, string End, string Text);

    public static string Convert(string src, string ext)
    {
        var cues = Parse(File.ReadAllText(src));
        var outPath = Paths.Output(src, ext);
        File.WriteAllText(outPath, ext switch
        {
            "srt" => string.Join("\n", cues.Select((c, i) => $"{i + 1}\n{Time(c.Start, true)} --> {Time(c.End, true)}\n{c.Text}\n")),
            "vtt" => "WEBVTT\n\n" + string.Join("\n", cues.Select(c => $"{Time(c.Start, false)} --> {Time(c.End, false)}\n{c.Text}\n")),
            _ => string.Join("\n", cues.Select(c => c.Text)) + "\n",
        });
        return outPath;
    }

    static List<Cue> Parse(string text) => text.Replace("\r\n", "\n").Split("\n\n").Select(block =>
    {
        var lines = block.Split('\n');
        int i = Array.FindIndex(lines, l => l.Contains("-->"));
        if (i < 0) return null;
        var parts = lines[i].Split("-->").Select(p => p.Trim()).ToArray();
        return new Cue(parts[0], parts[1].Split(' ')[0], string.Join("\n", lines.Skip(i + 1)).Trim('\n'));  // drop VTT cue settings
    }).Where(c => c != null).ToList();

    /// <summary>SRT wants "00:00:01,000", VTT "00:00:01.000" (hours optional in VTT).</summary>
    static string Time(string t, bool comma)
    {
        t = t.Replace(',', '.');
        if (t.Split(':').Length == 2) t = "00:" + t;
        return comma ? t.Replace('.', ',') : t;
    }
}

static class Archive
{
    public static string Extract(string src)
    {
        var dest = Paths.Folder(src);
        var name = Path.GetFileName(src).ToLowerInvariant();
        if (name.EndsWith(".gz") && !name.EndsWith(".tar.gz"))
        {
            using var input = new GZipStream(File.OpenRead(src), CompressionMode.Decompress);
            using var output = File.Create(Path.Combine(dest, Path.GetFileNameWithoutExtension(src)));
            input.CopyTo(output);
        }
        else Shell.Run(Shell.Tar, new[] { "-xf", Path.GetFullPath(src), "-C", dest });
        return dest;
    }

    public static string Convert(string src, string ext)
    {
        var tmp = Paths.Temp();
        try
        {
            var staged = Path.Combine(tmp, "x");
            Directory.Move(Extract(src), staged);
            var outPath = Paths.Output(src, ext);
            Pack(Directory.GetFileSystemEntries(staged).Select(Path.GetFileName), staged, outPath, ext);
            return outPath;
        }
        finally { try { Directory.Delete(tmp, true); } catch { } }
    }

    // ponytail: assumes the files share a folder (true for any Explorer drag).
    public static string Zip(List<string> files)
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(files[0]));
        var outPath = files.Count == 1 ? Paths.Output(files[0], "zip") : Paths.Output(Path.Combine(parent, "Archive"), "zip");
        Pack(files.Select(f => Path.GetFileName(f.TrimEnd('\\'))), parent, outPath, "zip");
        return outPath;
    }

    static void Pack(IEnumerable<string> names, string dir, string outPath, string ext)
    {
        if (ext != "zip")
        {
            Shell.Run(Shell.Tar, new[] { ext == "tar" ? "-cf" : "-czf", outPath }.Concat(names), dir);
            return;
        }
        using var zip = ZipFile.Open(outPath, ZipArchiveMode.Create);
        foreach (var name in names)
        {
            var full = Path.Combine(dir, name);
            if (File.Exists(full)) { zip.CreateEntryFromFile(full, name); continue; }
            foreach (var f in Directory.EnumerateFiles(full, "*", SearchOption.AllDirectories))
                zip.CreateEntryFromFile(f, Path.GetRelativePath(dir, f).Replace('\\', '/'));
        }
    }
}
