import Foundation
@testable import SOPKit
import ShotModel

/// A valid 1×1 PNG (magic-byte-clean) for seeding shot steps in tests.
let png1x1 = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

/// Network seam stub — canned unary + SSE responses.
struct MockTransport: ClaudeTransport {
    var dataHandler: @Sendable (URLRequest) -> (Data, Int) = { _ in (Data("{}".utf8), 200) }
    var streamHandler: @Sendable (URLRequest) -> ([String], Int) = { _ in ([], 200) }

    func data(for request: URLRequest) async throws -> (Data, Int) { dataHandler(request) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        let (lines, status) = streamHandler(request)
        let s = AsyncThrowingStream<String, Error> { c in
            for l in lines { c.yield(l) }
            c.finish()
        }
        return (s, status)
    }
}

/// In-memory key store for service tests.
struct StubKeyStore: ApiKeyStore {
    var stored: String? = "sk-test-key"
    func key() -> String? { stored }
    func status() -> ApiKeyStatus {
        stored != nil ? ApiKeyStatus(hasKey: true, source: .stored) : ApiKeyStatus(hasKey: false, source: .none)
    }
    func set(_ key: String) throws {}
    func clear() throws {}
}

/// Wrap SopEditPlan JSON into a minimal valid SSE line sequence.
func sseLines(json: String, stopReason: String = "end_turn") -> [String] {
    [
        #"data: {"type":"message_start"}"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(jsonStringLiteral(json))}}",
        #"data: {"type":"content_block_stop","index":0}"#,
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\"}}",
        #"data: {"type":"message_stop"}"#,
    ]
}

/// JSON-encode a string as a quoted literal (so embedding JSON-in-JSON is valid).
func jsonStringLiteral(_ s: String) -> String {
    let data = try! JSONEncoder().encode(s)
    return String(decoding: data, as: UTF8.self)
}

/// Create a temp project with `shots` shot steps (each a 1×1 PNG). Returns the
/// store + the project path + resolved dir.
func makeProject(shots: Int) async throws -> (store: ProjectStore, path: String, dir: String) {
    let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sopkit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
    let summary = try await store.createProject(title: "Test SOP")
    for _ in 0..<shots {
        _ = try await store.importImageStep(at: summary.path, atIndex: nil, imageData: png1x1)
    }
    let opened = try await store.openProject(at: summary.path)
    return (store, summary.path, opened.dir)
}
