import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class VaultCompatibilityTests: XCTestCase {
    func testFilenameMatchesIOSIdentityContract() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let filename = NasFinderVaultCompatibility.thumbnailFilename(
            name: "가족 사진.jpg",
            size: 12_345,
            modifiedAt: date
        )
        XCTAssertEqual(
            filename,
            "v1-b16415823178e9f2545f58906ca79dafe1c3bd34734e7527f5d94b163e9fc144.jpg"
        )
    }

    func testSupportedMediaClassificationIsCaseInsensitive() {
        XCTAssertEqual(SupportedMedia.kind(for: URL(fileURLWithPath: "/tmp/A.JPG")), .image)
        XCTAssertEqual(SupportedMedia.kind(for: URL(fileURLWithPath: "/tmp/B.HeIc")), .image)
        XCTAssertEqual(SupportedMedia.kind(for: URL(fileURLWithPath: "/tmp/C.MP4")), .video)
        XCTAssertEqual(SupportedMedia.kind(for: URL(fileURLWithPath: "/tmp/D.MkV")), .video)
        XCTAssertNil(SupportedMedia.kind(for: URL(fileURLWithPath: "/tmp/readme.txt")))
    }

    func testImageProcessingCreatesIOSCompatibleVaultJPEGAndCleansClaim() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("sample.png")
        try makePNG().write(to: imageURL)
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        let file = MediaFile(url: imageURL, kind: .image, size: Int64(values.fileSize ?? 0))
        let result = try await VaultProcessor.process(file, workerID: "test-worker")

        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        let thumbnail = vault.appendingPathComponent(
            try NasFinderVaultCompatibility.thumbnailFilename(for: imageURL)
        )
        XCTAssertTrue(result.generated)
        XCTAssertGreaterThan(result.thumbnailBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        let data = try Data(contentsOf: thumbnail)
        XCTAssertEqual(data.prefix(2), Data([0xff, 0xd8]))
        let entries = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".claim-") })
    }

    func testVaultRemovalDeletesOnlyVaultDirectoriesUnderRootAndPreservesMediaAndOtherHiddenFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        // Root media & vault
        let rootMedia = root.appendingPathComponent("photo.png")
        try makePNG().write(to: rootMedia)
        let rootVault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: rootVault, withIntermediateDirectories: true)
        try makePNG().write(to: rootVault.appendingPathComponent("v1-test.jpg"))

        // Subdirectory media & vault
        let sub = root.appendingPathComponent("vacation", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let subMedia = sub.appendingPathComponent("video.mp4")
        try makePNG().write(to: subMedia)
        let subVault = sub.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: subVault, withIntermediateDirectories: true)
        try makePNG().write(to: subVault.appendingPathComponent("v1-sub.jpg"))

        // Unrelated hidden folder inside root
        let otherHidden = root.appendingPathComponent(".git_or_config", isDirectory: true)
        try FileManager.default.createDirectory(at: otherHidden, withIntermediateDirectories: true)
        let secretFile = otherHidden.appendingPathComponent("config.txt")
        try Data("secret".utf8).write(to: secretFile)

        // Outside directory with vault
        let outsideVault = outside.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideVault, withIntermediateDirectories: true)
        let outsideThumb = outsideVault.appendingPathComponent("v1-outside.jpg")
        try makePNG().write(to: outsideThumb)

        // Execute vault removal strictly in root
        let removed = try VaultProcessor.removeVaultDirectories(in: root)
        XCTAssertEqual(removed, 2)

        // Vaults in root should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootVault.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: subVault.path))

        // Original media, unrelated hidden files, and root must be preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootMedia.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: subMedia.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherHidden.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path))

        // Outside vault must not be touched
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideVault.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideThumb.path))
    }

    func testRootContainmentHelperPreventsEscaping() {
        let root = URL(fileURLWithPath: "/Users/tester/Media")
        let directVault = URL(fileURLWithPath: "/Users/tester/Media/.NasFinder-Vault")
        let subVault = URL(fileURLWithPath: "/Users/tester/Media/Subfolder/.NasFinder-Vault")
        let parent = URL(fileURLWithPath: "/Users/tester")
        let sibling = URL(fileURLWithPath: "/Users/tester/Other/.NasFinder-Vault")

        XCTAssertTrue(VaultProcessor.isContained(target: directVault, within: root))
        XCTAssertTrue(VaultProcessor.isContained(target: subVault, within: root))
        XCTAssertFalse(VaultProcessor.isContained(target: root, within: root))
        XCTAssertFalse(VaultProcessor.isContained(target: parent, within: root))
        XCTAssertFalse(VaultProcessor.isContained(target: sibling, within: root))
    }

    func testDiscoverExistingPreviewsFindsFilesAndFolderSheetsSortedByDate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let olderFile = vault.appendingPathComponent("v1-older.jpg")
        let newerFolderSheet = vault.appendingPathComponent("v1-folder-newer.jpg")
        try makePNG().write(to: olderFile)
        try makePNG().write(to: newerFolderSheet)

        // Set modification dates explicitly
        let pastDate = Date(timeIntervalSince1970: 1_700_000_000)
        let recentDate = Date(timeIntervalSince1970: 1_700_005_000)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: olderFile.path)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: newerFolderSheet.path)

        let previews = VaultProcessor.discoverExistingPreviews(in: root, limit: 10)
        XCTAssertEqual(previews.count, 2)
        XCTAssertEqual(
            previews[0].vaultFileURL.resolvingSymlinksInPath().standardizedFileURL,
            newerFolderSheet.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertTrue(previews[0].isFolder)
        XCTAssertEqual(
            previews[1].vaultFileURL.resolvingSymlinksInPath().standardizedFileURL,
            olderFile.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertFalse(previews[1].isFolder)
    }

    func testFreshVsResumeProcessingSemantics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("photo.png")
        try makePNG().write(to: imageURL)
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        let file = MediaFile(url: imageURL, kind: .image, size: Int64(values.fileSize ?? 0))

        // Initial run -> Generated
        let initial = try await VaultProcessor.process(file, workerID: "test-worker")
        XCTAssertTrue(initial.generated)
        XCTAssertFalse(initial.alreadyCached)

        // Resume run -> Already cached
        let resume = try await VaultProcessor.process(file, workerID: "test-worker")
        XCTAssertFalse(resume.generated)
        XCTAssertTrue(resume.alreadyCached)

        // Fresh rebuild: remove vault -> Re-generated
        try VaultProcessor.removeVaultDirectories(in: root)
        let fresh = try await VaultProcessor.process(file, workerID: "test-worker")
        XCTAssertTrue(fresh.generated)
        XCTAssertFalse(fresh.alreadyCached)
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
