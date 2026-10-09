import AppKit
import MarqueeUI
import SwiftUI

/// Developer hook: `Marquee --play <path-or-url>` opens the real player window on that media.
/// Extra flags simulate pipeline states for visual checks:
///   --player-sim findingPeers|metadata|buffering|ready|failed|stalled   (all but `stalled` never load the file)
///   --player-start <seconds>        start position
///   --player-episodes               add fake sibling episodes (enables Up Next and the episode list)
///   --player-title <text>
/// Not part of the product UI.
enum DebugPlayArgument {
    static var url: URL? {
        guard let value = argument("--play") else { return nil }
        if let url = URL(string: value), url.scheme != nil, !url.isFileURL { return url }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    fileprivate static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        if let inline = args.first(where: { $0.hasPrefix(name + "=") }) { return String(inline.dropFirst(name.count + 1)) }
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    fileprivate static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
}

struct PlayerDebugLauncher: View {
    let url: URL

    var body: some View {
        Color.black
            .task { @MainActor in present() }
    }

    @MainActor private func present() {
        debugLog("[player-debug] presenting \(url.path)")
        let sim = DebugPlayArgument.argument("--player-sim")
        let start = DebugPlayArgument.argument("--player-start").flatMap(Double.init) ?? 0
        let title = DebugPlayArgument.argument("--player-title") ?? "Harbor Lights"
        let art = Artwork.generated(PlaceholderArt(hue: 0.58, symbol: "sailboat.fill", variant: 2))
        let episodes = DebugPlayArgument.flag("--player-episodes")
            ? (1...6).map {
                PlayerEpisode(
                    id: "e\($0)", title: ["Low Tide", "Dust and Ashes", "The Long Way Round", "Night Shift", "Salt", "Homecoming"][$0 - 1],
                    subtitle: "S1 · E\($0)", artwork: .generated(PlaceholderArt(hue: 0.05 + Double($0) * 0.13, symbol: "film", variant: $0)),
                    bufferedFraction: $0 == 2 ? 0.8 : nil)
            } : []

        var status: AsyncStream<PlayerBufferingStatus>?
        var source = PlayerSource.url(url)
        switch sim {
        case "findingPeers", "metadata", "buffering", "ready", "failed":
            let value: PlayerBufferingStatus = switch sim {
            case "metadata": .fetchingMetadata
            case "buffering": .buffering(secondsAhead: 12)
            case "ready": .ready
            case "failed": .failed(message: "We couldn't find a healthy source for this episode. Try again, or pick another version.")
            default: .findingPeers
            }
            status = AsyncStream { $0.yield(value) }
            source = .deferred { try await Task.sleep(for: .seconds(3600)); return URL(fileURLWithPath: "/dev/null") }
        case "stalled":
            status = AsyncStream { $0.yield(.stalled(message: "Connection is slow. Still trying…")) }
        default: break
        }

        defer {
            // Only the player should be visible: hide the launcher's own window. Log the player window id.
            for w in NSApp.windows where !(w is PlayerWindow) { w.orderOut(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for w in NSApp.windows where w is PlayerWindow { debugLog("[player-debug] window \(w.windowNumber) \(w.frame)") }
            }
        }
        PlayerPresenter.shared.present(PlayerRequest(
            title: title, subtitle: episodes.isEmpty ? "" : "S1 · E1 · Low Tide", artwork: art, source: source, startPosition: start,
            statusUpdates: status, episodes: episodes, currentEpisodeID: episodes.first?.id,
            onNextEpisode: { next in debugLog("[player-debug] next episode: \(next.id)") },
            onClose: { _ in NSApp.terminate(nil) }))
    }
}


func debugLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
