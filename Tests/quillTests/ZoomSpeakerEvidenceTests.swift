import CoreGraphics
import XCTest
@testable import quill

final class ZoomSpeakerEvidenceTests: XCTestCase {
    private let rect = CGRect(x: 20, y: 20, width: 120, height: 100)

    private func pixels(color: [UInt8], filled: Bool = false, edges: Int = 4) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 160 * 140 * 4)
        for y in 20..<120 {
            for x in 20..<140 {
                let border = (edges >= 1 && x < 23) || (edges >= 2 && x >= 137)
                    || (edges >= 3 && y < 23) || (edges >= 4 && y >= 117)
                let index = (y * 160 + x) * 4
                for channel in 0..<3 { rgba[index + channel] = filled || border ? color[channel] : 24 }
                rgba[index + 3] = 255
            }
        }
        return rgba
    }

    func testGreenAndYellowSpeakerOutlinesAreDetected() {
        for color: [UInt8] in [[20, 230, 40], [255, 210, 20]] {
            XCTAssertGreaterThan(ZoomSpeakerEvidence.borderScore(rgba: pixels(color: color), width: 160, height: 140, rect: rect), 0.9)
        }
    }

    func testFocusBackgroundAndPartialEdgesDoNotBecomeSpeakerNames() {
        for sample in [pixels(color: [25, 120, 250]), pixels(color: [20, 230, 40], filled: true), pixels(color: [20, 230, 40], edges: 2), pixels(color: [20, 230, 40], edges: 3)] {
            XCTAssertLessThan(ZoomSpeakerEvidence.borderScore(rgba: sample, width: 160, height: 140, rect: rect), 0.65)
        }
        XCTAssertEqual(ZoomSpeakerEvidence.borderScore(rgba: [], width: 160, height: 140, rect: rect), 0)
    }

    func testNativeNamesMuteStateAndSelfAreParsedSeparately() throws {
        let remote = try XCTUnwrap(ZoomSpeakerEvidence.participant(description: "Remote Person, Computer audio muted, Video off", frame: rect, localName: "Local Person"))
        XCTAssertEqual(remote.name, "Remote Person")
        XCTAssertTrue(remote.muted)
        XCTAssertFalse(remote.isLocal)
        let local = try XCTUnwrap(ZoomSpeakerEvidence.participant(description: "Local Person, Computer audio unmuted, Video on", frame: rect, localName: "Local Person"))
        XCTAssertFalse(local.muted)
        XCTAssertTrue(local.isLocal)
        XCTAssertNil(ZoomSpeakerEvidence.participant(description: "Remote Person is in chat", frame: rect, localName: nil))
    }

    func testPixelConversionPreservesTopAndBottomOrientation() throws {
        let data = Data([UInt8](arrayLiteral: 255,0,0,255, 255,0,0,255, 0,0,255,255, 0,0,255,255))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = try XCTUnwrap(ZoomSpeakerEvidence.rgbaPixels(image))
        XCTAssertEqual(Array(output.prefix(4)), [255,0,0,255])
        XCTAssertEqual(Array(output.suffix(4)), [0,0,255,255])
    }

    func testZoomSamplesUseTheSharedTimedNamePipeline() {
        let samples = [0.0, 0.5, 1.0].map { SpeakerObservation(observed_at: 100 + $0, meeting_id: "zoom", names: ["Remote Person"], source: "zoom_border") }
        let spans = SpeakerAttribution.tileSpans(observations: samples, audioStartedAt: 100)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.identity.name, "Remote Person")
        XCTAssertEqual(spans.first?.identity.source, "zoom_border")
    }
}
