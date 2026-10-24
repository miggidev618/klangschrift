import AppKit
import SwiftUI
import KlangschriftDesignSystem

/// This projection is intentionally content-free: no transcript, audio path,
/// clipboard value, or target application can cross this module boundary.
public enum DictationPresentationPhase: String, Equatable, Sendable { case idle, listening, processing, success, busy, error, recoveryCopied }
public enum RailSoundPreference: String, CaseIterable, Sendable { case gentle, clear, warm, off
    public var title: String { switch self { case .gentle: L("Sanft"); case .clear: L("Klar"); case .warm: L("Warm"); case .off: L("Aus") } }
}
public enum DictationPresentationNotice: Sendable, Equatable {
    case maximumDuration, callbackLoss, interrupted, interruptedCopied, lockedCopied
    public var message: String { switch self {
    case .maximumDuration: L("Aufnahme nach 30 Minuten automatisch beendet.")
    case .callbackLoss: L("Mikrofon hat ausgesetzt – Aufnahme bis dahin verwendet.")
    case .interrupted: L("Aufnahme unterbrochen – Text im Verlauf.")
    case .lockedCopied: L("Gesperrt – Text liegt in der Zwischenablage")
    case .interruptedCopied: L("Aufnahme unterbrochen – Text in der Zwischenablage.")
    } }
}
public enum PresentationActionOutcome: String, Equatable, Sendable { case success, unavailable, failed }
/// Temporary hiding lasts until the next application launch, not the next dictation.
public enum RailSnooze: String, Equatable, Sendable { case tenMinutes, oneHour, nextAppStart }
public enum RailAction: String, CaseIterable, Identifiable, Sendable {
    case dashboard, copyNewest, addSelection, visibility, close
    public var id: String { rawValue }
    public var symbol: String { switch self { case .dashboard: "rectangle.split.2x1"; case .copyNewest: "doc.on.doc"; case .addSelection: "text.badge.plus"; case .visibility: "eye.slash"; case .close: "xmark" } }
    public var accessibilityLabel: String { switch self { case .dashboard: L("Dashboard öffnen"); case .copyNewest: L("Neuestes gespeichertes Transkript kopieren"); case .addSelection: L("Markierten Text als Erkennungshinweis hinzufügen"); case .visibility: L("Sichtbarkeit der Leiste"); case .close: L("Menü einklappen") } }
}
public enum RailLayout {
    public static let collapsedSize = CGSize(width: 7, height: 42)
    public static let hoveredSize = CGSize(width: 12, height: 52)
    public static let recordingVerticalSize = CGSize(width: 42, height: 112)
    public static let recordingHorizontalSize = CGSize(width: 112, height: 42)
    public static let expandedSize = recordingVerticalSize
    public static let visibilityExpandedSize = recordingVerticalSize
    public static func size(expanded: Bool, visibilityExpanded: Bool) -> CGSize { guard expanded else { return collapsedSize }; return visibilityExpanded ? visibilityExpandedSize : expandedSize }
}
private let auxiliaryCardDuration: TimeInterval = 4.5
public enum RailSymbolResolver {
    public static func symbol(phase: DictationPresentationPhase, outcome: PresentationActionOutcome?) -> String {
        if phase == .idle && (outcome == .failed || outcome == .unavailable) { return "exclamationmark.circle" }
        return switch phase {
        case .idle, .listening: "waveform"
        case .processing, .busy: "hourglass"
        case .success: "checkmark.circle"
        case .error: "exclamationmark.triangle.fill"
        case .recoveryCopied: "exclamationmark.bubble"
        }
    }
}
public enum DictationPresentationFailure: String, Equatable, Sendable {
    case audioStart, audioDevice, audioPreference, microphone, audioStop, transcription, readerUnknown
    public var message: String { switch self {
    case .audioStart: L("Die Mikrofonaufnahme konnte nicht gestartet werden. Prüfe das Eingabegerät in den macOS-Einstellungen.")
    case .audioDevice: L("Das gewählte Mikrofon ist nicht verfügbar. Wähle ein verfügbares Eingabegerät.")
    case .audioPreference: L("Die Mikrofoneinstellung konnte nicht gelesen werden. Versuche es erneut.")
    case .microphone: L("Mikrofonzugriff fehlt. Erlaube Klangschrift den Zugriff in den macOS-Einstellungen.")
    case .audioStop: L("Die Aufnahme konnte nicht abgeschlossen werden. Versuche es erneut.")
    case .transcription: L("Das Diktat konnte nicht verarbeitet werden. Prüfe das gewählte Modell und versuche es erneut.")
    case .readerUnknown: L("Der vorherige Diktatprozess ist noch nicht sicher beendet. Starte keine weitere Aufnahme.")
    } }
}
public struct DictationPresentationState: Equatable, Sendable {
    public let phase: DictationPresentationPhase; public let sessionID: UUID?; public let generation: UInt64; public let listeningStartedAt: Date?; public let failure: DictationPresentationFailure?
    public init(phase: DictationPresentationPhase = .idle, sessionID: UUID? = nil, generation: UInt64 = 0, listeningStartedAt: Date? = nil, failure: DictationPresentationFailure? = nil) { self.phase = phase; self.sessionID = sessionID; self.generation = generation; self.listeningStartedAt = listeningStartedAt; self.failure = failure }
}
public enum PresentationPreflight: Equatable, Sendable { case ready, unavailable, needsMicrophone, needsAccessibility }
@MainActor public protocol DictationPresentationActions: AnyObject { func railContext() async -> RailContext; func selectRail(_ kind: String, id: String) async -> PresentationActionOutcome; func copyRailTranscript(_ id: UUID) async -> PresentationActionOutcome; func openDashboard(); func requestStartOrStop() async; func requestStopAndProcess() async; func requestCancel() async; func requestInsertLastRecovery() async; func copyNewestTranscript() async -> PresentationActionOutcome; func addSelectedTextAsRecognitionHint() async -> PresentationActionOutcome; func requestCloseRail() async -> PresentationActionOutcome; func requestQuit() }
public extension DictationPresentationActions {
    /// Compatibility default for existing non-production presentation doubles.
    /// The production graph overrides this with the explicit coordinator port.
    func requestStopAndProcess() async {}
}
public extension DictationPresentationActions {
    func railContext() async -> RailContext { .init() }
    func selectRail(_ kind: String, id: String) async -> PresentationActionOutcome { .unavailable }
    func copyRailTranscript(_ id: UUID) async -> PresentationActionOutcome { .unavailable }
}
@MainActor public protocol PresentationPreflightChecking: AnyObject { func checkPresentationPreflight() async -> PresentationPreflight }
@MainActor public protocol PresentationTimer: AnyObject { func invalidate() }
@MainActor public protocol PresentationClock: AnyObject { func now() -> Date; func schedule(after seconds: TimeInterval, handler: @escaping @MainActor () -> Void) -> any PresentationTimer }

