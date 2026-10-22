import Foundation
import Testing
@testable import FileFanCore

final class FileShelfTests {
    private var directory: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func testIntakeAcceptsFilesAndDirectoriesInOrderAndRejectsRemoteAndMissingURLs() throws {
        let first = directory.appendingPathComponent("one.txt")
        try Data("keep me".utf8).write(to: first)
        let missing = directory.appendingPathComponent("missing.txt")
        let remote = URL(string: "https://example.com/file.png")!

        let result = FileIntake.inspect([first, directory, remote, missing, first])

        expectEqual(result.accepted.map(\.url), [first, directory].map { $0.resolvingSymlinksInPath().standardizedFileURL })
        expectEqual(result.accepted.map(\.displayName), ["one.txt", directory.lastPathComponent])
        expectEqual(result.rejected.map(\.url), [remote, missing])
        expectTrue(result.rejected.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func testCanonicalSymlinkIdentityDeduplicatesAliases() throws {
        let original = directory.appendingPathComponent("original.txt")
        let alias = directory.appendingPathComponent("alias.txt")
        try Data("same file".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)

        let result = FileIntake.inspect([alias, original])

        expectEqual(result.accepted.count, 1)
        expectEqual(result.accepted.first?.id, original.resolvingSymlinksInPath().path)
        expectEqual(result.accepted.first?.url, original.resolvingSymlinksInPath())
    }

    @Test func testShelfKeepsInsertionOrderAndCopiesOnlySelectedPaths() throws {
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        var shelf = FileShelf()

        expectEqual(shelf.add([first]).accepted.count, 1)
        expectEqual(shelf.add([second, first]).accepted.map(\.displayName), ["second.txt"])
        let canonicalFirst = first.resolvingSymlinksInPath().path
        let canonicalSecond = second.resolvingSymlinksInPath().path
        expectEqual(shelf.pathText(), canonicalFirst + "\n" + canonicalSecond)
        expectEqual(shelf.pathText(for: [canonicalSecond]), canonicalSecond)
        expectEqual(shelf.pathText(for: []), "")
    }

    @Test func testRemoveAndClearDiscardReferencesWithoutDeletingSources() throws {
        let file = directory.appendingPathComponent("source.txt")
        let bytes = Data("irreplaceable".utf8)
        try bytes.write(to: file)
        var shelf = FileShelf()
        shelf.add([file, directory])

        shelf.remove(ids: [file.resolvingSymlinksInPath().path])
        expectEqual(shelf.items.map(\.displayName), [directory.lastPathComponent])
        shelf.clear()
        expectTrue(shelf.items.isEmpty)
        expectEqual(try Data(contentsOf: file), bytes)
        expectTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func testUnreadableFileIsRejected() throws {
        let file = directory.appendingPathComponent("unreadable.txt")
        try Data([1]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let result = FileIntake.inspect([file])

        expectTrue(result.accepted.isEmpty)
        expectEqual(result.rejected.map(\.url), [file])
    }
}
