import Foundation

/// The system reader retains an app PID even when its lazy element read fails.
/// Each PID gets one application lookup within the shared deadline.
enum FocusedElementReader {
    static func read<Value>(ownPID: Int32, withinBudget: () -> Bool = { true }, system: () -> (Int32, () -> Value?)?, frontmostPID: () -> Int32?, application: (Int32) -> Value?) -> Value? {
        guard withinBudget() else { return nil }
        let systemApp = system()
        guard withinBudget() else { return nil }
        if let (pid, readElement) = systemApp {
            guard pid != ownPID else { InsertionLog.record(.step(.ownAppRejected)); return nil }
            if let value = readElement(), withinBudget() {
                InsertionLog.record(.step(.focusSystemRoute))
                return value
            }
            // This PID has consumed its single application lookup, including
            // activation/search. Never restart it through a fresh app handle.
            InsertionLog.record(.step(.focusSystemFailed))
            return nil
        }
        guard withinBudget() else { return nil }
        InsertionLog.record(.step(.focusSystemFailed))
        guard let pid = frontmostPID(), withinBudget(), pid > 0 else { InsertionLog.record(.step(.focusFrontmostFailed)); return nil }
        guard pid != ownPID else { InsertionLog.record(.step(.ownAppRejected)); return nil }
        guard systemApp == nil || systemApp?.0 == pid else { InsertionLog.record(.step(.focusFrontmostMismatch)); return nil }
        guard let value = application(pid), withinBudget() else { InsertionLog.record(.step(.focusFrontmostFailed)); return nil }
        InsertionLog.record(.step(systemApp == nil ? .focusFrontmostRoute : .focusKnownAppRoute))
        return value
    }
}

/// Missing focus is distinct from transport/type errors: only absence enables
/// the attribute-based activation and focused-window fallback.
enum ApplicationFocusRead<Node> {
    case focused(Node), missing, unavailable
}

enum ApplicationFocusedElementReader {
    static func read<Node>(withinBudget: () -> Bool = { true }, focused: () -> ApplicationFocusRead<Node>, enableManualAccessibility: () -> Bool, focusedWindow: () -> Node?) -> Node? {
        guard withinBudget() else { return nil }
        let initial = focused()
        guard withinBudget() else { return nil }
        switch initial {
        case let .focused(node): return node
        case .unavailable: return nil
        case .missing: break
        }
        if enableManualAccessibility() {
            guard withinBudget() else { return nil }
            InsertionLog.record(.step(.manualAccessibilityEnabled))
            let retry = focused()
            guard withinBudget() else { return nil }
            switch retry {
            case let .focused(node): return node
            case .unavailable: return nil
            case .missing: break
            }
        }
        guard withinBudget() else { return nil }
        InsertionLog.record(.step(.focusedWindowSearch))
        let result = focusedWindow()
        return withinBudget() ? result : nil
    }
}

/// A complete bounded walk is required to establish uniqueness. Incomplete or
/// unreadable trees never turn a first match into a positive focus receipt.
enum FocusedWindowSearch {
    static func find<Node: Hashable>(root: Node, maximumNodes: Int = 2_000, maximumDepth: Int = 40, withinBudget: () -> Bool, confirm: (Node) -> Bool = { _ in true }, inspect: (Node) -> (matches: Bool, children: [Node])?) -> Node? {
        var pending = [(root, 0)], visited = Set<Node>(), match: Node?
        while let (node, depth) = pending.popLast() {
            guard withinBudget() else { return nil }
            guard !visited.contains(node) else { continue }
            guard visited.count < maximumNodes, depth <= maximumDepth else { return nil }
            visited.insert(node)
            guard let result = inspect(node), withinBudget() else { return nil }
            if result.matches {
                guard match == nil else { return nil }
                match = node
            }
            guard result.children.count <= maximumNodes, pending.count + result.children.count <= maximumNodes else { return nil }
            if depth == maximumDepth, result.children.contains(where: { !visited.contains($0) }) { return nil }
            pending.append(contentsOf: result.children.map { ($0, depth + 1) })
        }
        guard let match, withinBudget(), confirm(match), withinBudget() else { return nil }
        return match
    }
}

/// One monotonic deadline is shared by system, activation, search and final
/// confirmation. AX calls must use a fresh timeout from this same budget.
final class FocusReadBudget {
    private let now: () -> UInt64
    private let deadline: UInt64
    init(nanoseconds: UInt64 = 300_000_000, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        deadline = now() + nanoseconds
    }
    var isActive: Bool { now() < deadline }
    var remainingAXTimeout: Float? {
        let current = now()
        guard current < deadline else { return nil }
        return Float(min(0.2, Double(deadline - current) / 1e9))
    }
}

enum FocusedWindowConfirmation {
    static func confirms(expectedPID: Int32, currentPID: () -> Int32?, sameWindow: () -> Bool, stillFocused: () -> Bool, withinBudget: () -> Bool) -> Bool {
        withinBudget() && currentPID() == expectedPID && withinBudget() && sameWindow()
            && withinBudget() && stillFocused() && withinBudget() && currentPID() == expectedPID && withinBudget()
    }
}
