import KlangschriftCore
import KlangschriftDesktopModels

/// Detection is advisory; decoding always gets one language from the user's set.
/// Below three seconds there is too little speech for reliable detection.
struct WhisperPreferredLanguagePolicy {
    let preferred: [DesktopDictationLanguage]
    let last: DesktopDictationLanguage?
    init(preferredLanguages: [String], lastSuccessfulLanguage: DesktopDictationLanguage?) {
        preferred = PreferredDictationLanguages.normalized(preferredLanguages).compactMap(DesktopDictationLanguage.init(rawValue:))
        last = lastSuccessfulLanguage
    }
    func needsDetection(duration: Double) -> Bool { duration >= 3 }
    func choose(requested: DesktopDictationLanguage, duration: Double, detected: String?) -> DesktopDictationLanguage {
        guard requested == .automatic else { return requested }
        if needsDetection(duration: duration), let detected, let language = DesktopDictationLanguage(rawValue: detected), preferred.contains(language) { return language }
        if let last, preferred.contains(last) { return last }
        return preferred[0]
    }
}
