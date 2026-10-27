using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Satsuma;

enum EditTool { Edit, Crop, Redact, Annotate, Background }

/// <summary>
/// One window for every image tool: live preview on the left (a downscaled copy), controls on the right, Save writes the
/// full-size result beside the original. Geometry is kept in full-image pixels and scaled for the preview.
/// </summary>
class Editor : Window
{
    readonly string path;
    readonly EditTool tool;
    readonly BitmapSource full, small;
    readonly double s;  // small = full × s
    readonly Theme theme = Theme.Current;
    readonly Image preview = new() { Stretch = Stretch.Fill };
    readonly Canvas overlay = new() { Background = Brushes.Transparent, ClipToBounds = true };
    readonly StackPanel panel = new() { Margin = new Thickness(18, 16, 18, 16) };
    Viewbox viewbox;
    Brush Text => new SolidColorBrush(theme.TextColor);

    // Tool state, all in full-image pixels.
    Adjustments adjust = new();
    Rect? crop;
    double cropRatio;
    readonly List<Rect> boxes = new();
    RedactStyle redactStyle = RedactStyle.Pixelate;
    readonly List<Mark> marks = new();
    MarkKind markKind = MarkKind.Arrow;
    Color markColor = Color.FromRgb(255, 59, 48);
    double markWidth = 6;
    string markText = "Note";
    Backdrop backdrop;
    Point? dragFrom;

    public static void Open(string path, EditTool tool) => new Editor(path, tool).Show();

    Editor(string path, EditTool tool)
    {
        (this.path, this.tool) = (path, tool);
        // Re-made at 96 DPI so one image pixel is one layout unit, whatever DPI the file declares.
        full = ImageEdit.FromPixels(ImageEdit.Pixels(Img.Load(path), out int fw, out int fh), fw, fh);
        small = ImageEdit.Shrink(full, 1400, out s);
        backdrop = new Backdrop(theme.Accent, Darken(theme.Accent, 0.45));
        Title = $"{tool switch { EditTool.Background => "Add Background", _ => tool.ToString() }}: {System.IO.Path.GetFileName(path)}";
        Width = 1080; Height = 720; MinWidth = 640; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var bg = theme.Solid is Color c ? Color.FromRgb(c.R, c.G, c.B) : Theme.DarkMode ? Color.FromRgb(30, 30, 34) : Color.FromRgb(246, 246, 248);
        Background = new SolidColorBrush(bg);
        Foreground = Text;

        overlay.Width = small.PixelWidth; overlay.Height = small.PixelHeight;
        overlay.MouseLeftButtonDown += (_, e) => { dragFrom = Full(e.GetPosition(overlay)); overlay.CaptureMouse(); Drag(dragFrom.Value, dragFrom.Value, false); };
        overlay.MouseMove += (_, e) => { if (dragFrom is Point a) Drag(a, Full(e.GetPosition(overlay)), false); };
        overlay.MouseLeftButtonUp += (_, e) => { if (dragFrom is Point a) { dragFrom = null; overlay.ReleaseMouseCapture(); Drag(a, Full(e.GetPosition(overlay)), true); } };
        var stage = new Grid();
        stage.Children.Add(preview);
        stage.Children.Add(overlay);
        // A checkerboard-free, slightly recessed stage so both light and dark pictures read.
        var left = new Border
        {
            Background = new SolidColorBrush(Theme.WithAlpha(theme.TextColor, 0.06)), CornerRadius = new CornerRadius(14), Margin = new Thickness(16, 16, 0, 16),
            Child = viewbox = new Viewbox { Child = stage, Margin = new Thickness(18), Stretch = Stretch.Uniform, StretchDirection = StretchDirection.Both },
        };
        viewbox.SizeChanged += (_, _) => Refresh();

        var save = Button("Save", true, Save);
        var reset = Button("Reset", false, Reset);
        var actions = new UniformGrid { Columns = 2, Margin = new Thickness(18, 0, 18, 18) };
        actions.Children.Add(reset); actions.Children.Add(save);
        var right = new DockPanel { Width = 280 };
        DockPanel.SetDock(actions, Dock.Bottom);
        right.Children.Add(actions);
        right.Children.Add(new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });

