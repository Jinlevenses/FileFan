import Darwin
import Foundation

public struct FileMove: Sendable { public let source: URL; public let destination: URL }
public struct FileMoveResult: Sendable { public var moved: [FileMove] = []; public var failures: [String] = [] }
public enum LocalFileTools {
    public static func validated(_ urls: [URL]) throws -> [URL] {
        let result = FileIntake.inspect(urls)
        guard !urls.isEmpty, urls.count <= 2000, result.rejected.isEmpty, result.accepted.count == urls.count else {
            throw ConversionBackendError.invalidInput(result.rejected.map { $0.url.lastPathComponent + ": " + $0.reason }.joined(separator: "\n").isEmpty ? "Choose accessible, unique local files or folders." : result.rejected.map(\.reason).joined(separator: "\n"))
        }
        return result.accepted.map(\.url)
    }
    public static func directory(_ url: URL) throws -> URL {
        let directory = try validated([url])[0]
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true, FileManager.default.isWritableFile(atPath: directory.path) else { throw ConversionBackendError.invalidInput("Choose a writable local output folder.") }
        return directory
    }
    public static func publish(_ staged: URL, to directory: URL, name: String) throws -> URL {
        let preferred = URL(fileURLWithPath: name)
        for suffix in 0..<10000 {
            let stem = preferred.deletingPathExtension().lastPathComponent
            let ext = preferred.pathExtension
            let candidate = suffix == 0 ? name : stem + " (\(suffix + 1))" + (ext.isEmpty ? "" : "." + ext)
            let output = directory.appendingPathComponent(candidate)
            let status = staged.withUnsafeFileSystemRepresentation { input in output.withUnsafeFileSystemRepresentation { destination in renamex_np(input!, destination!, UInt32(RENAME_EXCL)) } }
            if status == 0 { return output }
            if errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: output.path]) }
        }
        throw ConversionBackendError.invalidInput("Too many output name collisions.")
    }
    public static func write(_ data: Data, source: URL, directory: URL, suffix: String, extension ext: String) throws -> URL {
        let output = try self.directory(directory)
        let temporary = output.appendingPathComponent(".filefan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        return try publish(temporary, to: output, name: source.deletingPathExtension().lastPathComponent + "-" + suffix + "." + ext)
    }
    public static func copy(_ source: URL, to directory: URL, suffix: String = "copy") throws -> URL {
        let input = try validated([source])[0], output = try self.directory(directory)
        if (try input.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
           output == input || output.path.hasPrefix(input.path + "/") {
            throw ConversionBackendError.invalidInput("The destination cannot be the selected folder or one of its descendants.")
        }
        let temporary = output.appendingPathComponent(".filefan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: input, to: temporary)
        let name = input.deletingPathExtension().lastPathComponent + "-" + suffix + (input.pathExtension.isEmpty ? "" : "." + input.pathExtension)
        return try publish(temporary, to: output, name: name)
    }
    public static func move(_ urls: [URL], to directory: URL) -> FileMoveResult {
        var result = FileMoveResult()
        do {
            let output = try self.directory(directory)
            for (index, source) in urls.enumerated() {
                if Task.isCancelled {
                    result.failures += urls.dropFirst(index).map { $0.lastPathComponent + ": move cancelled before this item." }
                    break
                }
                do {
                    let input = try validated([source])[0]
                    guard input != output, !output.path.hasPrefix(input.path + "/"), input.deletingLastPathComponent() != output else { throw ConversionBackendError.invalidInput("The item is already in this folder, or the destination is inside it.") }
                    var destination: URL?
                    for index in 0..<10000 {
                        let stem = input.deletingPathExtension().lastPathComponent, ext = input.pathExtension
                        let name = index == 0 ? input.lastPathComponent : stem + " (\(index + 1))" + (ext.isEmpty ? "" : "." + ext)
                        let candidate = output.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: candidate.path) { continue }
                        do { try FileManager.default.moveItem(at: input, to: candidate); destination = candidate; break }
                        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
                    }
                    guard let destination else { throw ConversionBackendError.invalidInput("Too many destination collisions.") }
                    result.moved.append(.init(source: input, destination: destination))
                } catch { result.failures.append(source.lastPathComponent + ": " + error.localizedDescription) }
            }
        } catch { result.failures.append(error.localizedDescription) }
        return result
    }
    /// The CLI expands folders into known formats only; ditto preserves nested, unknown and empty entries.
    public static func createFolderZIP(_ urls: [URL], to directory: URL) async throws -> URL {
        let inputs = try validated(urls), output = try self.directory(directory)
        for input in inputs where (try input.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            guard output != input, !output.path.hasPrefix(input.path + "/") else { throw ConversionBackendError.invalidInput("ZIP output must be outside every selected folder.") }
        }
        let stage = output.appendingPathComponent(".filefan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let contents = stage.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        for input in inputs {
            try Task.checkCancellation()
            let temporary = stage.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: input, to: temporary)
            _ = try publish(temporary, to: contents, name: input.lastPathComponent)
        }
        let archive = stage.appendingPathComponent("Files.zip")
        let result = try await BackendProcess.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", contents.path, archive.path], environment: ProcessInfo.processInfo.environment, timeout: 300)
        guard result.status == 0 else { throw ConversionBackendError.processFailed(String(decoding: result.standardError.prefix(8000), as: UTF8.self)) }
        try Task.checkCancellation()
        return try publish(archive, to: output, name: inputs.count == 1 ? inputs[0].lastPathComponent + ".zip" : "Files.zip")
    }

}
