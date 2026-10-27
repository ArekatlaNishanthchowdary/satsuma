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

namespace Satsuma;

/// <summary>PDF Organize: a grid of page thumbnails to reorder, turn and delete; Save writes "name organized.pdf".</summary>
class Organizer : Window
{
    readonly string path;
    readonly List<BitmapSource> thumbs;
    List<(int Index, int Turn)> pages;
    readonly Stack<List<(int, int)>> history = new();
    readonly Theme theme = Theme.Current;
    readonly WrapPanel grid = new() { Margin = new Thickness(12) };
    readonly TextBlock status = new() { VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold, Margin = new Thickness(18, 0, 0, 0) };
    Brush Text => new SolidColorBrush(theme.TextColor);

    public static void Open(string path) => new Organizer(path).Show();

    Organizer(string path)
    {
        this.path = path;
        thumbs = Pdfs.Render(path, 220);
        pages = Enumerable.Range(0, thumbs.Count).Select(i => (i, 0)).ToList();

        Title = $"Organize: {System.IO.Path.GetFileName(path)}";
        Width = 1000; Height = 720; MinWidth = 520; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var bg = theme.Solid is Color c ? Color.FromRgb(c.R, c.G, c.B) : Theme.DarkMode ? Color.FromRgb(30, 30, 34) : Color.FromRgb(246, 246, 248);
        Background = new SolidColorBrush(bg);
        Foreground = Text;

        var bar = new DockPanel { Height = 64 };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 18, 0), VerticalAlignment = VerticalAlignment.Center };
        buttons.Children.Add(Button("Reset", false, () => Change(Enumerable.Range(0, thumbs.Count).Select(i => (i, 0)).ToList())));
        buttons.Children.Add(Button("Save", true, Save));
        DockPanel.SetDock(buttons, Dock.Right);
        bar.Children.Add(buttons);
        bar.Children.Add(status);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(new ScrollViewer { Content = grid, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Close();
            if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) Save();
            if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control && history.Count > 0) { pages = history.Pop(); Build(); }
        };
        Build();
    }

    void Change(List<(int, int)> next)
    {
        history.Push(pages);
        pages = next;
        Build();
    }

    // ponytail: arrow buttons rather than drag-to-reorder; add DragDrop on the tiles if long documents make this tedious.
    void Build()
    {
        grid.Children.Clear();
        for (int pos = 0; pos < pages.Count; pos++)
        {
            int at = pos;
            var (index, turn) = pages[at];
            var image = new Image { Source = thumbs[index], Height = 200, Width = 200, Stretch = Stretch.Uniform, LayoutTransform = new RotateTransform(turn) };
            var row = new UniformGrid { Columns = 4, Margin = new Thickness(0, 8, 0, 0) };
            row.Children.Add(Small("", "Move earlier", at > 0, () => Move(at, -1)));
            row.Children.Add(Small("", "Turn 90°", true, () => Change(pages.Select((p, i) => i == at ? (p.Index, (p.Turn + 90) % 360) : p).ToList())));
            row.Children.Add(Small("", "Delete page", pages.Count > 1, () => Change(pages.Where((_, i) => i != at).ToList())));
            row.Children.Add(Small("", "Move later", at < pages.Count - 1, () => Move(at, 1)));
            var stack = new StackPanel();
            stack.Children.Add(new Border { Width = 210, Height = 210, Background = Brushes.White, Child = image, CornerRadius = new CornerRadius(6) });
            stack.Children.Add(new TextBlock { Text = index == at ? $"{at + 1}" : $"{at + 1}  (was {index + 1})", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0), Opacity = 0.8 });
            stack.Children.Add(row);
            grid.Children.Add(new Border
            {
                Child = stack, Padding = new Thickness(10), Margin = new Thickness(6), CornerRadius = new CornerRadius(12),
                Background = new SolidColorBrush(Theme.WithAlpha(theme.TextColor, 0.06)),
            });
        }
        var dropped = thumbs.Count - pages.Count;
        status.Text = $"{pages.Count} page{(pages.Count == 1 ? "" : "s")}" + (dropped > 0 ? $" · {dropped} removed" : "");
    }

    void Move(int at, int by)
    {
        var next = pages.ToList();
        (next[at], next[at + by]) = (next[at + by], next[at]);
        Change(next);
    }

    void Save()
    {
        try
        {
            var outPath = Pdfs.Organize(path, pages);
            Process.Start("explorer.exe", $"/select,\"{outPath}\"");
            Close();
        }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Couldn't save", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    Button Small(string glyph, string tip, bool enabled, Action click)
    {
        var b = new Button
        {
            Content = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), ToolTip = tip, Visibility = enabled ? Visibility.Visible : Visibility.Hidden,
            Height = 28, Margin = new Thickness(2, 0, 2, 0), Background = new SolidColorBrush(Theme.WithAlpha(theme.TextColor, 0.08)),
            Foreground = Text, BorderThickness = new Thickness(0),
        };
        b.Click += (_, _) => click();
        return b;
    }

    Button Button(string text, bool primary, Action click)
    {
        var b = new Button
        {
            Content = text, Height = 36, Width = 110, Margin = new Thickness(8, 0, 0, 0), FontWeight = FontWeights.SemiBold,
            Background = primary ? new SolidColorBrush(theme.Accent) : new SolidColorBrush(Theme.WithAlpha(theme.TextColor, 0.08)),
            Foreground = primary ? Brushes.White : Text, BorderThickness = new Thickness(0),
        };
        b.Click += (_, _) => click();
        return b;
    }
}
