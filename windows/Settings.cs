using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace Satsuma;

/// <summary>
/// The user's order and hidden slices for each wheel, one registry value per kind and mode:
/// "PNG|JPG|-GIF" lists titles in order, a leading "-" hides one. Slices not listed keep their place at the end.
/// </summary>
static class Layout
{
    const string Key = @"Software\Satsuma\Wheel";

    static string Name(Kind kind, Mode mode) => mode == Mode.Actions ? "Actions" : $"{kind}.{mode}";

    public static List<(string Title, bool Hidden)> Get(Kind kind, Mode mode) =>
        (Registry.CurrentUser.OpenSubKey(Key)?.GetValue(Name(kind, mode)) as string)?.Split('|', StringSplitOptions.RemoveEmptyEntries)
            .Select(t => t[0] == '-' ? (t[1..], true) : (t, false)).ToList();

    public static void Set(Kind kind, Mode mode, IEnumerable<(string Title, bool Hidden)> items) =>
        Registry.CurrentUser.CreateSubKey(Key).SetValue(Name(kind, mode), string.Join("|", items.Select(i => (i.Hidden ? "-" : "") + i.Title)));

    public static void Reset(Kind kind, Mode mode) => Registry.CurrentUser.CreateSubKey(Key).DeleteValue(Name(kind, mode), false);

    public static List<Op> Apply(List<Op> ops, Kind kind, Mode mode)
    {
        var saved = Get(kind, mode);
        if (saved == null) return ops;
        int Rank(Op o) { int i = saved.FindIndex(s => s.Title == o.Title); return i < 0 ? int.MaxValue : i; }
        return ops.Where(o => !saved.Any(s => s.Hidden && s.Title == o.Title)).OrderBy(Rank).ToList();  // OrderBy is stable
    }
}

/// <summary>"Customize Wheel…": tick slices on or off and drag them into order, with the wheel previewed beside the list.</summary>
class Customizer : Window
{
    static Customizer open;

    class Row { public string Title { get; set; } public bool Shown { get; set; } }

    static readonly Kind[] Kinds =
    {
        Kind.Image, Kind.Video, Kind.Audio, Kind.Pdf, Kind.Document, Kind.Sheet, Kind.Slides, Kind.Subtitle, Kind.Archive, Kind.Data, Kind.Font, Kind.Other,
    };

    readonly ComboBox kindBox = new() { Margin = new Thickness(0, 0, 8, 0), MinWidth = 120 };
    readonly ComboBox modeBox = new() { MinWidth = 110 };
    readonly ListBox list = new() { Height = 330, Width = 230, Margin = new Thickness(0, 10, 0, 10) };
    readonly Image preview = new() { Width = 300, Height = 300, Margin = new Thickness(18, 0, 0, 0) };
    readonly ObservableCollection<Row> rows = new();
    Row dragging;

