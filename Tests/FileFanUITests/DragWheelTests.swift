import AppKit
import Testing
@testable import FileFan

@MainActor
struct DragWheelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_LIVE_PASTEBOARD_TESTS"] == "1")) func realSectorDropUsesSenderFilesAndNotGeneralClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let source = URL(fileURLWithPath: "/tmp/sender-only.txt")
        pasteboard.writeObjects([source as NSURL])
        let view = DragWheelView(frame: CGRect(x: 0, y: 0, width: 360, height: 360))
        view.contextURLs = [URL(fileURLWithPath: "/tmp/stale-captured.txt")]
        let sender = DragInfo(pasteboard: pasteboard, point: CGPoint(x: 180, y: 290))
        var received: [URL] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.actions = [WheelAction(title: "Accept", detail: "", enabled: true, run: { urls in received = urls; continuation.resume() })]
            #expect(view.draggingEntered(sender) == .copy)
            #expect(view.performDragOperation(sender))
        }
        #expect(received == [source])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_LIVE_PASTEBOARD_TESTS"] == "1")) func centerOutsideAndDisabledSectorsRejectWithoutExecuting() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/source.txt") as NSURL])
        let view = DragWheelView(frame: CGRect(x: 0, y: 0, width: 360, height: 360))
        var executed = false
        view.actions = [WheelAction(title: "Disabled", detail: "engine unavailable", enabled: false, run: { _ in executed = true })]
        for point in [CGPoint(x: 180, y: 180), CGPoint(x: 180, y: 290), CGPoint(x: 0, y: 0)] {
            let sender = DragInfo(pasteboard: pasteboard, point: point)
            #expect(view.draggingUpdated(sender).isEmpty)
            #expect(!view.performDragOperation(sender))
        }
        #expect(!executed)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILEFAN_LIVE_PASTEBOARD_TESTS"] == "1"))
    func disabledGesturePollingLeavesManualWheelAloneUntilExplicitCancel() async throws {
        let controller = GlobalGestureController()
        var hides = 0
        controller.enabled = { false }
        controller.hide = { hides += 1 }
        controller.start()
        try await Task.sleep(nanoseconds: 70_000_000)
        #expect(hides == 0)
        controller.cancel()
        #expect(hides == 1)
    }
    @Test func manualWheelCanBecomeKeyWithoutChangingNonactivatingDragStyle() {
        _ = NSApplication.shared
        let panel = DragWheelPanel()
        #expect(!panel.canBecomeKey)
        panel.allowsKey = true
        #expect(panel.canBecomeKey)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        panel.allowsKey = false
        #expect(!panel.canBecomeKey)
    }
    @Test func accessibilityPressRunsEnabledActionWithCapturedMenuContext() async throws {
        let view = DragWheelView(frame: CGRect(x: 0, y: 0, width: 360, height: 360))
        let captured = [URL(fileURLWithPath: "/tmp/menu-context.txt")]
        view.contextURLs = captured
        var received: [URL] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.actions = [WheelAction(title: "Metadata", detail: "Inspect captured files", enabled: true, run: { received = $0; continuation.resume() })]
            let child = view.accessibilityChildren()?.first as? NSAccessibilityElement
            #expect(child?.accessibilityPerformPress() == true)
        }
        #expect(received == captured)
    }

}

@MainActor
private final class DragInfo: NSObject, @preconcurrency NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(pasteboard: NSPasteboard, point: CGPoint) { draggingPasteboard = pasteboard; draggingLocation = point }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
