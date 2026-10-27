using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace Satsuma;

enum Mode { Convert, Tools, Actions }

/// <summary>One slice of the wheel. <c>OnUiThread</c> ops (actions) touch the clipboard or show dialogs.</summary>
record Op(string Title, Func<List<string>, List<string>> Run, bool OnUiThread = false);

enum Kind { Image, Audio, Video, Pdf, Document, Sheet, Slides, Subtitle, Archive, Other }

static class Catalog
{
    public static string Title(this Mode m) => m.ToString();

    /// <summary>An op that runs once per file.</summary>
    static Op Each(string title, Func<string, string> f) => new(title, files => files.Select(f).ToList());

    public static string NormExt(string path)
    {
        var name = Path.GetFileName(path).ToLowerInvariant();
        if (name.EndsWith(".tar.gz") || name.EndsWith(".tgz")) return "tar.gz";
        var e = Path.GetExtension(name).TrimStart('.');
        return e switch { "jpeg" => "jpg", "tif" => "tiff", "htm" => "html", "aif" => "aiff", "markdown" => "md", "heif" => "heic", _ => e };
    }

    public static Kind KindOf(string path)
    {
        if (Directory.Exists(path)) return Kind.Other;
        return NormExt(path) switch
        {
            "jpg" or "png" or "heic" or "tiff" or "bmp" or "gif" or "webp" or "avif" or "ico" => Kind.Image,
            "mp3" or "m4a" or "wav" or "flac" or "ogg" or "opus" or "aiff" or "wma" or "aac" => Kind.Audio,
            "mp4" or "mov" or "mkv" or "webm" or "avi" or "wmv" or "m4v" => Kind.Video,
            "pdf" => Kind.Pdf,
            "docx" or "rtf" or "txt" or "md" or "html" or "odt" => Kind.Document,
            "epub" => Shell.Pandoc == null ? Kind.Other : Kind.Document,
            "csv" or "tsv" or "xlsx" or "ods" or "xls" => Kind.Sheet,
            "ppt" or "pptx" or "odp" => Kind.Slides,
            "srt" or "vtt" => Kind.Subtitle,
            "zip" or "tar" or "tar.gz" or "gz" or "rar" or "7z" => Kind.Archive,
            _ => Kind.Other,
        };
    }

    public static List<Op> Ops(Mode mode, List<string> files)
    {
        if (files.Count == 0) return new();
        var kinds = files.Select(KindOf).Distinct().ToList();
        var kind = kinds.Count == 1 ? kinds[0] : Kind.Other;
        switch (mode)
        {
            case Mode.Convert:
                var own = files.Select(NormExt).Distinct().ToList();
                return Targets(kind).Where(t => !(own.Count == 1 && own[0] == t))
                    .Select(ext => Each(ext.ToUpperInvariant(), f => Converter.Run(f, ext))).ToList();
            case Mode.Tools:
                return Tools(kind, files.Count > 1).Append(new Op("Zip", fs => new() { Archive.Zip(fs) })).ToList();
            default:
                return Actions;
        }
    }

    public static List<string> Targets(Kind kind)
    {
        bool ff = Shell.FFmpeg != null, office = Shell.Soffice != null;
        var list = kind switch
        {
            Kind.Image => new List<string> { "jpg", "png", "tiff", "bmp", "gif", "pdf", "docx" }.Concat(ff ? new[] { "webp", "avif" } : new string[0])
                .Concat(Img.CanHeic.Value ? new[] { "heic" } : new string[0]),
            Kind.Audio => ff ? new[] { "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma" } : new[] { "mp3", "m4a", "wav", "flac", "wma" },
            Kind.Video => ff ? new[] { "mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3", "m4a" } : new[] { "mp4", "wmv", "mp3", "m4a" },
            Kind.Pdf => new List<string> { "png", "jpg", "txt", "md", "docx", "rtf", "html", "xlsx" }
                .Concat(Shell.Pandoc != null ? new[] { "epub" } : new string[0]).Concat(office ? new[] { "pptx" } : new string[0]),
            Kind.Document => new List<string> { "pdf", "docx", "rtf", "html", "txt", "md", "odt" }.Concat(Shell.Pandoc != null ? new[] { "epub" } : new string[0]),
            Kind.Sheet => new[] { "csv", "tsv", "xlsx", "ods", "pdf" },
            Kind.Slides => office ? new[] { "pdf", "png", "jpg" } : new string[0],
            Kind.Subtitle => new[] { "srt", "vtt", "txt" },
            Kind.Archive => new[] { "zip", "tar", "tar.gz" },
            _ => new string[0],
        };
        return list.ToList();
    }

