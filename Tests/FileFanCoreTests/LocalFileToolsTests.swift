import Foundation
import Testing
@testable import FileFanCore

struct LocalFileToolsTests {
    @Test func moveRenamesCollisionsKeepsExistingBytesAndReportsOnlyMovedMappings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("same.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: output.appendingPathComponent("same.txt"))
        let missing = directory.appendingPathComponent("missing.txt")
        let result = LocalFileTools.move([source, missing], to: output)
        #expect(result.moved.count == 1)
        #expect(result.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: output.appendingPathComponent("same.txt")) == Data("existing".utf8))
        #expect(try Data(contentsOf: result.moved[0].destination) == Data("source".utf8))
    }
}

struct EditorCopySafetyTests {
    @Test func directoryCopyRejectsSelfAndDescendantBeforeCreatingAnyStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("keep".utf8).write(to: original)
        for destination in [root, child] {
            #expect(throws: (any Error).self) { try LocalFileTools.copy(root, to: destination) }
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["child", "original.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
    }
}
