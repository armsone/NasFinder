import UIKit
import XCTest
@testable import NasFinder

final class RemoteThumbnailCellularAccountingTests: XCTestCase {
    private let leaseMaximumBytes = 4 * 1_024 * 1_024

    func testChargedBytesUsesKnownTransferAndBoundsUnknownOutcomes() {
        typealias Policy = RemoteThumbnailCellularAccountingPolicy

        XCTAssertEqual(
            Policy.chargedBytes(for: .data(byteCount: 48_000), leaseMaximumBytes: leaseMaximumBytes),
            48_000
        )
        XCTAssertEqual(
            Policy.chargedBytes(for: .empty, leaseMaximumBytes: leaseMaximumBytes),
            Policy.emptyResponseChargeBytes
        )
        XCTAssertEqual(
            Policy.chargedBytes(for: .failed(CancellationError()), leaseMaximumBytes: leaseMaximumBytes),
            Policy.interruptedResponseChargeBytes
        )
        XCTAssertEqual(
            Policy.chargedBytes(
                for: .failed(NasFinderError.invalidResponse),
                leaseMaximumBytes: leaseMaximumBytes
            ),
            Policy.interruptedResponseChargeBytes
        )
        XCTAssertEqual(
            Policy.chargedBytes(
                for: .failed(RemoteThumbnailError.responseTooLarge),
                leaseMaximumBytes: leaseMaximumBytes
            ),
            leaseMaximumBytes
        )

        // Unknown outcomes stay conservative: far below one item lease, but
        // never free, and never above what the lease could have moved.
        XCTAssertLessThan(Policy.interruptedResponseChargeBytes * 8, leaseMaximumBytes)
        XCTAssertGreaterThan(Policy.emptyResponseChargeBytes, 0)
        XCTAssertEqual(
            Policy.chargedBytes(for: .failed(CancellationError()), leaseMaximumBytes: 1_000),
            1_000
        )
        XCTAssertEqual(
            Policy.chargedBytes(for: .data(byteCount: 9_999), leaseMaximumBytes: 1_000),
            1_000
        )
    }

    func testMeteredFetchKeepsCellularPoolAfterEmptyCancelledAndFailedResponses() async throws {
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 24 * 1_024 * 1_024,
            maximumItemBytes: leaseMaximumBytes,
            minimumLeaseBytes: RemoteVideoThumbnailTrafficBudget.defaultMinimumLeaseBytes,
            maximumTotalBytes: 24 * 1_024 * 1_024
        )
        let service = ScriptedThumbnailService(
            outcomes: [
                .empty, .empty,
                .cancelled, .cancelled,
                .failed, .failed,
                .data(byteCount: 40_000)
            ]
        )
        let item = videoItem(connectionID: service.connection.id, name: "clip.mp4")

        for _ in 0..<2 {
            let data = try await budget.meteredThumbnailData(for: item, service: service, size: .large)
            XCTAssertNil(data)
        }
        for _ in 0..<4 {
            do {
                _ = try await budget.meteredThumbnailData(for: item, service: service, size: .large)
                XCTFail("Scripted failure must propagate")
            } catch {
                // Expected: the caller still sees the original error.
            }
        }

        // Six failures previously charged six full leases and emptied the
        // pool. Now the pool keeps capacity and the next request succeeds.
        let hasCapacity = await budget.hasCapacity()
        XCTAssertTrue(hasCapacity)
        let data = try await budget.meteredThumbnailData(for: item, service: service, size: .large)
        XCTAssertEqual(data?.count, 40_000)

