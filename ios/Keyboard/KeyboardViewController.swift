import UIKit
import SwiftUI

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let primary = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let globe = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let meter = UIProgressView(progressViewStyle: .default)
    private let waveform = KeyboardWaveformView()
    private let processingLabel = UILabel()
    private let recordingHint = UILabel()
    private let recordingElapsedLabel = UILabel()
    private var recordingCenter: KeyboardRecordingCenter!
    private let recordingTools = UIView()
    private let recordCancel = UIButton(type: .system)
    private let recordStop = UIButton(type: .system)
    private let recordingGlobe = UIButton(type: .system)
    private var typingControls: UIStackView!
    private var actionRow: UIStackView!
    private var recordingRow: UIStackView!
    private var timer: Timer?
    private var pollingRecording = false
    private var store: KeyboardBridgeStore?
    private var sessionID: UUID?
    private var request: KeyboardBridgeRequest?
    private var snapshot: KeyboardBridgeState?
    private var actionError: String?
    private var openingHost = false
    private var openingHostDeadline: Date?
    private var visible = false
    private let presenceInstanceID = UUID()
    private var presenceSessionID: UUID?
    private var openLink: UIHostingController<KeyboardOpenLink>?
    private var lastMismatchTrace: (sessionID: UUID, requestID: UUID, phase: KeyboardBridgePhase, documentMatches: Bool)?
    private var lastSuccessfullyInsertedDictation: String?
    private var waveformIsRecording = false
    private var deleteRepeatDelayTimer: Timer?
    private var deleteRepeatTimer: Timer?

    override func loadView() {
        let keyboard = KeyboardFeedbackInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView = keyboard
        view = keyboard
    }

    private var favorites = KeyboardModelFavorites()
    private var selectedFavoriteID: String?
    private var displayedPhase: KeyboardBridgePhase?
    private let favoriteButtons = [UIButton(type: .system), UIButton(type: .system)]
    private let favoriteRow = UIStackView()

    private func favoriteChoice() throws -> (String?, UUID?) {
        guard let store = KeyboardModelFavoritesStore() else { return (nil, nil) }
        let current = try store.read()
        let selected = current.contains(selectedFavoriteID ?? "") ? selectedFavoriteID : current.models.first?.id
        return (selected, selected == nil ? nil : current.revision)
    }

    @objc private func chooseFavorite(_ sender: UIButton) {
        guard !favoriteRow.isHidden, sender.isEnabled, favorites.models.indices.contains(sender.tag) else { return }
        selectedFavoriteID = favorites.models[sender.tag].id
        refresh()
    }

    private func refreshFavoriteButtons() {
        if let current = try? KeyboardModelFavoritesStore()?.read() { favorites = current }
        if !favorites.contains(selectedFavoriteID ?? "") { selectedFavoriteID = favorites.models.first?.id }
        let pending = snapshot?.request
        let idle = pending == nil || pending?.consumed == true || pending?.phase == .failed
        favoriteRow.isHidden = !hasFullAccess || !idle || snapshot?.hasPendingCancellation(at: .now) == true || favorites.models.isEmpty
        for (index, button) in favoriteButtons.enumerated() {
            guard favorites.models.indices.contains(index) else { button.isHidden = true; continue }
            button.isHidden = false
            let model = favorites.models[index]
            let lease = snapshot?.audioSessionLease
            let ready = lease.map { Date() < $0.expiresAt && $0.expiresAt.timeIntervalSinceNow <= 2 && $0.favoritesRevision == favorites.revision && $0.preparedModelIDs?.contains(model.id) == true } ?? false
            button.configuration?.title = keyboardLanguageTitle(for: model.id)
            button.configuration?.subtitle = model.title
            button.configuration?.baseBackgroundColor = selectedFavoriteID == model.id ? KlangPalette.selected : KlangPalette.surface
            button.configuration?.baseForegroundColor = selectedFavoriteID == model.id ? KlangPalette.accent : KlangPalette.ink
            button.accessibilityLabel = "\(keyboardLanguageTitle(for: model.id)), \(model.title), \(ready ? L("ready", "bereit") : L("open app to prepare", "in App vorbereiten")), \(selectedFavoriteID == model.id ? L("selected", "ausgewählt") : L("select", "auswählen"))"
        }
    }

    private func keyboardLanguageTitle(for modelID: String) -> String {
        // Fixed-language models keep their own dictation language.
        if modelID.contains("-de") { return L("German", "Deutsch") }
        if modelID.contains("-en") || modelID.hasPrefix("phonon2") || modelID.hasPrefix("sherpa") { return L("English", "Englisch") }
        let fixedLanguages: [(String, String, String)] = [
            ("es", "Spanish", "Spanisch"), ("ja", "Japanese", "Japanisch"),
            ("ar", "Arabic", "Arabisch"), ("tl", "Tagalog", "Tagalog"),
            ("vi", "Vietnamese", "Vietnamesisch"), ("zh", "Chinese", "Chinesisch")
        ]
        if let language = fixedLanguages.first(where: { modelID.hasSuffix("-" + $0.0) }) {
            return L(language.1, language.2)
        }
        if modelID.hasPrefix("whisper") {
            // Root must mirror the host selection into the shared defaults.
            let language = UserDefaults(suiteName: "group.io.github.miggidev618.klangschrift")?.string(forKey: "klangschrift.dictation-language.v1")
            switch language {
            case "de": return L("German", "Deutsch")
            case "en": return L("English", "Englisch")
            case "auto": return L("Auto", "Auto")
            default: return L("Auto", "Auto")
            }
        }
        return L("Auto", "Auto")
    }

    private func updateCopyAppearance() {
        let enabled = lastSuccessfullyInsertedDictation != nil
        copyButton.isEnabled = enabled
        copyButton.tintColor = enabled ? KlangPalette.accent : KlangPalette.secondary.withAlphaComponent(0.35)
        copyButton.backgroundColor = enabled ? KlangPalette.selected : .clear
        copyButton.layer.cornerRadius = 12
        copyButton.accessibilityLabel = L("Copy last dictation", "Letztes Diktat kopieren")
        copyButton.accessibilityHint = enabled ? L("Copies your last inserted text.", "Kopiert den zuletzt eingefügten Text.") : L("Available after inserting a dictation.", "Nach dem Einfügen eines Diktats verfügbar.")
        deleteButton.accessibilityLabel = L("Delete character", "Zeichen löschen")
        globe.accessibilityLabel = L("Next keyboard", "Nächste Tastatur")
        recordingGlobe.accessibilityLabel = globe.accessibilityLabel
        recordCancel.accessibilityLabel = L("Cancel dictation", "Diktat abbrechen")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = KlangPalette.canvas
        view.tintColor = KlangPalette.accent
        titleLabel.text = L("♪  Klangschrift", "♪  Klangschrift")
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.textColor = KlangPalette.ink
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = KlangPalette.secondary
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.numberOfLines = 3
        previewLabel.font = .preferredFont(forTextStyle: .body)
        previewLabel.textColor = KlangPalette.ink
        previewLabel.isAccessibilityElement = true
        primary.configuration = .filled()
        primary.configuration?.baseBackgroundColor = KlangPalette.action
        primary.configuration?.baseForegroundColor = KlangPalette.onAction
        primary.configuration?.cornerStyle = .large
        primary.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        primary.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        cancelButton.setTitle(L("Cancel", "Abbrechen"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelAction), for: .touchUpInside)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.accessibilityLabel = L("Next keyboard", "Nächste Tastatur")
        globe.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)
        copyButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        copyButton.accessibilityLabel = L("Copy last dictation", "Letztes Diktat kopieren")
        copyButton.addTarget(self, action: #selector(copyLastDictation), for: .touchUpInside)
        copyButton.isEnabled = false
        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.accessibilityLabel = L("Delete character", "Zeichen löschen")
        deleteButton.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(stopDeleteRepeat), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        let punctuation = ["@", ".", ",", "?", "!", "'"].map { character in
            let button = miniKey(character, label: character)
            button.addTarget(self, action: #selector(insertMiniKey(_:)), for: .touchUpInside)
            return button
        }
        styleMiniKey(deleteButton)
        let punctuationRow = UIStackView(arrangedSubviews: punctuation + [deleteButton])
        punctuationRow.axis = .horizontal; punctuationRow.distribution = .fillEqually; punctuationRow.spacing = 5
        let abc = miniKey("ABC", label: L("Next keyboard", "Nächste Tastatur"))
        abc.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)
        let space = miniKey(L("space", "Leerzeichen"), label: L("Space", "Leerzeichen"))
        space.accessibilityIdentifier = "mini-space"
        space.addTarget(self, action: #selector(insertMiniKey(_:)), for: .touchUpInside)
        let enter = miniKey("↵", label: L("Return", "Zeilenumbruch"))
        enter.accessibilityIdentifier = "mini-return"
        enter.addTarget(self, action: #selector(insertMiniKey(_:)), for: .touchUpInside)
        let textRow = UIStackView(arrangedSubviews: [abc, space, enter])
        textRow.axis = .horizontal; textRow.spacing = 5
        let utilityRow = UIStackView(arrangedSubviews: [globe, copyButton])
        utilityRow.axis = .horizontal; utilityRow.distribution = .fillEqually
        [globe, copyButton].forEach { button in
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.tintColor = KlangPalette.secondary
        }
        typingControls = UIStackView(arrangedSubviews: [punctuationRow, textRow, utilityRow])
        typingControls.axis = .vertical; typingControls.spacing = 6
        abc.widthAnchor.constraint(equalTo: punctuation[0].widthAnchor, multiplier: 1.5).isActive = true
        enter.widthAnchor.constraint(equalTo: abc.widthAnchor).isActive = true
        let hostLink = UIHostingController(rootView: KeyboardOpenLink(title: L("Tap to speak", "Diktieren"), action: { [weak self] _ in
            guard let self, let store = self.store else { return .discarded }
            do {
                self.actionError = nil
                let choice = try self.favoriteChoice()
                if let warm = try store.startWarm(documentID: self.textDocumentProxy.documentIdentifier, instanceID: self.presenceInstanceID, modelID: choice.0, favoritesRevision: choice.1) {
                    self.sessionID = warm.sessionID
                    self.request = try store.read()?.request
                    self.playAcceptedClick()
                    self.refresh()
                    return .handled
                }
                let handoff = try self.handoffForLink(from: store, modelID: choice.0, favoritesRevision: choice.1)
                try store.setPresence(instanceID: self.presenceInstanceID, sessionID: handoff.sessionID, claim: true)
                self.presenceSessionID = handoff.sessionID
                self.sessionID = handoff.sessionID
                self.request = try store.read()?.request
                KeyboardBridgeDiagnostics.record("keyboard_link_tap", sessionID: handoff.sessionID, requestID: handoff.requestID, documentMatches: self.request?.documentID == self.textDocumentProxy.documentIdentifier, phase: self.request?.phase)
                self.openingHost = true
                self.openingHostDeadline = Date().addingTimeInterval(4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.openingHost, self.openingHostDeadline.map({ Date() >= $0 }) == true else { return }
                    self.openingHost = false
                    self.openingHostDeadline = nil
                    self.actionError = L("Could not open Klangschrift. Please try again.", "Klangschrift konnte nicht geöffnet werden. Bitte erneut tippen.")
                    self.refresh()
                }
                self.playAcceptedClick()
                return .systemAction(handoff.url)
            } catch {
                self.actionError = L("Please try again.", "Bitte erneut versuchen.")
                self.refresh()
                return .discarded
            }
        }))
        addChild(hostLink); hostLink.view.backgroundColor = .clear
        hostLink.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        hostLink.didMove(toParent: self); openLink = hostLink
        actionRow = UIStackView(arrangedSubviews: [primary, hostLink.view, cancelButton])
        actionRow.axis = .horizontal; actionRow.spacing = 8; actionRow.distribution = .fillEqually
        recordCancel.setImage(UIImage(systemName: "xmark"), for: .normal)
        recordCancel.accessibilityLabel = L("Cancel dictation", "Diktat abbrechen")
        recordCancel.addTarget(self, action: #selector(cancelAction), for: .touchUpInside)
        recordStop.setImage(UIImage(systemName: "checkmark"), for: .normal)
        recordStop.accessibilityLabel = L("Stop recording", "Aufnahme stoppen")
        recordStop.addTarget(self, action: #selector(primaryAction), for: .touchUpInside)
        [recordCancel, recordStop].forEach { button in
            button.tintColor = KlangPalette.onAction
            button.backgroundColor = KlangPalette.action
            button.layer.cornerRadius = 22
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        recordingGlobe.setImage(UIImage(systemName: "globe"), for: .normal)
        recordingGlobe.accessibilityLabel = L("Next keyboard", "Nächste Tastatur")
        recordingGlobe.tintColor = KlangPalette.ink
        recordingGlobe.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)
        recordingGlobe.widthAnchor.constraint(equalToConstant: 44).isActive = true
        recordingGlobe.heightAnchor.constraint(equalToConstant: 44).isActive = true
        processingLabel.text = L("Creating text …", "Text wird erstellt …")
        processingLabel.textAlignment = .center
        processingLabel.font = .preferredFont(forTextStyle: .subheadline)
        processingLabel.textColor = KlangPalette.secondary
        recordingCenter = KeyboardRecordingCenter(waveform: waveform, timer: recordingElapsedLabel, processing: processingLabel)
        recordingRow = UIStackView(arrangedSubviews: [recordCancel, recordingCenter, recordStop])
        recordingRow.axis = .horizontal; recordingRow.alignment = .center; recordingRow.spacing = 12
        recordCancel.backgroundColor = KlangPalette.selected; recordCancel.tintColor = KlangPalette.accent
        recordingGlobe.translatesAutoresizingMaskIntoConstraints = false
        recordingTools.addSubview(recordingGlobe)
        recordingTools.heightAnchor.constraint(equalToConstant: 44).isActive = true
        NSLayoutConstraint.activate([
            recordingGlobe.centerXAnchor.constraint(equalTo: recordingTools.centerXAnchor),
            recordingGlobe.centerYAnchor.constraint(equalTo: recordingTools.centerYAnchor)
        ])
        recordingHint.font = .preferredFont(forTextStyle: .caption1)
        recordingHint.textColor = KlangPalette.secondary
        recordingHint.textAlignment = .center
        recordingHint.numberOfLines = 2
        recordingHint.isHidden = true
        favoriteRow.axis = .horizontal; favoriteRow.distribution = .fillEqually; favoriteRow.spacing = 6
        for (index, button) in favoriteButtons.enumerated() {
            button.tag = index; button.configuration = .filled(); button.configuration?.buttonSize = .mini; button.configuration?.cornerStyle = .medium
            button.addTarget(self, action: #selector(chooseFavorite(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 2
            favoriteRow.addArrangedSubview(button)
        }
        let stack = UIStackView(arrangedSubviews: [favoriteRow, statusLabel, previewLabel, actionRow, recordingRow, recordingHint, recordingTools, typingControls])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
            typingControls.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        let height = view.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        height.priority = .defaultHigh; height.isActive = true
        applyKeyboardFonts()
    }

    private func applyKeyboardFonts() {
        let chipFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 24, compatibleWith: traitCollection)
        for button in favoriteButtons {
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var output = incoming; output.font = chipFont; return output
            }
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.titleLabel?.lineBreakMode = .byWordWrapping
        }
        let actionFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 24, compatibleWith: traitCollection)
        primary.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var output = incoming; output.font = actionFont; return output
        }
        primary.titleLabel?.adjustsFontSizeToFitWidth = true; primary.titleLabel?.minimumScaleFactor = 0.85
        cancelButton.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), maximumPointSize: 20, compatibleWith: traitCollection)
        cancelButton.tintColor = KlangPalette.accent
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { applyKeyboardFonts(); waveform.setNeedsDisplay() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true; openingHost = false; openingHostDeadline = nil
        store = hasFullAccess ? KeyboardBridgeStore() : nil
        timer?.invalidate(); timer = nil
        configurePolling(recording: false)
        if let state = try? store?.read() {
            try? store?.setPresence(instanceID: presenceInstanceID, sessionID: state.sessionID, claim: true)
            presenceSessionID = state.sessionID
        }
        refresh()
        KeyboardBridgeDiagnostics.record("keyboard_visible", sessionID: sessionID, requestID: request?.id, phase: request?.phase, fullAccess: hasFullAccess, storeAvailable: store != nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visible = false
        stopDeleteRepeat()
        waveform.update(measuredLevel: 0, recording: false); waveformIsRecording = false
        KeyboardBridgeDiagnostics.record(isOpeningHost ? "keyboard_handoff_return" : "keyboard_hidden", sessionID: sessionID, requestID: request?.id, phase: request?.phase)
        if !isOpeningHost { cancelBeforeProcessing() }
        if let presenceSessionID { try? store?.clearPresence(instanceID: presenceInstanceID, sessionID: presenceSessionID) }
        self.presenceSessionID = nil
        timer?.invalidate(); timer = nil
        snapshot = nil; store = nil
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refresh()
    }

    @objc private func refresh() {
        defer {
            if recordingRow.isHidden { statusLabel.isHidden = statusLabel.text == nil }
            previewLabel.isHidden = previewLabel.text == nil || !recordingRow.isHidden
            let phase = snapshot?.request?.phase
            if phase != displayedPhase {
                if !UIAccessibility.isReduceMotionEnabled {
                    let fade = CATransition(); fade.type = .fade; fade.duration = 0.12
                    view.layer.add(fade, forKey: "dictationAppearance")
                }
                displayedPhase = phase
            }
        }
        if openingHostDeadline.map({ Date() >= $0 }) == true { openingHost = false; openingHostDeadline = nil }
        if hasFullAccess, store == nil { store = KeyboardBridgeStore() }
        snapshot = try? store?.read()
        if visible, !isOpeningHost, let state = snapshot {
            try? store?.setPresence(instanceID: presenceInstanceID, sessionID: state.sessionID, claim: presenceSessionID != state.sessionID || state.keyboardPresence == nil)
            presenceSessionID = state.sessionID
            if let pending = state.request, pending.warmAudioEpoch != nil, pending.phase == .queued {
                let handoff = KeyboardHandoff(sessionID: state.sessionID, request: pending)
                if (try? store?.expireWarmStart(handoff)) == true {
                    actionError = L("Tap to speak again.", "Tippe erneut auf Diktieren.")
                    snapshot = try? store?.read()
                }
            }
        }
        refreshFavoriteButtons()
        primary.isHidden = false; openLink?.view.isHidden = true
        // Recover the same request after the intentional app handoff, including
        // extension recreation. Never adopt a draft for another document.
        if request == nil, let state = snapshot, Date() < state.expiresAt,
           let pending = state.request, !pending.consumed, (pending.command != .cancel || state.hasPendingCancellation(at: .now)) {
            request = pending; sessionID = state.sessionID
        }
        globe.isHidden = !needsInputModeSwitchKey
        recordingGlobe.isHidden = !needsInputModeSwitchKey
        updateCopyAppearance()
        cancelButton.setTitle(L("Cancel", "Abbrechen"), for: .normal)
        meter.progress = 0
        previewLabel.text = nil
        previewLabel.isHidden = true
        cancelButton.isHidden = request == nil
        if !hasFullAccess {
            setRecordingAppearance(false)
            statusLabel.text = L("Allow Full Access in iPhone keyboard settings to connect Klangschrift.", "Erlaube in den iPhone-Tastatureinstellungen den vollen Zugriff, um die lokale App zu verbinden.")
            primary.setTitle(L("Set up keyboard", "Tastatur einrichten"), for: .normal); primary.isEnabled = false
            return
        }
        guard let state = snapshot, state.usable(at: .now) else {
            setRecordingAppearance(false)
            request = nil; sessionID = nil
            statusLabel.text = actionError
            showOpenLink()
            cancelButton.isHidden = true
            return
        }
        if let current = request {
            guard sessionID == state.sessionID, let live = state.request,
                  live.id == current.id, live.nonce == current.nonce else {
                request = nil; sessionID = nil; refresh(); return
            }
            request = live
            if live.command == .cancel, state.hasPendingCancellation(at: .now) {
                setRecordingAppearance(false)
                statusLabel.text = L("Cancelling dictation …", "Diktat wird abgebrochen …")
                primary.setTitle(L("Cancelling …", "Abbrechen …"), for: .normal); primary.isEnabled = false
                openLink?.view.isHidden = true; cancelButton.isHidden = true
                return
            }
            if live.command == .cancel {
                request = nil; sessionID = nil
                setRecordingAppearance(false); showOpenLink(); cancelButton.isHidden = true
                statusLabel.text = actionError
                return
            }
            let documentMatches = live.documentID == textDocumentProxy.documentIdentifier
            let needsMismatchTrace = lastMismatchTrace?.sessionID != state.sessionID
                || lastMismatchTrace?.requestID != live.id
                || lastMismatchTrace?.phase != live.phase
                || lastMismatchTrace?.documentMatches != documentMatches
            if !documentMatches, needsMismatchTrace {
                KeyboardBridgeDiagnostics.record("keyboard_document_mismatch", sessionID: state.sessionID, requestID: live.id, documentMatches: false, phase: live.phase, fullAccess: hasFullAccess, storeAvailable: store != nil)
                lastMismatchTrace = (sessionID: state.sessionID, requestID: live.id, phase: live.phase, documentMatches: documentMatches)
            }
            switch live.phase {
            case .queued:
                setRecordingAppearance(false)
                if documentMatches {
                    statusLabel.text = L("Opening Klangschrift …", "Klangschrift wird geöffnet …")
                    showOpenLink()
                } else {
                    statusLabel.text = L("Cancel the previous dictation to start here.", "Ein vorheriger Diktatstart wartet. Brich ihn ab, um hier neu zu starten.")
                    primary.setTitle(L("Waiting to start", "Start wartet"), for: .normal)
                    primary.isEnabled = false
                    openLink?.view.isHidden = true
                }
            case .recording:
                statusLabel.text = documentMatches ? "\(L("Recording", "Aufnahme läuft"))  \(live.seconds / 60):\(String(format: "%02d", live.seconds % 60))" : L("Tap the checkmark to stop and insert here", "Häkchen: stoppen und hier einfügen")
                meter.progress = Float(live.level)
                recordingElapsedLabel.text = "\(live.seconds / 60):\(String(format: "%02d", live.seconds % 60))"
                setRecordingAppearance(true)
                waveform.update(measuredLevel: live.level, sequence: live.levelSampleSequence, requestID: live.id, recording: true)
                let remaining = Int(KeyboardBridgeState.maximumRecordingSeconds) - live.seconds
                let endingSoon = remaining > 0 && remaining <= 30
                setRecordingHint(endingSoon ? L("30 seconds left", "Noch 30 Sekunden") : (documentMatches ? nil : L("Tap the checkmark to stop and insert here", "Häkchen: stoppen und hier einfügen")))
                recordingHint.textColor = endingSoon ? KlangPalette.accent : KlangPalette.secondary
                recordStop.accessibilityLabel = documentMatches ? L("Stop recording", "Aufnahme stoppen") : L("Stop recording and insert here", "Aufnahme stoppen und hier einfügen")
                primary.isEnabled = true
            case .transcribing:
                setRecordingAppearance(false)
                statusLabel.text = live.error == nil ? L("Creating text …", "Text wird erstellt …") : L("Open the app to continue.", "Zum Fortsetzen App öffnen.")
                primary.setTitle(L("Processing …", "Verarbeiten …"), for: .normal); primary.isEnabled = false
                let heartbeatAge = Date().timeIntervalSince(state.heartbeat)
                let needsHost = live.error != nil || heartbeatAge >= KeyboardBridgeState.heartbeatTimeout || heartbeatAge < -KeyboardBridgeState.heartbeatTimeout
                setProcessingAppearance(showResume: needsHost)
                if let started = live.processingStartedAt, live.error == nil {
                    let elapsed = max(0, Int(Date().timeIntervalSince(started)))
                    processingLabel.text = "\(L("Creating text", "Text wird erstellt")) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
                } else {
                    processingLabel.text = L("Creating text …", "Text wird erstellt …")
                }
                if needsHost { showOpenLink(title: L("Open app", "App öffnen")) }
            case .ready:
                setRecordingAppearance(false)
                previewLabel.text = live.text
                previewLabel.isHidden = false
                statusLabel.text = documentMatches ? L("Inserting text …", "Text wird eingefügt …") : L("Text ready for this field", "Text für dieses Feld bereit")
                primary.setTitle(documentMatches ? L("Insert", "Einfügen") : L("Insert here", "Hier einfügen"), for: .normal); primary.isEnabled = !live.consumed
                if live.consumed { request = nil; sessionID = nil; refresh() }
                else if visible, documentMatches {
                    do { if try insertDraft(live, sessionID: state.sessionID) { refresh(); return } }
                    catch { actionError = L("Please try again.", "Bitte erneut versuchen.") }
                }
            case .failed:
                setRecordingAppearance(false)
                statusLabel.text = L("Could not create the text. Please try again.", "Der Text konnte nicht erstellt werden. Bitte erneut versuchen.")
                showOpenLink(title: L("Dictate again", "Erneut diktieren"))
            }
        } else {
            setRecordingAppearance(false)
            statusLabel.text = actionError ?? L("Ready to dictate", "Bereit für ein Diktat")
            showOpenLink()
            cancelButton.isHidden = true
        }
        if let actionError { statusLabel.text = actionError }
    }

    @objc private func primaryAction() {
        actionError = nil
        guard let store else { return }
        do {
            if let current = request, let sessionID {
                if current.phase == .recording {
                    let matches = current.documentID == textDocumentProxy.documentIdentifier
                    if matches {
                        if try store.command(.stop, sessionID: sessionID, requestID: current.id, nonce: current.nonce, documentID: current.documentID) { playAcceptedClick() }
                    } else if try store.stopAndBindCurrentDocument(sessionID: sessionID, requestID: current.id, nonce: current.nonce, currentDocumentID: textDocumentProxy.documentIdentifier) {
                        playAcceptedClick()
                    } else {
                        actionError = L("Could not use this text field.", "Die Aufnahme konnte nicht diesem Feld zugeordnet werden.")
                    }
                } else if current.phase == .ready {
                    if current.documentID == textDocumentProxy.documentIdentifier {
                        if try insertDraft(current, sessionID: sessionID) { playAcceptedClick() }
                    } else {
                        let destinationDocumentID = textDocumentProxy.documentIdentifier
                        if let text = try store.bindCurrentDocumentAndConsume(sessionID: sessionID, requestID: current.id, nonce: current.nonce, currentDocumentID: destinationDocumentID) {
                            guard textDocumentProxy.documentIdentifier == destinationDocumentID else {
                                actionError = L("The text field changed.", "Das Zielfeld hat sich geändert.")
                                refresh()
                                return
                            }
                            textDocumentProxy.insertText(KeyboardTextSpacing.insertion(text, after: textDocumentProxy.documentContextBeforeInput))
                            playAcceptedClick()
                            rememberSuccessfullyInsertedDictation(text)
                            actionError = current.error
                            KeyboardBridgeDiagnostics.record("keyboard_explicit_rebind_consume", sessionID: sessionID, requestID: current.id, documentMatches: false, phase: .ready, fullAccess: hasFullAccess, storeAvailable: true)
                            request = nil; self.sessionID = nil
                        }
                    }
                } else if current.phase == .failed {
                    request = nil; self.sessionID = nil
                    showOpenLink(title: L("Dictate again", "Erneut diktieren"))
                }
            } else { showOpenLink() }
        } catch { actionError = L("Please try again.", "Bitte erneut versuchen.") }
        refresh()
    }

    private func showOpenLink(title: String = L("Tap to speak", "Diktieren")) {
        primary.isHidden = true
        openLink?.view.isHidden = false
        if let link = openLink {
            link.rootView = KeyboardOpenLink(title: title, action: link.rootView.action)
        }
    }

    private func configurePolling(recording: Bool) {
        guard visible, timer == nil || pollingRecording != recording else { return }
        pollingRecording = recording
        timer?.invalidate()
        let timer = Timer(timeInterval: recording ? 0.1 : 0.3, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func playAcceptedClick() {
        guard visible else { return }
        UIDevice.current.playInputClick()
    }

    private func setRecordingAppearance(_ recording: Bool) {
        configurePolling(recording: recording)
        recordingRow.isHidden = !recording
        recordingTools.isHidden = !recording || !needsInputModeSwitchKey
        recordingCenter.setProcessing(!recording && snapshot?.request?.phase == .transcribing)
        setRecordingHint(nil)
        actionRow.isHidden = recording
        titleLabel.isHidden = recording
        statusLabel.isHidden = recording
        meter.isHidden = recording
        previewLabel.isHidden = recording
        typingControls.isHidden = recording
        if recording {
            stopDeleteRepeat()
            waveformIsRecording = true
            recordCancel.isHidden = false
            waveform.isHidden = false
            recordStop.isHidden = false
            processingLabel.isHidden = true
        } else {
            recordingElapsedLabel.text = nil
            if waveformIsRecording { waveform.update(measuredLevel: 0, recording: false); waveformIsRecording = false }
            primary.configuration?.image = nil
            primary.configuration?.imagePadding = 0
        }
    }

    private func setRecordingHint(_ text: String?) {
        recordingHint.text = text
        recordingHint.isHidden = text == nil
    }

    private func handoffForLink(from store: KeyboardBridgeStore, modelID: String?, favoritesRevision: UUID?) throws -> KeyboardHandoff {
        if let known = request, known.phase == .transcribing, let knownSessionID = sessionID,
           let current = try store.read(), current.usable(at: .now), current.sessionID == knownSessionID,
           let live = current.request, live.id == known.id, live.nonce == known.nonce,
           live.phase == .transcribing, live.command != .cancel, !live.consumed {
            return KeyboardHandoff(sessionID: knownSessionID, request: live)
        }
        return try store.prepareHandoff(documentID: textDocumentProxy.documentIdentifier, modelID: modelID, favoritesRevision: favoritesRevision)
    }

    private func setProcessingAppearance(showResume: Bool) {
        titleLabel.isHidden = true
        statusLabel.isHidden = !showResume || request?.error == nil
        meter.isHidden = true
        previewLabel.isHidden = true
        actionRow.isHidden = false
        primary.isHidden = true
        openLink?.view.isHidden = !showResume
        typingControls.isHidden = true
        recordCancel.isHidden = true
        waveform.isHidden = true
        recordStop.isHidden = true
        recordingCenter.setProcessing(true)
        recordingTools.isHidden = !needsInputModeSwitchKey
        recordingRow.isHidden = false
    }

    private func insertDraft(_ current: KeyboardBridgeRequest, sessionID: UUID) throws -> Bool {
        guard visible, let store,
              textDocumentProxy.documentIdentifier == current.documentID else { return false }
        if let text = try store.consume(sessionID: sessionID, requestID: current.id, nonce: current.nonce, documentID: current.documentID),
           textDocumentProxy.documentIdentifier == current.documentID {
            textDocumentProxy.insertText(KeyboardTextSpacing.insertion(text, after: textDocumentProxy.documentContextBeforeInput)) // Draft only. Never press Send/Return.
            rememberSuccessfullyInsertedDictation(text)
            actionError = current.error
            KeyboardBridgeDiagnostics.record("keyboard_consume_success", sessionID: sessionID, requestID: current.id, documentMatches: true, phase: .ready)
            request = nil; self.sessionID = nil
            return true
        }
        return false
    }

    private func cancelOutstanding() -> Bool {
        let accepted: Bool
        if let request, let sessionID {
            accepted = (try? store?.command(.cancel, sessionID: sessionID, requestID: request.id, nonce: request.nonce, documentID: request.documentID)) ?? false
        } else { accepted = false }
        request = nil; sessionID = nil
        return accepted
    }

    private func cancelBeforeProcessing() {
        guard let request, let sessionID else { return }
        try? store?.cancelBeforeProcessing(sessionID: sessionID, requestID: request.id, nonce: request.nonce, documentID: request.documentID, presenceInstanceID: presenceInstanceID)
        self.request = nil; self.sessionID = nil
    }

    @objc private func cancelAction() { if cancelOutstanding() { playAcceptedClick() }; actionError = nil; refresh() }
    private func styleMiniKey(_ button: UIButton) {
        button.backgroundColor = KlangPalette.surface
        button.tintColor = KlangPalette.ink
        button.layer.cornerRadius = 6
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func miniKey(_ title: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = label
        styleMiniKey(button)
        return button
    }

    @objc private func insertMiniKey(_ sender: UIButton) {
        guard !typingControls.isHidden else { return }
        let text: String
        switch sender.accessibilityIdentifier {
        case "mini-space": text = " "
        case "mini-return": text = "\n"
        default: text = sender.title(for: .normal) ?? ""
        }
        textDocumentProxy.insertText(text)
        playAcceptedClick()
    }

    @objc private func nextKeyboard() { stopDeleteRepeat(); cancelBeforeProcessing(); advanceToNextInputMode() }
    @objc private func copyLastDictation() {
        guard let lastSuccessfullyInsertedDictation else { return }
        UIPasteboard.general.string = lastSuccessfullyInsertedDictation
        playAcceptedClick()
    }
    @objc private func deleteTouchDown() {
        let hadText = textDocumentProxy.hasText
        textDocumentProxy.deleteBackward()
        if hadText { playAcceptedClick() }
        stopDeleteRepeat()
        let delay = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in self?.beginDeleteRepeat() }
        deleteRepeatDelayTimer = delay
        RunLoop.main.add(delay, forMode: .common)
    }

    private func beginDeleteRepeat() {
        guard deleteButton.isHighlighted, !typingControls.isHidden else { return }
        let repeatTimer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self, self.deleteButton.isHighlighted, !self.typingControls.isHidden else { self?.stopDeleteRepeat(); return }
            let hadText = self.textDocumentProxy.hasText
            self.textDocumentProxy.deleteBackward()
            if hadText { self.playAcceptedClick() }
        }
        deleteRepeatTimer = repeatTimer
        RunLoop.main.add(repeatTimer, forMode: .common)
    }

    @objc private func stopDeleteRepeat() {
        deleteRepeatDelayTimer?.invalidate(); deleteRepeatDelayTimer = nil
        deleteRepeatTimer?.invalidate(); deleteRepeatTimer = nil
    }

    private func rememberSuccessfullyInsertedDictation(_ text: String) {
        lastSuccessfullyInsertedDictation = text
        copyButton.isEnabled = true
        updateCopyAppearance()
    }

    private var isOpeningHost: Bool { openingHost && (openingHostDeadline.map { Date() < $0 } ?? false) }

    deinit { MainActor.assumeIsolated { stopDeleteRepeat() } }

}

@MainActor
private struct KeyboardOpenLink: View {
    let title: String
    let action: (URL) -> OpenURLAction.Result
    init(title: String = L("Tap to speak", "Diktieren"), action: @escaping (URL) -> OpenURLAction.Result) {
        self.title = title; self.action = action
    }
    private var displayTitle: String { title }
    var body: some View {
        Link(destination: URL(string: "klangschrift://dictate")!) {
            Group {
                if title == L("Tap to speak", "Diktieren") { Label(displayTitle, systemImage: "mic.fill").font(.headline) }
                else { Text(displayTitle).font(.subheadline.weight(.semibold)) }
            }
            .dynamicTypeSize(.xSmall ... (title == L("Tap to speak", "Diktieren") ? .accessibility1 : .xxxLarge))
            .lineLimit(1).minimumScaleFactor(0.9)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .foregroundStyle(Color(uiColor: title == L("Tap to speak", "Diktieren") ? KlangPalette.onAction : KlangPalette.accent))
        .background(title == L("Tap to speak", "Diktieren") ? Color(uiColor: KlangPalette.action) : .clear, in: Capsule())
        .buttonStyle(.plain)
        .tint(Color(uiColor: KlangPalette.action))
        .accessibilityLabel(title)
        .environment(\.openURL, OpenURLAction(handler: action))
    }
}

/// Input clicks are enabled on the actual input view, subject to system preferences.
private final class KeyboardFeedbackInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// 21 measured history bars; the 30-fps render only interpolates existing samples.
private final class KeyboardWaveformView: UIView {
    private var history = MeasuredWaveformHistory()
    private var targetSamples = Array(repeating: 0.0, count: MeasuredWaveformHistory.capacity)
    private var displayedSamples = Array(repeating: 0.0, count: MeasuredWaveformHistory.capacity)
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { super.init(coder: coder); isOpaque = false; backgroundColor = .clear }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(rect)
        let count = MeasuredWaveformHistory.capacity
        let gap: CGFloat = 2.5
        let width = max(2, (rect.width - CGFloat(count - 1) * gap) / CGFloat(count))
        for index in 0..<count {
            let level = displayedSamples[index]
            let centerDistance = abs(CGFloat(index) - CGFloat(count - 1) / 2) / (CGFloat(count) / 2)
            let envelope = 0.6 + 0.4 * (1 - centerDistance)
            let height = 3 + level * Double(34 * envelope)
            let bar = CGRect(x: CGFloat(index) * (width + gap), y: (rect.height - height) / 2, width: width, height: height)
            context.setFillColor(KlangPalette.accent.withAlphaComponent(level > 0.02 ? 1 : 0.28).resolvedColor(with: traitCollection).cgColor)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: width / 2).cgPath)
            context.fillPath()
        }
    }

    func update(measuredLevel: Double, sequence: Int64? = nil, requestID: UUID? = nil, recording: Bool) {
        guard recording else {
            stopDisplayLink(); history.reset()
            targetSamples = history.samples; displayedSamples = history.samples
            setNeedsDisplay(); return
        }
        let fresh = history.record(meterLevel: measuredLevel, sequence: sequence, requestID: requestID, recording: true)
        if UIAccessibility.isReduceMotionEnabled || sequence == nil {
            stopDisplayLink()
            let measured = MeasuredWaveformHistory.displayLevel(measuredLevel)
            targetSamples = Array(repeating: measured, count: targetSamples.count)
            displayedSamples = targetSamples
            setNeedsDisplay(); return
        }
        guard fresh else { return }
        targetSamples = history.samples
        startDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let target = WaveformDisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(WaveformDisplayLinkTarget.tick(_:)))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func displayTick() {
        guard !UIAccessibility.isReduceMotionEnabled, !isHidden else { stopDisplayLink(); return }
        var changed = false
        for index in displayedSamples.indices {
            let delta = targetSamples[index] - displayedSamples[index]
            let next = abs(delta) < 0.001 ? targetSamples[index] : displayedSamples[index] + delta * 0.35
            if next != displayedSamples[index] { changed = true }
            displayedSamples[index] = next
        }
        if changed { setNeedsDisplay() }
    }

    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }
    deinit { stopDisplayLink() }
}

private final class WaveformDisplayLinkTarget: NSObject {
    weak var owner: KeyboardWaveformView?
    init(owner: KeyboardWaveformView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.displayTick() }
}