    static List<Op> Tools(Kind kind, bool multi)
    {
        bool ff = Shell.FFmpeg != null;
        var ops = new List<Op>();
        switch (kind)
        {
            case Kind.Image:
                ops.AddRange(new[] {
                    Editor("Edit", EditTool.Edit), Editor("Crop", EditTool.Crop), Editor("Redact", EditTool.Redact),
                    Editor("Annotate", EditTool.Annotate), Editor("Add BG", EditTool.Background),
                    new Op("Compress", fs => SizePrompt.Ask(fs[0], SizePrompt.Image) is long target ? fs.Select(f => ImageEdit.CompressTo(f, target)).ToList() : new(), true),
                    Each("Resize 50%", f => Img.Transform(f, " small", b => Img.Scale(b, 0.5, 0.5))),
                    Each("Rotate", f => Img.Transform(f, " rotated", b => Img.Rotate(b, 90))),
                    Each("Strip Metadata", f => Img.Transform(f, " clean", b => b)),
                });
                if (multi) ops.Add(new Op("Make PDF", fs => new() { Pdfs.MakeFromImages(fs) }));
                if (multi) ops.Add(new Op("Collage", fs => { var o = Paths.Output(fs[0], "jpg", " collage"); Img.Save(ImageEdit.Collage(fs.Take(36).Select(Img.Load).ToList()), o); return new() { o }; }));
                break;
            case Kind.Video:
                if (!ff)
                {
                    ops.AddRange(new[] { Each("Snapshot", AV.Snapshot), Each("Compress", AV.CompressVideo), Each("Extract Audio", AV.ExtractAudio) });
                    break;
                }
                ops.AddRange(new[] {
                    Editor("Trim", EditTool.Trim), Editor("Split", EditTool.Split), Editor("Speed", EditTool.Speed),
                    Editor("Crop", EditTool.Crop), Editor("Redact", EditTool.Redact), CompressTo(SizePrompt.Video),
                    Each("Snapshot", AV.Snapshot), Each("Mute", f => AV.FF(f, null, " muted", "-an", "-c:v", "copy")), Each("Extract Audio", AV.ExtractAudio),
                    Each("Strip Metadata", f => AV.FF(f, null, " clean", "-map_metadata", "-1", "-c", "copy")),
                });
                if (multi) ops.Add(new Op("Join", fs => new() { AV.Join(fs) }));
                break;
            case Kind.Audio:
                if (!ff) { ops.AddRange(new[] { Each("Compress", AV.CompressAudio), Each("Mono", AV.Mono) }); break; }
                ops.AddRange(new[] {
                    Editor("Trim", EditTool.Trim), Editor("Bleep", EditTool.Bleep), Editor("Channels", EditTool.Channels),
                    Editor("Visualize", EditTool.Visualize), Editor("Split", EditTool.Split), CompressTo(SizePrompt.Audio),
                });
                ops.Add(Each("Normalize", f => AV.FF(f, null, " normalized", "-af", "loudnorm")));
                ops.Add(Each("Trim Silence", f => AV.FF(f, null, " trimmed", "-af",
                    "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse")));
                ops.Add(Each("Strip Metadata", f => AV.FF(f, null, " clean", "-map_metadata", "-1", "-c", "copy")));
                if (multi) ops.Add(new Op("Join", fs => new() { AV.Join(fs) }));
                break;
            case Kind.Pdf:
                ops.AddRange(new[] { new Op("Organize", fs => { Organizer.Open(fs[0]); return new(); }, true), Each("Compress", Pdfs.Compress), Each("Split Pages", Pdfs.Split), Each("Rotate", Pdfs.Rotate), Each("Strip Metadata", Pdfs.Strip) });
                if (multi) ops.Add(new Op("Merge", fs => new() { Pdfs.Merge(fs) }));
                break;
            case Kind.Archive:
                ops.Add(Each("Extract", Archive.Extract));
                break;
        }
        return ops;
    }

    /// <summary>Editors open a window per file (at most four at once) and save from there.</summary>
    static Op Editor(string title, EditTool t) => new(title, fs => { foreach (var f in fs.Take(4)) Satsuma.Editor.Open(f, t); return new(); }, true);

    /// <summary>Asks for the size on the UI thread; the encode itself runs in the background.</summary>
    static Op CompressTo((string, long)[] sizes) => new("Compress", fs =>
    {
        long? target = null;
        System.Windows.Application.Current.Dispatcher.Invoke(() => target = SizePrompt.Ask(fs[0], sizes));
        return target is long t ? fs.Select(f => AVEdit.CompressTo(f, t)).ToList() : new();
    });

    /// <summary>Alt wheel: things to do with the files themselves.</summary>
    static readonly List<Op> Actions = new()
    {
        new("Copy", fs =>
        {
            var list = new StringCollection();
            list.AddRange(fs.ToArray());
            System.Windows.Clipboard.SetFileDropList(list);
            return new();
        }, true),
        new("Copy Path", fs => { System.Windows.Clipboard.SetText(string.Join(Environment.NewLine, fs)); return new(); }, true),
        new("Terminal", fs =>
        {
            var dir = Directory.Exists(fs[0]) ? fs[0] : Path.GetDirectoryName(fs[0]);
            var wt = Shell.Find("wt.exe");
            if (wt != null) Process.Start(new ProcessStartInfo(wt, $"-d \"{dir}\"") { UseShellExecute = true });
            else Process.Start(new ProcessStartInfo("powershell.exe") { WorkingDirectory = dir, UseShellExecute = true });
            return new();
        }, true),
        new("Float", fs => { foreach (var f in fs.Take(8)) Float.Show(f); return new(); }, true),
        new("Share", fs => { Share.Files(fs); return new(); }, true),
        new("Open", fs => { foreach (var f in fs) Process.Start(new ProcessStartInfo(f) { UseShellExecute = true }); return new(); }, true),
        new("Move To…", fs =>
        {
            using var dlg = new System.Windows.Forms.FolderBrowserDialog { Description = "Move here" };
            if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return new();
            return fs.Select(src =>
            {
                var dst = Path.Combine(dlg.SelectedPath, Path.GetFileName(src));
                if (Directory.Exists(src)) Directory.Move(src, dst); else File.Move(src, dst);
                return dst;
            }).ToList();
        }, true),
    };
}
