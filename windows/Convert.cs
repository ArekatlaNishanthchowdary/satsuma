using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;
using WinImg = Windows.Graphics.Imaging;

namespace Satsuma;

class Fail : Exception { public Fail(string message) : base(message) { } }

static class Shell
{
    /// <summary>Looks on PATH as the registry has it now, so a fresh winget install is seen without a restart.</summary>
    public static string Find(string exe, params string[] extraDirs)
    {
        var path = string.Join(";", Environment.GetEnvironmentVariable("PATH"),
            Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User),
            Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine));
        return path.Split(';', StringSplitOptions.RemoveEmptyEntries).Concat(extraDirs)
            .Select(d => Path.Combine(d.Trim(), exe)).FirstOrDefault(File.Exists);
    }

    static readonly string LocalApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    public static string FFmpeg => Find("ffmpeg.exe", Path.Combine(LocalApp, @"Microsoft\WinGet\Links"));
    public static string Pandoc => Find("pandoc.exe", Path.Combine(LocalApp, "Pandoc"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Pandoc"));
    public static string Soffice => Find("soffice.exe", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"LibreOffice\program"));
    public static string Tar => Path.Combine(Environment.SystemDirectory, "tar.exe");  // bsdtar: zip, tar, gz, rar, 7z

    /// <summary>LibreOffice headless into a temp folder; returns the converted file there.</summary>
    public static string Office(string src, string ext, string infilter = null)
    {
        var so = Soffice ?? throw new Fail("This needs LibreOffice: winget install TheDocumentFoundation.LibreOffice");
        var dir = Paths.Temp();
        var args = new List<string> { "--headless", "--norestore", $"-env:UserInstallation=file:///{Path.Combine(dir, "profile").Replace('\\', '/')}" };
        if (infilter != null) args.Add($"--infilter={infilter}");
        args.AddRange(new[] { "--convert-to", ext, "--outdir", dir, Path.GetFullPath(src) });
        Run(so, args);
        return Directory.GetFiles(dir, "*." + ext).FirstOrDefault() ?? throw new Fail($"LibreOffice couldn't convert {Path.GetFileName(src)}");
    }

    public static byte[] Run(string exe, IEnumerable<string> args, string cwd = null)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (cwd != null) psi.WorkingDirectory = cwd;
        using var p = Process.Start(psi);
        p.StandardInput.Close();
        var err = p.StandardError.ReadToEndAsync();  // drain both pipes so a chatty tool can't stall
        using var ms = new MemoryStream();
        p.StandardOutput.BaseStream.CopyTo(ms);
        p.WaitForExit();
        if (p.ExitCode != 0)
        {
            var msg = err.Result.Trim();
            throw new Fail($"{Path.GetFileNameWithoutExtension(exe)} failed: {(msg.Length > 400 ? msg[^400..] : msg)}");
        }
        return ms.ToArray();
    }

    public static void FF(params string[] args)
    {
        var ff = FFmpeg ?? throw new Fail("This needs ffmpeg. Install it with: winget install ffmpeg");
        Run(ff, new[] { "-hide_banner", "-loglevel", "error", "-nostdin", "-y" }.Concat(args));
    }
}

static class Paths
{
    /// <summary>A free path beside <paramref name="src"/>: "name{suffix}.ext", then "name{suffix} 2.ext", …</summary>
    public static string Output(string src, string ext, string suffix = "")
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(src));
        var name = Path.GetFileName(src.TrimEnd('\\', '/'));
        var stem = Directory.Exists(src) ? name : Path.GetFileNameWithoutExtension(name);
        if (stem.EndsWith(".tar", StringComparison.OrdinalIgnoreCase)) stem = stem[..^4];
        stem += suffix;
        string Make(string s) => Path.Combine(dir, ext.Length == 0 ? s : $"{s}.{ext}");
        var path = Make(stem);
        for (int n = 2; File.Exists(path) || Directory.Exists(path); n++) path = Make($"{stem} {n}");
        return path;
    }

    public static string Folder(string src, string suffix = "") => Directory.CreateDirectory(Output(src, "", suffix)).FullName;

    public static string Temp() => Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "satsuma-" + Guid.NewGuid().ToString("N"))).FullName;
}