@MainActor private final class SystemPresentationTimer: PresentationTimer {
    private var timer: Timer?
    init(after seconds: TimeInterval, handler: @escaping @MainActor () -> Void) { timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in Task { @MainActor in self?.timer = nil; handler() } } }
    func invalidate() { timer?.invalidate(); timer = nil }
}
@MainActor public final class SystemPresentationClock: PresentationClock { public init() {} ; public func now() -> Date { Date() }; public func schedule(after seconds: TimeInterval, handler: @escaping @MainActor () -> Void) -> any PresentationTimer { SystemPresentationTimer(after: seconds, handler: handler) } }

public struct FloatingPanelAnchor: Equatable, Sendable {
    public let generation: UInt64
    public let sessionID: UUID?
    public init(generation: UInt64, sessionID: UUID?) { self.generation = generation; self.sessionID = sessionID }
}
@MainActor public protocol FloatingPanelHosting: AnyObject { func present(_ content: AnyView, size: CGSize, anchor: FloatingPanelAnchor?); func presentNoticeCard(_ content: AnyView?); func dismiss(); func reposition(); func tearDown(); var dockEdge: RailDockEdge { get }; func setDockHandler(_ handler: @escaping @MainActor (RailDockEdge) -> Void) }

public extension FloatingPanelHosting {
    func presentNoticeCard(_ content: AnyView?) {}
    var dockEdge: RailDockEdge { .right }
    func setDockHandler(_ handler: @escaping @MainActor (RailDockEdge) -> Void) {}
}

public struct FloatingScreenGeometry: Equatable, Sendable {
    public let identifier: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public init(identifier: String = "screen", frame: CGRect, visibleFrame: CGRect) { self.identifier = identifier; self.frame = frame; self.visibleFrame = visibleFrame }
}

public enum FloatingPanelPlacement {
    /// Resolves the screen independently of AppKit state on a newly-created
    /// panel: the pointer's screen wins, followed by the panel's current
    /// center, then the supplied main/fallback frame.
    public static func screen(
        from screens: [FloatingScreenGeometry],
        mouseLocation: CGPoint,
        panelFrame: CGRect,
        mainScreen: FloatingScreenGeometry?
    ) -> FloatingScreenGeometry? {
        if let mouseScreen = screens.first(where: { $0.frame.contains(mouseLocation) }) { return mouseScreen }
        let panelCenter = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        if let panelScreen = screens.first(where: { $0.frame.contains(panelCenter) }) { return panelScreen }
        if let mainScreen { return mainScreen }
        return screens.first
    }
    public static func visibleFrame(from screens: [FloatingScreenGeometry], mouseLocation: CGPoint, panelFrame: CGRect, mainScreen: FloatingScreenGeometry?) -> CGRect? {
        screen(from: screens, mouseLocation: mouseLocation, panelFrame: panelFrame, mainScreen: mainScreen)?.visibleFrame
    }

    /// Keeps the panel inside the current screen's visible frame while docking
    /// it to the right. The calculation is independent of AppKit and supports
    /// negative coordinates used by displays left of the primary screen.
    public static func origin(panelSize: CGSize, visibleFrame: CGRect, inset: CGFloat = 0) -> CGPoint {
        let safeInset = max(0, inset)
        let x: CGFloat
        if panelSize.width >= visibleFrame.width {
            x = visibleFrame.minX
        } else {
            x = min(
                max(visibleFrame.maxX - panelSize.width - safeInset, visibleFrame.minX),
                visibleFrame.maxX - panelSize.width
            )
        }
        let y: CGFloat
        if panelSize.height >= visibleFrame.height {
            y = visibleFrame.minY
        } else {
            y = min(
                max(visibleFrame.midY - panelSize.height / 2, visibleFrame.minY),
                visibleFrame.maxY - panelSize.height
            )
        }
        return CGPoint(x: x, y: y)
    }
}

/// Binds the rail to one display until that display disappears. State changes,
/// clicks and pointer movement must never make an apparently persistent rail
/// jump to another screen.
public struct FloatingPanelScreenBinding: Sendable {
    private var screenIdentifier: String?
    public init() {}
    public mutating func visibleFrame(from screens: [FloatingScreenGeometry], mouseLocation: CGPoint, panelFrame: CGRect, mainScreen: FloatingScreenGeometry?, anchor incoming: FloatingPanelAnchor?) -> CGRect? {
        _ = incoming
        if let screenIdentifier,
           let bound = screens.first(where: { $0.identifier == screenIdentifier }) { return bound.visibleFrame }
        guard let selected = FloatingPanelPlacement.screen(from: screens, mouseLocation: mouseLocation, panelFrame: panelFrame, mainScreen: mainScreen) else { return nil }
        screenIdentifier = selected.identifier
        return selected.visibleFrame
    }
    public mutating func reset() { screenIdentifier = nil }
}

/// The real panel is lazy; tests provide a fake host and never instantiate it.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        func nativeButton(in view: NSView, pointInHost: NSPoint, host: NSView) -> NSButton? {
            for child in view.subviews.reversed() {
                let childPoint = host.convert(pointInHost, to: child)
                if let button = child as? NSButton, button.bounds.contains(childPoint) { return button }
                if let button = nativeButton(in: child, pointInHost: pointInHost, host: host) { return button }
            }
            return nil
        }
        return nativeButton(in: self, pointInHost: point, host: self) ?? super.hitTest(point)
    }
}
private final class NoticePanel: NSPanel {
    private var pressedButton: FirstMouseButton?
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown || event.type == .leftMouseUp, let contentView else {
            super.sendEvent(event); return
        }
        if event.type == .leftMouseUp {
            guard let pressedButton else { return }
            self.pressedButton = nil
            pressedButton.mouseUp(with: event)
            return
        }
        guard event.type == .leftMouseDown else { super.sendEvent(event); return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        var candidate: NSView? = contentView.hitTest(point)
        while let view = candidate {
            if let button = view as? FirstMouseButton {
                pressedButton = button
                button.mouseDown(with: event)
                return
            }
            candidate = view.superview
        }
        super.sendEvent(event)
    }
}

