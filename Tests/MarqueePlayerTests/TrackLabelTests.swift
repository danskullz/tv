import Foundation
import Testing
@testable import MarqueePlayer

@Suite struct TrackLabelTests {
    private let en = Locale(identifier: "en_US")

    @Test func audioLabelsCombineLanguageCodecAndLayout() {
        let t = MediaTrack(id: 1, kind: .audio, language: "eng", codec: "eac3", channelCount: 6)
        #expect(t.displayName(locale: en) == "English")
        #expect(t.detail == "Dolby Digital Plus · 5.1")
        #expect(t.menuTitle(locale: en) == "English — Dolby Digital Plus · 5.1")
    }

    @Test func untaggedLanguageFallsBackToTitleThenNumber() {
        #expect(MediaTrack(id: 2, kind: .audio, title: "Director's Cut", language: "und").displayName(locale: en) == "Director's Cut")
        #expect(MediaTrack(id: 3, kind: .audio).displayName(locale: en) == "Track 3")
    }

    @Test func subtitleFlags() {
        let forced = MediaTrack(id: 4, kind: .subtitle, language: "fre", codec: "hdmv_pgs_subtitle", isForced: true)
        #expect(forced.displayName(locale: en) == "French (Forced)")
        #expect(forced.detail == "PGS")
        let sdh = MediaTrack(id: 5, kind: .subtitle, title: "English SDH", language: "eng", codec: "subrip", isExternal: true)
        #expect(sdh.displayName(locale: en) == "English (SDH)")
        #expect(sdh.detail == "SRT · External")
    }

    @Test func audioCycleWraps() {
        let tracks = [MediaTrack(id: 1, kind: .audio), MediaTrack(id: 2, kind: .audio)]
        #expect(TrackCycling.nextAudio(in: tracks, after: 1) == 2)
        #expect(TrackCycling.nextAudio(in: tracks, after: 2) == 1)
        #expect(TrackCycling.nextAudio(in: tracks, after: nil) == 1)
        #expect(TrackCycling.nextAudio(in: [tracks[0]], after: 1) == nil)
    }

    @Test func subtitleCycleEndsWithOff() {
        let tracks = [MediaTrack(id: 1, kind: .subtitle), MediaTrack(id: 2, kind: .subtitle)]
        #expect(TrackCycling.nextSubtitle(in: tracks, after: nil) == .some(1))
        #expect(TrackCycling.nextSubtitle(in: tracks, after: 1) == .some(2))
        #expect(TrackCycling.nextSubtitle(in: tracks, after: 2) == .some(nil))
        #expect(TrackCycling.nextSubtitle(in: [], after: nil) == nil)
    }

    @Test func subtitleDelayStaysOnTheGrid() {
        var d = 0.0
        for _ in 0..<7 { d = SubtitleDelay.adjusted(d, by: 0.1) }
        #expect(SubtitleDelay.label(d) == "+0.7 s")
        d = SubtitleDelay.adjusted(d, by: -1.0)
        #expect(SubtitleDelay.label(d) == "\u{2212}0.3 s")
        #expect(SubtitleDelay.label(0) == "0.0 s")
    }
}
