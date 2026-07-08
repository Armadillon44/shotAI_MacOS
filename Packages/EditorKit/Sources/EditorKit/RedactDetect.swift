import Foundation
import ShotModel

/// Detect likely-sensitive text in OCR output and map it to image-px rects to
/// redact. Ported from `shotAI-original/src/shared/redact-detect.ts`. BEST-EFFORT
/// assist on top of the manual redaction gate — OCR misses stylized/low-res text,
/// so the human review (the editor) stays authoritative. Pure + dependency-free.
/// Detector set (conservative, to limit noise): US SSN, credit cards (Luhn),
/// API keys/tokens. Email + phone are intentionally excluded (too noisy).

/// One OCR word with its bounding box (image px; x0,y0 = top-left).
public struct OcrWord: Equatable, Sendable {
    public struct Box: Equatable, Sendable {
        public var x0, y0, x1, y1: Double
        public init(x0: Double, y0: Double, x1: Double, y1: Double) {
            self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
        }
    }
    public var text: String
    public var bbox: Box
    public init(text: String, bbox: Box) {
        self.text = text
        self.bbox = bbox
    }
}

/// One OCR line — words are matched within a line so multi-word numbers
/// (e.g. "4111 1111 1111 1111") are caught.
public struct OcrLine: Equatable, Sendable {
    public var words: [OcrWord]
    public init(words: [OcrWord]) { self.words = words }
}

private let ssn = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
// 13–19 digits with optional single space/dash separators — Luhn-validated below.
private let card = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)
private let apiPatterns: [NSRegularExpression] = [
    #"\bsk-[A-Za-z0-9_-]{16,}\b"#,   // OpenAI / Anthropic-style secret keys
    #"\bAKIA[0-9A-Z]{12,20}\b"#,     // AWS access key id
    #"\bgh[posru]_[A-Za-z0-9]{20,}\b"#, // GitHub tokens
    #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, // Slack tokens
    #"\b[0-9a-fA-F]{40,}\b"#,        // long hex (hashes / hex secrets)
    #"\b[A-Za-z0-9+/]{40,}={0,2}\b"#, // long base64-ish blobs
].map { try! NSRegularExpression(pattern: $0) }

/// Luhn checksum — keeps card detection from firing on arbitrary long digit runs.
private func luhn(_ digits: String) -> Bool {
    var sum = 0
    var alt = false
    for ch in digits.reversed() {
        guard let d0 = ch.wholeNumberValue, d0 >= 0, d0 <= 9 else { return false }
        var d = d0
        if alt { d *= 2; if d > 9 { d -= 9 } }
        sum += d
        alt.toggle()
    }
    return sum % 10 == 0
}

private func union(_ a: Rect, _ b: Rect) -> Rect {
    let x = min(a.x, b.x), y = min(a.y, b.y)
    let right = max(a.x + a.width, b.x + b.width)
    let bottom = max(a.y + a.height, b.y + b.height)
    return Rect(x: x, y: y, width: right - x, height: bottom - y)
}

private func overlaps(_ a: Rect, _ b: Rect) -> Bool {
    a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
}

/// Merge overlapping rects so the same region isn't redacted twice.
private func mergeRects(_ rects: [Rect]) -> [Rect] {
    var out: [Rect] = []
    for r in rects {
        var merged = r
        var i = out.count - 1
        while i >= 0 {
            if overlaps(out[i], merged) { merged = union(out.remove(at: i), merged) }
            i -= 1
        }
        out.append(merged)
    }
    return out
}

/// Find sensitive substrings across OCR lines and return padded image-px rects.
/// Each line's words are joined (tracking each word's char span, in UTF-16 units
/// so NSRegularExpression ranges line up) and a match is mapped back to the
/// covering words, whose boxes are unioned.
public func detectSensitiveRects(_ lines: [OcrLine], pad: Double = 4) -> [Rect] {
    var rects: [Rect] = []

    for line in lines {
        guard !line.words.isEmpty else { continue }
        let joined = NSMutableString()
        var spans: [(start: Int, end: Int, w: OcrWord)] = []
        for w in line.words {
            if joined.length > 0 { joined.append(" ") }
            let start = joined.length
            joined.append(w.text)
            spans.append((start, joined.length, w))
        }
        let text = joined as String
        let full = NSRange(location: 0, length: joined.length)

        func addMatch(_ mStart: Int, _ mEnd: Int) {
            let covered = spans.filter { $0.start < mEnd && $0.end > mStart }.map(\.w)
            guard !covered.isEmpty else { return }
            let x0 = covered.map(\.bbox.x0).min()!
            let y0 = covered.map(\.bbox.y0).min()!
            let x1 = covered.map(\.bbox.x1).max()!
            let y1 = covered.map(\.bbox.y1).max()!
            rects.append(Rect(x: x0 - pad, y: y0 - pad, width: x1 - x0 + pad * 2, height: y1 - y0 + pad * 2))
        }
        func run(_ re: NSRegularExpression, validate: ((String) -> Bool)? = nil) {
            for m in re.matches(in: text, range: full) {
                if let validate {
                    let s = (text as NSString).substring(with: m.range)
                    if !validate(s) { continue }
                }
                addMatch(m.range.location, m.range.location + m.range.length)
            }
        }

        run(ssn)
        for re in apiPatterns { run(re) }
        run(card) { s in
            let digits = s.filter(\.isNumber)
            return digits.count >= 13 && digits.count <= 19 && luhn(digits)
        }
    }

    return mergeRects(rects)
}
