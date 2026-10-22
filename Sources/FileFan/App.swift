import AppKit
import SwiftUI
import FileFanCore

@main
enum FileFanApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(sessionStore: .application)
    private var statusItem: NSStatusItem!
    private var shelfPanel: NSPanel!
    private var dockController: ShelfDockController!
    private let gestures = GlobalGestureController()
    private let dragPanel = DragWheelPanel()
    private let dragView = DragWheelView(frame: .init(x: 0, y: 0, width: 360, height: 360))
    private var wheelRequest = UUID()
    private var wheelTargets: [ConversionTarget] = []
    private var wheelPage = 0
    private lazy var contextTools = ContextToolController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        model.showShelf = { [weak self] in self?.showShelf() }
        model.showFan = { [weak self] in self?.showFan() }
        shelfPanel = makePanel(title: "FileFan", size: .init(width: 600, height: 510), resizable: true)
        shelfPanel.minSize = .init(width: 520, height: 420)
        shelfPanel.contentView = NSHostingView(rootView: ShelfView(model: model))
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "FileFan")
            button.toolTip = "FileFan — click for actions, or drop local files"
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.model = model
            drop.showMenu = { [weak self] in self?.openStatusMenu() }
            button.addSubview(drop)
        }
        dockController = ShelfDockController(panel: shelfPanel, model: model)
        dragPanel.contentView = dragView
        dragView.cancel = { [weak self] in self?.gestures.cancel() }
        gestures.enabled = { [weak self] in self?.model.gesturesEnabled ?? false }
        gestures.hide = { [weak self] in
            guard let self else { return }
            let returnFocus = self.dragPanel.allowsKey && self.dragPanel.isKeyWindow && NSApp.isActive
            self.dragPanel.orderOut(nil)
            self.dragPanel.allowsKey = false
            self.wheelRequest = UUID()
            if returnFocus, self.shelfPanel.isVisible { self.shelfPanel.makeKeyAndOrderFront(nil) }
        }
        gestures.show = { [weak self] mode, urls, point in self?.showDragWheel(mode: mode, urls: urls, at: point) }
        gestures.start()
        model.refreshTargets()
        if model.session.dock == nil { showShelf() }
    }

    private func showDragWheel(mode: GestureMode, urls: [URL], at point: CGPoint, interactive: Bool = false) {
        wheelPage = 0
        dragView.contextURLs = urls
        dragView.summary = ContextToolController.summary(urls)
        let request = UUID(); wheelRequest = request
        dragView.heading = mode == .convert ? "Convert" : mode == .actions ? "Actions" : "Tools"
        dragView.actions = []
        var frame = CGRect(x: point.x - 180, y: point.y - 180, width: 360, height: 360)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
        }
        dragPanel.allowsKey = interactive
        dragPanel.title = mode == .actions ? "FileFan Actions" : mode == .tools ? "FileFan Tools" : "FileFan Convert"
        dragPanel.setFrame(frame, display: true)
        if interactive { dragPanel.makeKeyAndOrderFront(nil) }
        else { dragPanel.orderFrontRegardless() }
        if mode == .convert {
            Task {
                let targets = await model.targets(for: urls)
                guard wheelRequest == request else { return }
                wheelTargets = targets; renderConversionPage()
            }
        } else if mode == .actions {
            renderContextTools(ContextToolCatalog.fileActions(for: urls), universal: true)
        } else {
            Task {
                let tools = await contextTools.tools(for: urls)
                guard wheelRequest == request else { return }
                renderContextTools(tools, universal: false)
            }
        }
    }
    private func renderContextTools(_ tools: [ContextTool], universal: Bool) {
        dragView.actions = tools.map { tool in
            WheelAction(title: tool.title, detail: tool.reason ?? tool.title + " for the current files. Originals are preserved except an explicit Move.", enabled: tool.isAvailable, run: { [weak self] urls in
                self?.contextTools.run(tool.id, urls: urls, universal: universal)
            })
        }
    }
    private func showSelectedWheel(_ mode: GestureMode) {
        let urls = model.actionItems.map(\.url)
        guard !urls.isEmpty else { model.showError("Select files first", detail: "Add accessible files to the shelf and select the items to use."); return }
        NSApp.activate(ignoringOtherApps: true)
        showDragWheel(mode: mode, urls: urls, at: NSEvent.mouseLocation, interactive: true)
    }

    private func renderConversionPage() {
        let count = 8
        let pages = max(1, Int(ceil(Double(wheelTargets.count) / Double(count))))
        wheelPage = min(max(0, wheelPage), pages - 1)
        let targets = wheelTargets.dropFirst(wheelPage * count).prefix(count)
        var actions = targets.map { target in
            WheelAction(title: target.name, detail: target.unavailableReason ?? "Drop to convert to \(target.name).", enabled: target.isAvailable, run: { [weak self] urls in
                guard let self else { return }
                Task {
                    let current = await self.model.targets(for: urls)
                    guard current.contains(where: { $0.id == target.id && $0.isAvailable }) else {
                        self.model.showError("Conversion unavailable", detail: "The actual dropped files do not share this conversion target."); return
                    }
                    self.model.convert(urls, target: target)
                }
            })
        }
        if pages > 1 {
            actions.append(WheelAction(title: "Next ›", detail: "Hover to browse the next eight formats.", enabled: true, run: { [weak self] urls in self?.model.add(urls); self?.model.showShelf?(); self?.model.browseConversions() }, hover: { [weak self] in
                guard let self else { return }; self.wheelPage = (self.wheelPage + 1) % pages; self.renderConversionPage()
            }))
        }
        if actions.isEmpty {
            actions = [WheelAction(title: "Float / Add", detail: "No shared conversion targets. Keep these files on the shelf.", enabled: true, run: { [weak self] urls in self?.model.add(urls); self?.showShelf() })]
        }
        dragView.heading = "Convert \(wheelPage + 1)/\(pages)"
        dragView.actions = actions
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "FileFan")
        let quit = NSMenuItem(title: "Quit FileFan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        let appItem = NSMenuItem(title: "FileFan", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let shelfMenu = NSMenu(title: "Shelf")
        addItem("Tools for Selected Files", action: #selector(showToolsAction), key: "", to: shelfMenu)
        addItem("File Actions for Selected Files", action: #selector(showFanAction), key: "", to: shelfMenu)
        shelfMenu.addItem(.separator())
        addDockItems(to: shelfMenu, keyboardShortcuts: true)
        let shelfItem = NSMenuItem(title: "Shelf", action: nil, keyEquivalent: "")
        shelfItem.submenu = shelfMenu
        mainMenu.addItem(shelfItem)
        NSApp.mainMenu = mainMenu
    }

    private func makePanel(title: String, size: NSSize, resizable: Bool) -> NSPanel {
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow]
        if resizable { style.insert(.resizable) }
        let panel = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.center()
        return panel
    }

    func showShelf() {
        NSApp.activate(ignoringOtherApps: true)
        dockController.show()
    }

    func showFan() {
        showSelectedWheel(.actions)
    }

    private func openStatusMenu() {
        let menu = NSMenu()
        addItem("Show FileFan", action: #selector(showShelfAction), key: "o", to: menu)
        addItem("File Actions for Selected Files", action: #selector(showFanAction), key: "", to: menu)
        addItem("Tools for Selected Files", action: #selector(showToolsAction), key: "", to: menu)
        addItem("Add Files or Folders…", action: #selector(addAction), key: "", to: menu)
        let dockMenu = NSMenu(title: "Dock Shelf")
        addDockItems(to: dockMenu, keyboardShortcuts: false)
        let dockItem = NSMenuItem(title: "Dock Shelf", action: nil, keyEquivalent: "")
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)
        let gestureToggle = NSMenuItem(title: "Global Drag Gestures", action: #selector(toggleGestures), keyEquivalent: "")
        gestureToggle.target = self; gestureToggle.state = model.gesturesEnabled ? .on : .off
        menu.addItem(gestureToggle)
        menu.addItem(.separator())
        addItem("Quit FileFan", action: #selector(quitAction), key: "q", to: menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func addItem(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func addDockItems(to menu: NSMenu, keyboardShortcuts: Bool) {
        for (title, action, arrow) in [
            ("Dock Left", #selector(dockLeftAction), "\u{F702}"),
            ("Dock Right", #selector(dockRightAction), "\u{F703}"),
            ("Dock Top", #selector(dockTopAction), "\u{F700}"),
            ("Dock Bottom", #selector(dockBottomAction), "\u{F701}")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyboardShortcuts ? arrow : "")
            item.target = self
            if keyboardShortcuts { item.keyEquivalentModifierMask = [.command, .option] }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let undock = NSMenuItem(title: "Undock Shelf", action: #selector(undockAction), keyEquivalent: keyboardShortcuts ? "u" : "")
        undock.target = self
        if keyboardShortcuts { undock.keyEquivalentModifierMask = [.command, .option] }
        menu.addItem(undock)
    }

    @objc private func dockLeftAction() { dockController.dock(to: .left) }
    @objc private func dockRightAction() { dockController.dock(to: .right) }
    @objc private func dockTopAction() { dockController.dock(to: .top) }
    @objc private func dockBottomAction() { dockController.dock(to: .bottom) }
    @objc private func undockAction() { NSApp.activate(ignoringOtherApps: true); dockController.undock() }
    @objc private func showShelfAction() { showShelf() }
    @objc private func showFanAction() { showFan() }
    @objc private func showToolsAction() { showSelectedWheel(.tools) }
    @objc private func addAction() { model.chooseFiles() }
    @objc private func toggleGestures() { model.gesturesEnabled.toggle() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) { model.add(urls); showShelf() }
}

@MainActor
private final class StatusDropView: NSView {
    weak var model: AppModel?
    var showMenu: (() -> Void)?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]); setAccessibilityLabel("FileFan menu. Drop files to add them.") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { showMenu?() }
    override func rightMouseDown(with event: NSEvent) { showMenu?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { model?.add([]); return false }
        model?.add(urls)
        model?.showShelf?()
        return true
    }
}
