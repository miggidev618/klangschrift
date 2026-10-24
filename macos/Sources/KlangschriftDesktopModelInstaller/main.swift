import Darwin
import Foundation
import KlangschriftDesktopModels

/// Explicit AP04 installer entry point. It is intentionally separate from
/// preload/transcription: neither of those paths has a download transport.
@main
struct KlangschriftDesktopModelInstaller {
    static func main() async {
        do {
            let values = Array(CommandLine.arguments.dropFirst())
            func value(_ name: String) -> String? {
                guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
                return values[index + 1]
            }
            guard let catalogPath = value("--catalog"), let rootPath = value("--root"), let modelID = value("--model-id") else {
                throw InstallerError.invalidArguments
            }
            let manifests = try DesktopModelInstallCatalog.manifests(from: URL(fileURLWithPath: catalogPath))
            guard let manifest = manifests[modelID] else { throw InstallerError.invalidArguments }
            let installer = DesktopModelInstaller(root: URL(fileURLWithPath: rootPath, isDirectory: true))
            let destination = try await installer.install(manifest)
            print(destination.path)
        } catch {
            fputs("KLANGSCHRIFT_INSTALLER_FAILED\n", stderr)
            exit(1)
        }
    }
}

private enum InstallerError: Error { case invalidArguments }
