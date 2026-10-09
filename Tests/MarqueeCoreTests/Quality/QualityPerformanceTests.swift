import Foundation
import Testing
@testable import MarqueeCore

@Suite(.serialized) struct QualityPerformanceTests {
    #if DEBUG
    static let budgetMs = 1000.0  // debug builds are 30x+ slower; the gates below apply to release
    static let regexHeavyBudgetMs = 2000.0
    #else
    static let budgetMs = 5.0
    /// Every regex that is not a plain literal alternation goes through NSRegularExpression (a few
    /// microseconds per candidate each), so a profile with extra general regexes gets a looser gate.
    static let regexHeavyBudgetMs = 10.0
    #endif

    /// CPU time of the calling thread: unaffected by other processes competing for the cores.
    private static func cpuMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    private static func makeCandidates(_ count: Int) -> [ReleaseCandidate] {
        let sources = ["WEB-DL", "WEBRip", "BluRay", "HDTV", "BluRay.REMUX"]
        let resolutions = ["720p", "1080p", "2160p"]
        let audio = ["DDP5.1", "DD5.1", "DTS-HD.MA.5.1", "TrueHD.7.1.Atmos", "AAC"]
        let hdr = ["", ".HDR", ".DV", ".HDR10Plus", ".DV.HDR10"]
        let groups = ["FLUX", "NTb", "SPARKS", "YIFY", "GRP", "CMRG", "RARBG", "EVO"]
        return (0..<count).map { i in
            let title = "Movie.2021.\(resolutions[i % 3]).\(sources[i % 5])\(hdr[(i / 3) % 5]).\(audio[(i / 5) % 5]).H.265-\(groups[i % 8])"
            return qualityMakeCandidate(
                title, seeders: (i * 37) % 900, sizeGB: 2 + Double(i % 40), ageHours: Double(i % 2000),
                indexer: i % 2 == 0 ? "A" : "B", guid: "g\(i)")
        }
    }

    @Test func ranking500CandidatesIsFast() {
        let candidates = Self.makeCandidates(500)
        // Realistic format set: built-ins plus a general regex (the regex engine fallback costs a few microseconds per candidate each) and a size rule.
        var formats = BuiltInFormats.all
        formats.append(qualityFormat("Scene regex", FormatSpecification(type: .releaseTitle, value: "\\b(x26[45]|h\\.26[45])\\b")))
        formats.append(qualityFormat("Big files", FormatSpecification(type: .size, min: 20)))
        var profile = QualityProfileConfig.best
        profile.formatScores[formats[formats.count - 2].id.uuidString] = 5
        profile.formatScores[formats[formats.count - 1].id.uuidString] = 10
        let context = DecisionContext(
            wanted: .movie("Movie", year: 2021, runtimeMinutes: 120), profile: profile, formats: formats,
            current: CurrentFile(tier: .webDL1080p), freeSpaceBytes: 500 * 1_073_741_824, now: qualityNow)
        let engine = ReleaseDecisionEngine(context)

        _ = engine.decide(candidates)  // warm caches (regex compile)
        var samples: [Double] = []
        var accepted = 0
        for _ in 0..<21 {
            let start = Self.cpuMs()
            let results = engine.decide(candidates)
            samples.append(Self.cpuMs() - start)
            accepted = results.accepted.count
        }
        // Thread CPU time, best of 21 runs; the median is printed for context.
        let best = samples.min()!
        let median = samples.sorted()[samples.count / 2]
        print("rank 500 candidates: best \(String(format: "%.2f", best)) ms, median \(String(format: "%.2f", median)) ms, worst \(String(format: "%.2f", samples.max()!)) ms (budget \(Self.regexHeavyBudgetMs) ms), accepted \(accepted)")
        #expect(accepted > 0)
        #expect(best < Self.regexHeavyBudgetMs)
    }

    @Test func ranking500CandidatesIncludingEngineConstructionIsFast() {
        let candidates = Self.makeCandidates(500)
        let context = DecisionContext(
            wanted: .movie("Movie", year: 2021, runtimeMinutes: 120), profile: .balanced, formats: BuiltInFormats.all, now: qualityNow)
        _ = ReleaseDecisionEngine.decide(candidates, in: context)
        var samples: [Double] = []
        for _ in 0..<11 {
            let start = Self.cpuMs()
            let results = ReleaseDecisionEngine.decide(candidates, in: context)
            samples.append(Self.cpuMs() - start)
        }
        let ms = samples.min()!
        print("rank 500 candidates incl. engine setup, built-in formats only: best \(String(format: "%.2f", ms)) ms")
        #expect(ms < Self.budgetMs)
    }
}
