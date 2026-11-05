import XCTest
@testable import quill

@MainActor
final class PermissionsModelTests: XCTestCase {
    private func check(_ status: CheckStatus) -> Check { Check(name: "test", status: status, remediation: nil) }

    func testAttentionCountsFailuresAndWarningsExceptUnverifiableSystemAudio() {
        XCTAssertEqual(PermissionsModel.attentionCount([:]), 0)
        XCTAssertEqual(PermissionsModel.attentionCount([
            .microphone: check(.ok),
            .accessibility: check(.warn("Access not granted")),
            .screen: check(.ok),
            .systemAudio: check(.warn("Not verified until recording starts")),
            .notifications: check(.warn("Banners are disabled")),
            .folder: check(.fail("Cannot read or write here")),
            .transcription: check(.ok),
        ]), 3)
        XCTAssertEqual(PermissionsModel.attentionCount([.systemAudio: check(.warn("Not verified until recording starts"))]), 0)
    }
}
