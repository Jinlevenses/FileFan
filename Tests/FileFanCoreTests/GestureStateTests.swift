import Foundation
import Testing
@testable import FileFanCore

struct GestureStateTests {
    @Test func requiresFreshFileDragAndModifierRisingEdge() {
        var state = GestureState(pasteboardChange: 4)
        #expect(state.sample(buttonDown: false, pasteboardChange: 4, hasFiles: true, modifier: .convert) == nil)
        #expect(state.sample(buttonDown: true, pasteboardChange: 4, hasFiles: true, modifier: nil) == nil)
        #expect(state.sample(buttonDown: true, pasteboardChange: 4, hasFiles: true, modifier: .convert) == nil)
        #expect(state.sample(buttonDown: true, pasteboardChange: 5, hasFiles: true, modifier: nil) == nil)
        #expect(state.sample(buttonDown: true, pasteboardChange: 5, hasFiles: true, modifier: .convert) == .show(.convert))
        #expect(state.sample(buttonDown: true, pasteboardChange: 5, hasFiles: true, modifier: nil) == nil)
        #expect(state.isPresented)
        state.cancel()
        #expect(state.sample(buttonDown: true, pasteboardChange: 5, hasFiles: true, modifier: .actions) == nil)
        #expect(state.sample(buttonDown: false, pasteboardChange: 5, hasFiles: true, modifier: nil) == .ended)
        #expect(!state.isPresented)
    }
    @Test func dragEndResetsAndCannotReuseStalePasteboard() {
        var state = GestureState(pasteboardChange: 0)
        _ = state.sample(buttonDown: true, pasteboardChange: 1, hasFiles: true, modifier: .tools)
        #expect(state.isPresented)
        #expect(state.sample(buttonDown: false, pasteboardChange: 1, hasFiles: true, modifier: nil) == .ended)
        #expect(state.sample(buttonDown: true, pasteboardChange: 1, hasFiles: true, modifier: .tools) == nil)
    }
    @Test func ringHitTestingUsesRealSectorAndRejectsCenterAndOutside() {
        #expect(WheelGeometry.sector(at: CGPoint(x: 0, y: 90), count: 4, inner: 40, outer: 140) == 0)
        #expect(WheelGeometry.sector(at: CGPoint(x: 90, y: 0), count: 4, inner: 40, outer: 140) == 1)
        #expect(WheelGeometry.sector(at: .zero, count: 4, inner: 40, outer: 140) == nil)
        #expect(WheelGeometry.sector(at: CGPoint(x: 200, y: 0), count: 4, inner: 40, outer: 140) == nil)
    }
}
