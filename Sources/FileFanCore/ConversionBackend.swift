import Darwin
import Foundation

public actor ConversionBackend {
    private let executableURL: URL?
    private let dataDirectory: URL
    private var routes: [String: RouteAvailability] = [:]
    private var capabilityTask: Task<CapabilitiesManifest, Error>?
    private var capabilities: CapabilitiesManifest?

    public init(executableURL: URL?, dataDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.dataDirectory = dataDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("FileFanBackend", isDirectory: true)
    }

    public nonisolated static func bundled() -> ConversionBackend {
        let resources = Bundle.main.resourceURL
        let candidates = ["filee-cli", "Filee.Cli", "filee"].compactMap { resources?.appendingPathComponent("Backend/" + $0) }
        return ConversionBackend(executableURL: candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    public func formats() -> [ConversionFormat] { ConversionCatalog.formats }

    public func refreshCapabilities() { routes.removeAll(); capabilityTask = nil; capabilities = nil }

    public func targets(for sourceURLs: [URL]) async -> [ConversionTarget] {
        await loadCapabilities()
        let sourceFormats = sourceURLs.map { ConversionCatalog.format(for: $0) }
        let known = Set(sourceFormats.compactMap { $0?.id })
        var availability: [String: RouteAvailability] = [:]
        for source in known.sorted() { availability[source] = await probe(source) }
        let archiveReady: Bool
        if let capabilities {
            archiveReady = capabilities.archiveCombiner
        } else if known.isEmpty, !sourceURLs.isEmpty {
            archiveReady = await probe("zip").error == nil
        } else {
            archiveReady = !availability.isEmpty && availability.values.allSatisfy { $0.error == nil }
        }
        let inputOK = !sourceURLs.isEmpty && sourceFormats.allSatisfy { $0 != nil }
        let backendOK = executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        func reason(available: Bool, optional: Bool = false) -> String? {
            if available { return nil }
            if !backendOK { return ConversionBackendError.unavailable.errorDescription }
            if !inputOK { return "선택한 파일의 형식을 식별할 수 없습니다." }
            if availability.values.contains(where: { $0.error != nil }) { return availability.values.compactMap(\.error).first }
            return optional ? "이 경로에 필요한 선택 엔진이 포함되어 있지 않습니다." : "선택한 모든 파일에서 이 형식으로 변환하는 경로가 없습니다."
        }
        var targets = ConversionCatalog.formats.filter(\.writable).map { target in
            let supported = inputOK && known.allSatisfy { availability[$0]?.current.contains(target.id) == true }
            let optional = known.allSatisfy { availability[$0]?.all.contains(target.id) == true }
            return ConversionTarget(id: "format:" + target.id, name: target.name, category: target.category, targetFormatID: target.id,
                                    isAvailable: supported, unavailableReason: reason(available: supported, optional: optional))
        }
        let sccAvailable = inputOK && backendOK && known.allSatisfy { availability[$0]?.current.contains("srt") == true || $0 == "srt" }
        targets.append(ConversionTarget(id: "format:scc", name: "SCC (CEA-608)", category: "Subtitle", targetFormatID: "scc",
                                        isAvailable: sccAvailable, unavailableReason: reason(available: sccAvailable)))
        for action in ConversionCatalog.actions {
            let eligible = (action.id == "zip-all" ? !sourceURLs.isEmpty : inputOK) && (action.sources.map { known.isSubset(of: $0) } ?? true)
            let supported = eligible && backendOK && (action.id != "zip-all" || archiveReady) && known.allSatisfy { source in
                guard let route = availability[source], route.error == nil else { return false }
                if action.id == "zip-all" { return capabilities?.archiveCombiner ?? true }
                if capabilities != nil {
                    if action.id == "merge-pdf", capabilities?.pdfMerger != true { return false }
                    return route.current.contains(action.target)
                }
                if ["pdf-split", "compress-pdf", "pdf-pages"].contains(action.id) { return source == "pdf" }
                if action.id == "merge-pdf" && source == "pdf" { return true }
                if action.id == "extract" {
                    return ConversionCatalog.formats.first { $0.id == source }?.category == "Archive"
                        && (route.current.contains("zip") || (source == "zip" && !route.current.isDisjoint(with: ["7z", "tar", "tgz"])))
                }
                if action.target == source {
                    // The upstream human-readable route list deliberately omits identity targets.
                    if action.category == "Image" { return route.current.contains("jpg") || route.current.contains("webp") }
                    if action.category == "Video" { return route.current.contains("mkv") || route.current.contains("webm") }
                }
                return route.current.contains(action.target)
            }
            targets.append(ConversionTarget(id: "preset:" + action.id, name: action.name, category: action.category,
                                            targetFormatID: action.target, presetID: action.id, isAvailable: supported,
                                            unavailableReason: reason(available: supported)))
        }
        return targets
    }

    private func loadCapabilities() async {
        guard capabilities == nil, let executableURL else { return }
        let bridge = executableURL.deletingLastPathComponent().appendingPathComponent("filefan-caps")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else { return }
        if capabilityTask == nil {
            do {
                let directory = try makeJobDirectory()
                let variables = environment(data: directory)
                capabilityTask = Task {
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let response = try await BackendProcess.run(executable: bridge, arguments: [], environment: variables, timeout: 120)
                    guard response.status == 0 else { throw ConversionBackendError.processFailed(String(decoding: response.standardError, as: UTF8.self)) }
                    return try JSONDecoder().decode(CapabilitiesManifest.self, from: response.standardOutput)
                }
            } catch { return }
        }
        do {
            if let manifest = try await capabilityTask?.value {
                guard manifest.schemaVersion == 1 else { return }
                capabilities = manifest
                for format in manifest.formats { routes[format.id] = .init(current: Set(format.current), optional: Set(format.optional)) }
            }
        } catch { /* Older CLI distributions still have the human-readable route probe. */ }
    }

    private func probe(_ source: String) async -> RouteAvailability {
        if let cached = routes[source] { return cached }
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else { return .init(error: ConversionBackendError.unavailable.errorDescription) }
        do {
            let directory = try makeJobDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try await BackendProcess.run(executable: executableURL, arguments: ["formats", source], environment: environment(data: directory), timeout: 45)
            guard result.status == 0 else { throw ConversionBackendError.processFailed(String(decoding: result.standardError, as: UTF8.self)) }
            let parsed = try RouteAvailability.parse(result.standardOutput)
            routes[source] = parsed
            return parsed
        } catch { return .init(error: error.localizedDescription) }
    }

    public func convert(sourceURLs: [URL], outputDirectory: URL, target: ConversionTarget, options: ConversionOptions = .init()) async throws -> ConversionBatchResult {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw ConversionBackendError.unavailable }
        guard !sourceURLs.isEmpty, sourceURLs.count <= 10_000 else { throw ConversionBackendError.invalidInput("변환할 파일을 선택하세요. 한 번에 최대 10,000개입니다.") }
        guard (1...100).contains(options.quality), options.maxPixelDimension.map({ (1...100_000).contains($0) }) ?? true,
              options.pageRange.count <= 1024,
              options.pageRange.isEmpty || options.pageRange.range(of: "^[1-9][0-9]*(?:-[1-9][0-9]*)?(?:,[1-9][0-9]*(?:-[1-9][0-9]*)?)*$", options: .regularExpression) != nil else { throw ConversionBackendError.invalidOptions }
        let intake = FileIntake.inspect(sourceURLs)
        guard intake.rejected.isEmpty, intake.accepted.count == sourceURLs.count else { throw ConversionBackendError.invalidInput(intake.rejected.first?.reason ?? "중복 파일을 제거하세요.") }
        let sources = try intake.accepted.map { item -> URL in
            guard try item.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ConversionBackendError.invalidInput("폴더 대신 변환할 파일을 선택하세요.") }
            return item.url.resolvingSymlinksInPath().standardizedFileURL
        }
        guard Set(sources).count == sources.count else { throw ConversionBackendError.invalidInput("같은 파일은 한 번만 선택하세요.") }
        guard outputDirectory.isFileURL else { throw ConversionBackendError.invalidInput("로컬 출력 폴더를 선택하세요.") }
        let destination = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              FileManager.default.isWritableFile(atPath: destination.path) else { throw ConversionBackendError.invalidInput("쓰기 가능한 출력 폴더를 선택하세요.") }
        let allowed = await targets(for: sources)
        guard let selected = allowed.first(where: { $0.id == target.id }), selected.isAvailable,
              selected.targetFormatID == target.targetFormatID, selected.presetID == target.presetID else {
            throw ConversionBackendError.invalidInput(allowed.first { $0.id == target.id }?.unavailableReason ?? "지원하지 않는 변환입니다.")
        }
        try Task.checkCancellation()
        let job = try makeJobDirectory()
        defer { try? FileManager.default.removeItem(at: job) }
        // Stage on the destination volume so publication is an atomic exclusive rename.
        let stage = destination.appendingPathComponent(".filefan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let normalizer = selected.targetFormatID == "scc"
            ? ConversionTarget(id: "format:srt", name: selected.name, category: "Subtitle", targetFormatID: "srt", isAvailable: true) : selected
        let preset = Self.preset(for: normalizer, options: options)
        try JSONSerialization.data(withJSONObject: [preset], options: [.prettyPrinted, .sortedKeys]).write(to: job.appendingPathComponent("presets.json"), options: .atomic)
        // History stays disabled and no upstream GUI, updater or integration is invoked.
        try JSONSerialization.data(withJSONObject: ["keepHistory": false, "schemaVersion": 20]).write(to: job.appendingPathComponent("settings.json"), options: .atomic)
        let response = try await BackendProcess.run(executable: executableURL,
                                                    arguments: ["convert"] + sources.map(\.path) + ["--preset", "filefan-custom", "-o", stage.path, "--json"],
                                                    environment: environment(data: job), timeout: 3600)
        guard response.status == 0 || response.status == 1 else {
            throw ConversionBackendError.processFailed("변환 엔진 오류 (\(response.status)): " + String(decoding: response.standardError.prefix(4096), as: UTF8.self))
        }
        var parsed = try BackendJSON.parse(response.standardOutput, expectedSources: Set(sources), stage: stage,
                                          allowsCombinedOutputs: ["merge-pdf", "zip-all"].contains(selected.presetID ?? ""), expectedTarget: normalizer.targetFormatID)
        if selected.targetFormatID == "scc" {
            parsed = parsed.map { file in
                guard file.error == nil, let srt = file.outputs.first else { return file }
                defer { for path in file.outputs { try? FileManager.default.removeItem(at: path) } }
                do {
                    let output = srt.deletingPathExtension().appendingPathExtension("scc")
                    let originalSRT = file.source.pathExtension.lowercased() == "srt" ? try? Data(contentsOf: file.source) : nil
                    let contents = try originalSRT.flatMap { String(data: $0, encoding: .utf8) != nil ? $0 : nil } ?? Data(contentsOf: srt)
                    try SCCWriter.write(srt: contents).write(to: output, options: .withoutOverwriting)
                    return BackendJSON.Entry(source: file.source, outputs: [output], error: nil, notice: file.notice)
                } catch { return BackendJSON.Entry(source: file.source, outputs: [], error: error.localizedDescription) }
            }
        }
        try Task.checkCancellation()
        var published: [URL: URL] = [:]
        let outputs = Set(parsed.flatMap(\.outputs))
        if outputs.count > 1 {
            // Keep sibling references (OBJ/MTL/textures) intact and publish the batch in one atomic operation.
            let safeName = "FileFan " + selected.targetFormatID.uppercased()
            let bundle = try Self.publish(stage, to: destination, preferredName: safeName)
            for output in outputs {
                let relative = String(output.path.dropFirst(stage.path.count + 1))
                published[output] = bundle.appendingPathComponent(relative)
            }
        } else if let output = outputs.first {
            published[output] = try Self.publish(output, to: destination)
        }
        return ConversionBatchResult(files: parsed.map { file in
            ConversionFileResult(sourceURL: file.source, outputURLs: file.outputs.compactMap { published[$0] }, error: file.error, notice: file.notice)
        })
    }

    private func makeJobDirectory() throws -> URL {
        let directory = dataDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func environment(data: URL) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["FILEE_DATA_DIR"] = data.path
        result["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        result["DOTNET_NOLOGO"] = "1"
        if let executableURL {
            let resources = executableURL.deletingLastPathComponent().appendingPathComponent("engines/ghostscript/share/ghostscript")
            let versions = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
            if let version = ([resources] + versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }))
                .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Resource/Init").path) }) {
                result["GS_LIB"] = ["Resource/Init", "lib", "Resource/Font", "fonts"].map { version.appendingPathComponent($0).path }.joined(separator: ":")
                result["GS_FONTPATH"] = ["Resource/Font", "fonts"].map { version.appendingPathComponent($0).path }.joined(separator: ":")
            }
        }
        return result
    }

    static func preset(for target: ConversionTarget, options: ConversionOptions) -> [String: Any] {
        var image: [String: Any] = ["quality": options.quality]
        if let size = options.maxPixelDimension { image["resize"] = "LongEdge"; image["longEdge"] = size }
        var pdf: [String: Any] = ["pageRange": options.pageRange]
        var media: [String: Any] = [:], archive: [String: Any] = [:]
        switch target.presetID {
        case "merge-pdf": pdf["mergeIntoSingle"] = true
        case "pdf-split": pdf["splitPages"] = true
        case "compress-pdf": pdf["compression"] = "Ebook"
        case "mp4-720": media["maxHeight"] = 720; media["quality"] = "Small"
        case "mp4-hevc": media["videoCodec"] = "Hevc"
        case "mp4-av1": media["videoCodec"] = "Av1"
        case "zip-all": archive["combineIntoOne"] = true
        case "grayscale": image["grayscale"] = true
        case "resize": if options.maxPixelDimension == nil { image["resize"] = "LongEdge"; image["longEdge"] = 1920 }
        default: break
        }
        return ["id": "filefan-custom", "name": target.name, "targetFormat": target.targetFormatID,
                "image": image, "pdf": pdf, "media": media, "archive": archive,
                "output": ["conflict": "Rename", "fileNamePattern": "{name}"]]
    }

    private static func publish(_ source: URL, to directory: URL, preferredName: String? = nil) throws -> URL {
        let preferred = preferredName.map { URL(fileURLWithPath: $0) } ?? source
        let stem = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        for suffix in 0..<100_000 {
            let name = suffix == 0 ? preferred.lastPathComponent : stem + " (\(suffix + 1))" + (ext.isEmpty ? "" : "." + ext)
            let output = directory.appendingPathComponent(name)
            let result = source.withUnsafeFileSystemRepresentation { input in
                output.withUnsafeFileSystemRepresentation { destination in renamex_np(input!, destination!, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return output }
            if errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: output.path]) }
        }
        throw ConversionBackendError.invalidInput("출력 이름 충돌이 너무 많습니다.")
    }
}

