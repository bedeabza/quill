import XCTest
@testable import quill

final class NativeNotificationTests: XCTestCase {
    @MainActor
    func testNativeContentKeepsLiteralBodyAndUsesAppNameOnlyOnce() async {
        let body = "Quotes \" and $() stay literal\nnext line"
        let content = NativeNotifications.content(title: "Quill: Recording started", body: body)
        XCTAssertEqual(content.title, "Recording started")
        XCTAssertEqual(content.body, body)
        XCTAssertNil(content.sound)
    }
}
