import Foundation
import Testing
@testable import MarqueeCore

@Suite struct StreamingHTTPRequestParserTests {
    private func parse(_ s: String) throws -> HTTPRequestHead {
        try HTTPRequestParser.parse(Data(s.utf8))
    }

    @Test func parsesSimpleRequest() throws {
        let r = try parse("GET /abc/file.mkv?x=1 HTTP/1.1\r\nHost: 127.0.0.1:80\r\nRange: bytes=0-9\r\nX-Multi: a\r\nx-multi: b\r\n\r\n")
        #expect(r.method == "GET")
        #expect(r.target == "/abc/file.mkv?x=1")
        #expect(r.minorVersion == 1)
        #expect(r.header("HOST") == "127.0.0.1:80")
        #expect(r.header("range") == "bytes=0-9")
        #expect(r.header("x-multi") == "a, b")
        #expect(r.wantsKeepAlive)
    }

    @Test func keepAliveRules() throws {
        #expect(try !parse("GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n").wantsKeepAlive)
        #expect(try !parse("GET / HTTP/1.0\r\nHost: h\r\n\r\n").wantsKeepAlive)
        #expect(try parse("GET / HTTP/1.0\r\nHost: h\r\nConnection: Keep-Alive\r\n\r\n").wantsKeepAlive)
    }

    @Test(arguments: [
        "GET / HTTP/1.1\nHost: h\n\n",                                  // bare LF
        "GET / HTTP/1.1\r\nHost h\r\n\r\n",                             // no colon
        "GET / HTTP/1.1\r\nHost : h\r\n\r\n",                           // space before colon
        "GET / HTTP/1.1\r\nHost: h\r\n continued\r\n\r\n",              // obs-fold
        "GET /  HTTP/1.1\r\nHost: h\r\n\r\n",                           // double space
        "GET / HTTP/1.1 extra\r\nHost: h\r\n\r\n",
        "get / HTTP/1.1\r\nHost: h\r\n\r\n",                            // lowercase method
        "GET http://evil/ HTTP/1.1\r\nHost: h\r\n\r\n",                 // absolute-form
        "GET //x HTTP/1.1\r\nHost: h\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",                 // duplicate Host
        "GET / HTTP/1.1\r\nHost: h\r\nRange: bytes=0-1\r\nRange: bytes=2-3\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX: a\u{0}b\r\n\r\n",              // NUL
        "GET / HTTP/1.1\r\nHost: h\r\nX: caf\u{e9}\r\n\r\n",            // non-ASCII
        "GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 1x\r\n\r\n",
        "GET / FTP/1.1\r\nHost: h\r\n\r\n",
        "\r\n\r\n",
    ])
    func rejectsMalformed(_ raw: String) {
        #expect(throws: HTTPParseError.self) { try HTTPRequestParser.parse(Data(raw.utf8)) }
    }

    @Test func rejectsBodiesAndOtherVersions() {
        #expect(throws: HTTPParseError.bodyNotSupported) {
            try HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n".utf8))
        }
        #expect(throws: HTTPParseError.bodyNotSupported) {
            try HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
        #expect(throws: HTTPParseError.unsupportedVersion) {
            try HTTPRequestParser.parse(Data("GET / HTTP/2.0\r\nHost: h\r\n\r\n".utf8))
        }
        #expect((try? parse("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n")) != nil)
    }

    @Test func headLengthDetectionAndBounds() throws {
        let partial = Data("GET / HTTP/1.1\r\nHost: h\r\n".utf8)
        #expect(try HTTPRequestParser.headLength(in: partial) == nil)
        let full = Data("GET / HTTP/1.1\r\nHost: h\r\n\r\nGET /next".utf8)
        #expect(try HTTPRequestParser.headLength(in: full) == 27)
        let huge = Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.maxHeadBytes + 1)
        #expect(throws: HTTPParseError.headerTooLarge) { try HTTPRequestParser.headLength(in: huge) }
        var hugeWithEnd = Data("GET / HTTP/1.1\r\nX: ".utf8)
        hugeWithEnd.append(Data(repeating: UInt8(ascii: "a"), count: HTTPRequestParser.maxHeadBytes))
        hugeWithEnd.append(Data("\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.headerTooLarge) { try HTTPRequestParser.headLength(in: hugeWithEnd) }
    }

    @Test func tooManyHeaders() {
        var s = "GET / HTTP/1.1\r\nHost: h\r\n"
        for i in 0..<100 { s += "X-\(i): v\r\n" }
        s += "\r\n"
        #expect(throws: HTTPParseError.headerTooLarge) { try HTTPRequestParser.parse(Data(s.utf8)) }
    }
}

