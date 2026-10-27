using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PdfSharp.Pdf.IO;

namespace Satsuma;

/// <summary><c>Satsuma.exe --selftest</c>: round-trips a sample of each format through the real converters.</summary>
static class SelfTest
{
    public static int Run()
    {
        var dir = Paths.Temp();
        try
        {
            void Check(bool ok, string what)
            {
                Console.WriteLine(ok ? $"ok   {what}" : $"FAIL {what}");
                if (!ok) throw new Fail(what);
            }
            List<string> Tool(string title, params string[] files) =>
                Catalog.Ops(Mode.Tools, files.ToList()).First(o => o.Title == title).Run(files.ToList());
            string F(string name) => Path.Combine(dir, name);

            var rows = new List<List<string>> { new() { "name", "qty" }, new() { "a, \"b\"", "3" }, new() { "zip", "01234" } };
            File.WriteAllText(F("t.csv"), Sheets.Format(rows, ','));
            bool Same(List<List<string>> a) => a.Count == rows.Count && a.Zip(rows).All(p => p.First.SequenceEqual(p.Second));
            Check(Same(Sheets.Parse(File.ReadAllText(F("t.csv")), ',')), "csv quoting round-trip");
            var xlsx = Converter.Run(F("t.csv"), "xlsx");
            Check(Same(Sheets.Read(xlsx)), "csv → xlsx → rows");
            Check(Same(Sheets.Read(Converter.Run(xlsx, "tsv"))), "xlsx → tsv");
            var ods = Converter.Run(F("t.csv"), "ods");
            Check(Same(Sheets.Read(ods)), "csv → ods → rows");
            Check(string.Join(" ", Pdfs.Text(Converter.Run(ods, "pdf"))).Contains("qty"), "ods → pdf table");

            File.WriteAllText(F("s.srt"), "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n");
            var vtt = File.ReadAllText(Converter.Run(F("s.srt"), "vtt"));
            Check(vtt.StartsWith("WEBVTT") && vtt.Contains("00:00:01.000 --> 00:00:02.500"), "srt → vtt");

            File.WriteAllText(F("d.txt"), "Hello Satsuma\nSecond line");
            foreach (var ext in new[] { "docx", "odt", "rtf", "html" })
                Check(File.ReadAllText(Docs.NativeConvert(Docs.NativeConvert(F("d.txt"), ext), "txt")).Contains("Hello Satsuma"), $"txt → {ext} → txt");
            var pdf = Converter.Run(F("d.txt"), "pdf");
            Check(string.Join(" ", Pdfs.Text(pdf)).Contains("Hello Satsuma"), "txt → pdf → text");
            var page = Converter.Run(pdf, "png");
            Check(Img.Load(page).PixelWidth > 2000, "pdf → png at 300 DPI");
            Check(Sheets.Read(Converter.Run(pdf, "xlsx")).Any(r => r.Contains("Hello Satsuma")), "pdf → xlsx");
            if (Shell.Pandoc != null) Check(Docs.Read(Docs.Convert(Converter.Run(pdf, "epub"), "docx")).Any(l => l.Contains("Hello Satsuma")), "pdf → epub (pandoc)");

            var bmp = new WriteableBitmap(64, 48, 96, 96, PixelFormats.Bgra32, null);
            bmp.WritePixels(new System.Windows.Int32Rect(0, 0, 32, 48), Enumerable.Repeat(new byte[] { 0, 128, 255, 255 }, 32 * 48).SelectMany(b => b).ToArray(), 32 * 4, 0);
            Img.Save(bmp, F("i.png"));
            Check(Img.Load(Converter.Run(F("i.png"), "jpg")).PixelWidth == 64, "png → jpg");
            var imgPdf = Converter.Run(F("i.png"), "pdf");
            Check(PdfReader.Open(imgPdf, PdfDocumentOpenMode.Import).PageCount == 1, "png → pdf");
            Check(Img.Load(Tool("Resize 50%", F("i.png"))[0]).PixelWidth == 32, "resize 50%");
            using (var docx = System.IO.Compression.ZipFile.OpenRead(Converter.Run(F("i.png"), "docx")))
                Check(docx.GetEntry("word/media/image1.png")?.Length > 0 && docx.GetEntry("word/document.xml") != null, "png → docx");
            if (Img.CanHeic.Value) Check(Img.Load(Converter.Run(F("i.png"), "heic")).PixelWidth == 64, "png → heic");
            else Console.WriteLine("skip png → heic (no Windows HEIF encoder)");

            var merged = Tool("Merge", pdf, imgPdf)[0];
            Check(PdfReader.Open(merged, PdfDocumentOpenMode.Import).PageCount == 2, "merge pdfs");
            Check(Directory.GetFiles(Tool("Split Pages", merged)[0]).Length == 2, "split pdf");

            var unpacked = Tool("Extract", Tool("Zip", F("t.csv"))[0])[0];
            Check(File.ReadAllText(Path.Combine(unpacked, "t.csv")) == File.ReadAllText(F("t.csv")), "zip → extract");
            var tgz = Converter.Run(Tool("Zip", F("t.csv"))[0], "tar.gz");
            Check(File.Exists(Path.Combine(Tool("Extract", tgz)[0], "t.csv")), "zip → tar.gz → extract");

            WriteWav(F("a.wav"));
            foreach (var ext in new[] { "mp3", "m4a" })
                Check(new FileInfo(AV.Transcode(F("a.wav"), Paths.Output(F("a.wav"), ext), AV.Profile(ext))).Length > 1000, $"wav → {ext} (Windows encoder)");
            if (Shell.FFmpeg != null) Check(new FileInfo(Converter.Run(F("a.wav"), "ogg")).Length > 1000, "wav → ogg (ffmpeg)");
            if (Shell.Pandoc != null)
            {
                File.WriteAllText(F("m.md"), "# Title\n\nSome *text*.");
                Check(Docs.Read(Converter.Run(F("m.md"), "docx")).Contains("Title"), "md → docx (pandoc)");
            }

            if (Shell.Soffice != null)
            {
                Check(Same(Sheets.Read(Converter.Run(Shell.Office(ods, "xls"), "csv"))), "xls → csv (LibreOffice)");
                var odp = Shell.Office(pdf, "odp", "impress_pdf_import");
                Check(Pdfs.Text(Converter.Run(odp, "pdf")).Any(l => l.Contains("Hello")), "slides → pdf (LibreOffice)");
                Check(new FileInfo(Converter.Run(pdf, "pptx")).Length > 1000, "pdf → pptx (LibreOffice)");
            }
            else Console.WriteLine("skip slides, xls, pdf → pptx (no LibreOffice)");

            Console.WriteLine($"SELFTEST OK (ffmpeg: {Shell.FFmpeg ?? "none"}, pandoc: {Shell.Pandoc ?? "none"}, LibreOffice: {Shell.Soffice ?? "none"})");
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine($"FAIL {e.GetType().Name}: {e.Message}\n{e.StackTrace}");
            return 1;
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    /// <summary><c>--shots dir</c>: transparent PNGs of each wheel (Tangerine) and of every theme, for the README.</summary>
    public static void Shots(string dir)
    {
        Directory.CreateDirectory(dir);
        var saved = Theme.Current;
        var wheel = new WheelWindow();
        var photo = new List<string> { @"C:\Vacation.jpg" };
        Theme.Current = Theme.All[0];
        // A stand-in photo for the hub: dusk sky over a dark hill.
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(new LinearGradientBrush(Color.FromRgb(255, 170, 90), Color.FromRgb(120, 70, 160), 90), null, new System.Windows.Rect(0, 0, 96, 72));
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(40, 50, 70)), null, new System.Windows.Point(30, 90), 70, 34);
        }
        var pic = new RenderTargetBitmap(96, 72, 96, 96, PixelFormats.Pbgra32);
        pic.Render(dv);
        Img.Save(wheel.Render(Mode.Convert, photo, null, Brushes.Transparent, pic), Path.Combine(dir, "mode-convert.png"));
        Img.Save(wheel.Render(Mode.Tools, photo, 0, Brushes.Transparent), Path.Combine(dir, "mode-tools.png"));
        Img.Save(wheel.Render(Mode.Actions, photo, 3, Brushes.Transparent), Path.Combine(dir, "mode-actions.png"));
        foreach (var t in Theme.All)
        {
            Theme.Current = t;
            Img.Save(wheel.Render(Mode.Convert, photo, 1, Brushes.Transparent), Path.Combine(dir, "theme-" + t.Name + ".png"));
        }
        Theme.Current = saved;
    }

    /// <summary>One second of a 440 Hz tone, 16-bit mono PCM.</summary>
    static void WriteWav(string path)
    {
        const int rate = 22050;
        var samples = Enumerable.Range(0, rate).Select(i => (short)(Math.Sin(2 * Math.PI * 440 * i / rate) * 8000)).ToArray();
        using var w = new BinaryWriter(File.Create(path));
        w.Write("RIFF"u8); w.Write(36 + samples.Length * 2); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(samples.Length * 2);
        foreach (var s in samples) w.Write(s);
    }
}
