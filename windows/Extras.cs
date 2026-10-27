using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Xml;
using System.Xml.Linq;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace Satsuma;

/// <summary>Subtitles as timed cues: SRT, WebVTT, ASS/SSA, LRC (lyrics) and SBV (YouTube) in; the same, minus SSA, plus TXT out.</summary>
static class Subs
{
    record Cue(long Start, long End, string Text);

    public static string Convert(string src, string ext)
    {
        var cues = Parse(File.ReadAllText(src), Catalog.NormExt(src));
        if (cues.Count == 0) throw new Fail($"No subtitles found in {Path.GetFileName(src)}");
        var outPath = Paths.Output(src, ext);
        File.WriteAllText(outPath, Write(cues, ext));
        return outPath;
    }

    static string Write(List<Cue> cues, string ext) => ext switch
    {
        "srt" => string.Join("\n", cues.Select((c, i) => $"{i + 1}\n{Clock(c.Start, ',')} --> {Clock(c.End, ',')}\n{c.Text}\n")),
        "vtt" => "WEBVTT\n\n" + string.Join("\n", cues.Select(c => $"{Clock(c.Start, '.')} --> {Clock(c.End, '.')}\n{c.Text}\n")),
        "sbv" => string.Join("\n", cues.Select(c => $"{Clock(c.Start, '.')[1..]},{Clock(c.End, '.')[1..]}\n{c.Text}\n")),
        "lrc" => string.Concat(cues.Select(c => $"[{c.Start / 60000:00}:{c.Start / 1000 % 60:00}.{c.Start / 10 % 100:00}]{Plain(c.Text).Replace('\n', ' ')}\n")),
        "ass" => AssHeader + string.Concat(cues.Select(c => $"Dialogue: 0,{Cs(c.Start)},{Cs(c.End)},Default,,0,0,0,,{c.Text.Replace("\n", "\\N")}\n")),
        _ => string.Join("\n", cues.Select(c => Plain(c.Text))) + "\n",
    };

    const string AssHeader = "[Script Info]\nScriptType: v4.00+\nPlayResX: 384\nPlayResY: 288\n\n[V4+ Styles]\n" +
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n" +
        "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1\n\n[Events]\n" +
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";

    static string Plain(string s) => Regex.Replace(s, "<[^>]+>", "");
    static string Clock(long ms, char sep) => $"{ms / 3600000:00}:{ms / 60000 % 60:00}:{ms / 1000 % 60:00}{sep}{ms % 1000:000}";
    static string Cs(long ms) => $"{ms / 3600000}:{ms / 60000 % 60:00}:{ms / 1000 % 60:00}.{ms / 10 % 100:00}";

    /// <summary>"01:02:03,450", "2:03.45" or "03.4": the fraction is read as a decimal, so .45 and .450 agree.</summary>
    static long Ms(string t)
    {
        var m = Regex.Match(t.Trim(), @"^(?:(\d+):)?(?:(\d+):)?(\d+)(?:[.,](\d+))?$");
        if (!m.Success) throw new Fail($"Can't read the time \"{t}\"");
        long h = 0, min, s = long.Parse(m.Groups[3].Value);
        if (m.Groups[2].Success) { h = long.Parse(m.Groups[1].Value); min = long.Parse(m.Groups[2].Value); }
        else min = m.Groups[1].Success ? long.Parse(m.Groups[1].Value) : 0;
        var frac = m.Groups[4].Success ? long.Parse((m.Groups[4].Value + "00")[..3]) : 0;
        return ((h * 60 + min) * 60 + s) * 1000 + frac;
    }

