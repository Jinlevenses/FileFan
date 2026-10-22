import AppKit
import FileFanCore
import ImageIO
import PDFKit

@MainActor
enum FileClipboard {
    static func copyFiles(_ urls: [URL], to board: NSPasteboard = .general) throws {
        let urls = try LocalFileTools.validated(urls)
        board.clearContents()
        guard board.writeObjects(urls.map { $0 as NSURL }) else { throw ConversionBackendError.invalidInput("The clipboard could not accept the files.") }
    }
    static func copyPaths(_ urls: [URL], to board: NSPasteboard = .general) throws {
        let urls = try LocalFileTools.validated(urls)
        board.clearContents()
        guard board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) else { throw ConversionBackendError.invalidInput("The clipboard could not accept path text.") }
    }
}

@MainActor
final class ContextToolController {
    private let model: AppModel
    init(model: AppModel) { self.model = model }
    static func summary(_ urls: [URL]) -> String {
        var bytes: Int64 = 0, folders = 0
        for url in urls {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
                if values.isDirectory == true { folders += 1 } else { bytes += Int64(values.fileSize ?? 0) }
            }
        }
        return "\(urls.count) item(s)\n" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + (folders > 0 ? " + folders" : "")
    }
    func tools(for urls: [URL]) async -> [ContextTool] {
        let folders = Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true })
        let readable = urls.allSatisfy { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil }
        return ContextToolCatalog.tools(for: urls, folders: folders, targets: await model.targets(for: urls), imageReadable: readable, ffmpegAvailable: MediaTools.bundled != nil)
    }
    func run(_ id: ContextToolID, urls incoming: [URL], universal: Bool) {
        do {
            let urls = try LocalFileTools.validated(incoming)
            if universal { try runFileAction(id, urls: urls); return }
            Task {
                let current = await tools(for: urls)
                guard let tool = current.first(where: { $0.id == id }), tool.isAvailable else {
                    model.showError("Tool unavailable", detail: current.first { $0.id == id }?.reason ?? "This operation does not apply to all dropped files."); return
                }
                do { try runContext(tool, urls: urls) }
                catch { model.showError(id.title + " failed", detail: error.localizedDescription) }
            }
        } catch { model.showError("Files unavailable", detail: error.localizedDescription) }
    }
    private func runFileAction(_ id: ContextToolID, urls: [URL]) throws {
        switch id {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { throw ConversionBackendError.invalidInput("AirDrop is unavailable for this selection on this Mac.") }
            service.perform(withItems: urls)
        case .float: model.add(urls); model.showShelf?()
        case .copy: try FileClipboard.copyFiles(urls); model.message = "Copied \(urls.count) file reference(s). Paste them in Finder or another app."
        case .copyPath: try FileClipboard.copyPaths(urls); model.message = "Copied \(urls.count) path(s) as text."
        case .move:
            guard let directory = chooseDirectory("Move files to folder") else { return }
            model.moveFiles(urls, to: directory)
        case .terminal:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw ConversionBackendError.invalidInput("Terminal.app is unavailable.") }
            let directories = Array(Set(urls.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? $0 : $0.deletingLastPathComponent() }))
            NSWorkspace.shared.open(directories, withApplicationAt: app, configuration: .init()) { [weak model] _, error in
                if let error { Task { @MainActor in model?.showError("Could not open Terminal", detail: error.localizedDescription) } }
            }
        default: break
        }
    }
    private func runContext(_ tool: ContextTool, urls: [URL]) throws {
        let folders = Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true })
        let kind = ContextToolCatalog.kind(for: urls[0], folders: folders)
        if tool.id == .metadata { showMetadata(urls); return }
        if tool.id == .zip, !folders.isEmpty {
            guard let directory = chooseDirectory("Create ZIP outside the selected folders") else { return }
            model.performToolTask("Create ZIP") { [try await LocalFileTools.createFolderZIP(urls, to: directory)] }
            return
        }
        if kind == "image" {
            guard let options = try ToolOptionsDialog.image(tool.id, source: urls[0]), let directory = chooseDirectory("Save new \(tool.title) images") else { return }
            model.performToolTask(tool.title) {
                let task = Task.detached {
                    var outputs: [URL] = []
                    for url in urls { try Task.checkCancellation(); outputs.append(try NativeImageTools.process(source: url, directory: directory, tool: tool.id, options: options)) }
                    return outputs
                }
                return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }
            return
        }
        if ["audio", "video"].contains(kind), let media = MediaTools.bundled {
            Task {
                do {
                    let info = try await media.probe(urls[0])
                    guard let options = try ToolOptionsDialog.media(tool.id, info: info), let directory = chooseDirectory("Save new \(tool.title) media") else { return }
                    model.performToolTask(tool.title) {
                        var outputs: [URL] = []
                        for url in urls { try Task.checkCancellation(); outputs += try await media.process(url, directory: directory, tool: tool.id, options: options) }
                        return outputs
                    }
                } catch { model.showError(tool.title + " failed", detail: error.localizedDescription) }
            }
            return
        }
        if [.validate, .format, .utf8].contains(tool.id) {
            let encoding: String.Encoding
            if tool.id == .utf8 {
                guard let value = ToolOptionsDialog.encoding() else { return }; encoding = value
            } else { encoding = .utf8 }
            let directory = tool.id == .validate ? nil : chooseDirectory("Save new \(tool.title) files")
            if tool.id != .validate && directory == nil { return }
            model.performToolTask(tool.title) {
                let task = Task.detached {
                    try urls.map { url -> URL? in
                        try Task.checkCancellation()
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                        guard size <= 16_000_000 else { throw ConversionBackendError.invalidInput("Text tools accept files up to 16 MB.") }
                        let text = try String(contentsOf: url, encoding: encoding)
                        if tool.id == .utf8 { return try NativeTextTools.exportUTF8(url, directory: directory!, encoding: encoding) }
                        let lines = url.pathExtension.lowercased() == "jsonl" ? text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : [text]
                        let objects = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
                        guard tool.id != .validate else { return nil }
                        let pretty = url.pathExtension.lowercased() != "jsonl"
                        let encoded = try objects.map { try JSONSerialization.data(withJSONObject: $0, options: pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed]) }
                        var data = Data(); for (index, item) in encoded.enumerated() { if index > 0 { data.append(10) }; data.append(item) }; data.append(10)
                        return try LocalFileTools.write(data, source: url, directory: directory!, suffix: "formatted", extension: url.pathExtension)
                    }.compactMap { $0 }
                }
                return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }
            return
        }
        if tool.id == .edit || (tool.id == .annotate && kind == "pdf") {
            let appID = kind == "pdf" ? "com.apple.Preview" : "com.apple.TextEdit"
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { throw ConversionBackendError.invalidInput("The system editor is unavailable.") }
            let alert = NSAlert(); alert.messageText = "Edit a new copy in \(app.deletingPathExtension().lastPathComponent)"
            alert.informativeText = tool.targetID == nil ? "A copy will be saved in your chosen folder and opened for editing. Originals stay unchanged." : "New DOCX copies will be created and opened in TextEdit. Conversion can change layout; originals stay unchanged."
            alert.addButton(withTitle: "Create Copy…"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let targetID = tool.targetID {
                Task {
                    guard let target = await model.targets(for: urls).first(where: { $0.id == targetID }) else { return }
                    model.convert(urls, target: target) { [weak self] outputs in self?.openCopies(outputs, app: app) }
                }
            } else {
                guard let directory = chooseDirectory("Save editable copies") else { return }
                model.performToolTask(tool.title, operation: {
                    let task = Task.detached { try urls.map { url in try Task.checkCancellation(); return try LocalFileTools.copy(url, to: directory, suffix: "edit") } }
                    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                }, after: { [weak self] outputs in self?.openCopies(outputs, app: app) })
            }
            return
        }
        if tool.id == .pages {
            guard let range = ToolOptionsDialog.pageRange() else { return }; model.pageRange = range
        }
        guard let targetID = tool.targetID else { throw ConversionBackendError.invalidInput("No processing route is available.") }
        Task {
            guard let target = await model.targets(for: urls).first(where: { $0.id == targetID && $0.isAvailable }) else { model.showError("Tool unavailable", detail: "The current selection no longer supports this operation."); return }
            model.convert(urls, target: target)
        }
    }
    private func openCopies(_ urls: [URL], app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { [weak model] _, error in
            if let error { Task { @MainActor in model?.showError("Could not open editor", detail: error.localizedDescription) } }
        }
    }
    private func chooseDirectory(_ title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.prompt = "Choose"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func showMetadata(_ urls: [URL]) {
        Task {
            var sections: [String] = []
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .typeIdentifierKey])
                var text = url.path + "\nType: " + (values?.typeIdentifier ?? "Unknown") + "\n"
                text += values?.isDirectory == true ? "Folder; contents are not scanned.\n" : "Bytes: \(values?.fileSize ?? 0)\n"
                if let date = values?.contentModificationDate { text += "Modified: \(date)\n" }
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) { text += String(describing: properties) }
                if ContextToolCatalog.kind(for: url) == "pdf", let pdf = PDFDocument(url: url) { text += "PDF pages: \(pdf.pageCount)\n" }
                if ["video", "audio"].contains(ContextToolCatalog.kind(for: url)), let media = MediaTools.bundled, let info = try? await media.probe(url) { text += info.metadata }
                sections.append(text)
                if sections.joined().count > 60000 { break }
            }
            let alert = NSAlert(); alert.messageText = "Metadata — \(urls.count) item(s)"
            alert.informativeText = Self.summary(urls).replacingOccurrences(of: "\n", with: " · ")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 360)); scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true
            text.string = String(sections.joined(separator: "\n\n").prefix(64000)); text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; scroll.documentView = text
            alert.accessoryView = scroll; NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
}
