import Foundation
import CoreGraphics

public enum DockEdge: String, Codable, CaseIterable, Sendable { case left, right, top, bottom }
public struct DockPlacement: Codable, Equatable, Sendable {
    public var edge: DockEdge
    public var offset: Double
    public var screenID: String
    public init(edge: DockEdge, offset: Double, screenID: String = "") {
        self.edge = edge; self.offset = offset; self.screenID = screenID
    }
}
public enum DockGeometry {
    /// Restore on the screen containing most of the saved frame; disconnected displays use the explicit fallback.
    public static func screenIndex(for frame: CGRect, visibleFrames: [CGRect], fallback: Int = 0) -> Int? {
        guard !visibleFrames.isEmpty else { return nil }
        let intersections = visibleFrames.map { screen -> CGFloat in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let index = intersections.indices.max(by: { intersections[$0] < intersections[$1] }), intersections[index] > 0 { return index }
        return visibleFrames.indices.contains(fallback) ? fallback : 0
    }
    public static func snap(frame: CGRect, visibleFrame screen: CGRect, previous: DockPlacement? = nil, threshold: CGFloat = 24) -> DockPlacement? {
        let distances: [(DockEdge, CGFloat)] = [(.left, abs(frame.minX - screen.minX)), (.right, abs(frame.maxX - screen.maxX)), (.top, abs(frame.maxY - screen.maxY)), (.bottom, abs(frame.minY - screen.minY))]
        guard let candidate = distances.min(by: { $0.1 < $1.1 }), candidate.1 <= (previous?.edge == candidate.0 ? threshold * 2 : threshold) else { return nil }
        return placement(edge: candidate.0, frame: frame, visibleFrame: screen)
    }
    public static func placement(edge: DockEdge, frame: CGRect, visibleFrame screen: CGRect, screenID: String = "") -> DockPlacement {
        let vertical = edge == .left || edge == .right
        let travel = vertical ? screen.height - frame.height : screen.width - frame.width
        let position = vertical ? frame.minY - screen.minY : frame.minX - screen.minX
        return DockPlacement(edge: edge, offset: Double(travel > 0 ? min(1, max(0, position / travel)) : 0), screenID: screenID)
    }
    public static func frame(size: CGSize, visibleFrame screen: CGRect, placement: DockPlacement) -> CGRect {
        let size = CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        let offset = CGFloat(min(1, max(0, placement.offset.isFinite ? placement.offset : 0)))
        var origin = CGPoint(x: screen.minX + (screen.width - size.width) * offset, y: screen.minY + (screen.height - size.height) * offset)
        switch placement.edge {
        case .left: origin.x = screen.minX
        case .right: origin.x = screen.maxX - size.width
        case .top: origin.y = screen.maxY - size.height
        case .bottom: origin.y = screen.minY
        }
        return CGRect(origin: origin, size: size)
    }
    public static func tabFrame(visibleFrame screen: CGRect, placement: DockPlacement) -> CGRect {
        let vertical = placement.edge == .left || placement.edge == .right
        return frame(size: vertical ? CGSize(width: 30, height: 100) : CGSize(width: 100, height: 30), visibleFrame: screen, placement: placement)
    }
}
