import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Transient failures are retried; everything else fails fast; a dropped stream is
/// reported as the network problem it is.
final class TransportRobustnessTests: XCTestCase {

    typealias Reply = SopValidationTests.Script
    private let good = #"{"title":"A Real Title","intro":null,"steps":[{"stepNumber":1,"caption":"Open Settings","body":"Click the gear.","sectionHeading":null,"sectionBody":null}]}"#
    private func ok() -> ([String], ResponseHead) { (sseLines(json: good), ResponseHead(status: 200)) }
    private func status(_ code: Int, _ headers: [String: String] = [:]) -> ([String], ResponseHead) {
        ([], ResponseHead(status: code, headers: headers))
    }

    private func service(_ script: Reply, progress: ProgressLog? = nil) -> SopService {
        var svc = SopService(client: ClaudeClient(transport: MockTransport(streamHandler: script.next)),
                             keyStore: StubKeyStore())
        svc.sleep = { _ in }
        return svc
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [SopProgress] = []
        func add(_ p: SopProgress) { lock.lock(); items.append(p); lock.unlock() }
        var all: [SopProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func generate(_ svc: SopService, _ log: ProgressLog? = nil) async throws -> SopEditPlan {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        return try await svc.generate(dir: dir, manifest: m, settings: SopSettings(), onProgress: { log?.add($0) })
    }

    // MARK: A dropped stream is a connection problem

    /// The stream just stops: some text, no stop reason, no message_stop. That used
    /// to surface as "Claude returned malformed SOP data" — blaming the model for a
    /// network failure — and was never retried.
    func testAStreamThatStopsMidwayIsAConnectionFailureNotMalformedOutput() async throws {
        let truncated = [
            #"data: {"type":"message_start"}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"title\":\"A Re"}}"#,
        ]
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (truncated, ResponseHead(status: 200)) }))
        do {
            _ = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in })
            XCTFail("a truncated stream must not decode")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .connection)
        }
    }

    // MARK: Transient failures are retried

    func testAnOverloadIsRetriedAndTheGenerationSucceeds() async throws {
        let script = Reply([status(529), ok()])
        let log = ProgressLog()
        let plan = try await generate(service(script), log)
        XCTAssertEqual(plan.steps.first?.caption, "Open Settings")
        XCTAssertEqual(script.count, 2)
        XCTAssertTrue(log.all.contains(.waiting(seconds: 2)), "the user is told it is retrying")
    }

    func testADroppedConnectionIsRetried() async throws {
        let truncated = ([#"data: {"type":"message_start"}"#], ResponseHead(status: 200))
        let script = Reply([truncated, ok()])
        let plan = try await generate(service(script))
        XCTAssertEqual(plan.steps.first?.caption, "Open Settings")
    }

    func testTwoRetriesThenTheErrorIsSurfaced() async throws {
        let script = Reply([status(529), status(529), status(529), ok()])
        do {
            _ = try await generate(service(script))
            XCTFail("three overloads in a row must surface")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .overloaded)
        }
        XCTAssertEqual(script.count, 3, "the first attempt plus two retries, no more")
    }

    func testAServerErrorIsRetried() async throws {
        let script = Reply([status(503), ok()])
        _ = try await generate(service(script))
        XCTAssertEqual(script.count, 2)
    }

    func testAMidStreamApiErrorIsRetriedLikeAServerError() async throws {
        let err = ([#"data: {"type":"message_start"}"#,
                    #"data: {"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#],
                   ResponseHead(status: 200))
        let script = Reply([err, ok()])
        _ = try await generate(service(script))
        XCTAssertEqual(script.count, 2)
    }

    func testAServerErrorThatSaysDoNotRetryIsNotRetried() async throws {
        let script = Reply([status(503, ["x-should-retry": "false"]), ok()])
        do { _ = try await generate(service(script)); XCTFail("must surface") } catch {}
        XCTAssertEqual(script.count, 1)
    }

    /// Every request asks for the credential afresh. Resolved once per generation,
    /// a federated token could expire across a run that is now up to three
    /// requests plus backoff.
    func testEachRequestResolvesTheCredentialAgain() async throws {
        final class Counting: CredentialProvider, @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            var calls: Int { lock.withLock { n } }
            func credential() async throws -> ClaudeCredential {
                lock.withLock { n += 1 }
                return .apiKey("sk-ant-test")
            }
            func status() async -> CredentialStatus { await StoredKeyCredentialProvider(keyStore: StubKeyStore()).status() }
        }
        let creds = Counting()
        let script = Reply([status(529), ok()])
        var svc = SopService(client: ClaudeClient(transport: MockTransport(streamHandler: script.next)), credentials: creds)
        svc.sleep = { _ in }
        _ = try await generate(svc)
        XCTAssertEqual(script.count, 2)
        XCTAssertGreaterThanOrEqual(creds.calls, 1 + script.count,
                                    "one early fail-fast check, then one per request")
    }

    // MARK: Rate limits: wait a short one out, surface a long one

    func testAShortRateLimitIsWaitedOut() async throws {
        let script = Reply([status(429, ["retry-after": "3"]), ok()])
        let log = ProgressLog()
        _ = try await generate(service(script), log)
        XCTAssertEqual(script.count, 2)
        XCTAssertTrue(log.all.contains(.waiting(seconds: 3)), "retry-after is honoured, not undercut")
    }

    /// Past the in-app wait ceiling the user is better told "try again in about
    /// 60s" than left watching a spinner for a minute.
    func testALongRateLimitIsSurfacedNotWaitedOut() async throws {
        let script = Reply([status(429, ["retry-after": "60"]), ok()])
        do {
            _ = try await generate(service(script))
            XCTFail("a long rate limit must surface")
        } catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .rateLimited)
        }
        XCTAssertEqual(script.count, 1)
    }

    // MARK: Everything else fails fast

    func testANonTransientFailureIsNotRetried() async throws {
        for (code, kind) in [(401, ClaudeError.Kind.invalidKey), (402, .billing), (400, .api)] {
            let script = Reply([status(code), ok()])
            do {
                _ = try await generate(service(script))
                XCTFail("\(code) must not succeed")
            } catch {
                XCTAssertEqual((error as? ClaudeError)?.kind, kind, "\(code)")
            }
            XCTAssertEqual(script.count, 1, "\(code) must not be retried")
        }
    }

    /// The guard itself: the run is already cancelled when a retryable error comes
    /// back, and the backoff does not throw on cancel. Only the `Task.isCancelled`
    /// check stands between that and a second request. (The test below cancels
    /// DURING the backoff, where `Task.sleep` throws on its own, so it cannot tell
    /// whether the check exists.)
    func testACancelledRunDoesNotRetryEvenIfTheBackoffWouldNotNotice() async throws {
        let script = Reply([status(529), ok()])
        let svc = service(script)   // no-op sleep: cancellation is invisible to it
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await svc.generate(dir: dir, manifest: m, settings: SopSettings(), onProgress: { _ in })
        }
        do { _ = try await task.value; XCTFail("a cancelled run must not succeed") } catch {}
        XCTAssertLessThanOrEqual(script.count, 1, "a cancelled run makes no retry")
    }

    /// URLSession reports a cancelled request as a URLError, which arrives as
    /// `.connection` — a retryable error. A cancel must end the run, not retry it.
    func testACancelDuringTheBackoffDoesNotRetry() async throws {
        let script = Reply([status(529), ok()])
        var svc = SopService(client: ClaudeClient(transport: MockTransport(streamHandler: script.next)),
                             keyStore: StubKeyStore())
        svc.sleep = { _ in try await Task.sleep(for: .seconds(30)) }
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let task = Task { try await svc.generate(dir: dir, manifest: m, settings: SopSettings(), onProgress: { _ in }) }
        while script.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("a cancelled run must not succeed") } catch {}
        XCTAssertEqual(script.count, 1, "no request after the cancel")
    }
}
