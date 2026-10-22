import Foundation

public struct ShelfItem: Identifiable, Equatable, Sendable {
    public let url: URL
    public var id: String { url.path }
    public var displayName: String { url.lastPathComponent }
}

public struct FileIntakeRejection: Equatable, Sendable {
    public let url: URL
    public let reason: String
}

public struct FileIntakeResult: Sendable {
    public let accepted: [ShelfItem]
    public let rejected: [FileIntakeRejection]
}

public enum FileIntake {
    public static func inspect(_ urls: [URL]) -> FileIntakeResult {
        var accepted: [ShelfItem] = []
        var rejected: [FileIntakeRejection] = []
        var seen: Set<String> = []
        let manager = FileManager.default
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                rejected.append(.init(url: url, reason: "로컬 파일과 폴더만 추가할 수 있습니다."))
                continue
            }
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard manager.fileExists(atPath: canonicalURL.path) else {
                rejected.append(.init(url: url, reason: "파일 또는 폴더가 없습니다."))
                continue
            }
            guard manager.isReadableFile(atPath: canonicalURL.path) else {
                rejected.append(.init(url: url, reason: "파일 또는 폴더를 읽을 권한이 없습니다."))
                continue
            }
            let item = ShelfItem(url: canonicalURL)
            if seen.insert(item.id).inserted { accepted.append(item) }
        }
        return FileIntakeResult(accepted: accepted, rejected: rejected)
    }
}

public struct FileShelf: Sendable {
    public private(set) var items: [ShelfItem] = []
    public init() {}
    @discardableResult public mutating func add(_ urls: [URL]) -> FileIntakeResult {
        let result = FileIntake.inspect(urls)
        let existing = Set(items.map(\.id))
        let added = result.accepted.filter { !existing.contains($0.id) }
        items.append(contentsOf: added)
        return FileIntakeResult(accepted: added, rejected: result.rejected)
    }
    public mutating func remove(ids: Set<String>) { items.removeAll { ids.contains($0.id) } }
    public mutating func clear() { items.removeAll() }
    public func pathText(for ids: Set<String>? = nil) -> String {
        items.filter { ids?.contains($0.id) ?? true }.map(\.url.path).joined(separator: "\n")
    }
}
