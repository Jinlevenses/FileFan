import Foundation

public enum ContextToolID: String, Sendable, CaseIterable {
    case airdrop, float, copy, move, copyPath, terminal
    case compress, metadata, edit, annotate, background, crop, redact, merge, split, pages
    case pdf, text, mute, trim, speed, snapshot, extract, zip, utf8, validate, format
    case csv, xlsx, pptx, png, svg, dxf, ttf, woff, glb, obj, srt, vtt, json, xml
    public var title: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        case .background: return "Add BG"
        case .utf8: return "UTF-8"
        case .zip: return "Create ZIP"
        case .pdf, .csv, .xlsx, .pptx, .png, .svg, .dxf, .ttf, .woff, .glb, .obj, .srt, .vtt, .json, .xml: return rawValue.uppercased()
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}
public struct ContextTool: Identifiable, Sendable {
    public let id: ContextToolID
    public let isAvailable: Bool
    public let reason: String?
    public let targetID: String?
    public var title: String { id.title }
}
public enum ContextToolCatalog {
    public static func kind(for url: URL, folders: Set<URL> = []) -> String {
        guard !folders.contains(url), let format = ConversionCatalog.format(for: url) else { return "unknown" }
        switch format.category {
        case "Document", "Hwp", "Text": return "document"
        default: return format.category.lowercased()
        }
    }
    public static func fileActions(for urls: [URL]) -> [ContextTool] {
        [.airdrop, .float, .copy, .move, .copyPath, .terminal].map { ContextTool(id: $0, isAvailable: true, reason: nil, targetID: nil) }
    }
    public static func tools(for urls: [URL], folders: Set<URL> = [], targets: [ConversionTarget] = [], imageReadable: Bool = true, ffmpegAvailable: Bool = true) -> [ContextTool] {
        guard !urls.isEmpty else { return [] }
        let kinds = urls.map { kind(for: $0, folders: folders) }
        func ids(_ kind: String) -> [ContextToolID] {
            switch kind {
            case "image": return [.compress, .metadata, .edit, .annotate, .background, .crop, .redact]
            case "pdf": return [.compress, .metadata, .merge, .split, .pages, .annotate]
            case "document": return [.pdf, .text, .edit, .metadata]
            case "spreadsheet": return [.pdf, .csv, .xlsx, .metadata]
            case "presentation": return [.pdf, .pptx, .png, .metadata]
            case "video": return [.compress, .metadata, .mute, .trim, .crop, .speed, .snapshot, .redact, .split]
            case "audio": return [.compress, .metadata, .trim, .speed]
            case "archive": return [.extract, .zip, .metadata]
            case "subtitle": return [.utf8, .srt, .vtt, .metadata]
            case "data": return urls.allSatisfy { ["json", "jsonl"].contains($0.pathExtension.lowercased()) } ? [.validate, .format, .metadata] : [.json, .xml, .metadata]
            case "vector": return [.png, .svg, .metadata]
            case "font": return [.ttf, .woff, .metadata]
            case "cad": return [.dxf, .pdf, .metadata]
            case "model3d": return [.glb, .obj, .metadata]
            default: return [.metadata, .zip]
            }
        }
        let family = kinds[0]
        let mixed = Set(kinds).count > 1
        let common = ids(family).filter { id in kinds.allSatisfy { ids($0).contains(id) } && (!mixed || [.metadata, .zip].contains(id)) }
        return common.map { id in
            var available = true, reason: String?, target: ConversionTarget?
            var preset: String?, output: String?
            if family == "pdf" {
                switch id { case .compress: preset = "compress-pdf"; case .merge: preset = "merge-pdf"; case .split: preset = "pdf-split"; case .pages: preset = "pdf-pages"; default: break }
            }
            if id == .extract { preset = "extract" }
            if id == .zip { preset = "zip-all" }
            switch id {
            case .pdf, .csv, .xlsx, .pptx, .png, .svg, .dxf, .ttf, .woff, .glb, .obj, .srt, .vtt, .json, .xml: output = id.rawValue
            case .text: output = "txt"
            case .edit where family == "document":
                let nativeTextEdit = Set(["txt", "md", "html", "htm", "rtf", "rtfd", "doc", "docx", "odt", "tex", "csv", "tsv", "xml", "json", "rst", "org", "adoc", "typ", "mediawiki", "textile", "man", "opml"])
                if urls.contains(where: { !nativeTextEdit.contains($0.pathExtension.lowercased()) }) { output = "docx" }
            default: break
            }
            if let preset { target = targets.first { $0.presetID == preset } }
            if let output { target = targets.first { $0.presetID == nil && $0.targetFormatID == output } }
            if preset != nil || output != nil {
                available = target?.isAvailable == true
                reason = available ? nil : target?.unavailableReason ?? "No shared conversion route is available for these files."
            }
            if id == .zip, !folders.isEmpty { available = true; reason = nil; target = nil }
            if family == "image", id != .metadata, !imageReadable { available = false; reason = "ImageIO cannot decode every selected image for this operation." }
            if ["video", "audio"].contains(family), id != .metadata, !ffmpegAvailable { available = false; reason = "The bundled FFmpeg engine is unavailable." }
            return ContextTool(id: id, isAvailable: available, reason: reason, targetID: target?.id)
        }
    }
}
