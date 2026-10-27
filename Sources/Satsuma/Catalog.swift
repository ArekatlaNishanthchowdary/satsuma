import AppKit

enum Mode {
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

enum Kind {
    case image, audio, video, pdf, document, sheet, slides, subtitle, archive, other

    static func of(_ url: URL) -> Kind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           url.pathExtension.lowercased() != "rtfd" { return .other }
        switch normExt(url) {
        case "jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif", "svg": return .image
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac", "caf": return .audio
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v": return .video
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "txt", "md", "html", "odt", "webarchive": return .document
        case "epub": return Shell.pandoc == nil ? .other : .document
        case "csv", "tsv", "xlsx", "ods", "xls": return .sheet
        case "ppt", "pptx", "odp": return .slides
        case "srt", "vtt": return .subtitle
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
            return targets(kind)
                .filter { !(own.count == 1 && own.contains($0)) }
                .map { ext in each(ext.uppercased()) { try Convert.run($0, to: ext) } }
        case .tools:
            return tools(kind, multi: urls.count > 1) + [Op(title: "Zip") { [try Archive.zip($0)] }]
        case .actions:
            return Actions.all
        }
    }

    static func targets(_ kind: Kind) -> [String] {
        let ff = Shell.ffmpeg != nil, office = Shell.soffice != nil
        switch kind {
        case .image: return ["jpg", "png", "heic", "tiff", "bmp", "gif", "pdf", "docx"] + (ff ? ["webp", "avif"] : [])
        case .audio: return ff ? ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"] : ["m4a", "wav", "aiff", "flac"]
        case .video: return ff ? ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3", "m4a"] : ["mp4", "mov", "m4a"]
        case .pdf: return ["png", "jpg", "txt", "md", "docx", "rtf", "html", "xlsx"] + (Shell.pandoc != nil ? ["epub"] : []) + (office ? ["pptx"] : [])
        case .document: return ["pdf", "docx", "rtf", "html", "txt", "md", "odt"] + (Shell.pandoc != nil ? ["epub"] : [])
        case .sheet: return ["csv", "tsv", "xlsx", "ods", "pdf"]
        case .slides: return office ? ["pdf", "png", "jpg"] : []
        case .subtitle: return ["srt", "vtt", "txt"]
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
                each("Compress", Img.compress),
                each("Resize 50%") { try Img.transform($0, suffix: " small") { $0.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)) } },
                each("Rotate") { try Img.transform($0, suffix: " rotated") { $0.oriented(.right) } },
                each("Flip") { try Img.transform($0, suffix: " flipped") { $0.oriented(.upMirrored) } },
                each("Grayscale") { try Img.transform($0, suffix: " mono") { $0.applyingFilter("CIPhotoEffectMono") } },
                each("Strip Metadata") { try Img.transform($0, suffix: " clean") { $0 } },
                Op(title: "Read QR Code") { try Img.readQR($0); return [] },
            ]
            if multi { ops.append(Op(title: "Make PDF") { [try Img.makePDF($0)] }) }
        case .video:
            ops = [each("Snapshot", AV.snapshot), each("Compress", AV.compressVideo), each("Extract Audio", AV.extractAudio)]
            if ff {
                ops += [
                    each("Mute") { try AV.ff($0, suffix: " muted", ["-an", "-c:v", "copy"]) },
                    each("Speed 2×") { try AV.ff($0, suffix: " 2x", ["-vf", "setpts=0.5*PTS", "-af", "atempo=2.0"]) },
                    each("Strip Metadata") { try AV.ff($0, suffix: " clean", ["-map_metadata", "-1", "-c", "copy"]) },
                ]
                if multi { ops.append(Op(title: "Join") { [try AV.join($0)] }) }
            }
        case .audio:
            if ff {
                ops = [
                    each("Compress") { try AV.ff($0, ext: "m4a", suffix: " compressed", ["-vn", "-c:a", "aac", "-b:a", "96k"]) },
                    each("Normalize") { try AV.ff($0, suffix: " normalized", ["-af", "loudnorm"]) },
                    each("Trim Silence") { try AV.ff($0, suffix: " trimmed", ["-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"]) },
                    each("Mono") { try AV.ff($0, suffix: " mono", ["-ac", "1"]) },
                    each("Strip Metadata") { try AV.ff($0, suffix: " clean", ["-map_metadata", "-1", "-c", "copy"]) },
                ]
                if multi { ops.append(Op(title: "Join") { [try AV.join($0)] }) }
            } else {
                ops = [each("Mono", AV.monoNative)]
            }
        case .pdf:
            ops = [
                each("Compress", PDFs.compress),
                each("Split Pages", PDFs.split),
                each("Rotate", PDFs.rotate),
                each("Strip Metadata", PDFs.strip),
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
