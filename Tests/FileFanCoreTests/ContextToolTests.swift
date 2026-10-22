import Foundation
import Testing
@testable import FileFanCore

struct ContextToolTests {
    @Test func imageAndVideoCommandMenusMatchRequestedOrder() {
        #expect(ContextToolCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.png")]).map(\.id) == [.compress, .metadata, .edit, .annotate, .background, .crop, .redact])
        #expect(ContextToolCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.mp4")]).map(\.id) == [.compress, .metadata, .mute, .trim, .crop, .speed, .snapshot, .redact, .split])
        #expect(ContextToolCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.pdf")]).map(\.id) == [.compress, .metadata, .merge, .split, .pages, .annotate])
    }
    @Test func controlIsInvariantAndUnknownOrMixedCommandsStaySafe() {
        let urls = ["a.png", "a.docx", "a.unknown"].map { URL(fileURLWithPath: "/tmp/" + $0) }
        for input in [[urls[0]], [urls[1]], [urls[2]], urls, []] {
            #expect(ContextToolCatalog.fileActions(for: input).map(\.id) == [.airdrop, .float, .copy, .move, .copyPath, .terminal])
        }
        #expect(ContextToolCatalog.tools(for: [urls[2]]).map(\.id) == [.metadata, .zip])
        #expect(ContextToolCatalog.tools(for: Array(urls.prefix(2))).map(\.id) == [.metadata])
        #expect(ContextToolCatalog.tools(for: [urls[0]], folders: [urls[0]]).map(\.id) == [.metadata, .zip])
    }
    @Test func archiveSuffixAndBackendEligibilityArePreserved() {
        let items = ContextToolCatalog.tools(for: [URL(fileURLWithPath: "/tmp/a.tar.gz")])
        #expect(items.map(\.id) == [.extract, .zip, .metadata])
        #expect(items.first?.isAvailable == false)
        #expect(items.first?.reason != nil)
    }
    @Test func unsupportedOfficeEditRequiresActualDocxConversionBeforeTextEdit() {
        let pages = [URL(fileURLWithPath: "/tmp/document.pages")]
        #expect(ContextToolCatalog.tools(for: pages).first { $0.id == .edit }?.isAvailable == false)
        let docx = targetForEdit()
        let edit = ContextToolCatalog.tools(for: pages, targets: [docx]).first { $0.id == .edit }
        #expect(edit?.isAvailable == true && edit?.targetID == "format:docx")
        #expect(ContextToolCatalog.tools(for: [URL(fileURLWithPath: "/tmp/document.docx")]).first { $0.id == .edit }?.isAvailable == true)
    }
    private func targetForEdit() -> ConversionTarget {
        .init(id: "format:docx", name: "DOCX", category: "Document", targetFormatID: "docx", isAvailable: true)
    }

}
