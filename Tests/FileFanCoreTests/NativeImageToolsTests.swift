import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import FileFanCore

struct NativeImageToolsTests {
    private func fixture(_ directory: URL, transparent: Bool = false, orientation: Int = 1) throws -> URL {
        let context = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: transparent ? 0 : 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination)); return url
    }
    @Test func cropUsesOrientedDimensionsAndRejectsOutOfBoundsWithoutChangingSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir, orientation: 6), original = try Data(contentsOf: source)
        let output = try NativeImageTools.process(source: source, directory: dir, tool: .crop, options: .init(rect: CGRect(x: 2, y: 3, width: 20, height: 30)))
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)!
        #expect(image.width == 20 && image.height == 30)
        #expect(throws: (any Error).self) { try NativeImageTools.process(source: source, directory: dir, tool: .crop, options: .init(rect: CGRect(x: 100, y: 0, width: 50, height: 20))) }
        #expect(try Data(contentsOf: source) == original)
    }
    @Test func redactBackgroundAndAnnotationProduceRealPixelChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let white = try fixture(dir), transparent = try fixture(dir, transparent: true)
        let redacted = try NativeImageTools.process(source: white, directory: dir, tool: .redact, options: .init(rect: CGRect(x: 0, y: 0, width: 128, height: 64)))
        let background = try NativeImageTools.process(source: transparent, directory: dir, tool: .background, options: .init(color: .init(red: 1, green: 0, blue: 0)))
        let annotated = try NativeImageTools.process(source: white, directory: dir, tool: .annotate, options: .init(text: "Test", fontSize: 24))
        func pixels(_ url: URL) -> [UInt8] {
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        #expect(Array(pixels(redacted).prefix(4)) == [0, 0, 0, 255])
        #expect(pixels(background)[0] == 255 && pixels(background)[1] < 50 && pixels(background)[2] == 0 && pixels(background)[3] == 255)
        #expect(pixels(annotated) != pixels(white))
    }
    @Test func editNinetyDegreesMovesBottomLeftMarkerClockwiseToTopLeft() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let source = dir.appendingPathComponent("marker.png")
        let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); #expect(CGImageDestinationFinalize(destination))
        let output = try NativeImageTools.process(source: source, directory: dir, tool: .edit, options: .init(rotation: 90))
        let image = CIImage(contentsOf: output)!
        #expect(image.extent.width == 20 && image.extent.height == 40)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 2, y: 37, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        #expect(pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60)
    }

}
