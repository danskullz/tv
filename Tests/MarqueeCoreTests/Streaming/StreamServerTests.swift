import Foundation
import Testing
@testable import MarqueeCore

@Suite struct StreamingServerTests {
    static let fileSize: Int64 = 3_000_000  // > several 256 KiB chunks, not chunk aligned

    struct Harness {
        let server: StreamServer
        let endpoint: StreamEndpoint
        let port: UInt16
        let dir: StreamTempDir
        let session: URLSession
    }

    func harness(size: Int64 = StreamingServerTests.fileSize, filename: String = "Movie (2020).mkv") async throws -> Harness {
        let dir = StreamTempDir()
        let file = dir.makePatternFile(size: size)
        let server = StreamServer()
        let endpoint = try await server.register(try FileByteSource(url: file), filename: filename)
        return Harness(server: server, endpoint: endpoint, port: try await server.start(), dir: dir, session: makeStreamSession())
    }

    // MARK: Basics

    @Test func urlShapeAndLoopbackOnly() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let url = h.endpoint.url
        #expect(url.scheme == "http" && url.host == "127.0.0.1" && url.port == Int(h.port))
        #expect(url.path == "/\(h.endpoint.token)/Movie (2020).mkv")
        #expect(h.endpoint.token.count == 32 && h.endpoint.token.allSatisfy(\.isHexDigit))

