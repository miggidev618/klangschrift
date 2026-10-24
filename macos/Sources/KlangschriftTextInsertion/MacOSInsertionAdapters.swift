import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Validates dynamically returned AX attributes before bridging them to Swift reference types.
public enum AXRuntimeTypeValidator {
    public static func isAXUIElement(_ value: CFTypeRef?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }
    public static func isAXValue(_ value: CFTypeRef?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value) == AXValueGetTypeID()
    }
}

private func validatedAXUIElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard AXRuntimeTypeValidator.isAXUIElement(value), let value else { return nil }
    // CF type ID was checked above; CoreFoundation cannot express this guarded conversion as `as?`.
    return unsafeDowncast(value, to: AXUIElement.self)
}

private func validatedAXValue(_ value: CFTypeRef?) -> AXValue? {
    guard AXRuntimeTypeValidator.isAXValue(value), let value else { return nil }
    return unsafeDowncast(value, to: AXValue.self)
}

/// Private registry prevents a public identity token from being used as an AX pointer or a lookup key outside this process.
final class AXElementRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [UInt64: AXUIElement] = [:]
    func retain(_ element: AXUIElement) -> AXElementIdentity {
        lock.lock(); defer { lock.unlock() }
        var token = UInt64.random(in: UInt64.min...UInt64.max)
        while elements[token] != nil { token = UInt64.random(in: UInt64.min...UInt64.max) }
        elements[token] = element
        if elements.count > 64, let old = elements.keys.first { elements.removeValue(forKey: old) }
        return AXElementIdentity(opaqueToken: token)
    }
    func element(_ identity: AXElementIdentity) -> AXUIElement? { lock.lock(); defer { lock.unlock() }; return elements[identity.opaqueToken] }
}

