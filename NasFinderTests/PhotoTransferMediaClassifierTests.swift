import UniformTypeIdentifiers
import XCTest
@testable import NasFinder

final class PhotoTransferMediaClassifierTests: XCTestCase {
    func testLivePhotoWinsOverImageTypes() {
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(
                supportedContentTypes: [.livePhoto, .heic, .jpeg]
            ),
            .livePhoto
        )
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(
                supportedContentTypes: [.jpeg, .livePhoto]
            ),
            .livePhoto
        )
    }

    func testMovieTypesClassifyAsVideo() {
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(supportedContentTypes: [.quickTimeMovie]),
            .video
        )
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(supportedContentTypes: [.mpeg4Movie]),
            .video
        )
    }

    func testImageTypesClassifyAsPhoto() {
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(supportedContentTypes: [.heic]),
            .photo
        )
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(supportedContentTypes: [.png, .jpeg]),
            .photo
        )
    }

    func testPhotoKitLiveSubtypePromotesPickerImageOnly() {
        XCTAssertEqual(
            PhotoTransferMediaClassifier.refinedKind(.photo, assetIsLivePhoto: true),
            .livePhoto
        )
        XCTAssertEqual(
            PhotoTransferMediaClassifier.refinedKind(.photo, assetIsLivePhoto: false),
            .photo
        )
        XCTAssertEqual(
            PhotoTransferMediaClassifier.refinedKind(.video, assetIsLivePhoto: true),
            .video
        )
    }

    func testUnrelatedOrEmptyTypesClassifyAsUnknown() {
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(supportedContentTypes: []),
            .unknown
        )
        XCTAssertEqual(
            PhotoTransferMediaClassifier.classify(supportedContentTypes: [.pdf]),
            .unknown
        )
    }

    func testSelectionSummaryCountsByKind() {
        let summary = PhotoTransferSelectionSummary(
            kinds: [.livePhoto, .photo, .photo, .video, .unknown]
        )
        XCTAssertEqual(summary.totalCount, 5)
        XCTAssertEqual(summary.count(of: .livePhoto), 1)
        XCTAssertEqual(summary.count(of: .photo), 2)
        XCTAssertEqual(summary.count(of: .video), 1)
        XCTAssertEqual(summary.count(of: .unknown), 1)
    }

    func testSelectionAccessibilityKeepsMediaInformationSeparateFromDeleteAction() {
        XCTAssertEqual(
            PhotoTransferView.selectionAccessibilityLabel(
                index: 2,
                kindTitle: "동영상",
                duration: 65
            ),
            "항목 2, 동영상, 재생 시간 1:05"
        )
        XCTAssertEqual(
            PhotoTransferView.selectionAccessibilityLabel(
                index: 1,
                kindTitle: "Live Photo",
                duration: nil
            ),
            "항목 1, Live Photo"
        )
    }
}