    static List<Cue> Parse(string text, string ext)
    {
        text = text.Replace("\r\n", "\n").Replace('\r', '\n').TrimStart('\uFEFF');
        switch (ext)
        {
            case "ass" or "ssa":
            {
                // Field order comes from the [Events] Format line; Text is always last and may hold commas.
                var format = text.Split('\n').FirstOrDefault(l => l.StartsWith("Format:") && l.Contains("Text"))?[7..].Split(',').Select(f => f.Trim()).ToList()
                    ?? new() { "Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text" };
                return text.Split('\n').Where(l => l.StartsWith("Dialogue:")).Select(l =>
                {
                    var f = l[9..].Split(',', format.Count);
                    var body = Regex.Replace(f[^1], @"\{[^}]*\}", "").Replace("\\N", "\n").Replace("\\n", "\n").Replace("\\h", " ").Trim();
                    return new Cue(Ms(f[format.IndexOf("Start")]), Ms(f[format.IndexOf("End")]), body);
                }).OrderBy(c => c.Start).ToList();
            }
            case "lrc":
            {
                // A line may carry several time tags ("[00:12.00][01:30.00]chorus"); each cue ends where the next begins.
                var hits = text.Split('\n').SelectMany(l =>
                {
                    var tags = Regex.Matches(l, @"\[(\d+:\d+(?:[.:]\d+)?)\]");
                    var body = Regex.Replace(l, @"\[[^\]]*\]", "").Trim();
                    // "[01:02:50]" is minutes:seconds:centiseconds in some players
                    return tags.Select(t => t.Groups[1].Value).Select(v => (Start: Ms(v.Count(c => c == ':') == 2 ? v[..v.LastIndexOf(':')] + "." + v[(v.LastIndexOf(':') + 1)..] : v), Text: body));
                }).Where(h => h.Text.Length > 0).OrderBy(h => h.Start).ToList();
                return hits.Select((h, i) => new Cue(h.Start, i + 1 < hits.Count ? hits[i + 1].Start : h.Start + 4000, h.Text)).ToList();
            }
            default:
                // SRT and VTT time lines use "-->"; SBV puts "start,end" alone on the first line of a block.
                return text.Split("\n\n").Select(block =>
                {
                    var lines = block.Trim('\n').Split('\n');
                    int i = Array.FindIndex(lines, l => l.Contains("-->"));
                    if (i >= 0)
                    {
                        var parts = lines[i].Split("-->");
                        return new Cue(Ms(parts[0]), Ms(parts[1].Trim().Split(' ')[0]), string.Join("\n", lines.Skip(i + 1)).Trim('\n'));
                    }
                    var sbv = Regex.Match(lines[0], @"^(\d+:\d+:\d+\.\d+),(\d+:\d+:\d+\.\d+)$");
                    return sbv.Success ? new Cue(Ms(sbv.Groups[1].Value), Ms(sbv.Groups[2].Value), string.Join("\n", lines.Skip(1))) : null;
                }).Where(c => c != null).ToList();
        }
    }
}

/// <summary>JSON and XML (in), plus JSON, XML, YAML and tables out. Tables reuse the spreadsheet writers.</summary>
static class Data
{
    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string Convert(string src, string ext)
    {
        var node = Load(src);
        var outPath = Paths.Output(src, ext);
        switch (ext)
        {
            case "json": File.WriteAllText(outPath, node?.ToJsonString(Pretty) ?? "null"); break;
            case "xml": new XDocument(ToXml(node)).Save(outPath); break;
            case "yaml": File.WriteAllText(outPath, Yaml(node)); break;
            default: Sheets.Write(Rows(node), outPath); break;
        }
        return outPath;
    }

