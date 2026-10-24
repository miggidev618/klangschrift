import KlangschriftPresentation
import Foundation

/// Bundled measurements only; never derives scores from model size or family.
struct ModelPerformanceCatalog: Decodable, Sendable {
    let version: Int
    let measuredBuild: Int?
    let measuredAt: String?
    let device: String?
    let models: [String: ModelPerformance]

    static let empty = ModelPerformanceCatalog(version: 1, measuredBuild: nil, measuredAt: nil, device: nil, models: [:])
    static let bundled: ModelPerformanceCatalog = (try? loadBundled()) ?? .empty
    static func loadBundled() throws -> ModelPerformanceCatalog {
        guard let url = Bundle.module.url(forResource: "ModelPerformance", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> ModelPerformanceCatalog {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return result
    }

    func presentation(for modelID: String, coldPrepareMilliseconds: UInt64? = nil, warmInferenceMilliseconds: UInt64? = nil) -> ModelPerformancePresentation {
        let model = models[modelID]
        func valid(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? false }
        func rating(_ label: String, _ value: Int?, basis: Bool) -> String? {
            guard basis, let value, (1...10).contains(value) else { return nil }
            return "\(label): \(value)/10"
        }
        func metric(_ value: Double?, _ format: (Double) -> String) -> String? {
            guard let value, valid(value) else { return nil }
            return format(value)
        }
        let qualityBasis = model?.qualityBasis?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ratings = [rating(L("Qualität"), model?.quality, basis: qualityBasis?.isEmpty == false),
                       rating(L("Schnelligkeit"), model?.speed, basis: valid(model?.warmMsPerAudioSecond)),
                       rating(L("Ressourcenschonung"), model?.load, basis: valid(model?.peakRssMB))].compactMap { $0 }
        let warm = metric(model?.warmMsPerAudioSecond) { L("~%@ s pro 1 s Sprache (warm)", String(describing: Self.decimal($0 / 1_000))) }
        let cold = metric(model?.coldLoadMs) { L("Erstladen: ~%@ s", String(describing: Self.decimal($0 / 1_000))) }
        let ram = metric(model?.peakRssMB) { L("RAM-Spitze: ~%@ GB", String(describing: Self.decimal($0 / 1_000))) }
        let cpu = metric(model?.cpuPercent) { "CPU: ~\(Self.decimal($0)) %" }
        let hasReference = !ratings.isEmpty || [warm, cold, ram, cpu].contains { $0 != nil } || qualityBasis?.isEmpty == false
        let metrics = [warm, cold, ram, cpu].compactMap { $0 }
        var local: [String] = []
        if let coldPrepareMilliseconds { local.append(L("Vorbereitung ~%@ s", String(describing: Self.decimal(Double(coldPrepareMilliseconds) / 1_000)))) }
        if let warmInferenceMilliseconds { local.append(L("warme Transkription ~%@ s", String(describing: Self.decimal(Double(warmInferenceMilliseconds) / 1_000)))) }
        let localMeasurement = local.isEmpty ? nil : L("Auf diesem Mac zuletzt: ") + local.joined(separator: " · ")
        var context: [String] = []
        if hasReference {
            if model?.measuredAt == nil, let build = measuredBuild { context.append("Build \(build)") }
            if let date = model?.measuredAt ?? measuredAt, !date.isEmpty { context.append(ModelPerformanceProvenance.date(date)) }
            if let device = model?.device ?? device, !device.isEmpty { context.append(ModelPerformanceProvenance.device(device)) }
        }
        return .init(ratings: ratings, metrics: metrics,
                     context: context.isEmpty ? nil : L("Gemessen mit ") + context.joined(separator: " · "),
                     qualityBasis: qualityBasis?.isEmpty == false ? qualityBasis.map { AppLocalization.productText($0) } : nil, notes: model?.notes.map { AppLocalization.productText($0) },
                     localMeasurement: localMeasurement,
                     emptyMessage: ratings.isEmpty ? L("Noch nicht bewertet") : nil)
    }

    func comparison(for modelID: String) -> ModelComparisonMetrics {
        let model = models[modelID]
        func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        func score(_ value: Int?, basis: Bool) -> Int? {
            guard basis, let value, (1...10).contains(value) else { return nil }
            return value
        }
        let warm = valid(model?.warmMsPerAudioSecond)
        let ram = valid(model?.peakRssMB)
        return .init(quality: score(model?.quality, basis: model?.qualityBasis?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
                     speed: score(model?.speed, basis: warm != nil),
                     resources: score(model?.load, basis: ram != nil),
                     secondsPerAudioSecond: warm.map { $0 / 1_000 }, ramGB: ram.map { $0 / 1_000 })
    }

    private static func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = AppLocalization.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct ModelPerformance: Decodable, Sendable {
    let measuredAt: String?
    let device: String?
    let quality: Int?
    let speed: Int?
    /// Higher is better: 10 means very low resource use.
    let load: Int?
    let warmMsPerAudioSecond: Double?
    let coldLoadMs: Double?
    /// Decimal megabytes: bytes / 1_000_000 (not MiB). Display GB = MB / 1_000.
    let peakRssMB: Double?
    /// May exceed 100 when several CPU cores are used.
    let cpuPercent: Double?
    let qualityBasis: String?
    let notes: String?
}

struct ModelPerformancePresentation: Sendable {
    let ratings: [String]
    let metrics: [String]
    let context: String?
    let qualityBasis: String?
    let notes: String?
    let localMeasurement: String?
    let emptyMessage: String?
    var scale: String? { ratings.isEmpty ? nil : L("Skala 1–10: 10 = am besten.") }
    var measurementAccessibilityValue: String {
        (metrics + [qualityBasis, context, localMeasurement, emptyMessage, notes].compactMap { $0 })
            .joined(separator: ". ").replacingOccurrences(of: "~", with: L("etwa "))
    }
    var accessibilityValue: String {
        (ratings + [scale].compactMap { $0 } + metrics + [qualityBasis, context, localMeasurement, emptyMessage, notes].compactMap { $0 })
            .joined(separator: ". ").replacingOccurrences(of: "~", with: L("etwa "))
    }
}

struct ModelComparisonMetrics {
    let quality: Int?
    let speed: Int?
    let resources: Int?
    let secondsPerAudioSecond: Double?
    let ramGB: Double?
    var hasReferenceMeasurement: Bool {
        quality != nil || speed != nil || resources != nil || secondsPerAudioSecond != nil || ramGB != nil
    }
}

/// Display formatting only; measurement receipts and values remain unchanged.
enum ModelPerformanceProvenance {
    static func date(_ value: String, locale: Locale = AppLocalization.locale) -> String {
        let iso = ISO8601DateFormatter()
        let timestamp = iso.date(from: value)
        iso.formatOptions = [.withFullDate]
        guard let date = timestamp ?? iso.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func device(_ value: String, language: String = AppLocalization.language) -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let cores = Int(parts[1]), cores > 0,
              let bytes = UInt64(parts[2]), bytes > 0 else { return value }
        let locale = Locale(identifier: language)
        let coreCount = cores.formatted(.number.locale(locale))
        let coreLabel = AppLocalization.text(cores == 1 ? "%@ Kern" : "%@ Kerne", language: language, arguments: [coreCount])
        // hw.memsize describes the physical memory configuration, conventionally
        // advertised as 16/32 GB; this is separate from decimal process-RSS metrics.
        let memory = (Double(bytes) / 1_073_741_824).formatted(.number.locale(locale).precision(.fractionLength(0...1)))
        return "\(parts[0]) · \(coreLabel) · \(memory) GB"
    }
}

/// Compact display only. Raw bytes, model identities and measurement values
/// remain the source for sorting and accessibility descriptions.
enum ModelComparisonFormatting {
    /// Raw values belong to the unchanged model-service language contract.
    private enum Language: String {
        case german = "Deutsch"
        case english = "English"
        case multilingual = "Mehrsprachig"
        case tagalog = "Tagalog"
        case spanish = "Spanisch"
        case japanese = "Japanisch"
        case arabic = "Arabisch"
        case vietnamese = "Vietnamesisch"
        case mandarin = "Mandarin"
    }
    static func languageCode(_ language: String) -> String {
        switch Language(rawValue: language) {
        case .german: "DE"
        case .english: "EN"
        case .multilingual: L("Mehrsprachig")
        case .tagalog: "TL"
        case .spanish: "ES"
        case .japanese: "JA"
        case .arabic: "AR"
        case .vietnamese: "VI"
        case .mandarin: "ZH"
        case nil: language
        }
    }
    static func modelTitle(_ title: String, language: String) -> String {
        let code = languageCode(language)
        let suffix = " " + code
        let name = title.hasSuffix(suffix) ? String(title.dropLast(suffix.count)) : title
        return name + " · " + code
    }
    static func size(_ bytes: Int, locale: Locale = AppLocalization.locale) -> String {
        guard bytes > 0 else { return "–" }
        if bytes < 1_000 { return "\(bytes) B" }
        let divisor: Double = bytes >= 1_000_000_000 ? 1_000_000_000 : bytes >= 1_000_000 ? 1_000_000 : 1_000
        let unit = bytes >= 1_000_000_000 ? "GB" : bytes >= 1_000_000 ? "MB" : "KB"
        let value = Double(bytes) / divisor
        return value.formatted(.number.locale(locale).precision(.fractionLength(0...(unit == "GB" ? 1 : 0)))) + " " + unit
    }
}

/// Scores retain their measurement basis in the catalog; only presentation
/// changes to a five-star scale. Missing/invalid scores never become zero stars.
struct ModelStarRating: Equatable, Sendable {
    let score: Int?
    init(score: Int?) { self.score = score.flatMap { (1...10).contains($0) ? $0 : nil } }
    var value: Double? { score.map { Double($0) / 2 } }
    var symbols: [String] {
        guard let value else { return [] }
        return (0..<5).map { index in
            let remaining = value - Double(index)
            return remaining >= 1 ? "star.fill" : remaining >= 0.5 ? "star.leadinghalf.filled" : "star"
        }
    }
    func description(language: String = AppLocalization.language) -> String {
        guard let value else { return AppLocalization.text("Noch nicht bewertet", language: language) }
        let number = value.formatted(.number.locale(Locale(identifier: language)).precision(.fractionLength(0...1)))
        return AppLocalization.text("%@ von 5 Sternen", language: language, arguments: [number])
    }
}
