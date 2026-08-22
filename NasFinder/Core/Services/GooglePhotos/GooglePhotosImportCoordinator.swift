import Foundation

/// 항목이 다운로드 대상에서 안전하게 제외된 이유. 민감 정보(토큰·세션 ID·URL·파일명 원문)는 포함하지 않는다.
enum GooglePhotosImportSkipReason: Equatable, Sendable {
    case missingMediaFile
    case missingMimeType
    case mimeTypeMismatch
    case unsupportedMediaType
    case videoNotReady(GooglePhotosVideoProcessingStatus)
}

enum GooglePhotosImportFailureReason: Equatable, Sendable {
    case downloadFailed
    case importFailed
}

enum GooglePhotosImportStatus: Equatable, Sendable {
    case imported
    case skipped(GooglePhotosImportSkipReason)
    case failed(GooglePhotosImportFailureReason)
}

struct GooglePhotosImportOutcome: Equatable, Sendable {
    let itemID: String
    let status: GooglePhotosImportStatus
}

struct GooglePhotosImportSummary: Equatable, Sendable {
    let totalSelected: Int
    let importedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let outcomes: [GooglePhotosImportOutcome]
}

/// 이미 나열된 Picker 미디어 항목을 검증 → 다운로드 → 가져오기 순서로 순차 처리한다.
/// 한 항목의 실패가 이후 항목 처리를 막지 않도록 부분 성공을 보존한다.
struct GooglePhotosImportCoordinator: Sendable {
    let download: @Sendable (GooglePhotosPickedMediaItem) async throws -> URL
    let importFile: @Sendable (URL, String, String?) async throws -> Void

    func importItems(_ items: [GooglePhotosPickedMediaItem]) async throws -> GooglePhotosImportSummary {
        var outcomes: [GooglePhotosImportOutcome] = []
        outcomes.reserveCapacity(items.count)

        for item in items {
            try Task.checkCancellation()

            switch Self.validate(item) {
            case let .skip(reason):
                outcomes.append(GooglePhotosImportOutcome(itemID: item.id, status: .skipped(reason)))

            case let .valid(filename, mimeType):
                let downloadedURL: URL
                do {
                    downloadedURL = try await download(item)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcomes.append(GooglePhotosImportOutcome(itemID: item.id, status: .failed(.downloadFailed)))
                    continue
                }

                try Task.checkCancellation()

                do {
                    try await importFile(downloadedURL, filename, mimeType)
                    outcomes.append(GooglePhotosImportOutcome(itemID: item.id, status: .imported))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcomes.append(GooglePhotosImportOutcome(itemID: item.id, status: .failed(.importFailed)))
                }
            }
        }

        let importedCount = outcomes.filter { if case .imported = $0.status { return true }; return false }.count
        let skippedCount = outcomes.filter { if case .skipped = $0.status { return true }; return false }.count
        let failedCount = outcomes.filter { if case .failed = $0.status { return true }; return false }.count

        return GooglePhotosImportSummary(
            totalSelected: items.count,
            importedCount: importedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            outcomes: outcomes
        )
    }

    private enum ValidationResult {
        case valid(filename: String, mimeType: String)
        case skip(GooglePhotosImportSkipReason)
    }

    private static func validate(_ item: GooglePhotosPickedMediaItem) -> ValidationResult {
        guard let mediaFile = item.mediaFile else { return .skip(.missingMediaFile) }
        let baseURL = mediaFile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return .skip(.missingMediaFile) }
        guard let filename = mediaFile.filename, !filename.isEmpty else { return .skip(.missingMediaFile) }
        guard let mimeType = mediaFile.mimeType, !mimeType.isEmpty else { return .skip(.missingMimeType) }

        switch item.type {
        case .photo:
            guard mimeType.lowercased().hasPrefix("image/") else { return .skip(.mimeTypeMismatch) }
            return .valid(filename: filename, mimeType: mimeType)

        case .video:
            guard mimeType.lowercased().hasPrefix("video/") else { return .skip(.mimeTypeMismatch) }
            let status = mediaFile.metadata?.videoMetadata?.processingStatus ?? .unspecified
            guard status == .ready else { return .skip(.videoNotReady(status)) }
            return .valid(filename: filename, mimeType: mimeType)

        case .unspecified:
            return .skip(.unsupportedMediaType)
        }
    }
}
