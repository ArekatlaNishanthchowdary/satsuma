using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace Satsuma;

/// <summary>The ring of options that appears under the pointer mid-drag. Files are dropped onto a slice.</summary>
class WheelWindow : Window
{
    public const double Size = 380;
    const double Inner = 58, Outer = 182, C = Size / 2;

    public Mode Mode { get; private set; }
    public Action<Op, List<string>, Mode> OnPick;
    List<string> files = new();
    List<Op> ops = new();
    int? hover;
    Theme theme = Theme.Current;
    System.Windows.Media.Imaging.BitmapSource thumb;
    string thumbFor, sizeText = "";
    readonly Surface surface;

    class Surface : FrameworkElement
    {
        public WheelWindow Owner;
        protected override void OnRender(DrawingContext dc) => Owner.Draw(dc);
    }

    public WheelWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Width = Height = Size;
        AllowDrop = true;
        Content = surface = new Surface { Owner = this };
        DragEnter += OnDrag;
        DragOver += OnDrag;
        DragLeave += (_, _) => { hover = null; surface.InvalidateVisual(); };
        Drop += OnDrop;
        SourceInitialized += (_, _) =>
        {
            // Never steal focus from Explorer mid-drag, and stay out of Alt+Tab.
            var h = new WindowInteropHelper(this).Handle;
            SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x08000000 | 0x80);
        };
    }

    /// <summary>files == null keeps the current files (they arrive with DragEnter).</summary>
    public void ShowAt(Mode mode, List<string> newFiles, Point centerDip, int? previewHover = null)
    {
        if (!IsVisible) { files = new(); Left = centerDip.X - Size / 2; Top = centerDip.Y - Size / 2; }
        if (newFiles != null) files = newFiles;
        FilesChanged();
        Mode = mode;
        theme = Theme.Current;
        ops = Catalog.Ops(mode, files);
        hover = previewHover;
        if (!IsVisible) Show();
        surface.InvalidateVisual();
    }

    void OnDrag(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] dropped && !dropped.SequenceEqual(files))
        {
            files = dropped.ToList();
            ops = Catalog.Ops(Mode, files);
            FilesChanged();
        }
        var next = Index(e.GetPosition(surface));
        if (next != hover && next != null) Click.Play();
        hover = next;
        e.Effects = hover == null ? DragDropEffects.None : DragDropEffects.Copy;
        e.Handled = true;
        surface.InvalidateVisual();
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (hover is not int i || i >= ops.Count) return;
        var (op, picked, mode) = (ops[i], files, Mode);
        Hide();
        OnPick?.Invoke(op, picked, mode);
    }

    async void FilesChanged()
    {
        sizeText = Thumbs.Describe(files);
        var f = files.FirstOrDefault();
        if (f == thumbFor) return;
        (thumbFor, thumb) = (f, null);
        if (f == null) return;
        try
        {
            var t = await Thumbs.Get(f, 96);
            if (thumbFor == f) { thumb = t; surface.InvalidateVisual(); }
        }
        catch { }  // no thumbnail: the hub shows the mode name instead
    }

    /// <summary>The wheel drawn over <paramref name="backdrop"/>, for screenshots of each theme.</summary>
    public System.Windows.Media.Imaging.BitmapSource Render(Mode mode, List<string> sample, int? hoverIndex, Brush backdrop, System.Windows.Media.Imaging.BitmapSource sampleThumb = null)
    {
        (Mode, files, theme, hover, thumb, sizeText) = (mode, sample, Theme.Current, hoverIndex, sampleThumb, "2.4 MB");
        ops = Catalog.Ops(mode, files);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(backdrop, null, new Rect(0, 0, Size, Size));
            Draw(dc);
        }
        var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Size * 2, (int)Size * 2, 192, 192, PixelFormats.Pbgra32);
        rtb.Render(dv);
        return rtb;
    }

    double Step => 2 * Math.PI / Math.Max(ops.Count, 1);
    static Point At(double angle, double r) => new(C + Math.Sin(angle) * r, C - Math.Cos(angle) * r);

    /// <summary>Slice under a point; angles run clockwise from 12 o'clock.</summary>
    int? Index(Point p)
    {
        double dx = p.X - C, dy = C - p.Y, r = Math.Sqrt(dx * dx + dy * dy);
        if (ops.Count == 0 || r < Inner || r > Outer + 24) return null;
        var a = Math.Atan2(dx, dy);
        if (a < 0) a += 2 * Math.PI;
        return (int)(a / Step) % ops.Count;
    }

    Geometry Slice(int i, Geometry ring)
    {
        if (ops.Count == 1) return ring;
        double a0 = i * Step, a1 = a0 + Step;
        var fig = new PathFigure { StartPoint = At(a0, Outer), IsClosed = true };
        fig.Segments.Add(new ArcSegment(At(a1, Outer), new Size(Outer, Outer), 0, Step > Math.PI, SweepDirection.Clockwise, true));
        fig.Segments.Add(new LineSegment(At(a1, Inner), true));
        fig.Segments.Add(new ArcSegment(At(a0, Inner), new Size(Inner, Inner), 0, Step > Math.PI, SweepDirection.Counterclockwise, true));
        return new PathGeometry(new[] { fig });
    }

    void Draw(DrawingContext dc)
    {
        var center = new Point(C, C);
        var ring = new CombinedGeometry(GeometryCombineMode.Exclude, new EllipseGeometry(center, Outer, Outer), new EllipseGeometry(center, Inner, Inner));
        var hub = new EllipseGeometry(center, Inner, Inner);
        var text = theme.TextColor;

        foreach (var g in new Geometry[] { ring, hub })
        {
            dc.DrawGeometry(theme.Base, null, g);
            if (theme.TintBrush != null) dc.DrawGeometry(theme.TintBrush, null, g);
            if (theme.Highlight != null) dc.DrawGeometry(theme.Highlight, null, g);
        }
        if (theme.Rim != null) { dc.DrawEllipse(null, theme.Rim, center, Outer - 0.6, Outer - 0.6); dc.DrawEllipse(null, theme.Rim, center, Inner - 0.6, Inner - 0.6); }

        var sep = new Pen(new SolidColorBrush(Theme.WithAlpha(text, 0.14)), 1);
        for (int i = 0; i < ops.Count; i++)
        {
            double a0 = i * Step, mid = a0 + Step / 2;
            if (hover == i) dc.DrawGeometry(new SolidColorBrush(Theme.WithAlpha(theme.Accent, theme.IsGlass ? 0.88 : 1)), null, Slice(i, ring));
            if (ops.Count > 1) dc.DrawLine(sep, At(a0, Inner), At(a0, Outer));
            var color = hover == i ? Colors.White : text;
            var at = At(mid, (Inner + Outer) / 2);
            if (Icons.TryGetValue(ops[i].Title, out var glyph))
            {
                // Tools and actions: icon over a small caps label. Format slices stay text-only.
                Label(dc, glyph.ToString(), new Point(at.X, at.Y - 9), 18, FontWeights.Normal, color, IconFont);
                Label(dc, ops[i].Title.ToUpperInvariant(), new Point(at.X, at.Y + 12), ops[i].Title.Length > 11 ? 9 : 10, FontWeights.Bold, color);
            }
            else Label(dc, ops[i].Title, at, ops.Count > 10 ? 12 : 14.5, FontWeights.Bold, color);
        }

        // Hub: the file's thumbnail (or the hovered option / mode name), its size, then the mode keys.
        if (hover is int h && h < ops.Count) Label(dc, ops[h].Title, new Point(C, C - 15), 13.5, FontWeights.Bold, theme.Accent);
        else if (thumb != null)
        {
            const double t = 34;
            double scale = t / Math.Max(thumb.PixelWidth, thumb.PixelHeight), w = thumb.PixelWidth * scale, ht = thumb.PixelHeight * scale;
            var box = new Rect(C - w / 2, C - 15 - ht / 2, w, ht);
            dc.PushClip(new RectangleGeometry(box, 5, 5));
            dc.DrawImage(thumb, box);
            dc.Pop();
        }
        else Label(dc, files.Count > 0 && ops.Count == 0 ? "Nothing here" : Mode.Title(), new Point(C, C - 15), 13.5, FontWeights.Bold, text);
        Label(dc, sizeText, new Point(C, C + 10), 10.5, FontWeights.SemiBold, Theme.WithAlpha(text, 0.75));
        var keys = new[] { ("Shift", Mode.Convert), ("Ctrl", Mode.Tools), ("Alt", Mode.Actions) };
        for (int k = 0; k < keys.Length; k++)
            Label(dc, keys[k].Item1, new Point(C + (k - 1) * 27, C + 27), 9.5, FontWeights.SemiBold,
                keys[k].Item2 == Mode ? theme.Accent : Theme.WithAlpha(text, 0.5));
    }

    static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");
    // Segoe Fluent Icons ships with Windows 11; MDL2 Assets (same code points) with Windows 10.
    static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    static readonly Dictionary<string, char> Icons = new()
    {
        ["Compress"] = '', ["Edit"] = '', ["Trim"] = '', ["Bleep"] = '', ["Channels"] = '', ["Visualize"] = '', ["Split"] = '', ["Speed"] = '', ["Crop"] = '', ["Redact"] = '', ["Annotate"] = '', ["Add BG"] = '', ["Resize 50%"] = '', ["Rotate"] = '', ["Flip"] = '',
        ["Grayscale"] = '', ["Strip Metadata"] = '', ["Make PDF"] = '', ["Zip"] = '',
        ["Snapshot"] = '', ["Extract Audio"] = '', ["Mute"] = '', ["Speed 2×"] = '',
        ["Join"] = '', ["Normalize"] = '', ["Trim Silence"] = '', ["Mono"] = '',
        ["Split Pages"] = '', ["Merge"] = '', ["Extract"] = '',
        ["Copy"] = '', ["Copy Path"] = '', ["Terminal"] = '', ["Open"] = '', ["Float"] = '\uE718', ["Share"] = '\uE72D', ["Move To…"] = '',
    };

    void Label(DrawingContext dc, string s, Point p, double size, FontWeight weight, Color color, FontFamily family = null)
    {
        var ft = new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(family ?? Font, FontStyles.Normal, weight, FontStretches.Normal), size, new SolidColorBrush(color),
            VisualTreeHelper.GetDpi(surface).PixelsPerDip);
        var at = new Point(p.X - ft.Width / 2, p.Y - ft.Height / 2);
        if (theme.IsGlass)
        {
            // A soft shadow keeps labels legible on whatever shows through the glass.
            var shadow = ft.BuildGeometry(new Point(at.X, at.Y + 1));
            dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(color.R > 128 ? (byte)90 : (byte)40, 0, 0, 0)), null, shadow);
        }
        dc.DrawText(ft, at);
    }

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
}

