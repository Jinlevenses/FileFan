import AppKit
import FileFanCore

@MainActor
final class GlobalGestureController {
    private var machine = GestureState(pasteboardChange: NSPasteboard(name: .drag).changeCount)
    private var timer: Timer?
    private var monitor: Any?
    private var localMonitor: Any?
    var enabled: () -> Bool = { true }
    var show: ((GestureMode, [URL], CGPoint) -> Void)?
    var hide: (() -> Void)?
    func start() {
        // Public CG polling observes the existing drag; it never installs a consuming event tap or requests AX.
        timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor [weak self] in self?.cancel() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
            return event
        }
    }
    func cancel() { machine.cancel(); hide?() }
    private func sample() {
        let pasteboard = NSPasteboard(name: .drag)
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let mask: CGEventFlags = [.maskShift, .maskControl, .maskCommand, .maskAlternate]
        let exact = flags.intersection(mask)
        let mode: GestureMode? = exact == .maskShift ? .convert : exact == .maskControl ? .actions : exact == .maskCommand ? .tools : nil
        let urls = down ? fileURLs(from: pasteboard) : []
        let wasPresented = machine.isPresented
        if !enabled(), wasPresented { cancel() }
        if let transition = machine.sample(buttonDown: down, pasteboardChange: pasteboard.changeCount, hasFiles: !urls.isEmpty, modifier: enabled() ? mode : nil) {
            switch transition {
            case .show(let mode): show?(mode, urls, NSEvent.mouseLocation)
            case .ended:
                guard wasPresented else { return }
                // The destination receives performDragOperation on the same mouse-up. Close on the next run-loop.
                DispatchQueue.main.async { [weak self] in self?.hide?() }
            }
        }
        // Escape can be polled without global keyboard-monitor accessibility permission.
        if CGEventSource.keyState(.combinedSessionState, key: 53) { cancel() }
    }
    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

final class DragWheelPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }
}
