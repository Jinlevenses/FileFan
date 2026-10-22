import Foundation
import Testing
@testable import FileFanCore

struct DockGeometryTests {
    @Test func snapsOnNegativeOriginScreenAndRestoresNormalizedPosition() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1000)
        let frame = CGRect(x: -1910, y: 500, width: 600, height: 510)
        let placement = DockGeometry.snap(frame: frame, visibleFrame: screen)
        #expect(placement?.edge == .left)
        let restored = DockGeometry.frame(size: frame.size, visibleFrame: screen, placement: placement!)
        #expect(restored.minX == -1920)
        #expect(restored.minY == 500)
        #expect(DockGeometry.snap(frame: frame.offsetBy(dx: 80, dy: 0), visibleFrame: screen) == nil)
        #expect(DockGeometry.snap(frame: frame.offsetBy(dx: 30, dy: 0), visibleFrame: screen, previous: placement) != nil)
    }
    @Test func tabsStayInsideUsableFrameAndResizedRestoreIsClamped() {
        let screen = CGRect(x: 200, y: -800, width: 800, height: 600)
        let placement = DockPlacement(edge: .bottom, offset: 2, screenID: "secondary")
        let tab = DockGeometry.tabFrame(visibleFrame: screen, placement: placement)
        #expect(screen.contains(tab))
        let restored = DockGeometry.frame(size: CGSize(width: 1600, height: 1000), visibleFrame: screen, placement: placement)
        #expect(screen.contains(restored))
    }
}

struct AllDockEdgesTests {
    @Test func everyEdgeSnapsToVisibleFrameAndRetainsOffsetAfterScreenResize() {
        let screen = CGRect(x: -1000, y: -700, width: 1000, height: 700)
        let resized = CGRect(x: 200, y: 50, width: 1400, height: 900)
        for edge in DockEdge.allCases {
            let placement = DockPlacement(edge: edge, offset: 0.3)
            let frame = DockGeometry.frame(size: CGSize(width: 400, height: 300), visibleFrame: screen, placement: placement)
            let snapped = DockGeometry.snap(frame: frame, visibleFrame: screen)
            #expect(snapped?.edge == edge)
            #expect(abs((snapped?.offset ?? 0) - 0.3) < 0.001)
            let restored = DockGeometry.frame(size: frame.size, visibleFrame: resized, placement: placement)
            #expect(resized.contains(restored))
        }
    }
}

struct RestoreScreenTests {
    @Test func savedSecondaryFrameWinsOverDefaultPrimaryAndRemovedScreenFallsBack() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let saved = CGRect(x: -1500, y: 300, width: 600, height: 510)
        #expect(DockGeometry.screenIndex(for: saved, visibleFrames: [primary, secondary], fallback: 0) == 1)
        #expect(DockGeometry.screenIndex(for: saved, visibleFrames: [primary], fallback: 0) == 0)
        #expect(DockGeometry.screenIndex(for: saved, visibleFrames: [], fallback: 0) == nil)
    }
    @Test func spanningSavedWindowUsesLargestVisibleIntersection() {
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        #expect(DockGeometry.screenIndex(for: CGRect(x: -100, y: 200, width: 600, height: 500), visibleFrames: [left, right]) == 1)
    }
}

struct ExplicitDockPlacementTests {
    @Test func menuRequestedEdgesPreserveCurrentAxisPositionAndClampOffscreenFrames() {
        let screen = CGRect(x: -1600, y: 100, width: 1600, height: 1000)
        let current = CGRect(x: -1000, y: 345, width: 600, height: 510)
        for edge in DockEdge.allCases {
            let placement = DockGeometry.placement(edge: edge, frame: current, visibleFrame: screen, screenID: "secondary")
            #expect(placement.edge == edge)
            #expect(placement.screenID == "secondary")
            let vertical = edge == .left || edge == .right
            #expect(abs(placement.offset - (vertical ? 0.5 : 0.6)) < 0.0001)
            let docked = DockGeometry.frame(size: current.size, visibleFrame: screen, placement: placement)
            #expect(screen.contains(docked))
        }
        let outside = DockGeometry.placement(edge: .left, frame: current.offsetBy(dx: 0, dy: 2000), visibleFrame: screen)
        #expect(outside.offset == 1)
    }
}
