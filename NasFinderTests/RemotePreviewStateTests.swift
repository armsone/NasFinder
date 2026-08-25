@preconcurrency import AVFoundation
import CoreVideo
import UIKit
import XCTest
@testable import NasFinder

@MainActor
final class RemotePreviewStateTests: XCTestCase {
    func testPlaybackSourceLabelsAndControlsAutoHideDelay() {
        XCTAssertEqual(RemoteVideoPlaybackSource.partial.title, "부분 재생")
        XCTAssertEqual(RemoteVideoPlaybackSource.completeFile.title, "전체 파일")
        XCTAssertEqual(
            RemotePreviewInteractionPolicy.controlsAutoHideDelay,
            .milliseconds(2_500)
        )
    }

    func testVerticalVolumeDragStaysVolumeUntilFingerIsReleased() {
        let started = RemotePreviewVerticalDragMode.resolve(
            existing: nil,
            verticalTranslation: -80
        )
        XCTAssertEqual(started, .volume)
        XCTAssertEqual(
            RemotePreviewVerticalDragMode.resolve(
                existing: started,
                verticalTranslation: 140
            ),
            .volume
        )
    }

    func testVerticalDismissDragDoesNotBecomeVolumeMidGesture() {
        let started = RemotePreviewVerticalDragMode.resolve(
            existing: nil,
            verticalTranslation: 40
        )
        XCTAssertEqual(started, .dismiss)
        XCTAssertEqual(
            RemotePreviewVerticalDragMode.resolve(
                existing: started,
                verticalTranslation: -140
            ),
            .dismiss
        )
    }

    func testCompatibilityFormatPolicyKeepsMP4AndMOVOnAVPlayer() {
        let connectionID = UUID()
        for filename in ["movie.mp4", "clip.mov", "recording.m4v"] {
            let item = RemoteFileItem(
                connectionID: connectionID,
                path: "/share/\(filename)",
                name: filename,
                kind: .file,
                size: 1_024,
                modifiedAt: nil,
                contentTypeIdentifier: nil
            )
            XCTAssertFalse(
                CompatibilityVideoFormatPolicy.prefersCompatibilityPlayer(for: item)
            )
        }
    }

    func testCompatibilityFormatPolicyRoutesLegacyContainersToVLCKit() {
        let connectionID = UUID()
        for filename in ["movie.AVI", "clip.asf", "archive.wmv", "video.mkv"] {
            let item = RemoteFileItem(
                connectionID: connectionID,
                path: "/share/\(filename)",
                name: filename,
                kind: .file,
                size: 1_024,
                modifiedAt: nil,
                contentTypeIdentifier: nil
            )
            XCTAssertTrue(
                CompatibilityVideoFormatPolicy.prefersCompatibilityPlayer(for: item)
            )
        }
    }

    func testCompatibilitySubtitleMatchesExactBaseNameAndPrefersSRT() throws {
        let connectionID = UUID()
        let video = remoteItem(
            connectionID: connectionID,
            path: "/share/Movie.MKV"
        )
        let items = [
            remoteItem(connectionID: connectionID, path: "/share/Movie.en.srt"),
            remoteItem(connectionID: connectionID, path: "/share/movie.ass"),
            remoteItem(connectionID: connectionID, path: "/share/MOVIE.SRT"),
            remoteItem(connectionID: connectionID, path: "/other/Movie.srt"),
        ]

        let match = try XCTUnwrap(
            CompatibilityExternalSubtitlePolicy.matchingSubtitle(
                for: video,
                in: items
            )
        )
        XCTAssertEqual(match.path, "/share/MOVIE.SRT")
    }

    func testCompatibilitySubtitleDoesNotMatchLanguageSuffix() {
        let connectionID = UUID()
        let video = remoteItem(connectionID: connectionID, path: "/share/Movie.mkv")
        let subtitle = remoteItem(
            connectionID: connectionID,
            path: "/share/Movie.ko.srt"
        )

        XCTAssertNil(
            CompatibilityExternalSubtitlePolicy.matchingSubtitle(
                for: video,
                in: [subtitle]
            )
        )
    }

    func testSFTPMKVCircumventsAVFoundationBackendThumbnail() {
        let service = ThumbnailRoutingTestService(kind: .sftp)
        let mkv = remoteItem(
            connectionID: service.connection.id,
            path: "/share/video.mkv"
        )
        let mp4 = remoteItem(
            connectionID: service.connection.id,
            path: "/share/video.mp4"
        )

        XCTAssertTrue(
            RemoteVideoThumbnailRoutingPolicy.bypassesBackendThumbnail(
                for: mkv,
                service: service
            )
        )
        XCTAssertTrue(
            RemoteVideoThumbnailRoutingPolicy.canGenerateBoundedThumbnail(
                for: mkv,
                service: service
            )
        )
        XCTAssertFalse(
            RemoteVideoThumbnailRoutingPolicy.bypassesBackendThumbnail(
                for: mp4,
                service: service
            )
        )
    }

    func testSynologyMKVTriesServerThumbnailBeforeVLCKitFallback() {
        let service = ThumbnailRoutingTestService(kind: .synology)
        let mkv = remoteItem(
            connectionID: service.connection.id,
            path: "/share/video.mkv"
        )

        XCTAssertFalse(
            RemoteVideoThumbnailRoutingPolicy.bypassesBackendThumbnail(
                for: mkv,
                service: service
            )
        )
        XCTAssertTrue(
            RemoteVideoThumbnailRoutingPolicy.canGenerateBoundedThumbnail(
                for: mkv,
                service: service
            )
        )
    }

    func testCompatibilityThumbnailPlaybackIsSilentAndSerialized() {
        XCTAssertTrue(
            CompatibilityVideoThumbnailPlaybackPolicy.usesDedicatedThumbnailer
        )
        XCTAssertEqual(
            CompatibilityVideoThumbnailPlaybackPolicy.maximumConcurrentOperations,
            1
        )
        XCTAssertEqual(
            CompatibilityVideoThumbnailPlaybackPolicy.cleanupQueueLabel,
            "com.armsone.nasfinder.vlc-thumbnail-cleanup"
        )
        XCTAssertEqual(
            RemoteVideoThumbnailTrafficBudget.defaultMaximumFolderBytes,
            256 * 1_024 * 1_024
        )
        XCTAssertEqual(
            RemoteVideoThumbnailTrafficBudget.defaultMaximumItemBytes,
            16 * 1_024 * 1_024
        )
        XCTAssertEqual(
            ThumbnailPreheater.maximumSynologyDataBytes,
            256 * 1_024 * 1_024
        )
        XCTAssertEqual(
            ThumbnailPreheater.maximumCellularDataBytes,
            24 * 1_024 * 1_024
        )
        XCTAssertTrue(
            ThumbnailPreheatPolicy.allowsConstrainedNetwork(for: .bounded)
        )
        XCTAssertFalse(
            ThumbnailPreheatPolicy.allowsConstrainedNetwork(for: .completeFile)
        )
        XCTAssertFalse(
            CompatibilityVideoThumbnailAttemptPolicy.usesPlayerSnapshotFirst(
                for: .synology
            )
        )
        XCTAssertFalse(
            CompatibilityVideoThumbnailAttemptPolicy.usesPlayerSnapshotFirst(
                for: .sftp
            )
        )
        XCTAssertEqual(
            CompatibilityVideoThumbnailAttemptPolicy.seekFallbackDelay,
            .seconds(2)
        )
    }