public final class MacOSFocusTargeting: @unchecked Sendable, FocusTargeting {
    private let registry: AXElementRegistry
    public init() { self.registry = AXElementRegistry() }
    public func captureFocus() -> FocusLease? {
        guard AXIsProcessTrusted() else { InsertionLog.record(.focusFailure(.capture, .axNotTrusted)); return nil }
        guard let current = readFocusedElement(stage: .capture) else { return nil }
        guard let pid = processID(of: current.application) else { InsertionLog.record(.focusFailure(.capture, .noPID)); return nil }
        guard let bundle = canonicalBundle(for: pid) else { InsertionLog.record(.focusFailure(.capture, .noBundle)); return nil }
        let identity = registry.retain(current.element)
        return FocusLease(processID: pid, bundleIdentifier: bundle, element: identity, issuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
    public func revalidate(_ lease: FocusLease) -> CurrentFocus? {
        guard AXIsProcessTrusted() else { InsertionLog.record(.focusFailure(.revalidate, .axNotTrusted)); return nil }
        guard let stored = registry.element(lease.element) else { InsertionLog.record(.focusFailure(.revalidate, .missingElement)); return nil }
        guard let current = readFocusedElement(stage: .revalidate) else { return nil }
        guard CFEqual(stored, current.element) else { InsertionLog.record(.focusFailure(.revalidate, .elementMismatch)); return nil }
        guard let pid = processID(of: current.application) else { InsertionLog.record(.focusFailure(.revalidate, .noPID)); return nil }
        guard pid == lease.processID else { InsertionLog.record(.focusFailure(.revalidate, .pidMismatch)); return nil }
        guard let bundle = canonicalBundle(for: pid) else { InsertionLog.record(.focusFailure(.revalidate, .noBundle)); return nil }
        guard bundle == lease.bundleIdentifier else { InsertionLog.record(.focusFailure(.revalidate, .bundleMismatch)); return nil }
        return CurrentFocus(processID: pid, bundleIdentifier: bundle, element: lease.element, classification: classify(current.element))
    }
    public func issueInsertionLease(for current: CurrentFocus, nowNanoseconds: UInt64) -> FocusLease? {
        guard AXIsProcessTrusted() else { InsertionLog.record(.focusFailure(.issueLease, .axNotTrusted)); return nil }
        guard let element = registry.element(current.element) else { InsertionLog.record(.focusFailure(.issueLease, .missingElement)); return nil }
        guard let focused = readFocusedElement(stage: .issueLease) else { return nil }
        guard CFEqual(element, focused.element) else { InsertionLog.record(.focusFailure(.issueLease, .elementMismatch)); return nil }
        guard processID(of: focused.application) == current.processID else { InsertionLog.record(.focusFailure(.issueLease, .pidMismatch)); return nil }
        guard canonicalBundle(for: current.processID) == current.bundleIdentifier else { InsertionLog.record(.focusFailure(.issueLease, .bundleMismatch)); return nil }
        return FocusLease(processID: current.processID, bundleIdentifier: current.bundleIdentifier, element: current.element, issuedAtNanoseconds: nowNanoseconds)
    }
    fileprivate func validatesCurrentField(_ current: CurrentFocus) -> Bool {
        guard AXIsProcessTrusted() else { InsertionLog.record(.focusFailure(.fieldValidation, .axNotTrusted)); return false }
        guard let stored = registry.element(current.element) else { InsertionLog.record(.focusFailure(.fieldValidation, .missingElement)); return false }
        guard let focused = readFocusedElement() else { return false }
        guard CFEqual(stored, focused.element) else { InsertionLog.record(.focusFailure(.fieldValidation, .elementMismatch)); return false }
        guard let pid = processID(of: focused.application) else { InsertionLog.record(.focusFailure(.fieldValidation, .noPID)); return false }
        guard pid == current.processID else { InsertionLog.record(.focusFailure(.fieldValidation, .pidMismatch)); return false }
        guard canonicalBundle(for: pid) == current.bundleIdentifier else { InsertionLog.record(.focusFailure(.fieldValidation, .bundleMismatch)); return false }
        let editable = classify(focused.element) == .editable
        InsertionLog.record(.flag(.fieldEditable, editable))
        return editable
    }
    fileprivate func element(for current: CurrentFocus) -> AXUIElement? { registry.element(current.element) }
    private func readFocusedElement(stage: InsertionLog.Stage = .fieldValidation) -> (application: AXUIElement, element: AXUIElement)? {
        let port = FocusReadPort(budget: FocusReadBudget())
        var manualAttempts = Set<Int32>()
        return FocusedElementReader.read(ownPID: ProcessInfo.processInfo.processIdentifier, withinBudget: { port.budget.isActive }, system: {
            let system = AXUIElementCreateSystemWide()
            guard let (status, appValue) = port.read(system, kAXFocusedApplicationAttribute as CFString), status == .success,
                  let application = validatedAXUIElement(appValue) else { InsertionLog.record(.focusFailure(stage, .noFocusedApp)); return nil }
            guard let pid = port.pid(application) else { InsertionLog.record(.focusFailure(stage, .noPID)); return nil }
            return (pid, {
                guard let element = self.focusedElement(in: application, port: port, manualAttempts: &manualAttempts) else { InsertionLog.record(.focusFailure(stage, .noFocusedElement)); return nil }
                return (application: application, element: element)
            })
        }, frontmostPID: {
            guard port.budget.isActive else { return nil }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }, application: { pid in
            let application = AXUIElementCreateApplication(pid)
            guard let element = self.focusedElement(in: application, port: port, manualAttempts: &manualAttempts) else { InsertionLog.record(.focusFailure(stage, .noFocusedElement)); return nil }
            return (application: application, element: element)
        })
    }
    private func focusedElement(in application: AXUIElement, port: FocusReadPort, manualAttempts: inout Set<Int32>) -> AXUIElement? {
        guard let pid = port.pid(application), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return ApplicationFocusedElementReader.read(withinBudget: { port.budget.isActive }, focused: {
            guard let (status, value) = port.read(application, kAXFocusedUIElementAttribute as CFString) else { return .unavailable }
            if status == .noValue || (status == .success && value == nil) { return .missing }
            guard status == .success, let element = validatedAXUIElement(value) else { return .unavailable }
            return .focused(element)
        }, enableManualAccessibility: {
            let attribute = "AXManualAccessibility" as CFString
            guard !manualAttempts.contains(pid),
                  let (status, value) = port.read(application, attribute), status == .success, value as? Bool == false,
                  port.isSettable(application, attribute) == true else { return false }
            manualAttempts.insert(pid)
            return port.call(application) { AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue) } == .success
        }, focusedWindow: {
            self.searchFocusedWindow(in: application, pid: pid, port: port)
        })
    }

    private struct SearchNode: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    private struct FocusReadPort {
        let budget: FocusReadBudget
        func call<T>(_ element: AXUIElement, _ body: () -> T) -> T? {
            guard let timeout = budget.remainingAXTimeout else { return nil }
            guard AXUIElementSetMessagingTimeout(element, timeout) == .success, budget.isActive else { return nil }
            let result = body()
            return budget.isActive ? result : nil
        }
        func read(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?)? {
            call(element) {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, attribute, &value)
                return (status, value)
            }
        }
        func isSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
            var value = DarwinBoolean(false)
            let status = call(element, { AXUIElementIsAttributeSettable(element, attribute, &value) })
            return MacOSFocusTargeting.settableCapability(status: status, settable: value.boolValue)
        }
        func pid(_ element: AXUIElement) -> Int32? {
            var pid: pid_t = 0
            guard let status = call(element, { AXUIElementGetPid(element, &pid) }), status == .success, pid > 0 else { return nil }
            return pid
        }
    }
    private func searchFocusedWindow(in application: AXUIElement, pid: Int32, port: FocusReadPort) -> AXUIElement? {
        guard let (status, value) = port.read(application, kAXFocusedWindowAttribute as CFString), status == .success,
              let window = validatedAXUIElement(value) else { return nil }
        let found = FocusedWindowSearch.find(root: SearchNode(element: window), withinBudget: {
            port.budget.isActive
        }, confirm: { node in
            FocusedWindowConfirmation.confirms(expectedPID: pid, currentPID: {
                guard port.budget.isActive, port.pid(application) == pid, port.pid(node.element) == pid else { return nil }
                return NSWorkspace.shared.frontmostApplication?.processIdentifier
            }, sameWindow: {
                guard let (status, value) = port.read(application, kAXFocusedWindowAttribute as CFString), status == .success,
                      let currentWindow = validatedAXUIElement(value) else { return false }
                return CFEqual(window, currentWindow)
            }, stillFocused: {
                guard let (status, value) = port.read(node.element, kAXFocusedAttribute as CFString) else { return false }
                return status == .success && value as? Bool == true
            }, withinBudget: { port.budget.isActive })
        }, inspect: { node in
            guard port.pid(node.element) == pid,
                  let (focusStatus, focusValue) = port.read(node.element, kAXFocusedAttribute as CFString) else { return nil }
            let focused: Bool
            switch focusStatus {
            case .success: guard let flag = focusValue as? Bool else { return nil }; focused = flag
            case .noValue, .attributeUnsupported: focused = false
            default: return nil
            }
            var matches = false
            if focused {
                guard let (roleStatus, roleValue) = port.read(node.element, kAXRoleAttribute as CFString), roleStatus == .success,
                      let role = roleValue as? String else { return nil }
                // WebArea is a text candidate only with explicit write capability.
                var writable = false
                if role == "AXWebArea" {
                    guard let capability = Self.searchWriteCapability(value: {
                        port.isSettable(node.element, kAXValueAttribute as CFString)
                    }, selectedText: {
                        port.isSettable(node.element, kAXSelectedTextAttribute as CFString)
                    }, withinBudget: { port.budget.isActive }) else { return nil }
                    writable = capability
                }
                matches = Self.isFocusedSearchCandidate(role: role, focused: true, writable: writable)
            }
            guard let (childStatus, childValue) = port.read(node.element, kAXChildrenAttribute as CFString) else { return nil }
            if childStatus == .noValue || childStatus == .attributeUnsupported { return (matches, []) }
            guard childStatus == .success, let values = childValue as? [CFTypeRef], values.count <= 2_000 else { return nil }
            var children: [SearchNode] = []
            for value in values {
                guard let element = validatedAXUIElement(value) else { return nil }
                children.append(SearchNode(element: element))
            }
            return (matches, children)
        })
        return found?.element
    }
    static func settableCapability(status: AXError?, settable: Bool) -> Bool? {
        switch status {
        case .success: return settable
        case .attributeUnsupported, .noValue: return false
        default: return nil
        }
    }
    static func searchWriteCapability(value: () -> Bool?, selectedText: () -> Bool?, withinBudget: () -> Bool) -> Bool? {
        guard withinBudget(), let valueWritable = value(), withinBudget() else { return nil }
        if valueWritable { return true }
        guard let selectedWritable = selectedText(), withinBudget() else { return nil }
        return selectedWritable
    }
    static func isFocusedSearchCandidate(role: String, focused: Bool, writable: Bool) -> Bool {
        focused && (role == kAXTextAreaRole as String || role == kAXTextFieldRole as String || (role == "AXWebArea" && writable))
    }

    private func processID(of application: AXUIElement) -> Int32? { var pid: pid_t = 0; return AXUIElementGetPid(application, &pid) == .success && pid > 0 ? pid : nil }
    private func canonicalBundle(for pid: Int32) -> String? {
        guard let identifier = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines), identifier.contains("."), !identifier.contains(where: { $0.isWhitespace }) else { return nil }
        return identifier
    }
    private func classify(_ element: AXUIElement) -> EditableTargetClassification {
        // Host identity binds a lease, but must not decide whether a focused
        // field is writable. Capability comes only from the focused AX node.
        if IsSecureEventInputEnabled() { return .secure }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return .secure }
        var role: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let name = role as? String else { InsertionLog.record(.role(.unavailable)); return .notEditable }
        InsertionLog.record(.role(MacOSAXMutation.diagnosticRole(name)))
        var valueSettable = DarwinBoolean(false); var selectedTextSettable = DarwinBoolean(false); var enabled: CFTypeRef?
        let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        let selectedTextStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        let enabledStatus = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        return Self.productionClassification(role: name, valueWritable: valueStatus == .success && valueSettable.boolValue, selectedTextWritable: selectedTextStatus == .success && selectedTextSettable.boolValue, enabled: enabled as? Bool, enabledStatus: enabledStatus)
    }
    /// Pure mirror of the focused-field capability decision used by production.
    public static func productionClassification(role: String?, valueWritable: Bool, selectedTextWritable: Bool, secure: Bool = false, enabled: Bool? = true, enabledStatus: AXError = .success) -> EditableTargetClassification {
        guard !secure else { return .secure }
        switch enabledStatus {
        case .attributeUnsupported, .noValue:
            // Absence of AXEnabled does not assert that the field is disabled.
            break
        case .success:
            guard let enabled else { return .unknown }
            guard enabled else { return .notEditable }
        default:
            return .unknown
        }
        guard let kind = MacOSAXMutation.textTargetKind(forAXRole: role) else { return .notEditable }
        _ = kind
        return valueWritable || selectedTextWritable ? .editable : .notEditable
    }
}

