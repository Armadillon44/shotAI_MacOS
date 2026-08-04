import Foundation
import ShotModel

/// One published release, reduced to what the notifier shows.
///
/// Note what is NOT here: the asset's `browser_download_url`. This package is
/// notify-only by design (issue #62's scope boundary), so the model deliberately
/// gives no caller anything to download from. The user is pointed at
/// `releasePage`, where the browser applies the normal Gatekeeper quarantine — a
/// URLSession-fetched DMG arrives *unquarantined* for a non-sandboxed app, which
/// would silently skip that wall on a build that isn't notarized yet.
public struct ReleaseInfo: Sendable, Equatable {
    /// The raw tag (`"v1.1.3"`), for logging and the skip list.
    public let tag: String
    public let version: SemanticVersion
    /// Human title from the release, falling back to the tag.
    public let name: String
    /// Markdown release notes (`body`), trimmed. May be empty.
    public let notes: String
    /// The release's HTML page — where "Download" sends the user.
    public let releasePage: URL
    public let publishedAt: Date?
    /// Display-only details of the `.dmg` asset, when the release has one.
    public let assetName: String?
    public let assetSize: Int?

    public init(
        tag: String, version: SemanticVersion, name: String, notes: String,
        releasePage: URL, publishedAt: Date? = nil,
        assetName: String? = nil, assetSize: Int? = nil
    ) {
        self.tag = tag
        self.version = version
        self.name = name
        self.notes = notes
        self.releasePage = releasePage
        self.publishedAt = publishedAt
        self.assetName = assetName
        self.assetSize = assetSize
    }

    /// `"shotAI-1.1.3.dmg · 6.6 MB"`, or nil when the release has no asset.
    public var assetSummary: String? {
        guard let assetName else { return nil }
        guard let assetSize, assetSize > 0 else { return assetName }
        let mb = Double(assetSize) / 1_048_576
        return String(format: "%@ · %.1f MB", assetName, mb)
    }
}

public enum UpdateFeedError: Error, Equatable, Sendable {
    /// Offline, DNS, TLS, timeout — anything URLSession reports as a URLError.
    case connection
    /// 403/429. `resetAt` is `x-ratelimit-reset` when the server sent one.
    case rateLimited(resetAt: Date?)
    /// Any other non-2xx.
    case http(status: Int)
    /// 2xx whose body wasn't the shape we expect.
    case malformedResponse
    /// A redirect tried to leave api.github.com.
    case unexpectedRedirect
}

/// Seam over the network so tests run headless. `URLSessionFeedTransport` is the
/// real one.
public protocol UpdateFeedTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport on an EPHEMERAL configuration: no disk cache, no cookie
/// store, no credential store. The request carries nothing identifying beyond
/// the IP and a `shotAI/<version>` User-Agent.
public struct URLSessionFeedTransport: UpdateFeedTransport {
    private let session: URLSession
    private let pin: RedirectPin

    public init(allowedHost: String = UpdateFeed.host, timeout: TimeInterval = 15) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.pin = RedirectPin(allowedHost: allowedHost)
        self.session = URLSession(configuration: cfg, delegate: pin, delegateQueue: nil)
    }

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateFeedError.malformedResponse }
            // Defense in depth behind the redirect pin: whatever we ended up
            // reading, refuse it if it didn't come from the pinned host.
            guard http.url?.host?.lowercased() == pin.allowedHost else {
                throw UpdateFeedError.unexpectedRedirect
            }
            return (data, http)
        } catch let e as UpdateFeedError {
            throw e
        } catch is URLError {
            throw UpdateFeedError.connection
        }
    }
}

/// Refuses any redirect that would leave the pinned host. Same posture as
/// `ClaudeClient`'s pinned base URL: a hijacked DNS answer or a redirect must not
/// be able to point the app's "is there an update" question at another server.
private final class RedirectPin: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowedHost: String
    init(allowedHost: String) { self.allowedHost = allowedHost.lowercased() }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.host?.lowercased() == allowedHost {
            completionHandler(request)
        } else {
            Log.updates.error("refused a redirect off the pinned update host")
            completionHandler(nil)  // stop here; the caller sees the 3xx response
        }
    }
}

