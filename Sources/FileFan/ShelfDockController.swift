import AppKit
import FileFanCore

@MainActor
final class ShelfDockController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: AppModel
    private let tab = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var placement: DockPlacement?
    private var expanded = true
    private var adjusting = false
    private var mouseWasDown = false
    private var movedDuringPress = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    init(panel: NSPanel, model: AppModel) {
        self.panel = panel; self.model = model; self.placement = model.session.dock
        super.init()
        panel.delegate = self
        tab.level = .floating; tab.isOpaque = false; tab.backgroundColor = .clear
        tab.hasShadow = true; tab.hidesOnDeactivate = false; tab.isReleasedWhenClosed = false
        tab.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = DockTabView(frame: .zero)
        view.open = { [weak self] in self?.expand() }
        view.activate = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.show()
        }
        view.pull = { [weak self] point in self?.undock(at: point) }
        view.model = model
        tab.contentView = view
        restore()
        timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.restore() } }
    }
    private func screenID(_ screen: NSScreen) -> String { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "" }
    private func screen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let fallback = screens.firstIndex { $0 === NSScreen.main } ?? 0
        guard let index = DockGeometry.screenIndex(for: frame, visibleFrames: screens.map(\.visibleFrame), fallback: fallback) else { return nil }
        return screens[index]
    }
    private var dockScreen: NSScreen? {
        NSScreen.screens.first { screenID($0) == placement?.screenID } ?? screen(for: model.session.windowFrame ?? panel.frame) ?? NSScreen.main
    }

    func restore() {
        guard let screen = dockScreen else { return }
        adjusting = true
        if let placement {
            panel.setFrame(DockGeometry.frame(size: model.session.windowFrame?.size ?? panel.frame.size, visibleFrame: screen.visibleFrame, placement: placement), display: false)
            adjusting = false; collapse()
        } else if let saved = model.session.windowFrame {
            var frame = saved
            frame.size.width = min(frame.width, screen.visibleFrame.width); frame.size.height = min(frame.height, screen.visibleFrame.height)
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
            panel.setFrame(frame, display: false); adjusting = false
        } else { adjusting = false }
    }
    func show() { expand(); panel.makeKeyAndOrderFront(nil) }
    func dock(to edge: DockEdge) {
        guard let screen = panel.screen ?? screen(for: panel.frame) else { return }
        let next = DockGeometry.placement(edge: edge, frame: panel.frame, visibleFrame: screen.visibleFrame, screenID: screenID(screen))
        placement = next
        adjusting = true
        panel.setFrame(DockGeometry.frame(size: panel.frame.size, visibleFrame: screen.visibleFrame, placement: next), display: true)
        adjusting = false
        model.savePlacement(frame: panel.frame, dock: next)
        collapse()
    }
    func undock() {
        let previous = placement
        let screen = dockScreen
        placement = nil
        if let previous, let screen {
            var frame = panel.frame
            switch previous.edge {
            case .left: frame.origin.x += 64
            case .right: frame.origin.x -= 64
            case .top: frame.origin.y -= 64
            case .bottom: frame.origin.y += 64
            }
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
            adjusting = true; panel.setFrame(frame, display: true); adjusting = false
        }
        model.savePlacement(frame: panel.frame, dock: nil)
        show()
    }
    private func expand() {
        expanded = true; tab.orderOut(nil); panel.orderFrontRegardless()
    }
    private func collapse() {
        guard let placement, let screen = dockScreen else { return }
        expanded = false
        tab.setFrame(DockGeometry.tabFrame(visibleFrame: screen.visibleFrame, placement: placement), display: true)
        tab.orderFrontRegardless(); panel.orderOut(nil)
    }
    private func undock(at point: CGPoint) {
        placement = nil; expand()
        panel.setFrameOrigin(CGPoint(x: point.x - panel.frame.width / 2, y: point.y - panel.frame.height + 20))
        model.savePlacement(frame: panel.frame, dock: nil)
    }
    private func tick() {
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if mouseWasDown && !down && movedDuringPress { movedDuringPress = false; finishMove() }
        mouseWasDown = down
        guard placement != nil, expanded, !down, panel.isVisible else { return }
        if !panel.frame.insetBy(dx: -35, dy: -35).contains(NSEvent.mouseLocation), !panel.isKeyWindow { collapse() }
    }
    private func finishMove() {
        guard panel.isVisible, !adjusting, let screen = screen(for: panel.frame) else { return }
        var candidate = DockGeometry.snap(frame: panel.frame, visibleFrame: screen.visibleFrame, previous: placement)
        candidate?.screenID = screenID(screen)
        placement = candidate
        if let candidate {
            adjusting = true
            panel.setFrame(DockGeometry.frame(size: panel.frame.size, visibleFrame: screen.visibleFrame, placement: candidate), display: true)
            adjusting = false
        }
        model.savePlacement(frame: panel.frame, dock: placement)
        if placement != nil { collapse() }
    }
    func windowDidMove(_ notification: Notification) {
        guard !adjusting else { return }
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { movedDuringPress = true }
        // Save every move, including during dragging, so a forced termination retains the last frame.
        if let current = placement, let screen = dockScreen,
           DockGeometry.snap(frame: panel.frame, visibleFrame: screen.visibleFrame, previous: current) == nil { placement = nil }
        model.savePlacement(frame: panel.frame, dock: placement)
    }
    func windowDidResize(_ notification: Notification) {
        guard !adjusting else { return }
        if let placement, let screen = dockScreen {
            adjusting = true
            panel.setFrame(DockGeometry.frame(size: panel.frame.size, visibleFrame: screen.visibleFrame, placement: placement), display: true)
            adjusting = false
        }
        model.savePlacement(frame: panel.frame, dock: placement)
    }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor
final class DockTabView: NSView {
    var open: (() -> Void)?
    var activate: (() -> Void)?
    var pull: ((CGPoint) -> Void)?
    weak var model: AppModel?
    private var origin: CGPoint?
    private var hoverTask: DispatchWorkItem?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityLabel("FileFan dock tab. Hover or click to open, drag away to undock, or drop files to add.")
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self))
    }
    override func accessibilityPerformPress() -> Bool {
        guard let action = activate ?? open else { return false }
        action()
        return true
    }
    override func mouseEntered(with event: NSEvent) {
        let task = DispatchWorkItem { [weak self] in
            guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
            self?.open?()
        }
        hoverTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }
    override func mouseExited(with event: NSEvent) { hoverTask?.cancel() }
    override func mouseDown(with event: NSEvent) { hoverTask?.cancel(); origin = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        if let origin, hypot(location.x - origin.x, location.y - origin.y) > 10 { self.origin = nil; pull?(location) }
    }
    override func mouseUp(with event: NSEvent) { origin = nil; (activate ?? open)?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        model?.add(urls); (activate ?? open)?(); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let symbol = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: "FileFan")
        symbol?.draw(in: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20))
    }
}
