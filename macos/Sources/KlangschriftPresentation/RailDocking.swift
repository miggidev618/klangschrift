import AppKit
import SwiftUI

public enum RailDockEdge: String, Codable, Sendable { case left, right, top, bottom }
public struct RailDockPosition: Codable, Equatable, Sendable {
    public var edge: RailDockEdge
    public var fraction: Double
    public var screenID: String
    public init(edge: RailDockEdge = .right, fraction: Double = 0.5, screenID: String = "") {
        self.edge = edge; self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0.5; self.screenID = screenID
    }
    public static func snapped(panel: CGRect, screen: FloatingScreenGeometry) -> Self {
        let f = screen.visibleFrame
        let size = panel.size
        return targets(screen: screen, size: size).min { left, right in
            hypot(panel.midX - left.origin(size: size, visibleFrame: f).x - size.width / 2, panel.midY - left.origin(size: size, visibleFrame: f).y - size.height / 2)
                < hypot(panel.midX - right.origin(size: size, visibleFrame: f).x - size.width / 2, panel.midY - right.origin(size: size, visibleFrame: f).y - size.height / 2)
        } ?? .init(screenID: screen.identifier)
    }
    /// Exactly eight landing places: four side centres and four corners.
    public static func targets(screen: FloatingScreenGeometry, size: CGSize) -> [Self] {
        [.init(edge: .left, fraction: 0.5, screenID: screen.identifier), .init(edge: .right, fraction: 0.5, screenID: screen.identifier), .init(edge: .top, fraction: 0.5, screenID: screen.identifier), .init(edge: .bottom, fraction: 0.5, screenID: screen.identifier), .init(edge: .top, fraction: 0, screenID: screen.identifier), .init(edge: .top, fraction: 1, screenID: screen.identifier), .init(edge: .bottom, fraction: 0, screenID: screen.identifier), .init(edge: .bottom, fraction: 1, screenID: screen.identifier)]
    }
    public func origin(size: CGSize, visibleFrame f: CGRect) -> CGPoint {
        let fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
        let x = edge == .left ? f.minX : edge == .right ? max(f.minX, f.maxX-size.width) : f.minX+max(0,f.width-size.width)*fraction
        let y = edge == .bottom ? f.minY : edge == .top ? max(f.minY, f.maxY-size.height) : f.minY+max(0,f.height-size.height)*fraction
        return .init(x:x,y:y)
    }
}

final class RailPanel: NSPanel {
    var beganDragging: (() -> Void)?; var finishedDragging: (() -> Void)?; var draggingScreen: NSScreen?
}
struct RailDragHandle: NSViewRepresentable {
    let onClick: () -> Void; let onRightClick: () -> Void
    func makeNSView(context: Context) -> RailDragView { RailDragView(onClick: onClick, onRightClick: onRightClick) }
    func updateNSView(_ nsView: RailDragView, context: Context) { nsView.onClick = onClick; nsView.onRightClick = onRightClick }
}
final class RailDragView: NSView {
    var onClick: () -> Void; var onRightClick: () -> Void
    private var previousScreenPoint: CGPoint?; private var dragging = false; private var draggingScreen: NSScreen?
    init(onClick: @escaping () -> Void, onRightClick: @escaping () -> Void) { self.onClick = onClick; self.onRightClick = onRightClick; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        previousScreenPoint = window?.convertPoint(toScreen: event.locationInWindow)
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previousScreenPoint, let panel = window as? RailPanel else { return }
        // NSEvent coordinates are relative to the window's frame at delivery time.
        // Persist screen coordinates before moving the panel so subsequent deltas remain stable.
        let currentScreenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(x: currentScreenPoint.x - previousScreenPoint.x, y: currentScreenPoint.y - previousScreenPoint.y)
        guard dragging || hypot(delta.x, delta.y) >= 3 else { return }
        if !dragging {
            dragging = true
            // Bind the drag to the screen which contained the pill at its start.
            // The pointer may cross displays before mouse-up, but must not change its target screen.
            draggingScreen = panel.screen
            panel.draggingScreen = draggingScreen
            panel.beganDragging?()
        }
        var origin = CGPoint(x: panel.frame.origin.x + delta.x, y: panel.frame.origin.y + delta.y)
        if let visible = draggingScreen?.visibleFrame {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - panel.frame.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))
        }
        panel.setFrameOrigin(origin)
        self.previousScreenPoint = currentScreenPoint
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { (window as? RailPanel)?.finishedDragging?() } else { onClick() }
        previousScreenPoint = nil; dragging = false; draggingScreen = nil
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick() }
}

public struct RailChoice: Identifiable, Equatable, Sendable {
    public let id: String; public let title: String
    public init(id: String, title: String) { self.id=id; self.title=title }
}
public struct RailTranscript: Identifiable, Equatable, Sendable {
    public let id: UUID; public let preview: String
    public init(id: UUID, preview: String) { self.id=id; self.preview=String(preview.prefix(120)) }
}
/// Explicit, history-authorized preview port; the runtime state projection remains content-free.
public struct RailContext: Equatable, Sendable {
    public var microphones: [RailChoice] = []; public var microphoneID = ""
    public var models: [RailChoice] = []; public var modelID = ""
    public var language = "automatic"; public var transcripts: [RailTranscript] = []
    public var microphoneAvailable = false
    public var shortcutLabel = ""
    public init() {}
}
