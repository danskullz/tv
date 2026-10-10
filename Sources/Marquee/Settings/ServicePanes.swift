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
                    SecureField("API key or read access token", text: $key, prompt: Text(services.hasMetadataKey ? "Key saved" : "Paste your TMDB key"))
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
                    Text("Marquee uses TMDB for posters, synopses and episode lists. Your key is stored on this Mac, readable only by you, and only ever sent to TMDB.")
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
            result = AppServices.ConnectionResult(ok: true, message: "Key saved.")
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
    @State private var showAddProwlarr = false
    @State private var results: [UUID: AppServices.ConnectionResult] = [:]
    @State private var testing: Set<UUID> = []
    @State private var editingIndexer: Indexer?
    @State private var editingRemoteIndexer: Indexer?

    var body: some View {
        Pane {
            if let services = model.services {
                Section {
                    if indexers.isEmpty {
                        EmptyStateView(
                            title: "No indexers yet",
                            message: "Marquee doesn't include any sources. Add a Torznab indexer or connect to Prowlarr.",
                            systemImage: "antenna.radiowaves.left.and.right",
                            actionTitle: "Add Torznab…",
                            secondaryActionTitle: "Add Prowlarr…",
                            secondaryAction: { showAddProwlarr = true }
                        ) { showAdd = true }
                        .frame(height: 220)
                    } else {
                        ForEach(indexers) { indexer in row(indexer, services) }
                        HStack {
                            Button("Add Torznab…") { showAdd = true }
                            Button("Add Prowlarr…") { showAddProwlarr = true }
                        }
                    }
                }
            } else {
                NoServicesNote()
            }
        }
        .task(id: model.services?.indexerCount) { await reload() }
        .sheet(isPresented: $showAdd) {
            AddIndexerSheet { await reload() }
        }
        .sheet(isPresented: $showAddProwlarr) {
            AddProwlarrSheet { await reload() }
        }
        .sheet(item: $editingIndexer) { indexer in
            EditIndexerSolverSheet(indexer: indexer) { url in
                await model.services?.setIndexerFlareSolverrURL(indexer, url)
                await reload()
            }
        }
        .sheet(item: $editingRemoteIndexer) { indexer in
            EditRemoteIndexerSheet(indexer: indexer) {
                await reload()
            }
        }
    }

    private func row(_ indexer: Indexer, _ services: AppServices) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { indexer.enabled },
                    set: { value in
                        if value && ["prowlarr", "jackett"].contains(indexer.implementation) {
                            let key = try? services.secrets.get(account: indexer.credentialRef ?? "")
                            if key?.isEmpty != false {
                                editingRemoteIndexer = indexer
                                return
                            }
                        }
                        Task { await services.setIndexerEnabled(indexer, value); await reload() }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text(verbatim: indexer.name)
                        Text("\(sourceType(indexer)) · \(sourceAddress(indexer))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = sourceNote(indexer) {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Test") { test(indexer, services) }.disabled(testing.contains(indexer.id))
                if indexer.implementation == "prowlarr" || indexer.implementation == "jackett" {
                    Button("Configure…") { editingRemoteIndexer = indexer }
                } else if BuiltInProvider(rawValue: indexer.implementation) == nil && indexer.implementation != "torlock" {
                    Button("Configure…") { editingIndexer = indexer }
                }
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
            if indexer.implementation == "prowlarr" {
                results[indexer.id] = await services.testProwlarr(url: url, apiKey: key)
            } else if BuiltInProvider(rawValue: indexer.implementation) != nil {
                results[indexer.id] = await services.testBuiltInProvider(indexer, apiKey: key)
            } else {
                if indexer.implementation == "jackett" {
                    results[indexer.id] = await services.testIndexer(url: url, apiKey: key)
                } else {
                    let solver = indexer.flareSolverrURL.flatMap(URL.init(string:))
                    results[indexer.id] = await services.testIndexer(url: url, apiKey: key, flareSolverrURL: solver)
                }
            }
            testing.remove(indexer.id)
        }
    }

    private func sourceAddress(_ indexer: Indexer) -> String {
        guard let url = URL(string: indexer.baseURL) else { return indexer.baseURL }
        if BuiltInProvider(rawValue: indexer.implementation) != nil { return url.host(percentEncoded: false) ?? indexer.baseURL }
        if indexer.implementation == "prowlarr" {
            return url.host(percentEncoded: false).map { $0 + url.path } ?? indexer.baseURL
        }
        return url.host(percentEncoded: false) ?? indexer.baseURL
    }

    private func sourceType(_ indexer: Indexer) -> String {
        if BuiltInProvider(rawValue: indexer.implementation) != nil { return "Built-in provider" }
        switch indexer.implementation {
        case "prowlarr": return "Prowlarr"
        case "jackett": return "Jackett · Torznab"
        case "torlock": return "TorLock · Torznab"
        default: return "Torznab"
        }
    }

    private func sourceNote(_ indexer: Indexer) -> String? {
        if let provider = BuiltInProvider(rawValue: indexer.implementation) {
            return indexer.enabled ? nil : provider.defaultDisabledMessage
        }
        if !indexer.enabled, ["prowlarr", "jackett"].contains(indexer.implementation) {
            return "Configure the local service and API key to enable searches."
        }
        return nil
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
    @State private var flareSolverrAddress = ""
    @State private var result: AppServices.ConnectionResult?
    @State private var isTesting = false
    @State private var error: String?

    private var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    private var flareSolverrURL: URL? {
        let trimmed = flareSolverrAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil,
            url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }

    private var isFlareSolverrAddressValid: Bool {
        flareSolverrAddress.trimmingCharacters(in: .whitespaces).isEmpty || flareSolverrURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Indexer").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("My indexer"))
                TextField("Torznab URL", text: $address, prompt: Text("http://localhost:9117/api/v2.0/indexers/all/results/torznab/"))
                SecureField("API key", text: $apiKey)
                TextField("FlareSolverr URL (optional)", text: $flareSolverrAddress, prompt: Text("http://localhost:8191"))
            }
            .formStyle(.columns)
            Text("Paste the Torznab feed URL and API key your indexer manager shows. The key is stored on this Mac, readable only by you.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Use FlareSolverr only for indexers that need browser-challenge solving. Its server receives the full Torznab URL, including the API key.")
                .font(.caption).foregroundStyle(.secondary)
            ResultLine(result: result, isTesting: isTesting)
            if let error { Text(verbatim: error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Test") { test() }.disabled(url == nil || !isFlareSolverrAddressValid || isTesting)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil || !isFlareSolverrAddressValid || name.trimmingCharacters(in: .whitespaces).isEmpty)
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
            result = await services.testIndexer(url: url, apiKey: apiKey, flareSolverrURL: flareSolverrURL)
            isTesting = false
        }
    }

    private func add() {
        guard let url, let services = model.services else { return }
        Task {
            do {
                try await services.addIndexer(
                    name: name.trimmingCharacters(in: .whitespaces), url: url, apiKey: apiKey,
                    flareSolverrURL: flareSolverrURL)
                await onAdded()
                dismiss()
            } catch {
                self.error = "Couldn't save the indexer. Is the name already used?"
            }
        }
    }
}

