import Foundation
import Testing
@testable import FileFanCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_MEDIA_TESTS"] == "1"))
struct MediaToolsTests {
    @Test func realCropMuteSpeedSnapshotAndSplitPreserveInput() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appendingPathComponent("dist/FileFan.app/Contents/Resources/Backend/engines/ffmpeg")
        let processor = MediaTools(engineDirectory: engine)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("av.mp4")
        let generated = try await BackendProcess.run(executable: engine.appendingPathComponent("ffmpeg"), arguments: ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=10:duration=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=16000:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source.path], environment: ProcessInfo.processInfo.environment, timeout: 20)
        #expect(generated.status == 0)
        let original = try Data(contentsOf: source)
        let info = try await processor.probe(source)
        #expect(info.hasAudio)
        let cropped = try await processor.process(source, directory: directory, tool: .crop, options: .init(rect: CGRect(x: 0, y: 0, width: 16, height: 16)))
        let cropInfo = try await processor.probe(cropped[0])
        #expect(cropInfo.width == 16 && cropInfo.height == 16)
        let muted = try await processor.process(source, directory: directory, tool: .mute, options: .init())
        #expect(try await !processor.probe(muted[0]).hasAudio)
        let faster = try await processor.process(source, directory: directory, tool: .speed, options: .init(speed: 2))
        #expect(try await processor.probe(faster[0]).duration < info.duration)
        let shot = try await processor.process(source, directory: directory, tool: .snapshot, options: .init())
        #expect(try NativeImageTools.dimensions(shot[0]).width > 0)
        let parts = try await processor.process(source, directory: directory, tool: .split, options: .init(start: info.duration / 2))
        #expect(parts.count == 2)
        #expect(try Data(contentsOf: source) == original)
        #expect(throws: (any Error).self) { try MediaTools.validate(.init(speed: .infinity), tool: .speed, info: info) }
    }
    @Test func audioAlbumArtIsNotTreatedAsVideoAndIsNotMappedToOutput() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appendingPathComponent("dist/FileFan.app/Contents/Resources/Backend/engines/ffmpeg")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cover.mp3")
        let result = try await BackendProcess.run(executable: engine.appendingPathComponent("ffmpeg"), arguments: ["-nostdin", "-loglevel", "error", "-i", root.appendingPathComponent("artifacts/evidence/backend-fixtures/inputs/audio.wav").path, "-i", root.appendingPathComponent("artifacts/evidence/backend-fixtures/inputs/image.png").path, "-map", "0:a", "-map", "1:v", "-c:a", "libmp3lame", "-c:v", "mjpeg", "-id3v2_version", "3", "-disposition:v", "attached_pic", source.path], environment: ProcessInfo.processInfo.environment, timeout: 20)
        #expect(result.status == 0)
        let processor = MediaTools(engineDirectory: engine)
        let info = try await processor.probe(source)
        #expect(info.hasAudio && !info.hasVideo)
        let outputs = try await processor.process(source, directory: directory, tool: .compress, options: .init())
        #expect(outputs[0].pathExtension == "m4a")
        #expect(try await !processor.probe(outputs[0]).hasVideo)
    }

}
