import AppKit
import Foundation
import Testing
import FileFanCore
@testable import FileFan

@MainActor
struct ContextFileActionTests {
    @Test func partialMoveUpdatesOnlyExistingShelfReferencesAndSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("a.txt"), unrelated = directory.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: source); try Data("b".utf8).write(to: unrelated)
        let store = SessionStore(directory: directory.appendingPathComponent("state"))
        let model = AppModel(errorPresenter: { _, _ in }, sessionStore: store)
        model.add([source]); model.selection = [source.path]
        let result = LocalFileTools.move([source, unrelated], to: output)
        model.applyMoves(result)
        #expect(model.shelf.items.count == 1)
        #expect(model.shelf.items[0].url == result.moved[0].destination)
        #expect(model.selection == [result.moved[0].destination.path])
        #expect(store.load().state.files == [result.moved[0].destination])
    }
    @Test func cancelledMoveStopsBetweenFilesAndKeepsAllShelfReferencesValid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try (0..<100).map { index -> URL in
            let url = directory.appendingPathComponent("file-\(index).txt")
            try Data("original-\(index)".utf8).write(to: url); return url
        }
        let model = AppModel(errorPresenter: { _, _ in })
        model.add(sources); model.moveFiles(sources, to: output); model.cancelConversion()
        for _ in 0..<2000 {
            if !model.isConverting { break }; try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(!model.isConverting)
        #expect(model.shelf.items.count == sources.count)
        #expect(model.shelf.items.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count < sources.count)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_LIVE_PASTEBOARD_TESTS"] == "1"))
    func fileCopyWritesFileURLsWhilePathCopyWritesText() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("fixture".utf8).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try FileClipboard.copyFiles([source], to: board)
        #expect(fileURLs(from: board) == [source.resolvingSymlinksInPath().standardizedFileURL])
        try FileClipboard.copyPaths([source], to: board)
        #expect(board.string(forType: .string) == source.resolvingSymlinksInPath().path)
        #expect(fileURLs(from: board).isEmpty)
    }
}
