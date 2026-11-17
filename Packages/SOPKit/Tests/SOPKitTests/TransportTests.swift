import Foundation
import XCTest
@testable import SOPKit

/// The real URLSession transport: nothing a request carries is kept on disk, and
/// no request follows a redirect to another host.
final class TransportTests: XCTestCase {

    // MARK: Nothing on disk

    /// No URLCache at all: a cache policy on the request would not keep the
    /// request itself off disk.
    func testThePinnedSessionKeepsNothing() {
        for cfg in [URLSessionTransport.pinnedConfiguration(), URLSessionTransport.pinnedSession.configuration] {
            XCTAssertNil(cfg.urlCache, "no URLCache: it stores the request beside the response")
            XCTAssertNil(cfg.httpCookieStorage)
            XCTAssertFalse(cfg.httpShouldSetCookies)
            XCTAssertEqual(cfg.httpCookieAcceptPolicy, .never)
            XCTAssertNil(cfg.urlCredentialStorage)
            XCTAssertEqual(cfg.requestCachePolicy, .reloadIgnoringLocalCacheData)
        }
    }

    /// Every request goes through it: the default transport, and so the default client.
    func testTheDefaultTransportUsesThePinnedSession() throws {
        XCTAssertTrue(URLSessionTransport().session === URLSessionTransport.pinnedSession)
        let client = try XCTUnwrap(ClaudeClient().transport as? URLSessionTransport)
        XCTAssertTrue(client.session === URLSessionTransport.pinnedSession)
    }

    func testTheOldDiskCacheIsRemovedAndNothingElse() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sopkit-cache-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/0A1B", "keep.me"] {
            XCTAssertTrue(fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8)))
        }
        // A symlink at one of the names is removed itself; its target is untouched.
        let outside = fm.temporaryDirectory.appendingPathComponent("sopkit-target-\(UUID().uuidString)")
        XCTAssertTrue(fm.createFile(atPath: outside.path, contents: Data("mine".utf8)))
        defer { try? fm.removeItem(at: outside) }
        try fm.removeItem(at: dir.appendingPathComponent("Cache.db-shm"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Cache.db-shm"), withDestinationURL: outside)

        let removed = URLSessionTransport.removeLegacyDiskCache(in: dir)

        XCTAssertEqual(Set(removed), ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), ["keep.me"])
        XCTAssertEqual(try Data(contentsOf: outside), Data("mine".utf8), "a symlink's target is never followed")
        XCTAssertEqual(URLSessionTransport.removeLegacyDiskCache(in: dir), [], "nothing left: nothing removed")
    }

    // MARK: Redirects

    private func transport() -> URLSessionTransport {
        let cfg = URLSessionTransport.pinnedConfiguration()
        cfg.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(session: URLSessionTransport.makeSession(configuration: cfg))
    }

    private func get(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com\(path)")!)
        req.setValue("sk-ant-api-SENTINEL", forHTTPHeaderField: "x-api-key")
        return req
    }

    override func setUp() { StubProtocol.reset() }

    /// URLSession drops `Authorization` on a host change but keeps `x-api-key`, so
    /// a followed redirect would hand the key to the other host.
    func testARedirectToAnotherHostIsNotFollowed() async throws {
        let (_, head) = try await transport().data(for: get("/redirect/elsewhere"))
        XCTAssertEqual(head.status, 302, "the caller sees the redirect, not the other host's answer")
        XCTAssertFalse(StubProtocol.hosts.contains("elsewhere.example"), "the other host was never contacted")
    }

    func testARedirectToPlainHTTPIsNotFollowed() async throws {
        let (_, head) = try await transport().data(for: get("/redirect/insecure"))
        XCTAssertEqual(head.status, 302)
        XCTAssertEqual(StubProtocol.paths, ["/redirect/insecure"])
    }

    func testARedirectOnTheSameHostIsFollowed() async throws {
        let (data, head) = try await transport().data(for: get("/redirect/same"))
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
        XCTAssertEqual(StubProtocol.paths, ["/redirect/same", "/ok"])
    }

    func testAResponseFromAnotherHostIsNeverRead() async throws {
        do {
            _ = try await transport().data(for: get("/answered-by/elsewhere"))
            XCTFail("a response from another host must not be returned")
        } catch ClaudeError.malformed {}
        do {
            _ = try await transport().stream(for: get("/answered-by/elsewhere"))
            XCTFail("nor streamed")
        } catch ClaudeError.malformed {}
    }
}

/// Answers by path, standing in for the network. Every request it sees is
/// recorded, so a test can tell whether a redirect was followed.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URL] = []

    static func reset() { lock.withLock { seen = [] } }
    static var hosts: [String] { lock.withLock { seen.compactMap(\.host) } }
    static var paths: [String] { lock.withLock { seen.map(\.path) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.seen.append(url) }
        func respond(_ status: Int, from responder: URL = url, headers: [String: String] = [:], body: String = "") {
            let r = HTTPURLResponse(url: responder, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(body.utf8))
            client.urlProtocolDidFinishLoading(self)
        }
        func redirect(to target: String) {
            let r = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: r)
            // Reached only when the redirect is refused: the 302 is the answer.
            client.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        }
        switch url.path {
        case "/redirect/elsewhere": redirect(to: "https://elsewhere.example/v1/models")
        case "/redirect/insecure": redirect(to: "http://api.anthropic.com/ok")
        case "/redirect/same": redirect(to: "https://api.anthropic.com/ok")
        case "/answered-by/elsewhere": respond(200, from: URL(string: "https://elsewhere.example/x")!, body: "{}")
        case "/ok": respond(200, body: "{}")
        default: respond(404)
        }
    }

    override func stopLoading() {}
}
