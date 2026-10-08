import SwiftUI
import MarqueeUI

/// Settings scene (⌘,). Panes are placeholders that show the structure: sensible defaults up top,
/// deep controls behind the "Show advanced settings" switch (SCOPE §5.2 progressive disclosure).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Library", systemImage: "books.vertical") { LibraryPane() }
            Tab("Indexers", systemImage: "antenna.radiowaves.left.and.right") { IndexersPane() }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadsPane() }
            Tab("Streaming", systemImage: "bolt.horizontal.circle") { StreamingPane() }
            Tab("Playback", systemImage: "play.rectangle") { PlaybackPane() }
            Tab("Subtitles", systemImage: "captions.bubble") { SubtitlesPane() }
        }
        .scenePadding()
        .frame(width: 600, height: 460)
    }
}

/// Shared chrome: grouped form plus the Advanced switch at the bottom of every pane.
private struct Pane<Content: View>: View {
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

private struct Advanced<Content: View>: View {
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

struct IndexersPane: View {
    var body: some View {
        Pane {
            Section {
                EmptyStateView(
                    title: "No indexers yet",
                    message: "Marquee doesn't include any sources. Add your own Torznab indexer, or import them from Prowlarr or Jackett.",
                    systemImage: "antenna.radiowaves.left.and.right",
                    actionTitle: "Add Indexer…"
                ) {}
                .frame(height: 230)
            }
            Advanced {
                Toggle("Parallel search with de-duplication", isOn: .constant(true))
                Stepper("Minimum seeders: 2", value: .constant(2))
            }
        }
    }
}

struct DownloadsPane: View {
    @State private var limit = 0.0
    @State private var killSwitch = true

    var body: some View {
        Pane {
            Section("Location") {
                LabeledContent("Download folder") { Text("~/Downloads/Marquee").foregroundStyle(.secondary) }
                LabeledContent("Free space") { Text("412 GB").foregroundStyle(.secondary) }
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