public final class MacOSAXMutation: @unchecked Sendable, AXMutation, BoundedPasteWitnessing {
    private let focus: MacOSFocusTargeting
    public init(focus: MacOSFocusTargeting) { self.focus = focus }
    /// AXValue replacement is reserved for native plain text fields. Text
    /// areas and content-editable web areas retain their formatting and use
    /// the bounded, selection-witnessed paste route instead.
    public static func textTargetKind(forAXRole role: String?) -> AXTargetKind? {
        if role == (kAXTextFieldRole as String) { return .simpleText }
        if role == (kAXTextAreaRole as String) || role == "AXWebArea" { return .richText }
        return nil
    }
    public static func diagnosticRole(_ role: String?) -> InsertionLog.Role {
        guard let role else { return .unavailable }
        if role == (kAXTextFieldRole as String) { return .textField }
        if role == (kAXTextAreaRole as String) { return .textArea }
        if role == "AXWebArea" { return .webArea }
        return .other
    }
    /// Pure final-commit guard shared by the AX adapter and cold regressions.
    public static func allowsSelectedTextCommit(actualSelection: TextSelection, expectedSelection: TextSelection, evidence: AXSelectionEvidence, selectedTextWritable: Bool, fieldStillCurrent: Bool) -> Bool {
        selectedTextWritable && fieldStillCurrent && actualSelection == expectedSelection && AXSelectionValidator.validate(primary: expectedSelection, evidence: evidence)
    }
    public static func allowsFullValueCommit(actualValue: String?, expectedValue: String, actualSelection: TextSelection, expectedSelection: TextSelection, evidence: AXSelectionEvidence, valueWritable: Bool, fieldStillCurrent: Bool) -> Bool {
        valueWritable && fieldStillCurrent && actualValue == expectedValue && actualSelection == expectedSelection && AXSelectionValidator.validate(primary: expectedSelection, evidence: evidence)
    }
    /// Only an empty selection can interpret AX's explicit noValue as empty text.
    static func selectedText(status: AXError, value: String?, selection: TextSelection) -> String? {
        guard selection.location >= 0, selection.length >= 0 else { return nil }
        if status == .noValue, selection.length == 0 { return "" }
        guard status == .success, let value, value.utf16.count == selection.length else { return nil }
        return value
    }
    static func selectedRangesEvidence(status: AXError, materialize: () -> [TextSelection]?) -> AXSelectionEvidence {
        guard status == .success else { return .unavailable }
        guard let ranges = materialize() else { return .malformed }
        return .ranges(ranges)
    }
    public func readTextTarget(_ current: CurrentFocus) -> AXTextTarget? {
        guard current.classification == .editable else { return .init(kind: .terminal, value: nil, selection: nil, isValueWritable: false) }
        guard let element = focus.element(for: current) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.20)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { InsertionLog.record(.role(.unavailable)); return nil }
        InsertionLog.record(.role(Self.diagnosticRole(role as? String)))
        guard let kind = Self.textTargetKind(forAXRole: role as? String) else { return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false) }
        let contentContext = webContentContext(of: element)
        var rangeRef: CFTypeRef?
        guard
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = validatedAXValue(rangeRef) else { return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false, contentContext: contentContext) }
        var range = CFRange(); guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) else { return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false) }
        let selection = TextSelection(location: range.location, length: range.length)
        guard AXSelectionValidator.validate(primary: selection, evidence: selectedRanges(element)) else { return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false) }
        var selectedTextRef: CFTypeRef?; var selectedTextSettable = DarwinBoolean(false)
        let selectedTextStatus = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef)
        let selectedTextWritable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable) == .success && selectedTextSettable.boolValue
        if let selectedText = Self.selectedText(status: selectedTextStatus, value: selectedTextRef as? String, selection: selection) {
            // This is the primary selection-bound route for native fields and
            // text areas. The boolean records whether it may commit directly.
            return .init(kind: .richText, value: selectedText, selection: selection, isValueWritable: selectedTextWritable, contentContext: contentContext)
        }
        switch kind {
        case .simpleText:
            var valueRef: CFTypeRef?; var valueSettable = DarwinBoolean(false)
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                  let value = valueRef as? String,
                  AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
                  valueSettable.boolValue else { return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false) }
            return .init(kind: kind, value: value, selection: selection, isValueWritable: true, contentContext: contentContext)
        case .richText:
            return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false)
        case .terminal, .unsupported:
            return .init(kind: .unsupported, value: nil, selection: nil, isValueWritable: false)
        }
    }
    private func webContentContext(of element: AXUIElement) -> AXContentContext {
        AXWebContentDetector.detect(start: element, role: { node in
            AXUIElementSetMessagingTimeout(node, 0.20)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success else { return nil }
            return role as? String
        }, parent: { node in
            AXUIElementSetMessagingTimeout(node, 0.20)
            var parent: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent)
            if status == .noValue { return .root }
            guard status == .success, let parent = validatedAXUIElement(parent) else { return .unavailable }
            return .parent(parent)
        })
    }
    public func replaceValue(_ value: String, expectedOriginalValue: String, expectedOriginalSelection: TextSelection, in current: CurrentFocus) -> AXMutationResult {
        guard focus.validatesCurrentField(current), let element = focus.element(for: current) else { return .unavailable }
        AXUIElementSetMessagingTimeout(element, 0.20)
        var valueRef: CFTypeRef?; var rangeRef: CFTypeRef?; var settable = DarwinBoolean(false)
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              (valueRef as? String) == expectedOriginalValue,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = validatedAXValue(rangeRef) else { return .rejected }
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range),
              Self.allowsFullValueCommit(actualValue: valueRef as? String, expectedValue: expectedOriginalValue, actualSelection: .init(location: range.location, length: range.length), expectedSelection: expectedOriginalSelection, evidence: selectedRanges(element), valueWritable: AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue, fieldStillCurrent: focus.validatesCurrentField(current)) else { return .rejected }
        // Exactly one full-value write; caret updates would be a second mutation.
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success ? .confirmed : .uncertain
    }
    public func replaceSelectedText(_ text: String, selection: TextSelection, in current: CurrentFocus) -> AXMutationResult {
        guard focus.validatesCurrentField(current), let element = focus.element(for: current) else { return .unavailable }
        AXUIElementSetMessagingTimeout(element, 0.20)
        var rangeRef: CFTypeRef?; var settable = DarwinBoolean(false)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = validatedAXValue(rangeRef) else { return .unavailable }
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range),
              Self.allowsSelectedTextCommit(actualSelection: .init(location: range.location, length: range.length), expectedSelection: selection, evidence: selectedRanges(element), selectedTextWritable: AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue, fieldStillCurrent: focus.validatesCurrentField(current)) else { return .rejected }
        // This is the only AX write for rich content. No caret rewrite follows.
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success ? .confirmed : .uncertain
    }
    public func readBackValue(in current: CurrentFocus) -> String? {
        guard focus.validatesCurrentField(current), let element = focus.element(for: current) else { return nil }; AXUIElementSetMessagingTimeout(element, 0.20)
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }; return value as? String
    }
    public func captureWitness(for target: AXTextTarget, in focus: CurrentFocus, transcript: String) -> PasteWitness? {
        guard let element = self.focus.element(for: focus) else { return nil }; AXUIElementSetMessagingTimeout(element, 0.20)
        var rangeRef: CFTypeRef?
        guard
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = validatedAXValue(rangeRef) else { return nil }
        var range = CFRange(); guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        let selection = TextSelection(location: range.location, length: range.length)
        guard AXSelectionValidator.validate(primary: selection, evidence: selectedRanges(element)) else { return nil }
        guard selection == target.selection else { return nil }
        switch target.kind {
        case .simpleText:
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                  let value = valueRef as? String, value == target.value else { return nil }
            let target = AXTextTarget(kind: .simpleText, value: value, selection: selection, isValueWritable: true)
            guard let splice = AccessibilityInsertionAdapter.splicedValue(target: target, transcript: transcript) else { return nil }
            return PasteWitness(expectedValue: splice.value)
        case .richText:
            var selectedTextRef: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef)
            guard let selectedText = Self.selectedText(status: status, value: selectedTextRef as? String, selection: selection),
                  selectedText == target.value else { return nil }
            return SelectionInsertionPlan.witness(transcript: transcript, selection: selection)
        case .terminal, .unsupported:
            return nil
        }
    }
    public func confirms(_ witness: PasteWitness, in focus: CurrentFocus) async -> Bool {
        if let expectedValue = witness.expectedValue { return readBackValue(in: focus) == expectedValue }
        guard let expectedText = witness.expectedInsertedText, let expectedRange = witness.expectedInsertedRange, self.focus.validatesCurrentField(focus), let element = self.focus.element(for: focus) else { return false }
        AXUIElementSetMessagingTimeout(element, 0.20)
        var range = CFRange(location: expectedRange.location, length: expectedRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }
        var insertedText: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &insertedText) == .success && (insertedText as? String) == expectedText
    }
    private func selectedRanges(_ element: AXUIElement) -> AXSelectionEvidence {
        // The attribute is absent on many controls; when present it must prove one identical CFRange.
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXSelectedTextRanges" as CFString, &raw)
        return Self.selectedRangesEvidence(status: result) {
            guard let values = raw as? [AXValue] else { return nil }
            var ranges: [TextSelection] = []
            ranges.reserveCapacity(values.count)
            for value in values {
                var range = CFRange()
                guard AXValueGetType(value) == .cfRange,
                      AXValueGetValue(value, .cfRange, &range) else { return nil }
                ranges.append(TextSelection(location: range.location, length: range.length))
            }
            return ranges
        }
    }
}

