import Testing
import AppKit
@testable import FileFan

@MainActor
struct ToolOptionValidationTests {
    @Test func integerOptionsRejectHugeAndFractionalNumbersWithoutTrapping() throws {
        #expect(try ToolOptionsDialog.integer("90", label: "Rotation") == 90)
        for value in ["1e100", "2.5", "nan", "infinity"] {
            #expect(throws: (any Error).self) { try ToolOptionsDialog.integer(value, label: "Quality") }
        }
    }
    @Test func imageDefaultAndGrayColorsConvertToRGBBeforeReadingComponents() throws {
        let black = try ToolOptionsDialog.imageColor(nil)
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
        let gray = try ToolOptionsDialog.imageColor(NSColor(calibratedWhite: 0.4, alpha: 1))
        #expect(gray.red.isFinite && gray.green.isFinite && gray.blue.isFinite)
        #expect(abs(gray.red - gray.green) < 0.001 && abs(gray.green - gray.blue) < 0.001)
    }

}
