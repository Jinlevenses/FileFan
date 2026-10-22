import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageOutputFormat: String, CaseIterable, Sendable {
    case png, jpeg

    private var type: UTType { self == .png ? .png : .jpeg }
    fileprivate var identifier: CFString { type.identifier as CFString }
    fileprivate var fileExtension: String { self == .png ? "png" : "jpg" }
}

public struct ImageConversionOptions: Sendable {
    public let format: ImageOutputFormat
    public let maxPixelDimension: Int?
    public let jpegQuality: Double

    public init(format: ImageOutputFormat, maxPixelDimension: Int? = nil, jpegQuality: Double = 0.9) {
        self.format = format
        self.maxPixelDimension = maxPixelDimension
        self.jpegQuality = jpegQuality
    }
}

public struct ImageConversionResult: Sendable {
    public let sourceURL: URL
    public let outputURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum ImageConversionError: LocalizedError {
    case invalidSource(String)
    case invalidOptions
    case invalidOutputDirectory
    case decodingFailed
    case renderingFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let reason): return reason
        case .invalidOptions: return "최대 길이는 양수, JPEG 품질은 0부터 1 사이의 유한한 값이어야 합니다."
        case .invalidOutputDirectory: return "쓰기 가능한 로컬 출력 폴더를 선택하세요."
        case .decodingFailed: return "지원하지 않거나 손상된 이미지입니다."
        case .renderingFailed: return "이미지 픽셀을 처리할 수 없습니다."
        case .encodingFailed: return "이미지 파일을 인코딩할 수 없습니다."
        }
    }
}

public enum ImageConverter {
    public static func convert(sourceURL: URL, outputDirectory: URL, options: ImageConversionOptions) throws -> ImageConversionResult {
        guard options.maxPixelDimension.map({ $0 > 0 }) ?? true,
              options.jpegQuality.isFinite, (0...1).contains(options.jpegQuality) else {
            throw ImageConversionError.invalidOptions
        }
        let intake = FileIntake.inspect([sourceURL])
        guard let source = intake.accepted.first else {
            throw ImageConversionError.invalidSource(intake.rejected.first?.reason ?? "이미지 파일을 선택하세요.")
        }
        let sourceValues = try source.url.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues.isRegularFile == true else {
            throw ImageConversionError.invalidSource("일반 이미지 파일을 선택하세요. 폴더는 변환할 수 없습니다.")
        }
        let outputIntake = FileIntake.inspect([outputDirectory])
        guard let output = outputIntake.accepted.first?.url,
              (try output.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              FileManager.default.isWritableFile(atPath: output.path) else {
            throw ImageConversionError.invalidOutputDirectory
        }
        guard let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, nil),
              CGImageSourceGetType(imageSource) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ImageConversionError.decodingFailed
        }
        let maximum = min(options.maxPixelDimension ?? max(width, height), max(width, height))
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions as CFDictionary) else {
            throw ImageConversionError.decodingFailed
        }
        if options.format == .jpeg {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ImageConversionError.renderingFailed
            }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let opaque = context.makeImage() else { throw ImageConversionError.renderingFailed }
            image = opaque
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, options.format.identifier, 1, nil) else {
            throw ImageConversionError.encodingFailed
        }
        let propertiesOut: [CFString: Any] = options.format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: options.jpegQuality] : [:]
        CGImageDestinationAddImage(destination, image, propertiesOut as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.encodingFailed }
        let outputURL = try writeNewOutput(data as Data, directory: output,
                                           stem: source.url.deletingPathExtension().lastPathComponent,
                                           fileExtension: options.format.fileExtension)
        return ImageConversionResult(sourceURL: source.url, outputURL: outputURL,
                                     pixelWidth: image.width, pixelHeight: image.height)
    }

    private static func writeNewOutput(_ data: Data, directory: URL, stem: String, fileExtension: String) throws -> URL {
        var suffix = 0
        while true {
            let name = suffix == 0 ? "\(stem).\(fileExtension)" : "\(stem) \(suffix).\(fileExtension)"
            let url = directory.appendingPathComponent(name)
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                Darwin.open(path!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else {
                if errno == EEXIST { suffix += 1; continue }
                throw posixError(url: url)
            }
            var identity = stat()
            if fstat(descriptor, &identity) != 0 {
                let error = posixError(url: url)
                Darwin.close(descriptor)
                throw error
            }
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw posixError(url: url)
                        }
                        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                        offset += count
                    }
                }
                guard fsync(descriptor) == 0 else { throw posixError(url: url) }
            } catch {
                Darwin.close(descriptor)
                // A renamed/replaced path belongs to somebody else, even if our write failed.
                var current = stat()
                url.withUnsafeFileSystemRepresentation { path in
                    if lstat(path!, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino {
                        Darwin.unlink(path!)
                    }
                }
                throw error
            }
            Darwin.close(descriptor)
            return url
        }
    }

    private static func posixError(url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