    /// <summary>For README screenshots: the window drawn off-screen with the PDF tools wheel picked.</summary>
    public static System.Windows.Media.Imaging.BitmapSource Snapshot()
    {
        var c = new Customizer { Left = -20000, Top = -20000, ShowActivated = false };
        c.kindBox.SelectedIndex = Array.IndexOf(Kinds, Kind.Pdf);
        c.modeBox.SelectedIndex = 1;
        ((Window)c).Show();
        c.UpdateLayout();
        var root = (FrameworkElement)c.Content;
        var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap((int)root.ActualWidth * 2, (int)root.ActualHeight * 2, 192, 192, PixelFormats.Pbgra32);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen()) { dc.DrawRectangle(c.Background, null, new Rect(0, 0, root.ActualWidth, root.ActualHeight)); dc.DrawRectangle(new VisualBrush(root), null, new Rect(0, 0, root.ActualWidth, root.ActualHeight)); }
        rtb.Render(dv);
        c.Close();
        return rtb;
    }

    public static void Show() { if (open != null) { open.Activate(); return; } open = new Customizer(); open.Closed += (_, _) => open = null; ((Window)open).Show(); }

    Customizer()
    {
        var theme = Theme.Current;
        Title = "Customize Wheel";
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(theme.Solid is Color c ? Color.FromRgb(c.R, c.G, c.B) : Theme.DarkMode ? Color.FromRgb(30, 30, 34) : Color.FromRgb(246, 246, 248));
        Foreground = new SolidColorBrush(theme.TextColor);

        foreach (var k in Kinds) kindBox.Items.Add(k == Kind.Other ? "Any file" : k.ToString());
        foreach (var m in new[] { Mode.Convert, Mode.Tools, Mode.Actions }) modeBox.Items.Add(m.Title());
        kindBox.SelectedIndex = modeBox.SelectedIndex = 0;
        kindBox.SelectionChanged += (_, _) => Load();
        modeBox.SelectionChanged += (_, _) => Load();

        list.ItemsSource = rows;
        list.Background = Brushes.Transparent;
        list.Foreground = Foreground;
        list.BorderBrush = new SolidColorBrush(Theme.WithAlpha(theme.TextColor, 0.2));
        list.ItemTemplate = new DataTemplate { VisualTree = CheckTemplate() };
        list.AllowDrop = true;
        list.PreviewMouseLeftButtonDown += (_, e) =>
            dragging = (e.OriginalSource as FrameworkElement)?.DataContext as Row is Row r && e.OriginalSource is not System.Windows.Controls.Primitives.ToggleButton ? r : null;
        list.PreviewMouseMove += (_, e) =>
        {
            if (dragging != null && e.LeftButton == System.Windows.Input.MouseButtonState.Pressed)
                DragDrop.DoDragDrop(list, dragging, DragDropEffects.Move);
        };
        list.Drop += (_, e) =>
        {
            if (e.Data.GetData(typeof(Row)) is not Row moved || (e.OriginalSource as FrameworkElement)?.DataContext is not Row target || moved == target) return;
            rows.Move(rows.IndexOf(moved), rows.IndexOf(target));
            dragging = null;
            Save();
        };

        var top = new StackPanel { Orientation = Orientation.Horizontal };
        top.Children.Add(kindBox);
        top.Children.Add(modeBox);
        var reset = new Button { Content = "Reset this wheel", Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left };
        reset.Click += (_, _) => { var (k, m) = Selected(); Layout.Reset(k, m); Load(); };
        var left = new StackPanel();
        left.Children.Add(top);
        left.Children.Add(new TextBlock { Text = "Tick to show, drag to reorder.", Opacity = 0.7, Margin = new Thickness(0, 8, 0, 0) });
        left.Children.Add(list);
        left.Children.Add(reset);
        var body = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(20) };
        body.Children.Add(left);
        body.Children.Add(preview);
        Content = body;
        Load();
    }

    static FrameworkElementFactory CheckTemplate()
    {
        var box = new FrameworkElementFactory(typeof(CheckBox));
        box.SetBinding(CheckBox.IsCheckedProperty, new System.Windows.Data.Binding(nameof(Row.Shown)) { Mode = System.Windows.Data.BindingMode.TwoWay, UpdateSourceTrigger = System.Windows.Data.UpdateSourceTrigger.PropertyChanged });
        box.SetBinding(ContentProperty, new System.Windows.Data.Binding(nameof(Row.Title)));
        box.SetValue(MarginProperty, new Thickness(2, 3, 2, 3));
        box.SetBinding(ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(ListBox), 1) });
        box.AddHandler(System.Windows.Controls.Primitives.ToggleButton.ClickEvent, new RoutedEventHandler((s, _) => open?.Save()));
        return box;
    }

    (Kind, Mode) Selected() => (Kinds[Math.Max(kindBox.SelectedIndex, 0)], (Mode)Math.Max(modeBox.SelectedIndex, 0));

    void Load()
    {
        var (kind, mode) = Selected();
        var all = Catalog.AllTitles(kind, mode);
        var saved = Layout.Get(kind, mode) ?? new();
        rows.Clear();
        foreach (var s in saved.Where(s => all.Contains(s.Title))) rows.Add(new Row { Title = s.Title, Shown = !s.Hidden });
        foreach (var t in all.Where(t => !saved.Any(s => s.Title == t))) rows.Add(new Row { Title = t, Shown = true });
        Render();
    }

    void Save()
    {
        var (kind, mode) = Selected();
        Layout.Set(kind, mode, rows.Select(r => (r.Title, !r.Shown)));
        Render();
    }

    void Render()
    {
        var (kind, mode) = Selected();
        var ops = Layout.Apply(Catalog.AllTitles(kind, mode).Select(t => new Op(t, null)).ToList(), kind, mode);
        var wheel = new WheelWindow();
        preview.Source = wheel.Render(mode, new() { @"C:\Preview" }, null, Brushes.Transparent, ops: ops);
        wheel.Close();
    }
}

