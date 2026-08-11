import Foundation
import XCTest
@testable import NasFinder

final class DownloadCacheTests: XCTestCase {
    func testTrustedStoredPayloadDoesNotDependOnStaleListingSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let payload = Data(repeating: 0x53, count: 256)
        try payload.write(to: source)
        let cache = DownloadCache(root: root)
        let item = makeItem(listedByteCount: 1_024)

        let storedURL = try await cache.store(downloadedURL: source, for: item)
        let cachedURL = await cache.cachedURL(for: item)

        XCTAssertEqual(cachedURL, storedURL)
        XCTAssertEqual(try cachedURL.map { try Data(contentsOf: $0) }, payload)
    }

    private func makeItem(listedByteCount: Int64) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(),
            path: "/share/clip.mov",
            name: "clip.mov",
            kind: .file,
            size: listedByteCount,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
    }
}
