using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Satsuma;

/// <summary>Slider values, each −100…100; all zero leaves the picture untouched.</summary>
record Adjustments(double Exposure = 0, double Brightness = 0, double Contrast = 0, double Saturation = 0,
    double Temperature = 0, double Highlights = 0, double Shadows = 0)
{
    public bool IsIdentity => this == new Adjustments();
}

enum RedactStyle { Black, Pixelate, Blur }
enum MarkKind { Pen, Arrow, Box, Text }

/// <summary>One annotation in image pixels. Pen uses every point, the others the first and last.</summary>
record Mark(MarkKind Kind, List<Point> Points, Color Color, double Width, string Text = "");

/// <summary>Ratio 0 = fit the picture; Padding and Corner are fractions of the picture's longer side.</summary>
record Backdrop(Color From, Color To, double Padding = 0.08, double Corner = 0.03, bool Shadow = true, double Ratio = 0);

/// <summary>Pure image edits behind the editor windows. All geometry is in the image's own pixels.</summary>
static class ImageEdit
{
    public static byte[] Pixels(BitmapSource src, out int w, out int h)
    {
        var b = src.Format == PixelFormats.Bgra32 ? src : new FormatConvertedBitmap(src, PixelFormats.Bgra32, null, 0);
        (w, h) = (b.PixelWidth, b.PixelHeight);
        var px = new byte[w * h * 4];
        b.CopyPixels(px, w * 4, 0);
        return px;
    }

