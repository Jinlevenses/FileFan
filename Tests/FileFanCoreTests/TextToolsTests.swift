import Foundation
import Testing
@testable import FileFanCore

struct TextToolsTests {
    @Test func koreanCP949DecodesToUTF8AndPreservesSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("subtitle.srt")
        let korean = "1\n00:00:00,000 --> 00:00:01,000\n안녕하세요 광주\n"
        let bytes = try #require(korean.data(using: NativeTextTools.cp949))
        try bytes.write(to: source)
        let output = try NativeTextTools.exportUTF8(source, directory: directory, encoding: NativeTextTools.cp949)
        #expect(try String(contentsOf: output, encoding: .utf8) == korean)
        #expect(try Data(contentsOf: source) == bytes)
    }
}
