import Foundation
import Testing
@testable import MarqueeCore

@Suite("Calendar date buckets")
struct CalendarDateBucketsTests {
    @Test func groupsByLocalDayAcrossSpringDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let first = try #require(ISO8601DateFormatter().date(from: "2026-03-08T08:30:00Z"))
        let second = try #require(ISO8601DateFormatter().date(from: "2026-03-08T20:30:00Z"))
        let grouped = CalendarDateBuckets.bucket([first, second], calendar: calendar) { $0 }
        #expect(grouped.count == 1) // Both instants are March 8 in the local calendar.
        #expect(grouped.values.map(\.count).reduce(0, +) == 2)
    }

    @Test func monthGridContainsWholeWeeksAndTargetMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = 2
        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-15T12:00:00Z"))
        let days = CalendarDateBuckets.monthDays(containing: date, calendar: calendar)
        #expect(days.count == 35 || days.count == 42)
        #expect(days.contains { calendar.isDate($0, equalTo: date, toGranularity: .day) })
        #expect(days.count.isMultiple(of: 7))
    }

    @Test func weekStartsAtLocaleFirstWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z"))
        let days = CalendarDateBuckets.weekDays(containing: date, calendar: calendar)
        #expect(days.count == 7)
        #expect(calendar.component(.weekday, from: days[0]) == 2)
    }
}