/// <summary>Watch folders: every new file that lands in one is converted to that folder's format, beside the original.</summary>
static class Watch
{
    const string Key = @"Software\Satsuma\Watch";
    static readonly List<FileSystemWatcher> watchers = new();
    static readonly HashSet<string> seen = new(StringComparer.OrdinalIgnoreCase);
    public static Action<string, Exception> Failed;

    /// <summary>Folder → lower-case target extension.</summary>
    public static Dictionary<string, string> All
    {
        get
        {
            var k = Registry.CurrentUser.OpenSubKey(Key);
            return k == null ? new() : k.GetValueNames().ToDictionary(n => n, n => k.GetValue(n) as string);
        }
    }

    public static void Add(string dir, string ext) { Registry.CurrentUser.CreateSubKey(Key).SetValue(dir, ext); Restart(); }
    public static void Remove(string dir) { Registry.CurrentUser.CreateSubKey(Key).DeleteValue(dir, false); Restart(); }

    /// <summary>Every target format, for the "convert to…" choice.</summary>
    public static List<string> Formats => Enum.GetValues<Kind>().SelectMany(Catalog.Targets).Distinct().ToList();

    public static void Restart()
    {
        foreach (var w in watchers) w.Dispose();
        watchers.Clear();
        foreach (var (dir, ext) in All)
        {
            if (!Directory.Exists(dir)) continue;
            var w = new FileSystemWatcher(dir) { IncludeSubdirectories = false, EnableRaisingEvents = true };
            w.Created += (_, e) => Arrived(e.FullPath, ext);
            w.Renamed += (_, e) => Arrived(e.FullPath, ext);  // browsers download to .crdownload/.part, then rename
            watchers.Add(w);
        }
    }

    static void Arrived(string path, string ext)
    {
        var kind = Catalog.KindOf(path);
        var name = Path.GetFileName(path);
        if (Catalog.NormExt(path) == ext || name.StartsWith('.') || name.StartsWith("~$") || !File.Exists(path)) return;
        if (!(kind == Kind.Font ? Fonts.Targets(path) : Catalog.Targets(kind)).Contains(ext)) return;
        lock (seen) if (!seen.Add(path)) return;
        var t = new Thread(() =>
        {
            try
            {
                WaitUntilWritten(path);
                Converter.Run(path, ext);
            }
            catch (Exception e) { Failed?.Invoke(path, e); }
            finally { lock (seen) seen.Remove(path); }
        }) { IsBackground = true };
        t.SetApartmentState(ApartmentState.STA);  // WPF imaging
        t.Start();
    }

    /// <summary>A copy or download is done once the size holds still and nobody else has the file open for writing.</summary>
    static void WaitUntilWritten(string path)
    {
        long last = -1;
        for (int i = 0; i < 600; i++)
        {
            Thread.Sleep(500);
            long size = new FileInfo(path).Length;
            if (size == last)
                try { using var _ = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read); return; } catch (IOException) { }
            last = size;
        }
    }
}