public final class MacOSPasteboardGateway: @unchecked Sendable, PasteboardGateway {
    private let board: NSPasteboard
    public init(board: NSPasteboard = .general) { self.board = board }
    public func supportsAlwaysAllowSnapshot() -> Bool {
        let allowed: Bool
        if #available(macOS 15.4, *) { allowed = board.accessBehavior == .alwaysAllow } else { allowed = false }
        InsertionLog.record(.flag(.snapshotAllowed, allowed))
        return allowed
    }
    public func snapshot(maximumItems: Int, maximumBytes: Int, maximumItemBytes: Int) -> PasteboardSnapshot? {
        guard supportsAlwaysAllowSnapshot() else {
            InsertionLog.record(.snapshot(.accessDenied, items: 0, types: 0, countDelta: 0))
            return nil
        }
        guard maximumItems > 0, maximumBytes > 0, maximumItemBytes > 0 else {
            InsertionLog.record(.snapshot(.invalidLimits, items: 0, types: 0, countDelta: 0))
            return nil
        }
        var failure: (reason: InsertionLog.SnapshotReason, items: Int, types: Int)?
        return VersionedPasteboardSnapshot.capture(changeCount: { board.changeCount }, failureDetails: { failure }) {
            Self.snapshotItems(board.pasteboardItems, maximumItems: maximumItems, maximumBytes: maximumBytes, maximumItemBytes: maximumItemBytes) {
                failure = ($0, $1, $2)
            }
        }
    }

