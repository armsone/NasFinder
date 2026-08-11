@preconcurrency import AVFoundation
import CoreVideo
import XCTest
@testable import NasFinder

@MainActor
final class RemotePreviewStateTests: XCTestCase {
    func testStreamingPlayerIsPresentedWithoutLocalFileURL() {
        let kind = RemotePreviewContentKind.resolve(
            isImage: false,
            isVideo: true,
            hasImage: false,
            hasPlayer: true,
            hasLocalURL: false,
            hasError: false
        )

        XCTAssertEqual(kind, .video)
    }

    func testVideoWithoutPlayerStillShowsLoading() {
        let kind = RemotePreviewContentKind.resolve(
            isImage: false,
            isVideo: true,
            hasImage: false,
            hasPlayer: false,
            hasLocalURL: false,
            hasError: false
        )

        XCTAssertEqual(kind, .loading)
    }

    func testPreviewErrorTakesPriorityOverPreparedContent() {
        let kind = RemotePreviewContentKind.resolve(
            isImage: false,
            isVideo: true,
            hasImage: false,
            hasPlayer: true,
            hasLocalURL: false,
            hasError: true
        )

        XCTAssertEqual(kind, .error)
    }

    func testEverySizedVideoUsesRangeStreamingWhenBackendSupportsIt() {
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: true,
                fileSize: 1
            ),
            .rangeStreaming
        )
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: true,
                fileSize: 2 * 1_024 * 1_024 * 1_024
            ),
            .rangeStreaming
        )
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: false,
                fileSize: 2 * 1_024 * 1_024 * 1_024
            ),
            .fullDownload
        )
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: true,
                fileSize: nil
            ),
            .fullDownload
        )
    }

    func testSmallMOVReportsProgressThenCreatesLocalPlayer() async throws {
        let movieURL = try await makeTinyMOV()
        defer { try? FileManager.default.removeItem(at: movieURL) }

        let byteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        XCTAssertGreaterThan(byteCount, 0)

        let gate = SuccessfulSmallVideoProgressGate()
        let service = SuccessfulSmallVideoService(
            movieURL: movieURL,
            gate: gate
        )
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/share/tiny.mov",
            name: "tiny.mov",
            kind: .file,
            size: byteCount,
            modifiedAt: nil,
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .seconds(2),
            downloadInactivityPollInterval: .milliseconds(20)
        )

        let loadTask = Task { await viewModel.loadCurrentItem(forceFullDownload: true) }
        do {
            try await gate.waitUntilMiddleProgress()
        } catch {
            await gate.releaseMiddleProgress()
            await loadTask.value
            throw error
        }

        let middleByteCount = max(byteCount / 2, 1)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(
            viewModel.downloadProgress?.completedByteCount,
            middleByteCount
        )
        if let fraction = viewModel.downloadProgress?.fractionCompleted {
            XCTAssertEqual(
                fraction,
                Double(middleByteCount) / Double(byteCount),
                accuracy: 0.000_001
            )
        } else {
            XCTFail("중간 다운로드 진행률이 확정값이어야 합니다.")
        }

        await gate.releaseMiddleProgress()
        await loadTask.value

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.localURL, movieURL)
        XCTAssertNotNil(viewModel.player)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.downloadProgress)
        let progressValues = await gate.progressValues
        XCTAssertEqual(progressValues, [0, middleByteCount, byteCount])

        viewModel.tearDown()
    }

    func testDownloadProgressClampsFractionToValidRange() {
        XCTAssertEqual(
            RemoteDownloadProgress(
                completedByteCount: 25,
                totalByteCount: 100
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            RemoteDownloadProgress(
                completedByteCount: 125,
                totalByteCount: 100
            ).fractionCompleted,
            1
        )
        XCTAssertNil(
            RemoteDownloadProgress(
                completedByteCount: 10,
                totalByteCount: nil
            ).fractionCompleted
        )
        XCTAssertEqual(
            RemoteDownloadProgress(
                completedByteCount: 0,
                totalByteCount: 0
            ).fractionCompleted,
            1
        )
    }

    func testDownloadIntegrityRejectsEarlyEOF() throws {
        XCTAssertNoThrow(
            try RemoteDownloadIntegrityError.validate(
                expectedByteCount: 1_024,
                actualByteCount: 1_024
            )
        )
        XCTAssertThrowsError(
            try RemoteDownloadIntegrityError.validate(
                expectedByteCount: 1_024,
                actualByteCount: 512
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteDownloadIntegrityError,
                .sizeMismatch(expected: 1_024, actual: 512)
            )
        }
    }

    func testSmallVideoStallBecomesRetryableErrorAndCancelsDownload() async throws {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let item = previewVideoItem(connectionID: service.connection.id)
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .milliseconds(40),
            downloadInactivityPollInterval: .milliseconds(5)
        )

        let loadTask = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForStarts(1)
        try await waitUntil { viewModel.errorMessage != nil }
        await loadTask.value

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.player)
        XCTAssertTrue(viewModel.errorMessage?.contains("다운로드가 진행되지 않았습니다") == true)
        let cancellationCount = await recorder.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTearDownAllowsSameVideoToLoadAgain() async throws {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let item = previewVideoItem(connectionID: service.connection.id)
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .seconds(2),
            downloadInactivityPollInterval: .milliseconds(10)
        )

        let firstLoad = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForStarts(1)
        viewModel.tearDown()
        await firstLoad.value
        XCTAssertFalse(viewModel.isLoading)

        let secondLoad = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForStarts(2)
        viewModel.tearDown()
        await secondLoad.value

        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 2)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testPeriodicByteProgressKeepsDownloadWatchdogAlive() async throws {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(
            recorder: recorder,
            behavior: .periodicProgress(
                count: 7,
                interval: .milliseconds(100)
            )
        )
        let item = previewVideoItem(connectionID: service.connection.id)
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .milliseconds(500),
            downloadInactivityPollInterval: .milliseconds(20)
        )

        let loadTask = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForProgressUpdates(7)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isLoading)

        viewModel.tearDown()
        await loadTask.value
    }

    func testMixedMediaNavigationWrapsAndPlaybackOptionsAreSelectable() {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let first = previewVideoItem(connectionID: service.connection.id)
        let second = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/share/photo.jpg",
            name: "photo.jpg",
            kind: .file,
            size: 512,
            modifiedAt: nil,
            contentTypeIdentifier: "public.jpeg"
        )
        let viewModel = RemotePreviewViewModel(
            items: [first, second],
            initialItemID: first.id,
            service: service
        )
        defer {
            viewModel.setPlaybackMode(.repeatAll)
            viewModel.setPhotoAdvanceInterval(.fiveSeconds)
        }

        viewModel.navigate(by: -1)
        XCTAssertEqual(viewModel.currentItem.id, second.id)
        viewModel.navigate(by: 1)
        XCTAssertEqual(viewModel.currentItem.id, first.id)

        viewModel.setPlaybackMode(.shuffle)
        viewModel.setPhotoAdvanceInterval(.tenSeconds)
        XCTAssertEqual(viewModel.playbackMode, .shuffle)
        XCTAssertEqual(viewModel.photoAdvanceInterval, .tenSeconds)
    }

    private func previewVideoItem(connectionID: UUID) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: "/share/clip.mov",
            name: "clip.mov",
            kind: .file,
            size: 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("미리보기 상태가 제한 시간 안에 변경되지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeTinyMOV() async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        do {
            let width = 32
            let height = 32
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ]
            )
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
            )

            guard writer.canAdd(input) else {
                throw TinyMOVTestError.cannotAddVideoInput
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw TinyMOVTestError.writerFailed(
                    writer.error?.localizedDescription ?? "startWriting 실패"
                )
            }
            writer.startSession(atSourceTime: .zero)
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw TinyMOVTestError.missingPixelBufferPool
            }

            for frameIndex in 0..<3 {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                while !input.isReadyForMoreMediaData, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard input.isReadyForMoreMediaData else {
                    throw TinyMOVTestError.writerInputTimedOut
                }

                var optionalPixelBuffer: CVPixelBuffer?
                let result = CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pixelBufferPool,
                    &optionalPixelBuffer
                )
                guard result == kCVReturnSuccess,
                      let pixelBuffer = optionalPixelBuffer else {
                    throw TinyMOVTestError.cannotCreatePixelBuffer(result)
                }

                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    memset(
                        baseAddress,
                        0x7F,
                        CVPixelBufferGetDataSize(pixelBuffer)
                    )
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                let presentationTime = CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                )
                guard adaptor.append(
                    pixelBuffer,
                    withPresentationTime: presentationTime
                ) else {
                    throw TinyMOVTestError.writerFailed(
                        writer.error?.localizedDescription ?? "프레임 추가 실패"
                    )
                }
            }

            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw TinyMOVTestError.writerFailed(
                    writer.error?.localizedDescription ?? "finishWriting 실패"
                )
            }
            return outputURL
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