        let expected = 2 * RemoteThumbnailCellularAccountingPolicy.emptyResponseChargeBytes
            + 4 * RemoteThumbnailCellularAccountingPolicy.interruptedResponseChargeBytes
            + 40_000
        let transferred = await budget.transferredBytes(for: item)
        XCTAssertEqual(transferred, expected)
        let requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 7)
    }

    func testMeteredFetchChargesLeaseCapOnlyForResponseTooLarge() async {
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 24 * 1_024 * 1_024,
            maximumItemBytes: leaseMaximumBytes,
            minimumLeaseBytes: RemoteVideoThumbnailTrafficBudget.defaultMinimumLeaseBytes,
            maximumTotalBytes: 24 * 1_024 * 1_024
        )
        let service = ScriptedThumbnailService(outcomes: [.tooLarge])
        let item = videoItem(connectionID: service.connection.id, name: "huge.mp4")

        do {
            _ = try await budget.meteredThumbnailData(for: item, service: service, size: .large)
            XCTFail("responseTooLarge must propagate")
        } catch RemoteThumbnailError.responseTooLarge {
            let transferred = await budget.transferredBytes(for: item)
            XCTAssertEqual(transferred, leaseMaximumBytes)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMeteredFetchThrowsExhaustedWithoutRequestingWhenPoolIsEmpty() async {
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 1_000,
            maximumItemBytes: 1_000,
            minimumLeaseBytes: 1_000,
            maximumTotalBytes: 1_000
        )
        let service = ScriptedThumbnailService(outcomes: [.data(byteCount: 1_000)])
        let item = videoItem(connectionID: service.connection.id, name: "clip.mp4")
        _ = try? await budget.meteredThumbnailData(for: item, service: service, size: .large)

        do {
            _ = try await budget.meteredThumbnailData(for: item, service: service, size: .large)
            XCTFail("Exhausted pool must not start a request")
        } catch RemoteVideoThumbnailGenerationError.trafficBudgetExhausted {
            let requestCount = await service.requestCount()
            XCTAssertEqual(requestCount, 1)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testNegativeCacheEntryIsTrustedOnlyOnItsNetworkPath() {
        let now = Date()
        let entry = RemoteThumbnailNegativeCacheEntry(
            expiration: now.addingTimeInterval(30),
            networkPathGeneration: 3
        )
        XCTAssertTrue(entry.isActive(at: now, networkPathGeneration: 3))
        XCTAssertFalse(entry.isActive(at: now.addingTimeInterval(31), networkPathGeneration: 3))
        XCTAssertFalse(entry.isActive(at: now, networkPathGeneration: 4))
    }

    func testCoverFlowReflectionMirrorsCardThumbnail() {
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.thumbnailDisplayMode(for: .card),
            .standard
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.thumbnailDisplayMode(for: .reflection),
            .mirrorsCachedImage
        )
    }

    @MainActor
    func testFailedLoaderRetriesOnlyAfterLegitimateInvalidation() async {
        RemoteThumbnailLoader.clearTransientFailures()
        let service = ScriptedThumbnailService(
            outcomes: Array(repeating: .failed, count: 8)
        )
        let item = imageItem(connectionID: service.connection.id, name: "photo.jpg")
        let size = CGSize(width: 280, height: 280)
        let loader = RemoteThumbnailLoader()

        await loader.load(item: item, service: service, size: size, reloadVersion: 0)
        var requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(loader.image)

        // The same identity running again (view re-created while dragging,
        // network flapping) is throttled by the negative cache: no storm.
        await loader.load(item: item, service: service, size: size, reloadVersion: 0)
        await RemoteThumbnailLoader().load(item: item, service: service, size: size, reloadVersion: 0)
        requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 1)

        // Clearing transient failures (folder re-entry) retries once.
        RemoteThumbnailLoader.clearTransientFailures()
        await loader.load(item: item, service: service, size: size, reloadVersion: 0)
        requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 2)

        // A user reload retries as well.
        await loader.load(item: item, service: service, size: size, reloadVersion: 1)
        requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 3)
        RemoteThumbnailLoader.clearTransientFailures()
    }

    @MainActor
    func testMirroredLoaderNeverRequestsAndFollowsCardImage() async throws {
        RemoteThumbnailLoader.clearTransientFailures()
        let service = ScriptedThumbnailService(
            outcomes: [.data(byteCount: 0, image: try Self.solidImageData())]
        )
        let item = imageItem(connectionID: service.connection.id, name: "card.png")
        let size = CGSize(width: 280, height: 280)
        let mirror = RemoteThumbnailLoader()

        mirror.showCachedImage(item: item, size: size)
        XCTAssertNil(mirror.image)
        var requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 0)

        let card = RemoteThumbnailLoader()
        await card.load(item: item, service: service, size: size, reloadVersion: 0)
        XCTAssertNotNil(card.image)
        requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 1)

        mirror.showCachedImage(item: item, size: size)
        XCTAssertNotNil(mirror.image)
        XCTAssertTrue(mirror.image === card.image)

        // A store for another key leaves the mirror untouched; the matching
        // key is what the reflection listens for.
        let otherItem = imageItem(connectionID: service.connection.id, name: "other.png")
        mirror.showCachedImage(item: otherItem, size: size, onlyIfKeyMatches: "unrelated")
        XCTAssertNotNil(mirror.image)
        requestCount = await service.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    private static func solidImageData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func videoItem(connectionID: UUID, name: String) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: "/videos/\(name)",
            name: name,
            kind: .file,
            size: 900_000_000,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }

    private func imageItem(connectionID: UUID, name: String) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: "/photos/\(UUID().uuidString)/\(name)",
            name: name,
            kind: .file,
            size: 200_000,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }
}

private enum ScriptedThumbnailOutcome {
    case data(byteCount: Int, image: Data? = nil)
    case empty
    case cancelled
    case failed
    case tooLarge
}

private actor ScriptedThumbnailScript {
    private var outcomes: [ScriptedThumbnailOutcome]
    private(set) var requestCount = 0

    init(outcomes: [ScriptedThumbnailOutcome]) {
        self.outcomes = outcomes
    }

    func next() -> ScriptedThumbnailOutcome {
        requestCount += 1
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }
}

private struct ScriptedThumbnailService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Scripted thumbnails",
        kind: .synology,
        host: "scripted.invalid",
        username: "tester"
    )
    private let script: ScriptedThumbnailScript

    init(outcomes: [ScriptedThumbnailOutcome]) {
        script = ScriptedThumbnailScript(outcomes: outcomes)
    }

    func requestCount() async -> Int {
        await script.requestCount
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] { [] }
    func download(_ item: RemoteFileItem) async throws -> URL {
        throw NasFinderError.invalidResponse
    }
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        try await thumbnailData(for: item, size: size, maximumByteCount: .max)
    }
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        maximumByteCount: Int
    ) async throws -> Data? {
        switch await script.next() {
        case .data(let byteCount, let image):
            return image ?? Data(repeating: 0xAB, count: byteCount)
        case .empty:
            return nil
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw NasFinderError.invalidResponse
        case .tooLarge:
            throw RemoteThumbnailError.responseTooLarge
        }
    }
    func testConnection() async throws {}
}
