import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class PreviewOrderingTests: XCTestCase {
    func testNewestFirstOrdersByDateThenIDAndDropsDuplicates() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_005_000)
        let candidates = [
            candidate("/vault/b.jpg", date: older),
            candidate("/vault/z.jpg", date: newer),
            candidate("/vault/a.jpg", date: older),
            candidate("/vault/y.jpg", date: newer),
            candidate("/vault/a.jpg", date: newer),
        ]

        let ordered = SuperThumbnailPreviewOrdering.newestFirst(candidates)
        XCTAssertEqual(ordered.map(\.id), ["/vault/a.jpg", "/vault/y.jpg", "/vault/z.jpg", "/vault/b.jpg"])

        let limited = SuperThumbnailPreviewOrdering.newestFirst(candidates, limit: 2)
        XCTAssertEqual(limited.map(\.id), ["/vault/a.jpg", "/vault/y.jpg"])

        let shuffled = SuperThumbnailPreviewOrdering.newestFirst(candidates.reversed())
        XCTAssertEqual(shuffled, ordered)
    }

    func testPrependingPlacesNewItemAtFarLeftAndTrimsOldest() {
        let existing = ["/vault/2.jpg", "/vault/1.jpg"].map(item)
        let inserted = SuperThumbnailPreviewOrdering.prepending(
            item("/vault/3.jpg"),
            to: existing,
            limit: 2,
            promotesExisting: true
        )
        XCTAssertEqual(inserted.map(\.id), ["/vault/3.jpg", "/vault/2.jpg"])
    }

    func testPrependingPromotesRegeneratedButKeepsReverifiedInPlace() {
        let existing = ["/vault/3.jpg", "/vault/2.jpg", "/vault/1.jpg"].map(item)

        let promoted = SuperThumbnailPreviewOrdering.prepending(
            item("/vault/1.jpg"),
            to: existing,
            promotesExisting: true
        )
        XCTAssertEqual(promoted.map(\.id), ["/vault/1.jpg", "/vault/3.jpg", "/vault/2.jpg"])

        let untouched = SuperThumbnailPreviewOrdering.prepending(
            item("/vault/1.jpg"),
            to: existing,
            promotesExisting: false
        )
        XCTAssertEqual(untouched, existing)

        let unchangedMissingCache = SuperThumbnailPreviewOrdering.prepending(
            item("/vault/4.jpg"),
            to: existing,
            promotesExisting: false
        )
        XCTAssertEqual(unchangedMissingCache, existing)
    }

    func testDiscoverExistingPreviewsIsDeterministicForEqualModificationDates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        for name in ["v1-c.jpg", "v1-a.jpg", "v1-b.jpg"] {
            let file = vault.appendingPathComponent(name)
            try makePNG().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: sameDate], ofItemAtPath: file.path)
        }

        let first = VaultProcessor.discoverExistingPreviews(in: root)
        let second = VaultProcessor.discoverExistingPreviews(in: root)
        XCTAssertEqual(first.map(\.name), ["v1-a.jpg", "v1-b.jpg", "v1-c.jpg"])
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testResumeRunDoesNotDuplicateOrReorderExistingPreviews() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        try makePNG().write(to: photo)

        let model = try withPinnedLastFolder(root) { SuperThumbnailMacModel() }
        model.selectedFolder = root
        model.start()
        try await waitUntilFinished(model)

        let thumbnailURL = root
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
            .appendingPathComponent(try NasFinderVaultCompatibility.thumbnailFilename(for: photo))
        let thumbnailPath = SuperThumbnailPreviewOrdering.canonicalID(for: thumbnailURL)
        XCTAssertEqual(model.previewItems.map(\.id), [thumbnailPath])
        XCTAssertEqual(model.previewItems.first?.name, "photo.png")

        model.start()
        try await waitUntilFinished(model)
        XCTAssertEqual(model.cachedCount, 1)
        XCTAssertEqual(model.previewItems.map(\.id), [thumbnailPath])
    }

    // MARK: - Helpers

    private func item(_ id: String) -> SuperThumbnailMacPreviewItem {
        SuperThumbnailMacPreviewItem(
            id: id,
            name: (id as NSString).lastPathComponent,
            isFolder: false,
            vaultFileURL: URL(fileURLWithPath: id)
        )
    }

    private func candidate(_ id: String, date: Date) -> SuperThumbnailPreviewOrdering.Candidate {
        SuperThumbnailPreviewOrdering.Candidate(item: item(id), date: date)
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