struct RouteAvailability {
    var current: Set<String> = []
    var optional: Set<String> = []
    var error: String?
    var all: Set<String> { current.union(optional) }
    static func parse(_ data: Data) throws -> Self {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        guard lines.first?.contains(" converts to:") == true, lines.count >= 2 else { throw ConversionBackendError.invalidResponse("변환 경로 응답을 읽을 수 없습니다.") }
        func values(_ line: String) -> Set<String> {
            guard !line.contains("(nothing") else { return [] }
            return Set(line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        let optionalIndex = lines.firstIndex { $0.hasPrefix("With optional engines") }
        return Self(current: values(lines[1]), optional: optionalIndex.flatMap { $0 + 1 < lines.count ? values(lines[$0 + 1]) : nil } ?? [])
    }
}

private struct CapabilitiesManifest: Decodable, Sendable {
    var schemaVersion: Int
    var formats: [Format]
    var archiveCombiner: Bool
    var pdfMerger: Bool
    struct Format: Decodable, Sendable { var id: String; var current: [String]; var optional: [String] }
}

enum BackendJSON {
    struct Entry {
        let source: URL, outputs: [URL], error: String?, notice: String?
        init(source: URL, outputs: [URL], error: String?, notice: String? = nil) {
            self.source = source; self.outputs = outputs; self.error = error; self.notice = notice
        }
    }
    private struct Response: Decodable {
        var target: String?
        var converted: Int, skipped: Int, failed: Int
        var files: [File]
        struct File: Decodable { var source: String, state: String, outputs: [String], error: String?, notice: String? }
    }
    static func parse(_ data: Data, expectedSources: Set<URL>, stage: URL, allowsCombinedOutputs: Bool = false, expectedTarget: String? = nil) throws -> [Entry] {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ConversionBackendError.invalidResponse("변환 엔진의 JSON 응답이 올바르지 않습니다.") }
        guard expectedTarget.map({ response.target == $0 }) ?? true,
              response.converted >= 0, response.skipped >= 0, response.failed >= 0,
              response.converted + response.skipped + response.failed == response.files.count,
              response.converted == response.files.filter({ $0.state == "done" }).count,
              response.skipped == response.files.filter({ $0.state == "skipped" }).count,
              response.failed == response.files.filter({ ["failed", "cancelled"].contains($0.state) }).count,
              response.files.count == expectedSources.count,
              Set(response.files.map { URL(fileURLWithPath: $0.source).resolvingSymlinksInPath().standardizedFileURL }) == expectedSources else {
            throw ConversionBackendError.invalidResponse("파일별 변환 결과와 요청한 원본 목록이 일치하지 않습니다.")
        }
        let root = stage.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let combined = response.files.filter { $0.state == "done" }.flatMap(\.outputs)
        return try response.files.map { file in
            let paths = file.state == "done" && file.outputs.isEmpty && allowsCombinedOutputs ? combined : file.outputs
            let outputs = try paths.map { path -> URL in
                let output = URL(fileURLWithPath: path).standardizedFileURL
                guard output.path.hasPrefix(root), output.resolvingSymlinksInPath().path.hasPrefix(root),
                      FileManager.default.fileExists(atPath: output.path) else { throw ConversionBackendError.invalidResponse("변환 엔진이 출력 폴더 밖의 경로를 반환했습니다.") }
                let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
                var validate = [output]
                if let enumerator = FileManager.default.enumerator(at: output, includingPropertiesForKeys: Array(keys)) {
                    validate += enumerator.allObjects.compactMap { $0 as? URL }
                }
                for entry in validate {
                    let values = try entry.resourceValues(forKeys: keys)
                    guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                        throw ConversionBackendError.invalidResponse("출력에 심볼릭 링크 또는 특수 파일이 포함되어 있습니다.")
                    }
                    if values.isRegularFile == true {
                        let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
                        guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                            throw ConversionBackendError.invalidResponse("원본과 연결될 수 있는 하드 링크 출력은 저장할 수 없습니다.")
                        }
                    }
                }
                return output
            }
            guard file.state != "done" || !outputs.isEmpty else { throw ConversionBackendError.invalidResponse("성공 결과에 출력 파일이 없습니다.") }
            return Entry(source: URL(fileURLWithPath: file.source).resolvingSymlinksInPath(), outputs: file.state == "done" ? outputs : [],
                         error: file.state == "done" ? nil : (file.error ?? "변환하지 못했습니다 (\(file.state))."), notice: file.notice)
        }
    }
}
