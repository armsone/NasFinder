import Foundation
import XCTest
@testable import NasFinder

final class PhotoTransferWireCodecTests: XCTestCase {
    private func header(name: String = "photo-1.jpg", byteLength: UInt64 = 5) -> PhotoTransferWireHeader {
        PhotoTransferWireHeader(
            id: "D44DA8D7-EB1A-4E65-A1C8-425863ECE856",
            name: name,
            mimeType: "image/jpeg",
            mediaKind: PhotoTransferMediaKind.photo.rawValue,
            sourcePlatform: .ios,
            byteLength: byteLength
        )
    }

    func testFileAndCompletionFramesDecodeAcrossArbitraryChunks() throws {
        let firstPayload = Data([0, 1, 2, 3, 4])
        let secondPayload = Data("movie".utf8)
        var wire = try PhotoTransferWireCodec.fileFrame(header: header(), payload: firstPayload)
        wire.append(try PhotoTransferWireCodec.fileFrame(
            header: PhotoTransferWireHeader(
                id: "2",
                name: "video-2.mov",
                mimeType: "video/quicktime",
                mediaKind: PhotoTransferMediaKind.video.rawValue,
                sourcePlatform: .ios,
                byteLength: UInt64(secondPayload.count)
            ),
            payload: secondPayload
        ))
        wire.append(try PhotoTransferWireCodec.completionFrame())

        var decoder = PhotoTransferWireDecoder()
        var events: [PhotoTransferWireDecoder.Event] = []
        for byte in wire {
            events.append(contentsOf: try decoder.append(Data([byte])))
        }

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .file(header(), firstPayload))
        XCTAssertEqual(events[2], .completed)
    }

    func testHeaderUsesBigEndianLengthAndCarriesPlatform() throws {
        let value = header()
        let frame = try PhotoTransferWireCodec.headerFrame(value)
        let encodedLength = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(encodedLength), frame.count - 4)
        let decoded = try JSONDecoder().decode(
            PhotoTransferWireHeader.self,
            from: frame.dropFirst(4)
        )
        XCTAssertEqual(decoded.sourcePlatform, .ios)
        XCTAssertEqual(decoded.mediaKind, PhotoTransferMediaKind.photo.rawValue)
    }

    func testCompletionHeaderIsExactDoneObject() throws {
        let frame = try PhotoTransferWireCodec.completionFrame()
        XCTAssertEqual(String(decoding: frame.dropFirst(4), as: UTF8.self), "{\"done\":true}")
    }

    func testRejectsLengthMismatchAndOversizedHeaderPrefix() throws {
        XCTAssertThrowsError(
            try PhotoTransferWireCodec.fileFrame(header: header(byteLength: 6), payload: Data(repeating: 1, count: 5))
        ) { error in
            XCTAssertEqual(error as? PhotoTransferWireCodec.CodecError, .payloadLengthMismatch)
        }

        var decoder = PhotoTransferWireDecoder()
        let invalidLength = UInt32(PhotoTransferWireCodec.maximumHeaderLength + 1)
        let bytes: [UInt8] = [
            UInt8((invalidLength >> 24) & 0xFF),
            UInt8((invalidLength >> 16) & 0xFF),
            UInt8((invalidLength >> 8) & 0xFF),
            UInt8(invalidLength & 0xFF),
        ]
        XCTAssertThrowsError(try decoder.append(Data(bytes))) { error in
            XCTAssertEqual(error as? PhotoTransferWireCodec.CodecError, .invalidHeaderLength)
        }
    }

    func testGroupedLivePhotoHeaderRoundTripsWithIntegrityMetadata() throws {
        let digest = String(repeating: "a", count: 64)
        let value = PhotoTransferWireHeader(
            id: "component-1",
            name: "IMG_0001.HEIC",
            mimeType: "image/heic",
            mediaKind: PhotoTransferMediaKind.livePhoto.rawValue,
            sourcePlatform: .ios,
            byteLength: 123,
            itemId: "item-1",
            groupId: "group-1",
            itemKind: .livePhoto,
            componentRole: .primaryImage,
            componentIndex: 0,
            componentCount: 2,
            sha256: digest,
            stillImageTimeUs: -1
        )

        XCTAssertTrue(value.isFile)
        XCTAssertFalse(value.isLegacyFlatFile)
        let frame = try PhotoTransferWireCodec.headerFrame(value)
        let decoded = try JSONDecoder().decode(PhotoTransferWireHeader.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.itemId, "item-1")
        XCTAssertEqual(decoded.groupId, "group-1")
        XCTAssertEqual(decoded.componentRole, .primaryImage)
    }

    func testGroupedHeaderRejectsMissingOrMalformedChecksum() {
        let invalid = PhotoTransferWireHeader(
            id: "component-1",
            name: "IMG_0001.HEIC",
            mimeType: "image/heic",
            mediaKind: PhotoTransferMediaKind.livePhoto.rawValue,
            sourcePlatform: .ios,
            byteLength: 123,
            itemId: "item-1",
            groupId: "group-1",
            itemKind: .livePhoto,
            componentRole: .primaryImage,
            componentIndex: 0,
            componentCount: 2,
            sha256: "not-a-digest",
            stillImageTimeUs: -1
        )
        XCTAssertFalse(invalid.isFile)
        XCTAssertFalse(PhotoTransferWireHeader.isValidSHA256(String(repeating: "A", count: 64)))
        XCTAssertTrue(PhotoTransferWireHeader.isValidSHA256(String(repeating: "0", count: 64)))
    }

    func testMotionContainerIsOnlyValidAsSingleComponent() {
        let value = PhotoTransferWireHeader(
            id: "component-1",
            name: "motion.jpg",
            mimeType: "image/jpeg",
            mediaKind: "motionPhoto",
            sourcePlatform: .android,
            byteLength: 100,
            itemId: "item-1",
            groupId: "group-1",
            itemKind: .motionPhoto,
            componentRole: .motionContainer,
            componentIndex: 0,
            componentCount: 1,
            sha256: String(repeating: "1", count: 64),
            stillImageTimeUs: -1
        )
        XCTAssertTrue(value.isFile)
    }

    func testStreamingDecoderWritesPayloadToTemporaryFileAndVerifiesHash() throws {
        let payload = Data("hello".utf8)
        let value = PhotoTransferWireHeader(
            id: "component-1",
            name: "photo.jpg",
            mimeType: "image/jpeg",
            mediaKind: "photo",
            sourcePlatform: .ios,
            byteLength: UInt64(payload.count),
            itemId: "item-1",
            groupId: "item-1",
            itemKind: .photo,
            componentRole: .regularFile,
            componentIndex: 0,
            componentCount: 1,
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            stillImageTimeUs: -1
        )
        let frame = try PhotoTransferWireCodec.fileFrame(header: value, payload: payload)
        var decoder = PhotoTransferStreamingWireDecoder()
        var receivedURL: URL?
        for byte in frame {
            for event in try decoder.append(Data([byte])) {
                if case .file(let header, let url) = event {
                    XCTAssertEqual(header, value)
                    receivedURL = url
                }
            }
        }
        let url = try XCTUnwrap(receivedURL)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }
}
