/// Bounded structural evidence; a failed or exhausted walk never proves native content.
enum AXWebContentDetector {
    enum Parent<Node> { case parent(Node), root, unavailable }
    static func detect<Node>(start: Node, maximumDepth: Int = 32, role: (Node) -> String?, parent: (Node) -> Parent<Node>) -> AXContentContext {
        var node = start
        for _ in 0..<max(0, min(maximumDepth, 32)) {
            guard let name = role(node) else { return .unknown }
            if name == "AXWebArea" { return .webContent }
            if name == "AXApplication" || name == "AXSystemWide" { return .native }
            switch parent(node) {
            case let .parent(next): node = next
            case .root: return .native
            case .unavailable: return .unknown
            }
        }
        return .unknown
    }
}
