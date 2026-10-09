import SwiftUI
import MarqueeUI

/// Settings scene (⌘,). Panes are placeholders that show the structure: sensible defaults up top,
/// deep controls behind the "Show advanced settings" switch (SCOPE §5.2 progressive disclosure).
struct SettingsView: View {
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralPane() }
            Tab("Library", systemImage: "books.vertical", value: "library") { LibraryPane() }
            Tab("Metadata", systemImage: "film.stack", value: "metadata") { MetadataPane() }
            Tab("Indexers", systemImage: "antenna.radiowaves.left.and.right", value: "indexers") { IndexersPane() }
            Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { DownloadsPane() }
            Tab("Streaming", systemImage: "bolt.horizontal.circle", value: "streaming") { StreamingPane() }
            Tab("Playback", systemImage: "play.rectangle", value: "playback") { PlaybackPane() }
            Tab("Subtitles", systemImage: "captions.bubble", value: "subtitles") { SubtitlesPane() }
        }
        .scenePadding()
        .frame(width: 620, height: 520)
    }
}

/// Shared chrome: grouped form plus the Advanced switch at the bottom of every pane.
struct Pane<Content: View>: View {
    @AppStorage("showAdvancedSettings") private var showAdvanced = false
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
            Section {
                Toggle("Show advanced settings", isOn: $showAdvanced)
            } footer: {
                Text("Reveals expert options such as custom formats, delay profiles and network tuning.")
            }
        }
        .formStyle(.grouped)
    }
}

struct Advanced<Content: View>: View {
    @AppStorage("showAdvancedSettings") private var showAdvanced = false
    @ViewBuilder var content: Content

    var body: some View {
        if showAdvanced {
            Section("Advanced") { content }
        }
    }
}

struct GeneralPane: View {
    @AppStorage("appearance") private var appearance = AppearanceChoice.system
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("menuBarExtra") private var menuBarExtra = true

    var body: some View {
        Pane {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Startup") {
                Toggle("Open Marquee at login", isOn: $launchAtLogin)
                Toggle("Show downloads in the menu bar", isOn: $menuBarExtra)
                Button("Show Welcome Guide Again") {
                    NotificationCenter.default.post(name: .showWelcome, object: nil)
                }
            }
        }
    }
}

struct LibraryPane: View {
    @State private var naming = 0
    @State private var importMethod = 0

    var body: some View {
        Pane {
            QualityDefaultSection()
            Section("Folders") {
                LabeledContent("Movies") { Text("~/Movies/Marquee/Movies").foregroundStyle(.secondary) }
                LabeledContent("TV Shows") { Text("~/Movies/Marquee/TV").foregroundStyle(.secondary) }
                Button("Add Folder…") {}
            }
            Section("Organizing") {
                Picker("Naming", selection: $naming) {
                    Text("Plex / Jellyfin compatible").tag(0)
                    Text("Keep original names").tag(1)
                }
            }
            Advanced {
                Picker("Import method", selection: $importMethod) {
                    Text("Clone (APFS, no extra space)").tag(0)
                    Text("Hard link").tag(1)
                    Text("Copy").tag(2)
                    Text("Move").tag(3)
                }
                Toggle("Move replaced files to the Trash", isOn: .constant(true)).disabled(true)
            }
        }
    }
}

struct StreamingPane: View {
    @State private var keep = 0

    var body: some View {
        Pane {
            Section("Watching while downloading") {
                Toggle("Start playback as soon as it's safe", isOn: .constant(true))
                Toggle("Pre-fetch the next episode", isOn: .constant(true))
                Picker("After watching", selection: $keep) {
                    Text("Keep in library").tag(0)
                    Text("Stream only, then clean up").tag(1)
                }
            }
            Advanced {
                Stepper("Buffer before start: 12 s", value: .constant(12))
                Toggle("Offer a smaller version when playback can't keep up", isOn: .constant(true))
            }
        }
    }
}

struct PlaybackPane: View {
    var body: some View {
        Pane {
            Section("Player") {
                Picker("Engine", selection: .constant(0)) {
                    Text("Automatic").tag(0)
                    Text("Always use libmpv").tag(1)
                }
                Toggle("Play next episode automatically", isOn: .constant(true))
                Toggle("Skip intros and credits", isOn: .constant(true))
            }
            Advanced {
                Toggle("Hardware decoding (VideoToolbox)", isOn: .constant(true))
                Toggle("Audio passthrough (HDMI / eARC)", isOn: .constant(false))
            }
        }
    }
}

struct SubtitlesPane: View {
    var body: some View {
        Pane {
            Section("Languages") {
                Picker("Preferred language", selection: .constant(0)) {
                    Text("English").tag(0)
                    Text("Español").tag(1)
                    Text("Français").tag(2)
                }
                Toggle("Download subtitles automatically", isOn: .constant(true))
                Toggle("Prefer hearing-impaired (SDH)", isOn: .constant(false))
            }
            Advanced {
                Toggle("Auto-sync with audio", isOn: .constant(true))
                Toggle("Match by file hash while streaming", isOn: .constant(true))
            }
        }
    }
}
