import SwiftUI
import MarqueeUI

@main
struct MarqueeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            if let url = DebugPlayArgument.url {
                // Developer hook: `Marquee --play <path-or-url>` (see PlayerDebugView.swift).
                PlayerDebugView(url: url)
            } else {
                RootView()
                    .environment(model)
                    .environment(model.tracker)
                    .environment(model.lifecycle)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
        }

        Window("Component Gallery", id: "gallery") {
            GalleryView()
                .environment(model.tracker)
                .environment(model.lifecycle)
                .frame(minWidth: 760, minHeight: 600)
        }
        .defaultSize(width: 960, height: 760)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            ForEach(SidebarItem.allCases) { item in
                Button { model.go(to: item) } label: { Text(item.title) }
                    .keyboardShortcut(item.shortcutKey, modifiers: .command)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Command Palette…") { withMotion { model.isPaletteShown.toggle() } }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Component Gallery") { openWindow(id: "gallery") }
                .keyboardShortcut("g", modifiers: [.command, .option])
        }
    }
}
