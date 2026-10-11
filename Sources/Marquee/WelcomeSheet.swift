import SwiftUI
import MarqueeUI

/// First-run guide skeleton (SCOPE §5.3). Steps are static for now; each will drive a real setup pane.
struct WelcomeSheet: View {
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        /// Settings tab this step links to.
        var tab: String?
        var linkTitle: LocalizedStringKey = "Open Settings"
    }

    private let steps: [Step] = [
        Step(id: 1, symbol: "switch.2", title: "Standalone or connect", detail: "Run everything inside Marquee, or use it as a front end for your existing Sonarr and Radarr."),
        Step(id: 2, symbol: "externaldrive", title: "Pick your folders", detail: "Choose where your downloads live. External drives are fine.", tab: "downloads", linkTitle: "Choose Folder"),
        Step(id: 7, symbol: "key", title: "Add your TMDB key", detail: "A free key from themoviedb.org gives Marquee posters, synopses and episode lists.", tab: "metadata", linkTitle: "Add Key"),
        Step(id: 3, symbol: "antenna.radiowaves.left.and.right", title: "Add an indexer", detail: "Paste a Torznab URL and API key. Marquee doesn't include any sources.", tab: "indexers", linkTitle: "Add Indexer"),
        Step(id: 4, symbol: "dial.medium", title: "Choose a quality preset", detail: "Pick how big and how sharp your streams should be.", tab: "library", linkTitle: "Choose Preset"),
        Step(id: 5, symbol: "network.badge.shield.half.filled", title: "Optional extras", detail: "VPN interface check, Trakt sign-in and subtitle languages."),
        Step(id: 6, symbol: "play.circle.fill", title: "Press Play", detail: "Import an existing library or search for something and watch it in seconds."),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text("Welcome to Marquee")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                readiness
                Text("Marquee ships with no content or sources. You add your own and are responsible for what you access.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 260, alignment: .leading)
            .padding(Tokens.Spacing.l + 4)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Five minutes to your first play")
                    .font(.headline)
                    .padding(.bottom, Tokens.Spacing.m)
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.headline)
                            Text(step.detail).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let tab = step.tab {
                            Spacer(minLength: 8)
                            Button(step.linkTitle) {
                                UserDefaults.standard.set(tab, forKey: "settings.tab")
                                openSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: Tokens.Spacing.m)
                HStack {
                    Button("Skip for Now", action: onDone)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action: onDone) { Text("Get Started").padding(.horizontal, 10) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Tokens.Spacing.l + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 800, height: 560)
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 6) {
            check("Engine", ok: true)
            check("Indexers", ok: (model.services?.indexerCount ?? 0) > 0)
            check("Metadata", ok: model.services?.hasMetadataKey ?? false)
        }
        .padding(Tokens.Spacing.m - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Tokens.Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func check(_ name: LocalizedStringKey, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(name).font(.subheadline)
            Spacer()
            Text(ok ? "Ready" : "Not set up").font(.caption).foregroundStyle(.secondary)
        }
    }
}
