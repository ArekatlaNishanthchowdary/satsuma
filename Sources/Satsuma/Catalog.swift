import AppKit

enum Mode: Int, CaseIterable {
    case convert, tools, actions
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
}

struct Op {
    let title: String
    let run: ([URL]) throws -> [URL]
}

/// An op that runs once per file.
func each(_ title: String, _ f: @escaping (URL) throws -> URL) -> Op {
    Op(title: title) { try $0.map(f) }
}

enum Kind: String, CaseIterable {
    case image, audio, video, pdf, document, sheet, slides, subtitle, archive, data, font, other

    static func of(_ url: URL) -> Kind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           url.pathExtension.lowercased() != "rtfd" { return .other }
        switch normExt(url) {
        case "jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif", "svg", "ico", "icns": return .image
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac", "caf": return .audio
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v": return .video
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "txt", "md", "html", "odt", "webarchive": return .document
        case "epub": return Shell.pandoc == nil ? .other : .document
        case "csv", "tsv", "xlsx", "ods", "xls": return .sheet
        case "ppt", "pptx", "odp": return .slides
        case "srt", "vtt", "ass", "ssa", "lrc", "sbv": return .subtitle
        case "json", "xml": return .data
        case "ttf", "otf", "woff": return .font
        case "zip", "tar", "tar.gz", "gz", "rar", "7z": return .archive
        default: return .other
        }
    }
}

func normExt(_ url: URL) -> String {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "tar.gz" }
    let e = url.pathExtension.lowercased()
    return ["jpeg": "jpg", "tif": "tiff", "htm": "html", "aif": "aiff", "markdown": "md", "heif": "heic"][e] ?? e
}

enum Catalog {
    static func ops(_ mode: Mode, _ urls: [URL]) -> [Op] {
        guard !urls.isEmpty else { return [] }
        let kinds = Set(urls.map(Kind.of))
        let kind = kinds.count == 1 ? kinds.first! : .other
        switch mode {
        case .convert:
            let own = Set(urls.map(normExt))
            var list = kind == .font ? [] : targets(kind)
            if kind == .font { for t in urls.flatMap(Fonts.targets) where !list.contains(t) { list.append(t) } }
            return Layout.apply(list
                .filter { !(own.count == 1 && own.contains($0)) }
                .map { ext in each(ext.uppercased()) { try Convert.run($0, to: ext) } }, kind, mode)
        case .tools:
            return Layout.apply(tools(kind, multi: urls.count > 1) + [Op(title: "Zip") { [try Archive.zip($0)] }], kind, mode)
        case .actions:
            return Layout.apply(Actions.all, kind, mode)
        }
    }

    /// Every slice a wheel can show for this kind, before the user's layout hides or reorders any.
    static func allTitles(_ kind: Kind, _ mode: Mode) -> [String] {
        switch mode {
        case .convert: return targets(kind).map { $0.uppercased() }
        case .tools: return tools(kind, multi: true).map(\.title) + ["Zip"]
        case .actions: return Actions.all.map(\.title)
        }
    }

    static func targets(_ kind: Kind) -> [String] {
        let ff = Shell.ffmpeg != nil, office = Shell.soffice != nil
        switch kind {
        case .image: return ["jpg", "png", "heic", "tiff", "bmp", "gif", "pdf", "docx", "ico", "icns"] + (ff ? ["webp", "avif"] : [])
        case .audio: return ff ? ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"] : ["m4a", "wav", "aiff", "flac"]
        case .video: return ff ? ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3", "m4a"] : ["mp4", "mov", "m4a"]
        case .pdf: return ["png", "jpg", "txt", "md", "docx", "rtf", "html", "xlsx"] + (Shell.pandoc != nil ? ["epub"] : []) + (office ? ["pptx"] : [])
        case .document: return ["pdf", "docx", "rtf", "html", "txt", "md", "odt"] + (Shell.pandoc != nil ? ["epub"] : [])
        case .sheet: return ["csv", "tsv", "xlsx", "ods", "pdf", "json"]
        case .slides: return office ? ["pdf", "png", "jpg"] : []
        case .subtitle: return ["srt", "vtt", "ass", "lrc", "sbv", "txt"]
        case .data: return ["json", "xml", "yaml", "csv", "xlsx"]
        case .font: return ["woff", "ttf", "otf"]
        case .archive: return ["zip", "tar", "tar.gz"]
        case .other: return []
        }
    }

