import Foundation
import Testing
@testable import FileFanCore

@Suite struct SCCWriterTests {
    @Test func writesOddParityAndRejectsUnrepresentableCaptions() throws {
        let data = try SCCWriter.write(srt: Data("1\n00:00:02,000 --> 00:00:04,000\nHello world!\n".utf8))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("Scenarist_SCC V1.0\n"))
        for line in text.components(separatedBy: .newlines) where line.contains("\t") {
            for word in line.components(separatedBy: "\t")[1].split(separator: " ") {
                let value = try #require(UInt16(word, radix: 16))
                #expect(UInt8(value >> 8).nonzeroBitCount % 2 == 1)
                #expect(UInt8(value & 255).nonzeroBitCount % 2 == 1)
            }
        }
        #expect(SCCWriter.timecode(SCCWriter.frame(60_000)) == "00:00:59:28")
        for caption in ["한글", String(repeating: "x", count: 33), "<i>Hello</i>"] {
            #expect(throws: (any Error).self) { try SCCWriter.write(srt: Data("1\n00:00:02,000 --> 00:00:04,000\n\(caption)\n".utf8)) }
        }
        #expect(throws: (any Error).self) { try SCCWriter.write(srt: Data("1\n00:00:00,000 --> 00:00:01,000\nNo preroll\n".utf8)) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_BACKEND_EXECUTABLE"] != nil))
    func actualUpstreamReaderRoundTripsTextAndCaptionTiming() async throws {
        guard let executable = ProcessInfo.processInfo.environment["FILEFAN_BACKEND_EXECUTABLE"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileFanSCC-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let srt = root.appendingPathComponent("captions.srt")
        let plain = "Hello * _ {test} café!\nSecond line"
        try Data("1\n00:00:02,000 --> 00:00:04,000\n\(plain)\n\n2\n00:00:06,000 --> 00:00:08,000\nEncore ®®\n\n3\n00:00:08,000 --> 00:00:10,000\nAdjacent\n".utf8).write(to: srt)
        let backend = ConversionBackend(executableURL: URL(fileURLWithPath: executable), dataDirectory: root.appendingPathComponent("data"))
        let target = try #require(await backend.targets(for: [srt]).first { $0.id == "format:scc" && $0.isAvailable })
        let encoded = try await backend.convert(sourceURLs: [srt], outputDirectory: root, target: target)
        #expect(encoded.successCount == 1, "\(encoded.files.compactMap(\.error))")
        let scc = try #require(encoded.outputURLs.first)
        let srtTarget = try #require(await backend.targets(for: [scc]).first { $0.id == "format:srt" && $0.isAvailable })
        let decoded = try await backend.convert(sourceURLs: [scc], outputDirectory: root, target: srtTarget)
        let output = try String(contentsOf: #require(decoded.outputURLs.first), encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        #expect(output.contains(plain))
        #expect(output.contains("Encore ®®"))
        // Filee's independent SCC decoder schedules EOC/EDM at 30000/1001 frames/s.
        #expect(output.contains("00:00:02,002 --> 00:00:04,004"))
        #expect(output.contains("00:00:06,006 --> 00:00:08,008"))
        #expect(output.contains("00:00:08,008 --> 00:00:10,010"))
    }
}