private struct AddProwlarrSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdded: () async -> Void

    @State private var name = "Prowlarr"
    @State private var address = ""
    @State private var apiKey = ""
    @State private var result: AppServices.ConnectionResult?
    @State private var isTesting = false
    @State private var error: String?

    private var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty, url.query == nil, url.fragment == nil,
            url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Prowlarr").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Prowlarr URL", text: $address, prompt: Text("http://localhost:9696"))
                SecureField("API key", text: $apiKey)
            }
            .formStyle(.columns)
            Text("Marquee searches enabled torrent indexers through Prowlarr. The API key is stored on this Mac, readable only by you.")
                .font(.caption).foregroundStyle(.secondary)
            ResultLine(result: result, isTesting: isTesting)
            if let error { Text(verbatim: error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Test") { test() }.disabled(url == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
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
            result = await services.testProwlarr(url: url, apiKey: apiKey)
            isTesting = false
        }
    }

    private func add() {
        guard let url, let services = model.services else { return }
        Task {
            do {
                try await services.addProwlarr(
                    name: name.trimmingCharacters(in: .whitespaces), url: url, apiKey: apiKey)
                await onAdded()
                dismiss()
            } catch {
                self.error = "Couldn't save this Prowlarr connection. Is the name already in use?"
            }
        }
    }
}

private struct EditIndexerSolverSheet: View {
    @Environment(\.dismiss) private var dismiss
    let indexer: Indexer
    let onSave: (URL?) async -> Void

    @State private var address: String
    init(indexer: Indexer, onSave: @escaping (URL?) async -> Void) {
        self.indexer = indexer
        self.onSave = onSave
        _address = State(initialValue: indexer.flareSolverrURL ?? "")
    }

    private var parsedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil,
            url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }

    private var isValid: Bool {
        address.trimmingCharacters(in: .whitespaces).isEmpty || parsedURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Challenge Solver").font(.title2.weight(.semibold))
            Text(verbatim: indexer.name).foregroundStyle(.secondary)
            TextField("FlareSolverr URL (optional)", text: $address, prompt: Text("http://localhost:8191"))
                .textFieldStyle(.roundedBorder)
            Text("FlareSolverr receives this indexer’s Torznab requests, including its API key. Leave blank to connect directly.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    Task {
                        await onSave(parsedURL)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

private struct EditRemoteIndexerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let indexer: Indexer
    let onSaved: () async -> Void

    @State private var address: String
    @State private var apiKey = ""
    @State private var result: AppServices.ConnectionResult?
    @State private var isTesting = false
    @State private var error: String?

    init(indexer: Indexer, onSaved: @escaping () async -> Void) {
        self.indexer = indexer
        self.onSaved = onSaved
        _address = State(initialValue: indexer.baseURL)
    }

    private var isProwlarr: Bool { indexer.implementation == "prowlarr" }
    private var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty, url.query == nil, url.fragment == nil,
            url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure \(indexer.name)").font(.title2.weight(.semibold))
            Form {
                TextField(isProwlarr ? "Prowlarr URL" : "Jackett Torznab URL", text: $address)
                SecureField("API key", text: $apiKey)
            }
            .formStyle(.columns)
            Text(isProwlarr
                ? "Use your Prowlarr server address. The API key stays on this Mac, readable only by you."
                : "Use Jackett's all-indexers Torznab URL. The API key stays on this Mac, readable only by you.")
                .font(.caption).foregroundStyle(.secondary)
            ResultLine(result: result, isTesting: isTesting)
            if let error { Text(verbatim: error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Test") { test() }.disabled(url == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            apiKey = (try? model.services?.secrets.get(account: indexer.credentialRef ?? "")) ?? ""
        }
    }

    private func test() {
        guard let url, let services = model.services else { return }
        isTesting = true
        result = nil
        Task {
            result = isProwlarr
                ? await services.testProwlarr(url: url, apiKey: apiKey)
                : await services.testIndexer(url: url, apiKey: apiKey)
            isTesting = false
        }
    }

    private func save() {
        guard let url, let services = model.services else { return }
        Task {
            do {
                try await services.configureRemoteIndexer(indexer, url: url, apiKey: apiKey)
                await onSaved()
                dismiss()
            } catch {
                self.error = "Couldn't save this connection. Check the URL and API key, then try again."
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