@MainActor public final class AppKitFloatingPanelHost: FloatingPanelHosting {
    private static let compactNoticeSize = CGSize(width: 288, height: 112)
    private var panel: NSPanel?; private var mainContentHost: FirstMouseHostingView?; private var noticePanel: NSPanel?; private var noticeContentHost: FirstMouseHostingView?; private var dockingOverlay: NSPanel?; private var observers: [NSObjectProtocol] = []
    private var binding = FloatingPanelScreenBinding()
    private var currentAnchor: FloatingPanelAnchor?
    private let defaults: UserDefaults
    private var dock: RailDockPosition
    private var dockHandler: (@MainActor (RailDockEdge) -> Void)?
    public var dockEdge: RailDockEdge { dock.edge }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dock = defaults.data(forKey: "klangschrift.rail-position.v1").flatMap { try? JSONDecoder().decode(RailDockPosition.self, from: $0) } ?? .init()
    }
    public func setDockHandler(_ handler: @escaping @MainActor (RailDockEdge) -> Void) { dockHandler = handler }
    public func present(_ content: AnyView, size: CGSize, anchor: FloatingPanelAnchor?) {
        let panel = makePanel(); currentAnchor = anchor
        let isManualDrag = (panel as? RailPanel)?.draggingScreen != nil
        if !isManualDrag { panel.setFrame(.init(origin: panel.frame.origin, size: size), display: false) }
        if let mainContentHost { mainContentHost.rootView = content }
        else { let host = FirstMouseHostingView(rootView: content); panel.contentView = host; mainContentHost = host }
        if !isManualDrag { position(panel) }
        panel.orderFrontRegardless()
    }
    public func presentNoticeCard(_ content: AnyView?) {
        guard let content else { noticePanel?.orderOut(nil); noticePanel = nil; noticeContentHost = nil; return }
        let size = Self.compactNoticeSize
        let panel = noticePanel ?? NoticePanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true; panel.ignoresMouseEvents = false; panel.isMovable = false
        panel.setContentSize(size)
        if let noticeContentHost { noticeContentHost.rootView = content }
        else { let host = FirstMouseHostingView(rootView: content); panel.contentView = host; noticeContentHost = host }
        if let mainPanel = self.panel {
            let visible = mainPanel.screen?.visibleFrame
                ?? NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: mainPanel.frame.midX, y: mainPanel.frame.midY)) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame
            if let visible { panel.setFrameOrigin(Self.noticeOrigin(pillFrame: mainPanel.frame, edge: dock.edge, visibleFrame: visible, cardSize: size)) }
        }
        panel.orderFrontRegardless(); noticePanel = panel
    }
    public func dismiss() { panel?.contentView = nil; mainContentHost = nil; panel?.orderOut(nil) }
    public func reposition() { if let panel { position(panel) } }
    public func tearDown() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); dismissDockTargets(); noticePanel?.orderOut(nil); noticePanel = nil; noticeContentHost = nil; panel?.contentView = nil; mainContentHost = nil; panel?.orderOut(nil); panel = nil; currentAnchor = nil; binding.reset() }
    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = RailPanel(contentRect: .init(origin: .zero, size: RailLayout.collapsedSize), styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isMovable = false; panel.ignoresMouseEvents = false
        panel.finishedDragging = { [weak self, weak panel] in
            guard let self, let panel else { return }
            defer { panel.draggingScreen = nil; self.dismissDockTargets() }
            let screens = NSScreen.screens.enumerated().map { FloatingScreenGeometry(identifier: Self.identifier(for: $0.element, fallback: $0.offset), frame: $0.element.frame, visibleFrame: $0.element.visibleFrame) }
            let boundScreen = panel.draggingScreen.flatMap { dragged in
                NSScreen.screens.enumerated().first(where: { $0.element === dragged }).map { screens[$0.offset] }
            }
            guard let screen = boundScreen ?? FloatingPanelPlacement.screen(from: screens, mouseLocation: NSEvent.mouseLocation, panelFrame: panel.frame, mainScreen: nil) else { return }
            self.dock = RailDockPosition.snapped(panel: panel.frame, screen: screen)
            self.defaults.set(try? JSONEncoder().encode(self.dock), forKey: "klangschrift.rail-position.v1")
            self.binding.reset()
            panel.draggingScreen = nil
            self.dockHandler?(self.dock.edge)
            self.position(panel)
        }
        panel.beganDragging = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.showDockTargets(for: panel)
        }
        panel.becomesKeyOnlyIfNeeded = true
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reposition() } })
        self.panel = panel; return panel
    }
    private func position(_ panel: NSPanel) {
        let systemScreens = NSScreen.screens
        let screens = systemScreens.enumerated().map { index, screen in FloatingScreenGeometry(identifier: Self.identifier(for: screen, fallback: index), frame: screen.frame, visibleFrame: screen.visibleFrame) }
        let mainScreen = NSScreen.main.flatMap { main in systemScreens.firstIndex(where: { $0 === main }).map { screens[$0] } }
        let visible = screens.first(where: { $0.identifier == dock.screenID })?.visibleFrame ?? binding.visibleFrame(from: screens, mouseLocation: NSEvent.mouseLocation, panelFrame: panel.frame, mainScreen: mainScreen, anchor: currentAnchor)
        guard let visible else { return }
        let size = CGSize(width: min(panel.frame.width, visible.width), height: min(panel.frame.height, visible.height))
        panel.setFrame(.init(origin: dock.origin(size: size, visibleFrame: visible), size: size), display: false)
    }
    private func showDockTargets(for panel: NSPanel) {
        let screens = NSScreen.screens.enumerated().map { FloatingScreenGeometry(identifier: Self.identifier(for: $0.element, fallback: $0.offset), frame: $0.element.frame, visibleFrame: $0.element.visibleFrame) }
        guard let screen = FloatingPanelPlacement.screen(from: screens, mouseLocation: NSEvent.mouseLocation, panelFrame: panel.frame, mainScreen: nil) else { return }
        dismissDockTargets()
        let overlay = NSPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.level = .statusBar - 1; overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.ignoresMouseEvents = true; overlay.hasShadow = false
        overlay.contentView = DockTargetsView(screen: screen, pillSize: panel.frame.size)
        overlay.orderFrontRegardless(); dockingOverlay = overlay
    }
    private func dismissDockTargets() { dockingOverlay?.orderOut(nil); dockingOverlay = nil }
    static func noticeOrigin(pillFrame: CGRect, edge: RailDockEdge, visibleFrame: CGRect, cardSize: CGSize) -> CGPoint {
        let gap: CGFloat = 12
        var origin: CGPoint
        switch edge {
        case .right: origin = .init(x: pillFrame.minX - gap - cardSize.width, y: pillFrame.midY - cardSize.height / 2)
        case .left: origin = .init(x: pillFrame.maxX + gap, y: pillFrame.midY - cardSize.height / 2)
        case .top: origin = .init(x: pillFrame.midX - cardSize.width / 2, y: pillFrame.minY - gap - cardSize.height)
        case .bottom: origin = .init(x: pillFrame.midX - cardSize.width / 2, y: pillFrame.maxY + gap)
        }
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - cardSize.width))
        origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - cardSize.height))
        return origin
    }
    // Internal test seams exercise the real AppKit panel lifecycle without UI automation.
    var panelForTesting: NSPanel? { panel }
    var dockingOverlayForTesting: NSPanel? { dockingOverlay }
    var noticePanelForTesting: NSPanel? { noticePanel }
    var noticeCardSizeForTesting: CGSize { Self.compactNoticeSize }
    var dockTargetFramesForTesting: [CGRect] { (dockingOverlay?.contentView as? DockTargetsView)?.targetFramesForTesting ?? [] }
    private static func identifier(for screen: NSScreen, fallback: Int) -> String { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "screen-\(fallback)" }
}

