import Foundation
import MarqueeCore
import MarqueePlayer
import Testing

@Suite(.enabled(if: MPVLibrary.shared != nil, "libmpv not built; run scripts/build-mpv.sh"))
struct MPVMediaProbeTests {
    @Test func probesCommittedMediaFixture() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "test-clip", withExtension: "mp4", subdirectory: "Fixtures"))
        let info = try await MPVMediaProbe().probe(fixture, timeout: .seconds(20))
        try MediaProbeValidation.validate(info, expectedRuntimeSeconds: nil, minimumDurationSeconds: 0.1)
        #expect(info.durationSeconds ?? 0 > 0)
        #expect(info.width ?? 0 > 0)
        #expect(info.height ?? 0 > 0)
    }

}
