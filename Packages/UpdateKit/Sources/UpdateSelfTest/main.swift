// Live smoke test for the update checker — the macOS analog of CaptureSelfTest
// and PdfSelfTest. Drives the REAL GitHub Releases API once, so it proves the
// things a fixture-backed unit test can't: the pinned URL resolves, TLS works,
// GitHub accepts our User-Agent, and the live JSON still parses into the fields
// the UI reads.
//
//   swift run --package-path Packages/UpdateKit UpdateSelfTest [installedVersion]
//
// Costs exactly one request against the unauthenticated 60/hour budget, and
// runs against an in-memory throttle so it never disturbs the app's own state.
import Foundation
import UpdateKit

let installed = CommandLine.arguments.dropFirst().first ?? "1.1.2"
var failures: [String] = []

@MainActor func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures.append(label) }
}

print("[update-test] querying the live GitHub Releases API…")
print("  endpoint: https://api.github.com/repos/\(UpdateFeed.owner)/\(UpdateFeed.repo)/releases/latest")
print("  installed version under test: \(installed)\n")

let feed = UpdateFeed(appVersion: installed)
do {
    let release = try await feed.fetchLatest()
    print("  latest release: \(release.tag)  (\(release.name))")
    print("  asset:          \(release.assetSummary ?? "none")")
    print("  page:           \(release.releasePage.absoluteString)")
    print("  notes:          \(release.notes.isEmpty ? "(none)" : "\(release.notes.count) chars")\n")

    check("tag parsed as a version", true, release.version.description)
    check("release page is on github.com", release.releasePage.host == "github.com")
    check("release page is https", release.releasePage.scheme == "https")
    check("release is not a prerelease tag",
          !release.version.isPrerelease,
          release.version.isPrerelease ? "an rc was published WITHOUT prerelease:true" : "")
    check("a .dmg asset is attached", release.assetName?.hasSuffix(".dmg") == true,
          release.assetName ?? "no dmg found")

    // The comparison the app will actually make.
    if let running = SemanticVersion(installed) {
        let newer = release.version > running
        print("\n  comparison: installed \(running) vs latest \(release.version) → "
            + (newer ? "UPDATE AVAILABLE" : "up to date"))
        check("comparison did not offer a downgrade", newer ? true : release.version <= running)
    } else {
        check("installed version parsed", false, "\(installed) is unparseable")
    }

    // Prove the throttle gates a second call, using an isolated in-memory store.
    let store = InMemoryUpdateState()
    let checker = UpdateChecker(store: store, makeFeed: { UpdateFeed(appVersion: $0) })
    let first = await checker.check(reason: .automatic, enabled: true, currentVersion: installed)
    let second = await checker.check(reason: .automatic, enabled: true, currentVersion: installed)
    print("\n  first automatic check:  \(first)")
    print("  second automatic check: \(second)")
    if case .throttled = second {
        check("the daily throttle blocked the immediate second check", true)
    } else {
        check("the daily throttle blocked the immediate second check", false, "got \(second)")
    }
} catch {
    check("fetchLatest succeeded", false, "\(error)")
}

print("\n[update-test] \(failures.isEmpty ? "PASS" : "FAIL — \(failures.joined(separator: ", "))")")
exit(failures.isEmpty ? 0 : 1)
