import Foundation
import Security

/// Pure, I/O-free pieces of the Mac loopback HTTP Range relay: request parsing, host/origin/route
/// checks, `Range` resolution, response heads and the bounded chunk streamer. Nothing here opens a
/// socket or reads a remote file, so every rule can be exercised with plain values.
struct LoopbackHTTPRequest: Equatable, Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case head = "HEAD"
    }

    let method: Method
    let target: String
    /// Lower-cased header names. Security-relevant names are rejected when duplicated.
    let headers: [String: String]
}

enum LoopbackHTTPParseResult: Equatable, Sendable {
    case incomplete
    case request(LoopbackHTTPRequest)
    /// Reject with this HTTP status before any backend read.
    case rejected(Int)
}

enum LoopbackRangeResolution: Equatable, Sendable {
    case full
    case partial(ClosedRange<Int64>)
    /// Malformed, multiple, overflowing or beyond the end of the file (416).
    case unsatisfiable
}

enum LoopbackHTTP {
    static let maximumHeaderBytes = 8 * 1024
    static let maximumHeaderCount = 64
    static let routePrefix = "/v/"
    static let tokenByteCount = 32

    private static let uniqueHeaders: Set<String> = [
        "host", "origin", "range", "content-length", "transfer-encoding"
    ]

    // MARK: Request parsing

