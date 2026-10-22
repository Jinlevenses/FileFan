import Foundation

public struct ConversionTargetGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let matchesSource: Bool
    public let targets: [ConversionTarget]
}

/// Presentation changes order and removes duplicate format aliases; it never grants a conversion route.
public enum ConversionPresentation {
    private struct Family {
        let id: String
        let title: String
        let categories: Set<String>
        let preferred: [String]
    }
    private static let families: [Family] = [
        .init(id: "images", title: "Images", categories: ["image", "vector"], preferred: ["png", "jpg", "webp", "avif", "heic", "gif", "tiff", "bmp", "ico", "svg", "eps", "psd"]),
        .init(id: "documents", title: "Documents", categories: ["document", "hwp", "pdf", "text"], preferred: ["pdf", "docx", "doc", "hwpx", "hwp", "odt", "rtf", "txt", "md", "html"]),
        .init(id: "spreadsheets", title: "Spreadsheets", categories: ["spreadsheet"], preferred: ["xlsx", "xls", "csv", "tsv", "ods", "numbers"]),
        .init(id: "audio", title: "Audio", categories: ["audio"], preferred: ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff", "wma"]),
        .init(id: "video", title: "Video", categories: ["video"], preferred: ["mp4", "mov", "mkv", "webm", "avi", "m4v", "wmv"]),
        .init(id: "archives", title: "Archives", categories: ["archive"], preferred: ["zip", "7z", "tar", "tgz", "gz", "bz2", "xz", "rar"]),
        .init(id: "presentations", title: "Presentations", categories: ["presentation"], preferred: ["pptx", "ppt", "odp", "key"]),
        .init(id: "ebooks", title: "Ebooks", categories: ["ebook"], preferred: ["epub", "mobi", "azw3", "fb2"]),
        .init(id: "subtitles", title: "Subtitles", categories: ["subtitle"], preferred: ["srt", "vtt", "ass", "ssa", "smi", "scc"]),
        .init(id: "data", title: "Data", categories: ["data"], preferred: ["json", "jsonl", "yaml", "xml", "toml", "vcf"]),
        .init(id: "fonts", title: "Fonts", categories: ["font"], preferred: ["ttf", "otf", "woff2", "woff", "eot"]),
        .init(id: "cad", title: "CAD", categories: ["cad"], preferred: ["dxf", "dwg"]),
        .init(id: "models", title: "3D Models", categories: ["model3d"], preferred: ["glb", "gltf", "stl", "obj", "3mf", "ply"]),
        .init(id: "other", title: "Other", categories: [], preferred: [])
    ]
    private static func familyIndex(_ category: String) -> Int {
        families.firstIndex { $0.categories.contains(category.lowercased()) } ?? families.count - 1
    }
    private static func canonicalID(_ id: String) -> String {
        switch id.lowercased() {
        case "jpeg", "jpe", "jfif": return "jpg"
        case "tif": return "tiff"
        default: return id.lowercased()
        }
    }
    public static func groups(targets: [ConversionTarget], sourceURLs: [URL], search: String = "") -> [ConversionTargetGroup] {
        var sourceOrder: [Int] = []
        for url in sourceURLs where url.isFileURL {
            guard let format = ConversionCatalog.format(for: url) else { continue }
            let family = familyIndex(format.category)
            if !sourceOrder.contains(family) { sourceOrder.append(family) }
        }
        var unique: [ConversionTarget] = []
        var positions: [String: Int] = [:]
        for target in targets {
            let key = target.presetID == nil ? "format:" + canonicalID(target.targetFormatID) : target.id
            if let index = positions[key] {
                if target.isAvailable && !unique[index].isAvailable { unique[index] = target }
            } else {
                positions[key] = unique.count; unique.append(target)
            }
        }
        let indexed = unique.enumerated().map { (index: $0.offset, target: $0.element) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = families.indices.compactMap { family -> (index: Int, group: ConversionTargetGroup)? in
            let descriptor = families[family]
            let members = indexed.filter {
                familyIndex($0.target.category) == family && (query.isEmpty || ($0.target.name + " " + $0.target.category + " " + $0.target.targetFormatID + " " + descriptor.title).localizedCaseInsensitiveContains(query))
            }.sorted { lhs, rhs in
                if lhs.target.isAvailable != rhs.target.isAvailable { return lhs.target.isAvailable }
                if (lhs.target.presetID == nil) != (rhs.target.presetID == nil) { return lhs.target.presetID == nil }
                let leftRank = descriptor.preferred.firstIndex(of: canonicalID(lhs.target.targetFormatID)) ?? Int.max
                let rightRank = descriptor.preferred.firstIndex(of: canonicalID(rhs.target.targetFormatID)) ?? Int.max
                return leftRank == rightRank ? lhs.index < rhs.index : leftRank < rightRank
            }.map(\.target)
            guard !members.isEmpty else { return nil }
            return (family, ConversionTargetGroup(id: descriptor.id, title: descriptor.title, matchesSource: sourceOrder.contains(family), targets: members))
        }
        return groups.sorted { lhs, rhs in
            let leftSource = sourceOrder.firstIndex(of: lhs.index), rightSource = sourceOrder.firstIndex(of: rhs.index)
            if let leftSource, let rightSource { return leftSource < rightSource }
            if leftSource != nil || rightSource != nil { return leftSource != nil }
            let leftAvailable = lhs.group.targets.contains(where: \.isAvailable), rightAvailable = rhs.group.targets.contains(where: \.isAvailable)
            return leftAvailable == rightAvailable ? lhs.index < rhs.index : leftAvailable
        }.map(\.group)
    }
    public static func orderedTargets(_ targets: [ConversionTarget], sourceURLs: [URL]) -> [ConversionTarget] {
        groups(targets: targets, sourceURLs: sourceURLs).flatMap(\.targets)
    }
}
