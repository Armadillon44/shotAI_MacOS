import Foundation

/// A JSON object that serializes its members in the order they are written.
///
/// Structured outputs emit an object's properties in the order the SCHEMA declares
/// them: "properties in objects maintain their defined ordering from your schema"
/// (Anthropic structured-outputs docs, "Property ordering"). The schema used to be
/// a Swift dictionary, which has no order, and Swift seeds its hashing per process
/// — so the schema reached the API in a different property order on every launch
/// (measured: four launches, four orders), and Claude wrote each step's fields in
/// that order. In some launches it composed a step's caption and body BEFORE
/// committing to which `stepNumber` they were for.
///
/// `.sortedKeys` is not the fix it was for project.json (#127): alphabetical puts
/// `stepNumber` LAST in each step and `title` last at the root. The order here is
/// deliberate and is pinned byte-for-byte by a test.
struct OrderedObject {
    let members: [(key: String, value: Any)]

    init(_ members: KeyValuePairs<String, Any>) {
        self.members = members.map { ($0.key, $0.value) }
    }

    init(pairs: [(String, Any)]) {
        self.members = pairs.map { (key: $0.0, value: $0.1) }
    }

    subscript(key: String) -> Any? { members.first { $0.key == key }?.value }
}

/// The request body encoder. Deterministic by construction: an `OrderedObject`
/// is written in declaration order and every plain dictionary in sorted key order,
/// so the same request is the same bytes in every process. Leaves (strings,
/// numbers, booleans, null) go through `JSONSerialization`, which already escapes
/// them correctly and keeps a Bool a Bool.
enum RequestJSON {
    static func data(_ value: Any) throws -> Data {
        var out = Data()
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: Any, into out: inout Data) throws {
        switch value {
        case let o as OrderedObject:
            try object(o.members.map { ($0.key, $0.value) }, into: &out)
        case let d as [String: Any]:
            try object(d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, into: &out)
        case let a as [Any]:
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try write(v, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        default:
            out.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
    }

    private static func object(_ members: [(String, Any)], into out: inout Data) throws {
        out.append(UInt8(ascii: "{"))
        for (i, (k, v)) in members.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(try JSONSerialization.data(withJSONObject: k, options: [.fragmentsAllowed]))
            out.append(UInt8(ascii: ":"))
            try write(v, into: &out)
        }
        out.append(UInt8(ascii: "}"))
    }
}

/// The same value with every `OrderedObject` flattened to a plain dictionary, for
/// code that inspects a schema by key rather than sending it.
func plainJSON(_ value: Any) -> Any {
    switch value {
    case let o as OrderedObject:
        return Dictionary(o.members.map { ($0.key, plainJSON($0.value)) }, uniquingKeysWith: { a, _ in a })
    case let d as [String: Any]:
        return d.mapValues(plainJSON)
    case let a as [Any]:
        return a.map(plainJSON)
    default:
        return value
    }
}