    func testSuperThumbnailReportShowsSuccessAndRemainingByStage() {
        let report = SuperThumbnailSessionReport(
            successCounts: [10, 30, 2],
            failures: [
                SuperThumbnailFailureRecord(
                    itemID: "failed",
                    name: "failed.mkv",
                    fileExtension: "MKV",
                    fileSize: 1_024,
                    durationSeconds: 60,
                    reason: "timeout"
                ),
            ],
            pendingCount: 1,
            cachedCount: 50
        )

        XCTAssertEqual(report.totalCount, 93)
        XCTAssertEqual(report.remainingCounts, [33, 3, 1])
        XCTAssertTrue(report.hasWorkToResume)
    }

    func testSuperThumbnailCachedItemDoesNotDuplicateSuccessfulResult() async {
        let suiteName = "SuperThumbnailQueueStoreTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let store = SuperThumbnailQueueStore(
            userDefaults: UserDefaults(suiteName: suiteName)!
        )
        let item = remoteItem(
            connectionID: UUID(),
            path: "/share/movie.mkv"
        )
        _ = await store.attempts(for: [item], sessionKey: "session")
        await store.recordSuccess(item, sessionKey: "session", attempt: 0)
        let transition = await store.markCached(
            item,
            sessionKey: "session"
        )

