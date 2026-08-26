import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class JobQueueTests: XCTestCase {
    func testJobStatusPropertiesAndTerminalStates() {
        XCTAssertFalse(SuperThumbnailJobStatus.queued.isTerminal)
        XCTAssertFalse(SuperThumbnailJobStatus.running.isTerminal)
        XCTAssertFalse(SuperThumbnailJobStatus.paused.isTerminal)
        XCTAssertTrue(SuperThumbnailJobStatus.completed.isTerminal)
        XCTAssertTrue(SuperThumbnailJobStatus.failed("error").isTerminal)
        XCTAssertTrue(SuperThumbnailJobStatus.cancelled.isTerminal)

        XCTAssertEqual(SuperThumbnailJobStatus.queued.displayName, "대기 중")
        XCTAssertEqual(SuperThumbnailJobStatus.running.displayName, "진행 중")
        XCTAssertEqual(SuperThumbnailJobStatus.paused.displayName, "일시정지")
        XCTAssertEqual(SuperThumbnailJobStatus.completed.displayName, "완료")
        XCTAssertEqual(SuperThumbnailJobStatus.failed("err").displayName, "실패")
        XCTAssertEqual(SuperThumbnailJobStatus.cancelled.displayName, "중단됨")
    }

    func testJobProgressAndFolderName() {
        let url = URL(fileURLWithPath: "/Volumes/Media/Vacation Photos")
        var job = SuperThumbnailJob(
            folderURL: url,
            isFresh: false,
            status: .queued,
            totalCount: 10,
            completedCount: 5
        )

        XCTAssertEqual(job.folderName, "Vacation Photos")
        XCTAssertEqual(job.progress, 0.5, accuracy: 0.001)

        job.completedCount = 10
        XCTAssertEqual(job.progress, 1.0, accuracy: 0.001)

        let emptyJob = SuperThumbnailJob(folderURL: url, totalCount: 0, completedCount: 0)
        XCTAssertEqual(emptyJob.progress, 0.0)
    }

    @MainActor
    func testModelQueueManagement() throws {
        let dir1 = try makeTemporaryDirectory()
        let dir2 = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        let model = try withPinnedLastFolder(dir1) { SuperThumbnailMacModel() }
        model.jobs.removeAll()

        model.enqueueFolder(dir1)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs[0].folderURL.standardizedFileURL, dir1.standardizedFileURL)

        model.enqueueFolder(dir2)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs[1].folderURL.standardizedFileURL, dir2.standardizedFileURL)

        // Duplicate queued job for same URL should be ignored
        model.enqueueFolder(dir1)
        XCTAssertEqual(model.jobs.count, 2)

        let firstJobID = model.jobs[0].id
        model.removeJob(id: firstJobID)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs[0].folderURL.standardizedFileURL, dir2.standardizedFileURL)

        // Clear completed jobs
        model.jobs[0].status = .completed
        model.clearCompletedJobs()
        XCTAssertTrue(model.jobs.isEmpty)
    }

    @MainActor
    func testSequentialQueueExecutionProcessesMultipleJobs() async throws {
        let root1 = try makeTemporaryDirectory()
        let root2 = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root1)
            try? FileManager.default.removeItem(at: root2)
        }

        try makePNG().write(to: root1.appendingPathComponent("image1.png"))
        try makePNG().write(to: root2.appendingPathComponent("image2.png"))

        let model = try withPinnedLastFolder(root1) { SuperThumbnailMacModel() }
        model.jobs.removeAll()

        model.enqueueFolder(root1)
        model.enqueueFolder(root2)
        XCTAssertEqual(model.jobs.count, 2)

        model.start()
        XCTAssertTrue(model.isRunning)

        try await waitUntilFinished(model)

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs[0].status, .completed)
        XCTAssertEqual(model.jobs[1].status, .completed)
        XCTAssertEqual(model.jobs[0].generatedCount, 1)
        XCTAssertEqual(model.jobs[1].generatedCount, 1)

        let vault1 = root1.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        let vault2 = root2.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault2.path))
    }

    @MainActor
    func testTogglePauseStateTransitions() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try withPinnedLastFolder(dir) { SuperThumbnailMacModel() }
        model.jobs.removeAll()

        let jobID = UUID()
        let queuedJobID = UUID()
        let job1 = SuperThumbnailJob(id: jobID, folderURL: dir, status: .running, totalCount: 10, completedCount: 2)
        let job2 = SuperThumbnailJob(id: queuedJobID, folderURL: dir, status: .queued, totalCount: 5)
        model.jobs = [job1, job2]
        model.activeJobID = jobID

        // 1. When not running, togglePause has no effect
        model.isRunning = false
        model.togglePause()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.jobs[0].status, .running)
        XCTAssertEqual(model.jobs[1].status, .queued)

        // 2. When running, pausing transitions active job to .paused while queued job remains .queued
        model.isRunning = true
        model.togglePause()
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.jobs[0].status, .paused)
        XCTAssertEqual(model.jobs[1].status, .queued)

        // 3. Resuming transitions active job back to .running
        model.togglePause()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.jobs[0].status, .running)
        XCTAssertEqual(model.jobs[1].status, .queued)

        // 4. Terminal job status is preserved
        model.jobs[0].status = .completed
        model.togglePause()
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.jobs[0].status, .completed)
    }

    @MainActor
    func testQueueExecutionPauseAndResumeUpdatesJobStatus() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...12 {
            try makePNG().write(to: root.appendingPathComponent("image\(i).png"))
        }

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.jobs.removeAll()
        model.enqueueFolder(root)
        XCTAssertEqual(model.jobs.count, 1)

        model.start()
        XCTAssertTrue(model.isRunning)

        let deadline = Date().addingTimeInterval(10)
        while model.completedCount < 1 && model.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        guard model.isRunning && model.completedCount < 12 else {
            try await waitUntilFinished(model)
            return
        }

        // Pause active in-flight execution
        model.togglePause()
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.jobs.first?.status, .paused)

        let completedWhilePaused = model.completedCount
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.jobs.first?.status, .paused)
        XCTAssertEqual(model.completedCount, completedWhilePaused)

        // Resume active execution
        model.togglePause()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.jobs.first?.status, .running)

        try await waitUntilFinished(model)

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.jobs.first?.status, .completed)
        XCTAssertEqual(model.jobs.first?.completedCount, 12)
    }

    // MARK: - Helpers

    @MainActor
    private func withPinnedLastFolder<T>(_ root: URL, _ body: () -> T) throws -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "lastSelectedFolder")
        defaults.set(root.path, forKey: "lastSelectedFolder")
        defer {
            if let previous {
                defaults.set(previous, forKey: "lastSelectedFolder")
            } else {
                defaults.removeObject(forKey: "lastSelectedFolder")
            }
        }
        return body()
    }

    @MainActor
    private func waitUntilFinished(
        _ model: SuperThumbnailMacModel,
        timeout: TimeInterval = 30
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isRunning, "작업이 \(Int(timeout))초 안에 끝나지 않았습니다.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNG() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw VaultProcessorError.cannotEncode }
        context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { throw VaultProcessorError.cannotEncode }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw VaultProcessorError.cannotEncode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VaultProcessorError.cannotEncode }
        return data as Data
    }
}
