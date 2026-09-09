import CoreGraphics
import Foundation

struct ZoomVideoSnapshot: Equatable, Sendable {
    let name: String
    let frame: CGRect
    let muted: Bool
    let isLocal: Bool
}

enum ZoomSpeakerEvidence {
    static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 10000, height <= 10000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }

    static func participant(description: String, frame: CGRect, localName: String?) -> ZoomVideoSnapshot? {
        let pattern = #"^(.+), (?:Computer|Phone) audio (unmuted|muted)(?:, Video (?:on|off))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)),
              let nameRange = Range(match.range(at: 1), in: description),
              let stateRange = Range(match.range(at: 2), in: description),
              let name = SpeakerAttribution.cleanName(String(description[nameRange])) else { return nil }
        return ZoomVideoSnapshot(name: name, frame: frame, muted: description[stateRange] == "muted",
                                 isLocal: name.caseInsensitiveCompare(localName ?? "") == .orderedSame)
    }

    /// A thin green/yellow outline on three sides and part of the fourth.
    /// Blue focus outlines and solid colored video backgrounds do not match.
    static func borderScore(rgba: [UInt8], width: Int, height: Int, rect: CGRect) -> Double {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              rect.width >= 60, rect.height >= 60, rect.minX >= -5, rect.minY >= -5,
              rect.maxX <= Double(width) + 5, rect.maxY <= Double(height) + 5 else { return 0 }
        func highlighted(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            let offset = (y * width + x) * 4
            let r = Int(rgba[offset]), g = Int(rgba[offset + 1]), b = Int(rgba[offset + 2])
            let green = g >= 135 && g > r * 5 / 4 && g > b * 3 / 2
            let yellow = r >= 170 && g >= 130 && b < 110 && r - g < 110
            return green || yellow
        }
        var best = 0.0
        for inset in -4...4 {
            var edges = [Double](repeating: 0, count: 4)
            for sample in 0..<40 {
                let t = 0.08 + 0.84 * Double(sample) / 39
                let x = Int(rect.minX + t * rect.width), y = Int(rect.minY + t * rect.height)
                let left = Int(rect.minX) + inset, right = Int(rect.maxX) - 1 - inset
                let top = Int(rect.minY) + inset, bottom = Int(rect.maxY) - 1 - inset
                for (edge, point, inner) in [(0, (left,y), (left+8,y)), (1, (right,y), (right-8,y)),
                                             (2, (x,top), (x,top+8)), (3, (x,bottom), (x,bottom-8))] {
                    if highlighted(point.0, point.1) && !highlighted(inner.0, inner.1) { edges[edge] += 1.0 / 40 }
                }
            }
            let ranked = edges.sorted(by: >)
            if ranked[3] >= 0.25 { best = max(best, ranked[2]) }
        }
        return best
    }
}
