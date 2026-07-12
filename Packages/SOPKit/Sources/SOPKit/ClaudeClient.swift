import Foundation
import ShotModel

/// Progress events emitted during generation (for the UI).
public enum SopProgress: Sendable, Equatable {
    case preparing
    case thinking
    case writing(chars: Int)
    case done
}

/// Seam over the network so tests can feed canned responses/SSE. The real
/// implementation is `URLSessionTransport`.
public protocol ClaudeTransport: Sendable {
    /// Unary request → (body, HTTP status).
    func data(for request: URLRequest) async throws -> (Data, Int)
    /// Streaming request → (line stream of the SSE body, HTTP status). Status is
    /// available once headers arrive, before the body is consumed.
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int)
}

/// Default transport backed by URLSession. A URLError (offline, DNS, TLS) is
/// surfaced as `ClaudeError.connection`.
public struct URLSessionTransport: ClaudeTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is URLError {
            throw ClaudeError.connection
        }
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is URLError {
            throw ClaudeError.connection
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: (error is URLError) ? ClaudeError.connection : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, status)
    }
}

/// Low-level Anthropic Messages API client. Egress is PINNED to api.anthropic.com
/// (no env-var base-URL override) so a poisoned environment can't redirect the key
/// or the screenshots to another host. Ported from claude-service.ts.
public struct ClaudeClient: Sendable {
    /// Pinned host — shotAI only ever talks to the real API.
    static let baseURL = URL(string: "https://api.anthropic.com")!
    static let anthropicVersion = "2023-06-01"

    let transport: ClaudeTransport
    public init(transport: ClaudeTransport = URLSessionTransport()) { self.transport = transport }

    private func makeRequest(path: String, apiKey: String, method: String, jsonBody: [String: Any]?) throws -> URLRequest {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    /// Pull `error.message` out of an Anthropic error body (best-effort).
    private static func apiMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }

    // MARK: Model check (cheap key/model validation — GET /v1/models/{id})

    public func checkModel(apiKey: String, model: SopModelId) async throws {
        let req = try makeRequest(path: "/v1/models/\(model.rawValue)", apiKey: apiKey, method: "GET", jsonBody: nil)
        let (data, status) = try await transport.data(for: req)
        guard status == 200 else { throw ClaudeError.from(status: status, message: Self.apiMessage(data)) }
    }

    // MARK: Token count (POST /v1/messages/count_tokens)

    public func countTokens(apiKey: String, model: SopModelId, system: [[String: Any]], messages: [[String: Any]]) async throws -> Int {
        let body: [String: Any] = ["model": model.rawValue, "system": system, "messages": messages]
        let req = try makeRequest(path: "/v1/messages/count_tokens", apiKey: apiKey, method: "POST", jsonBody: body)
        let (data, status) = try await transport.data(for: req)
        guard status == 200 else { throw ClaudeError.from(status: status, message: Self.apiMessage(data)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["input_tokens"] as? Int else { throw ClaudeError.malformed }
        return n
    }

    // MARK: Generation (streaming POST /v1/messages, structured output)

    /// Stream a vision + structured-output request; accumulate the JSON text,
    /// track the stop reason, and decode the edit plan. Progress is reported via
    /// `onProgress`. Throws a friendly ClaudeError on refusal/cutoff/malformed.
    func streamEditPlan(
        apiKey: String, body: [String: Any],
        onProgress: @Sendable (SopProgress) -> Void,
        debugSink: (@Sendable (_ rawText: String, _ stopReason: String?, _ textDeltas: Int) -> Void)? = nil
    ) async throws -> SopEditRaw {
        let req = try makeRequest(path: "/v1/messages", apiKey: apiKey, method: "POST", jsonBody: body)
        let (lines, status) = try await transport.stream(for: req)

        // Non-200: the body is a JSON error, not SSE — drain + surface it.
        if status != 200 {
            var raw = ""
            for try await line in lines {
                raw += line.hasPrefix("data:") ? String(line.dropFirst(5)) : line
            }
            let msg = Self.apiMessage(Data(raw.utf8))
            throw ClaudeError.from(status: status, message: msg)
        }

        var text = ""
        var chars = 0
        var textDeltas = 0
        var lastEmit = Date.distantPast
        var stopReason: String?

        for try await line in lines {
            guard line.hasPrefix("data:") else { continue }  // ignore `event:`/blank lines
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let ev = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = ev["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                if let block = ev["content_block"] as? [String: Any], let bt = block["type"] as? String {
                    if bt == "thinking" { onProgress(.thinking) }
                    else if bt == "text" { onProgress(.writing(chars: chars)) }
                }
            case "content_block_delta":
                if let delta = ev["delta"] as? [String: Any] {
                    if (delta["type"] as? String) == "text_delta", let t = delta["text"] as? String {
                        text += t
                        chars += t.count
                        textDeltas += 1
                        let now = Date()
                        if now.timeIntervalSince(lastEmit) > 0.25 {
                            lastEmit = now
                            onProgress(.writing(chars: chars))
                        }
                    }
                }
            case "message_delta":
                if let delta = ev["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }
            default:
                break
            }
        }

        debugSink?(text, stopReason, textDeltas)
        if stopReason == "refusal" { throw ClaudeError.refusal }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw stopReason == "max_tokens" ? ClaudeError.cutoff : ClaudeError.noContent }
        guard let decoded = try? JSONDecoder().decode(SopEditRaw.self, from: Data(trimmed.utf8)) else {
            throw stopReason == "max_tokens" ? ClaudeError.cutoff : ClaudeError.malformed
        }
        return decoded
    }
}
