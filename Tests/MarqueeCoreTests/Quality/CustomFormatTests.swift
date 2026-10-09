import Foundation
import Testing
@testable import MarqueeCore

@Suite struct CustomFormatTests {
    private let uhd = qualityMakeCandidate(
        "Movie.2021.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10Plus.H.265-FLUX", seeders: 50, sizeGB: 20, downloadVolumeFactor: 0)
    private let hd = qualityMakeCandidate("Movie.2021.1080p.BluRay.x264.DTS-HD.MA.5.1-SPARKS", seeders: 50, sizeGB: 10)

    private func spec(
        _ type: SpecificationType, _ value: String = "", negate: Bool = false, required: Bool = false
    ) -> FormatSpecification {
        FormatSpecification(type: type, value: value, negate: negate, required: required)
    }

    // MARK: Semantics

    @Test func formatWithoutSpecificationsNeverMatches() {
        #expect(!CustomFormatConfig(name: "empty", specifications: []).matches(uhd))
    }

    @Test func allRequiredSpecificationsMustPass() {
        let both = qualityFormat("both", spec(.hdr, "dv", required: true), spec(.resolution, "2160p", required: true))
        let oneWrong = qualityFormat("wrong", spec(.hdr, "dv", required: true), spec(.resolution, "1080p", required: true))
        #expect(both.matches(uhd))
        #expect(!oneWrong.matches(uhd))
    }

    @Test func atLeastOneOptionalOfEachTypeMustPass() {
        // hdr: either of two; audio: either of two. Both groups need a hit.
        let format = qualityFormat(
            "hdr+audio", spec(.hdr, "hdr10+"), spec(.hdr, "hdr10"), spec(.audioCodec, "atmos"), spec(.audioCodec, "trueHD"))
        #expect(format.matches(uhd))  // HDR10+ and Atmos
        let missingAudio = qualityFormat("hdr+audio", spec(.hdr, "hdr10+"), spec(.audioCodec, "trueHD"))
        #expect(!missingAudio.matches(uhd))  // an optional type with no hit fails the format
        let onlyOneType = qualityFormat("hdr only", spec(.hdr, "hdr10+"), spec(.hdr, "hlg"))
        #expect(onlyOneType.matches(uhd))
    }

    @Test func requiredAndOptionalCombine() {
        let format = qualityFormat(
            "mix", spec(.source, "web", required: true), spec(.hdr, "dolbyVision"), spec(.hdr, "hlg"))
        #expect(format.matches(uhd))
        #expect(!format.matches(hd))  // bluray fails the required source
    }

    @Test func negateInvertsASpecification() {
        let notRemux = qualityFormat("no remux", spec(.source, "remux", negate: true, required: true))
        #expect(notRemux.matches(uhd))
        let remux = qualityMakeCandidate("Movie.2021.2160p.UHD.BluRay.REMUX.HEVC-GRP")
        #expect(!notRemux.matches(remux))
        // A negated optional spec still counts toward its type group.
        let notAtmos = qualityFormat("not atmos", spec(.audioCodec, "atmos", negate: true))
        #expect(!notAtmos.matches(uhd))
        #expect(notAtmos.matches(hd))
    }

    @Test func negatedRequiredSpecificationRejectsWhenItMatches() {
        let format = qualityFormat("no 3d", spec(.releaseFlag, "threeD", negate: true, required: true))
        #expect(format.matches(uhd))
        #expect(!format.matches(qualityMakeCandidate("Movie.2021.1080p.BluRay.3D.x264-GRP")))
    }

    // MARK: Spec types

    @Test(arguments: [
        (SpecificationType.source, "WEB-DL", true), (.source, "web", true), (.source, "bluray", false),
        (.resolution, "4K", true), (.resolution, "2160p", true), (.resolution, "1080p", false),
        (.videoCodec, "x265", true), (.videoCodec, "HEVC", true), (.videoCodec, "x264", false),
        (.hdr, "HDR10+", true), (.hdr, "Dolby Vision", true), (.hdr, "DV", true), (.hdr, "hdr", true), (.hdr, "sdr", false),
        (.audioCodec, "Atmos", true), (.audioCodec, "DDP", true), (.audioCodec, "DTS-HD MA", false),
        (.audioChannels, "5.1", true), (.audioChannels, "7.1", false),
        (.releaseGroup, "flux", true), (.releaseGroup, "FLUX|NTb", true), (.releaseGroup, "FLU", false),
        (.indexerFlag, "freeleech", true), (.indexerFlag, "halfleech", false),
        (.releaseTitle, "\\bdv\\b", true), (.releaseTitle, "remux", false),
    ])
    func specTypesMatchAsExpected(_ type: SpecificationType, _ value: String, _ expected: Bool) {
        #expect(qualityFormat("t", spec(type, value)).matches(uhd) == expected, "\(type) \(value)")
    }

    @Test func sdrMatchesReleasesWithoutHDR() {
        #expect(qualityFormat("sdr", spec(.hdr, "sdr")).matches(hd))
    }

    @Test func languageEditionAndServiceSpecs() {
        let c = qualityMakeCandidate("Movie.2019.Directors.Cut.MULTi.1080p.AMZN.WEB-DL.DDP5.1.H.264-GRP")
        #expect(qualityFormat("e", spec(.edition, "Director's Cut")).matches(c))
        #expect(qualityFormat("l", spec(.language, "multi")).matches(c))
        #expect(qualityFormat("s", spec(.streamingService, "amzn")).matches(c))
        #expect(!qualityFormat("s", spec(.streamingService, "nf")).matches(c))
    }

