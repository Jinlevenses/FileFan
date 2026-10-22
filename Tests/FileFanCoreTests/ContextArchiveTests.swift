import Foundation
import Testing
@testable import FileFanCore

struct ContextArchiveTests {
    @Test func folderZIPPreservesUnknownNestedAndEmptyEntriesAndRejectsDescendantOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("SelectedFolder"), directory = root.appendingPathComponent("out")
        let nested = source.appendingPathComponent("nested"), empty = source.appendingPathComponent("empty")
        for folder in [nested, empty, directory] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: nested.appendingPathComponent("keep.unknown"))
        let zip = try await LocalFileTools.createFolderZIP([source], to: directory)
        let listing = try await BackendProcess.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", zip.path], environment: ProcessInfo.processInfo.environment, timeout: 10)
        let names = String(decoding: listing.standardOutput, as: UTF8.self)
        #expect(names.contains("SelectedFolder/nested/keep.unknown") && names.contains("SelectedFolder/empty/"))
        #expect(!names.contains("-copy"))
        #expect(try Data(contentsOf: nested.appendingPathComponent("keep.unknown")) == Data("original".utf8))
        for output in [source, nested] {
            do { _ = try await LocalFileTools.createFolderZIP([source], to: output); Issue.record("A source folder cannot contain its own ZIP output.") }
            catch { #expect((try FileManager.default.contentsOfDirectory(atPath: output.path)).allSatisfy { !$0.hasPrefix(".filefan-") }) }
        }
    }
}
