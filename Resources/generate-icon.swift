import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Provide an output .iconset folder") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 512
        let canvas = NSAffineTransform()
        canvas.scale(by: factor)
        canvas.concat()
        NSColor(calibratedRed: 0.14, green: 0.32, blue: 0.57, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 448, height: 448), xRadius: 104, yRadius: 104).fill()
        NSColor(calibratedWhite: 1, alpha: 0.97).setFill()
        for angle in [-16.0, 0, 16] {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 256, yBy: 240)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -256, yBy: -240)
            transform.concat()
            NSBezierPath(roundedRect: NSRect(x: 163, y: 190, width: 186, height: 204), xRadius: 14, yRadius: 14).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(calibratedRed: 0.46, green: 0.74, blue: 0.96, alpha: 1).setFill()
        let folder = NSBezierPath()
        folder.move(to: NSPoint(x: 111, y: 155))
        folder.line(to: NSPoint(x: 111, y: 285))
        folder.curve(to: NSPoint(x: 130, y: 304), controlPoint1: NSPoint(x: 111, y: 298), controlPoint2: NSPoint(x: 119, y: 304))
        folder.line(to: NSPoint(x: 216, y: 304))
        folder.line(to: NSPoint(x: 244, y: 277))
        folder.line(to: NSPoint(x: 382, y: 277))
        folder.curve(to: NSPoint(x: 401, y: 258), controlPoint1: NSPoint(x: 393, y: 277), controlPoint2: NSPoint(x: 401, y: 270))
        folder.line(to: NSPoint(x: 401, y: 155))
        folder.curve(to: NSPoint(x: 381, y: 135), controlPoint1: NSPoint(x: 401, y: 142), controlPoint2: NSPoint(x: 394, y: 135))
        folder.line(to: NSPoint(x: 131, y: 135))
        folder.curve(to: NSPoint(x: 111, y: 155), controlPoint1: NSPoint(x: 118, y: 135), controlPoint2: NSPoint(x: 111, y: 142))
        folder.close()
        folder.fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// Pack our PNG representations directly; iconutil can fail in restricted build environments.
func lengthBytes(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
let representations = [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")]
var body = Data()
for (type, filename) in representations {
    let png = try Data(contentsOf: directory.appendingPathComponent(filename))
    body.append(contentsOf: type.utf8)
    body.append(lengthBytes(png.count + 8))
    body.append(png)
}
var icon = Data("icns".utf8)
icon.append(lengthBytes(body.count + 8))
icon.append(body)
let output = directory.deletingPathExtension().appendingPathExtension("icns")
try icon.write(to: output)
guard NSImage(contentsOf: output)?.isValid == true else { fatalError("Generated icon did not decode") }
