import Foundation

public enum GestureMode: String, Codable, Sendable { case convert, actions, tools }
public enum GestureTransition: Equatable, Sendable { case show(GestureMode), ended }

/// Drag pasteboard contents only become eligible after a new mouse-down and a fresh drag write.
public struct GestureState: Sendable {
    private var lastChange: Int
    private var down = false
    private var fresh = false
    private var consumed = false
    private var lastModifier: GestureMode?
    public private(set) var isPresented = false
    public init(pasteboardChange: Int) { lastChange = pasteboardChange }
    public mutating func sample(buttonDown: Bool, pasteboardChange: Int, hasFiles: Bool, modifier: GestureMode?) -> GestureTransition? {
        defer { lastChange = pasteboardChange; lastModifier = modifier; down = buttonDown }
        if !buttonDown {
            let ended = down
            fresh = false; consumed = false; isPresented = false
            return ended ? .ended : nil
        }
        if !down { fresh = false; consumed = false }
        if pasteboardChange != lastChange { fresh = hasFiles }
        guard fresh, hasFiles, !consumed, let modifier, modifier != lastModifier else { return nil }
        consumed = true; isPresented = true
        return .show(modifier)
    }
    public mutating func cancel() { consumed = true; isPresented = false }
}

public enum WheelGeometry {
    /// Coordinates use AppKit's upward Y axis. Sector zero is centered at twelve o'clock.
    public static func sector(at point: CGPoint, count: Int, inner: CGFloat, outer: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let radius = hypot(point.x, point.y)
        guard radius >= inner, radius <= outer else { return nil }
        var angle = atan2(point.x, point.y)
        if angle < 0 { angle += .pi * 2 }
        let span = CGFloat.pi * 2 / CGFloat(count)
        return Int(floor((angle + span / 2) / span)) % count
    }
}
