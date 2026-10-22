import AppKit
import FileFanCore
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Image(systemName: "folder.badge.plus").font(.system(size: 27)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("FileFan").font(.title2.weight(.semibold))
                    Text("A floating shelf for your files").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showFan?() } label: { Label("Actions", systemImage: "circle.hexagongrid") }
                    .help("Open the radial file action menu")
                Button { model.chooseFiles() } label: { Label("Add", systemImage: "plus") }
            }.padding(18)

            DropZone(model: model, compact: true).padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            if !model.missingFiles.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Saved items unavailable — originals may have moved").font(.caption.weight(.semibold))
                    ForEach(model.missingFiles, id: \.absoluteString) { url in
                        HStack {
                            Text(url.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Locate…") { model.recoverMissing(url) }
                            Button("Remove") { model.removeMissing(url) }
                        }
                    }
                }.padding(10).background(Color.orange.opacity(0.1))
            }
            if model.shelf.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Your shelf is empty").font(.headline)
                    Text("Add files or folders, then drag them into another app.\nSelect several items with Shift or Command.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in receive(providers, into: model) }
            } else {
                FileTable(model: model).frame(minHeight: 150)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Group {
                        Button("Open", action: model.open)
                        Button("Reveal", action: model.reveal)
                        Button("Copy Paths", action: model.copyPaths)
                        Button("Preview", action: model.quickLook)
                    }.disabled(model.actionItems.isEmpty)
                    Spacer(minLength: 4)
                    Button { model.removeSelection() } label: { Image(systemName: "minus.circle") }
                        .help("Remove selected items from the shelf; keep files on disk")
                        .accessibilityLabel("Remove selected items from shelf")
                        .disabled(model.selection.isEmpty)
                    Button("Clear", action: model.clear).disabled(model.shelf.items.isEmpty)
                }.disabled(model.shelf.items.isEmpty)
                HStack {
                    Text("Convert:").font(.caption).foregroundStyle(.secondary)
                    Button("PNG") { model.convert(to: .png) }
                    Button("JPEG") { model.convert(to: .jpeg) }
                    Button("All Formats…") { model.browseConversions() }
                    TextField("Max pixels (optional)", text: $model.maxDimension).textFieldStyle(.roundedBorder).frame(width: 150)
                        .accessibilityLabel("Optional maximum image dimension in pixels")
                    Spacer()
                    Text(model.selection.isEmpty ? "\(model.shelf.items.count) items" : "\(model.selection.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.isConverting || model.actionItems.isEmpty)
                if model.isConverting {
                    HStack { ProgressView().controlSize(.small); Text(model.progress).font(.caption).lineLimit(1); Button("Cancel", action: model.cancelConversion) }
                } else {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(14)
        }
        .frame(minWidth: 520, minHeight: 390)
        .background(.background)
        .sheet(isPresented: $model.showingConversionBrowser) { ConversionBrowser(model: model) }
    }
}

struct ConversionBrowser: View {
    @ObservedObject var model: AppModel
    private var groups: [ConversionTargetGroup] {
        ConversionPresentation.groups(targets: model.conversionTargets, sourceURLs: model.actionItems.map(\.url), search: model.conversionSearch)
    }
    private let formatColumns = [GridItem(.adaptive(minimum: 76, maximum: 112), spacing: 8)]
    private let actionColumns = [GridItem(.adaptive(minimum: 156, maximum: 260), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Convert dropped or selected files").font(.title2); Spacer(); Button("Done") { model.showingConversionBrowser = false } }
            TextField("Search formats and actions", text: $model.conversionSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search formats and actions")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Label(group.title, systemImage: symbol(for: group.id)).font(.headline)
                                Text("\(group.targets.count)").font(.caption).foregroundStyle(.secondary)
                                if group.matchesSource {
                                    Text("Source type").font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                            }
                            LazyVGrid(columns: formatColumns, alignment: .leading, spacing: 8) {
                                ForEach(group.targets.filter { $0.presetID == nil }) { target in formatButton(target) }
                            }
                            let actions = group.targets.filter { $0.presetID != nil }
                            if !actions.isEmpty {
                                LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 8) {
                                    ForEach(actions) { target in formatButton(target) }
                                }
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text(model.conversionTargets.isEmpty ? "Checking conversion targets…" : "No formats match your search.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 24)
                    }
                }.padding(.horizontal, 2).padding(.vertical, 4)
            }
            HStack(spacing: 9) {
                Text("Quality"); Slider(value: $model.quality, in: 1...100, step: 1).frame(width: 100); Text("\(Int(model.quality))").monospacedDigit().frame(width: 25)
                Spacer(minLength: 8)
                Text("Max pixels")
                TextField("Original", text: $model.maxDimension).textFieldStyle(.roundedBorder).frame(width: 75)
                    .accessibilityLabel("Maximum image dimension in pixels; empty preserves original size")
                Text("PDF pages")
                TextField("All", text: $model.pageRange).textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("PDF page range; empty selects all pages")
            }.font(.caption)
            Toggle("Enable global drag gestures", isOn: $model.gesturesEnabled)
            Text("While dragging local files in any app, tap Shift for conversions, Control for actions, or Command for tools. Drop on a sector; hover Next to browse the wheel. Escape cancels. Outputs use a chosen folder.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 740, height: 620)
    }

    private func formatButton(_ target: ConversionTarget) -> some View {
        Button {
            model.showingConversionBrowser = false
            model.convert(model.actionItems.map(\.url), target: target)
        } label: {
            Text(target.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Convert to \(target.name)")
        .accessibilityHint(target.unavailableReason ?? "Choose an output folder for the converted files.")
        .help("Convert to \(target.name)" + (target.unavailableReason.map { "\n" + $0 } ?? ""))
        .disabled(!target.isAvailable || model.isConverting)
    }
    private func symbol(for family: String) -> String {
        switch family {
        case "images": return "photo"
        case "documents": return "doc.text"
        case "spreadsheets": return "tablecells"
        case "audio": return "waveform"
        case "video": return "film"
        case "archives": return "archivebox"
        case "presentations": return "rectangle.on.rectangle"
        case "ebooks": return "book"
        case "subtitles": return "captions.bubble"
        case "data": return "curlybraces"
        case "fonts": return "textformat"
        case "cad": return "ruler"
        case "models": return "cube"
        default: return "doc"
        }
    }
}

private struct DropZone: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    var body: some View {
        Group {
            if compact {
                HStack { Image(systemName: "arrow.down.doc"); Text("Drop files or folders here").font(.callout); Spacer(); Text("Local files only").font(.caption).foregroundStyle(.secondary) }.padding(13)
            } else {
                VStack(spacing: 7) { Image(systemName: "arrow.down.doc").font(.system(size: 26)); Text("Drop to add").font(.caption.weight(.medium)) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(model.isDropTargeted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 25))
        .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 25).strokeBorder(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in receive(providers, into: model) }
        .accessibilityLabel("Drop local files or folders to add them to FileFan")
    }
}

@MainActor
private func receive(_ providers: [NSItemProvider], into model: AppModel) -> Bool {
    let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !providers.isEmpty else { return false }
    Task {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    if let url = value as? URL { continuation.resume(returning: url) }
                    else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else { continuation.resume(returning: nil) }
                }
            }
            if let url { urls.append(url) }
        }
        model.add(urls)
    }
    return true
}
