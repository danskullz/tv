import MarqueePlayer
import SwiftUI

/// Developer hook: `Marquee --play <path-or-url>` opens a window that plays the media with libmpv.
/// Used to verify the bundled LGPL libmpv end to end; not part of the product UI.
enum DebugPlayArgument {
    static var url: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--play"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        if let url = URL(string: value), url.scheme != nil, !url.isFileURL { return url }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
}

struct PlayerDebugView: View {
    let url: URL
    @State private var model: PlaybackViewModel?
    @State private var engine: MPVPlaybackEngine?
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let engine {
                MPVPlayerView(engine: engine)
            } else {
                Color.black
            }
            if let failure {
                Text(failure).foregroundStyle(.red).padding()
            } else if let model {
                let s = model.snapshot
                Text("\(String(describing: s.state))  \(s.position.formatted(.number.precision(.fractionLength(1)))) / \((s.duration ?? 0).formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .task {
            do {
                var config = MPVPlaybackEngine.Configuration()
                // Debug: MARQUEE_MPV_OPTIONS="terminal=yes,msg-level=all=v" passes raw libmpv options.
                for pair in (ProcessInfo.processInfo.environment["MARQUEE_MPV_OPTIONS"] ?? "").split(separator: ",") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { config.extraOptions[kv[0]] = kv[1] }
                }
                let engine = try MPVPlaybackEngine(configuration: config)
                self.engine = engine
                model = PlaybackViewModel(engine: engine)
                engine.load(url)
            } catch {
                failure = "\(error)"
            }
        }
        .onKeyPress(.space) { engine?.togglePause(); return .handled }
        .onDisappear { engine?.shutdown() }
    }
}