    /// Detached read port preserves nil (unreadable) versus [] (known empty).
    static func snapshotItems(_ source: [NSPasteboardItem]?, maximumItems: Int, maximumBytes: Int, maximumItemBytes: Int, onFailure: (InsertionLog.SnapshotReason, Int, Int) -> Void) -> [PasteboardItemSnapshot]? {
        guard let items = source else {
            onFailure(.itemsUnavailable, 0, 0)
            return nil
        }
        let typeCount = items.reduce(0) { $0 + $1.types.count }
        func reject(_ reason: InsertionLog.SnapshotReason) -> [PasteboardItemSnapshot]? {
            onFailure(reason, items.count, typeCount)
            return nil
        }
        guard items.count <= maximumItems else { return reject(.tooManyItems) }
        var total = 0; var snapshots: [PasteboardItemSnapshot] = []
        for item in items {
            guard !item.types.isEmpty else { return reject(.missingTypes) }
            var data: [String: Data] = [:]
            for type in item.types {
                guard let value = item.data(forType: type) else { return reject(.dataUnavailable) }
                guard value.count <= maximumItemBytes else { return reject(.itemTooLarge) }
                guard value.count <= maximumBytes - total else { return reject(.totalTooLarge) }
                total += value.count; data[type.rawValue] = value
            }
            snapshots.append(.init(types: data))
        }
        return snapshots
    }

