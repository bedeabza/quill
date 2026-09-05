import XCTest
@testable import quill

final class AppRunLockTests: XCTestCase {
    func testOnlyOneRecorderCanRunAndLockIsReleased() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("run.lock")
        var first = try AppRunLock.acquire(at: path)
        XCTAssertNotNil(first)
        XCTAssertNil(try AppRunLock.acquire(at: path))
        first = nil
        let next = try AppRunLock.acquire(at: path)
        XCTAssertNotNil(next)
        withExtendedLifetime(next) {}
    }
}
