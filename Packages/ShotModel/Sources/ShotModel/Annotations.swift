import Foundation

/// Non-destructive vector annotations drawn over a step's screenshot. All
/// geometry is in IMAGE (screenshot) pixel coordinates. They are flattened into
/// the exported PNG; blur/redact is BAKED destructively at flatten time so
/// original pixels never leave the machine. Mirrors `project.ts` exactly.

public struct RectAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var stroke: String
    public var strokeWidth: Double
    public var fill: String?

    enum CodingKeys: String, CodingKey {
        case id, x, y, width, height, cornerRadius, stroke, strokeWidth, fill
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(stroke, forKey: .stroke)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(fill, forKey: .fill) // "fill": null — TS shape
    }
}

/// Arrow from (points[0], points[1]) to (points[2], points[3]).
public struct ArrowAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var points: [Double]
    public var stroke: String
    public var strokeWidth: Double
}

/// Blur/redact region — baked destructively into the flattened output.
public struct BlurAnnotation: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case pixelate, solid
    }

    public var id: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var mode: Mode
    /// Mosaic block size in image px (pixelate); ignored for solid.
    public var blockSize: Double
}

/// Numbered step stamp (a circle with a number). x/y are the center.
public struct StampAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var x: Double
    public var y: Double
    public var n: Int
    public var radius: Double
    public var fill: String
    public var textColor: String
}

/// Free text label.
public struct TextAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var x: Double
    public var y: Double
    public var text: String
    public var fontSize: Double
    public var fill: String
}

/// A click-register ring, movable in the editor. x/y are the center (image px);
/// radius omitted = derive from the image size (legacy markers).
public struct MarkerAnnotation: Codable, Equatable, Sendable {
    public var id: String
    public var x: Double
    public var y: Double
    public var color: String
    public var radius: Double?
}

/// Tagged union over the `type` discriminator, exactly as the TS union. An
/// unrecognized type (from a newer schema, or hand-edited JSON) is preserved
/// verbatim as `.unknown` so it round-trips instead of being destroyed.
public enum Annotation: Codable, Equatable, Sendable {
    case rect(RectAnnotation)
    case arrow(ArrowAnnotation)
    case blur(BlurAnnotation)
    case stamp(StampAnnotation)
    case text(TextAnnotation)
    case marker(MarkerAnnotation)
    case unknown(JSONValue)

    private struct TypeKey: Codable {
        var type: String?
    }

    public init(from decoder: Decoder) throws {
        // Peek the discriminator, then decode the matching payload from the same
        // container. Anything unrecognized (or malformed for its claimed type)
        // falls back to a verbatim JSONValue.
        let raw = try JSONValue(from: decoder)
        guard case .object(let obj) = raw, case .string(let type)? = obj["type"] else {
            self = .unknown(raw)
            return
        }
        do {
            switch type {
            case "rect": self = .rect(try RectAnnotation(from: decoder))
            case "arrow": self = .arrow(try ArrowAnnotation(from: decoder))
            case "blur": self = .blur(try BlurAnnotation(from: decoder))
            case "stamp": self = .stamp(try StampAnnotation(from: decoder))
            case "text": self = .text(try TextAnnotation(from: decoder))
            case "marker": self = .marker(try MarkerAnnotation(from: decoder))
            default: self = .unknown(raw)
            }
        } catch {
            self = .unknown(raw)
        }
    }

    private var discriminator: String? {
        switch self {
        case .rect: "rect"
        case .arrow: "arrow"
        case .blur: "blur"
        case .stamp: "stamp"
        case .text: "text"
        case .marker: "marker"
        case .unknown: nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Unknown payloads re-encode verbatim (single-value); known ones write the
        // discriminator, then the payload merges its keys into the same keyed
        // container (Foundation keyed containers share storage).
        if case .unknown(let raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(discriminator, forKey: DynamicKey("type"))
        switch self {
        case .rect(let a): try a.encode(to: encoder)
        case .arrow(let a): try a.encode(to: encoder)
        case .blur(let a): try a.encode(to: encoder)
        case .stamp(let a): try a.encode(to: encoder)
        case .text(let a): try a.encode(to: encoder)
        case .marker(let a): try a.encode(to: encoder)
        case .unknown: break
        }
    }

    public var id: String {
        switch self {
        case .rect(let a): a.id
        case .arrow(let a): a.id
        case .blur(let a): a.id
        case .stamp(let a): a.id
        case .text(let a): a.id
        case .marker(let a): a.id
        case .unknown(let raw):
            if case .object(let o) = raw, case .string(let s)? = o["id"] { s } else { "" }
        }
    }
}
