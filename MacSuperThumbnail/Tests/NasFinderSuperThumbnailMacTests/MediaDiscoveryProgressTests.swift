import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class MediaDiscoveryProgressTests: XCTestCase {
    func testDiscoveryPhasePresentationValues() {
        XCTAssertEqual(MediaDiscoveryPhase.titleText, "사진과 영상을 찾는 중")

        XCTAssertFalse(MediaDiscoveryPhase.idle.isActive)
        XCTAssertEqual(MediaDiscoveryPhase.idle.activityText, "")
        XCTAssertEqual(MediaDiscoveryPhase.idle.accessibilityValueText, "")

        let files = MediaDiscoveryPhase.discoveringFiles
        XCTAssertTrue(files.isActive)
        XCTAssertEqual(files.activityText, "사진과 영상 파일을 찾는 중…")
        XCTAssertEqual(files.accessibilityLabelText, "사진과 영상을 찾는 중")
        XCTAssertEqual(files.accessibilityValueText, "사진과 영상 파일을 찾는 중")

        let folders = MediaDiscoveryPhase.discoveringFolders
        XCTAssertTrue(folders.isActive)
        XCTAssertEqual(folders.activityText, "하위 폴더를 찾는 중…")
        XCTAssertEqual(folders.accessibilityLabelText, "사진과 영상을 찾는 중")
        XCTAssertEqual(folders.accessibilityValueText, "하위 폴더를 찾는 중")

        XCTAssertNotEqual(files.activityText, folders.activityText)
        XCTAssertNotEqual(files.accessibilityValueText, folders.accessibilityValueText)
    }

    @MainActor
    func testResumeRunMovesFilesThenFoldersThenIdle() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        let recorder = PhaseRecorder(model)
        model.start()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertEqual(
            recorder.discoveryTransitions,
            [.idle, .discoveringFiles, .discoveringFolders, .idle, .idle]
        )
        XCTAssertFalse(recorder.sawCleanupAndDiscoveryTogether)
        XCTAssertTrue(model.status.hasPrefix("완료:"))
    }

    @MainActor
    func testFreshRunShowsCleanupBeforeDiscoveryAndNeverBoth() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))
        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        let recorder = PhaseRecorder(model)
        model.startFresh()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.cleanupPhase, .idle)
        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertFalse(recorder.sawCleanupAndDiscoveryTogether)
        let cleanupStart = try XCTUnwrap(recorder.events.firstIndex { $0 == .cleanup(.discovering) })
        let discoveryStart = try XCTUnwrap(recorder.events.firstIndex { $0 == .discovery(.discoveringFiles) })
        XCTAssertLessThan(cleanupStart, discoveryStart)
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFolders))
    }

    @MainActor
    func testNoMediaEarlyReturnResetsDiscoveryPhase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        let recorder = PhaseRecorder(model)
        model.start()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertFalse(model.hasPendingResume)
        XCTAssertEqual(model.status, "이 폴더에서 지원되는 사진이나 영상을 찾지 못했습니다.")
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFiles))
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFolders))
        XCTAssertEqual(recorder.discoveryTransitions.last, .idle)
    }

    @MainActor
    func testCancelDuringRunResetsDiscoveryPhase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        model.start()
        model.cancel()
        try await waitUntilFinished(model)

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertEqual(model.cleanupPhase, .idle)
    }

    @MainActor
    func testSubsequentRunStartsFromIdleDiscoveryAgain() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        model.start()
        try await waitUntilFinished(model)
        XCTAssertEqual(model.discoveryPhase, .idle)

        let recorder = PhaseRecorder(model)
        model.start()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertEqual(recorder.discoveryTransitions.first, .idle)
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFiles))
        XCTAssertEqual(recorder.discoveryTransitions.last, .idle)
    }

    // MARK: - Helpers

    enum PhaseEvent: Equatable {
        case cleanup(VaultCleanupPhase)
        case discovery(MediaDiscoveryPhase)
    }

    /// Records every published phase change on the main actor so tests can
    /// assert ordering without polling a fast-moving model.
    @MainActor
    final class PhaseRecorder {
        private(set) var events: [PhaseEvent] = []
        private(set) var sawCleanupAndDiscoveryTogether = false
        private var cancellables: Set<AnyCancellable> = []

        init(_ model: SuperThumbnailMacModel) {
            model.$discoveryPhase
                .dropFirst()
                .sink { [weak self, weak model] phase in
                    self?.events.append(.discovery(phase))
                    if phase.isActive, model?.cleanupPhase.isActive == true {
                        self?.sawCleanupAndDiscoveryTogether = true
                    }
                }
                .store(in: &cancellables)
            model.$cleanupPhase
                .dropFirst()
                .sink { [weak self, weak model] phase in
                    self?.events.append(.cleanup(phase))
                    if phase.isActive, model?.discoveryPhase.isActive == true {
                        self?.sawCleanupAndDiscoveryTogether = true
                    }
                }
                .store(in: &cancellables)
        }

        var discoveryTransitions: [MediaDiscoveryPhase] {
            events.compactMap {
                if case let .discovery(phase) = $0 { return phase }
                return nil
            }
        }
    }

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