final class DockTargetsView: NSView {
    private let screen: FloatingScreenGeometry; private let pillSize: CGSize
    var targetFramesForTesting: [CGRect] {
        RailDockPosition.targets(screen: screen, size: pillSize).map { target in
            let size = (target.edge == .top || target.edge == .bottom) ? RailLayout.recordingHorizontalSize : RailLayout.recordingVerticalSize
            return .init(origin: target.origin(size: size, visibleFrame: screen.visibleFrame), size: size)
        }
    }
    init(screen: FloatingScreenGeometry, pillSize: CGSize) { self.screen = screen; self.pillSize = pillSize; super.init(frame: .init(origin: .zero, size: screen.visibleFrame.size)) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.42).setFill(); bounds.fill()
        let vertical = CGSize(width: RailLayout.recordingVerticalSize.width, height: RailLayout.recordingVerticalSize.height)
        let horizontal = CGSize(width: RailLayout.recordingHorizontalSize.width, height: RailLayout.recordingHorizontalSize.height)
        for target in RailDockPosition.targets(screen: screen, size: pillSize) {
            let isHorizontal = target.edge == .top || target.edge == .bottom
            let size = isHorizontal ? horizontal : vertical
            let origin = target.origin(size: size, visibleFrame: screen.visibleFrame)
            let local = NSRect(x: origin.x - screen.visibleFrame.minX, y: origin.y - screen.visibleFrame.minY, width: size.width, height: size.height)
            NSColor.white.withAlphaComponent(0.92).setStroke(); let path = NSBezierPath(roundedRect: local, xRadius: min(size.width, size.height) / 2, yRadius: min(size.width, size.height) / 2); path.lineWidth = 2; path.stroke()
        }
    }
}

