import AppKit
import MarqueeCore
import MarqueeUI
import SwiftUI

/// Result line under a Test button: green check or orange warning, plain language.
struct ResultLine: View {
    let result: AppServices.ConnectionResult?
    let isTesting: Bool

    var body: some View {
        if isTesting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        } else if let result {
            Label {
                Text(verbatim: result.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? Color.green : Color.orange)
            }
            .font(.callout)
        }
    }
}

private struct NoServicesNote: View {
    var body: some View {
        Section {
            Text("These settings are unavailable while running on sample data (-mockData).").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Metadata (TMDB)

struct MetadataPane: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var result: AppServices.ConnectionResult?
    @State private var isTesting = false
    @State private var saveError: String?

    var body: some View {
        Pane {
            if let services = model.services {
                Section {
                    SecureField("API key or read access token", text: $key, prompt: Text(services.hasMetadataKey ? "Saved in your Keychain" : "Paste your TMDB key"))
                    HStack {
                        Button("Test") { test(services) }.disabled(isTesting || (key.isEmpty && !services.hasMetadataKey))
                        Button("Save") { save(services) }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if services.hasMetadataKey {
                            Button("Remove", role: .destructive) { remove(services) }
                        }
                        Spacer()
                        Link("Get a free key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    }
                    ResultLine(result: result, isTesting: isTesting)
                    if let saveError { Text(verbatim: saveError).foregroundStyle(.red).font(.callout) }
                } header: {
                    Text("TMDB")
                } footer: {
                    Text("Marquee uses TMDB for posters, synopses and episode lists. Your key is stored in the macOS Keychain and only ever sent to TMDB.")
                }
            } else {
                NoServicesNote()
            }
        }
    }

    private func test(_ services: AppServices) {
        isTesting = true
        result = nil
        let typed = key.trimmingCharacters(in: .whitespaces)
        Task {
            let candidate = typed.isEmpty ? ((try? services.secrets.get(account: AppServices.tmdbAccount)) ?? "") : typed
            result = await services.testTMDBKey(candidate)
            isTesting = false
        }
    }

    private func save(_ services: AppServices) {
        do {
            try services.saveTMDBKey(key)
            key = ""
            saveError = nil
            result = AppServices.ConnectionResult(ok: true, message: "Saved to your Keychain.")
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func remove(_ services: AppServices) {
        try? services.saveTMDBKey("")
        result = nil
    }
}

// MARK: - Indexers

struct IndexersPane: View {
    @Environment(AppModel.self) private var model
    @State private var indexers: [Indexer] = []
    @State private var showAdd = false
    @State private var results: [UUID: AppServices.ConnectionResult] = [:]
    @State private var testing: Set<UUID> = []

    var body: some View {
        Pane {
            if let services = model.services {
                Section {
                    if indexers.isEmpty {
                        EmptyStateView(
                            title: "No indexers yet",
                            message: "Marquee doesn't include any sources. Add your own Torznab indexer.",
                            systemImage: "antenna.radiowaves.left.and.right",
                            actionTitle: "Add Indexer…"
                        ) { showAdd = true }
                        .frame(height: 220)
                    } else {
                        ForEach(indexers) { indexer in row(indexer, services) }
                        Button("Add Indexer…") { showAdd = true }
                    }
                }
            } else {
                NoServicesNote()
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showAdd) {
            AddIndexerSheet { await reload() }
        }
    }

    private func row(_ indexer: Indexer, _ services: AppServices) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { indexer.enabled },
                    set: { value in Task { await services.setIndexerEnabled(indexer, value); await reload() } }
                )) {
                    VStack(alignment: .leading) {
                        Text(verbatim: indexer.name)
                        Text(verbatim: URL(string: indexer.baseURL)?.host(percentEncoded: false) ?? indexer.baseURL)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Test") { test(indexer, services) }.disabled(testing.contains(indexer.id))
                Button(role: .destructive) {
                    Task { await services.deleteIndexer(indexer); await reload() }
                } label: { Image(systemName: "trash") }
                    .help(Text("Remove this indexer"))
                    .accessibilityLabel(Text("Remove \(indexer.name)"))
            }
            ResultLine(result: results[indexer.id], isTesting: testing.contains(indexer.id))
        }
    }

    private func test(_ indexer: Indexer, _ services: AppServices) {
        guard let url = URL(string: indexer.baseURL) else { return }
        testing.insert(indexer.id)
        results[indexer.id] = nil
        Task {
            let key = (try? services.secrets.get(account: indexer.credentialRef ?? "")) ?? ""
            results[indexer.id] = await services.testIndexer(url: url, apiKey: key)
            testing.remove(indexer.id)
        }
    }

    private func reload() async {
        indexers = await model.services?.indexers() ?? []
        await model.services?.refreshStatus()
    }
}

private struct AddIndexerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdded: () async -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var apiKey = ""
    @State private var result: AppServices.ConnectionResult?
    @State private var isTesting = false
    @State private var error: String?

    private var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Indexer").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("My indexer"))
                TextField("Torznab URL", text: $address, prompt: Text("http://localhost:9117/api/v2.0/indexers/all/results/torznab/"))
                SecureField("API key", text: $apiKey)
            }
            .formStyle(.columns)
            Text("Paste the Torznab feed URL and API key your indexer manager shows. The key is stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            ResultLine(result: result, isTesting: isTesting)
            if let error { Text(verbatim: error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Test") { test() }.disabled(url == nil || isTesting)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func test() {
        guard let url, let services = model.services else { return }
        isTesting = true
        result = nil
        Task {
            result = await services.testIndexer(url: url, apiKey: apiKey)
            isTesting = false
        }
    }

    private func add() {
        guard let url, let services = model.services else { return }
        Task {
            do {
                try await services.addIndexer(name: name.trimmingCharacters(in: .whitespaces), url: url, apiKey: apiKey)
                await onAdded()
                dismiss()
            } catch {
                self.error = "Couldn't save the indexer. Is the name already used?"
            }
        }
    }
}

// MARK: - Downloads

struct DownloadsPane: View {
    @Environment(AppModel.self) private var model
    @State private var folder = AppSettings.downloadFolder
    @State private var isDefault = AppSettings.isDefaultDownloadFolder
    @State private var limit = 0.0
    @State private var killSwitch = true

    var body: some View {
        Pane {
            Section("Location") {
                LabeledContent("Download folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        HStack {
                            Button("Choose…") { choose() }
                            if !isDefault { Button("Reset") { reset() } }
                        }
                    }
                }
                LabeledContent("Free space") {
                    Text(verbatim: AppSettings.freeSpace(at: folder).map { $0.formatted(.byteCount(style: .file)) } ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Speed") {
                LabeledContent("Download limit") {
                    Slider(value: $limit, in: 0...100) { Text("Limit") }.frame(width: 180)
                    Text(limit == 0 ? "Unlimited" : "\(Int(limit)) MB/s").monospacedDigit().frame(width: 76, alignment: .trailing)
                }
                Toggle("Pause while on battery", isOn: .constant(false))
            }
            Advanced {
                Toggle("Bind to VPN interface with kill switch", isOn: $killSwitch)
                Toggle("Enable DHT, PEX and local peer discovery", isOn: .constant(true))
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where Marquee saves what you watch and download.")
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.downloadFolder = url
            folder = url
            isDefault = false
        }
    }

    private func reset() {
        AppSettings.resetDownloadFolder()
        folder = AppSettings.downloadFolder
        isDefault = true
    }
}

// MARK: - Quality

struct QualityDefaultSection: View {
    @State private var preset = AppSettings.defaultPreset

    var body: some View {
        Section {
            Picker("Quality preset", selection: $preset) {
                ForEach(QualityProfileConfig.presets, id: \.id) { Text(verbatim: $0.name).tag($0) }
            }
            .onChange(of: preset) { _, new in AppSettings.defaultPreset = new }
        } header: {
            Text("New titles")
        } footer: {
            Text(verbatim: preset.presetBlurb)
        }
    }
}
