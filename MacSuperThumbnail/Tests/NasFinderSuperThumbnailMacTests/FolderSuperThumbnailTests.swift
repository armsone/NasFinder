import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class FolderSuperThumbnailTests: XCTestCase {
    func testFolderFilenameIsDeterministicNFCNormalizedAndDistinctFromFileRecords() {
        let name = "가족 여행"
        let filename = NasFinderVaultCompatibility.folderThumbnailFilename(folderName: name)
        XCTAssertEqual(
            filename,
            NasFinderVaultCompatibility.folderThumbnailFilename(folderName: name)
        )
        XCTAssertEqual(
            filename,
            NasFinderVaultCompatibility.folderThumbnailFilename(
                folderName: name.decomposedStringWithCanonicalMapping
            )
        )
        XCTAssertTrue(filename.hasPrefix("v1-folder-"))
        XCTAssertTrue(filename.hasSuffix(".jpg"))

        // Independent re-derivation of the portable identity formula.
        let identity = "engine=1|kind=folder|name=\(name.precomposedStringWithCanonicalMapping)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(filename, "v1-folder-\(digest).jpg")
        XCTAssertEqual(
            NasFinderVaultCompatibility.folderEmptyMarkerFilename(folderName: name),
            "v1-folder-\(digest).empty"
        )

        // A file record for the same byte content can never collide because
        // file records use the plain `v1-<digest>.jpg` shape.
        let fileRecord = NasFinderVaultCompatibility.thumbnailFilename(
            name: name,
            size: nil,
            modifiedAt: nil
        )
        XCTAssertFalse(fileRecord.hasPrefix("v1-folder-"))
        XCTAssertNotEqual(fileRecord, filename)
    }

    func testContactSheetPlanIsDeterministicFoldersFirstAndCappedAtNine() {
        let children = [
            FolderSheetChild(name: "zeta.mp4", isDirectory: false),
            FolderSheetChild(name: ".hidden", isDirectory: false),
            FolderSheetChild(name: "10 여행", isDirectory: true),
            FolderSheetChild(name: "2 여행", isDirectory: true),
            FolderSheetChild(name: "alpha.jpg", isDirectory: false),
        ]
        let plan = FolderContactSheetPlanner.plan(children: children)
        XCTAssertEqual(plan, [
            FolderSheetChild(name: "2 여행", isDirectory: true),
            FolderSheetChild(name: "10 여행", isDirectory: true),
            FolderSheetChild(name: "alpha.jpg", isDirectory: false),
            FolderSheetChild(name: "zeta.mp4", isDirectory: false),
        ])

        let many = (1...12).map {
            FolderSheetChild(name: "file-\($0).jpg", isDirectory: false)
        }
        XCTAssertEqual(FolderContactSheetPlanner.plan(children: many).count, 9)
        XCTAssertEqual(
            FolderContactSheetPlanner.plan(children: many),
            FolderContactSheetPlanner.plan(children: many.shuffled())
        )
    }

    func testDiscoverFoldersStaysInsideRootAndOrdersDeepestFirst() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        let vault = root.appendingPathComponent(
            NasFinderVaultCompatibility.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let folders = try VaultProcessor.discoverFolders(in: root)
        XCTAssertEqual(folders.map(\.url.lastPathComponent), ["inner", "outer"])
        XCTAssertFalse(folders.contains { $0.url.standardizedFileURL == root.standardizedFileURL })
        XCTAssertFalse(folders.contains {
            $0.url.lastPathComponent == NasFinderVaultCompatibility.directoryName
        })
    }

    func testEmptyFolderWritesIndexedMarkerAndNoSheet() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("빈 폴더", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let result = try VaultProcessor.processFolder(
            FolderEntry(url: empty, depth: 1),
            workerID: "test-worker"
        )
        XCTAssertEqual(result.state, .emptyIndexed)
        XCTAssertEqual(result.thumbnailBytes, 0)

        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        let marker = vault.appendingPathComponent(
            NasFinderVaultCompatibility.folderEmptyMarkerFilename(folderName: "빈 폴더")
        )
        let sheet = vault.appendingPathComponent(
            NasFinderVaultCompatibility.folderThumbnailFilename(folderName: "빈 폴더")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sheet.path))
    }

    func testUnreadableFolderThrowsAndLeavesNoRecord() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("사라진 폴더", isDirectory: true)

        XCTAssertThrowsError(
            try VaultProcessor.processFolder(
                FolderEntry(url: missing, depth: 1),
                workerID: "test-worker"
            )
        )
        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName)
        let marker = vault.appendingPathComponent(
            NasFinderVaultCompatibility.folderEmptyMarkerFilename(folderName: "사라진 폴더")
        )
        let sheet = vault.appendingPathComponent(
            NasFinderVaultCompatibility.folderThumbnailFilename(folderName: "사라진 폴더")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sheet.path))
    }

    func testBottomUpProcessingReusesChildFolderSheet() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let imageURL = child.appendingPathComponent("photo.png")
        try makePNG(color: (0.15, 0.55, 0.95)).write(to: imageURL)
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        _ = try await VaultProcessor.process(
            MediaFile(url: imageURL, kind: .image, size: Int64(values.fileSize ?? 0)),
            workerID: "test-worker"
        )

        let folders = try VaultProcessor.discoverFolders(in: root)
        XCTAssertEqual(folders.map(\.url.lastPathComponent), ["child", "parent"])
        var results: [FolderProcessingResult] = []
        for folder in folders {
            results.append(
                try VaultProcessor.processFolder(folder, workerID: "test-worker")
            )
        }
        XCTAssertEqual(results.map(\.state), [.generated, .generated])
        // The parent sheet reused the child's already generated folder sheet.
        XCTAssertEqual(results[1].usedChildFolderSheetCount, 1)

        let parentSheet = root
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName)
            .appendingPathComponent(
                NasFinderVaultCompatibility.folderThumbnailFilename(folderName: "parent")
            )
        let data = try Data(contentsOf: parentSheet)
        XCTAssertEqual(data.prefix(2), Data([0xff, 0xd8]))
        let claims = try FileManager.default.contentsOfDirectory(
            atPath: root
                .appendingPathComponent(NasFinderVaultCompatibility.directoryName)
                .path
        )
        XCTAssertFalse(claims.contains { $0.hasPrefix(".claim-") })
    }

    func testSkinToneThresholdBoundaryMatchesDocumentedFraction() {
        // 12x12 sample grid: 61/144 = 0.4236 >= 0.42, 60/144 = 0.4167 < 0.42.
        XCTAssertTrue(SheetSkinTonePolicy.shouldBlur(skinToneCount: 61, sampleCount: 144))
        XCTAssertFalse(SheetSkinTonePolicy.shouldBlur(skinToneCount: 60, sampleCount: 144))
        XCTAssertTrue(SheetSkinTonePolicy.isSkinTone(red: 200, green: 120, blue: 90))
        XCTAssertFalse(SheetSkinTonePolicy.isSkinTone(red: 40, green: 140, blue: 240))
        // 1.5 pt at the 384 px / 192 pt reference is 3 px; the radius scales
        // with the sheet size so it is never re-derived per consumer.
        XCTAssertEqual(SheetSkinTonePolicy.blurRadiusPoints, 1.5)
        XCTAssertEqual(SheetSkinTonePolicy.blurRadiusPixels, 3.0)
        XCTAssertEqual(SheetSkinTonePolicy.blurRadiusPixels(forSheetPixelSize: 384), 3.0)
        XCTAssertEqual(SheetSkinTonePolicy.blurRadiusPixels(forSheetPixelSize: 192), 1.5)
    }

    /// A parent must compose from the child's unblurred tile, not from the
    /// blurred sheet stored in the vault, so the final 1.5 pt blur is applied
    /// exactly once per sheet. Sharpness is measured as the number of
    /// transitional luminance pixels between the dark and skin-tone tiles: a
    /// blurred edge spreads over several pixels, a sharp edge over about one.
    func testParentSheetUsesUnblurredChildTileSoBlurNeverCompounds() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // 5 skin-tone tiles (>= 42% of the sheet) and 4 near-black tiles give
        // the child sheet a blur and strong edges between neighbouring tiles.
        var sources: [(String, (Double, Double, Double))] = []
        for index in 1...4 { sources.append(("dark-\(index).png", (0.02, 0.02, 0.02))) }
        for index in 1...5 { sources.append(("skin-\(index).png", (0.78, 0.47, 0.35))) }
        for (name, color) in sources {
            let imageURL = child.appendingPathComponent(name)
            try makePNG(color: color).write(to: imageURL)
            let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
            _ = try await VaultProcessor.process(
                MediaFile(url: imageURL, kind: .image, size: Int64(values.fileSize ?? 0)),
                workerID: "test-worker"
            )
        }

        let cache = FolderSheetTileCache()
        let childResult = try VaultProcessor.processFolder(
            FolderEntry(url: child, depth: 2),
            workerID: "test-worker",
            tileCache: cache
        )
        XCTAssertTrue(childResult.didBlur)
        XCTAssertEqual(cache.count, 1)

        let childSheetURL = parent
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName)
            .appendingPathComponent(
                NasFinderVaultCompatibility.folderThumbnailFilename(folderName: "child")
            )
        let blurredChildSheet = try XCTUnwrap(loadImage(at: childSheetURL))
        let blurredTransitional = transitionalPixelCount(
            in: blurredChildSheet,
            scaledTo: 128,
            region: CGRect(x: 0, y: 0, width: 128, height: 128)
        )
        XCTAssertGreaterThan(blurredTransitional, 0)

        // The cached tile was captured before the child's blur.
        let cachedTile = try XCTUnwrap(cache.tile(for: child))
        XCTAssertEqual(cachedTile.width, 128)
        let cachedTransitional = transitionalPixelCount(
            in: cachedTile,
            scaledTo: 128,
            region: CGRect(x: 0, y: 0, width: 128, height: 128)
        )
        XCTAssertLessThan(cachedTransitional, blurredTransitional)

        let parentSheetURL = root
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName)
            .appendingPathComponent(
                NasFinderVaultCompatibility.folderThumbnailFilename(folderName: "parent")
            )
        // Cached path first, then the rebuild path without a cache. Both must
        // produce a parent tile that is sharper than the blurred child sheet.
        for tileCache in [cache, nil] {
            let parentResult = try VaultProcessor.processFolder(
                FolderEntry(url: parent, depth: 1),
                workerID: "test-worker",
                tileCache: tileCache
            )
            XCTAssertEqual(parentResult.state, .generated)
            XCTAssertEqual(parentResult.usedChildFolderSheetCount, 1)
            // One skin-tone tile out of nine never reaches 42%.
            XCTAssertFalse(parentResult.didBlur)
            let parentSheet = try XCTUnwrap(loadImage(at: parentSheetURL))
            XCTAssertEqual(parentSheet.width, 384)
            // The child occupies the visual top-left cell, which is the
            // first 128 rows and columns of the bitmap.
            let parentTileTransitional = transitionalPixelCount(
                in: parentSheet,
                scaledTo: 384,
                region: CGRect(x: 0, y: 0, width: 128, height: 128)
            )
            XCTAssertLessThan(
                parentTileTransitional,
                blurredTransitional,
                tileCache == nil ? "rebuild path" : "cache path"
            )
        }
        // The parent evicted the child's tile and stored its own.
        XCTAssertNil(cache.tile(for: child))
        XCTAssertNotNil(cache.tile(for: parent))
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Counts grayscale pixels strictly between the near-black tile (~0.02)
    /// and the skin-tone tile (~0.55) luminance inside `region` of the image
    /// drawn into a `side` x `side` grayscale bitmap. Row 0 is the top row.
    private func transitionalPixelCount(
        in image: CGImage,
        scaledTo side: Int,
        region: CGRect
    ) -> Int {
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var count = 0
        for row in Int(region.minY)..<Int(region.maxY) {
            for column in Int(region.minX)..<Int(region.maxX) {
                let value = Double(pixels[row * side + column]) / 255
                if value > 0.12, value < 0.42 { count += 1 }
            }
        }
        return count
    }

    func testSkinToneDominantSheetIsBlurred() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("사람들", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...9 {
            let imageURL = folder.appendingPathComponent("skin-\(index).png")
            try makePNG(color: (0.78, 0.47, 0.35)).write(to: imageURL)
            let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
            _ = try await VaultProcessor.process(
                MediaFile(url: imageURL, kind: .image, size: Int64(values.fileSize ?? 0)),
                workerID: "test-worker"
            )
        }
        let result = try VaultProcessor.processFolder(
            FolderEntry(url: folder, depth: 1),
            workerID: "test-worker"
        )
        XCTAssertEqual(result.state, .generated)
        XCTAssertTrue(result.didBlur)

        let neutral = root.appendingPathComponent("풍경", isDirectory: true)
        try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
        let skyURL = neutral.appendingPathComponent("sky.png")
        try makePNG(color: (0.2, 0.5, 0.9)).write(to: skyURL)
        let skyValues = try skyURL.resourceValues(forKeys: [.fileSizeKey])
        _ = try await VaultProcessor.process(
            MediaFile(url: skyURL, kind: .image, size: Int64(skyValues.fileSize ?? 0)),
            workerID: "test-worker"
        )
        let neutralResult = try VaultProcessor.processFolder(
            FolderEntry(url: neutral, depth: 1),
            workerID: "test-worker"
        )
        XCTAssertFalse(neutralResult.didBlur)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePNG(
        color: (Double, Double, Double)
    ) throws -> Data {
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
        context.setFillColor(
            CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        )
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
        guard CGImageDestinationFinalize(destination) else {
            throw VaultProcessorError.cannotEncode
        }
        return data as Data
    }
}
