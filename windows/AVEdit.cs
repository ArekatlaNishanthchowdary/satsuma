using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Satsuma;

record MediaInfo(double Duration, bool HasVideo, bool HasAudio, int Width, int Height);

enum ChannelMode { Stereo, Mono, Left, Right, Swap }
enum WaveStyle { Wave, Spectrum, Bars }

/// <summary>The audio and video editors' work, all done by ffmpeg. Times are seconds; boxes are video pixels.</summary>
static class AVEdit
{
    static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);
    static string Hex(Color c) => $"0x{c.R:X2}{c.G:X2}{c.B:X2}";

    /// <summary>Reads ffmpeg's own banner, so no ffprobe is needed (the Mac build doesn't ship one).</summary>
    public static MediaInfo Probe(string src)
    {
        var ff = Shell.FFmpeg ?? throw new Fail("This needs ffmpeg. Install it with: winget install ffmpeg");
        var psi = new ProcessStartInfo(ff) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var a in new[] { "-hide_banner", "-nostdin", "-i", src }) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi);
        var err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        return Parse(err);
    }

    public static MediaInfo Parse(string banner)
    {
        var d = Regex.Match(banner, @"Duration: (\d+):(\d+):([\d.]+)");
        double dur = d.Success ? int.Parse(d.Groups[1].Value) * 3600 + int.Parse(d.Groups[2].Value) * 60 + double.Parse(d.Groups[3].Value, CultureInfo.InvariantCulture) : 0;
        // Cover art shows up as a one-frame "Video:" stream; it isn't a video.
        var v = Regex.Match(banner, @"Video: (?!.*attached pic).*?(\d{2,5})x(\d{2,5})");
        return new(dur, v.Success, banner.Contains("Audio:"), v.Success ? int.Parse(v.Groups[1].Value) : 0, v.Success ? int.Parse(v.Groups[2].Value) : 0);
    }

    static BitmapSource RunPicture(params string[] args)
    {
        var png = Path.Combine(Paths.Temp(), "pic.png");
        Shell.FF(args.Append("-frames:v").Append("1").Append(png).ToArray());
        return Img.Load(png);
    }

    static BitmapSource Wave(string src, Color color, int height) =>
        RunPicture("-i", src, "-filter_complex", $"aformat=channel_layouts=mono,showwavespic=s=1600x{height}:scale=sqrt:colors={Hex(color)}");

    /// <summary>What the editor shows, 1600 px across the whole duration: the waveform, under a strip of frames for video.</summary>
    public static BitmapSource Picture(string src, MediaInfo m, Color color)
    {
        if (!m.HasVideo) return Wave(src, color, 520);
        var strip = RunPicture("-i", src, "-vf", $"fps={N(8 / Math.Max(m.Duration, 0.1))},scale=200:-2,tile=8x1");
        if (!m.HasAudio) return strip;
        var wave = Wave(src, color, 300);
        return ImageEdit.Render(1600, strip.PixelHeight + 12 + wave.PixelHeight, dc =>
        {
            dc.DrawImage(strip, new Rect(0, 0, 1600, strip.PixelHeight));
            dc.DrawImage(wave, new Rect(0, strip.PixelHeight + 12, 1600, wave.PixelHeight));
        });
    }

    /// <summary>One frame at native size, for video Crop and Redact.</summary>
    public static BitmapSource Frame(string src, MediaInfo m) => RunPicture("-ss", N(Math.Min(1, m.Duration / 2)), "-i", src);

    static string Out(string src, string suffix, string ext = null) => Paths.Output(src, ext ?? Catalog.NormExt(src), suffix);

    static string Run(string src, string outPath, params string[] args)
    {
        Shell.FF(new[] { "-i", src }.Concat(args).Append(outPath).ToArray());
        return outPath;
    }

    // ponytail: re-encodes for frame-accurate cuts; a stream-copy fast path would land on keyframes instead.
    public static string Trim(string src, double from, double to) => Run2(src, Out(src, " trimmed"), new[] { "-ss", N(from), "-to", N(to) });

    /// <summary>Input options (seeking) go before -i.</summary>
    static string Run2(string src, string outPath, string[] inputOpts, params string[] args)
    {
        Shell.FF(inputOpts.Concat(new[] { "-i", src }).Concat(args).Append(outPath).ToArray());
        return outPath;
    }

    public static string Enable(IEnumerable<(double From, double To)> ranges) =>
        string.Join("+", ranges.Select(r => $"between(t\\,{N(r.From)}\\,{N(r.To)})"));

    /// <summary>Silences the ranges and lays a 1 kHz tone over them; video, if any, is copied untouched.</summary>
    public static string Bleep(string src, List<(double From, double To)> ranges)
    {
        if (ranges.Count == 0) throw new Fail("Drag over the parts to bleep first.");
        var on = Enable(ranges);
        return Run(src, Out(src, " bleeped"), "-filter_complex",
            $"[0:a]volume=0:enable='{on}'[muted];sine=frequency=1000:sample_rate=48000,volume=0.3,volume=0:enable='not({on})'[tone];[muted][tone]amix=inputs=2:duration=first:normalize=0[out]",
            "-map", "0:v?", "-map", "[out]", "-c:v", "copy");
    }

    public static string ChannelFilter(ChannelMode mode, double left, double right) =>
        "aformat=channel_layouts=stereo," + mode switch
        {
            ChannelMode.Mono => $"pan=mono|c0={N(left / 2)}*c0+{N(right / 2)}*c1",
            ChannelMode.Left => $"pan=mono|c0={N(left)}*c0",
            ChannelMode.Right => $"pan=mono|c0={N(right)}*c1",
            ChannelMode.Swap => $"pan=stereo|c0={N(left)}*c1|c1={N(right)}*c0",
            _ => $"pan=stereo|c0={N(left)}*c0|c1={N(right)}*c1",
        };

    /// <summary>Gains are 0…2 (1 = unchanged).</summary>
    public static string Channels(string src, ChannelMode mode, double left, double right) =>
        Run(src, Out(src, " " + mode.ToString().ToLowerInvariant()), "-af", ChannelFilter(mode, left, right), "-c:v", "copy");

    public static string Visualize(string src, WaveStyle style, Color color)
    {
        var draw = style switch
        {
            WaveStyle.Spectrum => "showspectrum=s=1280x720:mode=combined:slide=scroll:color=intensity",
            WaveStyle.Bars => $"showfreqs=s=1280x720:mode=bar:ascale=sqrt:colors={Hex(color)}",
            _ => $"showwaves=s=1280x720:mode=cline:rate=30:colors={Hex(color)}",
        };
        return Run(src, Out(src, " visualized", "mp4"), "-filter_complex", $"[0:a]{draw},format=yuv420p[v]",
            "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-c:a", "aac", "-b:a", "192k", "-shortest");
    }

    /// <summary>Cuts at the given times (or into equal parts) into a folder of numbered files.</summary>
    public static string Split(string src, MediaInfo m, List<double> cuts, int parts)
    {
        if (cuts.Count == 0) cuts = Enumerable.Range(1, Math.Max(2, parts) - 1).Select(i => m.Duration * i / Math.Max(2, parts)).ToList();
        var times = string.Join(",", cuts.Where(t => t > 0.05 && t < m.Duration - 0.05).OrderBy(t => t).Select(N));
        var dir = Paths.Folder(src, " parts");
        var pattern = Path.Combine(dir, Path.GetFileNameWithoutExtension(src).Replace("%", "%%") + " %d." + Catalog.NormExt(src));
        var args = new List<string> { "-f", "segment", "-segment_times", times, "-segment_start_number", "1", "-reset_timestamps", "1" };
        if (m.HasVideo) args.AddRange(new[] { "-force_key_frames", times });  // so each part starts exactly at its cut
        Run(src, pattern, args.ToArray());
        return dir;
    }

    /// <summary>atempo only takes 0.5–2, so bigger changes chain several.</summary>
    public static string Atempo(double f)
    {
        var parts = new List<string>();
        for (; f > 2; f /= 2) parts.Add("atempo=2");
        for (; f < 0.5; f /= 0.5) parts.Add("atempo=0.5");
        parts.Add($"atempo={N(f)}");
        return string.Join(",", parts);
    }

    public static string Speed(string src, MediaInfo m, double f)
    {
        var args = new List<string>();
        if (m.HasVideo) args.AddRange(new[] { "-filter:v", $"setpts=PTS/{N(f)}" });
        if (m.HasAudio) args.AddRange(new[] { "-filter:a", Atempo(f) });
        return Run(src, Out(src, $" {N(f)}x"), args.ToArray());
    }

    static int Even(double v) => Math.Max(2, (int)Math.Round(v / 2) * 2);

    public static string CropVideo(string src, Rect r) =>
        Run(src, Out(src, " cropped"), "-vf", $"crop={Even(r.Width)}:{Even(r.Height)}:{Even(r.X)}:{Even(r.Y)}", "-c:a", "copy");

    public static string RedactFilter(IEnumerable<Rect> boxes, RedactStyle style)
    {
        var steps = new List<string>();
        var cur = "0:v";
        int i = 0;
        foreach (var b in boxes)
        {
            int x = Even(b.X), y = Even(b.Y), w = Even(b.Width), h = Even(b.Height);
            var next = $"v{i}";
            if (style == RedactStyle.Black) steps.Add($"[{cur}]drawbox=x={x}:y={y}:w={w}:h={h}:color=black:t=fill[{next}]");
            else
            {
                var hide = style == RedactStyle.Blur
                    ? $"boxblur=luma_radius={Math.Max(2, Math.Min(w, h) / 5)}:luma_power=3"
                    : $"scale={Math.Max(1, w / 14)}:{Math.Max(1, h / 14)},scale={w}:{h}:flags=neighbor";
                steps.Add($"[{cur}]split[a{i}][b{i}];[b{i}]crop={w}:{h}:{x}:{y},{hide}[c{i}];[a{i}][c{i}]overlay={x}:{y}[{next}]");
            }
            cur = next;
            i++;
        }
        return string.Join(";", steps) + (steps.Count == 0 ? "" : $";[{cur}]format=yuv420p[out]");
    }

    public static string RedactVideo(string src, List<Rect> boxes, RedactStyle style)
    {
        if (boxes.Count == 0) throw new Fail("Drag over what to hide first.");
        return Run(src, Out(src, " redacted"), "-filter_complex", RedactFilter(boxes, style), "-map", "[out]", "-map", "0:a?", "-c:a", "copy");
    }

    /// <summary>Bitrate maths: the whole file's bits over its duration, minus the audio's share, with 5% headroom.</summary>
    public static string CompressTo(string src, long target)
    {
        var m = Probe(src);
        if (m.Duration <= 0) throw new Fail($"Couldn't read the length of {Path.GetFileName(src)}");
        double total = target * 8 * 0.95 / m.Duration;
        if (!m.HasVideo)
        {
            int ab = (int)Math.Clamp(total, 24_000, 320_000);
            return Run(src, Out(src, " compressed", "m4a"), "-vn", "-c:a", "aac", "-b:a", $"{ab}");
        }
        int audio = m.HasAudio ? (int)Math.Clamp(total * 0.1, 48_000, 128_000) : 0;
        int video = (int)(total - audio);
        if (video < 50_000) throw new Fail($"{Thumbs.Bytes(target)} is too small for {m.Duration:0} seconds of video.");
        return Run(src, Out(src, " compressed", "mp4"), "-c:v", "libx264", "-b:v", $"{video}", "-maxrate", $"{video}", "-bufsize", $"{video * 2}",
            "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", $"{Math.Max(audio, 48_000)}");
    }

    public static string Clock(double t) => $"{(int)(t / 60)}:{t % 60:00.0}";
}