        var root = new DockPanel();
        DockPanel.SetDock(right, Dock.Right);
        root.Children.Add(right);
        root.Children.Add(left);
        Content = root;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control) Undo(); if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) Save(); };

        BuildControls();
        Refresh();
    }

    Point Full(Point p) => new(Math.Clamp(p.X, 0, small.PixelWidth) / s, Math.Clamp(p.Y, 0, small.PixelHeight) / s);
    static Rect Scale(Rect r, double k) => new(r.X * k, r.Y * k, r.Width * k, r.Height * k);
    static Color Darken(Color c, double f) => Color.FromRgb((byte)(c.R * f), (byte)(c.G * f), (byte)(c.B * f));

    // ---------- controls ----------

    void BuildControls()
    {
        Heading(Title.Split(':')[0]);
        switch (tool)
        {
            case EditTool.Edit:
                foreach (var (name, get, set) in new (string, Func<double>, Action<double>)[]
                {
                    ("Exposure", () => adjust.Exposure, v => adjust = adjust with { Exposure = v }),
                    ("Brightness", () => adjust.Brightness, v => adjust = adjust with { Brightness = v }),
                    ("Contrast", () => adjust.Contrast, v => adjust = adjust with { Contrast = v }),
                    ("Saturation", () => adjust.Saturation, v => adjust = adjust with { Saturation = v }),
                    ("Temperature", () => adjust.Temperature, v => adjust = adjust with { Temperature = v }),
                    ("Highlights", () => adjust.Highlights, v => adjust = adjust with { Highlights = v }),
                    ("Shadows", () => adjust.Shadows, v => adjust = adjust with { Shadows = v }),
                })
                    SliderRow(name, -100, 100, get(), v => { set(v); Refresh(); });
                break;
            case EditTool.Crop:
                Hint("Drag on the picture to choose the area.");
                Choice("Ratio", new[] { ("Free", 0.0), ("1:1", 1.0), ("4:3", 4 / 3.0), ("16:9", 16 / 9.0), ("4:5", 0.8) }, 0, r => { cropRatio = r; crop = null; Refresh(); });
                break;
            case EditTool.Redact:
                Hint("Drag over anything you want hidden. Ctrl+Z removes the last box.");
                Choice("Style", new[] { ("Pixelate", RedactStyle.Pixelate), ("Blur", RedactStyle.Blur), ("Black", RedactStyle.Black) }, 0, v => { redactStyle = v; Refresh(); });
                break;
            case EditTool.Annotate:
                Hint("Drag on the picture to draw. Ctrl+Z removes the last mark.");
                Choice("Draw", new[] { ("Arrow", MarkKind.Arrow), ("Box", MarkKind.Box), ("Pen", MarkKind.Pen), ("Text", MarkKind.Text) }, 0, v => markKind = v);
                Swatches("Colour", new[] { Color.FromRgb(255, 59, 48), Color.FromRgb(255, 204, 0), Color.FromRgb(52, 199, 89), Color.FromRgb(10, 132, 255), Colors.White, Colors.Black },
                    c => markColor = c);
                SliderRow("Width", 1, 30, markWidth, v => markWidth = v);
                var box = new TextBox { Text = markText, Margin = new Thickness(0, 4, 0, 12), Padding = new Thickness(6, 4, 6, 4) };
                box.TextChanged += (_, _) => markText = box.Text;
                Label("Text");
                panel.Children.Add(box);
                break;
            case EditTool.Background:
                var pairs = new[]
                {
                    (theme.Accent, Darken(theme.Accent, 0.45)), (Color.FromRgb(255, 179, 71), Color.FromRgb(214, 51, 108)),
                    (Color.FromRgb(94, 234, 212), Color.FromRgb(59, 130, 246)), (Color.FromRgb(196, 181, 253), Color.FromRgb(91, 33, 182)),
                    (Color.FromRgb(241, 245, 249), Color.FromRgb(203, 213, 225)), (Color.FromRgb(39, 39, 42), Color.FromRgb(9, 9, 11)),
                };
                Label("Backdrop");
                var row = new WrapPanel { Margin = new Thickness(0, 4, 0, 12) };
                foreach (var (a, b) in pairs)
                {
                    var chip = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand,
                        Background = new LinearGradientBrush(a, b, 45), BorderBrush = Text, BorderThickness = new Thickness(0.5) };
                    chip.MouseLeftButtonUp += (_, _) => { backdrop = backdrop with { From = a, To = b }; Refresh(); };
                    row.Children.Add(chip);
                }
                panel.Children.Add(row);
                SliderRow("Padding", 0, 40, backdrop.Padding * 100, v => { backdrop = backdrop with { Padding = v / 100 }; Refresh(); });
                SliderRow("Corners", 0, 20, backdrop.Corner * 100, v => { backdrop = backdrop with { Corner = v / 100 }; Refresh(); });
                var shadow = new CheckBox { Content = "Shadow", IsChecked = true, Foreground = Text, Margin = new Thickness(0, 0, 0, 12) };
                shadow.Click += (_, _) => { backdrop = backdrop with { Shadow = shadow.IsChecked == true }; Refresh(); };
                panel.Children.Add(shadow);
                Choice("Ratio", new[] { ("Auto", 0.0), ("1:1", 1.0), ("16:9", 16 / 9.0), ("4:5", 0.8) }, 0, r => { backdrop = backdrop with { Ratio = r }; Refresh(); });
                break;
        }
    }

    void Heading(string text) => panel.Children.Add(new TextBlock { Text = text, FontSize = 20, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 14) });
    void Label(string text) => panel.Children.Add(new TextBlock { Text = text.ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeights.SemiBold, Opacity = 0.6 });
    void Hint(string text) => panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.75, Margin = new Thickness(0, 0, 0, 14) });

    /// <summary>Label + value on one line, slider below; double-click the slider to zero it.</summary>
    void SliderRow(string name, double min, double max, double value, Action<double> changed)
    {
        var head = new DockPanel();
        var val = new TextBlock { Text = $"{value:0}", Opacity = 0.7 };
        DockPanel.SetDock(val, Dock.Right);
        head.Children.Add(val);
        head.Children.Add(new TextBlock { Text = name, FontWeight = FontWeights.SemiBold });
        var slider = new Slider { Minimum = min, Maximum = max, Value = value, Margin = new Thickness(0, 4, 0, 14), Foreground = new SolidColorBrush(theme.Accent) };
        double initial = value;
        slider.ValueChanged += (_, e) => { val.Text = $"{e.NewValue:0}"; changed(e.NewValue); };
        slider.MouseDoubleClick += (_, _) => slider.Value = initial;
        panel.Children.Add(head);
        panel.Children.Add(slider);
        resets.Add(() => slider.Value = initial);
    }

    /// <summary>A row of pill toggles; exactly one is on.</summary>
    void Choice<T>(string label, (string, T)[] options, int selected, Action<T> pick)
    {
        Label(label);
        var row = new WrapPanel { Margin = new Thickness(0, 4, 0, 12) };
        var pills = new List<Border>();
        void Select(int k)
        {
            for (int j = 0; j < pills.Count; j++)
            {
                pills[j].Background = new SolidColorBrush(j == k ? theme.Accent : Theme.WithAlpha(theme.TextColor, 0.08));
                ((TextBlock)pills[j].Child).Foreground = j == k ? Brushes.White : Text;
            }
            pick(options[k].Item2);
        }
        for (int i = 0; i < options.Length; i++)
        {
            int k = i;
            var pill = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(0, 0, 6, 6), Cursor = Cursors.Hand,
                Child = new TextBlock { Text = options[i].Item1, FontWeight = FontWeights.SemiBold } };
            pill.MouseLeftButtonUp += (_, _) => Select(k);
            pills.Add(pill);
            row.Children.Add(pill);
        }
        panel.Children.Add(row);
        Select(selected);
        resets.Add(() => Select(selected));
    }

    void Swatches(string label, Color[] colors, Action<Color> pick)
    {
        Label(label);
        var row = new WrapPanel { Margin = new Thickness(0, 4, 0, 12) };
        var rings = new List<Border>();
        foreach (var c in colors)
        {
            var ring = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Margin = new Thickness(0, 0, 8, 8), Cursor = Cursors.Hand,
                Background = new SolidColorBrush(c), BorderBrush = new SolidColorBrush(theme.Accent) };
            ring.MouseLeftButtonUp += (_, _) => { rings.ForEach(r => r.BorderThickness = new Thickness(0)); ring.BorderThickness = new Thickness(3); pick(c); };
            rings.Add(ring);
            row.Children.Add(ring);
        }
        rings[0].BorderThickness = new Thickness(3);
        panel.Children.Add(row);
    }

    Button Button(string text, bool primary, Action click)
    {
        var b = new Button
        {
            Content = text, Height = 36, Margin = new Thickness(primary ? 6 : 0, 0, primary ? 0 : 6, 0), FontWeight = FontWeights.SemiBold,
            Background = primary ? new SolidColorBrush(theme.Accent) : new SolidColorBrush(Theme.WithAlpha(theme.TextColor, 0.08)),
            Foreground = primary ? Brushes.White : Text, BorderThickness = new Thickness(0),
        };
        b.Click += (_, _) => click();
        return b;
    }

    readonly List<Action> resets = new();

    // ---------- interaction ----------

    void Drag(Point a, Point b, bool done)
    {
        var r = new Rect(a, b);
        switch (tool)
        {
            case EditTool.Crop:
                if (cropRatio > 0)
                {
                    // Keep the ratio: the drag's larger extent wins, anchored at the start point.
                    double w = Math.Max(r.Width, r.Height * cropRatio), h = w / cropRatio;
                    r = new Rect(b.X < a.X ? a.X - w : a.X, b.Y < a.Y ? a.Y - h : a.Y, w, h);
                }
                crop = r.Width > 2 && r.Height > 2 ? r : null;
                break;
            case EditTool.Redact:
                if (done && r.Width > 2 && r.Height > 2) boxes.Add(r);
                else live = done ? null : r;
                break;
            case EditTool.Annotate:
                if (markKind == MarkKind.Pen)
                {
                    if (current == null) { current = new Mark(MarkKind.Pen, new List<Point> { a }, markColor, markWidth); }
                    current.Points.Add(b);
                }
                else current = new Mark(markKind, new List<Point> { a, b }, markColor, markWidth, markText);
                if (done) { if (current.Kind == MarkKind.Text || (b - a).Length > 2 || current.Kind == MarkKind.Pen) marks.Add(current); current = null; }
                Refresh();
                return;
            default:
                return;
        }
        if (done) live = null;
        Refresh();
    }

    Rect? live;
    Mark current;

    void Undo()
    {
        if (tool == EditTool.Redact && boxes.Count > 0) boxes.RemoveAt(boxes.Count - 1);
        if (tool == EditTool.Annotate && marks.Count > 0) marks.RemoveAt(marks.Count - 1);
        Refresh();
    }

    void Reset()
    {
        (adjust, crop, current, live) = (new(), null, null, null);
        boxes.Clear(); marks.Clear();
        backdrop = new Backdrop(theme.Accent, Darken(theme.Accent, 0.45));
        foreach (var r in resets) r();
        Refresh();
    }

    // ---------- rendering ----------

    Mark ScaleMark(Mark m, double k) => m with { Points = m.Points.Select(p => new Point(p.X * k, p.Y * k)).ToList(), Width = m.Width * k };

    BitmapSource Apply(BitmapSource img, double k, bool final) => tool switch
    {
        EditTool.Edit => ImageEdit.Adjust(img, adjust),
        EditTool.Crop => crop is Rect r && final ? ImageEdit.Crop(img, r) : img,  // the preview shows the frame instead
        EditTool.Redact => boxes.Count == 0 ? img : ImageEdit.Redact(img, boxes.Select(b => Scale(b, k)), redactStyle),
        EditTool.Annotate => ImageEdit.Annotate(img, marks.Append(current).Where(m => m != null).Select(m => ScaleMark(m, k))),
        EditTool.Background => ImageEdit.AddBackground(img, backdrop),
        _ => img,
    };

    void Refresh()
    {
        var shown = Apply(small, s, false);
        preview.Source = shown;
        // Add Background changes the canvas size, so the stage follows the result.
        overlay.Width = preview.Width = shown.PixelWidth;
        overlay.Height = preview.Height = shown.PixelHeight;
        overlay.Children.Clear();
        var accent = new SolidColorBrush(theme.Accent);
        if (tool == EditTool.Crop && crop is Rect c)
        {
            var frame = Scale(c, s);
            var dim = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(new Rect(0, 0, small.PixelWidth, small.PixelHeight)), new RectangleGeometry(frame));
            overlay.Children.Add(new Path { Data = dim, Fill = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0)) });
            overlay.Children.Add(new Path { Data = new RectangleGeometry(frame), Stroke = accent, StrokeThickness = 2 / Zoom });
        }
        if (tool == EditTool.Redact && live is Rect l)
            overlay.Children.Add(new Path { Data = new RectangleGeometry(Scale(l, s)), Stroke = accent, StrokeThickness = 2 / Zoom, StrokeDashArray = new DoubleCollection { 4, 3 } });
    }

    /// <summary>How much the Viewbox magnifies the preview, so outlines stay ~2 screen pixels thick.</summary>
    double Zoom => viewbox.ActualWidth > 0 && overlay.Width > 0
        ? Math.Max(0.05, Math.Min(viewbox.ActualWidth / overlay.Width, viewbox.ActualHeight / overlay.Height)) : 1;

    void Save()
    {
        try
        {
            if (tool == EditTool.Crop && crop == null) throw new Fail("Drag on the picture to choose what to keep first.");
            var suffix = tool switch { EditTool.Edit => " edited", EditTool.Crop => " cropped", EditTool.Redact => " redacted", EditTool.Annotate => " annotated", _ => " background" };
            var outPath = Paths.Output(path, Img.SameFormat(path), suffix);
            Img.Save(Apply(full, 1, true), outPath, 92);
            Process.Start("explorer.exe", $"/select,\"{outPath}\"");
            Close();
        }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Couldn't save", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    /// <summary>For --shots: the editor window as a picture, after <paramref name="setup"/> has set some state.</summary>
    public static BitmapSource Snapshot(string path, EditTool tool, Action<Editor> setup)
    {
        var e = new Editor(path, tool) { ShowInTaskbar = false, Left = -4000, Top = -4000, ShowActivated = false };
        setup?.Invoke(e);
        e.Refresh();
        e.Show();
        e.UpdateLayout();
        e.Refresh();
        e.UpdateLayout();
        var root = (FrameworkElement)e.Content;
        var rtb = new RenderTargetBitmap((int)root.ActualWidth, (int)root.ActualHeight, 96, 96, PixelFormats.Pbgra32);
        var bg = new DrawingVisual();
        using (var dc = bg.RenderOpen()) dc.DrawRectangle(e.Background, null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
        rtb.Render(bg);
        rtb.Render(root);  // renders compose, so the window content lands on its background
        e.Close();
        return rtb;
    }

    public void Demo()
    {
        switch (tool)
        {
            case EditTool.Edit: adjust = new Adjustments(Exposure: 20, Contrast: 25, Saturation: 30, Temperature: 30); break;
            case EditTool.Crop: crop = new Rect(full.PixelWidth * 0.15, full.PixelHeight * 0.1, full.PixelWidth * 0.6, full.PixelHeight * 0.7); break;
            case EditTool.Redact: boxes.Add(new Rect(full.PixelWidth * 0.55, full.PixelHeight * 0.2, full.PixelWidth * 0.3, full.PixelHeight * 0.25)); break;
            case EditTool.Annotate:
                marks.Add(new Mark(MarkKind.Arrow, new() { new(full.PixelWidth * 0.2, full.PixelHeight * 0.8), new(full.PixelWidth * 0.5, full.PixelHeight * 0.45) }, markColor, Math.Max(4, full.PixelWidth / 150.0)));
                marks.Add(new Mark(MarkKind.Text, new() { new(full.PixelWidth * 0.08, full.PixelHeight * 0.82) }, markColor, Math.Max(4, full.PixelWidth / 150.0), "Look here"));
                break;
        }
    }
}

/// <summary>Asks for a target size; returns bytes, or null if cancelled.</summary>
static class SizePrompt
{
    public static long? Ask(string file)
    {
        var theme = Theme.Current;
        long? result = null;
        var w = new Window
        {
            Title = "Compress to size", SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Topmost = true,
            Background = new SolidColorBrush(theme.Solid is Color c ? Color.FromRgb(c.R, c.G, c.B) : Theme.DarkMode ? Color.FromRgb(30, 30, 34) : Color.FromRgb(246, 246, 248)),
            Foreground = new SolidColorBrush(theme.TextColor),
        };
        var stack = new StackPanel { Margin = new Thickness(22) };
        stack.Children.Add(new TextBlock { Text = $"Make {System.IO.Path.GetFileName(file)} at most…", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 12) });
        var row = new WrapPanel();
        foreach (var (label, bytes) in new[] { ("100 KB", 100_000L), ("250 KB", 250_000L), ("500 KB", 500_000L), ("1 MB", 1_000_000L), ("2 MB", 2_000_000L), ("5 MB", 5_000_000L) })
        {
            var b = new Button { Content = label, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 8), FontWeight = FontWeights.SemiBold,
                Background = new SolidColorBrush(theme.Accent), Foreground = Brushes.White, BorderThickness = new Thickness(0) };
            b.Click += (_, _) => { result = bytes; w.Close(); };
            row.Children.Add(b);
        }
        stack.Children.Add(row);
        w.Content = stack;
        w.ShowDialog();
        return result;
    }
}