static class Converter
{
    public static string Run(string src, string ext) => Catalog.KindOf(src) switch
    {
        Kind.Image => Img.Convert(src, ext),
        Kind.Audio or Kind.Video => AV.Convert(src, ext),
        Kind.Pdf => Pdfs.Convert(src, ext),
        Kind.Document => Docs.Convert(src, ext),
        Kind.Sheet => Sheets.Convert(src, ext),
        Kind.Subtitle => Subs.Convert(src, ext),
        Kind.Archive => Archive.Convert(src, ext),
        Kind.Slides => Slides.Convert(src, ext),
        _ => throw new Fail($"Satsuma doesn't know how to convert {Path.GetFileName(src)}"),
    };
}

/// <summary>WPF imaging. Callers run on STA threads (RenderTargetBitmap needs one).</summary>
static class Img
{
    static readonly HashSet<string> Writable = new() { "jpg", "png", "bmp", "gif", "tiff" };

    public static BitmapSource Load(string path)
    {
        try
        {
            var frame = BitmapDecoder.Create(new Uri(Path.GetFullPath(path)), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            BitmapSource b = frame;
            // WPF ignores EXIF orientation, so phone photos would come out sideways.
            object o = null;
            try { o = (frame.Metadata as BitmapMetadata)?.GetQuery("System.Photo.Orientation"); } catch { }
            var angle = (o as ushort?) switch { 3 => 180, 6 => 90, 8 => 270, _ => 0 };
            if (angle != 0) b = new TransformedBitmap(b, new RotateTransform(angle));
            b.Freeze();
            return b;
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or ArgumentException && Shell.FFmpeg != null)
        {
            // HEIC/WebP/AVIF without Windows' codec extensions: let ffmpeg decode.
            var png = Path.Combine(Paths.Temp(), "frame.png");
            Shell.FF("-i", path, png);
            return Load(png);
        }
    }

    public static void Save(BitmapSource img, string path, int quality = 90)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (ext is "webp" or "avif")
        {
            var png = Path.Combine(Paths.Temp(), "in.png");
            Save(img, png);
            Shell.FF("-i", png, path);
            return;
        }
        if (ext == "pdf") { Pdfs.FromImages(new[] { img }, path); return; }
        if (ext == "docx") { Docs.WriteImage(img, path); return; }
        if (ext is "heic" or "heif") { SaveHeic(img, path, quality); return; }
        BitmapEncoder enc = ext switch
        {
            "jpg" or "jpeg" => new JpegBitmapEncoder { QualityLevel = quality },
            "png" => new PngBitmapEncoder(),
            "bmp" => new BmpBitmapEncoder(),
            "gif" => new GifBitmapEncoder(),
            "tiff" or "tif" => new TiffBitmapEncoder(),
            _ => throw new Fail($"Can't write {ext.ToUpperInvariant()} images"),
        };
        if (ext is "jpg" or "jpeg" or "bmp") img = Flatten(img);
        enc.Frames.Add(BitmapFrame.Create(img));
        using var fs = File.Create(path);
        enc.Save(fs);
    }

    /// <summary>True when Windows has the HEIF encoder (HEIF + HEVC extensions from the Store).</summary>
    public static readonly Lazy<bool> CanHeic = new(() =>
    {
        try
        {
            var path = Path.Combine(Paths.Temp(), "probe.heic");
            SaveHeic(BitmapSource.Create(2, 2, 96, 96, PixelFormats.Bgra32, null, new byte[16], 8), path, 90);
            return new FileInfo(path).Length > 0;
        }
        catch { return false; }
    });

