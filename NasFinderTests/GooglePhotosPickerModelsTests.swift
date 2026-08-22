import Foundation
import XCTest
@testable import NasFinder

final class GooglePhotosPickerModelsTests: XCTestCase {
    func testPickingSessionDecodesAllDocumentedFields() throws {
        let json = Data("""
        {
          "id": "session-123",
          "pickerUri": "https://photos.google.com/picker/abc",
          "pollingConfig": {
            "pollInterval": "5s",
            "timeoutIn": "3.5s"
          },
          "expireTime": "2026-08-21T12:34:56.789Z",
          "pickingConfig": {
            "maxItemCount": "50"
          },
          "mediaItemsSet": true
        }
        """.utf8)

        let session = try JSONDecoder().decode(GooglePhotosPickingSession.self, from: json)
        XCTAssertEqual(session.id, "session-123")
        XCTAssertEqual(session.pickerURI, "https://photos.google.com/picker/abc")
        XCTAssertEqual(session.pollingConfig?.pollInterval, 5)
        XCTAssertEqual(session.pollingConfig?.timeoutIn ?? 0, 3.5, accuracy: 0.0001)
        XCTAssertEqual(session.pickingConfig?.maxItemCount, 50)
        XCTAssertTrue(session.mediaItemsSet)

        let expected = try XCTUnwrap(GooglePhotosWireFormat.parseTimestamp("2026-08-21T12:34:56.789Z"))
        XCTAssertEqual(session.expireTime, expected)
    }

    func testPickingSessionDecodesNumericMaxItemCountAndMissingMediaItemsSet() throws {
        let json = Data("""
        {
          "id": "session-456",
          "pickingConfig": { "maxItemCount": 25 }
        }
        """.utf8)

        let session = try JSONDecoder().decode(GooglePhotosPickingSession.self, from: json)
        XCTAssertEqual(session.pickingConfig?.maxItemCount, 25)
        XCTAssertFalse(session.mediaItemsSet)
        XCTAssertNil(session.expireTime)
    }

