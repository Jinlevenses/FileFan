import AppKit
import Testing
@testable import FileFan

@MainActor
struct DockTabAccessibilityTests {
    @Test func collapsedTabExposesButtonAndAccessibilityPressOpensShelf() {
        let tab = DockTabView(frame: CGRect(x: 0, y: 0, width: 30, height: 100))
        var openCount = 0
        var activationCount = 0
        tab.open = { openCount += 1 }
        tab.activate = { activationCount += 1 }
        #expect(tab.isAccessibilityElement())
        #expect(tab.accessibilityRole() == .button)
        #expect(tab.accessibilityLabel()?.contains("FileFan dock tab") == true)
        #expect(tab.accessibilityPerformPress())
        #expect(activationCount == 1)
        #expect(openCount == 0)
    }
    @Test func accessibilityPressFallsBackToPassiveOpenWhenActivationIsUnavailable() {
        let tab = DockTabView(frame: .zero)
        var count = 0
        tab.open = { count += 1 }
        #expect(tab.accessibilityPerformPress())
        #expect(count == 1)
    }
    @Test func mouseClickUsesActivationRatherThanPassiveHoverOpen() throws {
        let tab = DockTabView(frame: .zero)
        var activated = false
        var passivelyOpened = false
        tab.activate = { activated = true }
        tab.open = { passivelyOpened = true }
        let mouseUp = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        tab.mouseUp(with: mouseUp)
        #expect(activated)
        #expect(!passivelyOpened)
    }
    @Test func accessibilityPressWithoutOpenCallbackReportsUnavailable() {
        let tab = DockTabView(frame: .zero)
        #expect(!tab.accessibilityPerformPress())
    }
}