    static void SaveHeic(BitmapSource img, string path, int quality)
    {
        var bgra = new FormatConvertedBitmap(img, PixelFormats.Bgra32, null, 0);
        var pixels = new byte[bgra.PixelWidth * bgra.PixelHeight * 4];
        bgra.CopyPixels(pixels, bgra.PixelWidth * 4, 0);
        using var sb = WinImg.SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), WinImg.BitmapPixelFormat.Bgra8, bgra.PixelWidth, bgra.PixelHeight, WinImg.BitmapAlphaMode.Straight);
        using var ras = new InMemoryRandomAccessStream();
        var opts = new[] { new KeyValuePair<string, WinImg.BitmapTypedValue>("ImageQuality", new WinImg.BitmapTypedValue(quality / 100f, Windows.Foundation.PropertyType.Single)) };
        var enc = WinImg.BitmapEncoder.CreateAsync(WinImg.BitmapEncoder.HeifEncoderId, ras, opts).AsTask().GetAwaiter().GetResult();
        enc.SetSoftwareBitmap(sb);
        enc.FlushAsync().AsTask().GetAwaiter().GetResult();
        ras.Seek(0);
        using var fs = File.Create(path);
        ras.AsStreamForRead().CopyTo(fs);
    }

    /// <summary>Transparent pixels onto white, so JPEG doesn't turn them black.</summary>
    static BitmapSource Flatten(BitmapSource img)
    {
        var rect = new Rect(0, 0, img.PixelWidth, img.PixelHeight);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(Brushes.White, null, rect);
            dc.DrawImage(img, rect);
        }
        var rtb = new RenderTargetBitmap(img.PixelWidth, img.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(dv);
        return new FormatConvertedBitmap(rtb, PixelFormats.Bgr24, null, 0);
    }

    public static string Convert(string src, string ext)
    {
        var outPath = Paths.Output(src, ext);
        Save(Load(src), outPath);
        return outPath;
    }

    static string SameFormat(string src)
    {
        var e = Catalog.NormExt(src);
        return Writable.Contains(e) || (Shell.FFmpeg != null && e is "webp" or "avif") ? e : "png";
    }

    public static string Transform(string src, string suffix, Func<BitmapSource, BitmapSource> f)
    {
        var outPath = Paths.Output(src, SameFormat(src), suffix);
        Save(f(Load(src)), outPath, 92);
        return outPath;
    }

    public static BitmapSource Scale(BitmapSource b, double x, double y) => new TransformedBitmap(b, new ScaleTransform(x, y));
    public static BitmapSource Rotate(BitmapSource b, double degrees) => new TransformedBitmap(b, new RotateTransform(degrees));
    public static BitmapSource Gray(BitmapSource b) => new FormatConvertedBitmap(b, PixelFormats.Gray8, null, 0);

    // ponytail: fixed JPEG quality; add a target-size search if people want "under 1 MB".
    public static string Compress(string src)
    {
        var outPath = Paths.Output(src, "jpg", " compressed");
        Save(Load(src), outPath, 60);
        return outPath;
    }
}

/// <summary>ffmpeg when installed, otherwise Windows' own Media Foundation encoders.</summary>
static class AV
{
    static readonly HashSet<string> AudioExts = new() { "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma" };

    public static string Convert(string src, string ext)
    {
        var outPath = Paths.Output(src, ext);
        bool video = Catalog.KindOf(src) == Kind.Video;
        if (Shell.FFmpeg != null)
        {
            var args = new List<string> { "-i", src };
            if (ext == "gif") args.AddRange(new[] { "-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos", "-loop", "0" });
            if (ext == "mp4") args.AddRange(new[] { "-pix_fmt", "yuv420p" });
            if (video && AudioExts.Contains(ext)) args.Add("-vn");
            args.Add(outPath);
            Shell.FF(args.ToArray());
            return outPath;
        }
        return Transcode(src, outPath, Profile(ext));
    }

