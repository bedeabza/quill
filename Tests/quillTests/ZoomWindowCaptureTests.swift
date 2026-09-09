import AppKit
import XCTest
@testable import quill

@MainActor
private final class SpeakerBorderFixtureView: NSView {
    let localRect = NSRect(x: 20, y: 30, width: 220, height: 180)
    let remoteRect = NSRect(x: 260, y: 30, width: 220, height: 180)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor.darkGray.setFill()
        localRect.fill()
        remoteRect.fill()
        NSColor(calibratedRed: 0.05, green: 0.9, blue: 0.15, alpha: 1).setStroke()
        let border = NSBezierPath(rect: remoteRect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()
    }
}

final class ZoomWindowCaptureTests: XCTestCase {
    @MainActor
    func testWindowCaptureMapsBordersToNamesWithoutSavingFrames() async throws {
        guard ProcessInfo.processInfo.environment["QUILL_TEST_ZOOM_WINDOW"] == "1" else {
            throw XCTSkip("Set QUILL_TEST_ZOOM_WINDOW=1 for a local synthetic-window capture test")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        guard ZoomWindowSpeakerDetector.hasPermission else { throw XCTSkip("Screen Recording permission is required") }
        let targetScreen = try XCTUnwrap(NSScreen.screens.last)
        let window = NSWindow(contentRect: NSRect(x: targetScreen.frame.minX + 140, y: targetScreen.frame.minY + 140, width: 500, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Zoom Meeting"
        let view = SpeakerBorderFixtureView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        window.contentView = view
        window.orderFrontRegardless()
        window.displayIfNeeded()
        defer { window.close() }

        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let windowFrame = CGRect(x: window.frame.minX, y: screenHeight - window.frame.maxY,
                                 width: window.frame.width, height: window.frame.height)
        func screenRect(_ rect: NSRect) -> CGRect {
            let converted = window.convertToScreen(rect)
            return CGRect(x: converted.minX, y: screenHeight - converted.maxY, width: converted.width, height: converted.height)
        }
        let local = ZoomVideoSnapshot(name: "Local Fixture", frame: screenRect(view.localRect), muted: false, isLocal: true)
        let remote = ZoomVideoSnapshot(name: "Remote Fixture", frame: screenRect(view.remoteRect), muted: false, isLocal: false)
        let detector = ZoomWindowSpeakerDetector()
        var sample: ZoomSpeakerSample?
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(600))
            sample = await detector.sample(meetingID: "synthetic", pid: getpid(), frame: windowFrame, videos: [local, remote])
            if sample != nil { break }
        }
        let diagnostic = await detector.diagnostic
        let result = try XCTUnwrap(sample, diagnostic)
        XCTAssertEqual(result.names, ["Remote Fixture"], "\(result.scores)")
        XCTAssertGreaterThan(result.scores["Remote Fixture"] ?? 0, 0.65)
        XCTAssertLessThan(result.scores["Local Fixture"] ?? 1, 0.65)

        try await Task.sleep(for: .milliseconds(600))
        let muted = ZoomVideoSnapshot(name: remote.name, frame: remote.frame, muted: true, isLocal: false)
        let mutedResult = await detector.sample(meetingID: "synthetic", pid: getpid(), frame: windowFrame, videos: [local, muted])
        XCTAssertEqual(try XCTUnwrap(mutedResult).names, [])

        let unidentifiedSelf = ZoomVideoSnapshot(name: local.name, frame: local.frame, muted: false, isLocal: false)
        let missingSelf = await detector.sample(meetingID: "synthetic", pid: getpid(), frame: windowFrame, videos: [unidentifiedSelf, remote])
        XCTAssertNil(missingSelf)
    }
}