    static func tools(_ kind: Kind, multi: Bool) -> [Op] {
        let ff = Shell.ffmpeg != nil
        var ops: [Op] = []
        switch kind {
        case .image:
            ops = [
                editor("Edit", .edit), editor("Crop", .crop), editor("Redact", .redact), editor("Annotate", .annotate), editor("Add BG", .background),
                Op(title: "Compress") { urls in
                    guard let target = onMain({ SizePrompt.ask(urls[0], SizePrompt.image) }) else { return [] }
                    return try urls.map { try ImageEdit.compress($0, target: target) }
                },
                each("Resize 50%") { try Img.transform($0, suffix: " small") { $0.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)) } },
                each("Rotate") { try Img.transform($0, suffix: " rotated") { $0.oriented(.right) } },
                each("Strip Metadata") { try Img.transform($0, suffix: " clean") { $0 } },
                Op(title: "Read QR Code") { try Img.readQR($0); return [] },
            ]
            if multi { ops.append(Op(title: "Make PDF") { [try Img.makePDF($0)] }) }
            if multi { ops.append(Op(title: "Collage") { [try ImageEdit.collage($0)] }) }
        case .video:
            guard ff else { ops = [each("Snapshot", AV.snapshot), each("Compress", AV.compressVideo), each("Extract Audio", AV.extractAudio)]; break }
            ops = [
                editor("Trim", .trim), editor("Split", .split), editor("Speed", .speed), editor("Crop", .crop), editor("Redact", .redact),
                compress(SizePrompt.video), each("Snapshot", AV.snapshot),
                each("Mute") { try AV.ff($0, suffix: " muted", ["-an", "-c:v", "copy"]) },
                each("Extract Audio", AV.extractAudio),
                each("Strip Metadata") { try AV.ff($0, suffix: " clean", ["-map_metadata", "-1", "-c", "copy"]) },
            ]
            if multi { ops.append(Op(title: "Join") { [try AV.join($0)] }) }
        case .audio:
            if ff {
                ops = [
                    editor("Trim", .trim), editor("Bleep", .bleep), editor("Channels", .channels), editor("Visualize", .visualize),
                    editor("Split", .split), compress(SizePrompt.audio),
                    each("Normalize") { try AV.ff($0, suffix: " normalized", ["-af", "loudnorm"]) },
                    each("Trim Silence") { try AV.ff($0, suffix: " trimmed", ["-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"]) },
                    each("Strip Metadata") { try AV.ff($0, suffix: " clean", ["-map_metadata", "-1", "-c", "copy"]) },
                ]
                if multi { ops.append(Op(title: "Join") { [try AV.join($0)] }) }
            } else {
                ops = [each("Mono", AV.monoNative)]
            }
        case .pdf:
            ops = [
                Op(title: "Organize") { urls in try onMain { try Organizer.open(urls[0]) }; return [] },
                each("Compress", PDFs.compress),
                each("Split Pages", PDFs.split),
                each("Rotate", PDFs.rotate),
                each("Strip Metadata", PDFs.strip),
                Op(title: "Watermark") { urls in
                    guard let text = onMain({ Prompt.text("Watermark", "Text to put across every page:", initial: "CONFIDENTIAL") }) else { return [] }
                    return try urls.map { try Stamp.watermark($0, text) }
                },
                each("Page Numbers", Stamp.number),
                Op(title: "Password") { urls in
                    guard let pw = onMain({ Prompt.text("Password", "Password for the locked copy (the original stays as it is):", secret: true) }) else { return [] }
                    return try urls.map { try Stamp.protect($0, pw) }
                },
            ]
            if multi { ops.append(Op(title: "Merge") { [try PDFs.merge($0)] }) }
        case .archive:
            ops = [each("Extract", Archive.extract)]
        default:
            break
        }
        return ops
    }
}

/// Editors open a window per file (at most four at once) and save from there.
func editor(_ title: String, _ t: EditTool) -> Op {
    Op(title: title) { urls in try onMain { try urls.prefix(4).forEach { try Editor.open($0, t) } }; return [] }
}

/// Asks for the size on the main thread; the encode runs on the caller's background thread.
func compress(_ sizes: [(String, Int)]) -> Op {
    Op(title: "Compress") { urls in
        guard let target = onMain({ SizePrompt.ask(urls[0], sizes) }) else { return [] }
        return try urls.map { try AVEdit.compress($0, target: target) }
    }
}

/// Control wheel: things to do with the files themselves. Runs on the main thread.
enum Actions {
    static let all: [Op] = [
        Op(title: "AirDrop") { urls in
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
            return []
        },
        Op(title: "Copy") { urls in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            return []
        },
        Op(title: "Copy Path") { urls in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            return []
        },
        Op(title: "Terminal") { urls in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir)
            let dir = isDir.boolValue ? urls[0] : urls[0].deletingLastPathComponent()
            NSWorkspace.shared.open([dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            return []
        },
        Op(title: "Float") { urls in
            urls.prefix(8).forEach(Float.show)
            return []
        },
        Op(title: "Quick Look") { urls in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p.arguments = ["-p"] + urls.map(\.path)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            return []
        },
        Op(title: "Move To…") { urls in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Move Here"
            guard panel.runModal() == .OK, let dir = panel.url else { return [] }
            return try urls.map { src in
                let dst = dir.appendingPathComponent(src.lastPathComponent)
                try FileManager.default.moveItem(at: src, to: dst)
                return dst
            }
        },
    ]
}