        let report = await store.report(sessionKey: "session")
        XCTAssertEqual(transition.previousSuccessAttempt, 0)
        XCTAssertFalse(transition.removedPhotoSuccess)
        XCTAssertFalse(transition.removedFailure)
        XCTAssertEqual(report?.successCounts, [0, 0, 0])
        XCTAssertEqual(report?.cachedCount, 1)
        XCTAssertEqual(report?.totalCount, 1)
    }

    func testSuperThumbnailPhotoScopeAndResultSurviveVideoOnlyObservation() async {
        let suiteName = "SuperThumbnailPhotoScopeTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let store = SuperThumbnailQueueStore(
            userDefaults: UserDefaults(suiteName: suiteName)!
        )
        let connectionID = UUID()
        let video = remoteItem(connectionID: connectionID, path: "/share/movie.mkv")
        let photo = remoteItem(connectionID: connectionID, path: "/share/photo.heic")

        _ = await store.attempts(
            for: [video, photo],
            sessionKey: "session",
            allObservedItems: [video, photo],
            mediaScope: .videosAndPhotos
        )
        await store.recordPhotoSuccess(photo, sessionKey: "session")

        _ = await store.attempts(
            for: [video],
            sessionKey: "session",
            allObservedItems: [video, photo],
            mediaScope: .videosOnly
        )
        let report = await store.report(sessionKey: "session")

        XCTAssertEqual(report?.photoSuccessCount, 1)
        XCTAssertEqual(report?.mediaScope, .videosOnly)
        XCTAssertEqual(report?.pendingCount, 1)
        XCTAssertEqual(report?.totalCount, 2)
    }

    func testSuperThumbnailVaultResumeReportPersistsFolderUploadProgress() async {
        let suiteName = "SuperThumbnailVaultResumeTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let store = SuperThumbnailQueueStore(
            userDefaults: UserDefaults(suiteName: suiteName)!
        )
        let connectionID = UUID()
        let first = remoteItem(
            connectionID: connectionID,
            path: "/share/movies/first.mkv"
        )
        let second = remoteItem(
            connectionID: connectionID,
            path: "/share/movies/second.mkv"
        )
        let third = remoteItem(
            connectionID: connectionID,
            path: "/share/photos/third.mov"
        )
        let items = [first, second, third]

        _ = await store.attempts(for: items, sessionKey: "session")
        for item in items {
            _ = await store.markCached(item, sessionKey: "session")
        }
        await store.prepareVault(for: items, sessionKey: "session")
        await store.markVaultPending(first, sessionKey: "session")
        await store.markVaultPending(second, sessionKey: "session")
        await store.recordVaultResult(
            storedItemIDs: [first.id],
            attemptedItemIDs: [first.id, second.id],
            errorDescription: "upload failed",
            sessionKey: "session"
        )

        var report = await store.report(sessionKey: "session")
        XCTAssertEqual(report?.vaultUploadedCount, 1)
        XCTAssertEqual(report?.vaultFailedCount, 1)
        XCTAssertEqual(report?.vaultWaitingThumbnailCount, 1)
        XCTAssertTrue(report?.hasWorkToResume == true)
        XCTAssertEqual(report?.vaultFolders.count, 2)

        await store.markVaultPending(third, sessionKey: "session")
        let verifiedAt = Date(timeIntervalSince1970: 1_234)
        await store.recordVaultVerification(
            storedItemIDs: Set(items.map(\.id)),
            verifiedAt: verifiedAt,
            sessionKey: "session"
        )
        report = await store.report(sessionKey: "session")
        XCTAssertEqual(report?.vaultUploadedCount, 3)
        XCTAssertEqual(report?.vaultPendingCount, 0)
        XCTAssertEqual(report?.vaultFailedCount, 0)
        XCTAssertEqual(report?.vaultLastVerifiedAt, verifiedAt)
        XCTAssertFalse(report?.hasWorkToResume == true)
    }

    func testSuperThumbnailResumeUsesOnlyUnfinishedStoredItems() async {
        let suiteName = "SuperThumbnailResumeItemsTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let store = SuperThumbnailQueueStore(
            userDefaults: UserDefaults(suiteName: suiteName)!
        )
        let connectionID = UUID()
        let uploaded = remoteItem(connectionID: connectionID, path: "/share/uploaded.mkv")
        let pendingUpload = remoteItem(connectionID: connectionID, path: "/share/pending.mkv")
        let failedThumbnail = remoteItem(connectionID: connectionID, path: "/share/failed.mkv")
        let items = [uploaded, pendingUpload, failedThumbnail]

        _ = await store.attempts(for: items, sessionKey: "session")
        for item in [uploaded, pendingUpload] {
            _ = await store.markCached(item, sessionKey: "session")
        }
        await store.recordFailure(
            failedThumbnail,
            sessionKey: "session",
            durationSeconds: nil,
            reason: "timeout"
        )
        await store.prepareVault(for: items, sessionKey: "session")
        await store.markVaultPending(uploaded, sessionKey: "session")
        await store.markVaultPending(pendingUpload, sessionKey: "session")
        await store.recordVaultResult(
            storedItemIDs: [uploaded.id],
            attemptedItemIDs: [uploaded.id, pendingUpload.id],
            errorDescription: "upload failed",
            sessionKey: "session"
        )

        let resumed = await store.resumeItems(
            sessionKey: "session",
            connectionID: connectionID
        )

        XCTAssertEqual(
            Set(resumed.map(\.id)),
            Set([pendingUpload.id, failedThumbnail.id])
        )

        let failureOnlySuiteName = "SuperThumbnailResumeFailureOnlyTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: failureOnlySuiteName)?
                .removePersistentDomain(forName: failureOnlySuiteName)
        }
        let failureOnlyStore = SuperThumbnailQueueStore(
            userDefaults: UserDefaults(suiteName: failureOnlySuiteName)!
        )
        _ = await failureOnlyStore.attempts(
            for: [failedThumbnail],
            sessionKey: "failure-only"
        )
        await failureOnlyStore.recordFailure(
            failedThumbnail,
            sessionKey: "failure-only",
            durationSeconds: nil,
            reason: "timeout"
        )
        let failureOnlyResume = await failureOnlyStore.resumeItems(
            sessionKey: "failure-only",
            connectionID: connectionID
        )
        XCTAssertEqual(failureOnlyResume.map(\.id), [failedThumbnail.id])
    }

    func testVaultUploadCanReuseAutomaticThumbnailCache() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let superCache = SuperThumbnailCache(
            directoryURL: testRoot.appendingPathComponent("super", isDirectory: true),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let automaticCache = RemoteThumbnailDiskCache(
            directoryURL: testRoot.appendingPathComponent("automatic", isDirectory: true),
            userDefaultsSuiteName: UUID().uuidString
        )
        let item = remoteItem(connectionID: UUID(), path: "/share/cached.mkv")
        let imageData = try XCTUnwrap(
            UIImage(systemName: "photo")?.pngData()
        )
        let key = RemoteThumbnailCacheKey.remoteData(for: item, size: .small)
        await automaticCache.store(imageData, forKey: key)

        let restored = await ThumbnailPreheater.localThumbnailDataForVault(
            for: item,
            superCache: superCache,
            automaticCache: automaticCache
        )

        XCTAssertEqual(restored, imageData)
    }

    func testSuperThumbnailResumePrioritizesPreviousFailuresThenEarlierStages() {
        let connectionID = UUID()
        let newItem = remoteItem(connectionID: connectionID, path: "/new.mkv")
        let retryItem = remoteItem(connectionID: connectionID, path: "/retry.mkv")
        let failedItem = remoteItem(connectionID: connectionID, path: "/failed.mkv")
        let recoveryItem = remoteItem(connectionID: connectionID, path: "/recovery.mkv")

        let ordered = SuperThumbnailResumePolicy.orderedCandidates(
            [newItem, retryItem, failedItem, recoveryItem],
            savedAttempts: [
                retryItem.id: 1,
                failedItem.id: 2,
                recoveryItem.id: 2,
            ],
            previousFailureIDs: [failedItem.id]
        )

        XCTAssertEqual(
            ordered.map(\.id),
            [failedItem.id, newItem.id, retryItem.id, recoveryItem.id]
        )
    }

    func testTrafficMeasuringServiceForwardsBoundedThumbnailLimit() async throws {
        let probe = BoundedThumbnailProbe()
        let base = BoundedThumbnailProbeService(probe: probe)
        let tracker = PageNetworkTrafficTracker()
        let service = TrafficMeasuringRemoteFileService(
            base: base,
            tracker: tracker
        )
        let item = remoteItem(
            connectionID: base.connection.id,
            path: "/share/movie.mkv"
        )

        _ = try await service.thumbnailData(
            for: item,
            size: .small,
            maximumByteCount: 4_096
        )

        let forwardedLimit = await probe.maximumByteCount
        XCTAssertEqual(forwardedLimit, 4_096)
    }

    func testCompatibilityRemoteStreamSupportsBoundedReadsAndSeeking() async throws {
        let movieURL = try await makeTinyMOV()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let byteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        let service = RangeReadingTinyVideoService(movieURL: movieURL)
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/tiny.avi",
            name: "tiny.avi",
            kind: .file,
            size: byteCount,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let stream = try CompatibilityRemoteInputStream(
            item: item,
            service: service,
            maximumTransferredBytes: CompatibilityRemoteInputStream.maximumReadChunkBytes * 2
        )
        stream.open()
        defer { stream.close() }

        var firstBytes = [UInt8](repeating: 0, count: 32)
        let firstCount = stream.read(&firstBytes, maxLength: firstBytes.count)
        XCTAssertEqual(firstCount, firstBytes.count)
        XCTAssertEqual(
            stream.property(forKey: .fileCurrentOffsetKey) as? NSNumber,
            NSNumber(value: firstBytes.count)
        )

        XCTAssertTrue(
            stream.setProperty(4, forKey: .fileCurrentOffsetKey)
        )
        var soughtBytes = [UInt8](repeating: 0, count: 16)
        let soughtCount = stream.read(&soughtBytes, maxLength: soughtBytes.count)
        XCTAssertEqual(soughtCount, soughtBytes.count)
        XCTAssertGreaterThan(stream.accountedByteCount, 0)
        XCTAssertLessThanOrEqual(
            stream.accountedByteCount,
            CompatibilityRemoteInputStream.maximumReadChunkBytes * 2
        )
    }

    func testCompatibilityRemoteStreamStopsAStalledRangeRead() {
        let service = StallingRangeVideoService()
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/stalled.avi",
            name: "stalled.avi",
            kind: .file,
            size: 1_024 * 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let stream = try! CompatibilityRemoteInputStream(
            item: item,
            service: service,
            rangeReadTimeout: 0.05
        )
        stream.open()
        defer { stream.close() }

        var bytes = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(stream.read(&bytes, maxLength: bytes.count), -1)
        XCTAssertEqual(
            stream.streamError as? CompatibilityVideoPlayerError,
            .remoteReadTimedOut
        )
    }

    func testClosingCompatibilityRemoteStreamUnblocksActiveRead() async throws {
        let service = StallingRangeVideoService()
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/stalled.avi",
            name: "stalled.avi",
            kind: .file,
            size: 1_024 * 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let stream = try CompatibilityRemoteInputStream(
            item: item,
            service: service,
            rangeReadTimeout: 30
        )
        stream.open()
        let readTask = Task.detached {
            var bytes = [UInt8](repeating: 0, count: 32)
            return stream.read(&bytes, maxLength: bytes.count)
        }
        try await Task.sleep(for: .milliseconds(50))

        let clock = ContinuousClock()
        let closingStartedAt = clock.now
        stream.close()

        let readResult = await readTask.value
        XCTAssertEqual(readResult, -1)
        XCTAssertLessThan(
            closingStartedAt.duration(to: clock.now),
            .seconds(1)
        )
    }

    func testStoppingCompatibilityPlayerReturnsWhileRemoteReadIsStalled() async throws {
        let service = StallingRangeVideoService()
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/stalled.avi",
            name: "stalled.avi",
            kind: .file,
            size: 1_024 * 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let player = try CompatibilityVideoPlayer(item: item, service: service)
        player.play()
        try await Task.sleep(for: .milliseconds(50))

        let clock = ContinuousClock()
        let stopStartedAt = clock.now
        player.stop()

        XCTAssertLessThan(stopStartedAt.duration(to: clock.now), .milliseconds(250))
    }

    func testCompatibilityPlaybackWatchdogReportsNoProgress() async {
        let expectation = expectation(description: "stalled playback detected")
        let watchdog = CompatibilityPlaybackWatchdog()
        watchdog.start(
            stallTimeout: .milliseconds(40),
            pollInterval: .milliseconds(5),
            isPlaybackExpected: { true },
            currentSeconds: { 0 },
            onStall: { expectation.fulfill() }
        )

        await fulfillment(of: [expectation], timeout: 1)
        watchdog.stop()
    }

    func testCompatibilityPlaybackWatchdogIgnoresPausedPlayback() async {
        let expectation = expectation(description: "paused playback is not stalled")
        expectation.isInverted = true
        let watchdog = CompatibilityPlaybackWatchdog()
        watchdog.start(
            stallTimeout: .milliseconds(30),
            pollInterval: .milliseconds(5),
            isPlaybackExpected: { false },
            currentSeconds: { 0 },
            onStall: { expectation.fulfill() }
        )

        await fulfillment(of: [expectation], timeout: 0.1)
        watchdog.stop()
    }

    func testCompatibilityPlaybackWatchdogAcceptsContinuedProgress() async {
        let expectation = expectation(description: "progressing playback is not stalled")
        expectation.isInverted = true
        var currentSeconds = 0.0
        let watchdog = CompatibilityPlaybackWatchdog()
        watchdog.start(
            stallTimeout: .milliseconds(35),
            pollInterval: .milliseconds(5),
            isPlaybackExpected: { true },
            currentSeconds: { currentSeconds },
            onStall: { expectation.fulfill() }
        )
        let progressTask = Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(10))
                currentSeconds += 0.1
            }
        }

        await fulfillment(of: [expectation], timeout: 0.1)
        await progressTask.value
        watchdog.stop()
    }

    func testAAAHeavySynologyCompatibilityThumbnailUsesPlayerSnapshot() async throws {
        let movieURL = try await makeTinyMOV()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let byteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        let service = RangeReadingTinyVideoService(movieURL: movieURL)
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/tiny.avi",
            name: "tiny.avi",
            kind: .file,
            size: byteCount,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let maximumBytes = 1 * 1_024 * 1_024
        let trafficBudget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: maximumBytes,
            maximumItemBytes: maximumBytes,
            minimumLeaseBytes: 1
        )

        let result = try await RemoteVideoThumbnailGenerator.generate(
            for: item,
            service: service,
            size: .small,
            trafficBudget: trafficBudget,
            timeout: .seconds(10)
        )

        XCTAssertFalse(result.data.isEmpty)
        XCTAssertGreaterThan(result.transferredBytes, 0)
        XCTAssertLessThanOrEqual(result.transferredBytes, maximumBytes)
    }

    func testOfficialAVIAndASFSamplesPlaySeekRotateAndCreateThumbnails() async throws {
        guard ProcessInfo.processInfo.environment["NASFINDER_VLC_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("실제 VideoLAN 미디어 검증은 명시적으로 활성화할 때만 실행합니다.")
        }

        let samples = [
            (
                filename: "2-audio-streams.avi",
                url: URL(string: "https://streams.videolan.org/samples/avi/2-audio-streams.avi")!
            ),
            (
                filename: "IMAG0002.ASF",
                url: URL(string: "https://streams.videolan.org/samples/asf-wmv/IMAG0002.ASF")!
            ),
        ]

        for sample in samples {
            let (data, response) = try await URLSession.shared.data(from: sample.url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(data.isEmpty)
            let localURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .notDirectory)
                .appendingPathExtension((sample.filename as NSString).pathExtension)
            try data.write(to: localURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: localURL) }

            let service = RangeReadingTinyVideoService(movieURL: localURL)
            let item = RemoteFileItem(
                connectionID: service.connection.id,
                path: "/integration/\(sample.filename)",
                name: sample.filename,
                kind: .file,
                size: Int64(data.count),
                modifiedAt: nil,
                contentTypeIdentifier: nil
            )
            let viewModel = RemotePreviewViewModel(
                items: [item],
                initialItemID: item.id,
                service: service
            )
            await viewModel.loadCurrentItem()
            let player = try XCTUnwrap(viewModel.compatibilityPlayer)
            let drawable = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            player.attach(drawable: drawable)
            player.play()

            try await waitUntil(timeout: .seconds(20)) {
                !viewModel.isPreparingVideo || viewModel.errorMessage != nil
            }
            XCTAssertNil(viewModel.errorMessage, sample.filename)
            try await waitUntil(timeout: .seconds(10)) {
                player.currentSeconds > 0.1
            }
            XCTAssertFalse(player.mediaPlayer.audioTracks.isEmpty, sample.filename)
            XCTAssertFalse(player.mediaPlayer.videoTracks.isEmpty, sample.filename)
            XCTAssertGreaterThan(player.mediaPlayer.videoSize.width, 0, sample.filename)
            XCTAssertGreaterThan(player.mediaPlayer.videoSize.height, 0, sample.filename)

            let seekTarget = min(max(player.durationSeconds * 0.5, 0.2), 2)
            player.seek(to: seekTarget)
            player.play()
            try await waitUntil(timeout: .seconds(10)) {
                player.currentSeconds >= seekTarget
            }

            drawable.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
            drawable.setNeedsLayout()
            drawable.layoutIfNeeded()
            XCTAssertTrue(player.mediaPlayer.drawable as? UIView === drawable)
            viewModel.tearDown()

            let maximumBytes = min(max(data.count, 1), 4 * 1_024 * 1_024)
            for _ in 0..<3 {
                let budget = RemoteVideoThumbnailTrafficBudget(
                    maximumFolderBytes: maximumBytes,
                    maximumItemBytes: maximumBytes,
                    minimumLeaseBytes: 1
                )
                let thumbnail = try await RemoteVideoThumbnailGenerator.generate(
                    for: item,
                    service: service,
                    size: .small,
                    trafficBudget: budget,
                    timeout: .seconds(20)
                )
                XCTAssertFalse(thumbnail.data.isEmpty, sample.filename)
                XCTAssertLessThanOrEqual(thumbnail.transferredBytes, maximumBytes)
            }
        }
    }

    func testSingleTapOnlyTogglesPlaybackWhenControlsAreVisible() {
        XCTAssertFalse(
            RemotePreviewInteractionPolicy.shouldTogglePlaybackOnSingleTap(
                controlsAreVisible: false
            )
        )
        XCTAssertTrue(
            RemotePreviewInteractionPolicy.shouldTogglePlaybackOnSingleTap(
                controlsAreVisible: true
            )
        )
    }

    func testPreviewStartsWithAutomaticPlaybackEnabled() {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let item = previewVideoItem(connectionID: service.connection.id)

        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service
        )

        XCTAssertTrue(viewModel.isPlaying)
    }

    func testStreamingPlayerIsPresentedWithoutLocalFileURL() {
        let kind = RemotePreviewContentKind.resolve(
            isImage: false,
            isVideo: true,
            hasImage: false,
            hasPlayer: true,
            hasLocalURL: false,
            hasError: false
        )

        XCTAssertEqual(kind, .video)
    }

    func testVideoWithoutPlayerStillShowsLoading() {
        let kind = RemotePreviewContentKind.resolve(
            isImage: false,
            isVideo: true,
            hasImage: false,
            hasPlayer: false,
            hasLocalURL: false,
            hasError: false
        )

        XCTAssertEqual(kind, .loading)
    }

    func testPreviewErrorTakesPriorityOverPreparedContent() {
        let kind = RemotePreviewContentKind.resolve(
            isImage: false,
            isVideo: true,
            hasImage: false,
            hasPlayer: true,
            hasLocalURL: false,
            hasError: true
        )

        XCTAssertEqual(kind, .error)
    }

    func testEverySizedVideoUsesRangeStreamingWhenBackendSupportsIt() {
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: true,
                fileSize: 1
            ),
            .rangeStreaming
        )
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: true,
                fileSize: 2 * 1_024 * 1_024 * 1_024
            ),
            .rangeStreaming
        )
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: false,
                fileSize: 2 * 1_024 * 1_024 * 1_024
            ),
            .fullDownload
        )
        XCTAssertEqual(
            RemoteVideoLoadStrategy.resolve(
                supportsRangeStreaming: true,
                fileSize: nil
            ),
            .fullDownload
        )
    }

    func testSmallMOVReportsProgressThenCreatesLocalPlayer() async throws {
        let movieURL = try await makeTinyMOV()
        defer { try? FileManager.default.removeItem(at: movieURL) }

        let byteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        XCTAssertGreaterThan(byteCount, 0)

        let gate = SuccessfulSmallVideoProgressGate()
        let service = SuccessfulSmallVideoService(
            movieURL: movieURL,
            gate: gate
        )
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/share/tiny.mov",
            name: "tiny.mov",
            kind: .file,
            size: byteCount,
            modifiedAt: nil,
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .seconds(2),
            downloadInactivityPollInterval: .milliseconds(20)
        )

        let loadTask = Task { await viewModel.loadCurrentItem(forceFullDownload: true) }
        do {
            try await gate.waitUntilMiddleProgress()
        } catch {
            await gate.releaseMiddleProgress()
            await loadTask.value
            throw error
        }

        let middleByteCount = max(byteCount / 2, 1)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(
            viewModel.downloadProgress?.completedByteCount,
            middleByteCount
        )
        if let fraction = viewModel.downloadProgress?.fractionCompleted {
            XCTAssertEqual(
                fraction,
                Double(middleByteCount) / Double(byteCount),
                accuracy: 0.000_001
            )
        } else {
            XCTFail("중간 다운로드 진행률이 확정값이어야 합니다.")
        }

        await gate.releaseMiddleProgress()
        await loadTask.value

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.localURL, movieURL)
        XCTAssertNotNil(viewModel.player)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.downloadProgress)
        let progressValues = await gate.progressValues
        XCTAssertEqual(progressValues, [0, middleByteCount, byteCount])

        viewModel.tearDown()
    }

    func testRemoteThumbnailGenerationUsesBoundedRangeReads() async throws {
        let movieURL = try await makeTinyMOV()
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let byteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        let service = RangeReadingTinyVideoService(movieURL: movieURL)
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/tiny.mov",
            name: "tiny.mov",
            kind: .file,
            size: byteCount,
            modifiedAt: nil,
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
        let maximumBytes = 1 * 1_024 * 1_024
        let trafficBudget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: maximumBytes,
            maximumItemBytes: maximumBytes,
            minimumLeaseBytes: 1
        )

        let result = try await RemoteVideoThumbnailGenerator.generate(
            for: item,
            service: service,
            size: .small,
            trafficBudget: trafficBudget
        )

        XCTAssertFalse(result.data.isEmpty)
        XCTAssertGreaterThan(result.transferredBytes, 0)
        XCTAssertLessThanOrEqual(result.transferredBytes, maximumBytes)
        let recordedBytes = await trafficBudget.transferredBytes(for: item)
        XCTAssertEqual(recordedBytes, result.transferredBytes)
    }

    func testRemoteThumbnailGenerationTimesOutStalledRangeRead() async throws {
        let service = StallingRangeVideoService()
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/stalled.mp4",
            name: "stalled.mp4",
            kind: .file,
            size: 8 * 1_024 * 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: "public.mpeg-4"
        )
        let trafficBudget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 1 * 1_024 * 1_024,
            maximumItemBytes: 1 * 1_024 * 1_024,
            minimumLeaseBytes: 1
        )
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await RemoteVideoThumbnailGenerator.generate(
                for: item,
                service: service,
                size: .small,
                trafficBudget: trafficBudget,
                timeout: .milliseconds(100)
            )
            XCTFail("멈춘 범위 읽기는 제한 시간 오류여야 합니다.")
        } catch RemoteVideoThumbnailGenerationError.timedOut {
            XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(2))
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }
    }

    func testCancelledCompatibilityThumbnailDoesNotBlockNextGeneration() async throws {
        let service = StallingRangeVideoService()
        let item = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/home/test/stalled.avi",
            name: "stalled.avi",
            kind: .file,
            size: 8 * 1_024 * 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let trafficBudget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 8 * 1_024 * 1_024,
            maximumItemBytes: 4 * 1_024 * 1_024,
            minimumLeaseBytes: 1
        )
        let first = Task {
            try await RemoteVideoThumbnailGenerator.generate(
                for: item,
                service: service,
                size: .small,
                trafficBudget: trafficBudget,
                timeout: .seconds(30)
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let cancellationStartedAt = clock.now
        first.cancel()
        await CompatibilityRemoteVideoThumbnailGenerator.cancelAll()
        do {
            _ = try await first.value
            XCTFail("취소된 호환 썸네일이 성공하면 안 됩니다.")
        } catch is CancellationError {
            XCTAssertLessThan(
                cancellationStartedAt.duration(to: clock.now),
                .seconds(2)
            )
        } catch {
            XCTFail("취소는 CancellationError여야 합니다: \(error)")
        }

        do {
            _ = try await RemoteVideoThumbnailGenerator.generate(
                for: item,
                service: service,
                size: .small,
                trafficBudget: trafficBudget,
                timeout: .milliseconds(100)
            )
            XCTFail("다음 멈춘 작업은 제한 시간 오류여야 합니다.")
        } catch RemoteVideoThumbnailGenerationError.timedOut {
            XCTAssertLessThan(
                cancellationStartedAt.duration(to: clock.now),
                .seconds(3)
            )
        } catch {
            XCTFail("다음 작업이 이전 대기열에 막혔습니다: \(error)")
        }
    }

    func testRemoteThumbnailQualityRejectsFlatWhiteFrame() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())

        XCTAssertFalse(RemoteVideoThumbnailQuality.isUsable(image))
    }

    func testRemoteThumbnailQualityRejectsFlatBlackFrame() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())

        XCTAssertFalse(RemoteVideoThumbnailQuality.isUsable(image))
    }

    func testRemoteThumbnailQualityRetriesWhenAtLeast50PercentIsBlack() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0.005, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        let image = try XCTUnwrap(context.makeImage())

        XCTAssertTrue(RemoteVideoThumbnailQuality.isAtLeast50PercentBlack(image))
        XCTAssertFalse(RemoteVideoThumbnailQuality.isUsable(image))
    }

    func testRemoteThumbnailQualityAcceptsFrameBelow50PercentBlack() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 17, height: 32))
        let image = try XCTUnwrap(context.makeImage())

        XCTAssertFalse(RemoteVideoThumbnailQuality.isAtLeast50PercentBlack(image))
        XCTAssertTrue(RemoteVideoThumbnailQuality.isUsable(image))
    }

    func testRemoteThumbnailQualityAcceptsDetailedBrightFrame() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: 4, y: 4, width: 12, height: 12))
        context.fill(CGRect(x: 20, y: 20, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())

        XCTAssertTrue(RemoteVideoThumbnailQuality.isUsable(image))
    }

    func testDownloadProgressClampsFractionToValidRange() {
        XCTAssertEqual(
            RemoteDownloadProgress(
                completedByteCount: 25,
                totalByteCount: 100
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            RemoteDownloadProgress(
                completedByteCount: 125,
                totalByteCount: 100
            ).fractionCompleted,
            1
        )
        XCTAssertNil(
            RemoteDownloadProgress(
                completedByteCount: 10,
                totalByteCount: nil
            ).fractionCompleted
        )
        XCTAssertEqual(
            RemoteDownloadProgress(
                completedByteCount: 0,
                totalByteCount: 0
            ).fractionCompleted,
            1
        )
    }

    func testDownloadIntegrityRejectsEarlyEOF() throws {
        XCTAssertNoThrow(
            try RemoteDownloadIntegrityError.validate(
                expectedByteCount: 1_024,
                actualByteCount: 1_024
            )
        )
        XCTAssertThrowsError(
            try RemoteDownloadIntegrityError.validate(
                expectedByteCount: 1_024,
                actualByteCount: 512
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteDownloadIntegrityError,
                .sizeMismatch(expected: 1_024, actual: 512)
            )
        }
    }

    func testSmallVideoStallBecomesRetryableErrorAndCancelsDownload() async throws {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let item = previewVideoItem(connectionID: service.connection.id)
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .milliseconds(40),
            downloadInactivityPollInterval: .milliseconds(5)
        )

        let loadTask = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForStarts(1)
        try await waitUntil { viewModel.errorMessage != nil }
        await loadTask.value

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.player)
        XCTAssertTrue(viewModel.errorMessage?.contains("다운로드가 진행되지 않았습니다") == true)
        let cancellationCount = await recorder.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTearDownAllowsSameVideoToLoadAgain() async throws {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let item = previewVideoItem(connectionID: service.connection.id)
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .seconds(2),
            downloadInactivityPollInterval: .milliseconds(10)
        )

        let firstLoad = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForStarts(1)
        viewModel.tearDown()
        await firstLoad.value
        XCTAssertFalse(viewModel.isLoading)

        let secondLoad = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForStarts(2)
        viewModel.tearDown()
        await secondLoad.value

        let startCount = await recorder.startCount
        XCTAssertEqual(startCount, 2)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testPeriodicByteProgressKeepsDownloadWatchdogAlive() async throws {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(
            recorder: recorder,
            behavior: .periodicProgress(
                count: 7,
                interval: .milliseconds(100)
            )
        )
        let item = previewVideoItem(connectionID: service.connection.id)
        let viewModel = RemotePreviewViewModel(
            items: [item],
            initialItemID: item.id,
            service: service,
            downloadInactivityTimeout: .milliseconds(500),
            downloadInactivityPollInterval: .milliseconds(20)
        )

        let loadTask = Task { await viewModel.loadCurrentItem() }
        try await recorder.waitForProgressUpdates(7)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isLoading)

        viewModel.tearDown()
        await loadTask.value
    }

    func testMixedMediaNavigationWrapsAndPlaybackOptionsAreSelectable() {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let first = previewVideoItem(connectionID: service.connection.id)
        let second = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/share/photo.jpg",
            name: "photo.jpg",
            kind: .file,
            size: 512,
            modifiedAt: nil,
            contentTypeIdentifier: "public.jpeg"
        )
        let viewModel = RemotePreviewViewModel(
            items: [first, second],
            initialItemID: first.id,
            service: service
        )
        defer {
            viewModel.setPlaybackMode(.repeatAll)
            viewModel.setPhotoAdvanceInterval(.fiveSeconds)
        }

        viewModel.navigate(by: -1)
        XCTAssertEqual(viewModel.currentItem.id, second.id)
        viewModel.navigate(by: 1)
        XCTAssertEqual(viewModel.currentItem.id, first.id)

        viewModel.setPlaybackMode(.shuffle)
        viewModel.setPhotoAdvanceInterval(.tenSeconds)
        XCTAssertEqual(viewModel.playbackMode, .shuffle)
        XCTAssertEqual(viewModel.photoAdvanceInterval, .tenSeconds)
    }

    func testPhotoSlideshowOffersOneSecondAndKeepsDimmedControlsInteractive() {
        XCTAssertEqual(PhotoAdvanceInterval.allCases.first, .oneSecond)
        XCTAssertEqual(PhotoAdvanceInterval.oneSecond.title, "1초")
        XCTAssertEqual(
            RemotePreviewInteractionPolicy.controlsOpacity(
                controlsAreVisible: false,
                isPhoto: true,
                isPlaying: true
            ),
            0.10
        )
        XCTAssertTrue(
            RemotePreviewInteractionPolicy.controlsAcceptInput(
                controlsAreVisible: false,
                isPhoto: true,
                isPlaying: true
            )
        )
        XCTAssertEqual(
            RemotePreviewInteractionPolicy.controlsOpacity(
                controlsAreVisible: false,
                isPhoto: false,
                isPlaying: true
            ),
            0
        )
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(
            RemotePreviewInteractionPolicy.slideshowProgress(
                startedAt: startedAt,
                intervalSeconds: 4,
                now: startedAt.addingTimeInterval(1)
            ),
            0.25
        )
        XCTAssertEqual(
            RemotePreviewInteractionPolicy.slideshowProgress(
                startedAt: startedAt,
                intervalSeconds: 4,
                now: startedAt.addingTimeInterval(10)
            ),
            1
        )
    }

    func testManualNavigationAutoplaysWhileAutomaticNavigationPreservesPause() {
        let recorder = StallingPreviewRecorder()
        let service = StallingPreviewService(recorder: recorder)
        let first = previewVideoItem(connectionID: service.connection.id)
        let second = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/share/second.mov",
            name: "second.mov",
            kind: .file,
            size: 2_048,
            modifiedAt: nil,
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
        let viewModel = RemotePreviewViewModel(
            items: [first, second],
            initialItemID: first.id,
            service: service
        )

        viewModel.togglePlayback()
        XCTAssertFalse(viewModel.isPlaying)

        viewModel.navigate(by: 1)
        XCTAssertEqual(viewModel.currentItem.id, second.id)
        XCTAssertFalse(viewModel.isPlaying)

        viewModel.navigate(by: -1, autoplay: true)
        XCTAssertEqual(viewModel.currentItem.id, first.id)
        XCTAssertTrue(viewModel.isPlaying)
    }

    private func previewVideoItem(connectionID: UUID) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: "/share/clip.mov",
            name: "clip.mov",
            kind: .file,
            size: 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: "com.apple.quicktime-movie"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("미리보기 상태가 제한 시간 안에 변경되지 않았습니다.")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeTinyMOV() async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        do {
            let width = 32
            let height = 32
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ]
            )
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
            )

            guard writer.canAdd(input) else {
                throw TinyMOVTestError.cannotAddVideoInput
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw TinyMOVTestError.writerFailed(
                    writer.error?.localizedDescription ?? "startWriting 실패"
                )
            }
            writer.startSession(atSourceTime: .zero)
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw TinyMOVTestError.missingPixelBufferPool
            }

            for frameIndex in 0..<3 {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                while !input.isReadyForMoreMediaData, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard input.isReadyForMoreMediaData else {
                    throw TinyMOVTestError.writerInputTimedOut
                }

                var optionalPixelBuffer: CVPixelBuffer?
                let result = CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pixelBufferPool,
                    &optionalPixelBuffer
                )
                guard result == kCVReturnSuccess,
                      let pixelBuffer = optionalPixelBuffer else {
                    throw TinyMOVTestError.cannotCreatePixelBuffer(result)
                }

                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    memset(
                        baseAddress,
                        0x7F,
                        CVPixelBufferGetDataSize(pixelBuffer)
                    )
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                let presentationTime = CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                )
                guard adaptor.append(
                    pixelBuffer,
                    withPresentationTime: presentationTime
                ) else {
                    throw TinyMOVTestError.writerFailed(
                        writer.error?.localizedDescription ?? "프레임 추가 실패"
                    )
                }
            }

            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw TinyMOVTestError.writerFailed(
                    writer.error?.localizedDescription ?? "finishWriting 실패"
                )
            }
            return outputURL
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func remoteItem(
        connectionID: UUID,
        path: String
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: .file,
            size: 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }

    func testSuperThumbnailCancelImmediatelyAcknowledgesAndStopsWork() async throws {
        let service = CancellationResistantThumbnailListService()
        let folder = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/share/folder",
            name: "folder",
            kind: .folder,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let preheater = ThumbnailPreheater()

        preheater.start(
            rootItems: [folder],
            rootPath: "/share",
            recursively: true,
            requiresExternalPower: false,
            allowsConstrainedRun: true,
            generationMode: .completeFile,
            service: service
        )
        XCTAssertTrue(preheater.isRunning)
        XCTAssertFalse(preheater.isCancellationRequested)

        let listingDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await service.hasStartedListing),
              ContinuousClock.now < listingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let didStartListing = await service.hasStartedListing
        XCTAssertTrue(didStartListing)

        preheater.cancel()
        XCTAssertTrue(preheater.isCancellationRequested)
        XCTAssertFalse(preheater.isRunning)
        XCTAssertEqual(preheater.statusMessage, "썸네일 미리 생성을 중지했습니다.")

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while preheater.isCancellationRequested, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(preheater.isRunning)
        XCTAssertFalse(preheater.isCancellationRequested)
        XCTAssertEqual(preheater.statusMessage, "썸네일 미리 생성을 중지했습니다.")
        let cancelRequestCount = await service.cancelRequestCount
        XCTAssertEqual(cancelRequestCount, 1)
    }
}