    static JsonNode Load(string path)
    {
        if (Catalog.NormExt(path) == "xml")
        {
            var root = XDocument.Load(path).Root;
            return new JsonObject { [root.Name.LocalName] = FromXml(root) };
        }
        return JsonNode.Parse(File.ReadAllText(path), documentOptions: new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
    }

    /// <summary>Attributes become "@name", repeated children an array, mixed text "#text"; a bare element is just its text.</summary>
    static JsonNode FromXml(XElement e)
    {
        if (!e.HasAttributes && !e.HasElements) return e.Value;
        var o = new JsonObject();
        foreach (var a in e.Attributes().Where(a => !a.IsNamespaceDeclaration)) o["@" + a.Name.LocalName] = a.Value;
        foreach (var g in e.Elements().GroupBy(c => c.Name.LocalName))
            o[g.Key] = g.Count() == 1 ? FromXml(g.First()) : new JsonArray(g.Select(FromXml).ToArray());
        var text = string.Concat(e.Nodes().OfType<XText>().Select(t => t.Value)).Trim();
        if (text.Length > 0) o["#text"] = text;
        return o;
    }

    static XElement ToXml(JsonNode n) =>
        n is JsonObject o && o.Count == 1 && o.First().Value is not JsonArray ? El(o.First().Key, o.First().Value) : El("root", n);

    static XElement El(string name, JsonNode n) => new(Name(name), n switch
    {
        JsonObject o => o.SelectMany<KeyValuePair<string, JsonNode>, object>(kv => kv.Key.StartsWith('@') ? new object[] { new XAttribute(Name(kv.Key[1..]), Cell(kv.Value)) }
            : kv.Key == "#text" ? new object[] { Cell(kv.Value) }
            : kv.Value is JsonArray a ? a.Select(x => (object)El(kv.Key, x)) : new object[] { El(kv.Key, kv.Value) }).ToArray(),
        JsonArray a => a.Select(x => (object)El("item", x)).ToArray(),
        null => Array.Empty<object>(),
        _ => new object[] { Cell(n) },
    });

    static XName Name(string s) => s.Length == 0 ? "_" : XmlConvert.EncodeLocalName(s);
    static string Cell(JsonNode n) => n switch { null => "", JsonValue v when v.TryGetValue<string>(out var s) => s, _ => n.ToJsonString() };

    /// <summary>An array of objects becomes a header row plus one row per object. {"data": [...]} wrappers are looked through.</summary>
    public static List<List<string>> Rows(JsonNode n)
    {
        while (n is JsonObject w && w.Count == 1 && w.First().Value is JsonObject or JsonArray) n = w.First().Value;
        var items = n is JsonArray arr ? arr.ToList() : new List<JsonNode> { n };
        if (items.Count > 0 && items.All(i => i is JsonArray)) return items.Select(i => i.AsArray().Select(Cell).ToList()).ToList();
        var keys = items.OfType<JsonObject>().SelectMany(o => o.Select(kv => kv.Key)).Distinct().ToList();
        if (keys.Count == 0) return new[] { new List<string> { "value" } }.Concat(items.Select(i => new List<string> { Cell(i) })).ToList();
        return new[] { keys }.Concat(items.Select(i => i is JsonObject o ? keys.Select(k => Cell(o[k])).ToList() : new List<string> { Cell(i) })).ToList();
    }

    /// <summary>The first row names the fields. Numbers and true/false stay typed when they read back the same ("007" stays text).</summary>
    public static void WriteRows(List<List<string>> rows, string path)
    {
        var head = (rows.FirstOrDefault() ?? new()).Select((h, i) => h.Length > 0 ? h : $"column{i + 1}").ToList();
        for (int i = 0; i < head.Count; i++)
            for (int n = 2; head.Take(i).Contains(head[i]); n++) head[i] = $"{head[i]} {n}";
        var list = new JsonArray(rows.Skip(1).Select(r => (JsonNode)new JsonObject(head.Select((h, i) =>
            KeyValuePair.Create(h, Typed(i < r.Count ? r[i] : ""))))).ToArray());
        File.WriteAllText(path, list.ToJsonString(Pretty));
    }

    static JsonNode Typed(string s) =>
        s is "true" or "false" ? JsonValue.Create(s == "true")
        : Regex.IsMatch(s, @"^-?(0|[1-9]\d{0,14})(\.\d*[1-9])?$") ? JsonNode.Parse(s)
        : JsonValue.Create(s);

    static readonly HashSet<string> Reserved = new() { "true", "false", "null", "yes", "no", "on", "off", "y", "n", "~" };

    static string Yaml(JsonNode n)
    {
        var sb = new StringBuilder();
        if (n is JsonObject { Count: > 0 } or JsonArray { Count: > 0 }) Emit(n, sb, 0); else sb.Append(Scalar(n)).Append('\n');
        return sb.ToString();
    }

    static void Emit(JsonNode n, StringBuilder sb, int indent)
    {
        var pad = new string(' ', indent);
        if (n is JsonObject o) foreach (var (k, v) in o) { sb.Append(pad).Append(Key(k)).Append(':'); Child(v, sb, indent); }
        else foreach (var v in n.AsArray()) { sb.Append(pad).Append('-'); Child(v, sb, indent); }
    }

    static void Child(JsonNode v, StringBuilder sb, int indent)
    {
        if (v is JsonObject { Count: > 0 } or JsonArray { Count: > 0 }) { sb.Append('\n'); Emit(v, sb, indent + 2); }
        else sb.Append(' ').Append(Scalar(v)).Append('\n');
    }

    static string Scalar(JsonNode n) => n switch
    {
        null => "null",
        JsonObject => "{}",
        JsonArray => "[]",
        JsonValue v when v.TryGetValue<string>(out var s) => Key(s),
        _ => n.ToJsonString(),
    };

    /// <summary>Plain when it can't be misread as a number, bool or syntax; JSON-quoted (valid YAML) otherwise.</summary>
    static string Key(string s) => Regex.IsMatch(s, @"^[A-Za-z_][\w .\-/]*$") && !s.EndsWith(' ') && !Reserved.Contains(s.ToLowerInvariant())
        ? s : JsonSerializer.Serialize(s, Pretty);
}

/// <summary>TTF/OTF ↔ WOFF: the same tables, each zlib-compressed in WOFF.</summary>
static class Fonts
{
    const uint Woff = 0x774F4646, Woff2 = 0x774F4632, Otto = 0x4F54544F, Ttc = 0x74746366;