/// <summary>Shell thumbnails and a short size line for the hub and the Float window.</summary>
static class Thumbs
{
    public static async System.Threading.Tasks.Task<System.Windows.Media.Imaging.BitmapSource> Get(string path, uint size)
    {
        Windows.Storage.IStorageItemProperties item = System.IO.Directory.Exists(path)
            ? await Windows.Storage.StorageFolder.GetFolderFromPathAsync(path)
            : await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
        using var t = await item.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.SingleItem, size);
        using var s = System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(t);
        var frame = System.Windows.Media.Imaging.BitmapDecoder.Create(s, System.Windows.Media.Imaging.BitmapCreateOptions.None,
            System.Windows.Media.Imaging.BitmapCacheOption.OnLoad).Frames[0];
        frame.Freeze();
        return frame;
    }

    public static string Bytes(long n)
    {
        double bytes = n;
        var units = new[] { "B", "KB", "MB", "GB", "TB" };
        int u = 0;
        for (; bytes >= 1000 && u < units.Length - 1; u++) bytes /= 1000;
        return u == 0 ? $"{bytes:0} B" : $"{bytes:0.#} {units[u]}";
    }

    /// <summary>"2.4 MB", or "3 items · 7.1 MB"; folders aren't walked, so they add nothing.</summary>
    public static string Describe(List<string> files)
    {
        if (files.Count == 0) return "";
        var size = Bytes(files.Where(System.IO.File.Exists).Sum(f => new System.IO.FileInfo(f).Length));
        if (files.Count == 1) return System.IO.Directory.Exists(files[0]) ? "Folder" : size;
        return $"{files.Count} items · {size}";
    }
}