private actor CancellationResistantThumbnailListService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Cancellation test",
        kind: .synology,
        host: "cancel.invalid",
        username: "tester"
    )
    private var blockingTask: Task<Void, Error>?
    private(set) var cancelRequestCount = 0
    private(set) var hasStartedListing = false

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        hasStartedListing = true
        let blockingTask = Task<Void, Error> {
            try await Task.sleep(for: .seconds(30))
        }
        self.blockingTask = blockingTask
        try await blockingTask.value
        return []
    }

    func cancelPendingThumbnailWork() {
        cancelRequestCount += 1
        blockingTask?.cancel()
        blockingTask = nil
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        throw RemoteFileOperationError.unsupported(operation: .copy)
    }
}

private struct ThumbnailRoutingTestService: RemoteFileService {
    let connection: RemoteConnection
    let supportsRangeStreaming = true

    init(kind: ConnectionKind) {
        connection = RemoteConnection(
            name: "Thumbnail routing test",
            kind: kind,
            host: "thumbnail.invalid",
            username: "tester"
        )
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] { [] }
    func download(_ item: RemoteFileItem) async throws -> URL {
        throw RemoteThumbnailError.optimizedPreviewUnavailable
    }
    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data { Data() }
    func testConnection() async throws {}
}

private actor SuccessfulSmallVideoProgressGate {
    private(set) var progressValues: [Int64] = []
    private var didReachMiddleProgress = false
    private var mayFinish = false

    func record(_ byteCount: Int64) {
        progressValues.append(byteCount)
    }

    func pauseAtMiddleProgress() async throws {
        didReachMiddleProgress = true
        while !mayFinish {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilMiddleProgress() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !didReachMiddleProgress {
            guard clock.now < deadline else {
                throw SuccessfulSmallVideoTestError.didNotReachMiddleProgress
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseMiddleProgress() {
        mayFinish = true
    }
}

private struct SuccessfulSmallVideoService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Successful preview test",
        kind: .sftp,
        host: "preview.invalid",
        username: "tester"
    )
    let supportsRangeStreaming = true
    let movieURL: URL
    let gate: SuccessfulSmallVideoProgressGate

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        movieURL
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        let totalByteCount = Int64(
            try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        let middleByteCount = max(totalByteCount / 2, 1)

        for byteCount in [Int64(0), middleByteCount] {
            await progress(
                RemoteDownloadProgress(
                    completedByteCount: byteCount,
                    totalByteCount: totalByteCount
                )
            )
            await gate.record(byteCount)
        }
        try await gate.pauseAtMiddleProgress()
        await progress(
            RemoteDownloadProgress(
                completedByteCount: totalByteCount,
                totalByteCount: totalByteCount
            )
        )
        await gate.record(totalByteCount)
        return movieURL
    }

    func testConnection() async throws {}
}

private struct RangeReadingTinyVideoService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Range thumbnail test",
        kind: .synology,
        host: "thumbnail.invalid",
        username: "tester"
    )
    let supportsRangeStreaming = true
    let movieURL: URL

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        XCTFail("범위 썸네일 생성은 전체 다운로드를 호출하면 안 됩니다.")
        return movieURL
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        let data = try Data(contentsOf: movieURL, options: .mappedIfSafe)
        guard offset >= 0,
              length > 0,
              offset < Int64(data.count) else { return Data() }
        let lowerBound = Int(offset)
        let upperBound = min(lowerBound + length, data.count)
        return data.subdata(in: lowerBound..<upperBound)
    }

    func testConnection() async throws {}
}

