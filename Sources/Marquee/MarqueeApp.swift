import SwiftUI
import MarqueeCore

@main
struct MarqueeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text(AppInfo.name).font(.largeTitle.bold())
                Text(AppInfo.tagline).foregroundStyle(.secondary)
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}
