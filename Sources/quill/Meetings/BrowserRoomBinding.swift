import Foundation

/// A browser surface survives Meet's in-app room navigation. Room codes do not.
enum BrowserRoomBinding {
    struct Candidate {
        let id: String
        let code: String?
        let sameTab: Bool
        let sameDocument: Bool
    }

    static func existingID(_ candidates: [Candidate], code: String?, hasTab: Bool) -> String? {
        let surface = candidates.filter { $0.sameDocument || $0.sameTab }
        if surface.count == 1 { return surface[0].id }
        // An ambiguous surface must not borrow a different call's participants.
        guard surface.isEmpty, !hasTab, let code else { return nil }
        let sameCode = candidates.filter { $0.code == code }
        return sameCode.count == 1 ? sameCode[0].id : nil
    }
}