private struct StallingRangeVideoService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Stalling range thumbnail test",
        kind: .synology,
        host: "thumbnail.invalid",
        username: "tester"
    )
    let supportsRangeStreaming = true

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        XCTFail("범위 썸네일 생성은 전체 다운로드를 호출하면 안 됩니다.")
        throw CancellationError()
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        try await Task.sleep(for: .seconds(30))
        return Data()
    }

    func testConnection() async throws {}
}

private enum TinyMOVTestError: LocalizedError, Sendable {
    case cannotAddVideoInput
    case missingPixelBufferPool
    case cannotCreatePixelBuffer(CVReturn)
    case writerInputTimedOut
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            "AVAssetWriter에 영상 입력을 추가할 수 없습니다."
        case .missingPixelBufferPool:
            "AVAssetWriter pixel buffer pool을 만들지 못했습니다."
        case let .cannotCreatePixelBuffer(code):
            "테스트 영상 pixel buffer를 만들지 못했습니다. (\(code))"
        case .writerInputTimedOut:
            "AVAssetWriter 입력 준비 시간이 초과됐습니다."
        case let .writerFailed(message):
            "테스트 MOV 생성 실패: \(message)"
        }
    }
}

private enum SuccessfulSmallVideoTestError: Error {
    case didNotReachMiddleProgress
}