@MainActor public final class DictationPresentationController: ObservableObject {
    @Published public private(set) var state: DictationPresentationState
    /// Changes for every accepted runtime publication, including a new draft
    /// in the same recording generation. Overview consumers use this instead
    /// of treating a generation boundary as the only refresh signal.
    @Published public private(set) var stateRevision: UInt64 = 0
    @Published public private(set) var preflight: PresentationPreflight = .ready
    @Published public private(set) var isFloatingVisible = false
    @Published public private(set) var isExpanded = false
    @Published public private(set) var isVisibilityMenuExpanded = false
    @Published public private(set) var snooze: RailSnooze?
    @Published public private(set) var notice: DictationPresentationNotice?
    private var noticeTimer: (any PresentationTimer)?
    private var noticeGeneration: UInt64 = 0
    @Published public private(set) var isRecoveryCardVisible = false
    public private(set) var recoveryCardDeadline: Date?
    private var recoveryCardTimer: (any PresentationTimer)?
    private var recoveryCardGeneration: UInt64 = 0
    @Published public private(set) var lastActionOutcome: PresentationActionOutcome?
    @Published public private(set) var historyCapabilityAvailable: Bool
    @Published public private(set) var recoveryCopyAvailable = false
    @Published public private(set) var dockEdge: RailDockEdge = .right
    @Published public private(set) var railContext = RailContext()
    @Published public private(set) var microphoneLevel: Double = 0
    @Published public private(set) var isPillHovered = false
    @Published public private(set) var isPillContextMenuVisible = false
    private var contextRevision: UInt64 = 0
    private let actions: any DictationPresentationActions; private let checker: any PresentationPreflightChecking; private let clock: any PresentationClock; private let panelHost: any FloatingPanelHosting
    private var actionGeneration: UInt64 = 0; private var terminalTimer: (any PresentationTimer)?; private var snoozeTimer: (any PresentationTimer)?; private var snoozeGeneration: UInt64 = 0
    private var isPublished = false
    private var floatingPreferenceEnabled: Bool
    private let soundDefaults = UserDefaults.standard
    public convenience init() { self.init(actions: NoopPresentationActions(), checker: ReadyPresentationPreflight(), clock: SystemPresentationClock(), panelHost: AppKitFloatingPanelHost()) }
    public init(actions: any DictationPresentationActions, checker: any PresentationPreflightChecking, clock: any PresentationClock, panelHost: any FloatingPanelHosting, state: DictationPresentationState = .init(), floatingPreferenceEnabled: Bool = true, historyCapabilityAvailable: Bool = false) { self.actions = actions; self.checker = checker; self.clock = clock; self.panelHost = panelHost; self.state = state; self.floatingPreferenceEnabled = floatingPreferenceEnabled; self.historyCapabilityAvailable = historyCapabilityAvailable; self.dockEdge = panelHost.dockEdge
        panelHost.setDockHandler { [weak self] edge in self?.dockEdge = edge; self?.renderRail() }
    }
    /// App lifecycle owners call this before releasing the presentation shell.
    public func tearDown() { noticeTimer?.invalidate(); noticeTimer = nil; notice = nil; recoveryCardTimer?.invalidate(); recoveryCardTimer = nil; recoveryCardDeadline = nil; isRecoveryCardVisible = false; terminalTimer?.invalidate(); terminalTimer = nil; snoozeTimer?.invalidate(); snoozeTimer = nil; isPublished = false; panelHost.tearDown() }
    public func showNotice(_ notice: DictationPresentationNotice) {
        noticeGeneration &+= 1
        let token = noticeGeneration
        noticeTimer?.invalidate()
        self.notice = notice
        noticeTimer = clock.schedule(after: auxiliaryCardDuration) { [weak self] in
            guard let self, self.noticeGeneration == token else { return }
            self.notice = nil; self.noticeTimer = nil; self.renderRail()
        }
        renderRail()
    }
    public func dismissNotice() {
        noticeGeneration &+= 1
        noticeTimer?.invalidate(); noticeTimer = nil; notice = nil
        renderRail()
    }
    public func dismissRecoveryCard() {
        recoveryCardGeneration &+= 1
        recoveryCardTimer?.invalidate(); recoveryCardTimer = nil
        recoveryCardDeadline = nil; isRecoveryCardVisible = false
        renderRail()
    }
    public func activateRail() { isPublished = true; renderRail() }
    public func setPreferenceEnabled(_ enabled: Bool) { let wasEnabled = floatingPreferenceEnabled; floatingPreferenceEnabled = enabled; if enabled && !wasEnabled { clearSnooze() }; renderRail() }
    public func setHistoryCapabilityAvailable(_ available: Bool) { historyCapabilityAvailable = available; if !available { railContext.transcripts = [] }; renderRail() }
    public func toggleExpanded() { guard isFloatingVisible, state.phase == .idle else { return }; isExpanded.toggle(); if !isExpanded { isVisibilityMenuExpanded = false }; renderRail() }
    public func collapseExpanded() { guard isExpanded || isVisibilityMenuExpanded else { return }; isExpanded = false; isVisibilityMenuExpanded = false; renderRail() }
    public func toggleVisibilityMenu() { guard isExpanded else { return }; isVisibilityMenuExpanded.toggle(); renderRail() }
    public func selectSnooze(_ value: RailSnooze) {
        snoozeTimer?.invalidate(); snoozeTimer = nil; snoozeGeneration &+= 1; let scheduledGeneration = snoozeGeneration; snooze = value; isExpanded = false; isVisibilityMenuExpanded = false; isPillContextMenuVisible = false
        switch value {
        case .tenMinutes: snoozeTimer = clock.schedule(after: 600) { [weak self] in guard let self, self.snoozeGeneration == scheduledGeneration, self.snooze == value else { return }; self.clearSnooze(); self.renderRail() }
        case .oneHour: snoozeTimer = clock.schedule(after: 3_600) { [weak self] in guard let self, self.snoozeGeneration == scheduledGeneration, self.snooze == value else { return }; self.clearSnooze(); self.renderRail() }
        case .nextAppStart: break
        }
        renderRail()
    }
    /// An old asynchronous runtime callback cannot overwrite a newer session.
    public func apply(_ incoming: DictationPresentationState) {
        guard incoming.generation >= state.generation else { return }
        guard incoming.generation != state.generation || incoming.sessionID == state.sessionID || state.sessionID == nil else { return }
        let previousPhase = state.phase
        let startsRecoveryCard = incoming.phase == .recoveryCopied && (previousPhase != .recoveryCopied || incoming.generation != state.generation)
        if incoming.generation > state.generation || incoming.phase == .listening {
            noticeGeneration &+= 1; noticeTimer?.invalidate(); noticeTimer = nil; notice = nil
        }
        actionGeneration &+= 1
        terminalTimer?.invalidate(); terminalTimer = nil
        if incoming.generation > state.generation || incoming.phase != .idle { lastActionOutcome = nil }
        if incoming.phase != .idle { isExpanded = false; isVisibilityMenuExpanded = false; isPillContextMenuVisible = false }
        if incoming.phase == .recoveryCopied { recoveryCopyAvailable = true }
        if incoming.phase == .listening { recoveryCopyAvailable = false }
        if incoming.phase != .recoveryCopied { clearRecoveryCard() }
        state = incoming
        if startsRecoveryCard { showRecoveryCard() }
        if incoming.phase == .listening, previousPhase != .listening { playSound(start: true) }
        if previousPhase == .listening, incoming.phase == .processing { playSound(start: false) }
        if incoming.phase != .listening { microphoneLevel = 0 }
        stateRevision &+= 1
        if isTerminal(incoming.phase) { scheduleTerminalReset(for: incoming) }
        renderRail()
    }
    public func begin() async {
        actionGeneration &+= 1; let request = actionGeneration; preflight = .ready; lastActionOutcome = nil; isExpanded = false; isVisibilityMenuExpanded = false; isPillContextMenuVisible = false; state = .init(phase: .busy, generation: state.generation &+ 1); renderRail()
        let result = await checker.checkPresentationPreflight(); guard request == actionGeneration else { return }; preflight = result
        guard result == .ready else { state = .init(phase: .error, generation: state.generation, failure: result == .needsMicrophone ? .microphone : nil); scheduleTerminalReset(for: state); renderRail(); return }; await actions.requestStartOrStop()
    }
    public func requestStartOrStop() async {
        if state.phase == .listening { await stopAndProcess() }
        else if state.phase == .processing { await cancel() }
        else { await begin() }
    }
    /// The dashboard's visible Stop action is deliberately narrower than the
    /// legacy toggle command: it finishes the active recording and enters the
    /// existing coordinator inference path. Processing remains cancellable,
    /// but is never relabelled as a recording stop.
    public func stopAndProcess() async {
        guard state.phase == .listening else { return }
        actionGeneration &+= 1
        terminalTimer?.invalidate(); terminalTimer = nil
        await actions.requestStopAndProcess()
    }
    public func cancel() async { actionGeneration &+= 1; terminalTimer?.invalidate(); terminalTimer = nil; await actions.requestCancel(); lastActionOutcome = nil; isExpanded = false; microphoneLevel = 0; state = .init(phase: .idle, generation: state.generation &+ 1); renderRail() }
    public func requestInsertLastRecovery() async { guard recoveryCopyAvailable else { return }; await actions.requestInsertLastRecovery() }
    public func requestCopyNewest() async { guard !copyNewestDisabled else { return }; lastActionOutcome = await actions.copyNewestTranscript(); renderRail() }
    public func requestAddSelection() async { guard !contentActionsDisabled else { return }; lastActionOutcome = await actions.addSelectedTextAsRecognitionHint(); renderRail() }
    public func requestClose() async { guard state.phase == .idle else { return }; let result = await actions.requestCloseRail(); lastActionOutcome = result; if result == .success { floatingPreferenceEnabled = false; isExpanded = false; isVisibilityMenuExpanded = false }; renderRail() }
    public func updateMicrophoneLevel(_ value: Double) { microphoneLevel = state.phase == .listening && value.isFinite ? min(1,max(0,value)) : 0 }
    public func setPillHovered(_ hovered: Bool) { guard state.phase == .idle, isPillHovered != hovered else { return }; isPillHovered = hovered; renderRail() }
    public func showPillContextMenu() { guard state.phase == .idle else { return }; isPillContextMenuVisible = true; renderRail() }
    public func dismissPillContextMenu() { guard isPillContextMenuVisible else { return }; isPillContextMenuVisible = false; renderRail() }
    public func refreshRailContext() async {
        contextRevision &+= 1; let revision = contextRevision
        let next = await actions.railContext()
        guard revision == contextRevision else { return }
        railContext = next
        if !historyCapabilityAvailable { railContext.transcripts = [] }
    }
    public func selectRail(_ kind: String, id: String) async {
        guard state.phase == .idle else { return }
        contextRevision &+= 1
        lastActionOutcome = await actions.selectRail(kind, id: id)
        await refreshRailContext()
    }
    public func copyRailTranscript(_ id: UUID) async {
        guard historyCapabilityAvailable, !contentActionsDisabled else { return }
        lastActionOutcome = await actions.copyRailTranscript(id)
    }
    public func requestQuit() { actions.requestQuit() }
    public func openDashboard() { actions.openDashboard() }
    public var contentActionsDisabled: Bool { state.phase == .listening || state.phase == .processing }
    public var copyNewestDisabled: Bool { contentActionsDisabled || !historyCapabilityAvailable }
    public var closeDisabled: Bool { state.phase != .idle }
    private func clearSnooze() { snoozeGeneration &+= 1; snoozeTimer?.invalidate(); snoozeTimer = nil; snooze = nil }
    private func playSound(start: Bool) {
        let value = RailSoundPreference(rawValue: soundDefaults.string(forKey: "klangschrift.rail-sound.v1") ?? RailSoundPreference.gentle.rawValue) ?? .gentle
        guard value != .off else { return }
        let name: String = switch (value, start) { case (.gentle, true): "Tink"; case (.gentle, false): "Pop"; case (.clear, true): "Glass"; case (.clear, false): "Ping"; case (.warm, true): "Morse"; case (.warm, false): "Funk"; case (.off, _): "" }
        if let sound = NSSound(named: NSSound.Name(name)) { sound.volume = 0.18; sound.play() }
    }
    private func isTerminal(_ phase: DictationPresentationPhase) -> Bool { phase == .success || phase == .error || phase == .recoveryCopied }
    private var activeOverridesVisibility: Bool { notice != nil || state.phase == .listening || state.phase == .processing || state.phase == .busy || isTerminal(state.phase) }
    private var shouldShowRail: Bool { isPublished && (activeOverridesVisibility || (floatingPreferenceEnabled && snooze == nil)) }
    private func renderRail() {
        guard shouldShowRail else { isFloatingVisible = false; panelHost.dismiss(); panelHost.presentNoticeCard(nil); return }
        isFloatingVisible = true
        let active = state.phase == .listening || state.phase == .processing || state.phase == .busy
        let size = active
            ? ([.top, .bottom].contains(dockEdge) ? RailLayout.recordingHorizontalSize : RailLayout.recordingVerticalSize)
            : idlePillSize
        let anchor = state.phase == .idle ? nil : FloatingPanelAnchor(generation: state.generation, sessionID: state.sessionID)
        panelHost.present(AnyView(FloatingRailView(controller: self)), size: size, anchor: anchor)
        // A completion notice wins over recovery content; neither changes the rail's frame.
        let auxiliaryNotice: AnyView? = if let notice { AnyView(CompletionNoticeCard(notice: notice, controller: self)) } else if isRecoveryCardVisible { AnyView(NoTextFieldCard(controller: self)) } else if isPillContextMenuVisible { AnyView(PillContextMenu(controller: self)) } else { nil }
        panelHost.presentNoticeCard(auxiliaryNotice)
    }
    private var idlePillSize: CGSize {
        let base = isPillHovered ? RailLayout.hoveredSize : RailLayout.collapsedSize
        return [.top, .bottom].contains(dockEdge) ? CGSize(width: base.height, height: base.width) : base
    }
    private func showRecoveryCard() {
        recoveryCardGeneration &+= 1
        let token = recoveryCardGeneration
        recoveryCardTimer?.invalidate()
        recoveryCardDeadline = clock.now().addingTimeInterval(auxiliaryCardDuration)
        isRecoveryCardVisible = true
        recoveryCardTimer = clock.schedule(after: auxiliaryCardDuration) { [weak self] in
            guard let self, self.recoveryCardGeneration == token else { return }
            self.recoveryCardTimer = nil; self.recoveryCardDeadline = nil; self.isRecoveryCardVisible = false
            self.renderRail()
        }
    }
    private func clearRecoveryCard() {
        recoveryCardGeneration &+= 1
        recoveryCardTimer?.invalidate(); recoveryCardTimer = nil
        recoveryCardDeadline = nil; isRecoveryCardVisible = false
    }
    private func scheduleTerminalReset(for scheduled: DictationPresentationState) { terminalTimer?.invalidate(); let delay = scheduled.phase == .recoveryCopied ? auxiliaryCardDuration : 2.2; terminalTimer = clock.schedule(after: delay) { [weak self] in guard let self, self.state.generation == scheduled.generation, self.state.phase == scheduled.phase else { return }; self.clearRecoveryCard(); self.state = .init(phase: .idle, generation: scheduled.generation, failure: scheduled.failure); self.renderRail() } }
}
@MainActor private final class NoopPresentationActions: DictationPresentationActions { func openDashboard() {}; func requestStartOrStop() async {}; func requestStopAndProcess() async {}; func requestCancel() async {}; func requestInsertLastRecovery() async {}; func copyNewestTranscript() async -> PresentationActionOutcome { .unavailable }; func addSelectedTextAsRecognitionHint() async -> PresentationActionOutcome { .unavailable }; func requestCloseRail() async -> PresentationActionOutcome { .failed }; func requestQuit() {} }
@MainActor private final class ReadyPresentationPreflight: PresentationPreflightChecking { func checkPresentationPreflight() async -> PresentationPreflight { .ready } }

