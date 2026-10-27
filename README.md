# Satsuma

An open-source, offline file converter for the Mac menu bar, inspired by [Tangerine](https://tangerineformac.com/).
Built for **Intel Macs** (and Apple Silicon with `ARCH=arm64`), macOS 13 or later.

## Download

Grab the latest installers from [Releases](https://github.com/ArekatlaNishanthchowdary/satsuma/releases/latest):

- **Mac (Intel):** `Satsuma-<version>-mac-intel.dmg`. Open it, drag Satsuma to Applications, then right-click → **Open** the first time.
- **Windows (x64):** `Satsuma-<version>-windows-x64.exe`. Run it; if SmartScreen appears, choose **More info → Run anyway**.

Neither is code-signed, so both systems ask once.

## How it works

Drag any file in Finder, then **tap a key without letting go**:

| Key | Wheel | What's on it |
|---|---|---|
| ⇧ Shift | **Convert** | Output formats for that kind of file |
| ⌘ Command | **Tools** | Compress, resize, rotate, split, merge, extract… |
| ⌃ Control | **Actions** | AirDrop, Copy, Copy Path, Terminal, Quick Look, Move To… |

A ring of options opens around the pointer. Keep dragging, drop the file on a slice, and the result is saved
next to the original and shown in Finder. Drop in the middle to cancel. Tap a different key to switch wheels.
Prefer clicking? Use **Choose Files…** in the menu bar icon.

The wheel and progress card use **Liquid Glass** on macOS 26, and a blur on older systems. Pick a look under
**Theme** in the menu bar icon: Tangerine, Clear Glass, Lime, Blueberry, Grape, Strawberry, Mint or Graphite (glass),
or Midnight, Paper, Neon or Sunset (solid). **Preview Wheel** shows the current theme.

Everything runs locally. Nothing is uploaded, and no Accessibility permission is needed.

## Formats

Built in (no extra installs):

| Kind | Convert to | Tools |
|---|---|---|
| Images (JPG, PNG, HEIC, TIFF, BMP, GIF, WebP, AVIF, SVG) | JPG PNG HEIC TIFF BMP GIF PDF | Compress, Resize 50%, Rotate, Flip, Grayscale, Strip Metadata, Read QR Code, Make PDF (several) |
| Video (MP4, MOV, M4V) | MP4 MOV M4A | Snapshot, Compress, Extract Audio |
| Audio (MP3, M4A, WAV, FLAC, AIFF, CAF) | M4A WAV AIFF FLAC | Mono |
| PDF | PNG/JPG (300 DPI, every page), TXT, MD, DOCX, RTF, HTML | Compress, Split Pages, Rotate, Strip Metadata, Merge (several) |
| Documents (DOCX, DOC, ODT, RTF, RTFD, HTML, TXT, MD) | PDF DOCX RTF HTML TXT MD ODT | |
| Spreadsheets (CSV, TSV, XLSX) | CSV TSV XLSX | |
| Subtitles (SRT, VTT) | SRT VTT TXT | |
| Archives (ZIP, TAR, TAR.GZ, GZ, RAR, 7Z) | ZIP TAR TAR.GZ | Extract |
| Anything | | Zip |

With **ffmpeg** installed (`brew install ffmpeg`) you also get:

- Images: WebP and AVIF output
- Audio: MP3, OGG, Opus and WMA output, plus Compress, Normalize, Trim Silence, Strip Metadata and Join
- Video: MKV, WebM, AVI, WMV, GIF and MP3 output, plus Mute, Speed 2×, Strip Metadata and Join

With **pandoc** installed (`brew install pandoc`) you also get EPUB in and out, and better Markdown (headings and lists).

The menu bar menu shows whether each was found.

## Build

You need the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```bash
./build.sh --dmg
```

This produces `build/Satsuma.app` and `dist/Satsuma-<version>.dmg`. Run `build/Satsuma.app/Contents/MacOS/Satsuma --selftest`
to round-trip a sample file through each built-in converter.

The app is ad-hoc signed, so on first launch right-click it and choose **Open**.

## Not (yet) like Tangerine

- No Pages, Numbers, Keynote, PPT/PPTX or ODS. Those need Apple's or LibreOffice's apps.
- Tools run with fixed settings: no crop/trim editors and no "compress to exactly N MB".
- XLSX: first sheet only, values (not formulas).
- The trigger keys are fixed.

## License

MIT

## Windows

`windows/` holds the Windows version: same wheel, same 12 themes, same converters, with Windows keys.

| Key (tap mid-drag) | Wheel |
|---|---|
| Shift | Convert |
| Ctrl | Tools |
| Alt | Actions (Copy, Copy Path, Terminal, Open, Move To…) |

It lives in the system tray. Click the orange icon for **Choose Files…**, **Theme**, **Preview Wheel**, **Show in Send To menu**
(adds right-click → Send to → Satsuma) and **Start with Windows**.

It uses Windows' own encoders (MP3, M4A, WAV, WMA, FLAC, MP4, WMV), PDF renderer and `tar.exe`, plus PDFsharp (MIT) and PdfPig (Apache-2.0).
`winget install ffmpeg` and `winget install pandoc` add the same extras as on the Mac; the tray menu offers to install them.
Glass on Windows is drawn (translucent layers, tint, highlight); it doesn't blur what's behind.

```powershell
cd windows
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o publish
publish\Satsuma.exe --selftest
```

The exe is unsigned, so SmartScreen asks once: **More info → Run anyway**.
