import SwiftUI
import AppKit
import os
import KlangschriftAppComposition
import KlangschriftAppIntegration
import KlangschriftPresentation
import KlangschriftAppAdapters

/// One retained window object, supplied as a fake in non-native tests.
@MainActor protocol DashboardAppWindow: AnyObject {
    var isVisible: Bool { get }
    func show()
}

@MainActor private final class AppKitDashboardWindow: DashboardAppWindow {
    private let window: NSWindow
    init(composition: AppComposition) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(KlangschriftApplicationLifecycle.dashboardID)
        window.title = "Klangschrift"
        window.isReleasedWhenClosed = false
        // Keep the exact production hierarchy: PermissionRecoveryHost, onboarding,
        // startup tasks and the ready graph all remain inside ProductionRootView.
        window.contentViewController = NSHostingController(rootView: ProductionRootView(composition: composition))
        let restored = window.setFrameUsingName(KlangschriftApplicationLifecycle.frameAutosaveName)
        window.setFrameAutosaveName(KlangschriftApplicationLifecycle.frameAutosaveName)
        if !restored { window.center() }
    }
    var isVisible: Bool { window.isVisible }
    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The single dashboard and process-exit owner, attached before any view exists.
@MainActor final class KlangschriftApplicationLifecycle: NSObject, NSApplicationDelegate, DashboardWindowOpening {
    typealias TerminationFactory = @MainActor (@escaping @MainActor () async -> Void) -> ApplicationTerminationCoordinator
    static let dashboardID = "dashboard"
    static let frameAutosaveName = "KlangschriftDashboard"
    private static let log = Logger(subsystem: "io.github.miggidev618.klangschrift", category: "app")
    private(set) weak var composition: AppComposition?
    private(set) var termination: ApplicationTerminationCoordinator?
    private(set) var dashboardWindow: (any DashboardAppWindow)?
    private(set) var terminationStarted = false
    private(set) var terminationRequestPending = false
    private var launchHandled = false
    private let makeWindow: @MainActor (AppComposition) -> any DashboardAppWindow
    private let terminateApplication: @MainActor () -> Void
    private let makeTerminationCoordinator: TerminationFactory

    override convenience init() {
        self.init(makeWindow: { AppKitDashboardWindow(composition: $0) }, terminateApplication: { NSApp.terminate(nil) })
    }
    init(makeWindow: @escaping @MainActor (AppComposition) -> any DashboardAppWindow, terminateApplication: @escaping @MainActor () -> Void, makeTerminationCoordinator: @escaping TerminationFactory = { ApplicationTerminationCoordinator(shutdown: $0) }) {
        self.makeWindow = makeWindow
        self.terminateApplication = terminateApplication
        self.makeTerminationCoordinator = makeTerminationCoordinator
        super.init()
    }
    @discardableResult func attach(_ composition: AppComposition) -> Bool {
        guard self.composition == nil else { return false }
        self.composition = composition
        composition.attachApplicationTerminationRequest { [weak self] in self?.requestTermination() }
        composition.attachDashboardWindowOpening(self)
        termination = makeTerminationCoordinator { [weak composition] in await composition?.quit() }
        Self.log.notice("lifecycle.attach")
        Self.log.notice("opener.registered(source: appKitOwner)")
        return true
    }
    func openDashboardWindow() {
        Self.log.notice("openDashboard.requested")
        guard !terminationStarted else { Self.log.notice("openDashboard.blockedTermination"); return }
        guard let composition else { Self.log.notice("opener.missing"); return }
        let window: any DashboardAppWindow
        if let existing = dashboardWindow {
            Self.log.notice("window.reused")
            window = existing
        } else {
            Self.log.notice("window.created")
            window = makeWindow(composition)
            dashboardWindow = window
        }
        Self.log.notice("appkitWindow.called")
        window.show()
        let visible = window.isVisible
        Self.log.notice("window.visibleAfter(\(visible, privacy: .public))")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launchHandled else { return }
        launchHandled = true
        openDashboardWindow()
    }
    func handleReopen() -> Bool {
        openDashboardWindow()
        return false // AppKit must not perform its own additional reopen.
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { handleReopen() }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.terminationStarted, let composition = self.composition else { return }
            await composition.applicationDidBecomeActive()
        }
    }
    func requestTermination() {
        guard !terminationRequestPending else { return }
        terminationStarted = true
        terminationRequestPending = true
        terminateApplication()
    }
    func handleTerminationRequest(reply: @escaping @MainActor (Bool) -> Void) -> ApplicationTerminationCoordinator.Decision {
        terminationStarted = true
        terminationRequestPending = true
        let coordinator = termination ?? makeTerminationCoordinator { [weak composition] in await composition?.quit() }
        termination = coordinator
        let decision = coordinator.request { [weak self] allow in
            // A timeout rejects only this request. Cleanup and the permanent
            // opening block remain active, but a subsequent Quit may retry.
            self?.terminationRequestPending = false
            reply(allow)
        }
        if decision == .terminateNow { terminationRequestPending = false }
        return decision
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch handleTerminationRequest(reply: { [weak sender] allow in sender?.reply(toApplicationShouldTerminate: allow) }) {
        case .terminateNow: return .terminateNow
        case .terminateLater: return .terminateLater
        }
    }

}

@MainActor struct ProductionMenuRoot: View {
    @ObservedObject var composition: AppComposition
    let lifecycle: KlangschriftApplicationLifecycle
    var body: some View {
        if let graph = composition.graph { graph.menuSurface }
        else {
            Button(L("Klangschrift öffnen")) { lifecycle.openDashboardWindow() }
            Text(L("Klangschrift ist noch nicht eingerichtet.")).padding(8)
            Divider()
            Text(AppVersionDisplay.current).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@main struct KlangschriftApp: App {
    @StateObject private var composition: AppComposition
    @NSApplicationDelegateAdaptor(KlangschriftApplicationLifecycle.self) private var lifecycle
    private static func makeRoot(arbiter: EphemeralDictationArbiter, legacyImport: LegacyMLXImportRequest? = nil, startupFailure: LegacyMLXImportEntryError? = nil) -> AppComposition {
        ProductionCompositionFactory.make(legacyImport: legacyImport, startupFailure: startupFailure, recordingArbiter: arbiter) { foundation in
            let modelPresentation = AP05DesktopModelPresentationFactory.makeIfBundled(applicationSupportRoot: foundation.paths.root, legacyStandardAvailable: true)
            return try await ProductionAssemblyFactory.makeGraph(
                foundation: foundation,
                recordingArbiter: arbiter,
                modelPresenter: modelPresentation?.presenter,
                modelLifecycle: modelPresentation?.lifecycle
            )
        }
    }
    init() {
        let arbiter = EphemeralDictationArbiter()
        // This opt-in entry is the only legacy-byte handoff.  Its roots arrive
        // explicitly from the conscious launch action; no cache is scanned.
        let root = LegacyMLXImportEntry.route(arguments: CommandLine.arguments,
                                               normal: { Self.makeRoot(arbiter: arbiter) },
                                               importing: { Self.makeRoot(arbiter: arbiter, legacyImport: $0) },
                                               rejected: { Self.makeRoot(arbiter: arbiter, startupFailure: $0) })
        _composition = StateObject(wrappedValue: root)
        // Exit cleanup must not depend on any Window/Menu view appearing.
        lifecycle.attach(root)
    }
    var body: some Scene {
        MenuBarExtra("Klangschrift", systemImage: "mic") {
            ProductionMenuRoot(composition: composition, lifecycle: lifecycle)
                .klangschriftTheme()
        }
    }
}