/// Reads the newest published release from the GitHub Releases API.
///
/// `/releases/latest` excludes prereleases server-side, so our `v1.0.0-rc*` tags
/// are filtered out for free. **That is load-bearing:** an rc published without
/// `prerelease: true` would be offered to every user. It's on the release
/// checklist in docs/DISTRIBUTION.md.
public struct UpdateFeed: Sendable {
    /// Pinned host — the checker only ever talks to the real GitHub API.
    public static let host = "api.github.com"
    public static let owner = "Armadillon44"
    public static let repo = "shotAI_MacOS"
    /// Caps on the remote strings we keep. Generous for real release notes
    /// (1.1.2's are ~2.7 KB) and small enough that a hostile body can't bloat
    /// the popover or the persisted state.
    static let maxNotesChars = 20_000
    static let maxNameChars = 200

    static var latestReleaseURL: URL {
        URL(string: "https://\(host)/repos/\(owner)/\(repo)/releases/latest")!
    }

    let transport: UpdateFeedTransport
    let userAgent: String

    public init(transport: UpdateFeedTransport = URLSessionFeedTransport(), appVersion: String) {
        self.transport = transport
        // GitHub requires a User-Agent. Ours carries only the app name + version.
        self.userAgent = "shotAI/\(appVersion) (macOS; +https://github.com/\(Self.owner)/\(Self.repo))"
    }

    public func fetchLatest() async throws -> ReleaseInfo {
        var req = URLRequest(url: Self.latestReleaseURL)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, http) = try await transport.get(req)
        switch http.statusCode {
        case 200...299:
            guard let info = Self.parse(data) else { throw UpdateFeedError.malformedResponse }
            return info
        case 403, 429:
            throw UpdateFeedError.rateLimited(resetAt: Self.rateLimitReset(http))
        default:
            throw UpdateFeedError.http(status: http.statusCode)
        }
    }

    /// `x-ratelimit-reset` is epoch seconds. Parse ONLY — deliberately no
    /// "is it in the future?" test here. The feed must not read the wall clock:
    /// the checker owns time (it takes an injected `now` so the throttle is
    /// deterministic under test) and already clamps a past or absurd reset into
    /// its own backoff floor/ceiling. Two clock sources is how a throttle bug hides.
    static func rateLimitReset(_ http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "x-ratelimit-reset"),
              let epoch = Double(raw.trimmingCharacters(in: .whitespaces)), epoch > 0
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Whether a release-page URL is safe to hand to `NSWorkspace.open`.
    ///
    /// `NSWorkspace.open` is "launch whatever app claims this scheme, with this
    /// argument" — so a host check ALONE is not enough. Foundation parses
    /// `smb://github.com/share`, `file://github.com/x`, and
    /// `javascript://github.com/%0a…` with host `github.com`, so all of them
    /// would sail past a host-only guard and reach LaunchServices. Require the
    /// scheme too, and reject embedded credentials and a custom port
    /// (`https://evil.com@github.com/…` has host `github.com` as well).
    ///
    /// The value comes from GitHub, not from a repo owner, so this is defense in
    /// depth against a compromised or intercepted API — but it is the one place
    /// where remote data becomes an OS-level launch, in a feature whose whole
    /// premise is not acting on what the server says.
    static func isAcceptableReleasePage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil
            && url.password == nil
            && url.port == nil
    }

    /// Decode the fields we use. Anything missing that we require → nil (→
    /// `.malformedResponse`), so a changed API shape reports an error rather than
    /// silently deciding there's no update.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let version = SemanticVersion(tag),
              let pageString = obj["html_url"] as? String,
              let page = URL(string: pageString),
              isAcceptableReleasePage(page)
        else { return nil }

        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((rawName?.isEmpty == false ? rawName! : tag).prefix(maxNameChars))
        // Bounded: `body` is remote text rendered into a popover and persisted.
        // GitHub allows a very large release body, and neither the UI nor the
        // saved state should have to hold one.
        let notes = String(((obj["body"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxNotesChars))

        var published: Date?
        if let s = obj["published_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            published = f.date(from: s)
        }

        // First .dmg asset, for display only.
        var assetName: String?
        var assetSize: Int?
        if let assets = obj["assets"] as? [[String: Any]] {
            let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            assetName = dmg?["name"] as? String
            assetSize = dmg?["size"] as? Int
        }

        return ReleaseInfo(
            tag: tag, version: version, name: name, notes: notes,
            releasePage: page, publishedAt: published,
            assetName: assetName, assetSize: assetSize
        )
    }
}
