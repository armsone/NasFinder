import Foundation
import XCTest
@testable import NasFinder

private actor ImportRecorder {
    struct ImportedFile: Equatable {
        let filename: String
        let mimeType: String?
        let contents: Data
    }

    private(set) var importedFiles: [ImportedFile] = []

    func record(_ file: ImportedFile) {
        importedFiles.append(file)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func writeTempFile(_ contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try contents.write(to: url)
    return url
}

final class GooglePhotosImportCoordinatorTests: XCTestCase {
    private func makeMediaFile(
        baseURL: String? = "https://lh3.googleusercontent.com/p/x",
        mimeType: String?,
        filename: String? = "file.bin",
        processingStatus: GooglePhotosVideoProcessingStatus? = nil
    ) -> GooglePhotosMediaFile? {
        guard let baseURL else { return nil }
        let metadata: GooglePhotosMediaFileMetadata? = processingStatus.map {
            GooglePhotosMediaFileMetadata(
                width: nil,
                height: nil,
                videoMetadata: GooglePhotosVideoMetadata(fps: nil, processingStatus: $0)
            )
        }
        return GooglePhotosMediaFile(baseURL: baseURL, mimeType: mimeType, filename: filename, metadata: metadata)
    }

    private func makeItem(
        id: String,
        type: GooglePhotosMediaType,
        mediaFile: GooglePhotosMediaFile?
    ) -> GooglePhotosPickedMediaItem {
        GooglePhotosPickedMediaItem(id: id, createTime: nil, type: type, mediaFile: mediaFile)
    }

    private func outcome(_ summary: GooglePhotosImportSummary, for id: String) -> GooglePhotosImportOutcome? {
        summary.outcomes.first { $0.itemID == id }
    }

    // MARK: - Mixed success

    func testMixedPhotoAndVideoSucceed() async throws {
        let photo = makeItem(
            id: "photo-1",
            type: .photo,
            mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "a.jpg")
        )
        let video = makeItem(
            id: "video-1",
            type: .video,
            mediaFile: makeMediaFile(mimeType: "video/mp4", filename: "b.mp4", processingStatus: .ready)
        )

        let recorder = ImportRecorder()
        let coordinator = GooglePhotosImportCoordinator(
            download: { item in
                try writeTempFile(Data("bytes-\(item.id)".utf8))
            },
            importFile: { url, filename, mimeType in
                let contents = try Data(contentsOf: url)
                await recorder.record(.init(filename: filename, mimeType: mimeType, contents: contents))
            }
        )

        let summary = try await coordinator.importItems([photo, video])

        XCTAssertEqual(summary.totalSelected, 2)
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.skippedCount, 0)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(outcome(summary, for: "photo-1")?.status, .imported)
        XCTAssertEqual(outcome(summary, for: "video-1")?.status, .imported)

        let imported = await recorder.importedFiles
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(imported.contains(.init(filename: "a.jpg", mimeType: "image/jpeg", contents: Data("bytes-photo-1".utf8))))
        XCTAssertTrue(imported.contains(.init(filename: "b.mp4", mimeType: "video/mp4", contents: Data("bytes-video-1".utf8))))
    }

    // MARK: - Processing video skipped

    func testProcessingVideoIsSkippedWithoutDownload() async throws {
        let processingVideo = makeItem(
            id: "video-processing",
            type: .video,
            mediaFile: makeMediaFile(mimeType: "video/mp4", filename: "b.mp4", processingStatus: .processing)
        )

        let counter = CallCounter()
        let coordinator = GooglePhotosImportCoordinator(
            download: { _ in
                await counter.increment()
                return try writeTempFile(Data())
            },
            importFile: { _, _, _ in }
        )

        let summary = try await coordinator.importItems([processingVideo])

        let downloadCallCount = await counter.count
        XCTAssertEqual(downloadCallCount, 0)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(
            outcome(summary, for: "video-processing")?.status,
            .skipped(.videoNotReady(.processing))
        )
    }

    // MARK: - Malformed items skipped without download

    func testMalformedItemsAreSkippedWithoutDownload() async throws {
        let missingMediaFile = makeItem(id: "missing-media-file", type: .photo, mediaFile: nil)
        let missingBaseURL = makeItem(
            id: "missing-base-url",
            type: .photo,
            mediaFile: makeMediaFile(baseURL: "   ", mimeType: "image/jpeg")
        )
        let missingFilename = makeItem(
            id: "missing-filename",
            type: .photo,
            mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: nil)
        )
        let missingMimeType = makeItem(
            id: "missing-mime",
            type: .photo,
            mediaFile: makeMediaFile(mimeType: nil)
        )
        let mismatchedMime = makeItem(
            id: "mismatched-mime",
            type: .photo,
            mediaFile: makeMediaFile(mimeType: "video/mp4")
        )
        let unspecifiedType = makeItem(
            id: "unspecified-type",
            type: .unspecified,
            mediaFile: makeMediaFile(mimeType: "image/jpeg")
        )

        let counter = CallCounter()
        let coordinator = GooglePhotosImportCoordinator(
            download: { _ in
                await counter.increment()
                return try writeTempFile(Data())
            },
            importFile: { _, _, _ in }
        )

        let items = [missingMediaFile, missingBaseURL, missingFilename, missingMimeType, mismatchedMime, unspecifiedType]
        let summary = try await coordinator.importItems(items)

        let downloadCallCount = await counter.count
        XCTAssertEqual(downloadCallCount, 0)
        XCTAssertEqual(summary.skippedCount, items.count)
        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(outcome(summary, for: "missing-media-file")?.status, .skipped(.missingMediaFile))
        XCTAssertEqual(outcome(summary, for: "missing-base-url")?.status, .skipped(.missingMediaFile))
        XCTAssertEqual(outcome(summary, for: "missing-filename")?.status, .skipped(.missingMediaFile))
        XCTAssertEqual(outcome(summary, for: "missing-mime")?.status, .skipped(.missingMimeType))
        XCTAssertEqual(outcome(summary, for: "mismatched-mime")?.status, .skipped(.mimeTypeMismatch))
        XCTAssertEqual(outcome(summary, for: "unspecified-type")?.status, .skipped(.unsupportedMediaType))
    }

    // MARK: - Download failure followed by later success

    func testDownloadFailureDoesNotStopLaterItems() async throws {
        struct DownloadError: Error {}
        let failing = makeItem(id: "fails", type: .photo, mediaFile: makeMediaFile(mimeType: "image/jpeg"))
        let succeeding = makeItem(id: "succeeds", type: .photo, mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "ok.jpg"))

        let recorder = ImportRecorder()
        let coordinator = GooglePhotosImportCoordinator(
            download: { item in
                if item.id == "fails" { throw DownloadError() }
                return try writeTempFile(Data("ok-bytes".utf8))
            },
            importFile: { url, filename, mimeType in
                let contents = try Data(contentsOf: url)
                await recorder.record(.init(filename: filename, mimeType: mimeType, contents: contents))
            }
        )

        let summary = try await coordinator.importItems([failing, succeeding])

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(outcome(summary, for: "fails")?.status, .failed(.downloadFailed))
        XCTAssertEqual(outcome(summary, for: "succeeds")?.status, .imported)

        let imported = await recorder.importedFiles
        XCTAssertEqual(imported.map(\.filename), ["ok.jpg"])
    }

    // MARK: - Import failure followed by later success

    func testImportFailureDoesNotStopLaterItems() async throws {
        struct ImportError: Error {}
        let failing = makeItem(id: "import-fails", type: .photo, mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "fail.jpg"))
        let succeeding = makeItem(id: "import-succeeds", type: .photo, mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "ok.jpg"))

        let recorder = ImportRecorder()
        let coordinator = GooglePhotosImportCoordinator(
            download: { _ in try writeTempFile(Data("bytes".utf8)) },
            importFile: { url, filename, mimeType in
                if filename == "fail.jpg" { throw ImportError() }
                let contents = try Data(contentsOf: url)
                await recorder.record(.init(filename: filename, mimeType: mimeType, contents: contents))
            }
        )

        let summary = try await coordinator.importItems([failing, succeeding])

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(outcome(summary, for: "import-fails")?.status, .failed(.importFailed))
        XCTAssertEqual(outcome(summary, for: "import-succeeds")?.status, .imported)

        let imported = await recorder.importedFiles
        XCTAssertEqual(imported.map(\.filename), ["ok.jpg"])
    }

    // MARK: - Cancellation

    func testCancellationStopsFurtherProcessingButKeepsAlreadyImportedFiles() async throws {
        let first = makeItem(id: "first", type: .photo, mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "first.jpg"))
        let second = makeItem(id: "second", type: .photo, mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "second.jpg"))

        let recorder = ImportRecorder()
        let coordinator = GooglePhotosImportCoordinator(
            download: { _ in try writeTempFile(Data("bytes".utf8)) },
            importFile: { url, filename, mimeType in
                let contents = try Data(contentsOf: url)
                await recorder.record(.init(filename: filename, mimeType: mimeType, contents: contents))
            }
        )

        let task = Task {
            try await coordinator.importItems([first, second])
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소 시 CancellationError가 던져져야 합니다.")
        } catch is CancellationError {
            // expected
        }

        let imported = await recorder.importedFiles
        XCTAssertTrue(imported.isEmpty)
    }

    func testCancellationThrownDuringLastDownloadIsNotConvertedToFailure() async throws {
        let item = makeItem(
            id: "cancelled-download",
            type: .photo,
            mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "photo.jpg")
        )
        let coordinator = GooglePhotosImportCoordinator(
            download: { _ in throw CancellationError() },
            importFile: { _, _, _ in XCTFail("취소된 다운로드는 가져오기로 이어지면 안 됩니다.") }
        )

        do {
            _ = try await coordinator.importItems([item])
            XCTFail("다운로드 취소가 전파되어야 합니다.")
        } catch is CancellationError {
            // expected
        }
    }

    func testCancellationThrownDuringLastImportIsNotConvertedToFailure() async throws {
        let item = makeItem(
            id: "cancelled-import",
            type: .photo,
            mediaFile: makeMediaFile(mimeType: "image/jpeg", filename: "photo.jpg")
        )
        let coordinator = GooglePhotosImportCoordinator(
            download: { _ in try writeTempFile(Data("bytes".utf8)) },
            importFile: { _, _, _ in throw CancellationError() }
        )

        do {
            _ = try await coordinator.importItems([item])
            XCTFail("가져오기 취소가 전파되어야 합니다.")
        } catch is CancellationError {
            // expected
        }
    }
}
