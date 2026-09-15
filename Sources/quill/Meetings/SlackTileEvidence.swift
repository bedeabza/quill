import Foundation

/// Captured in Slack's native huddle on 2026-09-15. Each peer is an AXCell
/// named "View <name>'s profile". Speaking adds a mic overlay below that cell;
/// the overlay disappears when silent, so cache the peer, not the overlay.
enum SlackTileEvidence {
    static let peerClass = "p-huddle_peer_tile"
    static let gridClass = "p-huddle_grid_component"

    static func name(in label: String) -> String? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.hasPrefix("View ") else { return nil }
        for suffix in ["'s profile", "’s profile"] where label.hasSuffix(suffix) {
            return SpeakerAttribution.cleanName(String(label.dropFirst(5).dropLast(suffix.count)))
        }
        return nil
    }

    static func tiles(_ nodes: [SpeakerUINode]) -> [SpeakerUITile] {
        var result: [SpeakerUITile] = []
        for index in nodes.indices {
            let node = nodes[index]
            guard node.role == "AXCell", node.classes.contains(peerClass), let name = name(in: node.text) else { continue }
            var parent = node.parent
            var visited: Set<Int> = []
            var inGrid = false
            while let next = parent, nodes.indices.contains(next), visited.insert(next).inserted {
                if nodes[next].classes.contains(peerClass) { break }
                if nodes[next].role == "AXTable", nodes[next].classes.contains(gridClass) { inGrid = true; break }
                parent = nodes[next].parent
            }
            guard inGrid else { continue }
            result.append(SpeakerUITile(indicatorIndex: index, nameIndex: index, name: name, isLocal: false, kind: .slackPeer))
        }
        let counts = Dictionary(grouping: result, by: { $0.name.lowercased() }).mapValues(\.count)
        return result.filter { counts[$0.name.lowercased()] == 1 }
    }

    /// Re-read a small peer subtree on every sample because Slack creates and
    /// removes the speaking overlay. Missing/changed/oversized trees are unknown.
    static func activity<Element: Hashable>(root: Element, expectedName: String, hasTime: () -> Bool,
        read: (Element) -> (SpeakerUINode, [Element])?) -> Bool? {
        guard hasTime(), let (peer, children) = read(root), valid(peer, name: expectedName) else { return nil }
        var queue = children
        var visited: Set<Element> = [root]
        var speaking = false
        while let element = queue.popLast() {
            guard hasTime(), visited.count < 64, queue.count < 128 else { return nil }
            guard visited.insert(element).inserted else { continue }
            guard let (node, descendants) = read(element), !node.classes.contains(peerClass) else { return nil }
            if node.classes.isSuperset(of: ["p-huddle_peer_tile__mic_overlay", "p-huddle_peer_tile__overlay--active_speaker"]) {
                speaking = true
            }
            queue.append(contentsOf: descendants)
        }
        // A rename or recycled cell must not retain the cached identity.
        guard hasTime(), let (after, _) = read(root), valid(after, name: expectedName) else { return nil }
        return speaking
    }

    private static func valid(_ node: SpeakerUINode, name expected: String) -> Bool {
        node.role == "AXCell" && node.classes.contains(peerClass) && name(in: node.text) == expected
    }
}
