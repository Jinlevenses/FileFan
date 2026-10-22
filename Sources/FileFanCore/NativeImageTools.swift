import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

public struct ImageToolColor: Sendable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double = 0, green: Double = 0, blue: Double = 0) { self.red = red; self.green = green; self.blue = blue }
}
public struct ImageToolOptions: Sendable {
    public var rect: CGRect?
    public var text: String
    public var fontSize: Double
    public var color: ImageToolColor
    public var rotation: Int
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var quality: Double
    public init(rect: CGRect? = nil, text: String = "", fontSize: Double = 24, color: ImageToolColor = .init(), rotation: Int = 0, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, quality: Double = 0.8) {
        self.rect = rect; self.text = text; self.fontSize = fontSize; self.color = color; self.rotation = rotation
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation; self.quality = quality
    }
}
public enum NativeImageTools {
    public static func dimensions(_ source: URL) throws -> CGSize {
        let image = try decode(source)
        return CGSize(width: image.width, height: image.height)
    }
    private static func decode(_ url: URL) throws -> CGImage {
        let source = try LocalFileTools.validated([url])[0]
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 80_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else { throw ImageConversionError.decodingFailed }
        return image
    }
    public static func process(source: URL, directory: URL, tool: ContextToolID, options: ImageToolOptions) throws -> URL {
        guard options.quality.isFinite, (0.01...1).contains(options.quality), [0, 90, 180, 270].contains(options.rotation),
              options.brightness.isFinite, (-1...1).contains(options.brightness), options.contrast.isFinite, (0...4).contains(options.contrast),
              options.saturation.isFinite, (0...2).contains(options.saturation),
              [options.color.red, options.color.green, options.color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ImageConversionError.invalidOptions }
        if tool == .compress { return try ImageConverter.convert(sourceURL: source, outputDirectory: directory, options: .init(format: .jpeg, jpegQuality: options.quality)).outputURL }
        var image = try decode(source)
        if tool == .edit {
            var ci = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: options.brightness, kCIInputContrastKey: options.contrast, kCIInputSaturationKey: options.saturation])
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(options.rotation) * .pi / 180))
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
            guard let rendered = CIContext().createCGImage(ci, from: ci.extent.integral) else { throw ImageConversionError.renderingFailed }
            image = rendered
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if [.crop, .redact].contains(tool) {
            guard let rect = options.rect, [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0, bounds.contains(rect), rect == rect.integral else { throw ConversionBackendError.invalidInput("Use a whole-pixel rectangle inside the oriented image (top-left origin).") }
            if tool == .crop {
                guard let cropped = image.cropping(to: rect) else { throw ImageConversionError.renderingFailed }; image = cropped
            }
        }
        if [.background, .redact, .annotate].contains(tool) {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageConversionError.renderingFailed }
            let color = CGColor(red: options.color.red, green: options.color.green, blue: options.color.blue, alpha: 1)
            if tool == .background { context.setFillColor(color); context.fill(bounds) }
            context.draw(image, in: bounds)
            if tool == .redact, let rect = options.rect {
                context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
            }
            if tool == .annotate {
                guard !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, options.text.count <= 2000, options.fontSize.isFinite, (8...512).contains(options.fontSize) else { throw ConversionBackendError.invalidInput("Enter annotation text (up to 2000 characters) and font size 8–512.") }
                let point = options.rect?.origin ?? CGPoint(x: 8, y: 8)
                guard bounds.contains(point) else { throw ConversionBackendError.invalidInput("Annotation position must be inside the image.") }
                let font = CTFontCreateUIFontForLanguage(.system, options.fontSize, nil)!
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: options.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
                context.textPosition = CGPoint(x: point.x, y: bounds.height - point.y - options.fontSize)
                CTLineDraw(line, context)
            }
            guard let rendered = context.makeImage() else { throw ImageConversionError.renderingFailed }; image = rendered
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw ImageConversionError.encodingFailed }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.encodingFailed }
        return try LocalFileTools.write(data as Data, source: source, directory: directory, suffix: tool.rawValue, extension: "png")
    }
}
