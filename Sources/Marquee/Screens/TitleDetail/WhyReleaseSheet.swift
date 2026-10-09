import MarqueeCore
import MarqueeUI
import SwiftUI

struct WhyReleaseSheet: View {
    let titleID: String
    let title: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var grabs: [Grab] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why This Release?").font(.title2.bold())
                    Text(verbatim: title).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if isLoading {
                VStack(alignment: .leading, spacing: 12) { SkeletonView().frame(height: 24); SkeletonView().frame(height: 120); SkeletonView().frame(height: 84) }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            } else if grabs.isEmpty {
                EmptyStateView(title: "No release decision yet", message: "When Marquee finds and picks a release, its quality and streamability reasoning will be recorded here.", systemImage: "questionmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text("Each attempt is kept, so fallbacks remain explainable.").font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(grabs.enumerated()), id: \.element.id) { index, grab in
                            attempt(grab, number: grabs.count - index)
                        }
                    }.padding(20)
                }
            }
        }
        .task { await load() }
    }

    private func attempt(_ grab: Grab, number: Int) -> some View {
        let facts = DecisionLogRenderer.render(grab.reason)
        let summary = facts.summary
        let headline = facts.headline
        let explanation = facts.reasons
        let components = facts.streamability
        let rejections = facts.rejectionCounts
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(number == grabs.count ? headline : "Fallback attempt \(number)").font(.headline)
                Spacer()
                Text(grab.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: grab.releaseTitle).font(.title3.weight(.semibold)).textSelection(.enabled)
            if let summary { Text(verbatim: summary).font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                StatusPill(verbatim: grab.outcome.rawValue.capitalized)
                if let quality = facts.quality { StatusPill(verbatim: quality) }
                if let score = grab.score { StatusPill("Score \(score)") }
                if let formatScore = facts.formatScore { StatusPill(verbatim: "Format +\(formatScore)") }
                if let profile = facts.profile { StatusPill(verbatim: profile) }
            }
            if !explanation.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why it ranked").font(.subheadline.weight(.semibold))
                    ForEach(Array(explanation.enumerated()), id: \.offset) { _, reason in Label(reason, systemImage: "checkmark.circle.fill").font(.callout) }
                }
            }
            if !components.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Streamability").font(.subheadline.weight(.semibold))
                    ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                        HStack {
                            Text(verbatim: component.name).font(.callout)
                            Spacer()
                            if let points = component.points { Text(points.formatted(.number.precision(.fractionLength(0)))) }
                        }
                        if let note = component.note, !note.isEmpty { Text(verbatim: note).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if !rejections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other candidates").font(.subheadline.weight(.semibold))
                    ForEach(rejections.keys.sorted(), id: \.self) { key in
                        Text("\(rejections[key] ?? 0) rejected: \(readable(key))").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let failure = facts.failure, !failure.isEmpty {
                Label("This attempt couldn't start: \(failure)", systemImage: "arrow.uturn.backward").font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func readable(_ code: String) -> String {
        ["wrongTitle": "different title", "wrongEpisode": "wrong episode", "wrongYear": "wrong year",
         "qualityNotAllowed": "quality outside your profile", "tooFewSeeders": "not enough seeders",
         "sizeTooSmall": "too small", "sizeTooLarge": "too large", "blocklisted": "blocklisted"] [code] ?? code
    }

    private func load() async {
        defer { isLoading = false }
        grabs = await model.services?.recentGrabs(for: titleID) ?? []
    }
}

private extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var numberValue: Double? {
        switch self { case .int(let value): Double(value); case .double(let value): value; default: nil }
    }
    var stringArray: [String] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap(\.stringValue)
    }
    var objectArray: [[String: JSONValue]] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }
    var intDictionary: [String: Int] {
        guard case .object(let values) = self else { return [:] }
        return values.compactMapValues { if case .int(let value) = $0 { value } else { nil } }
    }
}
