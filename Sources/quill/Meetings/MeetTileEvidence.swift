import Foundation

/// Verified against speaking and silent Meet tiles in Brave on 2026-09-09.
/// These are Meet's DOM classes exposed by AXDOMClassList, not participant
/// names or a guessed active video. If the structure changes, return no tiles.
enum MeetTileEvidence {
    static func tiles(_ nodes: [SpeakerUINode]) -> [SpeakerUITile] {
        func descendant(_ index: Int, of ancestor: Int) -> Bool {
            var current = nodes[index].parent
            var visited: Set<Int> = []
            while let parent = current, nodes.indices.contains(parent), visited.insert(parent).inserted {
                if parent == ancestor { return true }
                current = nodes[parent].parent
            }
            return false
        }
        var result: [SpeakerUITile] = []
        for index in nodes.indices {
            let indicator = nodes[index]
            guard indicator.classes.isSuperset(of: ["lH9pqf", "atLQQ"]), let parent = indicator.parent else { continue }
            let labels = nodes.indices.filter { nodes[$0].classes.contains("OFfHfd") && descendant($0, of: parent) }
            guard labels.count == 1, let label = labels.first else { continue }
            let names = nodes.indices.filter { nodes[$0].role == "AXStaticText" && descendant($0, of: label) && SpeakerAttribution.cleanName(nodes[$0].text) != nil }
            guard names.count == 1, let nameIndex = names.first,
                  let name = SpeakerAttribution.cleanName(nodes[nameIndex].text) else { continue }
            result.append(SpeakerUITile(indicatorIndex: index, nameIndex: nameIndex, name: name,
                                          isLocal: indicator.classes.contains("eQJ1qd")))
        }
        return result
    }

    static func isSpeaking(classes: Set<String>) -> Bool {
        // Meet's loaded CSS hides the audio indicator under
        // .atLQQ:not(.kssMZb), and uses kssMZb for its speaker-border animation.
        classes.isSuperset(of: ["lH9pqf", "atLQQ", "kssMZb"])
    }
}