/// <summary>An always-on-top preview of a file: the picture itself for images, the shell thumbnail otherwise.</summary>
static class Float
{
    // ponytail: still image only; video/audio playback would need a MediaElement and transport controls.
    public static void Show(string path)
    {
        System.Windows.Media.Imaging.BitmapSource img = null;
        if (Catalog.KindOf(path) == Kind.Image) try { img = Img.Load(path); } catch { }
        // Off the UI thread: Thumbs.Get awaits WinRT calls that would otherwise post back to this blocked thread.
        img ??= System.Threading.Tasks.Task.Run(() => Thumbs.Get(path, 256)).GetAwaiter().GetResult();
        double scale = Math.Min(1, Math.Min(520.0 / img.PixelWidth, 520.0 / img.PixelHeight));
        var image = new Image { Source = img, Width = img.PixelWidth * scale, Height = img.PixelHeight * scale, Stretch = Stretch.Uniform };
        var w = new Window
        {
            Title = System.IO.Path.GetFileName(path), Topmost = true, WindowStyle = WindowStyle.ToolWindow,
            SizeToContent = SizeToContent.WidthAndHeight, Content = image, Background = Brushes.Black,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
        };
        // Sized to the picture first, then free to resize with the picture following.
        w.ContentRendered += (_, _) => { w.SizeToContent = SizeToContent.Manual; image.Width = image.Height = double.NaN; };
        w.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) w.Close(); };
        w.Show();
    }
}

