import CoreGraphics
import Foundation
import ShotModel
import Vision

/// The auto-redaction pre-scan seam. The editor offers to pre-select sensitive
/// regions; a real scan runs Vision OCR, a fake drives tests. Best-effort and
/// non-fatal — any failure returns [] and the manual redaction gate (the editor)
/// remains the real guarantee.
public protocol OCRScanning: Sendable {
    /// Return padded image-px rects over detected sensitive text, or [] on any
    /// failure. `image` is the raw screenshot (top-left px, the schema space).
    func scanForSensitiveRects(_ image: CGImage) async -> [Rect]
}

/// Vision-backed OCR — the macOS replacement for the Windows Tesseract worker.
/// Vision provides word-level boxes built in and needs no vendored model and no
/// TCC grant (on-device image analysis, not screen capture).
public struct VisionOCR: OCRScanning {
    public init() {}

    public func scanForSensitiveRects(_ image: CGImage) async -> [Rect] {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Raw tokens (API keys, card numbers) must not be "corrected" into words.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return [] // best-effort: OCR failure yields no auto-redactions
        }
        guard let observations = request.results else { return [] }

        var lines: [OcrLine] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let string = candidate.string
            var words: [OcrWord] = []
            // Split into words and recover each word's box from the candidate.
            for range in wordRanges(in: string) {
                guard let box = try? candidate.boundingBox(for: range) else { continue }
                // Vision boxes are normalized, bottom-left origin → image-px top-left.
                let bb = box.boundingBox
                words.append(OcrWord(
                    text: String(string[range]),
                    bbox: .init(
                        x0: Double(bb.minX * w),
                        y0: Double((1 - bb.maxY) * h),
                        x1: Double(bb.maxX * w),
                        y1: Double((1 - bb.minY) * h)
                    )
                ))
            }
            if !words.isEmpty { lines.append(OcrLine(words: words)) }
        }
        return detectSensitiveRects(lines)
    }

    /// Ranges of whitespace-separated tokens in a string.
    private func wordRanges(in s: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let start = i
            while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
            ranges.append(start..<i)
        }
        return ranges
    }
}
