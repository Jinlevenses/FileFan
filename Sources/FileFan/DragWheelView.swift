import AppKit
import FileFanCore

struct WheelAction {
    var title: String
    var detail: String
    var enabled: Bool
    var run: ([URL]) -> Void
    var hover: (() -> Void)? = nil
}

@MainActor
final class DragWheelView: NSView {
    var actions: [WheelAction] = [] { didSet { highlighted = nil; updateAccessibility(); needsDisplay = true } }
    var heading = "Convert" { didSet { needsDisplay = true } }
    var summary = "" { didSet { setAccessibilityValue(summary); needsDisplay = true } }
    var contextURLs: [URL] = [] { didSet { updateAccessibility() } }
    var cancel: (() -> Void)?
    private(set) var highlighted: Int?
    private let inner: CGFloat = 53
    private let outer: CGFloat = 170
    private var labels: [NSAccessibilityElement] = []
    private var hoverTask: DispatchWorkItem?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("FileFan drag wheel. Drop on a labeled sector. Center or Escape cancels.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func sector(_ point: CGPoint) -> Int? {
        WheelGeometry.sector(at: CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY), count: actions.count, inner: inner, outer: outer)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hoverTask?.cancel(); highlighted = nil; needsDisplay = true }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let next = sector(convert(sender.draggingLocation, from: nil))
        if next != highlighted {
            hoverTask?.cancel()
            if let next, let hover = actions[next].hover {
                let task = DispatchWorkItem(block: hover); hoverTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: task)
            }
        }
        highlighted = next; needsDisplay = true
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty, let index = highlighted, actions[index].enabled else { return [] }
        return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Only this drag sender's pasteboard determines execution. Shelf selection is never the input.
        let urls = fileURLs(from: sender.draggingPasteboard)
        let index = sector(convert(sender.draggingLocation, from: nil))
        hoverTask?.cancel(); cancel?()
        guard !urls.isEmpty, let index, actions[index].enabled else { return false }
        let action = actions[index]
        DispatchQueue.main.async { action.run(urls) }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        guard let index = sector(convert(event.locationInWindow, from: nil)), actions[index].enabled, !contextURLs.isEmpty else { cancel?(); return }
        let action = actions[index], urls = contextURLs
        cancel?(); DispatchQueue.main.async { action.run(urls) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let count = actions.count
        guard count > 0 else {
            drawText("Checking formats…", at: center, size: 14, color: .labelColor); return
        }
        let span = CGFloat.pi * 2 / CGFloat(count)
        for (index, action) in actions.enumerated() {
            let mid = CGFloat(index) * span
            let start = mid - span / 2 + 0.014
            let end = mid + span / 2 - 0.014
            let path = NSBezierPath()
            let steps = max(8, Int(span * 30))
            for step in 0...steps {
                let a = start + (end - start) * CGFloat(step) / CGFloat(steps)
                let p = CGPoint(x: center.x + outer * sin(a), y: center.y + outer * cos(a))
                step == 0 ? path.move(to: p) : path.line(to: p)
            }
            for step in (0...steps).reversed() {
                let a = start + (end - start) * CGFloat(step) / CGFloat(steps)
                path.line(to: CGPoint(x: center.x + inner * sin(a), y: center.y + inner * cos(a)))
            }
            path.close()
            (highlighted == index && action.enabled ? NSColor.controlAccentColor : NSColor.windowBackgroundColor.withAlphaComponent(0.97)).setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
            let radius: CGFloat = 111
            let point = CGPoint(x: center.x + radius * sin(mid), y: center.y + radius * cos(mid))
            let color: NSColor = !action.enabled ? .disabledControlTextColor : highlighted == index ? .white : .labelColor
            drawText(action.title, at: point, size: count > 8 ? 10 : 12, color: color)
        }
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - inner + 3, y: center.y - inner + 3, width: (inner - 3) * 2, height: (inner - 3) * 2)).fill()
        drawText(heading + (summary.isEmpty ? "" : "\n" + summary) + "\n× Cancel", at: center, size: 10, color: .secondaryLabelColor, height: 70)
        if let index = highlighted {
            toolTip = actions[index].detail
        }
    }
    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, height: CGFloat = 34) {
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color, .paragraphStyle: style]
        let rect = CGRect(x: point.x - 42, y: point.y - height / 2, width: 84, height: height)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
    private func updateAccessibility() {
        labels = actions.enumerated().map { index, action in
            let element = WheelActionAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(action.title + (action.enabled ? "" : ", unavailable") + ". " + action.detail)
            element.setAccessibilityParent(self)
            element.setAccessibilityEnabled(action.enabled)
            element.press = { [weak self] in
                guard let self, action.enabled, !self.contextURLs.isEmpty else { return false }
                let urls = self.contextURLs
                self.cancel?()
                DispatchQueue.main.async { action.run(urls) }
                return true
            }
            let angle = CGFloat(index) * .pi * 2 / CGFloat(max(1, actions.count))
            let local = CGRect(x: bounds.midX + 111 * sin(angle) - 36, y: bounds.midY + 111 * cos(angle) - 20, width: 72, height: 40)
            element.setAccessibilityFrame(window?.convertToScreen(convert(local, to: nil)) ?? local)
            return element
        }
        setAccessibilityChildren(labels)
    }
}

@MainActor
private final class WheelActionAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { press?() ?? false }
}
