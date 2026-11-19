import Foundation

/// A project's screenshot frame: the shape every step's image is shown in, in the
/// report and in every export. Stored as `ProjectManifest.shotFrame`, a `"W:H"`
/// string; absent means no frame, which is how every project looked before.
///
/// The frame is presentation only. The screenshot, its crop and its
/// redaction-baked render are never changed; each image sits inside the frame,
/// positioned by the step's report zoom and pan (`FrameGeometry`). The shared
/// spec, which the Windows port follows, is Armadillon44/shotAI#160.
public struct ShotFrame: Hashable, Sendable {
    /// The ratio in lowest terms, each term in 1...`maxTerm`.
    public let width: Int
    public let height: Int

    /// Bounds each term after reduction, so a value is a shape a person would
    /// choose, not a pixel size or a hand-edited extreme.
    public static let maxTerm = 64

    /// The choices the app offers, besides no frame.
    public static let presets: [ShotFrame] = [
        ShotFrame(width: 1, height: 1)!, ShotFrame(width: 5, height: 4)!, ShotFrame(width: 4, height: 3)!,
        ShotFrame(width: 3, height: 2)!, ShotFrame(width: 16, height: 9)!,
    ]

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let g = Self.gcd(width, height)
        let a = width / g, b = height / g
        guard a <= Self.maxTerm, b <= Self.maxTerm else { return nil }
        self.width = a
        self.height = b
    }

    /// Parse `"W:H"`: ASCII digits on each side of one colon, nothing else (no
    /// spaces, signs or decimals). Equivalent ratios parse to the same frame:
    /// `"10:8"` is `5:4`. Anything else is nil, which callers treat as no frame;
    /// the raw string itself is kept on disk regardless (see `shotFrame`).
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let w = Int(parts[0]), let h = Int(parts[1])
        else { return nil }
        self.init(width: w, height: h)
    }

    /// The canonical `"W:H"` written to disk.
    public var rawValue: String { "\(width):\(height)" }

    /// Width over height.
    public var ratio: Double { Double(width) / Double(height) }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}
