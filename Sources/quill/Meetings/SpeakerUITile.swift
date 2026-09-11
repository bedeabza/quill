import Foundation

struct SpeakerUINode {
    let parent: Int?
    let role: String
    let text: String
    let classes: Set<String>
    var subrole: String = ""
    var identifier: String = ""
    var roleDescription: String = ""
}

enum SpeakerUITileKind {
    case meet, teamsFrame

    func recognizes(_ classes: Set<String>) -> Bool {
        switch self {
        case .meet: return classes.isSuperset(of: ["lH9pqf", "atLQQ"])
        case .teamsFrame: return classes.contains("fui-Flex")
        }
    }

    func isSpeaking(_ classes: Set<String>) -> Bool {
        switch self {
        case .meet: return MeetTileEvidence.isSpeaking(classes: classes)
        case .teamsFrame: return classes.contains("vdi-frame-occlusion")
        }
    }
}

struct SpeakerUITile {
    let indicatorIndex: Int
    let nameIndex: Int
    let name: String
    let isLocal: Bool
    var kind: SpeakerUITileKind = .meet
}
