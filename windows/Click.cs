using System;
using System.IO;
using System.Media;
using Microsoft.Win32;

namespace Satsuma;

/// <summary>The little mechanical "tick" when the pointer moves onto a slice. Synthesized, so there is no audio asset.</summary>
static class Click
{
    const string Key = @"Software\Satsuma";

    public static bool Enabled
    {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("ClickSound") is not int v || v != 0;
        set => Registry.CurrentUser.CreateSubKey(Key).SetValue("ClickSound", value ? 1 : 0);
    }

    static readonly SoundPlayer Player = new(new MemoryStream(Wav()));

    public static void Play()
    {
        if (!Enabled) return;
        try { Player.Play(); } catch { }  // no audio device: stay silent
    }

    /// <summary>
    /// A mouse-switch click: a sharp noise transient with a damped high "ping" and a low body,
    /// then a quieter release click 9 ms later. 30 ms, 16-bit mono.
    /// </summary>
    public static byte[] Wav()
    {
        const int rate = 44100;
        int n = rate * 30 / 1000;
        uint seed = 22222;
        double Noise() { seed = seed * 1664525 + 1013904223; return (seed >> 8) / (double)(1 << 24) * 2 - 1; }
        var ms = new MemoryStream();
        using (var w = new BinaryWriter(ms, System.Text.Encoding.ASCII, true))
        {
            w.Write("RIFF"u8); w.Write(36 + n * 2); w.Write("WAVE"u8);
            w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write("data"u8); w.Write(n * 2);
            for (int i = 0; i < n; i++)
            {
                double t = (double)i / rate, t2 = t - 0.009;
                double s = Noise() * Math.Exp(-t / 0.0012) * 0.6
                         + Math.Sin(2 * Math.PI * 3200 * t) * Math.Exp(-t / 0.002) * 0.35
                         + Math.Sin(2 * Math.PI * 900 * t) * Math.Exp(-t / 0.004) * 0.25;
                if (t2 >= 0) s += Noise() * Math.Exp(-t2 / 0.0008) * 0.3 + Math.Sin(2 * Math.PI * 4100 * t2) * Math.Exp(-t2 / 0.0015) * 0.2;
                w.Write((short)Math.Clamp(s * 0.5 * short.MaxValue, short.MinValue, short.MaxValue));
            }
        }
        return ms.ToArray();
    }
}