    public func writeCurrentHostOnlyTranscript(_ text: String) -> Bool {
        board.prepareForNewContents(with: [.currentHostOnly])
        return board.setString(text, forType: .string)
    }
    public func changeCount() -> Int { board.changeCount }
    public func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        guard supportsAlwaysAllowSnapshot() else { return false }
        return Self.restoreContents(snapshot, clear: {
            board.prepareForNewContents(with: [.currentHostOnly])
        }, write: { board.writeObjects($0) })
    }
    /// Detached restoration port: empty snapshots clear without writing objects.
    /// The transaction performs its unchanged-version check before entering here.
    static func restoreContents(_ snapshot: PasteboardSnapshot, clear: () -> Void, write: ([NSPasteboardItem]) -> Bool) -> Bool {
        guard let items = materializedItems(from: snapshot) else { return false }
        clear()
        return items.isEmpty || write(items)
    }
    /// All detached items are constructed before the live board is cleared.
    private static func materializedItems(from snapshot: PasteboardSnapshot) -> [NSPasteboardItem]? {
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.items.count)
        for snapshot in snapshot.items {
            guard !snapshot.types.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in snapshot.types {
                guard !type.isEmpty, item.setData(data, forType: .init(type)) else { return nil }
            }
            items.append(item)
        }
        return items
    }
}

public final class MacOSPasteEventPoster: @unchecked Sendable, PasteEventPosting {
    public init() {}
    public func isPreflightAllowed() -> Bool { CGPreflightPostEventAccess() }
    public func postCommandV(to processID: Int32) -> PastePostResult {
        guard processID > 0, CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(), let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true), let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true), let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false), let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return .unavailable }
        commandDown.flags = .maskCommand; vDown.flags = .maskCommand; vUp.flags = .maskCommand; commandUp.flags = []
        commandDown.postToPid(pid_t(processID)); vDown.postToPid(pid_t(processID)); vUp.postToPid(pid_t(processID)); commandUp.postToPid(pid_t(processID))
        return .posted
    }
}
