import Foundation
import CoreGraphics

public struct SessionState: Codable, Sendable {
    public var version = 1
    public var files: [URL] = []
    public var selection: Set<String> = []
    public var dock: DockPlacement?
    public var windowFrame: CGRect?
    public var maxDimension = ""
    public var gesturesEnabled = true
    public var quality = 90.0
    public var pageRange = ""
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, files, selection, dock, windowFrame, maxDimension, gesturesEnabled, quality, pageRange }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        files = try values.decodeIfPresent([URL].self, forKey: .files) ?? []
        selection = try values.decodeIfPresent(Set<String>.self, forKey: .selection) ?? []
        dock = try values.decodeIfPresent(DockPlacement.self, forKey: .dock)
        windowFrame = try values.decodeIfPresent(CGRect.self, forKey: .windowFrame)
        maxDimension = try values.decodeIfPresent(String.self, forKey: .maxDimension) ?? ""
        gesturesEnabled = try values.decodeIfPresent(Bool.self, forKey: .gesturesEnabled) ?? true
        quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? 90
        pageRange = try values.decodeIfPresent(String.self, forKey: .pageRange) ?? ""
    }
}
public struct SessionLoadResult: Sendable {
    public var state: SessionState
    public var warning: String?
}
public struct SessionStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("session.json") }
    public init(directory: URL) { self.directory = directory }
    public static var application: SessionStore {
        let override = ProcessInfo.processInfo.environment["FILEFAN_DATA_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FileFan", isDirectory: true)
        return SessionStore(directory: directory)
    }
    public func load() -> SessionLoadResult {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(state: SessionState(), warning: nil) }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 4_000_000 else { throw SessionError.invalid }
            let data = try Data(contentsOf: file)
            if let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int, version > 1 {
                return .init(state: SessionState(), warning: "This shelf was saved by a newer FileFan version. Its state is preserved at \(file.path); changes cannot be saved by this version.")
            }
            let state = try JSONDecoder().decode(SessionState.self, from: data)
            try validate(state)
            return .init(state: state, warning: nil)
        } catch {
            let quarantine = directory.appendingPathComponent("session-corrupt-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: file, to: quarantine)
                return .init(state: SessionState(), warning: "Previous shelf state was unreadable. It was preserved at \(quarantine.path).")
            } catch {
                return .init(state: SessionState(), warning: "Previous shelf state could not be read or preserved. Check \(file.path).")
            }
        }
    }
    public func save(_ state: SessionState) throws {
        try validate(state)
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 4_000_000 else { throw SessionError.invalid }
            let data = try Data(contentsOf: file)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? Int, version > 1 { throw SessionError.futureVersion }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
    private func validate(_ state: SessionState) throws {
        guard state.version == 1, state.files.count <= 2000, state.selection.count <= 2000,
              state.files.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && $0.path.utf8.count < 32768 }),
              state.maxDimension.count < 100, state.quality.isFinite, (1...100).contains(state.quality), state.pageRange.count <= 1024 else { throw SessionError.invalid }
        if let frame = state.windowFrame {
            guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else { throw SessionError.invalid }
        }
        if let dock = state.dock { guard dock.offset.isFinite, dock.screenID.count < 1000 else { throw SessionError.invalid } }
    }
    private enum SessionError: LocalizedError {
        case invalid, futureVersion
        var errorDescription: String? {
            switch self {
            case .invalid: return "The shelf state exceeds limits or has invalid fields."
            case .futureVersion: return "A newer FileFan version saved this shelf. Its existing state was preserved; use that version to save changes."
            }
        }
    }
}
