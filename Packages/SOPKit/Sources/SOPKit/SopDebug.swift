import Foundation

// Best-effort local diagnostics for SOP generation, written under the project's
// export/.render/ folder (regenerable, never egressed). Lets a bad generation be
// inspected after the fact: the exact request (base64 image bytes elided so it
// stays readable) and the raw model response + stop reason. Temporary debug aid.
enum SopDebug {
    private static func renderDir(_ dir: String) -> String {
        ((dir as NSString).appendingPathComponent("export") as NSString).appendingPathComponent(".render")
    }

    private static func write(_ dir: String, _ name: String, _ contents: String) {
        let rd = renderDir(dir)
        try? FileManager.default.createDirectory(atPath: rd, withIntermediateDirectories: true)
        try? contents.write(toFile: (rd as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Dump the request body with image `data` fields replaced by a size marker.
    static func writeRequest(dir: String, body: [String: Any]) {
        let safe = elideImages(body)
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]) else { return }
        write(dir, "sop-request.json", String(decoding: data, as: UTF8.self))
    }

    /// Dump the raw model response text + a metadata header.
    static func writeResponse(dir: String, rawText: String, stopReason: String?, textDeltas: Int) {
        let header = """
        // stop_reason: \(stopReason ?? "nil")
        // text_deltas: \(textDeltas)
        // raw_length: \(rawText.count)
        //
        """
        write(dir, "sop-response.txt", header + "\n" + rawText)
    }

    /// Recursively replace base64 image `data` strings with "<base64 N chars>".
    private static func elideImages(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            for (k, v) in dict {
                if k == "data", let s = v as? String, s.count > 200 {
                    dict[k] = "<base64 \(s.count) chars>"
                } else {
                    dict[k] = elideImages(v)
                }
            }
            return dict
        }
        if let arr = value as? [Any] {
            return arr.map { elideImages($0) }
        }
        return value
    }
}
