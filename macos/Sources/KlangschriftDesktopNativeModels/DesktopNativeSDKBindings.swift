import Foundation
import KlangschriftDesktopModelCatalog
import KlangschriftDesktopModels
import FluidAudio
import MoonshineVoice
@preconcurrency import WhisperKit
import SherpaOnnxC

/// Names the concrete AP04 SDK boundary selected for a catalog route. This is
/// intentionally desktop-only and does not mirror an iOS lifecycle type.
public enum DesktopNativeSDKBinding: String, Sendable {
    case fluidAudio
    case moonshine
    case whisperKit
    case sherpaOnnx
}

public enum DesktopNativeSDKBindings {
    public static func binding(for modelID: String) throws -> DesktopNativeSDKBinding {
        guard let model = DesktopModelCatalog.referenceModels.first(where: { $0.id == modelID }) else {
            throw DesktopRuntimeError.unavailable
        }
        switch model.family {
        case .fluidAudioCoreML: return .fluidAudio
        case .moonshineStreaming: return .moonshine
        case .whisperKitCoreML: return .whisperKit
        case .sherpaZipformer: return .sherpaOnnx
        }
    }
}
