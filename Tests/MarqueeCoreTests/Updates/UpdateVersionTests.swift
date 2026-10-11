import Testing
@testable import MarqueeCore

/// `UpdateVersion` exists because a lexicographic compare ranks `0.1.9` above `0.1.28`, and the
/// project's tags are `0.1.<github run_number>` — so that one bug pins every user on an old build.
@Suite("Update version ordering")
struct UpdateVersionTests {
    @Test func patchComponentsCompareAsNumbersNotAsText() {
        #expect(UpdateVersion("0.1.9") < UpdateVersion("0.1.10"))
        #expect(UpdateVersion("0.1.28") > UpdateVersion("0.1.9"))
        #expect(UpdateVersion("0.1.99") < UpdateVersion("0.1.100"))
        #expect(UpdateVersion("0.1.28") != UpdateVersion("0.1.29"))
        #expect(UpdateVersion("0.2.0") > UpdateVersion("0.1.999"))
        // The exact case the release workflow produces: run 9 then run 10.
        #expect([UpdateVersion("0.1.10"), UpdateVersion("0.1.9")].sorted() == ["0.1.9", "0.1.10"].map(UpdateVersion.init))
    }

    @Test func missingComponentsCountAsZero() {
        let short = UpdateVersion("1.2")
        let long = UpdateVersion("1.2.0")
        #expect(short.components == [1, 2])
        #expect(long.components == [1, 2, 0])
        // Neither is older than the other: as far as ordering is concerned they are one version.
        #expect(!(short < long))
        #expect(!(long < short))
        #expect(UpdateVersion("1.2.0.0").components == [1, 2, 0, 0])
        #expect(!(UpdateVersion("1.2.0.0") < UpdateVersion("1.2.0")))
        #expect(!(UpdateVersion("1.2.0") < UpdateVersion("1.2.0.0")))
        // BLOCKER (minor): ordering says `1.2` and `1.2.0` are the same version, but `Equatable` is
        // synthesised over `description`, so they are *not* equal. `Appcast.sortedReleases` then
        // leaves the two tied entries in whatever order the file happened to use, and
        // `sortedReleases.first` picks whichever. Not exploitable today — `make-appcast.sh` only
        // accepts `^[0-9.]+$` versions and refuses a re-publish of a version already in the feed, so
        // the two spellings can never appear together — but it is a latent inconsistency.
        #expect(short != long)
    }

    @Test func aPrereleaseSortsBelowTheFinishedRelease() {
        #expect(UpdateVersion("1.0.0-beta.1") < UpdateVersion("1.0.0"))
        #expect(!(UpdateVersion("1.0.0") < UpdateVersion("1.0.0-beta.1")))
        #expect(UpdateVersion("0.2.0-beta.3") < UpdateVersion("0.2.0"))
        #expect(UpdateVersion("1.0.0-beta.1").prerelease == "beta.1")
        #expect(UpdateVersion("1.0.0").prerelease == nil)
        #expect(UpdateVersion("1.0.0").components == [1, 0, 0])
        // A prerelease of a *newer* version still outranks a finished older one.
        #expect(UpdateVersion("1.1.0-beta.1") > UpdateVersion("1.0.0"))
    }

    @Test func prereleaseIdentifiersAreComparedAsNumbersNotAsText() {
        // semver: `-beta.10` is a *later* prerelease than `-beta.9`. A plain text compare would put
        // it first, and a client already on beta.9 would never be offered beta.10.
        #expect(UpdateVersion("1.0.0-beta.10") > UpdateVersion("1.0.0-beta.9"))
        #expect(UpdateVersion("1.0.0-beta.2") < UpdateVersion("1.0.0-beta.10"))
        #expect(UpdateVersion("1.0.0-beta.2") < UpdateVersion("1.0.0-beta.11"))
        // Equal prefix, longer identifier list wins.
        #expect(UpdateVersion("1.0.0-beta.1") < UpdateVersion("1.0.0-beta.1.1"))
        // Numeric identifiers rank below alphanumeric ones.
        #expect(UpdateVersion("1.0.0-1") < UpdateVersion("1.0.0-alpha"))
        #expect(UpdateVersion("1.0.0-rc.1") < UpdateVersion("1.0.0"))
    }

    @Test func aLeadingVIsStrippedFromTheNumbers() {
        #expect(UpdateVersion("v1.2.3").components == [1, 2, 3])
        #expect(UpdateVersion("V1.2.3").components == [1, 2, 3])
        #expect(!(UpdateVersion("v1.2.3") < UpdateVersion("1.2.3")))
        #expect(!(UpdateVersion("1.2.3") < UpdateVersion("v1.2.3")))
        #expect(UpdateVersion("v1.2.3-beta.1").prerelease == "beta.1")
        #expect(UpdateVersion("v1.2.3-beta.1") < UpdateVersion("v1.2.3"))
        // The original spelling is kept for diagnostics; the numbers are what ordering uses.
        #expect(UpdateVersion("v1.2.3").description == "v1.2.3")
    }

    @Test func aJunkComponentReadsAsZeroRatherThanFailingTheWholeCheck() {
        #expect(UpdateVersion("0.x.3").components == [0, 0, 3])
        #expect(UpdateVersion("0.x.3").components == UpdateVersion("0.0.3").components)
        #expect(UpdateVersion("banana").components == [0])
        #expect(UpdateVersion("").components == [0])
        #expect(UpdateVersion("...").components == [0])
        // Unorderable input reads as older than anything well-formed, which is the safe direction:
        // a typo in a version can never make a client think it is up to date.
        #expect(UpdateVersion("0.x.3") < UpdateVersion("0.0.4"))
        #expect(UpdateVersion("garbage") < UpdateVersion("0.0.1"))
        #expect(UpdateVersion.zero < UpdateVersion("0.0.1"))
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(UpdateVersion("  0.1.30\n").components == [0, 1, 30])
        #expect(UpdateVersion(" 0.1.30 ") == UpdateVersion("0.1.30"))
    }

    @Test func theComponentInitialiserRoundTrips() {
        let version = UpdateVersion(components: [1, 0, 0], prerelease: "beta.1")
        #expect(version.description == "1.0.0-beta.1")
        #expect(version == UpdateVersion("1.0.0-beta.1"))
        #expect(UpdateVersion(components: []).components == [0])
        #expect(UpdateVersion(components: []).description == "0")
        #expect(UpdateVersion(components: [2]).description == "2")
    }

    @Test func sortingNewestFirstIsStableAcrossTheProjectsRealTags() {
        let versions = ["0.1.9", "0.1.28", "0.1.10", "0.1.100", "0.2.0", "0.1.2"].map(UpdateVersion.init)
        let newestFirst = versions.sorted(by: >)
        #expect(newestFirst.map(\.description) == ["0.2.0", "0.1.100", "0.1.28", "0.1.10", "0.1.9", "0.1.2"])
    }
}