private actor SuccessfulSmallVideoProgressGate {
    private(set) var progressValues: [Int64] = []
    private var didReachMiddleProgress = false
    private var mayFinish = false

    func record(_ byteCount: Int64) {
        progressValues.append(byteCount)
    }

    func pauseAtMiddleProgress() async throws {
        didReachMiddleProgress = true
        while !mayFinish {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilMiddleProgress() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !didReachMiddleProgress {
            guard clock.now < deadline else {
                throw SuccessfulSmallVideoTestError.didNotReachMiddleProgress
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseMiddleProgress() {
        mayFinish = true
    }
}

private struct SuccessfulSmallVideoService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Successful preview test",
        kind: .sftp,
        host: "preview.invalid",
        username: "tester"
    )
    let supportsRangeStreaming = true
    let movieURL: URL
    let gate: SuccessfulSmallVideoProgressGate

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        movieURL
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        let totalByteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        let middleByteCount = max(totalByteCount / 2, 1)

        for byteCount in [Int64(0), middleByteCount] {
            await progress(
                RemoteDownloadProgress(
                    completedByteCount: byteCount,
                    totalByteCount: totalByteCount
                )
            )
            await gate.record(byteCount)
        }
        try await gate.pauseAtMiddleProgress()
        await progress(
            RemoteDownloadProgress(
                completedByteCount: totalByteCount,
                totalByteCount: totalByteCount
            )
        )
        await gate.record(totalByteCount)
        return movieURL
    }

    func testConnection() async throws {}
}

private enum TinyMOVTestError: LocalizedError, Sendable {
    case cannotAddVideoInput
    case missingPixelBufferPool
    case cannotCreatePixelBuffer(CVReturn)
    case writerInputTimedOut
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            "AVAssetWriter에 영상 입력을 추가할 수 없습니다."
        case .missingPixelBufferPool:
            "AVAssetWriter pixel buffer pool을 만들지 못했습니다."
        case let .cannotCreatePixelBuffer(code):
            "테스트 영상 pixel buffer를 만들지 못했습니다. (\(code))"
        case .writerInputTimedOut:
            "AVAssetWriter 입력 준비 시간이 초과됐습니다."
        case let .writerFailed(message):
            "테스트 MOV 생성 실패: \(message)"
        }
    }
}

