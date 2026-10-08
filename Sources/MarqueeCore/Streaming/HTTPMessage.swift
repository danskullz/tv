import Foundation

/// A parsed HTTP/1.x request head (the server never accepts request bodies).
struct HTTPRequestHead: Equatable, Sendable {
    var method: String
    var target: String
    /// 0 for HTTP/1.0, 1 for HTTP/1.1.
    var minorVersion: Int
    /// Header names lowercased. Repeated headers are comma-joined (security-relevant ones are rejected instead).
    var headers: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Whether the connection may be reused after answering this request.
    var wantsKeepAlive: Bool {
        let tokens = (header("connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains("close") { return false }
        if minorVersion == 0 { return tokens.contains("keep-alive") }
        return true
    }
}

enum HTTPParseError: Error, Equatable {
    case headerTooLarge
    case malformed(String)
    case unsupportedVersion
    case bodyNotSupported
}

enum HTTPRequestParser {
    static let maxHeadBytes = 16 * 1024
    static let maxHeaderCount = 64
    private static let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
    /// Headers that must not be repeated (request smuggling / confusion hardening).
    private static let singleValued: Set<String> = ["host", "range", "origin", "content-length", "transfer-encoding", "connection"]

    /// Locates the end of the request head in `buffer`. Returns the byte count of the head including the
    /// blank line, nil if more data is needed, or throws if the head is already too large.
    static func headLength(in buffer: Data) throws -> Int? {
        if let r = buffer.range(of: terminator) {
            let n = r.upperBound - buffer.startIndex
            if n > maxHeadBytes { throw HTTPParseError.headerTooLarge }
            return n
        }
        if buffer.count > maxHeadBytes { throw HTTPParseError.headerTooLarge }
        return nil
    }

    /// Parses a complete head (including the trailing blank line).
    static func parse(_ head: Data) throws -> HTTPRequestHead {
        guard head.count <= maxHeadBytes else { throw HTTPParseError.headerTooLarge }
        // Only printable ASCII plus HT and the CRLF delimiters are allowed anywhere in the head.
        for b in head where (b < 0x20 && b != 0x09 && b != 0x0D && b != 0x0A) || b >= 0x7F {
            throw HTTPParseError.malformed("illegal byte")
        }
        guard let text = String(data: head, encoding: .ascii) else { throw HTTPParseError.malformed("encoding") }
        guard text.hasSuffix("\r\n\r\n") else { throw HTTPParseError.malformed("terminator") }
        // Every LF must be preceded by CR and every CR followed by LF.
        let bytes = Array(text.utf8)
        for i in bytes.indices {
            if bytes[i] == 0x0A, i == 0 || bytes[i - 1] != 0x0D { throw HTTPParseError.malformed("bare LF") }
            if bytes[i] == 0x0D, i + 1 >= bytes.count || bytes[i + 1] != 0x0A { throw HTTPParseError.malformed("bare CR") }
        }
        // CRLF is a single Character, so trim by UTF-8 count rather than Character count.
        let lines = String(decoding: text.utf8.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { throw HTTPParseError.malformed("empty request line") }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw HTTPParseError.malformed("request line") }
        let method = String(parts[0])
        let target = String(parts[1])
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && ($0.isUppercase || $0 == "-") }) else {
            throw HTTPParseError.malformed("method")
        }
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { throw HTTPParseError.malformed("target") }
        let minor: Int
        switch parts[2] {
        case "HTTP/1.1": minor = 1
        case "HTTP/1.0": minor = 0
        default:
            if parts[2].hasPrefix("HTTP/") { throw HTTPParseError.unsupportedVersion }
            throw HTTPParseError.malformed("version")
        }

        var headers: [String: String] = [:]
        let headerLines = lines.dropFirst()
        guard headerLines.count <= maxHeaderCount else { throw HTTPParseError.headerTooLarge }
        for line in headerLines {
            guard !line.isEmpty else { throw HTTPParseError.malformed("blank header line") }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw HTTPParseError.malformed("header") }
            let name = String(line[..<colon])
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }) else {
                throw HTTPParseError.malformed("header name")  // also rejects whitespace before the colon and obs-fold
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let key = name.lowercased()
            if let existing = headers[key] {
                if singleValued.contains(key) { throw HTTPParseError.malformed("duplicate \(key)") }
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }

        if headers["transfer-encoding"] != nil { throw HTTPParseError.bodyNotSupported }
        if let cl = headers["content-length"] {
            guard cl.allSatisfy(\.isASCII), cl.allSatisfy(\.isNumber), !cl.isEmpty else { throw HTTPParseError.malformed("content-length") }
            if cl.contains(where: { $0 != "0" }) { throw HTTPParseError.bodyNotSupported }
        }
        return HTTPRequestHead(method: method, target: target, minorVersion: minor, headers: headers)
    }
}

// MARK: - Range handling

enum RangeResolution: Equatable {
    /// No (usable) Range header: serve everything with 200.
    case full
    /// Serve this half-open byte range with 206.
    case partial(Range<Int64>)
    /// Serve 416.
    case unsatisfiable
}

enum HTTPRange {
    /// Resolves an RFC 9110 `Range` header against a representation of `length` bytes. Syntactically
    /// invalid headers, other units and multi-range requests are ignored (served as 200), as the RFC permits.
    static func resolve(_ header: String?, length: Int64) -> RangeResolution {
        guard let header else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .full }
        let first = String(spec[..<dash]).trimmingCharacters(in: .whitespaces)
        let last = String(spec[spec.index(after: dash)...]).trimmingCharacters(in: .whitespaces)

        // nil = not a number; digit strings too large for Int64 clamp to Int64.max.
        func number(_ s: String) -> Int64? {
            guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(s) ?? Int64.max
        }

        if first.isEmpty {
            // suffix: last n bytes
            guard let n = number(last) else { return .full }
            if n == 0 || length == 0 { return .unsatisfiable }
            return .partial(max(0, length - n)..<length)
        }
        guard let a = number(first) else { return .full }
        var b = length - 1
        if !last.isEmpty {
            guard let parsed = number(last) else { return .full }
            if parsed < a { return .full }  // invalid per RFC: ignore header
            b = min(parsed, length - 1)
        }
        if a >= length { return .unsatisfiable }
        return .partial(a..<(b + 1))
    }
}

// MARK: - Response heads

enum HTTPResponse {
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Status"
        }
    }

    /// Serializes a status line + headers + blank line.
    static func head(status: Int, headers: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }
}