private actor StallingPreviewRecorder {
    private(set) var startCount = 0
    private(set) var cancellationCount = 0
    private(set) var progressUpdateCount = 0

    func recordStart() {
        startCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func recordProgressUpdate() {
        progressUpdateCount += 1
    }

    func waitForStarts(_ expectedCount: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while startCount < expectedCount {
            guard clock.now < deadline else {
                throw StallingPreviewTestError.didNotStart
            }
            await Task.yield()
        }
    }


    func waitForProgressUpdates(_ expectedCount: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while progressUpdateCount < expectedCount {
            guard clock.now < deadline else {
                throw StallingPreviewTestError.didNotProgress
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct StallingPreviewService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Preview test",
        kind: .sftp,
        host: "preview.invalid",
        username: "tester"
    )
    let supportsRangeStreaming = false
    let recorder: StallingPreviewRecorder
    var behavior: StallingPreviewBehavior = .noProgress

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await stalledDownload(item) { _ in }
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        try await stalledDownload(item, progress: progress)
    }

    func testConnection() async throws {}

    private func stalledDownload(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        await recorder.recordStart()
        await progress(
            RemoteDownloadProgress(
                completedByteCount: 0,
                totalByteCount: item.size
            )
        )
        do {
            if case let .periodicProgress(count, interval) = behavior {
                for updateIndex in 1...count {
                    try await Task.sleep(for: interval)
                    await progress(
                        RemoteDownloadProgress(
                            completedByteCount: Int64(updateIndex),
                            totalByteCount: item.size
                        )
                    )
                    await recorder.recordProgressUpdate()
                }
            }
            try await Task.sleep(for: .seconds(30))
            return FileManager.default.temporaryDirectory.appending(path: "never-returned.mov")
        } catch {
            await recorder.recordCancellation()
            throw error
        }
    }
}

private enum StallingPreviewBehavior: Sendable {
    case noProgress
    case periodicProgress(count: Int, interval: Duration)
}

private enum StallingPreviewTestError: Error {
    case didNotStart
    case didNotProgress
}

private actor BoundedThumbnailProbe {
    private(set) var maximumByteCount: Int?

    func record(_ value: Int) {
        maximumByteCount = value
    }
}

private struct BoundedThumbnailProbeService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Bounded thumbnail probe",
        kind: .synology,
        host: "probe.invalid",
        username: "tester"
    )
    let probe: BoundedThumbnailProbe

    func list(directory path: String?) async throws -> [RemoteFileItem] { [] }
    func download(_ item: RemoteFileItem) async throws -> URL {
        throw NasFinderError.invalidResponse
    }
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        XCTFail("Unbounded thumbnail API must not be used")
        return nil
    }
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        maximumByteCount: Int
    ) async throws -> Data? {
        await probe.record(maximumByteCount)
        return Data(count: min(maximumByteCount, 64))
    }
    func testConnection() async throws {}
}