private enum SuccessfulSmallVideoTestError: Error {
    case didNotReachMiddleProgress
}

private actor StallingPreviewRecorder {
    private(set) var startCount = 0
    private(set) var cancellationCount = 0
    private(set) var progressUpdateCount = 0

    func recordStart() {
        startCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func recordProgressUpdate() {
        progressUpdateCount += 1
    }

    func waitForStarts(_ expectedCount: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while startCount < expectedCount {
            guard clock.now < deadline else {
                throw StallingPreviewTestError.didNotStart
            }
            await Task.yield()
        }
    }


    func waitForProgressUpdates(_ expectedCount: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while progressUpdateCount < expectedCount {
            guard clock.now < deadline else {
                throw StallingPreviewTestError.didNotProgress
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct StallingPreviewService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Preview test",
        kind: .sftp,
        host: "preview.invalid",
        username: "tester"
    )
    let supportsRangeStreaming = false
    let recorder: StallingPreviewRecorder
    var behavior: StallingPreviewBehavior = .noProgress

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await stalledDownload(item) { _ in }
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        try await stalledDownload(item, progress: progress)
    }

    func testConnection() async throws {}

    private func stalledDownload(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        await recorder.recordStart()
        await progress(
            RemoteDownloadProgress(
                completedByteCount: 0,
                totalByteCount: item.size
            )
        )
        do {
            if case let .periodicProgress(count, interval) = behavior {
                for updateIndex in 1...count {
                    try await Task.sleep(for: interval)
                    await progress(
                        RemoteDownloadProgress(
                            completedByteCount: Int64(updateIndex),
                            totalByteCount: item.size
                        )
                    )
                    await recorder.recordProgressUpdate()
                }
            }
            try await Task.sleep(for: .seconds(30))
            return FileManager.default.temporaryDirectory.appending(path: "never-returned.mov")
        } catch {
            await recorder.recordCancellation()
            throw error
        }
    }
}

private enum StallingPreviewBehavior: Sendable {
    case noProgress
    case periodicProgress(count: Int, interval: Duration)
}

private enum StallingPreviewTestError: Error {
    case didNotStart
    case didNotProgress
}
