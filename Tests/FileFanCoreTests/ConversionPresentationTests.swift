import Foundation
import Testing
@testable import FileFanCore

struct ConversionPresentationTests {
    private func target(_ id: String, _ category: String, available: Bool = true, preset: String? = nil) -> ConversionTarget {
        .init(id: preset.map { "preset:" + $0 } ?? "format:" + id, name: id.uppercased(), category: category, targetFormatID: id, presetID: preset, isAvailable: available, unavailableReason: available ? nil : "Missing engine")
    }
    @Test func pngPrioritizesAllImagesTogetherInCommonFormatOrder() {
        let input = [target("zip", "Archive"), target("webp", "Image"), target("tiff", "Image"), target("jpg", "Image"), target("png", "Image"), target("svg", "Vector")]
        let groups = ConversionPresentation.groups(targets: input, sourceURLs: [URL(fileURLWithPath: "/tmp/source.PNG")])
        #expect(groups.first?.id == "images")
        #expect(groups.first?.targets.map(\.targetFormatID) == ["png", "jpg", "webp", "tiff", "svg"])
        #expect(groups.flatMap(\.targets).count == input.count)
    }
    @Test func mixedInputFamiliesKeepFirstSeenOrderAndAvailabilityRemainsUnchanged() {
        let input = [target("mp3", "Audio"), target("xlsx", "Spreadsheet"), target("docx", "Document", available: false), target("pdf", "Pdf"), target("png", "Image")]
        let groups = ConversionPresentation.groups(targets: input, sourceURLs: [URL(fileURLWithPath: "/tmp/table.xlsx"), URL(fileURLWithPath: "/tmp/letter.docx")])
        #expect(groups.prefix(2).map(\.id) == ["spreadsheets", "documents"])
        #expect(groups[1].targets.map(\.targetFormatID) == ["pdf", "docx"])
        #expect(groups.flatMap(\.targets).first { $0.targetFormatID == "docx" }?.isAvailable == false)
    }
    @Test func unknownInputUsesAvailableGroupsBeforeUnavailableWithoutInventingSourceFamily() {
        let groups = ConversionPresentation.groups(targets: [target("png", "Image", available: false), target("zip", "Archive")], sourceURLs: [URL(fileURLWithPath: "/tmp/unknown.abcdef")])
        #expect(groups.map(\.id) == ["archives", "images"])
        #expect(groups.allSatisfy { !$0.matchesSource })
    }
    @Test func longestArchiveSuffixAndSearchPreserveFamilyPriority() {
        let input = [target("png", "Image"), target("zip", "Archive"), target("7z", "Archive"), target("mp3", "Audio")]
        let groups = ConversionPresentation.groups(targets: input, sourceURLs: [URL(fileURLWithPath: "/tmp/input.tar.gz")], search: "archive")
        #expect(groups.map(\.id) == ["archives"])
        #expect(groups[0].matchesSource)
        #expect(groups[0].targets.map(\.targetFormatID) == ["zip", "7z"])
    }
    @Test func nativeJpegAliasWinsUnavailableBackendDuplicateWithoutRemovingPresets() {
        let native = ConversionTarget(id: "native:jpeg", name: "JPEG", category: "Image", targetFormatID: "jpeg", isAvailable: true)
        let input = [target("jpg", "Image", available: false), native, target("png", "Image", preset: "resize")]
        let groups = ConversionPresentation.groups(targets: input, sourceURLs: [URL(fileURLWithPath: "/tmp/source.jpeg")])
        #expect(groups[0].targets.map(\.id) == ["native:jpeg", "preset:resize"])
        #expect(groups[0].matchesSource)
    }
    @Test func completeWritableImageFamilyIsExpandedAndWheelUsesIdenticalOrder() {
        let inventory = ConversionCatalog.formats.filter(\.writable)
        let targets = inventory.map { format in
            ConversionTarget(id: "format:" + format.id, name: format.name, category: format.category, targetFormatID: format.id, isAvailable: true)
        }
        let sources = [URL(fileURLWithPath: "/tmp/source.png")]
        let groups = ConversionPresentation.groups(targets: targets, sourceURLs: sources)
        let images = groups.first!
        let expectedImages = inventory.filter { ["Image", "Vector"].contains($0.category) }
        #expect(images.id == "images")
        #expect(images.targets.count == expectedImages.count)
        #expect(Set(images.targets.map(\.targetFormatID)) == Set(expectedImages.map(\.id)))
        #expect(groups.flatMap(\.targets).count == targets.count)
        #expect(ConversionPresentation.orderedTargets(targets, sourceURLs: sources).map(\.id) == groups.flatMap(\.targets).map(\.id))
    }

}