    /// <summary>TTF and OTF go to WOFF; a WOFF goes back to whichever of the two it holds.</summary>
    public static List<string> Targets(string path)
    {
        if (Catalog.NormExt(path) != "woff") return new() { "woff" };
        try
        {
            using var f = File.OpenRead(path);
            var head = new byte[8];
            f.ReadExactly(head);
            return new() { U32(head, 4) == Otto ? "otf" : "ttf" };
        }
        catch { return new() { "ttf", "otf" }; }
    }

    public static string Convert(string src, string ext)
    {
        var b = File.ReadAllBytes(src);
        var outPath = Paths.Output(src, ext);
        File.WriteAllBytes(outPath, ext == "woff" ? ToWoff(b) : FromWoff(b));
        return outPath;
    }

    static uint U32(byte[] b, int o) => BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(o));
    static int U16(byte[] b, int o) => BinaryPrimitives.ReadUInt16BigEndian(b.AsSpan(o));
    static void W32(Stream s, uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, v); s.Write(b); }
    static void W16(Stream s, int v) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, (ushort)v); s.Write(b); }
    static int Pad4(int n) => (n + 3) & ~3;

    static byte[] Zlib(byte[] data, bool compress)
    {
        var o = new MemoryStream();
        if (compress) using (var z = new ZLibStream(o, CompressionLevel.SmallestSize, true)) z.Write(data);
        else using (var z = new ZLibStream(new MemoryStream(data), CompressionMode.Decompress)) z.CopyTo(o);
        return o.ToArray();
    }

    public static byte[] ToWoff(byte[] f)
    {
        uint flavor = U32(f, 0);
        if (flavor == Ttc) throw new Fail("Font collections (.ttc) aren't supported.");
        if (flavor is Woff or Woff2) throw new Fail("This font is already a web font.");
        int n = U16(f, 4);
        var tables = Enumerable.Range(0, n).Select(i => 12 + 16 * i)
            .Select(e => (Tag: U32(f, e), Sum: U32(f, e + 4), Data: f.AsSpan((int)U32(f, e + 8), (int)U32(f, e + 12)).ToArray()))
            .OrderBy(t => t.Tag).ToList();
        int start = 44 + 20 * n;
        var body = new MemoryStream();
        var dir = new MemoryStream();
        foreach (var t in tables)
        {
            var z = Zlib(t.Data, true);
            var data = z.Length < t.Data.Length ? z : t.Data;  // the spec stores a table as-is when zlib doesn't help
            W32(dir, t.Tag); W32(dir, (uint)(start + body.Length)); W32(dir, (uint)data.Length); W32(dir, (uint)t.Data.Length); W32(dir, t.Sum);
            body.Write(data);
            while (body.Length % 4 != 0) body.WriteByte(0);
        }
        var o = new MemoryStream();
        W32(o, Woff); W32(o, flavor); W32(o, (uint)(start + body.Length)); W16(o, n); W16(o, 0);
        W32(o, (uint)(12 + 16 * n + tables.Sum(t => Pad4(t.Data.Length)))); W16(o, 1); W16(o, 0);
        for (int i = 0; i < 5; i++) W32(o, 0);  // no metadata or private block
        dir.WriteTo(o);
        body.WriteTo(o);
        return o.ToArray();
    }

    public static byte[] FromWoff(byte[] w)
    {
        if (U32(w, 0) == Woff2) throw new Fail("WOFF2 fonts aren't supported yet, only WOFF.");
        if (U32(w, 0) != Woff) throw new Fail("This isn't a WOFF font.");
        int n = U16(w, 12);
        var tables = Enumerable.Range(0, n).Select(i => 44 + 20 * i).Select(e =>
        {
            int off = (int)U32(w, e + 4), comp = (int)U32(w, e + 8), orig = (int)U32(w, e + 12);
            var raw = w.AsSpan(off, comp).ToArray();
            return (Tag: U32(w, e), Sum: U32(w, e + 16), Data: comp == orig ? raw : Zlib(raw, false));
        }).ToList();
        int sel = (int)Math.Floor(Math.Log2(n)), range = 16 << sel;
        var o = new MemoryStream();
        W32(o, U32(w, 4)); W16(o, n); W16(o, range); W16(o, sel); W16(o, n * 16 - range);
        int offset = 12 + 16 * n;
        foreach (var t in tables) { W32(o, t.Tag); W32(o, t.Sum); W32(o, (uint)offset); W32(o, (uint)t.Data.Length); offset += Pad4(t.Data.Length); }
        foreach (var t in tables) { o.Write(t.Data); while (o.Length % 4 != 0) o.WriteByte(0); }
        return o.ToArray();
    }
}

