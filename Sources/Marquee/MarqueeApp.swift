import AppKit
import SwiftUI
import MarqueeCore
import MarqueeUI

@main
struct MarqueeApp: App {
    @State private var model = AppModel.forLaunch()

    init() {
        // An installer only leaves its marker behind when the app it just replaced started; being
        // here is that proof, so the old bundle can go.
        AppUpdater.clearPendingInstallIfNeeded()
        guard UserDefaults.standard.bool(forKey: "openSettings") else { return }
        // Dev hook: `Marquee -openSettings YES` for looking at a pane without a human at the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let url = DebugPlayArgument.url {
                // Developer hook: `Marquee --play <path-or-url>` (see PlayerDebugLauncher.swift).
                PlayerDebugLauncher(url: url)
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
                .environment(model)
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
        CommandGroup(replacing: .newItem) {
            Button("Add to Library…") { model.isAddSheetShown = true }
                .keyboardShortcut("n", modifiers: .command)
        }
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
        CommandGroup(replacing: .appInfo) {
            Button("Check for Updates…") { Task { await model.updater.checkNow() } }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.updater.state.isBusy)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Component Gallery") { openWindow(id: "gallery") }
                .keyboardShortcut("g", modifiers: [.command, .option])
        }
    }
}
