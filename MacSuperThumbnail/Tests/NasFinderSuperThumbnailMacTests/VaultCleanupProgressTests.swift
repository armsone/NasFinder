import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class VaultCleanupProgressTests: XCTestCase {
    func testCleanupPhasePresentationValues() {
        XCTAssertFalse(VaultCleanupPhase.idle.isActive)
        XCTAssertEqual(VaultCleanupPhase.idle.activityText, "")
        XCTAssertEqual(VaultCleanupPhase.idle.accessibilityValueText, "")

        let discovering = VaultCleanupPhase.discovering
        XCTAssertTrue(discovering.isActive)
        XCTAssertFalse(discovering.isDeterminate)
        XCTAssertEqual(discovering.activityText, ".NasFinder-Vault 폴더를 찾는 중…")
        XCTAssertEqual(discovering.accessibilityValueText, "보관본 폴더를 찾는 중")

        let removing = VaultCleanupPhase.removing(completed: 3, total: 12)
        XCTAssertTrue(removing.isActive)
        XCTAssertTrue(removing.isDeterminate)
        XCTAssertEqual(removing.fractionCompleted, 0.25, accuracy: 0.0001)
        XCTAssertEqual(removing.countText, "3 / 12")
        XCTAssertEqual(removing.activityText, "보관본을 삭제하는 중 · 3 / 12")
        XCTAssertEqual(removing.accessibilityValueText, "전체 12개 중 3개 삭제됨")

        let empty = VaultCleanupPhase.removing(completed: 0, total: 0)
        XCTAssertEqual(empty.fractionCompleted, 0)
        XCTAssertEqual(empty.activityText, "삭제할 보관본이 없습니다.")
    }

    func testDiscoverVaultDirectoriesListsOnlyRealVaultsUnderRootWithoutDuplicates() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let rootVault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: rootVault, withIntermediateDirectories: true)
        let sub = root.appendingPathComponent("vacation", isDirectory: true)
        let subVault = sub.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: subVault, withIntermediateDirectories: true)

        // Symlink named like a vault pointing to an outside vault must be skipped.
        let outsideVault = outside.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideVault, withIntermediateDirectories: true)
        let linkParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
        let vaultLink = linkParent.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        try FileManager.default.createSymbolicLink(at: vaultLink, withDestinationURL: outsideVault)

        let discovered = try VaultProcessor.discoverVaultDirectories(in: root)
        let discoveredPaths = Set(discovered.map(\.path))
        XCTAssertEqual(discovered.count, 2)
        XCTAssertTrue(discoveredPaths.contains(rootVault.resolvingSymlinksInPath().standardizedFileURL.path))
        XCTAssertTrue(discoveredPaths.contains(subVault.resolvingSymlinksInPath().standardizedFileURL.path))
        XCTAssertFalse(discoveredPaths.contains(outsideVault.resolvingSymlinksInPath().standardizedFileURL.path))
    }

    func testDiscoverySkipsRootVaultThatIsASymlinkToOutside() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let outsideVault = outside.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideVault, withIntermediateDirectories: true)
        let rootVaultLink = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        try FileManager.default.createSymbolicLink(at: rootVaultLink, withDestinationURL: outsideVault)

        let discovered = try VaultProcessor.discoverVaultDirectories(in: root)
        XCTAssertTrue(discovered.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideVault.path))
    }

    func testDiscoveryAndRemovalRejectVaultSymlinkToInsideDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realParent = root.appendingPathComponent("real", isDirectory: true)
        let realVault = realParent.appendingPathComponent(
            NasFinderVaultCompatibility.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: realVault, withIntermediateDirectories: true)
        let rootVaultLink = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        try FileManager.default.createSymbolicLink(at: rootVaultLink, withDestinationURL: realVault)

        let discovered = try VaultProcessor.discoverVaultDirectories(in: root)
        XCTAssertFalse(discovered.contains { $0.standardizedFileURL == rootVaultLink.standardizedFileURL })
        XCTAssertThrowsError(try VaultProcessor.removeVaultDirectory(at: rootVaultLink, within: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootVaultLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realVault.path))
    }

    func testRemoveVaultDirectoryEnforcesNameAndContainment() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        // Outside vault: refused and preserved.
        let outsideVault = outside.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideVault, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VaultProcessor.removeVaultDirectory(at: outsideVault, within: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideVault.path))

        // Non-vault directory inside root: refused and preserved.
        let media = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VaultProcessor.removeVaultDirectory(at: media, within: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))

        // Real vault inside root: removed once, then reported missing.
        let vault = media.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        XCTAssertTrue(try VaultProcessor.removeVaultDirectory(at: vault, within: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.path))
        XCTAssertFalse(try VaultProcessor.removeVaultDirectory(at: vault, within: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }

    @MainActor
    func testFreshRunResetsCleanupPhaseAndRebuildsVault() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        try makePNG().write(to: photo)
        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let staleThumb = vault.appendingPathComponent("v1-stale.jpg")
        try makePNG().write(to: staleThumb)

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        model.startFresh()
        XCTAssertTrue(model.isRunning)
        try await waitUntilFinished(model)

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.cleanupPhase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleThumb.path))
        let rebuiltThumb = vault.appendingPathComponent(
            try NasFinderVaultCompatibility.thumbnailFilename(for: photo)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuiltThumb.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
    }

    @MainActor
    func testCancelDuringFreshRunResetsCleanupPhase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        model.startFresh()
        model.cancel()
        try await waitUntilFinished(model)

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.cleanupPhase, .idle)
    }

    // MARK: - Helpers

    /// Runs `body` while "lastSelectedFolder" points at the test root so the
    /// model's restore path never touches a real user folder; the developer's
    /// stored value is put back afterwards.
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
