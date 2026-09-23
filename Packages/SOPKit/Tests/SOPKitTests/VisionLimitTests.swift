import CoreGraphics
import Foundation
import ImageIO
import ShotModel
import UniformTypeIdentifiers
import XCTest
@testable import SOPKit

/// Requests that would be rejected for their images are fixed or refused up front.
final class VisionLimitTests: XCTestCase {

    /// A PNG the size of a Retina full-display capture at the 0.85 contract.
    private func widePNG(_ w: Int = 2570, _ h: Int = 1600) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dst)
        return out as Data
    }

    private func project(_ shots: Int) async throws -> (dir: String, manifest: ProjectManifest) {
        let (store, path, dir) = try await makeProject(shots: 0)
        let png = widePNG()
        for _ in 0..<shots { _ = try await store.importImageStep(at: path, atIndex: nil, imageData: png) }
        return (dir, try await store.openProject(at: path).manifest)
    }

    private func sentSides(_ req: AssembledRequest) -> [Int] {
        let content = req.messages.first?["content"] as? [[String: Any]] ?? []
        return content.compactMap { block -> Int? in
            guard block["type"] as? String == "image",
                  let b64 = (block["source"] as? [String: Any])?["data"] as? String,
                  let d = Data(base64Encoded: b64),
                  let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return max(w, h)
        }
    }

    func testMoreThanTwentyImagesAreEachSentAtMostTwoThousandPixels() async throws {
        let (dir, m) = try await project(21)
        let sides = sentSides(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertEqual(sides.count, 21)
        XCTAssertTrue(sides.allSatisfy { $0 <= 2000 }, "largest sent side: \(sides.max() ?? 0)")
    }

    /// The control: at or under twenty images there is no stricter limit, so the
    /// renders go out at full size — shrinking them would only cost legibility.
    func testTwentyOrFewerImagesAreSentAtFullSize() async throws {
        let (dir, m) = try await project(20)   // the boundary itself: 20 is not "more than 20"
        let sides = sentSides(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertEqual(sides, Array(repeating: 2570, count: 20))
    }

    /// Over the payload cap the request is refused with a message that says what
    /// to do — before the cost estimate, not as an opaque API error after it.
    func testAnOversizedProjectIsRefusedWithAMessageThatSaysWhatToDo() async throws {
        let (dir, m) = try await project(2)
        XCTAssertThrowsError(try assembleRequest(dir: dir, manifest: m, settings: SopSettings(),
                                                 maxImagePayloadBytes: 1024)) { error in
            let text = (error as? ClaudeError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("Split it into smaller projects"), text)
        }
    }
}