@MainActor public final class PresentationCommands {
    private weak var controller: DictationPresentationController?
    init(controller: DictationPresentationController) { self.controller = controller }
    public func startOrStop() { Task { [weak self] in await self?.controller?.requestStartOrStop() } }
    public func cancel() { Task { [weak self] in await self?.controller?.cancel() } }
    public func insertRecovery() { Task { [weak self] in await self?.controller?.requestInsertLastRecovery() } }
    public func copyNewest() { Task { [weak self] in await self?.controller?.requestCopyNewest() } }
    public func addSelection() { Task { [weak self] in await self?.controller?.requestAddSelection() } }
    public func close() { controller?.collapseExpanded() }
    public func dashboard() { controller?.openDashboard() }
    public func toggleExpanded() { controller?.toggleExpanded() }
    public func toggleVisibility() { controller?.toggleVisibilityMenu() }
    public func snooze(_ value: RailSnooze) { controller?.selectSnooze(value) }
}
/// Always-active AppKit tracking also receives hover while the owning app is inactive.
/// A separate nonactivating panel keeps the label outside the narrow rail's bounds.
private struct RailHoverLabel: NSViewRepresentable {
    let text: String
    let scheme: ColorScheme
    func makeNSView(context: Context) -> RailHoverTrackingView { RailHoverTrackingView(text: text, scheme: scheme) }
    func updateNSView(_ view: RailHoverTrackingView, context: Context) { view.text = text; view.scheme = scheme }
    static func dismantleNSView(_ view: RailHoverTrackingView, coordinator: ()) { view.dismissLabel() }
}
@MainActor private final class RailHoverTrackingView: NSView {
    var text: String
    var scheme: ColorScheme
    private var tracking: NSTrackingArea?
    private var labelPanel: NSPanel?
    init(text: String, scheme: ColorScheme) { self.text = text; self.scheme = scheme; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dismissLabel() } }
    override func mouseEntered(with event: NSEvent) {
        guard let window, let screen = window.screen else { return }
        dismissLabel()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.sizeToFit()
        let size = NSSize(width: min(label.frame.width + 20, screen.visibleFrame.width), height: label.frame.height + 14)
        let panel = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dark = scheme == .dark
        panel.backgroundColor = dark ? NSColor(calibratedRed: 0.165, green: 0.157, blue: 0.145, alpha: 1) : NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.89, alpha: 1)
        label.textColor = dark ? .white : NSColor(calibratedRed: 0.165, green: 0.157, blue: 0.145, alpha: 1)
        panel.hasShadow = true
        label.frame = NSRect(x: 10, y: 7, width: size.width - 20, height: label.frame.height)
        panel.contentView?.addSubview(label)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = screen.visibleFrame
        let preferredX = anchor.minX - size.width - 8 >= visible.minX ? anchor.minX - size.width - 8 : anchor.maxX + 8
        let x = max(visible.minX, min(preferredX, visible.maxX - size.width))
        let y = max(visible.minY, min(anchor.midY - size.height / 2, visible.maxY - size.height))
        panel.setFrameOrigin(.init(x: x, y: y)); panel.orderFrontRegardless(); labelPanel = panel
    }
    override func mouseExited(with event: NSEvent) { dismissLabel() }
    func dismissLabel() { labelPanel?.orderOut(nil); labelPanel = nil }
}
private extension View {
    func railHoverLabel(_ text: String, scheme: ColorScheme) -> some View { background(RailHoverLabel(text: text, scheme: scheme).allowsHitTesting(false)) }
}