@Suite struct StreamingHTTPRangeTests {
    private func r(_ header: String?, _ length: Int64 = 1000) -> RangeResolution {
        HTTPRange.resolve(header, length: length)
    }

    @Test func satisfiable() {
        #expect(r("bytes=0-499") == .partial(0..<500))
        #expect(r("bytes=500-") == .partial(500..<1000))
        #expect(r("bytes=-100") == .partial(900..<1000))
        #expect(r("bytes=0-0") == .partial(0..<1))
        #expect(r("bytes=999-999") == .partial(999..<1000))
        #expect(r("BYTES=1-2") == .partial(1..<3))
        #expect(r(" bytes= 1 - 2 ") == .partial(1..<3))
    }

    @Test func clamping() {
        #expect(r("bytes=900-5000") == .partial(900..<1000))
        #expect(r("bytes=-5000") == .partial(0..<1000))
        #expect(r("bytes=0-99999999999999999999999") == .partial(0..<1000))
    }

    @Test func unsatisfiable() {
        #expect(r("bytes=1000-") == .unsatisfiable)
        #expect(r("bytes=1000-2000") == .unsatisfiable)
        #expect(r("bytes=-0") == .unsatisfiable)
        #expect(r("bytes=0-", 0) == .unsatisfiable)
        #expect(r("bytes=-5", 0) == .unsatisfiable)
        #expect(r("bytes=99999999999999999999999-") == .unsatisfiable)
    }

    @Test func ignoredHeaders() {
        #expect(r(nil) == .full)
        #expect(r("items=0-5") == .full)
        #expect(r("bytes=") == .full)
        #expect(r("bytes=-") == .full)
        #expect(r("bytes=abc-def") == .full)
        #expect(r("bytes=5-2") == .full)         // last < first is invalid syntax
        #expect(r("bytes=0-1,5-6") == .full)     // multi-range not supported
        #expect(r("bytes=0-1-2") == .full)
        #expect(r("bytes=-5-") == .full)
    }
}

@Suite struct StreamingServerHelperTests {
    @Test func hostAllowList() {
        #expect(ServerConnection.hostAllowed("127.0.0.1:5000", port: 5000))
        #expect(ServerConnection.hostAllowed("LocalHost:5000", port: 5000))
        #expect(!ServerConnection.hostAllowed("127.0.0.1:5001", port: 5000))
        #expect(!ServerConnection.hostAllowed("127.0.0.1", port: 5000))
        #expect(!ServerConnection.hostAllowed("evil.com:5000", port: 5000))
        #expect(!ServerConnection.hostAllowed("127.0.0.1.evil.com:5000", port: 5000))
        #expect(!ServerConnection.hostAllowed("", port: 5000))
    }

    @Test func originAllowList() {
        #expect(ServerConnection.originAllowed("http://localhost:3000"))
        #expect(ServerConnection.originAllowed("http://127.0.0.1"))
        #expect(ServerConnection.originAllowed("http://[::1]:80"))
        #expect(!ServerConnection.originAllowed("http://evil.com"))
        #expect(!ServerConnection.originAllowed("http://localhost.evil.com"))
        #expect(!ServerConnection.originAllowed("null"))
        #expect(!ServerConnection.originAllowed(""))
    }

    @Test func tokenExtraction() {
        let t = String(repeating: "ab", count: 16)
        #expect(ServerConnection.token(fromTarget: "/\(t)/movie.mkv") == t)
        #expect(ServerConnection.token(fromTarget: "/\(t)") == t)
        #expect(ServerConnection.token(fromTarget: "/\(t)/a%20b.mkv?x=1") == t)
        #expect(ServerConnection.token(fromTarget: "/\(t.uppercased())/x") == t)
        #expect(ServerConnection.token(fromTarget: "/\(t)0/x") == nil)
        #expect(ServerConnection.token(fromTarget: "/abc/x") == nil)
        #expect(ServerConnection.token(fromTarget: "/") == nil)
        #expect(ServerConnection.token(fromTarget: "/zz" + t.dropFirst(2) + "/x") == nil)
    }

    @Test func filenameSanitising() {
        #expect(StreamServer.urlSafeFilename("My Movie (2020).mkv") == "My%20Movie%20(2020).mkv")
        #expect(StreamServer.urlSafeFilename("a/b\\c.mp4") == "a_b_c.mp4")
        #expect(StreamServer.urlSafeFilename("  ") == "stream")
    }
}
