import CoreGraphics
import Foundation

public struct MediaInfo: Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var videoStreamIndex: Int?
    public var audioStreamIndex: Int?
    public var frameRate: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var metadata: String
}
public struct MediaToolOptions: Sendable {
    public var start: Double
    public var end: Double?
    public var speed: Double
    public var rect: CGRect?
    public var quality: Int
    public init(start: Double = 0, end: Double? = nil, speed: Double = 1, rect: CGRect? = nil, quality: Int = 75) {
        self.start = start; self.end = end; self.speed = speed; self.rect = rect; self.quality = quality
    }
}
public struct MediaTools: Sendable {
    public let engineDirectory: URL
    public init(engineDirectory: URL) { self.engineDirectory = engineDirectory }
    public static var bundled: MediaTools? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Backend/engines/ffmpeg"), FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("ffmpeg").path) else { return nil }
        return .init(engineDirectory: directory)
    }
    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 600) async throws -> BackendProcessResult {
        let response = try await BackendProcess.run(executable: engineDirectory.appendingPathComponent(executable), arguments: arguments, environment: ProcessInfo.processInfo.environment, timeout: timeout)
        guard response.status == 0 else { throw ConversionBackendError.processFailed(String(decoding: response.standardError.prefix(16000), as: UTF8.self)) }
        return response
    }
    public func probe(_ source: URL) async throws -> MediaInfo {
        let source = try LocalFileTools.validated([source])[0]
        let result = try await run("ffprobe", ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_format", "-show_streams", "-of", "json", source.path], timeout: 20)
        guard let object = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else { throw ConversionBackendError.invalidResponse("Could not read media metadata.") }
        let streams = object["streams"] as? [[String: Any]] ?? []
        let video = streams.first { stream in
            let attached = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0
            return stream["codec_type"] as? String == "video" && attached == 0
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let format = object["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        var width = video?["width"] as? Int ?? 0, height = video?["height"] as? Int ?? 0
        let rotation = (video?["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first ?? 0
        if abs(rotation) % 180 == 90 { swap(&width, &height) }
        let rate = (video?["avg_frame_rate"] as? String ?? "0/1").split(separator: "/").compactMap { Double($0) }
        let frameRate = rate.count == 2 && rate[1] > 0 ? rate[0] / rate[1] : 0
        return .init(duration: duration, width: width, height: height, videoStreamIndex: video?["index"] as? Int, audioStreamIndex: audio?["index"] as? Int, frameRate: frameRate, hasVideo: video != nil, hasAudio: audio != nil, metadata: String(decoding: result.standardOutput.prefix(64000), as: UTF8.self))
    }
    public static func validate(_ options: MediaToolOptions, tool: ContextToolID, info: MediaInfo) throws {
        guard info.duration.isFinite, info.duration > 0, options.start.isFinite, options.start >= 0, options.start < info.duration,
              options.speed.isFinite, (0.25...4).contains(options.speed), (1...100).contains(options.quality) else { throw ConversionBackendError.invalidOptions }
        if let end = options.end { guard end.isFinite, end > options.start, end <= info.duration else { throw ConversionBackendError.invalidOptions } }
        if tool == .split { guard options.start > 0, options.start < info.duration else { throw ConversionBackendError.invalidInput("Split time must be between the start and end of the media.") } }
        if [.crop, .redact].contains(tool) {
            guard info.hasVideo, let rect = options.rect, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), rect == rect.integral,
                  rect.width >= 2, rect.height >= 2, CGRect(x: 0, y: 0, width: info.width, height: info.height).contains(rect),
                  tool != .crop || (Int(rect.width) % 2 == 0 && Int(rect.height) % 2 == 0) else { throw ConversionBackendError.invalidInput("Use an in-frame integer rectangle; crop width and height must be even.") }
        }
    }
    public func process(_ source: URL, directory: URL, tool: ContextToolID, options: MediaToolOptions) async throws -> [URL] {
        let source = try LocalFileTools.validated([source])[0], directory = try LocalFileTools.directory(directory)
        let info = try await probe(source)
        try Self.validate(options, tool: tool, info: info)
        let stage = directory.appendingPathComponent(".filefan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var names: [String] = []
        let ext = tool == .snapshot ? "png" : info.hasVideo ? "mp4" : "m4a"
        let parts = tool == .split ? 2 : 1
        for part in 0..<parts {
            try Task.checkCancellation()
            let name = source.deletingPathExtension().lastPathComponent + "-" + tool.rawValue + (parts > 1 ? "-\(part + 1)" : "") + "." + ext
            let temporary = stage.appendingPathComponent(name)
            var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-protocol_whitelist", "file,pipe", "-i", source.path]
            if let video = info.videoStreamIndex { arguments += ["-map", "0:\(video)"] }
            if tool != .mute && tool != .snapshot, let audio = info.audioStreamIndex { arguments += ["-map", "0:\(audio)"] }
            if tool == .split {
                arguments += part == 0 ? ["-t", String(options.start)] : ["-ss", String(options.start)]
            } else if tool == .trim {
                arguments += ["-ss", String(options.start), "-t", String((options.end ?? info.duration) - options.start)]
            } else if tool == .snapshot { arguments += ["-ss", String(options.start), "-frames:v", "1"] }
            var videoFilters: [String] = []
            if tool == .speed, info.hasVideo { videoFilters.append("setpts=PTS/\(options.speed)") }
            if let rect = options.rect, [.crop, .redact].contains(tool) {
                let x = Int(rect.minX), y = Int(rect.minY), width = Int(rect.width), height = Int(rect.height)
                videoFilters.append(tool == .crop ? "crop=\(width):\(height):\(x):\(y)" : "drawbox=x=\(x):y=\(y):w=\(width):h=\(height):color=black:t=fill")
            }
            if !videoFilters.isEmpty { arguments += ["-vf", videoFilters.joined(separator: ",")] }
            if tool == .mute || !info.hasAudio || tool == .snapshot { arguments += ["-an"] }
            else {
                if tool == .speed {
                    var speed = options.speed, filters: [String] = []
                    while speed < 0.5 { filters.append("atempo=0.5"); speed *= 2 }
                    while speed > 2 { filters.append("atempo=2"); speed /= 2 }
                    filters.append("atempo=\(speed)"); arguments += ["-af", filters.joined(separator: ",")]
                }
                arguments += ["-c:a", "aac", "-b:a", "\(64 + options.quality * 2)k"]
            }
            if tool == .speed, info.hasVideo, info.frameRate > 0 { arguments += ["-r", String(min(240, info.frameRate * options.speed))] }
            if tool != .snapshot {
                if info.hasVideo { arguments += ["-c:v", "libx264", "-preset", "fast", "-crf", String(40 - options.quality * 24 / 100), "-pix_fmt", "yuv420p", "-metadata:s:v:0", "rotate=0", "-movflags", "+faststart"] }
                else { arguments += ["-vn"] }
            }
            arguments.append(temporary.path)
            _ = try await run("ffmpeg", arguments)
            names.append(name)
        }
        try Task.checkCancellation()
        if parts == 1 { return [try LocalFileTools.publish(stage.appendingPathComponent(names[0]), to: directory, name: names[0])] }
        let published = try LocalFileTools.publish(stage, to: directory, name: source.deletingPathExtension().lastPathComponent + "-split")
        return names.map { published.appendingPathComponent($0) }
    }
}
