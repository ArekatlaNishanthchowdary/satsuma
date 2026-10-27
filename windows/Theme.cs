using System;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Satsuma;

/// <summary>Solid == null means a glass theme. Text == null follows light/dark mode.</summary>
record Theme(string Name, Color Accent, Color? Tint = null, bool Clear = false, Color? Solid = null, Color? Text = null)
{
    static Color Rgb(byte r, byte g, byte b, double a = 1) => Color.FromArgb((byte)(a * 255), r, g, b);

    public static readonly Theme[] All =
    {
        new("Tangerine", Rgb(255, 140, 26), Rgb(255, 140, 26, 0.20)),
        new("Clear Glass", Rgb(10, 132, 255), Clear: true),
        new("Lime", Rgb(132, 204, 22), Rgb(132, 204, 22, 0.20)),
        new("Blueberry", Rgb(59, 110, 246), Rgb(59, 110, 246, 0.20)),
        new("Grape", Rgb(147, 82, 230), Rgb(147, 82, 230, 0.20)),
        new("Strawberry", Rgb(236, 64, 100), Rgb(236, 64, 100, 0.20)),
        new("Mint", Rgb(20, 184, 166), Rgb(20, 184, 166, 0.20)),
        new("Graphite", Rgb(142, 142, 147), Rgb(0, 0, 0, 0.22)),
        new("Midnight", Rgb(255, 140, 26), Solid: Rgb(20, 20, 22, 0.94), Text: Colors.White),
        new("Paper", Rgb(234, 88, 12), Solid: Rgb(250, 248, 244, 0.97), Text: Rgb(28, 25, 23)),
        new("Neon", Rgb(255, 0, 170), Solid: Rgb(8, 6, 20, 0.95), Text: Rgb(0, 240, 255)),
        new("Sunset", Rgb(251, 113, 133), Solid: Rgb(67, 20, 7, 0.94), Text: Rgb(254, 215, 170)),
        // Community palettes (MIT), the same four Filee ships as theme examples.
        new("Catppuccin", Rgb(203, 166, 247), Solid: Rgb(30, 30, 46, 0.96), Text: Rgb(205, 214, 244)),
        new("Dracula", Rgb(189, 147, 249), Solid: Rgb(40, 42, 54, 0.96), Text: Rgb(248, 248, 242)),
        new("Nord", Rgb(136, 192, 208), Solid: Rgb(46, 52, 64, 0.96), Text: Rgb(236, 239, 244)),
        new("Monokai", Rgb(166, 226, 46), Solid: Rgb(39, 40, 34, 0.96), Text: Rgb(248, 248, 242)),
    };

    const string Key = @"Software\Satsuma";

    /// <summary>The chosen theme, with the user's own accent colour if they picked one.</summary>
    public static Theme Current
    {
        get
        {
            var t = All.FirstOrDefault(t => t.Name == Registry.CurrentUser.OpenSubKey(Key)?.GetValue("Theme") as string) ?? All[0];
            return CustomAccent is Color c ? t with { Accent = c, Tint = t.Tint == null ? null : WithAlpha(c, 0.20) } : t;
        }
        set => Registry.CurrentUser.CreateSubKey(Key).SetValue("Theme", value.Name);
    }

    public static Color? CustomAccent
    {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("Accent") is int v ? Color.FromRgb((byte)(v >> 16), (byte)(v >> 8), (byte)v) : null;
        set { var k = Registry.CurrentUser.CreateSubKey(Key); if (value is Color c) k.SetValue("Accent", c.R << 16 | c.G << 8 | c.B); else k.DeleteValue("Accent", false); }
    }

    /// <summary>How see-through the whole wheel is, 0.5 to 1.</summary>
    public static double Opacity
    {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("Opacity") is int v ? Math.Clamp(v / 100.0, 0.5, 1) : 1;
        set => Registry.CurrentUser.CreateSubKey(Key).SetValue("Opacity", (int)Math.Round(value * 100));
    }

    public static bool DarkMode =>
        Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue("AppsUseLightTheme") is int v && v == 0;

    public bool IsGlass => Solid == null;
    public Color TextColor => Text ?? (DarkMode ? Colors.White : Rgb(24, 24, 27));

    /// <summary>The frosted layer. Without real blur, glass needs enough opacity to keep labels readable.</summary>
    public Brush Base => new SolidColorBrush(Solid ?? (DarkMode
        ? Rgb(30, 30, 34, Clear ? 0.38 : 0.62)
        : Rgb(250, 250, 252, Clear ? 0.40 : 0.70)));

    public Brush TintBrush => Tint is Color c ? new SolidColorBrush(c) : null;

    /// <summary>Light catching the top edge, the signature of the glass look.</summary>
    public Brush Highlight => IsGlass
        ? new LinearGradientBrush(new GradientStopCollection
            {
                new GradientStop(Color.FromArgb(DarkMode ? (byte)95 : (byte)150, 255, 255, 255), 0),
                new GradientStop(Color.FromArgb(0, 255, 255, 255), 0.55),
            }, new Point(0.5, 0), new Point(0.5, 1))
        : null;

    public Pen Rim => IsGlass ? new Pen(new SolidColorBrush(Color.FromArgb(DarkMode ? (byte)70 : (byte)170, 255, 255, 255)), 1.2) : null;

    public static Color WithAlpha(Color c, double a) => Color.FromArgb((byte)(a * 255), c.R, c.G, c.B);
}
