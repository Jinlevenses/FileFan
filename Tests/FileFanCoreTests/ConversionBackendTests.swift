import Foundation
import Testing
@testable import FileFanCore

@Suite struct ConversionBackendTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileFanBackendTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func inventoryIsCompleteAndDoesNotTreatReadOnlyFormatsAsTargets() async {
        let backend = ConversionBackend(executableURL: nil)
        let formats = await backend.formats()
        #expect(formats.count == 244)
        #expect(Set(formats.map(\.category)).count == 17)
        #expect(ConversionCatalog.format(for: URL(fileURLWithPath: "/tmp/photo.CR3"))?.id == "raw")
        #expect(ConversionCatalog.format(for: URL(fileURLWithPath: "/tmp/a.tar.gz"))?.id == "tgz")
        #expect(formats.first { $0.id == "scc" }?.writable == false)
        let targets = await backend.targets(for: [URL(fileURLWithPath: "/tmp/a.png")])
        #expect(targets.allSatisfy { !$0.isAvailable && $0.unavailableReason != nil })
        #expect(!targets.contains { $0.targetFormatID == "raw" })
    }

    @Test func parsesInstalledAndOptionalRoutesSeparately() throws {
        let data = Data("PNG (png) converts to:\n  jpg, webp\nWith optional engines (install them in Filee, Settings → Engines):\n  heic, eps\n".utf8)
        let result = try RouteAvailability.parse(data)
        #expect(result.current == ["jpg", "webp"])
        #expect(result.optional == ["heic", "eps"])
        #expect(throws: (any Error).self) { try RouteAvailability.parse(Data("error".utf8)) }
    }

    @Test func jsonRejectsOutsidePathsWrongSourcesAndCountMismatch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt"), output = stage.appendingPathComponent("out.txt")
        try Data("source".utf8).write(to: source)
        try Data("out".utf8).write(to: output)
        func json(path: String, count: Int = 1, input: String? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["converted": count, "skipped": 0, "failed": 0,
                                                        "files": [["source": input ?? source.path, "state": "done", "outputs": [path]]]])
        }
        #expect(try BackendJSON.parse(json(path: output.path), expectedSources: [source], stage: stage).count == 1)
        #expect(throws: (any Error).self) { try BackendJSON.parse(json(path: source.path), expectedSources: [source], stage: stage) }
        #expect(throws: (any Error).self) { try BackendJSON.parse(json(path: output.path, count: 2), expectedSources: [source], stage: stage) }
        #expect(throws: (any Error).self) { try BackendJSON.parse(json(path: output.path, input: "/tmp/other"), expectedSources: [source], stage: stage) }
        let link = stage.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try BackendJSON.parse(json(path: link.path), expectedSources: [source], stage: stage) }
    }

    @Test func processDrainsBothPipesAndCancellationTerminates() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tool")
        try Data("#!/bin/zsh\nfor n in {1..5000}; do print 'stdout data'; print -u2 'stderr data'; done\nexit 7\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try await BackendProcess.run(executable: script, arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 5)
        #expect(result.status == 7)
        #expect(result.standardOutput.count > 40_000)
        #expect(result.standardError.count > 40_000)
        try Data("#!/bin/zsh\nexec /bin/sleep 30\n".utf8).write(to: script)
        let task = Task { try await BackendProcess.run(executable: script, arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled process succeeded") }
        catch is CancellationError { }
        do {
            _ = try await BackendProcess.run(executable: script, arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 0.1)
            Issue.record("Deadline was ignored")
        } catch ConversionBackendError.timedOut { }
    }

    @Test func partialFailureRetainsSuccessfulOutputsAndNotices() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"), broken = root.appendingPathComponent("broken.pdf")
        let output = root.appendingPathComponent("out.pdf")
        try Data("ok".utf8).write(to: output)
        let json = try JSONSerialization.data(withJSONObject: ["converted": 1, "skipped": 0, "failed": 1, "files": [
            ["source": source.path, "state": "done", "outputs": [output.path], "notice": "Pictures were reduced"],
            ["source": broken.path, "state": "failed", "outputs": [], "error": "Damaged PDF"]
        ]])
        let result = try BackendJSON.parse(json, expectedSources: [source, broken], stage: root)
        #expect(result[0].notice == "Pictures were reduced")
        #expect(result[0].outputs == [output])
        #expect(result[1].error == "Damaged PDF")
    }

    @Test func customPresetsCarryOperationsAndNeverOverwrite() {
        let target = ConversionTarget(id: "preset:pdf-split", name: "Split", category: "Pdf", targetFormatID: "pdf", presetID: "pdf-split", isAvailable: true)
        let preset = ConversionBackend.preset(for: target, options: .init(quality: 80, maxPixelDimension: 320, pageRange: "1-3,5"))
        #expect((preset["pdf"] as? [String: Any])?["splitPages"] as? Bool == true)
        #expect((preset["pdf"] as? [String: Any])?["pageRange"] as? String == "1-3,5")
        #expect((preset["output"] as? [String: Any])?["conflict"] as? String == "Rename")
        #expect((preset["image"] as? [String: Any])?["longEdge"] as? Int == 320)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_BACKEND_EXECUTABLE"] != nil))
    func actualCLIRepresentativeConversionsPreserveSourcesAndExistingOutputs() async throws {
        guard let path = ProcessInfo.processInfo.environment["FILEFAN_BACKEND_EXECUTABLE"] else { return }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ConversionBackend(executableURL: URL(fileURLWithPath: path), dataDirectory: root.appendingPathComponent("state"))
        let fixtures: [(String, String, String)] = [
            ("sample.srt", "1\n00:00:00,000 --> 00:00:01,000\nHello 한글\n", "vtt"),
            ("sample.csv", "name,score\nAlice,10\nBob,20\n", "xlsx"),
            ("sample.json", "{\"name\":\"FileFan\",\"count\":2}", "yaml"),
            ("sample.txt", "FileFan offline document conversion 한글", "hwpx"),
            ("sample.obj", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n", "stl")
        ]
        for (name, contents, targetID) in fixtures {
            let source = root.appendingPathComponent(name)
            let original = Data(contents.utf8)
            try original.write(to: source)
            let targets = await backend.targets(for: [source])
            let target = try #require(targets.first { $0.id == "format:" + targetID && $0.isAvailable })
            let result = try await backend.convert(sourceURLs: [source], outputDirectory: root, target: target)
            #expect(result.successCount == 1, "\(name) → \(targetID): \(result.files.compactMap(\.error))")
            #expect(result.outputURLs.count == 1)
            #expect(try Data(contentsOf: source) == original)
            if let output = result.outputURLs.first {
                #expect(try Data(contentsOf: output).count > 0)
                let firstBytes = try Data(contentsOf: output)
                let second = try await backend.convert(sourceURLs: [source], outputDirectory: root, target: target)
                #expect(second.successCount == 1)
                #expect(second.outputURLs.first != output)
                #expect(try Data(contentsOf: output) == firstBytes)
                #expect(try Data(contentsOf: source) == original)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_BACKEND_EXECUTABLE"] != nil))
    func actualCombinedZipExtractionAndModelSiblingReferences() async throws {
        guard let path = ProcessInfo.processInfo.environment["FILEFAN_BACKEND_EXECUTABLE"] else { return }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ConversionBackend(executableURL: URL(fileURLWithPath: path), dataDirectory: root.appendingPathComponent("state"))
        let unknown = root.appendingPathComponent("raw.foo"), text = root.appendingPathComponent("note.txt")
        try Data("arbitrary bytes".utf8).write(to: unknown)
        try Data("hello".utf8).write(to: text)
        #expect(await backend.targets(for: [unknown]).contains { $0.presetID == "zip-all" && $0.isAvailable })
        let zipTarget = try #require(await backend.targets(for: [unknown, text]).first { $0.presetID == "zip-all" && $0.isAvailable })
        let zipped = try await backend.convert(sourceURLs: [unknown, text], outputDirectory: root, target: zipTarget)
        #expect(zipped.successCount == 2)
        let zip = try #require(zipped.outputURLs.first)
        let extraction = try #require(await backend.targets(for: [zip]).first { $0.presetID == "extract" && $0.isAvailable })
        let extracted = try await backend.convert(sourceURLs: [zip], outputDirectory: root, target: extraction)
        let folder = try #require(extracted.outputURLs.first)
        #expect(try Data(contentsOf: folder.appendingPathComponent("raw.foo")) == Data("arbitrary bytes".utf8))
        let obj = root.appendingPathComponent("colored.obj"), mtl = root.appendingPathComponent("color.mtl")
        try Data("newmtl Red\nKd 1 0 0\n".utf8).write(to: mtl)
        try Data("mtllib color.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl Red\nf 1 2 3\n".utf8).write(to: obj)
        let glbTarget = try #require(await backend.targets(for: [obj]).first { $0.id == "format:glb" && $0.isAvailable })
        let glbResult = try await backend.convert(sourceURLs: [obj], outputDirectory: root, target: glbTarget)
        let glb = try #require(glbResult.outputURLs.first)
        let objTarget = try #require(await backend.targets(for: [glb]).first { $0.id == "format:obj" && $0.isAvailable })
        let output = try await backend.convert(sourceURLs: [glb], outputDirectory: root, target: objTarget)
        let newOBJ = try #require(output.outputURLs.first { $0.pathExtension == "obj" })
        let contents = try String(contentsOf: newOBJ, encoding: .utf8)
        let material = try #require(contents.components(separatedBy: .newlines).first { $0.hasPrefix("mtllib ") })
        let referenced = String(material.dropFirst("mtllib ".count))
        #expect(FileManager.default.fileExists(atPath: newOBJ.deletingLastPathComponent().appendingPathComponent(referenced).path))
        #expect(newOBJ.deletingLastPathComponent().lastPathComponent.hasPrefix("FileFan OBJ"))
        #expect(try String(contentsOf: mtl, encoding: .utf8) == "newmtl Red\nKd 1 0 0\n")
    }
}
