import MarqueePlayer
import MarqueeUI
import SwiftUI

/// The player window's content: video, pre-roll, transport overlay, HUD, stats and Up Next.
struct PlayerRootView: View {
    let session: PlayerSession

    var body: some View {
        ZStack {
            Color.black
            if let engine = session.engine {
                MPVPlayerView(engine: engine)
                    // A swapped session (Up Next) has a new engine; the video view is bound to one engine for life.
                    .id(ObjectIdentifier(engine))
                    .accessibilityHidden(true)
            }
            PlayerInputLayer(onClick: { session.togglePlayPause() }, onDoubleClick: { session.toggleFullScreen() })
                .accessibilityHidden(true)

            if session.stallLine != nil || session.hud != nil || session.showStats {
                overlayStatus
            }
            if session.hasStartedPlaying && session.controlsVisible {
                PlayerTransport(session: session).transition(.opacity)
            }
            if session.showsPreroll { preroll }
            PlayerTopBar(session: session)
            upNext
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .background(Color.black)
    }

    private var preroll: some View {
        let request = session.request
        let phase: PlayerPrerollView.Phase = session.failureMessage.map { .failed(message: $0) }
            ?? .working(status: session.prerollStatusLine)
        return PlayerPrerollView(
            title: request.title, subtitle: request.subtitle, artwork: request.artwork, phase: phase,
            onRetry: { session.retry() }, onClose: { session.requestClose() })
            .transition(.opacity)
    }

    private var overlayStatus: some View {
        ZStack {
            if let hud = session.hud {
                PlayerHUDPill(hud.text, systemImage: hud.symbol)
                    .id(hud.id)
                    .transition(.opacity)
                    .padding(.top, session.isFullScreen ? 36 : 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if let stall = session.stallLine {
                HStack(spacing: 12) {
                    ProgressRing(fraction: nil, lineWidth: 2.5, tint: .white).frame(width: 20, height: 20)
                    Text(verbatim: stall).font(.system(size: 14, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .marqueeGlass(in: Capsule())
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
            if session.showStats {
                PlayerStatsPanel(lines: StatsLines.make(stats: session.stats, snapshot: session.snapshot))
                    .padding(.top, 76)
                    .padding(.trailing, 28)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var upNext: some View {
        if session.upNextVisible, let next = session.nextEpisode {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PlayerUpNextCard(
                        episode: next, secondsRemaining: session.upNextSeconds,
                        fractionRemaining: 1 - Double(session.upNextSeconds) / 30,
                        onPlayNow: { session.playNext() }, onCancel: { session.cancelUpNext() })
                }
            }
            .padding(.trailing, 28)
            .padding(.bottom, session.controlsVisible ? 164 : 36)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .motion(Tokens.Motion.smooth, value: session.controlsVisible)
        }
    }
}

// MARK: - Top bar

private struct PlayerTopBar: View {
    let session: PlayerSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                if session.hasStartedPlaying && session.failureMessage == nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: session.request.title)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                        if !session.request.subtitle.isEmpty {
                            Text(verbatim: session.request.subtitle)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
                    .padding(.leading, session.isFullScreen ? 0 : 76)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                PlayerGlassCircleButton(systemImage: "xmark", label: "Close player") { session.requestClose() }
                    .onHover { session.controlsHoverChanged($0) }
            }
            .padding(.leading, 28)
            .padding(.trailing, 20)
            .padding(.top, session.isFullScreen ? 28 : 10)
            .foregroundStyle(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .opacity(session.hasStartedPlaying ? 1 : 0)
                .allowsHitTesting(false)
        }
        .opacity(session.controlsVisible || !session.hasStartedPlaying ? 1 : 0)
        .allowsHitTesting(session.controlsVisible || !session.hasStartedPlaying)
        .accessibilityHidden(!(session.controlsVisible || !session.hasStartedPlaying))
    }
}

// MARK: - Transport

private struct PlayerTransport: View {
    let session: PlayerSession
    @State private var showEpisodes = false

    var body: some View {
        let s = session.snapshot
        VStack(spacing: 0) {
            Spacer()
            panel(s)
                .padding(.horizontal, 28)
                .padding(.bottom, session.isFullScreen ? 36 : 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .allowsHitTesting(false)
        }
        .opacity(session.controlsVisible ? 1 : 0)
        .allowsHitTesting(session.controlsVisible)
        .accessibilityHidden(!session.controlsVisible)
    }

    private func panel(_ s: PlaybackSnapshot) -> some View {
        VStack(spacing: 4) {
            PlayerScrubber(
                position: s.position, duration: s.duration, bufferedAhead: s.bufferedAhead, isEnabled: session.isSeekable,
                onScrubbing: { session.scrubbingChanged($0) }, onSeek: { session.seek(to: $0) })
            ZStack {
                HStack(spacing: 0) {
                    volume(s)
                    Spacer(minLength: 0)
                    trailing(s)
                }
                transport(s)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: 860)
        .marqueeGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onHover { session.controlsHoverChanged($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Playback controls"))
    }

    private func transport(_ s: PlaybackSnapshot) -> some View {
        let playing = s.state == .playing || (s.state == .buffering && session.hasStartedPlaying)
        return HStack(spacing: 14) {
            Button { session.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(.playerIcon)
                .help("Back 10 seconds (←)")
                .accessibilityLabel(Text("Skip back 10 seconds"))
                .disabled(!session.isSeekable)
            Button { session.togglePlayPause() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .buttonStyle(.playerIconProminent)
                .help(playing ? Text("Pause (Space)") : Text("Play (Space)"))
                .accessibilityLabel(playing ? Text("Pause") : Text("Play"))
            Button { session.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                .buttonStyle(.playerIcon)
                .help("Forward 10 seconds (→)")
                .accessibilityLabel(Text("Skip forward 10 seconds"))
                .disabled(!session.isSeekable)
        }
    }

    private func volume(_ s: PlaybackSnapshot) -> some View {
        let level = session.isMuted ? 0 : s.volume
        let symbol = level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        return HStack(spacing: 2) {
            Button { session.toggleMute() } label: { Image(systemName: symbol).frame(width: 20) }
                .buttonStyle(.playerIcon)
                .help(session.isMuted ? Text("Unmute (M)") : Text("Mute (M)"))
                .accessibilityLabel(session.isMuted ? Text("Unmute") : Text("Mute"))
            PlayerSlider(value: level, label: "Volume") { session.setVolume($0) }
        }
    }

    private func trailing(_ s: PlaybackSnapshot) -> some View {
        HStack(spacing: 2) {
            if session.request.episodes.count > 1 { episodesButton }
            speedMenu(s)
            audioMenu(s)
            subtitleMenu(s)
            Button { session.toggleFullScreen() } label: {
                Image(systemName: session.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.playerIcon)
            .help(session.isFullScreen ? Text("Exit Full Screen (F)") : Text("Enter Full Screen (F)"))
            .accessibilityLabel(session.isFullScreen ? Text("Exit full screen") : Text("Enter full screen"))
        }
    }

    // MARK: Menus

    private func speedMenu(_ s: PlaybackSnapshot) -> some View {
        Menu {
            Picker("Playback speed", selection: Binding(get: { s.speed }, set: { session.setSpeed($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
                    Text(verbatim: speed == 1 ? String(localized: "Normal") : "\(speed.formatted(.number.precision(.fractionLength(0...2))))×")
                        .tag(speed)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if abs(s.speed - 1) > 0.01 {
                Text(verbatim: "\(s.speed.formatted(.number.precision(.fractionLength(0...2))))×")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
            } else {
                Image(systemName: "speedometer")
            }
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.playerIcon).fixedSize()
        .help("Playback speed")
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(verbatim: "\(s.speed.formatted(.number.precision(.fractionLength(0...2))))×"))
    }

    private func audioMenu(_ s: PlaybackSnapshot) -> some View {
        Menu {
            Picker("Audio", selection: Binding<Int?>(get: { s.selectedAudioTrack }, set: { session.selectAudio($0) })) {
                ForEach(s.audioTracks) { track in Text(verbatim: track.menuTitle()).tag(Int?.some(track.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "waveform")
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.playerIcon).fixedSize()
        .disabled(s.audioTracks.isEmpty)
        .help("Audio (A)")
        .accessibilityLabel(Text("Audio tracks"))
    }

    private func subtitleMenu(_ s: PlaybackSnapshot) -> some View {
        Menu {
            Picker("Subtitles", selection: Binding<Int?>(get: { s.selectedSubtitleTrack }, set: { session.selectSubtitle($0) })) {
                Text("Off").tag(Int?.none)
                ForEach(s.subtitleTracks) { track in Text(verbatim: track.menuTitle()).tag(Int?.some(track.id)) }
            }
            .pickerStyle(.inline)
            if s.selectedSubtitleTrack != nil {
                Divider()
                Text(verbatim: String(localized: "Timing: \(SubtitleDelay.label(session.subtitleDelay))"))
                Button("Show Earlier") { session.nudgeSubtitleDelay(-SubtitleDelay.step) }
                Button("Show Later") { session.nudgeSubtitleDelay(SubtitleDelay.step) }
                Button("Reset Timing") { session.nudgeSubtitleDelay(0) }
                    .disabled(session.subtitleDelay == 0)
            }
        } label: {
            Image(systemName: s.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.playerIcon).fixedSize()
        .disabled(s.subtitleTracks.isEmpty)
        .help("Subtitles (S)")
        .accessibilityLabel(Text("Subtitles"))
    }

    private var episodesButton: some View {
        Button { showEpisodes.toggle() } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.playerIcon)
            .help("Episodes")
            .accessibilityLabel(Text("Episodes"))
            .popover(isPresented: $showEpisodes, arrowEdge: .top) {
                EpisodeStrip(session: session) { showEpisodes = false }
            }
            .onChange(of: showEpisodes) { _, open in session.menuTrackingChanged(open) }
    }
}

/// Episode list for binge viewing: the current season in play order with pre-buffer state per episode.
private struct EpisodeStrip: View {
    let session: PlayerSession
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(session.request.episodes) { episode in
                    let isCurrent = episode.id == session.request.currentEpisodeID
                    Button {
                        dismiss()
                        if !isCurrent { session.play(episode: episode) }
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if let art = episode.artwork { ArtworkView(art, targetSize: CGSize(width: 96, height: 54)) }
                                else { Color.white.opacity(0.1) }
                            }
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: episode.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(verbatim: episode.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if isCurrent {
                                Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                            } else if let f = episode.bufferedFraction {
                                ProgressRing(fraction: f, lineWidth: 2.5).frame(width: 18, height: 18)
                            }
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(episode.subtitle), \(episode.title)"))
                    .accessibilityValue(isCurrent ? Text("Now playing") : Text(verbatim: episode.bufferedFraction.map { String(localized: "\(Formatters.percent($0)) ready") } ?? ""))
                }
            }
            .padding(8)
        }
        .frame(width: 340)
        .frame(maxHeight: 360)
    }
}

// MARK: - Stats

enum StatsLines {
    static func make(stats: PlaybackStats, snapshot: PlaybackSnapshot) -> [PlayerStatsPanel.Line] {
        var lines: [PlayerStatsPanel.Line] = []
        if let w = stats.videoWidth, let h = stats.videoHeight {
            lines.append(.init("Video", "\(w)×\(h)" + (stats.videoFormat.map { " · \($0)" } ?? "")))
        }
        lines.append(.init("Decode", stats.hwdec == nil ? "—" : stats.isHardwareDecoding ? "Hardware (\(stats.hwdec ?? ""))" : "Software"))
        if let fps = stats.framesPerSecond { lines.append(.init("Frame rate", fps.formatted(.number.precision(.fractionLength(2))) + " fps")) }
        if let b = stats.videoBitrate { lines.append(.init("Video bitrate", bitrate(b))) }
        if stats.audioCodec != nil || stats.audioBitrate != nil {
            lines.append(.init("Audio", [stats.audioCodec, stats.audioBitrate.map(bitrate)].compactMap { $0 }.joined(separator: " · ")))
        }
        lines.append(.init("Dropped", "\(stats.droppedFrames) render · \(stats.decoderDroppedFrames) decode"))
        if let c = stats.colorSummary { lines.append(.init("Color", c)) }
        lines.append(.init("Buffer", snapshot.bufferedAhead.map { String(localized: "\(Int($0.rounded())) s ahead") } ?? "—"))
        return lines
    }

    private static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? (bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " Mb/s"
            : Int(bitsPerSecond / 1000).formatted() + " kb/s"
    }
}