    @Test func sizeRangeUsesGiB() {
        let inRange = qualityFormat("r", FormatSpecification(type: .size, min: 15, max: 25))
        #expect(inRange.matches(uhd))
        #expect(!inRange.matches(hd))
        let noSize = qualityMakeCandidate("Movie.2021.1080p.WEB-DL-GRP", sizeGB: nil)
        #expect(!inRange.matches(noSize))
        #expect(qualityFormat("open", FormatSpecification(type: .size, max: 12)).matches(hd))
    }

    @Test func releaseFlagProperMatchesVersionTwo() {
        let proper = qualityMakeCandidate("Show.S01E01.PROPER.1080p.WEB-DL.H.264-GRP")
        #expect(qualityFormat("p", spec(.releaseFlag, "proper")).matches(proper))
    }

    // MARK: Patterns

    @Test func invalidRegexNeverMatchesAndIsReported() {
        let format = qualityFormat("bad", spec(.releaseTitle, "([unclosed"))
        #expect(!format.matches(uhd))
        #expect(format.validationIssues.count == 1)
        #expect(qualityFormat("ok", spec(.releaseTitle, "flux")).validationIssues.isEmpty)
    }

    @Test func literalFastPathAgreesWithRegexEngine() throws {
        let patterns = [
            "\\b(flux|sparks)\\b", "FLUX", "^movie", "-FLUX$", "\\batmos\\b", "(?:dv|hdr10plus)", "h\\.265", "web-dl",
            "\\b(dts-hd|truehd)\\b", "^movie.2021$", "ux", "\\bdd\\b", "2160p|1080p",
        ]
        let titles = [
            "Movie.2021.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10Plus.H.265-FLUX", "Movie.2021.1080p.BluRay.x264.DTS-HD.MA.5.1-SPARKS",
            "Movie.2021", "Another.Title.1080p.WEB-DL.DD5.1.x264-FLUXX", "movie 2021 1080p web-dl", "SPARKSflux",
        ]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let matcher = PatternMatcher.make(pattern, wholeString: false)
            for title in titles {
                let expected = regex.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) != nil
                let actual = matcher.matches(Array(title.lowercased().utf8), original: title)
                #expect(actual == expected, "pattern \(pattern) on \(title)")
            }
        }
    }

    @Test func releaseGroupMatchesWholeNameOnly() {
        let c = qualityMakeCandidate("Movie.2021.1080p.WEB-DL.H.264-SPARKS2")
        #expect(!qualityFormat("g", spec(.releaseGroup, "SPARKS")).matches(c))
        #expect(qualityFormat("g", spec(.releaseGroup, "SPARKS2")).matches(c))
        #expect(qualityFormat("g", spec(.releaseGroup, "SPARK.*")).matches(c))
    }

    @Test func attributeBitsFollowDeclarationOrder() {
        func check<T: CaseIterable>(_ type: T.Type) {
            for (index, value) in T.allCases.enumerated() { #expect(CandidateFacts.bit(value) == 1 << UInt64(index)) }
            #expect(T.allCases.count <= 64)
        }
        check(Source.self); check(VideoCodec.self); check(HDRFormat.self); check(AudioCodec.self)
        check(Language.self); check(Edition.self); check(ReleaseFlag.self)
    }

    // MARK: JSON

    @Test func specificationDecodesWithDefaults() throws {
        let json = #"{"type":"hdr","value":"DV"}"#
        let decoded = try JSONDecoder().decode(FormatSpecification.self, from: Data(json.utf8))
        #expect(decoded.type == .hdr)
        #expect(!decoded.negate && !decoded.required)
    }

    @Test func bundleFixtureImportsAndScores() throws {
        let bundle = try FormatBundle.decode(qualityFixtureData("example-bundle.json"))
        #expect(bundle.formats.count == 8)
        let imported = bundle.materialize()
        #expect(imported.profiles.count == 1)
        #expect(imported.warnings.contains { $0.contains("Format that does not exist") })

        let profile = imported.profiles[0]
        let engine = ReleaseDecisionEngine(
            DecisionContext(
                wanted: .movie("Movie", year: 2021, runtimeMinutes: 120), profile: profile, formats: imported.formats,
                now: qualityNow))
        let decision = engine.decide([uhd])[0]
        let names = Set(decision.matchedFormats.map(\.name))
        #expect(names.contains("DV with HDR10 fallback") == false)  // DV required, but HDR10 base layer is not tagged
        #expect(names.contains("Freeleech"))
        #expect(names.contains("No remux / not oversized"))
        #expect(!names.contains("Unwanted: hardcoded subs"))
    }

    @Test func bundleRoundTripsThroughExport() throws {
        let imported = try FormatBundle.decode(qualityFixtureData("example-bundle.json")).materialize()
        let exported = FormatBundle.export(name: "Round trip", formats: imported.formats, profiles: imported.profiles)
        let data = try exported.encoded()
        let again = try FormatBundle.decode(data).materialize()
        #expect(again.formats.map(\.name) == imported.formats.map(\.name))
        #expect(again.formats.map(\.specifications) == imported.formats.map(\.specifications))
        let scoreByName = { (r: FormatBundle.Imported) -> [String: Int] in
            let names = Dictionary(uniqueKeysWithValues: r.formats.map { ($0.id.uuidString, $0.name) })
            return Dictionary(uniqueKeysWithValues: r.profiles[0].formatScores.map { (names[$0.key]!, $0.value) })
        }
        #expect(scoreByName(again) == scoreByName(imported))
        #expect(again.profiles[0].cutoff == .bluray2160p)
    }

    @Test func importAssignsFreshIDs() throws {
        let bundle = try FormatBundle.decode(qualityFixtureData("example-bundle.json"))
        let a = bundle.materialize(), b = bundle.materialize()
        #expect(Set(a.formats.map(\.id)).isDisjoint(with: b.formats.map(\.id)))
    }
}
