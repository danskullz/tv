import MarqueeCore
import MarqueeUI
import SwiftUI

struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @State private var events: [CalendarEvent] = []
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var mode: Mode = .month
    @State private var isLoading = true
    @State private var error: String?

    private enum Mode: String, CaseIterable { case month = "Month", week = "Week", agenda = "Agenda" }

    private var calendar: Calendar { Calendar.current }
    private var byDay: [Date: [CalendarEvent]] {
        CalendarDateBuckets.bucket(events, calendar: calendar) { $0.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error, events.isEmpty, !isLoading {
                ErrorBanner(title: "Calendar couldn't load", message: "Your local calendar is safe. Try again when metadata is available.", details: error, fixTitle: "Retry") { Task { await load() } }
                    .padding(Tokens.Spacing.gutter)
                EmptyStateView(title: "Your library is unchanged", message: "Calendar events come from release and episode dates.", systemImage: "calendar")
            } else if isLoading {
                VStack(spacing: 14) {
                    SkeletonView().frame(height: 44).padding(.horizontal, Tokens.Spacing.gutter)
                    SkeletonView().frame(height: 360).padding(.horizontal, Tokens.Spacing.gutter)
                }.padding(.top, Tokens.Spacing.l)
            } else if events.isEmpty {
                EmptyStateView(title: "Nothing scheduled yet", message: "Upcoming episodes and releases from monitored titles will appear here.", systemImage: "calendar.badge.clock", tips: ["Monitor a series from its page to follow new episodes."])
            } else {
                switch mode {
                case .month: monthView
                case .week: weekView
                case .agenda: agendaView
                }
            }
        }
        .navigationTitle(Text("Calendar"))
        .task { await load() }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { _ = move(-1) } label: { Image(systemName: "chevron.left") }.help("Previous period")
            Button("Today") { selectedDay = calendar.startOfDay(for: Date()); displayedMonth = selectedDay }
            Button { _ = move(1) } label: { Image(systemName: "chevron.right") }.help("Next period")
            Text(periodTitle).font(.title3.weight(.semibold)).padding(.leading, 8)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Picker("Calendar view", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 240)
                .labelsHidden().accessibilityLabel(Text("Calendar view"))
        }
        .padding(.horizontal, Tokens.Spacing.gutter)
        .frame(height: 56)
    }

    private var periodTitle: String {
        switch mode {
        case .month: displayedMonth.formatted(.dateTime.month(.wide).year())
        case .week: "Week of " + selectedDay.formatted(.dateTime.month(.abbreviated).day())
        case .agenda: "Upcoming"
        }
    }

    private var monthView: some View {
        VStack(spacing: 0) {
            weekdayHeader
            let days = CalendarDateBuckets.monthDays(containing: displayedMonth, calendar: calendar)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                ForEach(days, id: \.self) { day in dayCell(day, compact: false) }
            }
            .padding(.horizontal, Tokens.Spacing.gutter)
            .padding(.top, 8)
            Divider().padding(.vertical, 12)
            eventList(for: selectedDay)
        }
    }

    private var weekView: some View {
        VStack(spacing: 0) {
            weekdayHeader
            HStack(alignment: .top, spacing: 8) {
                ForEach(CalendarDateBuckets.weekDays(containing: selectedDay, calendar: calendar), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        dayCell(day, compact: true)
                        ForEach(byDay[calendar.startOfDay(for: day)] ?? []) { event in eventButton(event) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, Tokens.Spacing.gutter).padding(.top, 10)
            Spacer(minLength: 0)
        }
    }

    private var agendaView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                let grouped = Dictionary(grouping: events, by: { calendar.startOfDay(for: $0.date) })
                ForEach(grouped.keys.sorted(), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(Tokens.Typography.sectionTitle)
                        ForEach(grouped[day] ?? []) { event in eventButton(event) }
                    }
                }
            }.padding(Tokens.Spacing.gutter)
        }
    }

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return HStack {
            ForEach(0..<7, id: \.self) { offset in
                Text(symbols[(calendar.firstWeekday - 1 + offset) % 7].uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, Tokens.Spacing.gutter).padding(.top, 12)
    }

    private func dayCell(_ day: Date, compact: Bool) -> some View {
        let key = calendar.startOfDay(for: day)
        let dayEvents = byDay[key] ?? []
        let isToday = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        return Button { selectedDay = key; displayedMonth = day } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(day.formatted(.dateTime.day())).font(.subheadline.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                    Spacer(minLength: 0)
                    if !dayEvents.isEmpty { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                }
                if !compact {
                    ForEach(dayEvents.prefix(2)) { event in
                        Text(event.title).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    }
                    if dayEvents.count > 2 { Text("+\(dayEvents.count - 2) more").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: compact ? 52 : 92, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isToday ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).accessibilityLabel(Text(day.formatted(date: .complete, time: .omitted)))
    }

    @ViewBuilder
    private func eventList(for day: Date) -> some View {
        let dayEvents = byDay[calendar.startOfDay(for: day)] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(calendar.isDateInToday(day) ? "Airs Tonight" : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(Tokens.Typography.sectionTitle)
                if calendar.isDateInToday(day) { StatusPill("Today", systemImage: "sun.max.fill") }
            }.padding(.horizontal, Tokens.Spacing.gutter)
            if dayEvents.isEmpty { Text("No releases on this day.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, Tokens.Spacing.gutter) }
            ForEach(dayEvents) { event in eventButton(event) }
        }
    }

    private func eventButton(_ event: CalendarEvent) -> some View {
        Button { model.open(event.titleID) } label: {
            HStack(spacing: 12) {
                Image(systemName: event.kind == .episode ? "tv" : "film").font(.title3).foregroundStyle(.tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: event.title).font(.headline)
                    Text(verbatim: event.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.date, style: .date).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, Tokens.Spacing.gutter)
    }

    private func move(_ direction: Int) -> KeyPress.Result {
        let component: Calendar.Component = mode == .month ? .month : mode == .week ? .weekOfYear : .day
        let amount = mode == .agenda ? 7 : 1
        if let next = calendar.date(byAdding: component, value: direction * amount, to: mode == .month ? displayedMonth : selectedDay) {
            selectedDay = calendar.startOfDay(for: next); displayedMonth = selectedDay
        }
        return .handled
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { events = try await model.services?.calendarEvents() ?? [] }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