/// <summary>The Windows share sheet (Nearby Sharing, Mail, Teams, …) for a desktop app, via the HWND interop.</summary>
static class Share
{
    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow(IntPtr appWindow, ref Guid riid);
        void ShowShareUIForWindow(IntPtr appWindow);
    }

    static Guid dtmIid = new("a5caee9b-8708-49d1-8d36-67d25a8da00c");
    static Window host;
    static List<Windows.Storage.IStorageItem> items;

    public static void Files(List<string> files)
    {
        items = System.Threading.Tasks.Task.Run(async () =>
        {
            var list = new List<Windows.Storage.IStorageItem>();
            foreach (var f in files)
                list.Add(System.IO.Directory.Exists(f) ? await Windows.Storage.StorageFolder.GetFolderFromPathAsync(f) : await Windows.Storage.StorageFile.GetFileFromPathAsync(f));
            return list;
        }).GetAwaiter().GetResult();
        var interop = Windows.ApplicationModel.DataTransfer.DataTransferManager.As<IDataTransferManagerInterop>();
        if (host == null)
        {
            // The sheet anchors to a window of ours; an invisible 1-pixel one mid-screen is enough.
            var area = SystemParameters.WorkArea;
            host = new Window { Width = 1, Height = 1, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent,
                ShowInTaskbar = false, Topmost = true, Left = area.Left + area.Width / 2, Top = area.Top + area.Height / 2 };
            host.Show();
            var dtm = WinRT.MarshalInterface<Windows.ApplicationModel.DataTransfer.DataTransferManager>.FromAbi(
                interop.GetForWindow(new WindowInteropHelper(host).Handle, ref dtmIid));
            dtm.DataRequested += (_, e) =>
            {
                e.Request.Data.Properties.Title = items.Count == 1 ? items[0].Name : $"{items.Count} items";
                e.Request.Data.SetStorageItems(items);
            };
        }
        interop.ShowShareUIForWindow(new WindowInteropHelper(host).Handle);
    }
}

/// <summary>Small floating "working…" card while a job runs.</summary>
class Hud : Window
{
    readonly TextBlock label = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    int jobs;

    public Hud()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Width = 300;
        Height = 64;
    }

    public void Start(string text)
    {
        jobs++;
        var t = Theme.Current;
        var stack = new StackPanel { Margin = new Thickness(18, 12, 18, 12) };
        label.Text = text;
        label.Foreground = new SolidColorBrush(t.TextColor);
        if (label.Parent is Panel old) old.Children.Remove(label);
        stack.Children.Add(label);
        stack.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4, Margin = new Thickness(0, 9, 0, 0),
            Foreground = new SolidColorBrush(t.Accent), Background = new SolidColorBrush(Theme.WithAlpha(t.TextColor, 0.12)), BorderThickness = new Thickness(0) });
        var layers = new Grid();
        foreach (var b in new[] { t.Base, t.TintBrush, t.Highlight })
            if (b != null) layers.Children.Add(new Border { Background = b, CornerRadius = new CornerRadius(20) });
        layers.Children.Add(new Border { CornerRadius = new CornerRadius(20), BorderThickness = new Thickness(t.Rim != null ? 1.2 : 0), BorderBrush = t.Rim?.Brush });
        layers.Children.Add(stack);
        Content = layers;
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Bottom - Height - 80;
        Show();
    }

    public void Finish()
    {
        if (--jobs <= 0) { jobs = 0; Hide(); }
    }
}
