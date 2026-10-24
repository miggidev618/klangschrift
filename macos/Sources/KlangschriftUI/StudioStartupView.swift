import AppKit
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

/// The standalone app supplies Brand/ in its main bundle. A package preview or
/// damaged/missing image uses the same accent waveform without a filesystem search.
enum StartupLogoLoader {
    static func load(resourceURL: URL?) -> NSImage? {
        guard let resourceURL else { return nil }
        return NSImage(contentsOf: resourceURL.appendingPathComponent("Brand/KlangschriftLogoOchre.png"))
    }
}

/// The signed app's resource is immutable for this process. Keep both a decoded
/// image and a missing-image fallback stable across SwiftUI view reconstruction.
@MainActor final class StartupLogoCache {
    static let main = StartupLogoCache(resourceURL: Bundle.main.resourceURL)
    let image: NSImage?
    init(resourceURL: URL?) { image = StartupLogoLoader.load(resourceURL: resourceURL) }
}

enum StartupPulse {
    static func scale(reduceMotion: Bool, expanded: Bool) -> CGFloat {
        reduceMotion || expanded ? 1 : 0.55
    }
}

public struct StudioStartupLogo: View {
    private let image: NSImage?
    private let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(size: CGFloat, bundle: Bundle = .main) {
        self.size = size
        image = bundle.bundleURL == Bundle.main.bundleURL ? StartupLogoCache.main.image : StartupLogoLoader.load(resourceURL: bundle.resourceURL)
    }
    public var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { KlangschriftNotePair().fill(Color.semantic(.accent, scheme)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct StudioStartupProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array([10.0, 20, 28, 20, 10].enumerated()), id: \.offset) { _, height in
                Capsule().fill(Color.semantic(.accent, scheme)).frame(width: 4, height: height)
            }
        }
        .frame(height: 32)
        .scaleEffect(y: StartupPulse.scale(reduceMotion: reduceMotion, expanded: expanded))
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: expanded)
        .task(id: reduceMotion) { expanded = !reduceMotion }
        .accessibilityHidden(true) // The adjacent status text communicates loading once.
    }
}

/// Presentation only. The caller owns every action and lifecycle transition.
public struct StudioStartupView<Actions: View>: View {
    private let title: String
    private let message: String?
    private let isStarting: Bool
    private let actions: Actions
    @Environment(\.colorScheme) private var scheme
    public init(title: String, message: String? = nil, isStarting: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.message = message; self.isStarting = isStarting; self.actions = actions()
    }
    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    StudioStartupLogo(size: isStarting ? 148 : 64)
                    VStack(spacing: 12) {
                        Text(verbatim: title).font(.system(isStarting ? .largeTitle : .title, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.semantic(.primary, scheme)).accessibilityAddTraits(.isHeader)
                        if isStarting { StudioStartupProgress() }
                        if let message {
                            Text(verbatim: message).font(.body).foregroundStyle(Color.semantic(.secondary, scheme))
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    actions
                }
                .frame(maxWidth: 680)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollContentBackground(.hidden)
            .background(Color.semantic(.canvas, scheme))
        }
        .tint(Color.semantic(.accent, scheme))
    }
}

/// The router owns its content layout/scrolling. Keep the compact setup header
/// outside that content instead of nesting the router in the splash ScrollView.
public struct StudioStartupSetupView<Actions: View, Content: View>: View {
    private let title: String
    private let actions: Actions
    private let content: Content
    @Environment(\.colorScheme) private var scheme
    public init(title: String, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title; self.actions = actions(); self.content = content()
    }
    public var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                StudioStartupLogo(size: 44)
                Text(verbatim: title).font(.title2.weight(.semibold))
                    .foregroundStyle(Color.semantic(.primary, scheme)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                actions
            }.padding(.horizontal, 24).padding(.top, 16)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.semantic(.canvas, scheme))
        .tint(Color.semantic(.accent, scheme))
    }
}

#Preview("Starting") {
    StudioStartupView(title: "Klangschrift", message: L("Klangschrift wird gestartet …"), isStarting: true) { EmptyView() }
}
