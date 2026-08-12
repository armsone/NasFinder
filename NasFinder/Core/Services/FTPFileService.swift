import Foundation
import Network

enum FTPServiceError: LocalizedError, Sendable {
    case connectionFailed(String)
    case rejected(Int, String)
    case invalidPassiveResponse
    case invalidListing

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): "FTP 서버에 연결하지 못했습니다. \(message)"
        case .rejected(let code, let message): "FTP 서버가 요청을 거부했습니다. (\(code) \(message))"
        case .invalidPassiveResponse: "FTP 서버의 Passive 응답을 해석하지 못했습니다."
        case .invalidListing: "FTP 폴더 목록을 해석하지 못했습니다."
        }
    }
}

/// Passive-mode FTP driver for ipTIME ipDISK, ipTIME router USB storage and
/// standards-compliant FTP servers. FTP is unencrypted; the UI explicitly
/// recommends using it on a trusted LAN or through VPN.
actor FTPFileService: RemoteFileService {
    nonisolated let connection: RemoteConnection
    private let credential: RemoteCredential

    nonisolated var supportsRangeStreaming: Bool { true }
    nonisolated var permitsFullDownloadForVideoThumbnail: Bool { false }
    nonisolated var capabilities: RemoteFileServiceCapabilities {
        [.createFolder, .rename, .delete, .upload, .replaceFile, .serverSideMove]
    }

    init(connection: RemoteConnection, credential: RemoteCredential) {
        self.connection = connection
        self.credential = credential
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        let directory = normalized(path ?? connection.normalizedRootPath)
        do {
            let listing = try await directoryListing(command: "MLSD", directory: directory)
            return listing
                .split(whereSeparator: \.isNewline)
                .compactMap { parseMLSDLine(String($0), parent: directory) }
        } catch {
            // Older ipTIME firmware commonly supports only PASV + LIST.
            let listing = try await directoryListing(command: "LIST", directory: directory)
            return listing
                .split(whereSeparator: \.isNewline)
                .compactMap { parseLegacyListLine(String($0), parent: directory) }
        }
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await download(item) { _ in }
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        let session = try await loggedInSession()
        let dataConnection = try await session.openPassiveDataConnection()
        _ = try await session.command("RETR \(item.path)", accepting: 100..<200)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var completed: Int64 = 0
        do {
            try await dataConnection.receive { chunk in
                try handle.write(contentsOf: chunk)
                completed += Int64(chunk.count)
                await progress(.init(completedByteCount: completed, totalByteCount: item.size))
            }
            try handle.close()
            _ = try await session.readReply(accepting: 200..<300)
            await session.close()
            try RemoteDownloadIntegrityError.validate(
                expectedByteCount: item.size,
                actualByteCount: completed
            )
            return destination
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            await session.close()
            throw error
        }
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let session = try await loggedInSession()
        _ = try await session.command("REST \(offset)", accepting: 300..<400)
        let dataConnection = try await session.openPassiveDataConnection()
        _ = try await session.command("RETR \(item.path)", accepting: 100..<200)
        var result = Data()
        try await dataConnection.receive(maximumByteCount: length) { chunk in
            result.append(chunk.prefix(max(length - result.count, 0)))
        }
        await dataConnection.close()
        await session.close()
        return result
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let name = try RemotePath.validatedName(name)
        let destination = appending(name, to: directoryPath)
        let session = try await loggedInSession()
        _ = try await session.command("MKD \(destination)", accepting: 200..<300)
        await session.close()
        return RemoteFileItem(
            connectionID: connection.id,
            path: destination,
            name: name,
            kind: .folder,
            size: nil,
            modifiedAt: .now,
            contentTypeIdentifier: nil
        )
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let name = try RemotePath.validatedName(newName)
        let destination = appending(
            name,
            to: (item.path as NSString).deletingLastPathComponent
        )
        let session = try await loggedInSession()
        _ = try await session.command("RNFR \(item.path)", accepting: 300..<400)
        _ = try await session.command("RNTO \(destination)", accepting: 200..<300)
        await session.close()
        return RemoteFileItem(
            connectionID: item.connectionID,
            path: destination,
            name: name,
            kind: item.kind,
            size: item.size,
            modifiedAt: item.modifiedAt,
            contentTypeIdentifier: item.contentTypeIdentifier
        )
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let session = try await loggedInSession()
        _ = try await session.command(
            "\(item.isDirectory ? "RMD" : "DELE") \(item.path)",
            accepting: 200..<300
        )
        await session.close()
        return .init(
            operationID: context.operationID,
            operation: .delete,
            outcomes: [.succeeded(sourcePath: item.path)]
        )
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let requestedName = try RemotePath.validatedName(
            preferredName ?? localURL.lastPathComponent
        )
        let siblings = try await list(directory: directoryPath)
        let existing = siblings.first { $0.name == requestedName }
        let finalName: String
        switch conflictPolicy {
        case .fail:
            guard existing == nil else {
                throw RemoteFileOperationError.conflict(
                    sourcePath: localURL.path,
                    destinationPath: appending(requestedName, to: directoryPath)
                )
            }
            finalName = requestedName
        case .skip:
            if let existing {
                return .init(
                    operationID: context.operationID,
                    operation: .upload,
                    outcomes: [.skipped(
                        sourcePath: localURL.path,
                        destinationPath: existing.path,
                        issue: .init(
                            code: .conflict,
                            message: "같은 이름의 파일이 이미 있습니다."
                        )
                    )]
                )
            }
            finalName = requestedName
        case .replace:
            guard existing?.isDirectory != true else {
                throw RemoteFileOperationError.folderReplacementNotAllowed(
                    path: existing?.path ?? requestedName
                )
            }
            finalName = requestedName
        case .keepBoth:
            finalName = try RemotePath.keepBothName(
                for: requestedName,
                existingNames: siblings.map(\.name)
            )
        }
        let destination = appending(finalName, to: directoryPath)
        let session = try await loggedInSession()
        let dataConnection = try await session.openPassiveDataConnection()
        _ = try await session.command("STOR \(destination)", accepting: 100..<200)
        try await dataConnection.sendFile(at: localURL)
        _ = try await session.readReply(accepting: 200..<300)
        await session.close()
        return .init(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [.succeeded(
                sourcePath: localURL.path,
                destinationPath: destination
            )]
        )
    }

    private func loggedInSession() async throws -> FTPControlSession {
        let session = FTPControlSession(host: connection.host, port: connection.port)
        try await session.connect()
        _ = try await session.readReply(accepting: 200..<400)
        let userReply = try await session.command(
            "USER \(connection.username)",
            accepting: 200..<400
        )
        if userReply.code != 230 {
            _ = try await session.command("PASS \(credential.password)", accepting: 200..<300)
        }
        _ = try await session.command("TYPE I", accepting: 200..<300)
        return session
    }

    private func directoryListing(command: String, directory: String) async throws -> String {
        let session = try await loggedInSession()
        do {
            let dataConnection = try await session.openPassiveDataConnection()
            _ = try await session.command("\(command) \(directory)", accepting: 100..<200)
            let data = try await dataConnection.receiveAll()
            _ = try await session.readReply(accepting: 200..<300)
            await session.close()
            guard let listing = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw FTPServiceError.invalidListing
            }
            return listing
        } catch {
            await session.close()
            throw error
        }
    }

    private func parseMLSDLine(_ line: String, parent: String) -> RemoteFileItem? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let factsText = line[..<separator]
        let name = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        var facts: [String: String] = [:]
        for fact in factsText.split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { facts[pair[0].lowercased()] = pair[1] }
        }
        let isDirectory = facts["type"]?.lowercased() == "dir"
        return RemoteFileItem(
            connectionID: connection.id,
            path: appending(name, to: parent),
            name: name,
            kind: isDirectory ? .folder : .file,
            size: isDirectory ? nil : facts["size"].flatMap(Int64.init),
            modifiedAt: facts["modify"].flatMap(Self.ftpDateFormatter.date),
            contentTypeIdentifier: nil
        )
    }

    private func parseLegacyListLine(_ line: String, parent: String) -> RemoteFileItem? {
        let fields = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
        guard fields.count == 9 else { return nil }
        let permissions = String(fields[0])
        guard permissions.first == "d" || permissions.first == "-" else { return nil }
        let name = String(fields[8]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let isDirectory = permissions.first == "d"
        return RemoteFileItem(
            connectionID: connection.id,
            path: appending(name, to: parent),
            name: name,
            kind: isDirectory ? .folder : .file,
            size: isDirectory ? nil : Int64(fields[4]),
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }

    private func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private func appending(_ name: String, to path: String) -> String {
        let base = normalized(path)
        return base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private static let ftpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()
}

private struct FTPReply: Sendable {
    let code: Int
    let message: String
}

private final class FTPControlSession: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let connection: NWConnection
    private var receiveBuffer = Data()

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
    }

    func connect() async throws {
        try await connection.awaitReady()
    }

    func command(_ command: String, accepting range: Range<Int>) async throws -> FTPReply {
        try await connection.sendData(Data("\(command)\r\n".utf8))
        return try await readReply(accepting: range)
    }

    func readReply(accepting range: Range<Int>) async throws -> FTPReply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw FTPServiceError.connectionFailed(first)
        }
        var lines = [first]
        if first.dropFirst(3).first == "-" {
            while true {
                let line = try await readLine()
                lines.append(line)
                if line.hasPrefix("\(code) ") { break }
            }
        }
        let message = lines.joined(separator: " ")
        guard range.contains(code) else { throw FTPServiceError.rejected(code, message) }
        return FTPReply(code: code, message: message)
    }

    func openPassiveDataConnection() async throws -> FTPDataConnection {
        let port: UInt16
        do {
            let reply = try await command("EPSV", accepting: 200..<300)
            guard let start = reply.message.lastIndex(of: "("),
                  let end = reply.message[start...].firstIndex(of: ")") else {
                throw FTPServiceError.invalidPassiveResponse
            }
            let payload = reply.message[reply.message.index(after: start)..<end]
            guard let portText = payload.split(separator: "|").last,
                  let parsedPort = UInt16(portText) else {
                throw FTPServiceError.invalidPassiveResponse
            }
            port = parsedPort
        } catch {
            let reply = try await command("PASV", accepting: 200..<300)
            guard let start = reply.message.lastIndex(of: "("),
                  let end = reply.message[start...].firstIndex(of: ")") else {
                throw FTPServiceError.invalidPassiveResponse
            }
            let numbers = reply.message[reply.message.index(after: start)..<end]
                .split(separator: ",")
                .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 6, numbers[4] <= 255, numbers[5] <= 255 else {
                throw FTPServiceError.invalidPassiveResponse
            }
            port = numbers[4] * 256 + numbers[5]
        }
        let dataConnection = FTPDataConnection(host: host, port: port)
        try await dataConnection.connect()
        return dataConnection
    }

    func close() async {
        try? await connection.sendData(Data("QUIT\r\n".utf8))
        connection.cancel()
    }

    private func readLine() async throws -> String {
        while true {
            if let range = receiveBuffer.range(of: Data("\r\n".utf8)) {
                let line = receiveBuffer[..<range.lowerBound]
                receiveBuffer.removeSubrange(..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = try await connection.receiveData()
            guard !chunk.isEmpty else {
                throw FTPServiceError.connectionFailed("서버가 연결을 종료했습니다.")
            }
            receiveBuffer.append(chunk)
        }
    }
}

private final class FTPDataConnection: @unchecked Sendable {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func connect() async throws { try await connection.awaitReady() }

    func receiveAll() async throws -> Data {
        var result = Data()
        try await receive { result.append($0) }
        return result
    }

    func receive(
        maximumByteCount: Int = .max,
        handler: @escaping (Data) async throws -> Void
    ) async throws {
        var received = 0
        while received < maximumByteCount {
            let chunk = try await connection.receiveData(
                maximumLength: min(256 * 1_024, maximumByteCount - received)
            )
            if chunk.isEmpty { break }
            received += chunk.count
            try await handler(chunk)
        }
        connection.cancel()
    }

    func close() async { connection.cancel() }

    func sendFile(at url: URL) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 256 * 1_024) ?? Data()
            if data.isEmpty { break }
            try await connection.sendData(data)
        }
        try await connection.finishSending()
    }
}

private extension NWConnection {
    func awaitReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let gate = NWContinuationGate()
                stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if gate.claim() { continuation.resume() }
                    case .failed(let error):
                        if gate.claim() { continuation.resume(throwing: error) }
                    case .cancelled:
                        if gate.claim() { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                start(queue: .global(qos: .utility))
            }
        } onCancel: {
            cancel()
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func finishSending() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            )
        }
    }

    func receiveData(maximumLength: Int = 64 * 1_024) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: max(maximumLength, 1)) {
                data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(returning: Data()) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
}

private final class NWContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
