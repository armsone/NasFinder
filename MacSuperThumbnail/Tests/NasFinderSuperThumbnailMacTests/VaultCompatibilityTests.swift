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
