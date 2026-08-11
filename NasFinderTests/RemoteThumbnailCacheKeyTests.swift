import CoreGraphics
import XCTest
@testable import NasFinder

final class RemoteThumbnailCacheKeyTests: XCTestCase {
    func testRemoteDataKeyIsSharedAcrossRenderedSizes() {
        let item = makeItem(modifiedAt: Date(timeIntervalSince1970: 100))
        let remoteKey = RemoteThumbnailCacheKey.remoteData(for: item, size: .small)
        let first = RemoteThumbnailCacheKey.renderedImage(
            for: item,
            size: .small,
            displaySize: CGSize(width: 58, height: 58),
            scale: 3
        )
        let second = RemoteThumbnailCacheKey.renderedImage(
            for: item,
            size: .small,
            displaySize: CGSize(width: 104, height: 104),
            scale: 3
        )

        XCTAssertTrue((first as String).hasPrefix(remoteKey))
        XCTAssertTrue((second as String).hasPrefix(remoteKey))
        XCTAssertNotEqual(first, second)
    }

    func testModificationDateInvalidatesRemoteDataKey() {
        let first = makeItem(modifiedAt: Date(timeIntervalSince1970: 100))
        let second = makeItem(modifiedAt: Date(timeIntervalSince1970: 101))

        XCTAssertNotEqual(
            RemoteThumbnailCacheKey.remoteData(for: first, size: .small),
            RemoteThumbnailCacheKey.remoteData(for: second, size: .small)
        )
    }

    private func makeItem(modifiedAt: Date) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            path: "/video/test.mp4",
            name: "test.mp4",
            kind: .file,
            size: 123_456,
            modifiedAt: modifiedAt,
            contentTypeIdentifier: "public.mpeg-4"
        )
    }
}
