import Foundation
import KlangschriftAppIntegration
import KlangschriftDesktopModelProduct
import KlangschriftUI

/// Resolves only AP07-bundled AP04 assets. There is deliberately no source-tree,
/// PATH, legacy-MLX or user-cache fallback: an absent product bundle simply
/// leaves the separate desktop-model management surface unavailable.
public struct AP05DesktopModelPresentation {
    public let presenter: any AP05ModelPresenting
    public let lifecycle: any AP05DesktopModelLifecycleControlling
    public init(presenter: any AP05ModelPresenting, lifecycle: any AP05DesktopModelLifecycleControlling) {
        self.presenter = presenter
        self.lifecycle = lifecycle
    }
}

public enum AP05DesktopModelPresentationFactory {
    public static func makeIfBundled(bundle: Bundle = .main, applicationSupportRoot: URL, legacyStandardAvailable: Bool = false) -> AP05DesktopModelPresentation? {
        guard let manifest = bundle.url(forResource: "AP04-REFERENCE-MANIFESTS", withExtension: "json"),
              let worker = bundle.url(forAuxiliaryExecutable: "KlangschriftDesktopNativeWorker"),
              FileManager.default.isExecutableFile(atPath: worker.path)
        else { return nil }

        do {
            let service = try DesktopModelProductService.production(
                manifestSourceURL: manifest,
                installerRoot: applicationSupportRoot.appendingPathComponent("desktop-models-v1", isDirectory: true),
                workerURL: worker
            )
            let adapter = AP05DesktopModelProductAdapter(service: service, legacyStandardAvailable: legacyStandardAvailable)
            return .init(presenter: adapter, lifecycle: adapter)
        } catch {
            // Manifest/worker details remain in AP04/AP07 evidence. The normal
            // product surface neither exposes diagnostics nor creates a fallback.
            return nil
        }
    }
}
