import Foundation

/// Add only a cursor-boundary separator; preserve whitespace and punctuation.
enum KeyboardTextSpacing {
    static func insertion(_ text: String, after context: String?) -> String {
        guard let previous = context?.last, let first = text.first,
              !previous.isWhitespace, !first.isWhitespace,
              first.isLetter || first.isNumber || isEmoji(first)
                || "„«‚".contains(first) || (first == "\"" && text.count > 1),
              previous.isLetter || previous.isNumber || isEmoji(previous)
                || ".!?…:;,)]}\"”’»“".contains(previous) else { return text }
        return " " + text
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || ($0.value > 127 && $0.properties.isEmoji)
        } || character.unicodeScalars.contains { $0.value == 0x20E3 }
    }
}

#if canImport(UIKit)
import UIKit

/// Pure layout shared by the real keyboard and isolated UI geometry probes.
final class KeyboardRecordingCenter: UIStackView {
    private let waveform: UIView
    private let timer: UILabel
    private let processing: UILabel
    private let activity = UIActivityIndicatorView(style: .medium)

    init(waveform: UIView, timer: UILabel, processing: UILabel) {
        self.waveform = waveform; self.timer = timer; self.processing = processing
        super.init(frame: .zero)
        axis = .vertical; alignment = .center; spacing = 4
        [waveform, timer, activity, processing].forEach(addArrangedSubview)
        timer.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        timer.adjustsFontForContentSizeCategory = false
        timer.textAlignment = .center; timer.textColor = KlangPalette.secondary
        processing.font = .preferredFont(forTextStyle: .subheadline)
        processing.adjustsFontForContentSizeCategory = false
        processing.numberOfLines = 0; processing.textAlignment = .center
        processing.textColor = KlangPalette.secondary
        activity.color = KlangPalette.accent
        waveform.heightAnchor.constraint(equalToConstant: 44).isActive = true
        waveform.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        applyFonts()
        setProcessing(false)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func applyFonts() {
        timer.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), maximumPointSize: 24, compatibleWith: traitCollection)
        processing.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 22, compatibleWith: traitCollection)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection); applyFonts()
    }
    func setProcessing(_ value: Bool) {
        waveform.isHidden = value; timer.isHidden = value; processing.isHidden = !value
        activity.isHidden = !value || UIAccessibility.isReduceMotionEnabled
        if value && !UIAccessibility.isReduceMotionEnabled { if !activity.isAnimating { activity.startAnimating() } } else { activity.stopAnimating() }
    }
}

#endif
