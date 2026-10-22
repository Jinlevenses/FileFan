import CoreGraphics
import FileFanCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct BackendQA {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--fixtures" {
                try fixtures(URL(fileURLWithPath: arguments[1]))
                return
            }
            if arguments.first == "--compression-fixture" {
                try imagePDF(URL(fileURLWithPath: arguments[1]))
                return
            }
            if arguments.first == "--pdf-render-check" {
                let document = try require(CGPDFDocument(URL(fileURLWithPath: arguments[1]) as CFURL))
                let page = try require(document.page(at: 1)), bounds = page.getBoxRect(.mediaBox)
                let width = Int(bounds.width.rounded()), height = Int(bounds.height.rounded())
                let bitmap = try require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                bitmap.drawPDFPage(page)
                let bytes = try require(bitmap.data).assumingMemoryBound(to: UInt8.self)
                var visible = 0
                for pixel in 0..<(width * height) where min(bytes[pixel * 4], bytes[pixel * 4 + 1], bytes[pixel * 4 + 2]) < 245 { visible += 1 }
                let image = try require(bitmap.makeImage())
                let destination = try require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination), visible > width * height / 2 else { throw NSError(domain: "PDF raster readback is empty", code: 1) }
                try printJSON(["width": width, "height": height, "visiblePixels": visible])
                return
            }
            if arguments.first == "--image-info" {
                let source = try require(CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil))
                let image = try require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let width = image.width, height = image.height
                let bitmap = try require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let bytes = try require(bitmap.data).assumingMemoryBound(to: UInt8.self)
                var grayPixels = 0
                for pixel in 0..<(width * height) where bytes[pixel * 4] == bytes[pixel * 4 + 1] && bytes[pixel * 4] == bytes[pixel * 4 + 2] { grayPixels += 1 }
                let center = (height / 2 * width + width / 2) * 4
                try printJSON(["width": width, "height": height, "grayPixels": grayPixels,
                               "centerRGBA": (0..<4).map { Int(bytes[center + $0]) }])
                return
            }
            if arguments.first == "--pdf-info" {
                let document = try require(CGPDFDocument(URL(fileURLWithPath: arguments[1]) as CFURL))
                let sizes = (1...document.numberOfPages).compactMap { index -> [String: Double]? in
                    guard let page = document.page(at: index) else { return nil }
                    let bounds = page.getBoxRect(.mediaBox)
                    return ["width": bounds.width, "height": bounds.height]
                }
                try printJSON(["pages": document.numberOfPages, "pageSizes": sizes])
                return
            }
            if arguments.first == "--bundle-probe" {
                let backend = ConversionBackend.bundled()
                let formats = await backend.formats()
                guard formats.count == 244 else { throw NSError(domain: "Bundle", code: 1) }
                let targets = await backend.targets(for: [URL(fileURLWithPath: "/private/tmp/test.png")])
                try printJSON(["formats": formats.count, "categories": Set(formats.map(\.category)).count,
                               "availablePNGTargets": targets.filter(\.isAvailable).count,
                               "resourceURL": Bundle.main.resourceURL?.path ?? ""])
                return
            }
            guard arguments.count >= 4 else { throw NSError(domain: "Usage: BACKEND OUTPUT TARGET SOURCES... [--pages 1-2]", code: 2) }
            let backend = ConversionBackend(executableURL: URL(fileURLWithPath: arguments[0]))
            let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let id = arguments[2]
            var files = Array(arguments.dropFirst(3))
            var options = ConversionOptions()
            if let index = files.firstIndex(of: "--pages") {
                options.pageRange = files[index + 1]; files.removeSubrange(index...(index + 1))
            }
            if let index = files.firstIndex(of: "--max-pixels") {
                guard let pixels = Int(files[index + 1]) else { throw NSError(domain: "Invalid pixels", code: 2) }
                options.maxPixelDimension = pixels; files.removeSubrange(index...(index + 1))
            }
            let sources = files.map { URL(fileURLWithPath: $0) }
            let targets = await backend.targets(for: sources)
            guard let target = targets.first(where: { $0.id == id }) else { throw NSError(domain: "Unknown target " + id, code: 3) }
            guard target.isAvailable else { throw NSError(domain: target.unavailableReason ?? "Unavailable", code: 4) }
            let result = try await backend.convert(sourceURLs: sources, outputDirectory: output, target: target, options: options)
            try printJSON(["successCount": result.successCount, "failureCount": result.failureCount,
                           "outputs": result.outputURLs.map(\.path),
                           "files": result.files.map { ["source": $0.sourceURL.path, "outputs": $0.outputURLs.map(\.path), "error": $0.error as Any? ?? NSNull(), "notice": $0.notice as Any? ?? NSNull()] }])
            if result.failureCount > 0 { exit(1) }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "Invalid QA fixture", code: 1) }; return value
    }
    private static func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
    private static func fixtures(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 240, height: 180)
        let consumer = try require(CGDataConsumer(url: directory.appendingPathComponent("three-pages.pdf") as CFURL))
        let pdf = try require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<3 {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0.4, blue: 0.7, alpha: 1))
            pdf.fill(CGRect(x: 10, y: 10, width: 200, height: 140)); pdf.endPDFPage()
        }
        pdf.closePDF()
        let context = try require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try require(context.makeImage())
        let destination = try require(CGImageDestinationCreateWithURL(directory.appendingPathComponent("image.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PNG", code: 1) }
    }

    private static func imagePDF(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = 1200, height = 900
        let bitmap = try require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = try require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 0xF11EFACE
        for index in 0..<(width * height) {
            for channel in 0..<3 { seed = seed &* 1_664_525 &+ 1_013_904_223; bytes[index * 4 + channel] = UInt8(seed >> 24) }
            bytes[index * 4 + 3] = 255
        }
        let image = try require(bitmap.makeImage())
        var box = CGRect(x: 0, y: 0, width: 288, height: 216) // 1200 × 900 pixels at 300 dpi.
        let consumer = try require(CGDataConsumer(url: url as CFURL))
        let pdf = try require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.draw(image, in: box); pdf.endPDFPage(); pdf.closePDF()
    }
}
