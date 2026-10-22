import AppKit
import FileFanCore
import SwiftUI

struct FileTable: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ShelfTableView()
        table.model = model
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.headerView = nil
        table.rowHeight = 52
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.style = .fullWidth
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.open)
        table.setAccessibilityLabel("File shelf. Select files, press Space to preview, or drag files to another application.")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.updating = true
        coordinator.items = model.shelf.items
        coordinator.table?.reloadData()
        coordinator.table?.selectRowIndexes(IndexSet(coordinator.items.indices.filter { model.selection.contains(coordinator.items[$0].id) }), byExtendingSelection: false)
        coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AppModel
        var items: [ShelfItem] = []
        weak var table: NSTableView?
        var updating = false
        init(model: AppModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: item.url.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
            let name = NSTextField(labelWithString: item.displayName)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            let path = NSTextField(labelWithString: item.url.deletingLastPathComponent().path)
            path.font = .systemFont(ofSize: 10)
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            let labels = NSStackView(views: [name, path])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
            let stack = NSStackView(views: [icon, labels])
            stack.spacing = 10
            stack.edgeInsets = .init(top: 5, left: 12, bottom: 5, right: 12)
            stack.setAccessibilityLabel(item.displayName + ", " + item.url.path)
            return stack
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = items[row]
            guard let accessible = FileIntake.inspect([item.url]).accepted.first else {
                model.message = "\(item.displayName) is no longer accessible. Remove it from the shelf and add it again if it moved."
                return nil
            }
            return accessible.url as NSURL
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = fileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { model.add([]); return false }
            model.add(urls)
            return true
        }
        @objc func open() { model.open() }
    }
}

@MainActor
private final class ShelfTableView: NSTableView {
    weak var model: AppModel?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { model?.quickLook() }
        else if event.keyCode == 51 || event.keyCode == 117 { model?.removeSelection() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { model?.copyPaths(); return true }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" { selectAll(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
}
