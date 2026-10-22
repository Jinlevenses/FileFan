import Foundation
import Testing
@testable import FileFanCore

struct SessionStateTests {
    @Test func atomicSaveRestoresImmediatelyWithoutTerminationAndKeepsMissingURLs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let missing = URL(fileURLWithPath: "/missing/file.txt")
        var state = SessionState()
        state.files = [missing]
        state.selection = [missing.path]
        state.dock = DockPlacement(edge: .right, offset: 0.4, screenID: "display")
        try store.save(state)
        let restored = SessionStore(directory: directory).load()
        #expect(restored.state.files == [missing])
        #expect(restored.state.dock == state.dock)
        #expect(restored.warning == nil)
    }
    @Test func corruptStateIsQuarantinedAndNeverCrashes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("bad json".utf8).write(to: directory.appendingPathComponent("session.json"))
        let restored = SessionStore(directory: directory).load()
        #expect(restored.state.files.isEmpty)
        #expect(restored.warning != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("session-corrupt-") })
    }
}

struct SessionValidationTests {
    @Test func versionOneWithoutNewSettingsUsesDefaults() throws {
        let state = try JSONDecoder().decode(SessionState.self, from: Data(#"{"version":1,"files":[]}"#.utf8))
        #expect(state.quality == 90)
        #expect(state.gesturesEnabled)
        #expect(state.pageRange.isEmpty)
    }
    @Test func unsupportedSchemaAndOversizedListsAreRejectedWithoutChangingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try store.save(SessionState())
        let original = try Data(contentsOf: store.file)
        var state = SessionState()
        state.files = (0...2000).map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(throws: (any Error).self) { try store.save(state) }
        #expect(try Data(contentsOf: store.file) == original)
        state = SessionState(); state.version = 999
        #expect(throws: (any Error).self) { try store.save(state) }
    }
}

struct FutureSessionTests {
    @Test func newerSchemaRemainsAtOriginalPathAndCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let future = Data(#"{"version":99,"futurePayload":"preserve me"}"#.utf8)
        try future.write(to: store.file)
        #expect(store.load().warning != nil)
        #expect(try Data(contentsOf: store.file) == future)
        #expect(throws: (any Error).self) { try store.save(SessionState()) }
        #expect(try Data(contentsOf: store.file) == future)
    }
}
