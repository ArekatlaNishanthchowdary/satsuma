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
        }
        hover = Index(e.GetPosition(surface));
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

    /// <summary>The wheel drawn over <paramref name="backdrop"/>, for screenshots of each theme.</summary>
    public System.Windows.Media.Imaging.BitmapSource Render(Mode mode, List<string> sample, int? hoverIndex, Brush backdrop)
    {
        (Mode, files, theme, hover) = (mode, sample, Theme.Current, hoverIndex);
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
            double size = ops.Count > 10 || ops[i].Title.Length > 9 ? 11 : 13;
            Label(dc, ops[i].Title, At(mid, (Inner + Outer) / 2), size, FontWeights.SemiBold, hover == i ? Colors.White : text);
        }

        var title = hover is int h && h < ops.Count ? ops[h].Title : files.Count == 0 ? Mode.Title() : ops.Count == 0 ? "Nothing here" : Mode.Title();
        Label(dc, title, new Point(C, C - 9), 13.5, FontWeights.Bold, hover == null ? text : theme.Accent);
        var keys = new[] { ("Shift", Mode.Convert), ("Ctrl", Mode.Tools), ("Alt", Mode.Actions) };
        for (int k = 0; k < keys.Length; k++)
            Label(dc, keys[k].Item1, new Point(C + (k - 1) * 27, C + 13), 10, FontWeights.SemiBold,
                keys[k].Item2 == Mode ? theme.Accent : Theme.WithAlpha(text, 0.5));
    }

    static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");

    void Label(DrawingContext dc, string s, Point p, double size, FontWeight weight, Color color)
    {
        var ft = new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(Font, FontStyles.Normal, weight, FontStretches.Normal), size, new SolidColorBrush(color),
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