/// <summary>Windows ICO and Apple ICNS, both as a stack of PNGs at the standard sizes.</summary>
static class IconFile
{
    static readonly int[] IcoSizes = { 16, 24, 32, 48, 64, 128, 256 };
    static readonly (string Type, int Size)[] IcnsTypes = { ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024) };

    public static void Write(BitmapSource img, string path)
    {
        using var o = File.Create(path);
        if (path.EndsWith(".icns", StringComparison.OrdinalIgnoreCase))
        {
            // Up to 256 always; the larger Retina sizes only when the picture has the pixels for them.
            int biggest = Math.Max(256, Math.Max(img.PixelWidth, img.PixelHeight));
            var parts = IcnsTypes.Where(t => t.Size <= biggest).Select(t => (t.Type, Png: Square(img, t.Size))).ToList();
            o.Write("icns"u8);
            WriteBE(o, 8 + parts.Sum(p => 8 + p.Png.Length));
            foreach (var (type, png) in parts) { o.Write(Encoding.ASCII.GetBytes(type)); WriteBE(o, 8 + png.Length); o.Write(png); }
            return;
        }
        var pngs = IcoSizes.Select(s => Square(img, s)).ToList();
        var w = new BinaryWriter(o);
        w.Write((short)0); w.Write((short)1); w.Write((short)pngs.Count);
        int offset = 6 + 16 * pngs.Count;
        for (int i = 0; i < pngs.Count; i++)
        {
            byte side = (byte)(IcoSizes[i] == 256 ? 0 : IcoSizes[i]);
            w.Write(side); w.Write(side); w.Write((byte)0); w.Write((byte)0); w.Write((short)1); w.Write((short)32);
            w.Write(pngs[i].Length); w.Write(offset);
            offset += pngs[i].Length;
        }
        foreach (var p in pngs) w.Write(p);
        w.Flush();
    }

    static void WriteBE(Stream s, int v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteInt32BigEndian(b, v); s.Write(b); }

    /// <summary>The picture fitted, centred, into a transparent square.</summary>
    static byte[] Square(BitmapSource img, int size)
    {
        double scale = (double)size / Math.Max(img.PixelWidth, img.PixelHeight), w = img.PixelWidth * scale, h = img.PixelHeight * scale;
        var dv = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(dv, BitmapScalingMode.HighQuality);
        using (var dc = dv.RenderOpen()) dc.DrawImage(img, new Rect((size - w) / 2, (size - h) / 2, w, h));
        var rtb = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(dv);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        var ms = new MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }
}

