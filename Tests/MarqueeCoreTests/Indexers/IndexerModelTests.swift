import Foundation
import Testing
@testable import MarqueeCore

struct SecretStoreTests {
    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemorySecretStore()
        #expect(try store.get(account: "a") == nil)
        try store.set("one", account: "a")
        #expect(try store.get(account: "a") == "one")
        try store.set("two", account: "a")
        #expect(try store.get(account: "a") == "two")
        try store.delete(account: "a")
        #expect(try store.get(account: "a") == nil)
        try store.delete(account: "a")  // deleting a missing item is not an error
    }

    @Test func keychainStoreUsesDocumentedService() {
        #expect(KeychainSecretStore().service == "com.danskullz.marquee")
        #expect(KeychainSecretStore.defaultService == "com.danskullz.marquee")
    }
}

struct IndexerDefinitionTests {
    @Test func apiKeyIsNotPartOfTheEncodedDefinition() throws {
        let d = makeDefinition(categories: [5000], minimumSeeders: 3, tags: ["tv"])
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self).lowercased()
        #expect(!json.contains("apikey\":\""))
        #expect(!json.contains("secretkey"))
        let decoded = try JSONDecoder().decode(IndexerDefinition.self, from: JSONEncoder().encode(d))
        #expect(decoded == d)
    }

    @Test func apiKeyAccountIsStablePerIndexer() {
        let d = makeDefinition()
        #expect(d.apiKeyAccount == "indexer.\(d.id.uuidString.lowercased()).apikey")
        #expect(d.apiKeyAccount != makeDefinition().apiKeyAccount)
    }

    @Test func rateLimitIsClamped() {
        let r = IndexerRateLimit(minInterval: -5, burst: 0)
        #expect(r.minInterval == 0)
        #expect(r.burst == 1)
    }
}

struct RedactionAndErrorTests {
    @Test func redactsAPIKeyQueryParameters() {
        let text = "Failed https://x.example.invalid/api?t=search&apikey=SECRETKEY123&q=a and APIKEY=other&token=abc"
        let out = SecretRedactor.redact(text)
        #expect(!out.contains("SECRETKEY123"))
        #expect(!out.contains("other"))
        #expect(!out.contains("abc"))
        #expect(out.contains("t=search"))
        #expect(out.contains("q=a"))
    }

    @Test func redactsLiteralSecretsRawAndEncoded() {
        let out = SecretRedactor.redact("oops s3cret/key+1 and s3cret%2Fkey%2B1", secrets: ["s3cret/key+1"])
        #expect(!out.contains("s3cret"))
    }

    @Test func requestDescriptionRedactsURL() {
        let request = IndexerHTTPRequest(url: URL(string: "https://x.example.invalid/api?t=caps&apikey=SECRETKEY123")!)
        #expect(!request.description.contains("SECRETKEY123"))
    }

    @Test func apiErrorCodesMapToTypedErrors() {
        #expect(IndexerError.fromAPIError(code: 100, description: "bad") == .authenticationFailed(detail: "bad"))
        #expect(IndexerError.fromAPIError(code: 101, description: "suspended") == .authenticationFailed(detail: "suspended"))
        #expect(IndexerError.fromAPIError(code: 201, description: "p") == .apiError(code: 201, description: "p"))
    }

    @Test func userMessagesArePlainLanguage() {
        let errors: [IndexerError] = [
            .invalidConfiguration("x"), .authenticationFailed(detail: "x"), .rateLimited(retryAfter: 30),
            .rateLimited(retryAfter: nil), .serverError(status: 503), .httpStatus(404), .httpStatus(403), .httpStatus(418),
            .timeout, .network("x"), .malformedResponse("x"), .apiError(code: 910, description: ""),
            .apiError(code: 201, description: "Bad param"), .apiError(code: 900, description: ""),
            .unsupportedSearch("x"), .responseTooLarge, .cancelled,
        ]
        for e in errors {
            #expect(!e.userMessage.isEmpty)
            #expect(e.errorDescription == e.userMessage)
            #expect(!e.userMessage.contains("IndexerError"))
            #expect(!e.technicalDetail.isEmpty)
        }
        #expect(IndexerError.rateLimited(retryAfter: 30).userMessage.contains("30"))
        #expect(IndexerError.authenticationFailed(detail: "x").userMessage.contains("API key"))
    }

