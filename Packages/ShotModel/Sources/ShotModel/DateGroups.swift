import Foundation

/// Bucket projects by a date into dynamic, mutually-exclusive spans for the Home
/// list when it's sorted by date. Ported from the Windows app's `date-groups.ts`
/// (F4) — pure and unit-tested. Weeks start Sunday at local midnight; the week
/// buckets win over the month buckets, so a date in the current week reads as
/// "This Week", not "This Month".
public enum DateBucket: String, CaseIterable, Sendable {
    case thisWeek = "This Week"
    case lastWeek = "Last Week"
    case thisMonth = "This Month"
    case lastMonth = "Last Month"
    case older = "Older"
}

public enum DateGroups {
    /// Local midnight at the start of the week (Sunday) containing `d`.
    private static func startOfWeek(_ d: Date, _ cal: Calendar) -> Date {
        let midnight = cal.startOfDay(for: d)
        let weekday = cal.component(.weekday, from: midnight) // 1 = Sunday
        return cal.date(byAdding: .day, value: -(weekday - 1), to: midnight) ?? midnight
    }

    private static func firstOfMonth(_ year: Int, _ month: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date(timeIntervalSince1970: 0)
    }

    /// Which span a date falls in, relative to `now`. Buckets are checked in
    /// order and are mutually exclusive. All boundaries use calendar arithmetic
    /// (DST / month-safe), not fixed offsets.
    public static func bucket(for date: Date, now: Date, calendar cal: Calendar = .current) -> DateBucket {
        let ts = date.timeIntervalSince1970
        guard ts.isFinite else { return .older }
        let thisWeek = startOfWeek(now, cal)
        let lastWeek = cal.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
        let comps = cal.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 1970, month = comps.month ?? 1
        let thisMonth = firstOfMonth(year, month, cal)
        let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        if date >= thisWeek { return .thisWeek }
        if date >= lastWeek { return .lastWeek }
        if date >= thisMonth { return .thisMonth }
        if date >= lastMonth { return .lastMonth }
        return .older
    }

    /// Group `items` (already sorted by the caller) into date buckets, preserving
    /// each item's order within its bucket and emitting only non-empty buckets in
    /// canonical newest→oldest order. `date` extracts the value to bucket on.
    public static func group<T>(
        _ items: [T], now: Date, calendar cal: Calendar = .current, date: (T) -> Date
    ) -> [(label: DateBucket, items: [T])] {
        var map: [DateBucket: [T]] = [:]
        for it in items {
            map[bucket(for: date(it), now: now, calendar: cal), default: []].append(it)
        }
        return DateBucket.allCases.compactMap { b in
            map[b].map { (label: b, items: $0) }
        }
    }
}
