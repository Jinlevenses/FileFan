import AppKit
import Combine
import FileFanCore
import QuickLookUI
import ImageIO

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var shelf = FileShelf()
    @Published var selection = Set<String>() {
        didSet { if !selection.isEmpty { actionsBlocked = false }; persist(); refreshTargets() }
    }
    @Published private var actionsBlocked = false
    @Published var isDropTargeted = false
    @Published private(set) var isConverting = false
    @Published private(set) var progress = ""
    @Published var message = "Drop files or folders here to keep them within reach."
    @Published var maxDimension = "" { didSet { persist() } }
    @Published private(set) var missingFiles: [URL] = []
    @Published var gesturesEnabled = true { didSet { persist() } }
    private let sessionStore: SessionStore?
    private(set) var session = SessionState()
    var showShelf: (() -> Void)?
    var showFan: (() -> Void)?
    let backend = ConversionBackend.bundled()
    @Published var conversionTargets: [ConversionTarget] = []
    @Published var showingConversionBrowser = false
    @Published var conversionSearch = ""
    @Published var quality = 90.0 { didSet { persist() } }
    @Published var pageRange = "" { didSet { persist() } }
    private var targetTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private let preview = PreviewController()
    private let errorPresenter: ((String, String) -> Void)?
    private let copyText: (String) -> Bool

    init(errorPresenter: ((String, String) -> Void)? = nil, copyText: ((String) -> Bool)? = nil, sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
        self.errorPresenter = errorPresenter
        self.copyText = copyText ?? { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        if let sessionStore {
            let loaded = sessionStore.load()
            session = loaded.state
            _ = shelf.add(loaded.state.files)
            let available = Set(shelf.items.map(\.id))
            missingFiles = loaded.state.files.filter { !available.contains($0.resolvingSymlinksInPath().path) }
            selection = loaded.state.selection.intersection(available)
            maxDimension = loaded.state.maxDimension
            gesturesEnabled = loaded.state.gesturesEnabled
            quality = loaded.state.quality
            pageRange = loaded.state.pageRange
            if let warning = loaded.warning { message = warning }
            else if !missingFiles.isEmpty { message = "\(missingFiles.count) saved item(s) are unavailable. Recover or remove them below." }
        }
    }

    func persist() {
        guard let sessionStore else { return }
        session.files = shelf.items.map(\.url) + missingFiles
        session.selection = selection
        session.maxDimension = maxDimension
        session.gesturesEnabled = gesturesEnabled
        session.quality = quality
        session.pageRange = pageRange
        do { try sessionStore.save(session) }
        catch { message = "Shelf changes could not be saved: \(error.localizedDescription)" }
    }

    func savePlacement(frame: CGRect, dock: DockPlacement?) {
        session.windowFrame = frame; session.dock = dock; persist()
    }

    func removeMissing(_ url: URL) { missingFiles.removeAll { $0 == url }; persist() }
    func recoverMissing(_ url: URL) {
        let panel = NSOpenPanel()
        panel.title = "Locate \(url.lastPathComponent)"
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let replacement = panel.url else { return }
        let intake = FileIntake.inspect([replacement])
        guard !intake.accepted.isEmpty else { showError("Could not recover item", detail: "Choose an accessible local file or folder."); return }
        missingFiles.removeAll { $0 == url }; add([replacement])
    }

    var selectedItems: [ShelfItem] { shelf.items.filter { selection.contains($0.id) } }
    var actionItems: [ShelfItem] { actionsBlocked ? [] : (selectedItems.isEmpty ? shelf.items : selectedItems) }

    func add(_ urls: [URL]) {
        let incoming = FileIntake.inspect(urls)
        let result = shelf.add(urls)
        let recovered = Set(incoming.accepted.map(\.id))
        missingFiles.removeAll { recovered.contains($0.resolvingSymlinksInPath().path) }
        selection = Set(incoming.accepted.map(\.id)).intersection(shelf.items.map(\.id))
        actionsBlocked = selection.isEmpty
        if !result.accepted.isEmpty {
            message = "Added \(result.accepted.count) item(s). Originals stay in place."
        } else if !incoming.accepted.isEmpty {
            message = "These items are already in FileFan."
        } else {
            message = "No accessible files were added. Select shelf items or add files to continue."
        }
        persist()
        refreshTargets()
        if !result.rejected.isEmpty {
            showError("Some items could not be added", detail: result.rejected.map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n"))
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add to FileFan"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls); showShelf?() }
    }

    func removeSelection() {
        let count = selection.count
        shelf.remove(ids: selection)
        selection.removeAll()
        message = "Removed \(count) item(s) from the shelf. Files remain on disk."
    }

    func clear() {
        shelf.clear()
        missingFiles.removeAll()
        selection.removeAll()
        message = "Shelf cleared. Files remain on disk."
    }

    func open() {
        for item in validatedActionItems() {
            if !NSWorkspace.shared.open(item.url) { showError("Could not open \(item.displayName)", detail: "Check that the file still exists and that an application can open it.") }
        }
    }

    func reveal() {
        let items = validatedActionItems()
        if !items.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
    }

    func copyPaths() {
        let items = validatedActionItems()
        guard !items.isEmpty else { message = "Add accessible files before copying paths."; return }
        guard copyText(items.map(\.url.path).joined(separator: "\n")) else {
            message = "Could not copy paths to the clipboard. Try again."
            showError("Could not copy paths", detail: "The system clipboard did not accept these paths. Try again, or restart FileFan if the problem continues.")
            return
        }
        message = "Copied \(items.count) path(s)."
    }

    func quickLook() {
        let items = validatedActionItems()
        guard !items.isEmpty else { message = "Add accessible files before opening Preview."; return }
        preview.show(items.map(\.url))
    }

    func convert(to format: ImageOutputFormat) {
        guard !isConverting else { return }
        let items = actionItems
        guard !items.isEmpty else { message = "Add images before converting."; return }
        let trimmed = maxDimension.trimmingCharacters(in: .whitespacesAndNewlines)
        var maximum: Int?
        if !trimmed.isEmpty {
            guard let parsed = Int(trimmed), parsed > 0, parsed <= 100_000 else {
                showError("Enter a valid maximum dimension", detail: "Use a whole number from 1 to 100000, or leave this field empty to preserve image size.")
                return
            }
            maximum = parsed
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for converted images"
        panel.prompt = "Convert Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        startNativeConversion(items: items, directory: directory, format: format, maxPixelDimension: maximum)
    }

    func startNativeConversion(items: [ShelfItem], directory: URL, format: ImageOutputFormat, maxPixelDimension: Int? = nil) {
        guard !isConverting else { return }
        let options = ImageConversionOptions(format: format, maxPixelDimension: maxPixelDimension, jpegQuality: quality / 100)
        isConverting = true
        progress = "Preparing \(items.count) image(s)…"
        conversionTask = Task {
            defer { conversionTask = nil }
            var outputs: [URL] = []
            var failures: [String] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                progress = "Converting \(index + 1) of \(items.count): \(item.displayName)"
                let outcome = await Task.detached(priority: .userInitiated) {
                    Result { try ImageConverter.convert(sourceURL: item.url, outputDirectory: directory, options: options) }
                }.value
                switch outcome {
                case .success(let result): outputs.append(result.outputURL)
                case .failure(let error): failures.append("\(item.displayName): \(error.localizedDescription)")
                }
            }
            isConverting = false
            progress = ""
            if !outputs.isEmpty { add(outputs) }
            message = Task.isCancelled ? "Conversion cancelled after the current image. Kept \(outputs.count) output(s); originals preserved." : "Converted \(outputs.count) of \(items.count) image(s). Originals preserved."
            if !failures.isEmpty { showError("\(failures.count) image(s) could not be converted", detail: failures.joined(separator: "\n")) }
        }
    }

    func targets(for urls: [URL]) async -> [ConversionTarget] {
        var targets = await backend.targets(for: urls)
        let canUseNative = !urls.isEmpty && urls.allSatisfy { $0.isFileURL && CGImageSourceCreateWithURL($0 as CFURL, nil) != nil }
        if canUseNative {
            for (id, name) in [("png", "PNG"), ("jpeg", "JPEG")] {
                let backendIDs = id == "jpeg" ? ["jpg", "jpeg"] : ["png"]
                if !targets.contains(where: { backendIDs.contains($0.targetFormatID) && $0.isAvailable && $0.presetID == nil }) {
                    targets.insert(ConversionTarget(id: "native:" + id, name: name, category: "Image", targetFormatID: id, isAvailable: true), at: 0)
                }
            }
        }
        return ConversionPresentation.orderedTargets(targets, sourceURLs: urls)
    }

    func refreshTargets() {
        let urls = actionItems.map(\.url)
        targetTask?.cancel()
        targetTask = Task {
            let targets = await self.targets(for: urls)
            guard !Task.isCancelled else { return }
            conversionTargets = targets
        }
    }

    func browseConversions() { refreshTargets(); showingConversionBrowser = true }
    func cancelConversion() { conversionTask?.cancel(); progress = "Cancelling conversion…" }
    func convert(_ urls: [URL], target: ConversionTarget, after: (([URL]) -> Void)? = nil) {
        guard !isConverting else { message = "A conversion is already running."; return }
        if target.id.hasPrefix("native:") { add(urls); convert(to: target.targetFormatID == "png" ? .png : .jpeg); return }
        guard target.isAvailable else { showError("Conversion unavailable", detail: target.unavailableReason ?? "Required engine is unavailable."); return }
        let trimmed = maxDimension.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = trimmed.isEmpty ? nil : Int(trimmed)
        guard trimmed.isEmpty || (maximum != nil && maximum! > 0 && maximum! <= 100000) else {
            showError("Enter a valid maximum dimension", detail: "Use a whole number from 1 to 100000, or leave empty."); return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose output folder — \(target.name)"
        panel.prompt = "Convert Here"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isConverting = true; progress = "Converting \(urls.count) item(s) to \(target.name)…"
        let options = ConversionOptions(quality: Int(quality), maxPixelDimension: maximum, pageRange: pageRange)
        conversionTask = Task {
            defer { isConverting = false; progress = ""; conversionTask = nil }
            do {
                let result = try await backend.convert(sourceURLs: urls, outputDirectory: directory, target: target, options: options)
                if !result.outputURLs.isEmpty { add(result.outputURLs); after?(result.outputURLs) }
                message = "Converted \(result.successCount) of \(urls.count) item(s). Originals preserved."
                let failures = result.files.compactMap { item in item.error.map { item.sourceURL.lastPathComponent + ": " + $0 } }
                let notices = result.files.compactMap { item in
                    item.notice.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.sourceURL.lastPathComponent + ": " + $0 }
                }
                if !notices.isEmpty {
                    message += " \(notices.count) conversion notice(s)."
                    showError("Conversion notices", detail: notices.joined(separator: "\n\n"))
                }
                if !failures.isEmpty { showError("Some conversions failed", detail: failures.joined(separator: "\n")) }
            } catch is CancellationError { message = "Conversion cancelled. Originals preserved." }
            catch { message = error.localizedDescription; showError("Conversion failed", detail: error.localizedDescription) }
        }
    }

    func performToolTask(_ label: String, operation: @escaping @Sendable () async throws -> [URL], after: (([URL]) -> Void)? = nil) {
        guard !isConverting else { message = "Another file operation is running."; return }
        isConverting = true; progress = label + "…"
        conversionTask = Task {
            defer { isConverting = false; progress = ""; conversionTask = nil }
            do {
                let outputs = try await operation()
                if !outputs.isEmpty { add(outputs) }
                after?(outputs)
                message = label + " completed. \(outputs.count) new output(s); originals preserved."
            } catch is CancellationError { message = label + " cancelled; completed outputs may remain. Originals preserved." }
            catch {
                message = label + " stopped. Earlier completed outputs may remain in the chosen folder; originals are preserved."
                showError(label + " stopped", detail: error.localizedDescription + "\n\nEarlier completed outputs may remain in the chosen folder. Originals were preserved.")
            }
        }
    }
    func moveFiles(_ urls: [URL], to directory: URL) {
        guard !isConverting else { return }
        isConverting = true; progress = "Moving files…"
        conversionTask = Task {
            let task = Task.detached { LocalFileTools.move(urls, to: directory) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            applyMoves(result)
            isConverting = false; progress = ""; conversionTask = nil
        }
    }
    func applyMoves(_ result: FileMoveResult) {
        var nextSelection = selection
        for move in result.moved {
            if shelf.items.contains(where: { $0.id == move.source.path }) {
                shelf.remove(ids: [move.source.path]); _ = shelf.add([move.destination])
            }
            if nextSelection.remove(move.source.path) != nil { nextSelection.insert(move.destination.path) }
            if missingFiles.contains(move.source) { missingFiles.removeAll { $0 == move.source }; _ = shelf.add([move.destination]) }
        }
        selection = nextSelection
        persist()
        message = "Moved \(result.moved.count) item(s). \(result.failures.count) failed."
        if !result.failures.isEmpty { showError("Some files could not be moved", detail: result.failures.joined(separator: "\n")) }
    }

    func showError(_ title: String, detail: String) {
        if let errorPresenter { errorPresenter(title, detail); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func validatedActionItems() -> [ShelfItem] {
        let result = FileIntake.inspect(actionItems.map(\.url))
        if !result.rejected.isEmpty {
            showError("Some files are no longer accessible", detail: result.rejected.map { "\($0.url.lastPathComponent): \($0.reason)\nRemove this item from the shelf and add it again if it moved." }.joined(separator: "\n\n"))
        }
        return result.accepted
    }
}

@MainActor
private final class PreviewController: NSResponder, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}
