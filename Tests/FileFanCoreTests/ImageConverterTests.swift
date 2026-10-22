import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import FileFanCore

final class ImageConverterTests {
    private var directory: URL!
    private var output: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        output = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func testPNGConversionResizesWithoutUpscalingAndPreservesSourceBytes() throws {
        let source = try fixture(width: 80, height: 40)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let result = try ImageConverter.convert(sourceURL: source, outputDirectory: output,
                                               options: .init(format: .png, maxPixelDimension: 20))
        let decoded = try image(at: result.outputURL)
        expectEqual([result.pixelWidth, result.pixelHeight], [20, 10])
        expectEqual([decoded.width, decoded.height], [20, 10])
        expectEqual(result.outputURL.pathExtension, "png")
        expectEqual(SHA256.hash(data: try Data(contentsOf: source)), before)
        let largerLimit = try ImageConverter.convert(sourceURL: source, outputDirectory: output,
                                                    options: .init(format: .png, maxPixelDimension: 160))
        expectEqual([largerLimit.pixelWidth, largerLimit.pixelHeight], [80, 40])
    }

    @Test func testOrientationIsAppliedToDimensionsAndPixels() throws {
        // Stored pixels are red on the left and blue on the right; EXIF 6 rotates clockwise.
        let source = try fixture(width: 40, height: 20, orientation: 6)
        let result = try ImageConverter.convert(sourceURL: source, outputDirectory: output,
                                               options: .init(format: .png))
        let decoded = try image(at: result.outputURL)
        expectEqual([decoded.width, decoded.height], [20, 40])
        expectEqual([result.pixelWidth, result.pixelHeight], [20, 40])
        let top = pixel(decoded, x: 10, y: 5)
        let bottom = pixel(decoded, x: 10, y: 35)
        expectGreaterThan(top[0], 240)
        expectLessThan(top[2], 15)
        expectGreaterThan(bottom[2], 240)
        expectLessThan(bottom[0], 15)
        let properties = try requireValue(CGImageSourceCopyPropertiesAtIndex(
            try requireValue(CGImageSourceCreateWithURL(result.outputURL as CFURL, nil)), 0, nil) as? [CFString: Any])
        expectEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
    }

    @Test func testJPEGCompositesTransparencyOverWhite() throws {
        let source = try fixture(width: 32, height: 32, transparent: true)
        let result = try ImageConverter.convert(sourceURL: source, outputDirectory: output,
                                               options: .init(format: .jpeg, jpegQuality: 1))
        let decoded = try image(at: result.outputURL)
        let color = pixel(decoded, x: 16, y: 16)
        expectTrue(color.prefix(3).allSatisfy { $0 > 245 }, "Transparent JPEG pixels must become white: \(color)")
        expectEqual(result.outputURL.pathExtension, "jpg")
    }

    @Test func testPNGPreservesTransparency() throws {
        let source = try fixture(width: 16, height: 16, transparent: true)
        let result = try ImageConverter.convert(sourceURL: source, outputDirectory: output, options: .init(format: .png))
        expectEqual(pixel(try image(at: result.outputURL), x: 8, y: 8)[3], 0)
    }

    @Test func testExistingOutputsAndSourceAreNeverOverwritten() throws {
        let source = try fixture(width: 12, height: 6)
        let existing = output.appendingPathComponent("fixture.png")
        let existingBytes = Data("pre-existing user content".utf8)
        try existingBytes.write(to: existing)
        let before = try Data(contentsOf: source)
        let first = try ImageConverter.convert(sourceURL: source, outputDirectory: output, options: .init(format: .png))
        let second = try ImageConverter.convert(sourceURL: source, outputDirectory: output, options: .init(format: .png))
        expectNotEqual(first.outputURL, existing)
        expectNotEqual(first.outputURL, second.outputURL)
        expectEqual(try Data(contentsOf: existing), existingBytes)
        expectEqual(try Data(contentsOf: source), before)
        let sameDirectory = try ImageConverter.convert(sourceURL: source, outputDirectory: directory, options: .init(format: .png))
        expectNotEqual(sameDirectory.outputURL, source)
        expectEqual(try Data(contentsOf: source), before)
    }

    @Test func testConcurrentConversionsReserveDifferentValidOutputs() throws {
        let source = try fixture(width: 64, height: 32)
        let results = ConversionResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.record { try ImageConverter.convert(sourceURL: source, outputDirectory: output,
                                                       options: .init(format: .png)) }
        }
        expectTrue(results.errors.isEmpty, "\(results.errors)")
        expectEqual(results.values.count, 8)
        expectEqual(Set(results.values.map(\.outputURL)).count, 8)
        for value in results.values {
            expectEqual(try image(at: value.outputURL).width, 64)
        }
    }

    @Test func testInvalidInputsAndOptionsFailWithoutLeavingArtifacts() throws {
        let valid = try fixture(width: 10, height: 10)
        let corrupt = directory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        let inputs = [corrupt, directory!, directory.appendingPathComponent("missing.png"), URL(string: "https://example.com/a.png")!]
        for source in inputs {
            expectThrows(try ImageConverter.convert(sourceURL: source, outputDirectory: output, options: .init(format: .png))) {
                expectFalse($0.localizedDescription.isEmpty)
            }
        }
        for limit in [0, -1] {
            expectThrows(try ImageConverter.convert(sourceURL: valid, outputDirectory: output,
                                                           options: .init(format: .png, maxPixelDimension: limit)))
        }
        for quality in [-0.1, 1.1, .nan, .infinity] {
            expectThrows(try ImageConverter.convert(sourceURL: valid, outputDirectory: output,
                                                           options: .init(format: .jpeg, jpegQuality: quality)))
        }
        for destination in [valid, directory.appendingPathComponent("missing-folder"), URL(string: "https://example.com")!] {
            expectThrows(try ImageConverter.convert(sourceURL: valid, outputDirectory: destination, options: .init(format: .png)))
        }
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    @Test func testTruncatedHeaderIsRejectedWithoutOutput() throws {
        let source = try fixture(width: 100, height: 50)
        let truncated = Data(try Data(contentsOf: source).prefix(24))
        try truncated.write(to: source)

        expectThrows(try ImageConverter.convert(sourceURL: source, outputDirectory: output, options: .init(format: .png)))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
        expectEqual(try Data(contentsOf: source), truncated)
    }

    private func fixture(width: Int, height: Int, orientation: Int = 1, transparent: Bool = false) throws -> URL {
        let context = try requireValue(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparent {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        let file = directory.appendingPathComponent("fixture.png")
        let destination = try requireValue(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try requireValue(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        expectTrue(CGImageDestinationFinalize(destination))
        return file
    }

    private func image(at url: URL) throws -> CGImage {
        let source = try requireValue(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try requireValue(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let start = (y * image.width + x) * 4
        return Array(bytes[start ..< start + 4])
    }
}

private final class ConversionResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [ImageConversionResult] = []
    private(set) var errors: [Error] = []

    func record(_ work: () throws -> ImageConversionResult) {
        let result = Result(catching: work)
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let value): values.append(value)
        case .failure(let error): errors.append(error)
        }
    }
}
