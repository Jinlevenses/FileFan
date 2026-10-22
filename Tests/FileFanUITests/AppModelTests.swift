import FileFanCore

import AppKit
import Testing
@testable import FileFan

@MainActor
struct AppModelTests {
    @Test func duplicateAndMixedDropsReplaceThePreviousActionSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["A.txt", "B.txt", "C.txt"].map { directory.appendingPathComponent($0) }
        for url in urls { try Data("fixture".utf8).write(to: url) }
        let model = AppModel()
        model.add(Array(urls.prefix(2)))
        model.selection = [urls[1].resolvingSymlinksInPath().path]

        model.add([urls[0]])
        #expect(model.actionItems.map(\.displayName) == ["A.txt"])
        #expect(model.shelf.items.count == 2)

        model.add([urls[0], urls[2]])
        #expect(model.actionItems.map(\.displayName) == ["A.txt", "C.txt"])
        #expect(model.shelf.items.count == 3)
    }

    @Test func invalidDropCannotTargetThePreviousShelfContext() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var errors: [String] = []
        let model = AppModel(errorPresenter: { title, _ in errors.append(title) })
        model.add([file])

        model.add([URL(string: "https://example.com/remote.txt")!])

        #expect(model.selection.isEmpty)
        #expect(model.actionItems.isEmpty)
        #expect(model.shelf.items.count == 1)
        #expect(errors.count == 1)
        model.selection = [file.resolvingSymlinksInPath().path]
        #expect(model.actionItems.count == 1)
        model.add([])
        #expect(model.actionItems.isEmpty)
    }

    @Test func copiedPathsUseTheCurrentValidatedSymlinkDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let replacement = directory.appendingPathComponent("replacement.txt")
        try Data("original".utf8).write(to: original)
        try Data("replacement".utf8).write(to: replacement)
        var copied: String?
        let model = AppModel(copyText: { copied = $0; return true })
        model.add([original])
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)

        model.copyPaths()

        #expect(copied == replacement.resolvingSymlinksInPath().path)
    }

    @Test func failedClipboardWriteDoesNotReportCopiedPaths() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var errors: [String] = []
        let model = AppModel(errorPresenter: { title, _ in errors.append(title) }, copyText: { _ in false })
        model.add([file])

        model.copyPaths()

        #expect(!model.message.hasPrefix("Copied"))
        #expect(model.message.contains("clipboard"))
        #expect(errors.count == 1)
    }

    @Test func removedSourceIsNotAdvertisedByTheExternalDragWriter() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: file)
        let model = AppModel()
        model.add([file])
        let coordinator = FileTable.Coordinator(model: model)
        coordinator.items = model.shelf.items
        try FileManager.default.removeItem(at: file)

        let writer = coordinator.tableView(NSTableView(), pasteboardWriterForRow: 0)

        #expect(writer == nil)
        #expect(model.message.contains("no longer accessible"))
    }
}

@MainActor
struct SessionModelTests {
    @Test func missingRecordsSurviveOtherShelfChangesUntilExplicitRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileFanCore.SessionStore(directory: directory.appendingPathComponent("state"))
        let missing = directory.appendingPathComponent("missing.txt")
        var state = FileFanCore.SessionState()
        state.files = [missing]
        try store.save(state)
        let model = AppModel(sessionStore: store)
        #expect(model.missingFiles == [missing])
        let file = directory.appendingPathComponent("exists.txt")
        try Data("fixture".utf8).write(to: file)
        model.add([file])
        #expect(store.load().state.files.contains(missing))
        model.removeMissing(missing)
        #expect(!store.load().state.files.contains(missing))
        #expect(store.load().state.files.contains(file))
    }
}

@MainActor
struct NativeCancellationTests {
    @Test func cancelBeforeNativeBatchStartsProducesNoOutputsAndStopsProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = AppModel()
        model.add([source])
        model.startNativeConversion(items: model.actionItems, directory: output, format: .png)
        model.cancelConversion()
        for _ in 0..<1000 {
            if !model.isConverting { break }
            await Task.yield()
        }
        #expect(!model.isConverting)
        #expect(model.message.contains("cancelled"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

@MainActor
struct NativeQualityTests {
    @Test func jpegFallbackUsesCurrentSliderQualityAndPreservesSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("noise.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        var seed: UInt32 = 1234567
        for y in 0..<128 {
            for x in 0..<128 {
                let offset = y * bitmap.bytesPerRow + x * 4
                for channel in 0..<3 {
                    seed = seed &* 1664525 &+ 1013904223
                    pixels[offset + channel] = UInt8(truncatingIfNeeded: seed >> 24)
                }
                pixels[offset + 3] = 255
            }
        }
        let original = bitmap.representation(using: .png, properties: [:])!
        try original.write(to: source)
        var sizes: [Int] = []
        for quality in [10.0, 100.0] {
            let output = directory.appendingPathComponent("quality-\(Int(quality))")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = AppModel()
            model.add([source]); model.quality = quality
            model.startNativeConversion(items: model.actionItems, directory: output, format: .jpeg)
            for _ in 0..<2000 {
                if !model.isConverting { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(!model.isConverting)
            let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            let image = try #require(files.first)
            sizes.append(try Data(contentsOf: image).count)
        }
        #expect(sizes[1] > sizes[0] * 2)
        #expect(try Data(contentsOf: source) == original)
    }
}
