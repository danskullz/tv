import Foundation

/// Calendar arithmetic shared by the release calendar and tests. Every bucket is keyed by local
/// start-of-day, so daylight-saving transitions never assume that a day contains 86,400 seconds.
public enum CalendarDateBuckets {
    public static func bucket<Element>(
        _ elements: [Element], calendar: Calendar, date: (Element) -> Date
    ) -> [Date: [Element]] {
        Dictionary(grouping: elements) { calendar.startOfDay(for: date($0)) }
    }

    public static func weekDays(containing date: Date, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    /// A six-week grid with complete weeks, including adjacent-month dates.
    public static func monthDays(containing date: Date, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return [] }
        let firstDay = calendar.component(.weekday, from: interval.start)
        let leading = (firstDay - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: interval.start) else { return [] }
        let count = ((leading + calendar.component(.day, from: last) + 6) / 7) * 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }
}