        // 128-bit tokens are unique
        let second = try await h.server.register(try FileByteSource(url: h.dir.url.appendingPathComponent("video.mkv")), filename: "x")
        #expect(second.token != h.endpoint.token)
    }

    @Test func fullGet() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let (data, resp) = try await streamFetch(h.endpoint.url, session: h.session)
        #expect(resp.statusCode == 200)
        #expect(resp.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(resp.value(forHTTPHeaderField: "Content-Type") == "video/x-matroska")
        #expect(resp.value(forHTTPHeaderField: "Content-Length") == "\(Self.fileSize)")
        #expect(data.count == Int(Self.fileSize))
        #expect(data == streamPatternBytes(offset: 0, count: Int(Self.fileSize)))
    }

    @Test func head() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let (data, resp) = try await streamFetch(h.endpoint.url, method: "HEAD", session: h.session)
        #expect(resp.statusCode == 200)
        #expect(data.isEmpty)
        #expect(resp.value(forHTTPHeaderField: "Content-Length") == "\(Self.fileSize)")
        #expect(resp.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        let (rd, rr) = try await streamFetch(h.endpoint.url, method: "HEAD", headers: ["Range": "bytes=10-19"], session: h.session)
        #expect(rr.statusCode == 206 && rd.isEmpty)
        #expect(rr.value(forHTTPHeaderField: "Content-Length") == "10")
        #expect(rr.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/\(Self.fileSize)")
    }

    // MARK: Ranges

    @Test(arguments: [
        ("bytes=0-0", 0, 0),
        ("bytes=0-99", 0, 99),
        ("bytes=262140-262150", 262_140, 262_150),          // crosses a chunk boundary
        ("bytes=100-2999999", 100, 2_999_999),
        ("bytes=2500000-", 2_500_000, 2_999_999),
        ("bytes=-1", 2_999_999, 2_999_999),
        ("bytes=-12345", 2_987_655, 2_999_999),
        ("bytes=-99999999", 0, 2_999_999),                   // suffix longer than file
        ("bytes=2999990-99999999", 2_999_990, 2_999_999),    // end clamped
    ])
    func ranges(spec: String, first: Int, last: Int) async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let (data, resp) = try await streamFetch(h.endpoint.url, headers: ["Range": spec], session: h.session)
        #expect(resp.statusCode == 206)
        #expect(resp.value(forHTTPHeaderField: "Content-Range") == "bytes \(first)-\(last)/\(Self.fileSize)")
        #expect(resp.value(forHTTPHeaderField: "Content-Length") == "\(last - first + 1)")
        #expect(data == streamPatternBytes(offset: Int64(first), count: last - first + 1))
    }

    @Test(arguments: ["bytes=3000000-", "bytes=3000000-3000010", "bytes=-0"])
    func unsatisfiableRange(spec: String) async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let (data, resp) = try await streamFetch(h.endpoint.url, headers: ["Range": spec], session: h.session)
        #expect(resp.statusCode == 416)
        #expect(resp.value(forHTTPHeaderField: "Content-Range") == "bytes */\(Self.fileSize)")
        #expect(data.isEmpty)
    }

    @Test func zeroLengthSource() async throws {
        let h = try await harness(size: 0)
        defer { Task { await h.server.stop() } }
        let (data, resp) = try await streamFetch(h.endpoint.url, session: h.session)
        #expect(resp.statusCode == 200 && data.isEmpty)
        let (_, r2) = try await streamFetch(h.endpoint.url, headers: ["Range": "bytes=0-"], session: h.session)
        #expect(r2.statusCode == 416)
    }

    // MARK: Rejections

    @Test func unknownTokenIs404() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let bogus = URL(string: "http://127.0.0.1:\(h.port)/\(String(repeating: "0", count: 32))/x.mkv")!
        let (_, resp) = try await streamFetch(bogus, session: h.session)
        #expect(resp.statusCode == 404)
        let garbage = URL(string: "http://127.0.0.1:\(h.port)/nope")!
        let (_, r2) = try await streamFetch(garbage, session: h.session)
        #expect(r2.statusCode == 404)
        let root = URL(string: "http://127.0.0.1:\(h.port)/")!
        let (_, r3) = try await streamFetch(root, session: h.session)
        #expect(r3.statusCode == 404)
    }

    @Test func hostHeaderIsEnforced() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let path = "/\(h.endpoint.token)/x.mkv"
        let port = h.port
        func status(host: String?) async -> Int? {
            await streamOffload {
                let c = try! StreamRawClient(port: port)
                c.send("GET \(path) HTTP/1.1\r\n" + (host.map { "Host: \($0)\r\n" } ?? "") + "Connection: close\r\nRange: bytes=0-9\r\n\r\n")
                return c.readResponse()?.status
            }
        }
        #expect(await status(host: "evil.example.com") == 403)
        #expect(await status(host: "evil.example.com:\(port)") == 403)
        #expect(await status(host: "127.0.0.1:\(port &+ 1)") == 403)
        #expect(await status(host: "127.0.0.1") == 403)
        #expect(await status(host: nil) == 403)
        #expect(await status(host: "127.0.0.1:\(port)") == 206)
        #expect(await status(host: "localhost:\(port)") == 206)
    }

    @Test func originHeaderIsEnforced() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let (_, bad) = try await streamFetch(h.endpoint.url, headers: ["Origin": "http://evil.example.com"], session: h.session)
        #expect(bad.statusCode == 403)
        let (_, null) = try await streamFetch(h.endpoint.url, headers: ["Origin": "null"], session: h.session)
        #expect(null.statusCode == 403)
        let (_, ok) = try await streamFetch(h.endpoint.url, headers: ["Origin": "http://localhost:8080", "Range": "bytes=0-1"], session: h.session)
        #expect(ok.statusCode == 206)
    }

    @Test func unsupportedMethodsAreRejected() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        for method in ["POST", "PUT", "DELETE", "OPTIONS"] {
            let (_, resp) = try await streamFetch(h.endpoint.url, method: method, session: h.session)
            #expect(resp.statusCode == 405, "\(method)")
            #expect(resp.value(forHTTPHeaderField: "Allow") == "GET, HEAD")
        }
    }

    @Test func malformedRequestsGet4xxAndClose() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let port = h.port
        let cases: [(String, Int)] = [
            ("GARBAGE\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n", 400),
            ("GET / HTTP/3.0\r\nHost: 127.0.0.1:\(port)\r\n\r\n", 505),
            ("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 4\r\n\r\nabcd", 501),
            ("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Big: " + String(repeating: "a", count: 20_000) + "\r\n\r\n", 431),
        ]
        for (raw, expected) in cases {
            let (status, closed) = await streamOffload {
                let c = try! StreamRawClient(port: port)
                c.send(raw)
                let r = c.readResponse()
                return (r?.status, c.isClosedByPeer())
            }
            #expect(status == expected, "\(raw.prefix(30))")
            #expect(closed)
        }
    }

    @Test func headerFloodWithoutTerminatorIsCutOff() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let port = h.port
        let status = await streamOffload {
            let c = try! StreamRawClient(port: port)
            c.send("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 100_000))
            return c.readResponse()?.status
        }
        #expect(status == 431)
    }

    // MARK: Keep-alive

    @Test func keepAliveServesSequentialAndPipelinedRequests() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let port = h.port
        let path = "/\(h.endpoint.token)/x.mkv"
        let responses: [StreamRawResponse?] = await streamOffload {
            let c = try! StreamRawClient(port: port)
            let host = "Host: 127.0.0.1:\(port)\r\n"
            var out: [StreamRawResponse?] = []
            for i in 0..<3 {  // sequential
                c.send("GET \(path) HTTP/1.1\r\n\(host)Range: bytes=\(i * 1000)-\(i * 1000 + 999)\r\n\r\n")
                out.append(c.readResponse())
            }
            // two pipelined in one write, including a HEAD and a 404
            c.send("GET \(path) HTTP/1.1\r\n\(host)Range: bytes=5-9\r\n\r\nHEAD \(path) HTTP/1.1\r\n\(host)\r\n")
            out.append(c.readResponse())
            out.append(c.readResponse(expectBody: false))
            c.send("GET /\(String(repeating: "1", count: 32))/x HTTP/1.1\r\n\(host)\r\n")
            out.append(c.readResponse())
            c.send("GET \(path) HTTP/1.1\r\n\(host)Range: bytes=7-7\r\n\r\n")  // still usable after a 404
            out.append(c.readResponse())
            return out
        }
        #expect(responses.count == 7 && responses.allSatisfy { $0 != nil })
        for i in 0..<3 {
            #expect(responses[i]?.status == 206)
            #expect(responses[i]?.body == streamPatternBytes(offset: Int64(i * 1000), count: 1000))
        }
        #expect(responses[3]?.body == streamPatternBytes(offset: 5, count: 5))
        #expect(responses[4]?.status == 200 && responses[4]?.body.isEmpty == true)
        #expect(responses[5]?.status == 404)
        #expect(responses[6]?.body == streamPatternBytes(offset: 7, count: 1))
    }

    @Test func connectionCloseIsHonoured() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let port = h.port
        let path = "/\(h.endpoint.token)/x.mkv"
        let (status, closed) = await streamOffload {
            let c = try! StreamRawClient(port: port)
            c.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nRange: bytes=0-3\r\n\r\n")
            let r = c.readResponse()
            return (r?.status, c.isClosedByPeer())
        }
        #expect(status == 206 && closed)
    }

    // MARK: Concurrency

    @Test func manyConcurrentRequests() async throws {
        let h = try await harness()
        defer { Task { await h.server.stop() } }
        let url = h.endpoint.url
        let session = h.session
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let first = (i * 73_331) % 2_900_000
                    let len = 50_000 + (i * 17_011) % 600_000
                    let last = min(first + len, 2_999_999)
                    let (data, resp) = try await streamFetch(url, headers: ["Range": "bytes=\(first)-\(last)"], session: session)
                    return resp.statusCode == 206 && data == streamPatternBytes(offset: Int64(first), count: last - first + 1)
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }

    @Test func moreConnectionsThanTheCapAreDropped() async throws {
        let dir = StreamTempDir()
        let file = dir.makePatternFile(size: 1000)
        let server = StreamServer(maxConnections: 2)
        defer { Task { await server.stop() } }
        let ep = try await server.register(try FileByteSource(url: file), filename: "a.mkv")
        let port = try await server.start()
        let path = ep.url.path
        let results: [Int?] = await streamOffload {
            let clients = (0..<3).map { _ -> StreamRawClient in try! StreamRawClient(port: port, receiveTimeout: 3) }
            return clients.map { c in
                c.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
                return c.readResponse()?.status
            }
        }
        #expect(results.filter { $0 == 200 }.count == 2)
        #expect(results.filter { $0 == nil }.count == 1)
    }

    // MARK: Prioritisation

    @Test func serverHintsSourceWithRequestedRange() async throws {
        let source = StreamRecordingSource(length: 30_000_000)
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(source, filename: "a.mp4")
        let session = makeStreamSession()
        // seek: tail request first, then a mid-file request
        _ = try await streamFetch(ep.url, headers: ["Range": "bytes=29000000-"], session: session)
        _ = try await streamFetch(ep.url, headers: ["Range": "bytes=12000000-12100000"], session: session)
        let calls = source.prioritizeCalls
        #expect(calls.first?.0 == 29_000_000)
        #expect(calls.contains { $0.0 == 12_000_000 })
        // the long streaming request re-hints as the playhead advances
        let streamingHints = calls.filter { $0.0 >= 29_000_000 }
        #expect(streamingHints.count >= 1)
        let (_, _) = try await streamFetch(ep.url, headers: ["Range": "bytes=0-"], session: session)
        #expect(source.prioritizeCalls.filter { $0.0 < 29_000_000 && $0.0 != 12_000_000 }.count >= 2)
    }

    // MARK: Growing source

    @Test func growingSourceBlocksThenCompletes() async throws {
        let dir = StreamTempDir()
        let pieceLength: Int64 = 256 * 1024
        let size: Int64 = pieceLength * 8
        let file = dir.makePatternFile(size: size)
        let map = PieceMap(pieceLength: pieceLength, torrentSize: size, fileOffset: 0, fileLength: size)!
        let avail = StreamManualAvailability(pieceCount: 8, completed: [0, 1])
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(GrowingFileByteSource(url: file, pieceMap: map, availability: avail), filename: "g.mkv")

        let session = makeStreamSession()
        let start = ContinuousClock.now
        let request = Task { try await streamFetch(ep.url, session: session) }
        try await Task.sleep(for: .milliseconds(300))
        avail.complete(2..<5)
        try await Task.sleep(for: .milliseconds(300))
        avail.complete(5..<8)
        let (data, resp) = try await request.value
        #expect(ContinuousClock.now - start >= .milliseconds(550))
        #expect(resp.statusCode == 200)
        #expect(data == streamPatternBytes(offset: 0, count: Int(size)))
    }

    @Test func growingSourceSeekOutOfOrderThenPlaysFromThere() async throws {
        let dir = StreamTempDir()
        let pieceLength: Int64 = 128 * 1024
        let size: Int64 = pieceLength * 16
        let file = dir.makePatternFile(size: size)
        let map = PieceMap(pieceLength: pieceLength, torrentSize: size, fileOffset: 0, fileLength: size)!
        // only the tail piece and head piece exist yet
        let avail = StreamManualAvailability(pieceCount: 16, completed: [0, 15])
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(GrowingFileByteSource(url: file, pieceMap: map, availability: avail), filename: "g.mkv")
        let session = makeStreamSession()

        let tail = try await streamFetch(ep.url, headers: ["Range": "bytes=-1000"], session: session)  // available -> immediate
        #expect(tail.1.statusCode == 206)
        #expect(tail.0 == streamPatternBytes(offset: size - 1000, count: 1000))

        let mid = Task { try await streamFetch(ep.url, headers: ["Range": "bytes=\(pieceLength * 8)-\(pieceLength * 8 + 99)"], session: session) }
        try await Task.sleep(for: .milliseconds(150))
        avail.complete([8])
        let (data, resp) = try await mid.value
        #expect(resp.statusCode == 206)
        #expect(data == streamPatternBytes(offset: pieceLength * 8, count: 100))
    }

    // MARK: Disconnect / revoke

    @Test func clientDisconnectCancelsPendingRead() async throws {
        let probe = StreamProbeSource()
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(probe, filename: "p.mp4")
        let port = try await server.start()
        let path = ep.url.path

        let client = try await streamOffloadTry { try StreamRawClient(port: port) }
        await streamOffload {
            client.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
            _ = client.readResponse(expectBody: false)  // headers arrive before any body bytes
        }
        #expect(await streamEventually { probe.readsStarted >= 1 })
        #expect(probe.readsCancelled == 0)
        await streamOffload { client.close() }
        #expect(await streamEventually { probe.readsCancelled >= 1 })
        #expect(await streamEventually { await server.connectionCount == 0 })
    }

    @Test func urlSessionCancellationCancelsPendingRead() async throws {
        let probe = StreamProbeSource()
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(probe, filename: "p.mp4")
        let session = makeStreamSession()
        let task = Task { try await streamFetch(ep.url, session: session) }
        #expect(await streamEventually { probe.readsStarted >= 1 })
        task.cancel()
        #expect(await streamEventually { probe.readsCancelled >= 1 })
    }

    @Test func revokingATokenClosesItsConnections() async throws {
        let probe = StreamProbeSource()
        let server = StreamServer()
        defer { Task { await server.stop() } }
        let ep = try await server.register(probe, filename: "p.mp4")
        let port = try await server.start()
        let path = ep.url.path
        let client = try await streamOffloadTry { try StreamRawClient(port: port) }
        await streamOffload {
            client.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
            _ = client.readResponse(expectBody: false)
        }
        #expect(await streamEventually { probe.readsStarted >= 1 })
        await server.revoke(token: ep.token)
        #expect(await streamEventually { probe.readsCancelled >= 1 })
        let closed = await streamOffload { client.isClosedByPeer() }
        #expect(closed)
        // Token is gone for new requests.
        let (_, resp) = try await streamFetch(ep.url, session: makeStreamSession())
        #expect(resp.statusCode == 404)
        #expect(await server.registrationCount == 0)
    }

    @Test func stopClosesEverything() async throws {
        let probe = StreamProbeSource()
        let server = StreamServer()
        let ep = try await server.register(probe, filename: "p.mp4")
        let session = makeStreamSession()
        let task = Task { try await streamFetch(ep.url, session: session) }
        #expect(await streamEventually { probe.readsStarted >= 1 })
        await server.stop()
        #expect(await streamEventually { probe.readsCancelled >= 1 })
        _ = try? await task.value
        #expect(await server.port == nil)
        // can be restarted on a fresh port
        let port = try await server.start()
        #expect(port != 0)
        await server.stop()
    }
}
