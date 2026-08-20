import Photos
import XCTest
@testable import NasFinder

final class PhotoTransferReceiverSessionTests: XCTestCase {
    func testPairingQRCodeCanOnlyRegenerateWhileWaiting() throws {
        let payload = try XCTUnwrap(
            PhotoTransferPairingPayload(
                host: "192.168.0.20",
                port: 49_152,
                token: PhotoTransferPairingPayload.makeToken()
            )
        )

        XCTAssertTrue(
            PhotoTransferReceiverSession.canRegeneratePairingQRCode(
                in: .waitingForSender(payload)
            )
        )
        XCTAssertFalse(PhotoTransferReceiverSession.canRegeneratePairingQRCode(in: .idle))
        XCTAssertFalse(PhotoTransferReceiverSession.canRegeneratePairingQRCode(in: .starting))
        XCTAssertFalse(
            PhotoTransferReceiverSession.canRegeneratePairingQRCode(
                in: .senderConnected(payload, .android)
            )
        )
        XCTAssertFalse(
            PhotoTransferReceiverSession.canRegeneratePairingQRCode(in: .failed("오류"))
        )
    }

    func testActualSavedMediaKindsPreferPhotoLibraryType() {
        XCTAssertEqual(
            PhotoTransferReceiverSession.actualReceivedKind(
                mediaType: .video,
                mediaSubtypes: [],
                plannedKind: .photo
            ),
            .video
        )
        XCTAssertEqual(
            PhotoTransferReceiverSession.actualReceivedKind(
                mediaType: .image,
                mediaSubtypes: [],
                plannedKind: .livePhoto
            ),
            .photo
        )
    }

    func testActualLiveAssetKeepsMotionPhotoProvenance() {
        XCTAssertEqual(
            PhotoTransferReceiverSession.actualReceivedKind(
                mediaType: .image,
                mediaSubtypes: .photoLive,
                plannedKind: .motionPhoto
            ),
            .motionPhoto
        )
        XCTAssertEqual(
            PhotoTransferReceiverSession.actualReceivedKind(
                mediaType: .image,
                mediaSubtypes: .photoLive,
                plannedKind: .livePhoto
            ),
            .livePhoto
        )
    }
}