    @Test func retryAndHealthClassification() {
        #expect(IndexerError.serverError(status: 500).isRetryable)
        #expect(IndexerError.rateLimited(retryAfter: nil).isRetryable)
        #expect(IndexerError.timeout.isRetryable)
        #expect(!IndexerError.authenticationFailed(detail: "").isRetryable)
        #expect(!IndexerError.httpStatus(404).isRetryable)
        #expect(!IndexerError.unsupportedSearch("").countsAgainstHealth)
        #expect(!IndexerError.cancelled.countsAgainstHealth)
        #expect(IndexerError.timeout.countsAgainstHealth)
    }

    @Test func redactedErrorScrubsEmbeddedSecrets() {
        let e = IndexerError.network("could not load https://x.example.invalid/api?apikey=SECRETKEY123 SECRETKEY123")
        let r = e.redacted(secrets: ["SECRETKEY123"])
        #expect(!r.technicalDetail.contains("SECRETKEY123"))
    }
}

struct TokenBucketTests {
    @Test func burstThenSpacedByInterval() {
        var b = TokenBucket(limit: IndexerRateLimit(minInterval: 2, burst: 2), now: 0)
        #expect(b.reserve(now: 0) == 0)
        #expect(b.reserve(now: 0) == 0)
        #expect(b.reserve(now: 0) == 2)
        #expect(b.reserve(now: 0) == 4)
    }

    @Test func refillsOverTimeButNeverAboveBurst() {
        var b = TokenBucket(limit: IndexerRateLimit(minInterval: 1, burst: 2), now: 0)
        _ = b.reserve(now: 0)
        _ = b.reserve(now: 0)
        #expect(b.reserve(now: 10) == 0)
        #expect(b.reserve(now: 10) == 0)
        #expect(b.reserve(now: 10) == 1)  // only 2 tokens were available despite 10s idle
    }

    @Test func unlimitedNeverWaits() {
        var b = TokenBucket(limit: .unlimited, now: 0)
        for _ in 0..<20 { #expect(b.reserve(now: 0) == 0) }
    }

    @Test func blockDelaysUntilTime() {
        var b = TokenBucket(limit: .unlimited, now: 0)
        b.block(until: 5)
        #expect(b.reserve(now: 1) == 4)
        #expect(b.reserve(now: 6) == 0)
    }
}

struct BackoffTests {
    @Test func exponentialWithCap() {
        let d = { (a: Int) in IndexerBackoff.delay(attempt: a, base: 1, max: 10, jitter: 0, random: 0.5) }
        #expect(d(0) == 1)
        #expect(d(1) == 2)
        #expect(d(2) == 4)
        #expect(d(3) == 8)
        #expect(d(4) == 10)
        #expect(d(100) == 10)
    }

    @Test func jitterStaysWithinBounds() {
        #expect(IndexerBackoff.delay(attempt: 2, base: 1, max: 100, jitter: 0.5, random: 0) == 2)
        #expect(IndexerBackoff.delay(attempt: 2, base: 1, max: 100, jitter: 0.5, random: 1) == 4)
        #expect(IndexerBackoff.delay(attempt: 2, base: 1, max: 100, jitter: 0.5, random: 0.5) == 3)
    }

    @Test func parsesRetryAfter() {
        #expect(IndexerBackoff.parseRetryAfter("120") == 120)
        #expect(IndexerBackoff.parseRetryAfter(nil) == nil)
        #expect(IndexerBackoff.parseRetryAfter("soon") == nil)
        let now = Date(timeIntervalSince1970: 1_727_778_600)  // Tue, 01 Oct 2024 10:30:00 GMT
        #expect(IndexerBackoff.parseRetryAfter("Tue, 01 Oct 2024 10:31:00 GMT", now: now) == 60)
        #expect(IndexerBackoff.parseRetryAfter("Tue, 01 Oct 2024 10:00:00 GMT", now: now) == 0)
    }
}
