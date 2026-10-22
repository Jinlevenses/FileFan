import Foundation

public struct ConversionFormat: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    public let extensions: [String]
    public let writable: Bool
}

public struct ConversionTarget: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    public let targetFormatID: String
    public let presetID: String?
    public let isAvailable: Bool
    public let unavailableReason: String?

    public init(id: String, name: String, category: String, targetFormatID: String, presetID: String? = nil, isAvailable: Bool, unavailableReason: String? = nil) {
        self.id = id; self.name = name; self.category = category; self.targetFormatID = targetFormatID
        self.presetID = presetID; self.isAvailable = isAvailable; self.unavailableReason = unavailableReason
    }
}

public struct ConversionOptions: Sendable {
    public var quality: Int
    public var maxPixelDimension: Int?
    public var pageRange: String
    public init(quality: Int = 90, maxPixelDimension: Int? = nil, pageRange: String = "") {
        self.quality = quality; self.maxPixelDimension = maxPixelDimension; self.pageRange = pageRange
    }
}

public struct ConversionFileResult: Sendable {
    public let sourceURL: URL
    public let outputURLs: [URL]
    public let error: String?
    public let notice: String?
}

public struct ConversionBatchResult: Sendable {
    public let files: [ConversionFileResult]
    public var successCount: Int { files.filter { $0.error == nil && !$0.outputURLs.isEmpty }.count }
    public var failureCount: Int { files.count - successCount }
    public var outputURLs: [URL] { Array(Set(files.flatMap(\.outputURLs))).sorted { $0.path < $1.path } }
}

public enum ConversionBackendError: LocalizedError {
    case unavailable, timedOut, invalidInput(String), invalidOptions, processFailed(String), invalidResponse(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "변환 백엔드가 앱에 포함되어 있지 않습니다. PNG/JPEG 기본 변환은 사용할 수 있습니다."
        case .timedOut: return "변환 엔진의 처리 시간이 제한을 초과했습니다. 더 작은 파일로 다시 시도하세요."
        case .invalidInput(let message), .processFailed(let message), .invalidResponse(let message): return message
        case .invalidOptions: return "품질(1–100), 양수 크기 또는 페이지 범위(예: 1-3,5)를 확인하세요."
        }
    }
}

enum ConversionCatalog {
    static let formats: [ConversionFormat] = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("FileFan_FileFanCore.bundle/formats.json")
        let resource = packaged.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "formats", withExtension: "json")
        guard let url = resource,
              let data = try? Data(contentsOf: url), let formats = try? JSONDecoder().decode([ConversionFormat].self, from: data) else { return [] }
        return formats
    }()
    private static let suffixes: [(String, ConversionFormat)] = formats.flatMap { format in
        format.extensions.map { ("." + $0, format) }
    }.sorted { $0.0.count > $1.0.count }
    static func format(for url: URL) -> ConversionFormat? {
        let name = url.lastPathComponent.lowercased()
        return suffixes.first { name.hasSuffix($0.0) }?.1
    }

    struct Action {
        let id: String, name: String, target: String, category: String
        let sources: Set<String>?
    }
    static let actions: [Action] = [
        .init(id: "merge-pdf", name: "PDF 병합", target: "pdf", category: "Pdf", sources: nil),
        .init(id: "pdf-split", name: "PDF 페이지 분할", target: "pdf", category: "Pdf", sources: ["pdf"]),
        .init(id: "compress-pdf", name: "PDF 압축", target: "pdf", category: "Pdf", sources: ["pdf"]),
        .init(id: "pdf-pages", name: "PDF 페이지 범위 추출", target: "pdf", category: "Pdf", sources: ["pdf"]),
        .init(id: "pdf-slides", name: "PDF → PPTX (페이지 이미지)", target: "pptx", category: "Presentation", sources: ["pdf"]),
        .init(id: "mp4-720", name: "MP4 720p", target: "mp4", category: "Video", sources: nil),
        .init(id: "mp4-hevc", name: "MP4 HEVC", target: "mp4", category: "Video", sources: nil),
        .init(id: "mp4-av1", name: "MP4 AV1", target: "mp4", category: "Video", sources: nil),
        .init(id: "extract-subtitles", name: "자막 추출 (SRT)", target: "srt", category: "Subtitle", sources: nil),
        .init(id: "extract", name: "압축 풀기", target: "folder", category: "Archive", sources: nil),
        .init(id: "zip-all", name: "ZIP 하나로 묶기", target: "zip", category: "Archive", sources: nil),
        .init(id: "grayscale", name: "회색조 PNG", target: "png", category: "Image", sources: nil),
        .init(id: "resize", name: "PNG 크기 조절", target: "png", category: "Image", sources: nil)
    ]
}
