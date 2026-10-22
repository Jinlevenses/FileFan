import AppKit
import FileFanCore

@MainActor
enum ToolOptionsDialog {
    static func integer(_ text: String, label: String) throws -> Int {
        guard let number = Double(text), number.isFinite, let value = Int(exactly: number) else { throw ConversionBackendError.invalidInput("Enter a whole number within range for \(label).") }
        return value
    }
    static func imageColor(_ color: NSColor?) throws -> ImageToolColor {
        guard let selected = (color ?? .black).usingColorSpace(.sRGB) else { throw ConversionBackendError.invalidInput("Choose an RGB-compatible color.") }
        return .init(red: selected.redComponent, green: selected.greenComponent, blue: selected.blueComponent)
    }
    @MainActor private struct Form {
        let alert = NSAlert()
        let stack = NSStackView()
        var fields: [String: NSTextField] = [:]
        init(title: String, detail: String) {
            alert.messageText = title; alert.informativeText = detail
            alert.addButton(withTitle: "Continue…"); alert.addButton(withTitle: "Cancel")
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        }
        mutating func field(_ key: String, _ label: String, _ value: String) {
            let text = NSTextField(string: value); text.setAccessibilityLabel(label); text.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let name = NSTextField(labelWithString: label); name.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let row = NSStackView(views: [name, text]); row.spacing = 10; stack.addArrangedSubview(row); fields[key] = text
        }
        func number(_ key: String, default fallback: Double) throws -> Double {
            guard let field = fields[key] else { return fallback }
            guard let value = Double(field.stringValue), value.isFinite else { throw ConversionBackendError.invalidInput("Enter a finite number for \(field.accessibilityLabel() ?? key).") }
            return value
        }
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let field = fields[key] else { return fallback }
            return try ToolOptionsDialog.integer(field.stringValue, label: field.accessibilityLabel() ?? key)
        }
        func run() -> Bool {
            stack.frame = CGRect(x: 0, y: 0, width: 410, height: stack.fittingSize.height)
            alert.accessoryView = stack; NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
    static func image(_ tool: ContextToolID, source: URL) throws -> ImageToolOptions? {
        let size = try NativeImageTools.dimensions(source)
        let detail = tool == .compress ? "Create new JPEG outputs. Transparency becomes white. Quality controls lossy encoding; smaller size is not guaranteed. Originals are preserved." : "Save new PNG outputs; only the first image frame is edited. Coordinates use whole pixels from the top-left of the oriented image. Originals are preserved."
        var form = Form(title: tool.title + " Images", detail: detail + "\nImage: \(Int(size.width)) × \(Int(size.height)) px")
        if let preview = NSImage(contentsOf: source) {
            let image = NSImageView(image: preview); image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 400).isActive = true; image.heightAnchor.constraint(equalToConstant: 150).isActive = true
            image.setAccessibilityLabel("Original image preview"); form.stack.addArrangedSubview(image)
        }
        var color: NSColorWell?
        if tool == .compress { form.field("quality", "JPEG quality (1–100)", "80") }
        if tool == .edit {
            form.field("rotation", "Clockwise rotation (0/90/180/270)", "0")
            form.field("brightness", "Brightness (-1…1)", "0")
            form.field("contrast", "Contrast (0…4)", "1")
            form.field("saturation", "Saturation (0…2)", "1")
        }
        if [.crop, .redact, .annotate].contains(tool) {
            form.field("x", "X (pixels from left)", tool == .annotate ? "8" : "0")
            form.field("y", "Y (pixels from top)", tool == .annotate ? "8" : "0")
        }
        if [.crop, .redact].contains(tool) {
            form.field("width", "Width (pixels)", String(Int(tool == .redact ? size.width / 2 : size.width)))
            form.field("height", "Height (pixels)", String(Int(tool == .redact ? size.height / 2 : size.height)))
        }
        if tool == .annotate { form.field("text", "Annotation text", "Text"); form.field("font", "Font size (8–512 px)", "24") }
        if [.background, .annotate].contains(tool) {
            let well = NSColorWell(); well.color = tool == .background ? .white : .black; well.setAccessibilityLabel(tool == .background ? "Opaque background color" : "Annotation color")
            form.stack.addArrangedSubview(well); color = well
        }
        guard form.run() else { return nil }
        let selected = try imageColor(color?.color)
        let rect = try [.crop, .redact, .annotate].contains(tool) ? CGRect(x: form.number("x", default: 0), y: form.number("y", default: 0), width: form.number("width", default: 0), height: form.number("height", default: 0)) : nil
        return try ImageToolOptions(rect: rect, text: form.fields["text"]?.stringValue ?? "", fontSize: form.number("font", default: 24), color: selected, rotation: form.integer("rotation", default: 0), brightness: form.number("brightness", default: 0), contrast: form.number("contrast", default: 1), saturation: form.number("saturation", default: 1), quality: form.number("quality", default: 80) / 100)
    }
    static func media(_ tool: ContextToolID, info: MediaInfo) throws -> MediaToolOptions? {
        var form = Form(title: tool.title + (info.hasVideo ? " Video" : " Audio"), detail: "Create new \(tool == .snapshot ? "PNG" : info.hasVideo ? "MP4 (H.264/AAC)" : "M4A (AAC)") outputs. Re-encoding may change quality or size. Originals are preserved.\nDuration: \(String(format: "%.3f", info.duration)) seconds" + (info.hasVideo ? "; \(info.width) × \(info.height) px" : ""))
        if [.trim, .snapshot, .split].contains(tool) { form.field("start", tool == .split ? "Split at (seconds)" : "Start (seconds)", tool == .split ? String(info.duration / 2) : "0") }
        if tool == .trim { form.field("end", "End (seconds)", String(info.duration)) }
        if tool == .speed { form.field("speed", "Playback speed (0.25…4)", "1.5") }
        if tool == .compress { form.field("quality", "Encoding quality (1–100)", "60") }
        if [.crop, .redact].contains(tool) {
            form.field("x", "X (pixels from left)", "0"); form.field("y", "Y (pixels from top)", "0")
            form.field("width", "Width (even pixels)", String(max(2, info.width / 4 * 2)))
            form.field("height", "Height (even pixels)", String(max(2, info.height / 4 * 2)))
        }
        guard form.run() else { return nil }
        let rect = try [.crop, .redact].contains(tool) ? CGRect(x: form.number("x", default: 0), y: form.number("y", default: 0), width: form.number("width", default: 0), height: form.number("height", default: 0)) : nil
        let options = try MediaToolOptions(start: form.number("start", default: 0), end: tool == .trim ? form.number("end", default: info.duration) : nil, speed: form.number("speed", default: 1), rect: rect, quality: form.integer("quality", default: 75))
        try MediaTools.validate(options, tool: tool, info: info)
        return options
    }
    static func encoding() -> String.Encoding? {
        let alert = NSAlert(); alert.messageText = "Export UTF-8 copy"; alert.informativeText = "Choose the source encoding. A new UTF-8 file will be saved; the original stays unchanged."
        let menu = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 280, height: 26)); menu.addItems(withTitles: ["UTF-8", "UTF-16 (with BOM)", "CP949 (Korean)", "Windows-1252"]); menu.setAccessibilityLabel("Source text encoding")
        alert.accessoryView = menu; alert.addButton(withTitle: "Continue…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return [.utf8, .utf16, NativeTextTools.cp949, .windowsCP1252][menu.indexOfSelectedItem]
    }
    static func pageRange() -> String? {
        let alert = NSAlert(); alert.messageText = "Extract PDF pages"; alert.informativeText = "Enter page numbers and ranges, for example 1-3,5. A new PDF will be created."
        let field = NSTextField(string: "1"); field.frame.size = CGSize(width: 300, height: 26); field.setAccessibilityLabel("PDF page range")
        alert.accessoryView = field; alert.addButton(withTitle: "Continue…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }; return field.stringValue
    }
}