    static func parse(_ data: Data) -> LoopbackHTTPParseResult {
        let terminator = Data([13, 10, 13, 10])
        guard let found = data.range(of: terminator) else {
            return data.count > maximumHeaderBytes ? .rejected(431) : .incomplete
        }
        guard found.upperBound <= maximumHeaderBytes else { return .rejected(431) }
        guard let text = String(data: data[data.startIndex..<found.lowerBound], encoding: .ascii) else {
            return .rejected(400)
        }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count <= maximumHeaderCount + 1 else { return .rejected(431) }
        for line in lines where line.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 || $0.value == 0x7F }) {
            return .rejected(400)
        }

        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return .rejected(400)
        }
        guard let method = LoopbackHTTPRequest.Method(rawValue: requestLine[0]) else {
            return .rejected(405)
        }
        let target = requestLine[1]
        guard target.hasPrefix("/"), !target.contains("?"), !target.contains("#") else {
            return .rejected(400)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let name = line[line.startIndex..<colon].lowercased()
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ isTokenScalar($0) }) else { return .rejected(400) }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if headers[name] != nil, uniqueHeaders.contains(name) { return .rejected(400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .rejected(400) }
        if let length = headers["content-length"], length != "0" { return .rejected(400) }
        return .request(LoopbackHTTPRequest(method: method, target: target, headers: headers))
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case 0x2D, 0x5F, 0x2E: true // - _ .
        default: false
        }
    }

    // MARK: Host / Origin / route

    /// Returns the rejecting status, or nil when the request may proceed to a backend read.
    /// Host must be exactly `127.0.0.1:<bound port>` (not `localhost`); Origin is absent for a
    /// native client or exactly the same loopback origin; the route is exactly `/v/<token>`.
    static func rejection(for request: LoopbackHTTPRequest, token: String, boundPort: UInt16) -> Int? {
        let expectedHost = "127.0.0.1:\(boundPort)"
        guard request.headers["host"] == expectedHost else { return 403 }
        if let origin = request.headers["origin"], origin != "http://\(expectedHost)" { return 403 }
        guard constantTimeEquals(request.target, routePrefix + token) else { return 404 }
        return nil
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    // MARK: Range

    /// One `bytes=` range only: `start-end`, `start-` or suffix `-n`. Anything else is 416.
    static func resolveRange(_ header: String?, size: Int64) -> LoopbackRangeResolution {
        guard size > 0 else { return .unsatisfiable }
        guard let header else { return .full }
        let parts = header.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return .unsatisfiable }
        let spec = parts[1]
        guard !spec.contains(",") else { return .unsatisfiable }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .unsatisfiable }
        let startText = String(bounds[0])
        let endText = String(bounds[1])

        if startText.isEmpty {
            guard let suffix = decimal(endText), suffix > 0 else { return .unsatisfiable }
            let length = min(suffix, size)
            return .partial((size - length)...(size - 1))
        }
        guard let start = decimal(startText), start < size else { return .unsatisfiable }
        if endText.isEmpty { return .partial(start...(size - 1)) }
        guard let end = decimal(endText), end >= start else { return .unsatisfiable }
        return .partial(start...min(end, size - 1))
    }

    private static func decimal(_ text: String) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int64(text)
    }

    // MARK: Response heads

    /// 200/206 head and the byte span the body must cover. nil for an unsatisfiable range.
    static func successHead(
        resolution: LoopbackRangeResolution,
        size: Int64,
        contentType: String
    ) -> (head: Data, span: ClosedRange<Int64>)? {
        let span: ClosedRange<Int64>
        var headers: [(String, String)] = []
        let status: Int
        switch resolution {
        case .unsatisfiable:
            return nil
        case .full:
            guard size > 0 else { return nil }
            span = 0...(size - 1)
            status = 200
        case let .partial(range):
            span = range
            status = 206
            headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"))
        }
        headers.append(("Accept-Ranges", "bytes"))
        headers.append(("Content-Type", contentType))
        headers.append(("Content-Length", String(span.upperBound - span.lowerBound + 1)))
        return (head(status: status, headers: headers), span)
    }

    /// Fixed-text error head; `size` adds `Content-Range: bytes */size` (416).
    static func errorHead(status: Int, size: Int64? = nil) -> Data {
        var headers: [(String, String)] = [("Content-Length", "0")]
        if let size { headers.append(("Content-Range", "bytes */\(size)")) }
        if status == 405 { headers.append(("Allow", "GET, HEAD")) }
        return head(status: status, headers: headers)
    }

    private static func head(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        // Values are integers or fixed table strings only, so no request data reaches a header.
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(text.utf8)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 502: "Bad Gateway"
        default: "Service Unavailable"
        }
    }

    /// Known media types only; anything else is an opaque byte stream.
    static func contentType(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4": "video/mp4"
        case "m4v": "video/x-m4v"
        case "mov", "qt": "video/quicktime"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "ts", "mts", "m2ts": "video/mp2t"
        case "mpg", "mpeg", "mpe": "video/mpeg"
        case "wmv": "video/x-ms-wmv"
        case "flv": "video/x-flv"
        case "3gp": "video/3gpp"
        case "ogv": "video/ogg"
        case "mp3": "audio/mpeg"
        case "m4a", "m4b": "audio/mp4"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "oga", "ogg", "opus": "audio/ogg"
        case "aac": "audio/aac"
        default: "application/octet-stream"
        }
    }

    // MARK: Token

    /// 256 bits from the system CSPRNG, hex encoded (opaque capability, not derived from the item).
    static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum LoopbackStreamError: Error, Equatable {
    /// The service returned a different byte count than the requested chunk.
    case invalidChunk
}

/// Streams one resolved span in bounded chunks. The next remote read starts only after the
/// previous chunk's send has completed (`NWConnection.send` `.contentProcessed`), so memory stays
/// at one chunk and a slow player applies back-pressure all the way to the NAS.
enum LoopbackRangeStreamer {
    static let chunkSize = 256 * 1024

    static func stream(
        span: ClosedRange<Int64>,
        chunkSize: Int = LoopbackRangeStreamer.chunkSize,
        read: (_ offset: Int64, _ length: Int) async throws -> Data,
        send: (_ chunk: Data) async throws -> Void
    ) async throws {
        var offset = span.lowerBound
        while offset <= span.upperBound {
            try Task.checkCancellation()
            let remaining = span.upperBound - offset + 1
            let length = Int(min(Int64(max(chunkSize, 1)), remaining))
            let chunk = try await read(offset, length)
            guard chunk.count == length else { throw LoopbackStreamError.invalidChunk }
            try Task.checkCancellation()
            try await send(chunk)
            offset += Int64(length)
        }
    }
}