public struct FloatingRailView: View {
    @ObservedObject private var controller: DictationPresentationController
    @Environment(\.colorScheme) private var scheme
    public init(controller: DictationPresentationController) { self.controller = controller }
    public var body: some View {
        pill
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .klangschriftTheme(paintsCanvas: false)
        .task { await controller.refreshRailContext() }
    }
    private var active: Bool { [.listening, .processing, .busy].contains(controller.state.phase) }
    private var horizontal: Bool { controller.dockEdge == .top || controller.dockEdge == .bottom }
    private var pill: some View {
        Button { Task { await controller.requestStartOrStop() } } label: {
            Group {
                if active {
                    let layout = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 5))
                    layout {
                        if controller.state.phase == .listening {
                            ActiveApplicationIcon().frame(width: 18, height: 18)
                            RailMeasuredWaveform(level: controller.microphoneLevel, horizontalPill: horizontal).frame(width: horizontal ? 64 : 22, height: horizontal ? 22 : 56)
                        } else { ProgressView().controlSize(.small).tint(Color.presentation(.accent, scheme)) }
                    }
                } else { Color.clear }
            }
            .frame(width: active ? (horizontal ? 112 : 42) : (horizontal ? (controller.isPillHovered ? 52 : 42) : (controller.isPillHovered ? 12 : 7)), height: active ? (horizontal ? 42 : 112) : (horizontal ? (controller.isPillHovered ? 12 : 7) : (controller.isPillHovered ? 52 : 42)))
            .background(Color(red: 0.98, green: 0.95, blue: 0.89), in: Capsule())
            .overlay { Capsule().stroke(Color.presentation(.accent, scheme).opacity(active ? 0.65 : 0.35), lineWidth: active ? 1 : 0.5) }
            .shadow(color: .black.opacity(active ? 0.18 : 0.30), radius: active ? 2 : 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { controller.setPillHovered($0) }
        .overlay { if !active { RailDragHandle(onClick: { Task { await controller.requestStartOrStop() } }, onRightClick: { controller.showPillContextMenu() }).accessibilityLabel(L("Pille verschieben")) } }
        .railHoverLabel(L("Diktieren (%@)", controller.railContext.shortcutLabel.isEmpty ? L("Taste") : controller.railContext.shortcutLabel), scheme: scheme)
        .accessibilityLabel(L("Diktieren (%@)", controller.railContext.shortcutLabel.isEmpty ? L("Taste") : controller.railContext.shortcutLabel))
    }
}

private struct PillContextMenu: View {
    @ObservedObject var controller: DictationPresentationController
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(L("10 Minuten ausblenden")) { controller.selectSnooze(.tenMinutes) }
            Button(L("1 Stunde ausblenden")) { controller.selectSnooze(.oneHour) }
            Button(L("Bis zum nächsten Start ausblenden")) { controller.selectSnooze(.nextAppStart) }
        }.buttonStyle(.plain).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.presentation(.primary, scheme))
            .background(Color.presentation(.surface, scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.presentation(.accent, scheme).opacity(0.45)) }
    }
}


private struct CompletionNoticeCard: View {
    let notice: DictationPresentationNotice
    @ObservedObject var controller: DictationPresentationController
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.presentation(.accent, scheme))
            Text(notice.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            CardHitButton(label: L("Hinweis schließen"), prominent: false) { controller.dismissNotice() }
                .frame(width: 24, height: 24)
        }
        .padding(10).background(Color.presentation(.surface, scheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.presentation(.accent, scheme).opacity(0.45)) }
    }
}

/// Recovery text is already persisted by the coordinator. This card only offers
/// an explicit copy of that stored transcript; it never initiates insertion.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isHighlighted = true }
    override func mouseUp(with event: NSEvent) {
        defer { isHighlighted = false }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return }
        sendAction(action, to: target)
    }
}
private struct CardHitButton: NSViewRepresentable {
    let label: String
    let prominent: Bool
    let compactText: Bool
    let action: () -> Void
    init(label: String, prominent: Bool, compactText: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.prominent = prominent
        self.compactText = compactText
        self.action = action
    }
    final class Coordinator: NSObject { var action: () -> Void; init(action: @escaping () -> Void) { self.action = action }; @objc func pressed(_ sender: Any?) { action() } }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = FirstMouseButton(title: prominent || compactText ? label : "×", target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.isBordered = prominent; button.focusRingType = .none; button.setAccessibilityLabel(label)
        let accent = NSColor(calibratedRed: 0.86, green: 0.39, blue: 0.12, alpha: 1)
        if prominent {
            // NSButton's bezelColor is ignored by the inactive Aqua appearances used by the auxiliary panel.
            button.isBordered = false; button.wantsLayer = true; button.layer?.backgroundColor = accent.cgColor; button.layer?.cornerRadius = 6; button.layer?.masksToBounds = true
            button.contentTintColor = .white; button.attributedTitle = .init(string: label, attributes: [.foregroundColor: NSColor.white])
        }
        else if compactText { button.isBordered = false; button.font = .systemFont(ofSize: 13, weight: .medium); button.contentTintColor = accent; button.attributedTitle = .init(string: label, attributes: [.foregroundColor: accent, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]) }
        else { button.font = .systemFont(ofSize: 15, weight: .bold); button.contentTintColor = accent; button.attributedTitle = .init(string: "×", attributes: [.foregroundColor: accent, .font: NSFont.systemFont(ofSize: 15, weight: .bold)]) }
        return button
    }
    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.action = action }
}
private struct NoTextFieldCard: View {
    @ObservedObject var controller: DictationPresentationController
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if controller.isRecoveryCardVisible, let deadline = controller.recoveryCardDeadline {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "text.cursor").foregroundStyle(Color.presentation(.accent, scheme))
                    Text(L("Kein Textfeld ausgewählt")).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    CardHitButton(label: L("Hinweis schließen"), prominent: false) { controller.dismissRecoveryCard() }
                        .frame(width: 22, height: 22)
                        .background(CountdownCloseIcon(deadline: deadline).allowsHitTesting(false))
                }
                Text(L("Text ist im Verlauf gespeichert.")).font(.caption).fixedSize(horizontal: false, vertical: true)
                CardHitButton(label: L("Text kopieren"), prominent: false, compactText: true) { Task { await controller.requestInsertLastRecovery() } }
                    .frame(height: 18, alignment: .leading)
            }
            .padding(12).frame(width: 288, alignment: .leading).background(Color.presentation(.surface, scheme), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.presentation(.accent, scheme).opacity(0.45)) }
        }
    }
}

