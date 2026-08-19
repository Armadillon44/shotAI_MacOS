import Foundation
import ShotModel

/// Progress events emitted during generation (for the UI).
public enum SopProgress: Sendable, Equatable {
    case preparing
    case thinking
    case writing(chars: Int)
    case done
}

/// Status + response headers. Headers are carried across the transport seam
/// because the status ALONE cannot classify a failure: under federated auth
/// (#69) every user shares one workspace's limits, so a 429 may mean "slow down
/// for a moment" or "the shared budget is spent" — and Anthropic publishes no
/// distinct error type for the latter. `retry-after` is what separates them.
public struct ResponseHead: Sendable, Equatable {
    public let status: Int
    /// Lowercased field names (HTTP headers are case-insensitive).
    public let headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Seconds to wait, when the server said. Only the delta-seconds form is
    /// parsed; the HTTP-date form is treated as absent, which classifies as a
    /// hard stop — the safe direction, since the cost of not retrying a
    /// retryable request is a manual re-run, and the cost of retrying an
    /// unretryable one is telling the user to wait for something that cannot
    /// succeed.
    public var retryAfter: TimeInterval? {
        guard let raw = header("retry-after")?.trimmingCharacters(in: .whitespaces),
              let secs = TimeInterval(raw) else { return nil }
        return secs
    }

    /// Anthropic's explicit "don't bother" signal, when present.
    public var shouldRetry: Bool? {
        guard let raw = header("x-should-retry")?.lowercased() else { return nil }
        return raw == "true" ? true : (raw == "false" ? false : nil)
    }

    /// The only handle support can act on. Surfaced on every failure.
    public var requestId: String? { header("request-id") }
}

/// Seam over the network so tests can feed canned responses/SSE. The real
/// implementation is `URLSessionTransport`.
public protocol ClaudeTransport: Sendable {
    /// Unary request → (body, status + headers).
    func data(for request: URLRequest) async throws -> (Data, ResponseHead)
    /// Streaming request → (line stream of the SSE body, status + headers).
    /// The head is available once headers arrive, before the body is consumed.
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, ResponseHead)
}

/// Default transport backed by URLSession. A URLError (offline, DNS, TLS) is
/// surfaced as `ClaudeError.connection`.
public struct URLSessionTransport: ClaudeTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private static func head(_ response: URLResponse?) -> ResponseHead {
        guard let http = response as? HTTPURLResponse else { return ResponseHead(status: 0) }
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, let value = v as? String { fields[key] = value }
        }
        return ResponseHead(status: http.statusCode, headers: fields)
    }

    public func data(for request: URLRequest) async throws -> (Data, ResponseHead) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, Self.head(response))
        } catch is URLError {
            throw ClaudeError.connection
        }
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, ResponseHead) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is URLError {
            throw ClaudeError.connection
        }
        let head = Self.head(response)
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
        return (stream, head)
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
        let (data, head) = try await transport.data(for: req)
        guard head.status == 200 else { throw ClaudeError.from(head: head, message: Self.apiMessage(data)) }
    }

    // MARK: Token count (POST /v1/messages/count_tokens)

    public func countTokens(apiKey: String, model: SopModelId, system: [[String: Any]], messages: [[String: Any]]) async throws -> Int {
        let body: [String: Any] = ["model": model.rawValue, "system": system, "messages": messages]
        let req = try makeRequest(path: "/v1/messages/count_tokens", apiKey: apiKey, method: "POST", jsonBody: body)
        let (data, head) = try await transport.data(for: req)
        guard head.status == 200 else { throw ClaudeError.from(head: head, message: Self.apiMessage(data)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["input_tokens"] as? Int else { throw ClaudeError.malformed }
        return n
    }

    // MARK: Generation (streaming POST /v1/messages, structured output)

    /// Stream a vision + structured-output request; accumulate the JSON text,
    /// track the stop reason, and decode the edit plan. Progress is reported via
    /// `onProgress`. Throws a friendly ClaudeError on refusal/cutoff/malformed.
    func streamEditPlan(apiKey: String, body: [String: Any], onProgress: @Sendable (SopProgress) -> Void) async throws -> SopEditRaw {
        let req = try makeRequest(path: "/v1/messages", apiKey: apiKey, method: "POST", jsonBody: body)
        let (lines, head) = try await transport.stream(for: req)

        // Non-200: the body is a JSON error, not SSE — drain + surface it.
        if head.status != 200 {
            var raw = ""
            for try await line in lines {
                raw += line.hasPrefix("data:") ? String(line.dropFirst(5)) : line
            }
            let msg = Self.apiMessage(Data(raw.utf8))
            throw ClaudeError.from(head: head, message: msg)
        }

        var text = ""
        var chars = 0
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
            case "error":
                // Anthropic can emit an error event mid-stream on a 200 connection
                // (e.g. overloaded_error under load). Surface the real, actionable
                // error instead of falling through to a generic "no content".
                let err = ev["error"] as? [String: Any]
                let f = ApiFailure(message: err?["message"] as? String, requestId: head.requestId)
                switch err?["type"] as? String {
                case "overloaded_error": throw ClaudeError.overloaded
                // Constructed directly rather than via `from`: an SSE error event
                // on an established 200 is Anthropic shedding load, which IS
                // transient, and it carries no retry-after to classify with.
                case "rate_limit_error": throw ClaudeError.rateLimited(f)
                default: throw ClaudeError.api(status: 0, failure: f)
                }
            default:
                break
            }
        }

        if stopReason == "refusal" { throw ClaudeError.refusal }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw stopReason == "max_tokens" ? ClaudeError.cutoff : ClaudeError.noContent }
        guard let decoded = try? JSONDecoder().decode(SopEditRaw.self, from: Data(trimmed.utf8)) else {
            throw stopReason == "max_tokens" ? ClaudeError.cutoff : ClaudeError.malformed
        }
        return decoded
    }
}
