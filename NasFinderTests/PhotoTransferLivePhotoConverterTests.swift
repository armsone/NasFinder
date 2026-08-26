import AVFoundation
import XCTest
import ImageIO
@testable import NasFinder

final class PhotoTransferLivePhotoConverterTests: XCTestCase {
    func testCopyLoopStopsForFailedOrCancelledReaderWriter() {
        XCTAssertTrue(
            PhotoTransferLivePhotoConverter.copyLoopHasTerminalFailure(
                readerStatus: .failed,
                writerStatus: .writing
            )
        )
        XCTAssertTrue(
            PhotoTransferLivePhotoConverter.copyLoopHasTerminalFailure(
                readerStatus: .reading,
                writerStatus: .cancelled
            )
        )
        XCTAssertFalse(
            PhotoTransferLivePhotoConverter.copyLoopHasTerminalFailure(
                readerStatus: .reading,
                writerStatus: .writing
            )
        )
    }

    func testKnownStillImageTimeUsesMicrosecondsAndClampsToDuration() {
        XCTAssertEqual(
            PhotoTransferLivePhotoConverter.resolvedStillImageTime(
                durationSeconds: 3,
                requestedMicroseconds: 1_250_000
            ),
            1.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhotoTransferLivePhotoConverter.resolvedStillImageTime(
                durationSeconds: 3,
                requestedMicroseconds: 9_000_000
            ),
            3,
            accuracy: 0.000_001
        )
    }

    func testUnknownStillImageTimeUsesSafeMidpoint() {
        XCTAssertEqual(
            PhotoTransferLivePhotoConverter.resolvedStillImageTime(
                durationSeconds: 3,
                requestedMicroseconds: -1
            ),
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PhotoTransferLivePhotoConverter.resolvedStillImageTime(
                durationSeconds: 0,
                requestedMicroseconds: -1
            ),
            0,
            accuracy: 0.000_001
        )
    }


    func testImageMetadataUsesMatchingMakerAppleAssetIdentifier() {
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:08:20 11:22:33"]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Samsung"]
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.5665]
        let source: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyOrientation: 6,
        ]
        let properties = PhotoTransferLivePhotoConverter.imagePropertiesByAddingAssetIdentifier(
            source,
            assetIdentifier: "asset-123"
        )
        let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        XCTAssertEqual(makerApple?["17"] as? String, "asset-123")
        let writtenExif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let writtenTIFF = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let writtenGPS = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(writtenExif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:08:20 11:22:33")
        XCTAssertEqual(writtenTIFF?[kCGImagePropertyTIFFMake] as? String, "Samsung")
        XCTAssertEqual(writtenGPS?[kCGImagePropertyGPSLatitude] as? Double, 37.5665)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
    }
}