/// <summary>Things stamped onto every page of a PDF, and a password.</summary>
static class Stamp
{
    public static string Watermark(string src, string text) => Pdfs.Edit(src, " watermarked", PdfDocumentOpenMode.Modify, d =>
    {
        foreach (var page in d.Pages)
        {
            using var g = XGraphics.FromPdfPage(page, XGraphicsPdfPageOptions.Append);
            double w = page.Width.Point, h = page.Height.Point;
            // Corner to corner, sized so the text spans about 70% of the diagonal.
            double diagonal = Math.Sqrt(w * w + h * h);
            var probe = g.MeasureString(text, new XFont("Arial", 100, XFontStyleEx.Bold));
            var font = new XFont("Arial", Math.Clamp(100 * diagonal * 0.7 / Math.Max(probe.Width, 1), 10, 160), XFontStyleEx.Bold);
            g.TranslateTransform(w / 2, h / 2);
            g.RotateTransform(-Math.Atan2(h, w) * 180 / Math.PI);
            g.DrawString(text, font, new XSolidBrush(XColor.FromArgb(56, 120, 120, 120)), 0, 0, XStringFormats.Center);
        }
    });

    public static string Number(string src) => Pdfs.Edit(src, " numbered", PdfDocumentOpenMode.Modify, d =>
    {
        var font = new XFont("Arial", 10);
        for (int i = 0; i < d.PageCount; i++)
        {
            var page = d.Pages[i];
            using var g = XGraphics.FromPdfPage(page, XGraphicsPdfPageOptions.Append);
            g.DrawString($"{i + 1} / {d.PageCount}", font, new XSolidBrush(XColor.FromArgb(255, 90, 90, 90)),
                new XRect(0, page.Height.Point - 34, page.Width.Point, 20), XStringFormats.Center);
        }
    });

    /// <summary>AES-256. The same password opens the file and lifts its restrictions.</summary>
    public static string Protect(string src, string password) => Pdfs.Edit(src, " locked", PdfDocumentOpenMode.Modify, d =>
    {
        d.SecuritySettings.UserPassword = password;
        d.SecuritySettings.OwnerPassword = password;
        d.SecurityHandler.SetEncryptionToV5();
    });
}

/// <summary>Small themed dialogs: pick one of several buttons, or type a line of text.</summary>
static class Prompt
{
    static Window Frame(string title, out StackPanel stack)
    {
        var theme = Theme.Current;
        var w = new Window
        {
            Title = title, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Topmost = true, MaxWidth = 560,
            Background = new SolidColorBrush(theme.Solid is Color c ? Color.FromRgb(c.R, c.G, c.B) : Theme.DarkMode ? Color.FromRgb(30, 30, 34) : Color.FromRgb(246, 246, 248)),
            Foreground = new SolidColorBrush(theme.TextColor),
        };
        w.Content = stack = new StackPanel { Margin = new Thickness(22) };
        return w;
    }

    static Button Accent(string label) => new()
    {
        Content = label, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 8), FontWeight = FontWeights.SemiBold,
        Background = new SolidColorBrush(Theme.Current.Accent), Foreground = Brushes.White, BorderThickness = new Thickness(0),
    };

    public static string Choose(string title, string message, IEnumerable<string> options)
    {
        string result = null;
        var w = Frame(title, out var stack);
        stack.Children.Add(new TextBlock { Text = message, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap });
        var row = new WrapPanel();
        foreach (var o in options)
        {
            var b = Accent(o);
            b.Click += (_, _) => { result = o; w.Close(); };
            row.Children.Add(b);
        }
        stack.Children.Add(row);
        w.ShowDialog();
        return result;
    }

    public static string Text(string title, string message, string initial = "", bool secret = false)
    {
        string result = null;
        var w = Frame(title, out var stack);
        stack.Children.Add(new TextBlock { Text = message, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10), TextWrapping = TextWrapping.Wrap });
        Control box = secret ? new PasswordBox() : new TextBox { Text = initial };
        box.MinWidth = 300; box.Padding = new Thickness(6, 4, 6, 4); box.Margin = new Thickness(0, 0, 0, 12);
        string Value() => box is PasswordBox p ? p.Password : ((TextBox)box).Text;
        stack.Children.Add(box);
        var ok = Accent("OK");
        ok.IsDefault = true;
        ok.Click += (_, _) => { if (Value().Length > 0) { result = Value(); w.Close(); } };
        stack.Children.Add(ok);
        w.Loaded += (_, _) => { box.Focus(); if (box is TextBox t) t.SelectAll(); };
        w.ShowDialog();
        return result;
    }

    /// <summary>For ops that run off the UI thread but need to ask first.</summary>
    public static T OnUi<T>(Func<T> ask) => Application.Current.Dispatcher.Invoke(ask);
}
