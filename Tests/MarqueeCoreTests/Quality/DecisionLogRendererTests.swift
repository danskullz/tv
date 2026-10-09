import Testing
@testable import MarqueeCore

@Suite("Decision log rendering")
struct DecisionLogRendererTests {
    @Test func rendersPickedReleaseAndStreamabilityFacts() {
        let value: JSONValue = [
            "headline": "Picked because", "summary": "1080p WEB-DL (42 seeders)",
            "quality": "1080p WEB-DL", "profile": "Balanced", "formatScore": 150,
            "streamabilityScore": 82.5,
            "reasons": ["quality is in your profile", "custom format score +150 (HDR10, Atmos)", "42 seeders"],
            "streamability": [["name": "Health", "points": 18.0, "note": "42 seeders"], ["name": "Archive", "points": -8.0]],
            "candidates": ["rejections": ["tooFewSeeders": 2, "qualityNotAllowed": 1]],
            "failure": "peer disconnected",
        ]
        let result = DecisionLogRenderer.render(value)
        #expect(result.headline == "Picked because")
        #expect(result.summary == "1080p WEB-DL (42 seeders)")
        #expect(result.reasons.count == 3)
        #expect(result.streamability.first?.points == 18)
        #expect(result.rejectionCounts["tooFewSeeders"] == 2)
        #expect(result.failure == "peer disconnected")
    }

    @Test func olderOrSparseLogsRenderWithoutThrowing() {
        let result = DecisionLogRenderer.render(["summary": "SDTV"])
        #expect(result.headline == "Release decision")
        #expect(result.reasons.isEmpty)
        #expect(result.streamability.isEmpty)
    }
}