    public static BitmapSource FromPixels(byte[] px, int w, int h)
    {
        var b = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, px, w * 4);
        b.Freeze();
        return b;
    }

    /// <summary>Draws into a fresh w×h bitmap at 96 DPI, so one DIP is one pixel.</summary>
    public static BitmapSource Render(int w, int h, Action<DrawingContext> draw)
    {
        var dv = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(dv, BitmapScalingMode.HighQuality);
        using (var dc = dv.RenderOpen()) draw(dc);
        var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(dv);
        rtb.Freeze();
        return rtb;
    }

    /// <summary>Downscaled copy for live previews; returns the factor applied.</summary>
    public static BitmapSource Shrink(BitmapSource src, int maxSide, out double scale)
    {
        scale = Math.Min(1, (double)maxSide / Math.Max(src.PixelWidth, src.PixelHeight));
        if (scale >= 1) return src;
        var b = new TransformedBitmap(src, new ScaleTransform(scale, scale));
        b.Freeze();
        return b;
    }

    static double Clamp(double v) => v < 0 ? 0 : v > 1 ? 1 : v;

    public static BitmapSource Adjust(BitmapSource src, Adjustments a)
    {
        if (a.IsIdentity) return src;
        var px = Pixels(src, out int w, out int h);
        double gain = Math.Pow(2, a.Exposure / 50), lift = a.Brightness / 250, contrast = 1 + a.Contrast / 100,
            sat = 1 + a.Saturation / 100, warm = a.Temperature / 1000, hi = a.Highlights / 330, lo = a.Shadows / 330;
        Parallel.For(0, h, y =>
        {
            for (int i = y * w * 4, end = i + w * 4; i < end; i += 4)
            {
                double b = px[i] / 255.0, g = px[i + 1] / 255.0, r = px[i + 2] / 255.0;
                double L = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                // Highlights/shadows push the bright/dark end; the squared weight leaves midtones mostly alone.
                double tone = lift + hi * L * L + lo * (1 - L) * (1 - L);
                double Tone(double v) => ((v * gain + tone) - 0.5) * contrast + 0.5;
                (r, g, b) = (Tone(r) + warm, Tone(g), Tone(b) - warm);
                double gray = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                px[i + 2] = (byte)Math.Round(Clamp(gray + (r - gray) * sat) * 255);
                px[i + 1] = (byte)Math.Round(Clamp(gray + (g - gray) * sat) * 255);
                px[i] = (byte)Math.Round(Clamp(gray + (b - gray) * sat) * 255);
            }
        });
        return FromPixels(px, w, h);
    }

    public static Int32Rect ClampRect(Rect r, int w, int h)
    {
        int x = (int)Math.Clamp(Math.Round(r.X), 0, w - 1), y = (int)Math.Clamp(Math.Round(r.Y), 0, h - 1);
        return new Int32Rect(x, y, (int)Math.Clamp(Math.Round(r.Width), 1, w - x), (int)Math.Clamp(Math.Round(r.Height), 1, h - y));
    }

    public static BitmapSource Crop(BitmapSource src, Rect r)
    {
        var c = new CroppedBitmap(src, ClampRect(r, src.PixelWidth, src.PixelHeight));
        c.Freeze();
        return c;
    }

    public static BitmapSource Redact(BitmapSource src, IEnumerable<Rect> boxes, RedactStyle style)
    {
        var px = Pixels(src, out int w, out int h);
        int block = Math.Max(6, Math.Max(w, h) / 60);
        foreach (var box in boxes)
        {
            var r = ClampRect(box, w, h);
            if (style == RedactStyle.Black)
            {
                for (int y = r.Y; y < r.Y + r.Height; y++)
                    for (int x = r.X; x < r.X + r.Width; x++) { int i = (y * w + x) * 4; px[i] = px[i + 1] = px[i + 2] = 0; px[i + 3] = 255; }
                continue;
            }
            if (style == RedactStyle.Blur)
                for (int pass = 0; pass < 3; pass++) { BoxBlur(px, w, r, block, true); BoxBlur(px, w, r, block, false); }
            else
                for (int by = r.Y; by < r.Y + r.Height; by += block)
                    for (int bx = r.X; bx < r.X + r.Width; bx += block)
                    {
                        int x1 = Math.Min(bx + block, r.X + r.Width), y1 = Math.Min(by + block, r.Y + r.Height), n = (x1 - bx) * (y1 - by);
                        var sum = new long[4];
                        for (int y = by; y < y1; y++) for (int x = bx; x < x1; x++) for (int c = 0; c < 4; c++) sum[c] += px[(y * w + x) * 4 + c];
                        for (int y = by; y < y1; y++) for (int x = bx; x < x1; x++) for (int c = 0; c < 4; c++) px[(y * w + x) * 4 + c] = (byte)(sum[c] / n);
                    }
        }
        return FromPixels(px, w, h);
    }

    /// <summary>One running-sum pass along rows or columns, kept inside <paramref name="r"/> so nothing outside leaks in.</summary>
    static void BoxBlur(byte[] px, int w, Int32Rect r, int radius, bool horizontal)
    {
        int lines = horizontal ? r.Height : r.Width, len = horizontal ? r.Width : r.Height;
        var line = new byte[len * 4];
        int Index(int line_, int k) => horizontal ? ((r.Y + line_) * w + r.X + k) * 4 : ((r.Y + k) * w + r.X + line_) * 4;
        for (int l = 0; l < lines; l++)
        {
            for (int k = 0; k < len; k++) Buffer.BlockCopy(px, Index(l, k), line, k * 4, 4);
            for (int c = 0; c < 4; c++)
            {
                long sum = 0;
                for (int k = -radius; k <= radius; k++) sum += line[Math.Clamp(k, 0, len - 1) * 4 + c];
                for (int k = 0; k < len; k++)
                {
                    px[Index(l, k) + c] = (byte)(sum / (2 * radius + 1));
                    sum += line[Math.Min(k + radius + 1, len - 1) * 4 + c] - line[Math.Max(k - radius, 0) * 4 + c];
                }
            }
        }
    }

    public static BitmapSource Annotate(BitmapSource src, IEnumerable<Mark> marks) =>
        Render(src.PixelWidth, src.PixelHeight, dc =>
        {
            dc.DrawImage(src, new Rect(0, 0, src.PixelWidth, src.PixelHeight));
            foreach (var m in marks) Draw(dc, m);
        });

    public static void Draw(DrawingContext dc, Mark m)
    {
        if (m.Points.Count == 0) return;
        var brush = new SolidColorBrush(m.Color);
        var pen = new Pen(brush, m.Width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        Point a = m.Points[0], b = m.Points[^1];
        switch (m.Kind)
        {
            case MarkKind.Pen:
                var fig = new PathFigure { StartPoint = a };
                fig.Segments.Add(new PolyLineSegment(m.Points.Skip(1), true));
                dc.DrawGeometry(null, pen, new PathGeometry(new[] { fig }));
                break;
            case MarkKind.Box:
                dc.DrawRectangle(null, pen, new Rect(a, b));
                break;
            case MarkKind.Arrow:
                dc.DrawLine(pen, a, b);
                var dir = a - b;
                if (dir.Length < 1) break;
                dir.Normalize();
                double head = Math.Max(10, m.Width * 4);
                foreach (var turn in new[] { 28.0, -28.0 })
                {
                    var rot = new RotateTransform(turn).Transform(new Point(dir.X, dir.Y));
                    dc.DrawLine(pen, b, b + new Vector(rot.X, rot.Y) * head);
                }
                break;
            case MarkKind.Text:
                var ft = new FormattedText(m.Text, System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                    new Typeface("Segoe UI Variable Display, Segoe UI"), Math.Max(12, m.Width * 6), brush, 1);
                ft.SetFontWeight(FontWeights.Bold);
                dc.DrawText(ft, a);
                break;
        }
    }

    public static BitmapSource AddBackground(BitmapSource src, Backdrop bg)
    {
        double w = src.PixelWidth, h = src.PixelHeight, pad = Math.Max(w, h) * bg.Padding, corner = Math.Max(w, h) * bg.Corner;
        double cw = w + 2 * pad, ch = h + 2 * pad;
        if (bg.Ratio > 0) { if (cw / ch < bg.Ratio) cw = ch * bg.Ratio; else ch = cw / bg.Ratio; }
        var img = new Rect((cw - w) / 2, (ch - h) / 2, w, h);
        return Render((int)Math.Round(cw), (int)Math.Round(ch), dc =>
        {
            dc.DrawRectangle(new LinearGradientBrush(bg.From, bg.To, 45), null, new Rect(0, 0, cw, ch));
            if (bg.Shadow)
            {
                // A soft shadow from stacked translucent plates; DrawingVisual has no blur effect.
                double spread = Math.Max(w, h) * 0.03;
                for (int i = 8; i >= 1; i--)
                {
                    var r = img; r.Inflate(spread * i / 8, spread * i / 8); r.Offset(0, spread * 0.5);
                    dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(10, 0, 0, 0)), null, r, corner + spread * i / 8, corner + spread * i / 8);
                }
            }
            dc.PushClip(new RectangleGeometry(img, corner, corner));
            dc.DrawImage(src, img);
            dc.Pop();
        });
    }

    /// <summary>JPEG bytes no bigger than <paramref name="target"/>: binary-search the quality, then shrink if even q=10 is too big.</summary>
    public static byte[] EncodeUnder(BitmapSource src, long target)
    {
        byte[] Encode(BitmapSource b, int q)
        {
            var ms = new MemoryStream();
            var enc = new JpegBitmapEncoder { QualityLevel = q };
            enc.Frames.Add(BitmapFrame.Create(b));
            enc.Save(ms);
            return ms.ToArray();
        }
        var img = src.Format == PixelFormats.Bgr24 ? src : new FormatConvertedBitmap(src, PixelFormats.Bgr24, null, 0);
        for (int round = 0; round < 12; round++)
        {
            byte[] best = null;
            for (int lo = 10, hi = 95; lo <= hi;)
            {
                int q = (lo + hi) / 2;
                var bytes = Encode(img, q);
                if (bytes.Length <= target) { best = bytes; lo = q + 1; } else hi = q - 1;
            }
            if (best != null) return best;
            img = new TransformedBitmap(img, new ScaleTransform(0.75, 0.75));
        }
        throw new Fail($"Couldn't get the picture under {Thumbs.Bytes(target)}");
    }

    public static string CompressTo(string src, long target)
    {
        var outPath = Paths.Output(src, "jpg", " compressed");
        File.WriteAllBytes(outPath, EncodeUnder(Img.Load(src), target));
        return outPath;
    }
}
