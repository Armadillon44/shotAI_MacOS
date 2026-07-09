import Foundation
import Testing
@testable import ShotModel

@Suite struct DateGroupsTests {
    /// Deterministic UTC Gregorian calendar so the buckets don't depend on the
    /// test machine's locale/timezone.
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func bucketsAreMutuallyExclusiveAndWeekBeatsMonth() {
        // "now" = Wednesday 2026-07-08; start-of-week (Sunday) = 2026-07-05.
        let now = date("2026-07-08T12:00:00Z")
        #expect(DateGroups.bucket(for: date("2026-07-08T09:00:00Z"), now: now, calendar: utc) == .thisWeek)
        #expect(DateGroups.bucket(for: date("2026-07-05T00:00:00Z"), now: now, calendar: utc) == .thisWeek) // Sunday boundary
        #expect(DateGroups.bucket(for: date("2026-07-02T00:00:00Z"), now: now, calendar: utc) == .lastWeek) // earlier this month, but the week wins
        #expect(DateGroups.bucket(for: date("2026-06-20T00:00:00Z"), now: now, calendar: utc) == .lastMonth)
        #expect(DateGroups.bucket(for: date("2026-05-01T00:00:00Z"), now: now, calendar: utc) == .older)
    }

    @Test func nonFiniteAndFutureAreSafe() {
        let now = date("2026-07-08T12:00:00Z")
        #expect(DateGroups.bucket(for: .distantPast, now: now, calendar: utc) == .older)
        #expect(DateGroups.bucket(for: date("2027-01-01T00:00:00Z"), now: now, calendar: utc) == .thisWeek) // future ≥ start-of-week
    }

    @Test func groupEmitsOnlyNonEmptyBucketsInOrder() {
        let now = date("2026-07-08T12:00:00Z")
        let items = [
            date("2026-07-08T09:00:00Z"), // this week
            date("2026-05-01T00:00:00Z"), // older
            date("2026-07-07T00:00:00Z"), // this week
        ]
        let groups = DateGroups.group(items, now: now, calendar: utc) { $0 }
        #expect(groups.map(\.label) == [.thisWeek, .older])
        #expect(groups[0].items.count == 2) // input order preserved within a bucket
        #expect(groups[1].items.count == 1)
    }
}