    public static MediaEncodingProfile Profile(string ext) => ext switch
    {
        "mp3" => MediaEncodingProfile.CreateMp3(AudioEncodingQuality.High),
        "m4a" => MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High),
        "wav" => MediaEncodingProfile.CreateWav(AudioEncodingQuality.High),
        "wma" => MediaEncodingProfile.CreateWma(AudioEncodingQuality.High),
        "flac" => MediaEncodingProfile.CreateFlac(AudioEncodingQuality.High),
        "mp4" => MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Auto),
        "wmv" => MediaEncodingProfile.CreateWmv(VideoEncodingQuality.Auto),
        _ => throw new Fail($"Converting to {ext.ToUpperInvariant()} needs ffmpeg: winget install ffmpeg"),
    };

    public static string Transcode(string src, string outPath, MediaEncodingProfile profile)
    {
        var input = StorageFile.GetFileFromPathAsync(Path.GetFullPath(src)).AsTask().GetAwaiter().GetResult();
        var folder = StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(Path.GetFullPath(outPath))).AsTask().GetAwaiter().GetResult();
        var output = folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting).AsTask().GetAwaiter().GetResult();
        var prep = new MediaTranscoder().PrepareFileTranscodeAsync(input, output, profile).AsTask().GetAwaiter().GetResult();
        if (!prep.CanTranscode)
        {
            output.DeleteAsync().AsTask().GetAwaiter().GetResult();
            throw new Fail($"Windows can't convert {Path.GetFileName(src)} ({prep.FailureReason}). Installing ffmpeg may help.");
        }
        prep.TranscodeAsync().AsTask().GetAwaiter().GetResult();
        return outPath;
    }

    public static string FF(string src, string ext, string suffix, params string[] args)
    {
        var outPath = Paths.Output(src, ext ?? Catalog.NormExt(src), suffix);
        Shell.FF(new[] { "-i", src }.Concat(args).Append(outPath).ToArray());
        return outPath;
    }

    public static string Snapshot(string src)
    {
        var outPath = Paths.Output(src, "png", " snapshot");
        try
        {
            var file = StorageFile.GetFileFromPathAsync(Path.GetFullPath(src)).AsTask().GetAwaiter().GetResult();
            var clip = MediaClip.CreateFromFileAsync(file).AsTask().GetAwaiter().GetResult();
            var comp = new MediaComposition();
            comp.Clips.Add(clip);
            var thumb = comp.GetThumbnailAsync(clip.OriginalDuration / 2, 0, 0, VideoFramePrecision.NearestFrame).AsTask().GetAwaiter().GetResult();
            using var s = thumb.AsStreamForRead();
            Img.Save(BitmapDecoder.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0], outPath);
        }
        catch when (Shell.FFmpeg != null)
        {
            Shell.FF("-i", src, "-frames:v", "1", outPath);
        }
        return outPath;
    }

    public static string CompressVideo(string src)
    {
        if (Shell.FFmpeg != null)
            return FF(src, "mp4", " compressed", "-c:v", "libx264", "-crf", "28", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k");
        return Transcode(src, Paths.Output(src, "mp4", " compressed"), MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD720p));
    }

    public static string ExtractAudio(string src)
    {
        if (Shell.FFmpeg != null) return FF(src, "m4a", "", "-vn", "-c:a", "aac", "-b:a", "192k");
        return Transcode(src, Paths.Output(src, "m4a"), MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High));
    }

    public static string CompressAudio(string src)
    {
        if (Shell.FFmpeg != null) return FF(src, "m4a", " compressed", "-vn", "-c:a", "aac", "-b:a", "96k");
        return Transcode(src, Paths.Output(src, "m4a", " compressed"), MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Low));
    }

    public static string Mono(string src)
    {
        if (Shell.FFmpeg != null) return FF(src, null, " mono", "-ac", "1");
        var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
        profile.Audio.ChannelCount = 1;
        return Transcode(src, Paths.Output(src, "m4a", " mono"), profile);
    }

    // ponytail: stream copy, so the files must share codecs; re-encode if mixed sources become common.
    public static string Join(List<string> files)
    {
        var list = Path.Combine(Paths.Temp(), "list.txt");
        File.WriteAllLines(list, files.Select(f => $"file '{Path.GetFullPath(f).Replace("'", "'\\''")}'"));
        var outPath = Paths.Output(files[0], Catalog.NormExt(files[0]), " joined");
        Shell.FF("-f", "concat", "-safe", "0", "-i", list, "-c", "copy", outPath);
        return outPath;
    }
}