    func testRFC3339TimestampParsingWithAndWithoutFractionalSeconds() throws {
        let plain = try XCTUnwrap(GooglePhotosWireFormat.parseTimestamp("2026-01-02T03:04:05Z"))
        XCTAssertEqual(plain.timeIntervalSince1970, 1_767_323_045, accuracy: 0.001)

        let fractional = try XCTUnwrap(GooglePhotosWireFormat.parseTimestamp("2026-01-02T03:04:05.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince1970, 1_767_323_045.25, accuracy: 0.001)

        XCTAssertNil(GooglePhotosWireFormat.parseTimestamp("not-a-date"))
    }

    func testDurationParsing() {
        XCTAssertEqual(GooglePhotosWireFormat.parseDuration("5s"), 5)
        XCTAssertEqual(GooglePhotosWireFormat.parseDuration("3.5s") ?? 0, 3.5, accuracy: 0.0001)
        XCTAssertEqual(GooglePhotosWireFormat.parseDuration("0s"), 0)
        XCTAssertNil(GooglePhotosWireFormat.parseDuration("5"))
        XCTAssertNil(GooglePhotosWireFormat.parseDuration("abc"))
    }

    func testPickedMediaItemDecodesPhotoAndVideo() throws {
        let json = Data("""
        {
          "mediaItems": [
            {
              "id": "photo-1",
              "createTime": "2025-12-31T23:59:59Z",
              "type": "PHOTO",
              "mediaFile": {
                "baseUrl": "https://lh3.googleusercontent.com/p/photo-1",
                "mimeType": "image/jpeg",
                "filename": "IMG_0001.JPG",
                "mediaFileMetadata": { "width": "4032", "height": "3024" }
              }
            },
            {
              "id": "video-1",
              "createTime": "2026-01-15T08:00:00.500Z",
              "type": "VIDEO",
              "mediaFile": {
                "baseUrl": "https://lh3.googleusercontent.com/p/video-1",
                "mimeType": "video/mp4",
                "filename": "MOV_0002.MP4",
                "mediaFileMetadata": {
                  "width": 1920,
                  "height": 1080,
                  "videoMetadata": { "fps": 29.97, "processingStatus": "READY" }
                }
              }
            },
            {
              "id": "unknown-1",
              "type": "SOMETHING_NEW"
            }
          ],
          "nextPageToken": "token-2"
        }
        """.utf8)

        let page = try JSONDecoder().decode(GooglePhotosMediaItemsPage.self, from: json)
        XCTAssertEqual(page.mediaItems.count, 3)
        XCTAssertEqual(page.nextPageToken, "token-2")

        let photo = page.mediaItems[0]
        XCTAssertEqual(photo.type, .photo)
        XCTAssertEqual(photo.mediaFile?.filename, "IMG_0001.JPG")
        XCTAssertEqual(photo.mediaFile?.metadata?.width, 4032)
        XCTAssertEqual(photo.mediaFile?.metadata?.height, 3024)

        let video = page.mediaItems[1]
        XCTAssertEqual(video.type, .video)
        XCTAssertEqual(video.mediaFile?.metadata?.videoMetadata?.processingStatus, .ready)
        XCTAssertEqual(video.mediaFile?.metadata?.videoMetadata?.fps ?? 0, 29.97, accuracy: 0.0001)

        XCTAssertEqual(page.mediaItems[2].type, .unspecified)
        XCTAssertNil(page.mediaItems[2].mediaFile)
    }

    func testVideoProcessingStatusMapping() {
        XCTAssertEqual(GooglePhotosVideoProcessingStatus(rawValue: "PROCESSING"), .processing)
        XCTAssertEqual(GooglePhotosVideoProcessingStatus(rawValue: "READY"), .ready)
        XCTAssertEqual(GooglePhotosVideoProcessingStatus(rawValue: "FAILED"), .failed)
        XCTAssertEqual(GooglePhotosVideoProcessingStatus(rawValue: "UNSPECIFIED"), .unspecified)
        XCTAssertEqual(GooglePhotosVideoProcessingStatus(rawValue: nil), .unspecified)
    }

    func testEmptyMediaItemsPageDecodesToEmptyArray() throws {
        let page = try JSONDecoder().decode(GooglePhotosMediaItemsPage.self, from: Data("{}".utf8))
        XCTAssertTrue(page.mediaItems.isEmpty)
        XCTAssertNil(page.nextPageToken)
    }

    func testContentURLAppendsPhotoAndVideoSuffixes() throws {
        let photoURL = try GooglePhotosContentURLBuilder.downloadURL(
            baseURL: "https://lh3.googleusercontent.com/p/abc",
            type: .photo
        )
        XCTAssertEqual(photoURL.absoluteString, "https://lh3.googleusercontent.com/p/abc=d")

        let videoURL = try GooglePhotosContentURLBuilder.downloadURL(
            baseURL: "https://lh3.googleusercontent.com/p/xyz",
            type: .video
        )
        XCTAssertEqual(videoURL.absoluteString, "https://lh3.googleusercontent.com/p/xyz=dv")
    }

    func testContentURLNormalizesExistingSuffixAndWhitespace() throws {
        let corrected = try GooglePhotosContentURLBuilder.downloadURL(
            baseURL: "https://lh3.googleusercontent.com/p/abc=d",
            type: .video
        )
        XCTAssertEqual(corrected.absoluteString, "https://lh3.googleusercontent.com/p/abc=dv")

        let idempotent = try GooglePhotosContentURLBuilder.downloadURL(
            baseURL: " https://lh3.googleusercontent.com/p/abc=dv \n",
            type: .video
        )
        XCTAssertEqual(idempotent.absoluteString, "https://lh3.googleusercontent.com/p/abc=dv")
    }

    func testContentURLRejectsEmptyAndNonHTTPSBase() {
        XCTAssertThrowsError(
            try GooglePhotosContentURLBuilder.downloadURL(baseURL: "  ", type: .photo)
        ) { error in
            XCTAssertEqual(error as? GooglePhotosPickerError, .invalidContentURL)
        }
        XCTAssertThrowsError(
            try GooglePhotosContentURLBuilder.downloadURL(baseURL: "http://insecure.example/p/abc", type: .photo)
        ) { error in
            XCTAssertEqual(error as? GooglePhotosPickerError, .invalidContentURL)
        }
    }

    func testContentURLForItemWithoutMediaFileThrows() {
        let item = GooglePhotosPickedMediaItem(id: "x", createTime: nil, type: .photo, mediaFile: nil)
        XCTAssertThrowsError(try GooglePhotosContentURLBuilder.downloadURL(for: item)) { error in
            XCTAssertEqual(error as? GooglePhotosPickerError, .invalidContentURL)
        }
    }
}