private struct CountdownCloseIcon: View {
    let deadline: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let progress = max(0, min(1, deadline.timeIntervalSince(context.date) / auxiliaryCardDuration))
            Image(systemName: "xmark").font(.caption.weight(.bold)).padding(5)
                .background(Circle().trim(from: 0, to: progress).stroke(Color.presentation(.accent, .light), lineWidth: 1.5).rotationEffect(.degrees(-90)))
        }
    }
}

private struct ActiveApplicationIcon: View {
    var body: some View {
        Group {
            if let image = NSWorkspace.shared.frontmostApplication?.icon { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: "app.fill") }
        }.accessibilityLabel(L("Aktive App"))
    }
}
public struct RailMeasuredWaveform: View {
    @Environment(\.colorScheme) private var scheme
    public let level: Double
    public let horizontalPill: Bool
    public init(level: Double, horizontalPill: Bool = false) { self.level = level.isFinite ? min(1,max(0,level)) : 0; self.horizontalPill = horizontalPill }
    public var body: some View {
        GeometryReader { geometry in
            let barCount = 10
            let spacing: CGFloat = 2
            if horizontalPill {
                let barWidth = max(2, (geometry.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule().fill(Color.presentation(.accent, scheme)).frame(width: barWidth, height: max(2, geometry.size.height * RailMeasuredWaveform.displayLevel(level) * RailMeasuredWaveform.weight(index, count: barCount)))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let barHeight = max(2, (geometry.size.height - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                VStack(spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule().fill(Color.presentation(.accent, scheme)).frame(width: max(2, geometry.size.width * RailMeasuredWaveform.displayLevel(level) * RailMeasuredWaveform.weight(index, count: barCount)), height: barHeight).frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }.accessibilityLabel(L("Mikrofonpegel"))
    }
    private static func weight(_ index: Int, count: Int) -> CGFloat { let center = CGFloat(count - 1) / 2; return 1 - abs(CGFloat(index) - center) / max(1, center) * 0.42 }
    private static func displayLevel(_ level: Double) -> CGFloat { CGFloat(min(1, max(0, level * 8))) }
}
private struct RailTabIcon: View {
    let phase: DictationPresentationPhase
    let outcome: PresentationActionOutcome?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false
    @State private var spin = false
    var body: some View {
        icon
            .scaleEffect(isAnimated && !reduceMotion && pulse ? 1.14 : 1)
            .opacity(isAnimated && !reduceMotion && pulse ? 0.58 : 1)
            .shadow(color: Color.presentation(statusRole, scheme).opacity(isAnimated && pulse ? 0.8 : 0.22), radius: isAnimated && pulse ? 7 : 2)
            .rotationEffect(.degrees(isProcessing && !reduceMotion && spin ? 360 : 0))
            .task(id: "\(phase.rawValue)-\(reduceMotion)") {
                pulse = false
                spin = false
                guard !reduceMotion else { return }
                await Task.yield()
                withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) { pulse = isAnimated }
                withAnimation(.linear(duration: 1.55).repeatForever(autoreverses: false)) { spin = isProcessing }
            }
            .accessibilityHidden(true)
    }
    private var icon: some View {
        Image(systemName: RailSymbolResolver.symbol(phase: phase, outcome: outcome))
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.presentation(statusRole, scheme))
    }
    private var isAnimated: Bool { phase == .listening || phase == .processing || phase == .busy }
    private var isProcessing: Bool { phase == .processing || phase == .busy }
    private var statusRole: KlangschriftPaletteRole { switch phase { case .listening: .listening; case .processing, .busy: .processing; case .success: .success; case .recoveryCopied: .secondary; case .error: .error; case .idle: .accent } }
}
public struct MenuBarPresentationView: View { @ObservedObject var controller: DictationPresentationController; public init(controller: DictationPresentationController) { self.controller = controller }; public var body: some View { VStack(alignment: .leading, spacing: 10) { Text(statusTitle).font(.headline); Text(statusDetail).font(.caption).foregroundStyle(.secondary); Button(controller.state.phase == .listening || controller.state.phase == .processing ? L("Diktat stoppen") : L("Diktat starten")) { Task { await controller.requestStartOrStop() } }; if controller.state.phase == .listening || controller.state.phase == .processing { Button(L("Abbrechen")) { Task { await controller.cancel() } } }; Divider(); Button(L("Dashboard öffnen")) { controller.openDashboard() }; Button(L("Beenden")) { controller.requestQuit() }; Divider(); Text(AppVersionDisplay.current).font(.caption).foregroundStyle(.secondary).accessibilityLabel(AppVersionDisplay.current) }.padding(8).frame(minWidth: 300).klangschriftTheme() }; private var statusTitle: String { switch controller.state.phase { case .listening: L("Aufnahme läuft"); case .processing: L("Wird transkribiert"); case .success: L("Transkript fertig"); case .recoveryCopied: L("Einfügen nicht bestätigt – Text liegt bereit"); case .error: L("Aktion erforderlich"); case .busy: L("Bitte warten"); case .idle: L("Bereit") } }; private var statusDetail: String { controller.state.phase == .recoveryCopied ? L("Bitte im Zielfeld prüfen, bevor du den Text manuell einfügst.") : L("Klangschrift verarbeitet Diktate lokal.") } }
private struct ListeningTimer: View { let start: Date?; var body: some View { TimelineView(.periodic(from: .now, by: 1)) { context in Text(elapsed(context.date)) } }; private func elapsed(_ date: Date) -> String { let seconds = max(0, Int(date.timeIntervalSince(start ?? date))); return String(format: "%d:%02d", seconds / 60, seconds % 60) } }
extension Color { static func presentation(_ role: KlangschriftPaletteRole, _ scheme: ColorScheme) -> Color { let color = KlangschriftPalette.color(role, dark: scheme == .dark); return Color(red: color.red, green: color.green, blue: color.blue) } }
