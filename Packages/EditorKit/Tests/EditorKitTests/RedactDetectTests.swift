import Foundation
import Testing
@testable import EditorKit
import ShotModel

// C3: the sensitive-text detectors (ported from redact-detect.test.ts intent).
@Suite struct RedactDetectTests {
    /// Build a single-line OCR input from words, giving each a 10×10 box in a row.
    private func line(_ words: [String]) -> OcrLine {
        OcrLine(words: words.enumerated().map { i, t in
            OcrWord(text: t, bbox: .init(x0: Double(i) * 60, y0: 0, x1: Double(i) * 60 + 50, y1: 20))
        })
    }

    @Test func detectsSSN() {
        let rects = detectSensitiveRects([line(["SSN:", "123-45-6789"])])
        #expect(rects.count == 1)
    }

    @Test func detectsLuhnValidCardAcrossWords() {
        // 4111 1111 1111 1111 is a Luhn-valid test Visa split across 4 words.
        let rects = detectSensitiveRects([line(["Card", "4111", "1111", "1111", "1111"])])
        #expect(rects.count == 1)
    }

    @Test func ignoresNonLuhnLongDigitRun() {
        // 4111111111111112 = the Luhn-valid test Visa with its check digit
        // changed → fails Luhn, so a 16-digit order number is NOT redacted.
        let rects = detectSensitiveRects([line(["Order", "4111111111111112"])])
        #expect(rects.isEmpty)
    }

    @Test func detectsAPIKeys() {
        #expect(detectSensitiveRects([line(["key", "sk-abcdefghijklmnop0123"])]).count == 1)
        #expect(detectSensitiveRects([line(["AKIAIOSFODNN7EXAMPLE"])]).count == 1)
        #expect(detectSensitiveRects([line(["ghp_0123456789abcdefghijklmnopqrstuvwx"])]).count == 1)
    }

    @Test func ignoresOrdinaryText() {
        let rects = detectSensitiveRects([line(["Click", "the", "Save", "button", "in", "Safari"])])
        #expect(rects.isEmpty)
    }

    @Test func emailAndPhoneAreNotRedacted() {
        // Deliberately excluded as too noisy.
        #expect(detectSensitiveRects([line(["jane@example.com", "555-123-4567"])]).isEmpty)
    }

    @Test func mergesOverlappingRects() {
        // Two SSNs whose padded boxes overlap merge into one.
        let l = OcrLine(words: [
            OcrWord(text: "123-45-6789", bbox: .init(x0: 0, y0: 0, x1: 50, y1: 20)),
            OcrWord(text: "987-65-4321", bbox: .init(x0: 52, y0: 0, x1: 100, y1: 20)),
        ])
        let rects = detectSensitiveRects([l], pad: 8)
        #expect(rects.count == 1) // padded boxes overlap → merged
    }
}
