import Foundation
import XCTest
@testable import NasFinder

@MainActor
final class FileOperationCoordinatorTests: XCTestCase {
    func testUploadBatchUsesKeepBothAndRefreshesOnce() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(recorder: recorder)
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("첫 번째.txt"), testURL("second.mov")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitUntilFinished(coordinator)

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["첫 번째.txt", "second.mov"])
        XCTAssertEqual(calls.map(\.directoryPath), ["/uploads", "/uploads"])
        XCTAssertTrue(calls.allSatisfy { $0.conflictPolicy == .keepBoth })
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(coordinator.statusMessage, "2개 항목 업로드 완료")
        XCTAssertNil(coordinator.errorMessage)
    }

    func testUploadSourceUsesPreferredNameInsteadOfStoredFilename() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(recorder: recorder)
        let coordinator = FileOperationCoordinator()
        let storedURL = testURL("4f84731c-944a-45fe-a86f.mov")

        coordinator.upload(
            [LocalUploadSource(url: storedURL, preferredName: "IMG_8927.mov")],
            into: "/movies",
            using: service
        ) {}

        try await waitUntilFinished(coordinator)

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["IMG_8927.mov"])
        XCTAssertEqual(calls.map(\.directoryPath), ["/movies"])
        XCTAssertEqual(coordinator.statusMessage, "1개 항목 업로드 완료")
    }

    func testUploadBatchContinuesAfterOneFileFails() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .fail(filenames: ["bad.txt"])
        )
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("bad.txt"), testURL("good.txt")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitUntilFinished(coordinator)

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["bad.txt", "good.txt"])
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(
            coordinator.errorMessage,
            "1개 성공, 1개 실패\nbad.txt: 테스트 업로드 실패"
        )
        XCTAssertNil(coordinator.statusMessage)
    }

    func testCancellingUploadStopsBeforeNextFileAndRefreshesOnce() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .waitForCancellation(filename: "slow.mov")
        )
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("slow.mov"), testURL("not-started.mov")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitForCallCount(1, recorder: recorder)
        try await waitForProgress(coordinator)
        XCTAssertEqual(coordinator.progress?.fractionCompleted, 0.25)
        XCTAssertEqual(coordinator.progress?.currentPath, "/uploads/slow.mov")
        coordinator.cancel()
        try await waitUntilFinished(coordinator)
        try await waitForRefreshCount(1) { refreshCount }

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["slow.mov"])
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(coordinator.statusMessage, "0개 완료 후 업로드를 취소했습니다.")
        XCTAssertNil(coordinator.operationTitle)
        XCTAssertNil(coordinator.progress)
    }

    func testCancelledResultPreservesSuccessAndStopsBeforeNextFile() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .returnCancelledResult(filename: "partial.mov")
        )
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("partial.mov"), testURL("not-started.mov")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitUntilFinished(coordinator)
        try await waitForRefreshCount(1) { refreshCount }

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["partial.mov"])
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(coordinator.statusMessage, "1개 완료 후 업로드를 취소했습니다.")
        XCTAssertNil(coordinator.errorMessage)
    }

    func testTypedCancellationPreservesPartialSuccessAndStopsBeforeNextFile() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .throwCancelledInterruption(filename: "partial.mov")
        )
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("partial.mov"), testURL("not-started.mov")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitUntilFinished(coordinator)
        try await waitForRefreshCount(1) { refreshCount }

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["partial.mov"])
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(coordinator.statusMessage, "1개 완료 후 업로드를 취소했습니다.")
        XCTAssertNil(coordinator.errorMessage)
    }

    func testTypedCancellationPreservesCleanupFailure() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .throwCancelledCleanupFailure(filename: "partial.mov")
        )
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("partial.mov"), testURL("not-started.mov")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitUntilFinished(coordinator)
        try await waitForRefreshCount(1) { refreshCount }

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["partial.mov"])
        XCTAssertEqual(
            coordinator.errorMessage,
            "0개 완료 후 업로드를 취소했습니다.\n"
                + "partial.mov: 취소한 업로드의 임시 파일을 정리하지 못했습니다."
        )
        XCTAssertNil(coordinator.statusMessage)
    }

    func testCancellationPreservesFailuresFromEarlierFiles() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .failThenWait(
                failedFilename: "bad.txt",
                waitingFilename: "slow.mov"
            )
        )
        let coordinator = FileOperationCoordinator()
        var refreshCount = 0

        coordinator.upload(
            [testURL("bad.txt"), testURL("slow.mov"), testURL("not-started.mov")],
            into: "/uploads",
            using: service
        ) {
            refreshCount += 1
        }

        try await waitForCallCount(2, recorder: recorder)
        try await waitForProgress(coordinator)
        coordinator.cancel()
        try await waitUntilFinished(coordinator)
        try await waitForRefreshCount(1) { refreshCount }

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.filename), ["bad.txt", "slow.mov"])
        XCTAssertEqual(
            coordinator.errorMessage,
            "0개 완료 후 업로드를 취소했습니다.\nbad.txt: 테스트 업로드 실패"
        )
        XCTAssertNil(coordinator.statusMessage)
    }

    func testCancellationRefreshBlocksASecondOperationUntilItFinishes() async throws {
        let recorder = UploadServiceRecorder()
        let service = RecordingUploadService(
            recorder: recorder,
            behavior: .waitForCancellation(filename: "slow.mov")
        )
        let refreshGate = RefreshGate()
        let coordinator = FileOperationCoordinator()

        coordinator.upload(
            [testURL("slow.mov")],
            into: "/uploads",
            using: service
        ) {
            await refreshGate.wait()
        }
        try await waitForCallCount(1, recorder: recorder)
        coordinator.cancel()
        try await waitUntilFinished(coordinator)

        XCTAssertFalse(coordinator.isWorking)
        XCTAssertTrue(coordinator.isRefreshing)
        XCTAssertTrue(coordinator.isBusy)

        coordinator.upload(
            [testURL("blocked.txt")],
            into: "/uploads",
            using: service
        ) {}
        try await Task.sleep(for: .milliseconds(30))
        let callsWhileRefreshing = await recorder.calls
        XCTAssertEqual(callsWhileRefreshing.count, 1)

        await refreshGate.release()
        try await waitUntilRefreshFinishes(coordinator)
        coordinator.upload(
            [testURL("after-refresh.txt")],
            into: "/uploads",
            using: service
        ) {}
        try await waitUntilFinished(coordinator)

        let finalCalls = await recorder.calls
        XCTAssertEqual(finalCalls.map(\.filename), ["slow.mov", "after-refresh.txt"])
    }

    func testReloadAfterCurrentLoadWaitsAndStartsANewRequest() async throws {
        let gate = ListRequestGate()
        let service = BlockingListService(gate: gate)
        let viewModel = FileBrowserViewModel(
            connection: service.connection,
            path: "/uploads",
            service: service
        )

        let initialLoad = Task { await viewModel.load() }
        try await waitForListRequestCount(1, gate: gate)

        let postMutationReload = Task {
            await viewModel.reloadAfterCurrentLoad()
        }
        try await Task.sleep(for: .milliseconds(30))
        let requestCountWhileInitialLoadIsBlocked = await gate.requestCount
        XCTAssertEqual(requestCountWhileInitialLoadIsBlocked, 1)

        await gate.releaseFirstRequest()
        try await waitForListRequestCount(2, gate: gate)
        await initialLoad.value
        await postMutationReload.value

        let finalRequestCount = await gate.requestCount
        XCTAssertEqual(finalRequestCount, 2)
        XCTAssertFalse(viewModel.isLoading)
    }

    private func testURL(_ filename: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private func waitUntilFinished(
        _ coordinator: FileOperationCoordinator,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while coordinator.isWorking {
            guard clock.now < deadline else {
                XCTFail("파일 작업이 제한 시간 안에 끝나지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForCallCount(
        _ expectedCount: Int,
        recorder: UploadServiceRecorder,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await recorder.calls.count < expectedCount {
            guard clock.now < deadline else {
                XCTFail("업로드 호출이 제한 시간 안에 시작되지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForProgress(
        _ coordinator: FileOperationCoordinator,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while coordinator.progress == nil {
            guard clock.now < deadline else {
                XCTFail("업로드 진행률이 제한 시간 안에 보고되지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForListRequestCount(
        _ expectedCount: Int,
        gate: ListRequestGate,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await gate.requestCount < expectedCount {
            guard clock.now < deadline else {
                XCTFail("목록 요청이 제한 시간 안에 시작되지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForRefreshCount(
        _ expectedCount: Int,
        currentCount: @escaping @MainActor () -> Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while currentCount() < expectedCount {
            guard clock.now < deadline else {
                XCTFail("새로 고침이 제한 시간 안에 실행되지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntilRefreshFinishes(
        _ coordinator: FileOperationCoordinator,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while coordinator.isRefreshing {
            guard clock.now < deadline else {
                XCTFail("새로 고침이 제한 시간 안에 끝나지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor UploadServiceRecorder {
    private(set) var calls: [UploadServiceCall] = []

    func record(_ call: UploadServiceCall) {
        calls.append(call)
    }
}

private actor RefreshGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private struct UploadServiceCall: Sendable {
    let filename: String
    let directoryPath: String
    let conflictPolicy: RemoteConflictPolicy
}

private enum RecordingUploadBehavior: Sendable {
    case succeed
    case fail(filenames: Set<String>)
    case waitForCancellation(filename: String)
    case returnCancelledResult(filename: String)
    case throwCancelledInterruption(filename: String)
    case throwCancelledCleanupFailure(filename: String)
    case failThenWait(failedFilename: String, waitingFilename: String)
}

private struct RecordingUploadService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Upload test",
        kind: .synology,
        host: "nas.example.com",
        username: "tester"
    )
    let capabilities: RemoteFileServiceCapabilities = [.upload]
    let recorder: UploadServiceRecorder
    let behavior: RecordingUploadBehavior

    init(
        recorder: UploadServiceRecorder,
        behavior: RecordingUploadBehavior = .succeed
    ) {
        self.recorder = recorder
        self.behavior = behavior
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        throw RemoteFileOperationError.unsupported(operation: .copy)
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let filename = preferredName ?? localURL.lastPathComponent
        await recorder.record(
            UploadServiceCall(
                filename: filename,
                directoryPath: directoryPath,
                conflictPolicy: conflictPolicy
            )
        )

        switch behavior {
        case .succeed:
            break
        case .fail(let filenames) where filenames.contains(filename):
            throw RecordingUploadError.failed
        case .waitForCancellation(let waitingFilename) where waitingFilename == filename:
            await context.report(
                operation: .upload,
                phase: .writing,
                unit: .bytes,
                completedUnitCount: 25,
                totalUnitCount: 100,
                currentPath: "\(directoryPath)/\(filename)"
            )
            try await Task.sleep(for: .seconds(30))
        case .returnCancelledResult(let cancelledFilename) where cancelledFilename == filename:
            return successfulResult(
                localURL: localURL,
                directoryPath: directoryPath,
                filename: filename,
                context: context,
                wasCancelled: true
            )
        case .throwCancelledInterruption(let cancelledFilename)
            where cancelledFilename == filename:
            let success = successfulResult(
                localURL: localURL,
                directoryPath: directoryPath,
                filename: filename,
                context: context
            )
            throw RemoteOperationInterruptedError(
                reason: .cancelled,
                partialResult: RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .upload,
                    outcomes: success.outcomes + [
                        .failed(
                            sourcePath: localURL.path,
                            destinationPath: "\(directoryPath)/\(filename)",
                            issue: RemoteOperationIssue(
                                code: .unknown,
                                message: "작업이 취소되었습니다."
                            )
                        )
                    ],
                    wasCancelled: true
                )
            )
        case .throwCancelledCleanupFailure(let cancelledFilename)
            where cancelledFilename == filename:
            throw RemoteOperationInterruptedError(
                reason: .cancelled,
                partialResult: RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .upload,
                    outcomes: [
                        .failed(
                            sourcePath: localURL.path,
                            destinationPath: "\(directoryPath)/\(filename)",
                            issue: RemoteOperationIssue(
                                code: .server,
                                message: "취소한 업로드의 임시 파일을 정리하지 못했습니다."
                            )
                        )
                    ],
                    wasCancelled: true,
                    rollbackState: .failed
                )
            )
        case .failThenWait(let failedFilename, _) where failedFilename == filename:
            throw RecordingUploadError.failed
        case .failThenWait(_, let waitingFilename) where waitingFilename == filename:
            await context.report(
                operation: .upload,
                phase: .writing,
                unit: .bytes,
                completedUnitCount: 25,
                totalUnitCount: 100,
                currentPath: "\(directoryPath)/\(filename)"
            )
            try await Task.sleep(for: .seconds(30))
        case .fail,
             .waitForCancellation,
             .returnCancelledResult,
             .throwCancelledInterruption,
             .throwCancelledCleanupFailure,
             .failThenWait:
            break
        }

        await context.report(
            operation: .upload,
            phase: .completed,
            unit: .bytes,
            completedUnitCount: 1,
            totalUnitCount: 1,
            currentPath: "\(directoryPath)/\(filename)"
        )
        return successfulResult(
            localURL: localURL,
            directoryPath: directoryPath,
            filename: filename,
            context: context
        )
    }

    private func successfulResult(
        localURL: URL,
        directoryPath: String,
        filename: String,
        context: RemoteOperationContext,
        wasCancelled: Bool = false
    ) -> RemoteOperationResult {
        RemoteOperationResult(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [
                .succeeded(
                    sourcePath: localURL.path,
                    destinationPath: "\(directoryPath)/\(filename)"
                )
            ],
            wasCancelled: wasCancelled
        )
    }
}

private actor ListRequestGate {
    private(set) var requestCount = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    func beginRequest() async {
        requestCount += 1
        guard requestCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}

private struct BlockingListService: RemoteFileService {
    let connection = RemoteConnection(
        name: "List test",
        kind: .synology,
        host: "nas.example.com",
        username: "tester"
    )
    let gate: ListRequestGate

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        await gate.beginRequest()
        return []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        throw RemoteFileOperationError.unsupported(operation: .copy)
    }
}

private enum RecordingUploadError: LocalizedError {
    case failed

    var errorDescription: String? {
        "테스트 업로드 실패"
    }
}
