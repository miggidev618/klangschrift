import SwiftUI
import KlangschriftPresentation
/// The app scene is deliberately parameterized: P7-03 composes only fakes.
/// The executable owns the `@main` entry point, keeping this library testable.
private final class ShellPresentationLifecycle: NSObject, NSApplicationDelegate { weak var controller: DictationPresentationController?; func applicationWillTerminate(_ notification: Notification) { controller?.tearDown() } }
public struct KlangschriftAppShell: App { @StateObject private var router = OnboardingRouter(); @StateObject private var presentation = DictationPresentationController(); @NSApplicationDelegateAdaptor(ShellPresentationLifecycle.self) private var lifecycle; public init() {}; public var body: some Scene { WindowGroup("Klangschrift") { OnboardingRouterView(router: router).onAppear { lifecycle.controller = presentation } }.defaultSize(width: 980, height: 660); MenuBarExtra("Klangschrift", systemImage: "mic") { MenuBarPresentationView(controller: presentation) } } }
