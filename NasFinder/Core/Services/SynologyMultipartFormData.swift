import Foundation

/// A disk-backed RFC 1867 multipart body for File Station uploads.
///
/// Synology requires the binary file part to be the final form part and also
/// requires an exact Content-Length. Building into a protected temporary file
/// keeps large uploads out of memory while satisfying both requirements.
struct SynologyMultipartFormData: Sendable {
    let bodyURL: URL
    let boundary: String
    let contentLength: Int64

    static func build(
        fields: [(name: String, value: String)],
        fileURL: URL,
        fileName: String,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> Self {
        guard !fileName.contains("\r"), !fileName.contains("\n") else {
            throw NasFinderError.invalidConfiguration(
                "파일 이름에 줄바꿈 문자를 사용할 수 없습니다."
            )
        }

        let boundary = "NasFinder-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appending(path: "NasFinderUpload-\(UUID().uuidString).multipart")

        do {
            let worker = Task.detached(priority: .utility) {
                let values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true else {
                    throw NasFinderError.unsupported("현재는 개별 파일만 업로드할 수 있습니다.")
                }
                let totalFileBytes = Int64(values.fileSize ?? 0)

                guard FileManager.default.createFile(
                    atPath: bodyURL.path,
                    contents: nil
                ) else {
                    throw NasFinderError.server("업로드 임시 파일을 만들 수 없습니다.")
                }
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: bodyURL.path
                )

                let output = try FileHandle(forWritingTo: bodyURL)
                let input = try FileHandle(forReadingFrom: fileURL)
                defer {
                    try? input.close()
                    try? output.close()
                }

                func write(_ string: String) throws {
                    guard let data = string.data(using: .utf8) else {
                        throw NasFinderError.invalidResponse
                    }
                    try output.write(contentsOf: data)
                }

                for field in fields {
                    try context.checkCancellation()
                    try write("--\(boundary)\r\n")
                    try write(
                        "Content-Disposition: form-data; name=\"\(quoted(field.name))\"\r\n\r\n"
                    )
                    try write(field.value)
                    try write("\r\n")
                }

                try write("--\(boundary)\r\n")
                try write(
                    "Content-Disposition: form-data; name=\"file\"; filename=\"\(quoted(fileName))\"\r\n"
                )
                try write("Content-Type: application/octet-stream\r\n\r\n")

                var copiedBytes: Int64 = 0
                let chunkSize = 1_024 * 1_024
                while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                    try context.checkCancellation()
                    try output.write(contentsOf: chunk)
                    copiedBytes += Int64(chunk.count)
                    await context.report(
                        operation: operation,
                        phase: .reading,
                        unit: .bytes,
                        completedUnitCount: copiedBytes,
                        totalUnitCount: totalFileBytes,
                        currentPath: nil
                    )
                }

                try context.checkCancellation()
                try write("\r\n--\(boundary)--\r\n")
                try output.synchronize()
                let bodyValues = try bodyURL.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = bodyValues.fileSize else {
                    throw NasFinderError.invalidResponse
                }
                return Int64(fileSize)
            }
            let contentLength = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }

            return Self(
                bodyURL: bodyURL,
                boundary: boundary,
                contentLength: contentLength
            )
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    func removeTemporaryFile() {
        try? FileManager.default.removeItem(at: bodyURL)
    }

    private static func quoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
