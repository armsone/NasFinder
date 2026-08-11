import Foundation
import Network
import UIKit

enum ThumbnailPreheatPolicy {
    static func canGenerate(
        item: RemoteFileItem,
        connectionKind: ConnectionKind,
        supportsRangeStreaming: Bool
    ) -> Bool {
        guard !item.isDirectory else { return false }
        switch connectionKind {
        case .synology:
            return item.isImage || item.isVideo
        case .sftp:
            return item.isVideo
                && supportsRangeStreaming
                && item.size.map { $0 > 0 } == true
        }
    }

    static func requiresExternalPower(
        rootItems: [RemoteFileItem],
        recursively: Bool
    ) -> Bool {
        recursively || rootItems.count != 1 || rootItems.first?.isDirectory != false
    }
}

final class ThumbnailNetworkMonitor: @unchecked Sendable {
    static let shared = ThumbnailNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.armsone.nasfinder.thumbnail-network")
    private let lock = NSLock()
    private var currentPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.currentPath = path
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isUnmeteredWiFi: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let currentPath else { return false }
        return currentPath.status == .satisfied
            && currentPath.usesInterfaceType(.wifi)
            && !currentPath.isExpensive
    }
}

@MainActor
final class ThumbnailPreheater: ObservableObject {
    static let maximumSynologyDataBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumSFTPDataBytes: Int64 = 18_000_000

    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var generatedCount = 0
    @Published private(set) var cachedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var transferredBytes: Int64 = 0
    @Published private(set) var currentItemName: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var appIsActive = true
    private let screenAwakeActivityID = UUID()

    init() {
        _ = ThumbnailNetworkMonitor.shared
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var fractionCompleted: Double? {
        guard totalCount > 0 else { return nil }
        return min(Double(completedCount) / Double(totalCount), 1)
    }

    func updateAppIsActive(_ isActive: Bool) {
        appIsActive = isActive
        if !isActive, isRunning {
            cancel()
        }
    }

    func start(
        rootItems: [RemoteFileItem],
        rootPath: String,
        recursively: Bool,
        requiresExternalPower powerOverride: Bool? = nil,
        service: any RemoteFileService
    ) {
        guard !isRunning else { return }
        let requiresExternalPower = powerOverride
            ?? ThumbnailPreheatPolicy.requiresExternalPower(
                rootItems: rootItems,
                recursively: recursively
            )
        do {
            try validateRuntimeConditions(requiresExternalPower: requiresExternalPower)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        resetProgress()
        isRunning = true
        ScreenAwakeController.shared.beginActivity(screenAwakeActivityID)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(
                rootItems: rootItems,
                rootPath: rootPath,
                recursively: recursively,
                requiresExternalPower: requiresExternalPower,
                service: service
            )
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismissStatus() {
        statusMessage = nil
    }

    private func run(
        rootItems: [RemoteFileItem],
        rootPath: String,
        recursively: Bool,
        requiresExternalPower: Bool,
        service: any RemoteFileService
    ) async {
        defer {
            ScreenAwakeController.shared.finishActivity(screenAwakeActivityID)
            isRunning = false
            currentItemName = nil
            task = nil
        }

        do {
            let candidates = try await collectCandidates(
                rootItems: rootItems,
                rootPath: rootPath,
                recursively: recursively,
                service: service
            )
            totalCount = candidates.count
            let maximumDataBytes = maximumDataBytes(for: service)

            var reachedDataLimit = false
            var reachedPreviouslyUsedDataLimit = false
            for item in candidates {
                try Task.checkCancellation()
                try validateRuntimeConditions(requiresExternalPower: requiresExternalPower)
                currentItemName = item.name

                let cacheKey = RemoteThumbnailCacheKey.remoteData(for: item, size: .small)
                var hasCachedThumbnail = false
                for candidateKey in RemoteThumbnailCacheKey.allRemoteDataKeys(for: item) {
                    if await RemoteThumbnailDiskCache.shared.containsData(
                        forKey: candidateKey
                    ) {
                        hasCachedThumbnail = true
                        break
                    }
                }
                if hasCachedThumbnail {
                    cachedCount += 1
                    completedCount += 1
                    continue
                }
                let diskCacheGeneration = await RemoteThumbnailDiskCache.shared
                    .currentGeneration()

                let estimatedBytes = estimatedTransferBytes(for: item, service: service)
                if let estimatedBytes,
                   transferredBytes + estimatedBytes > maximumDataBytes {
                    reachedDataLimit = true
                    break
                }

                let activityID = UUID()
                RemoteThumbnailActivityTracker.shared.begin(activityID)
                defer { RemoteThumbnailActivityTracker.shared.finish(activityID) }

                do {
                    if let payload = try await thumbnailData(
                        for: item,
                        service: service
                    ) {
                        _ = try await RemoteThumbnailImageDecoder.downsample(
                            data: payload.data,
                            maximumPixelSize: 192
                        )
                        await RemoteThumbnailDiskCache.shared.store(
                            payload.data,
                            forKey: cacheKey,
                            expectedGeneration: diskCacheGeneration
                        )
                        generatedCount += 1
                        if service.connection.kind == .sftp {
                            let usedBytes = await RemoteVideoThumbnailTrafficBudget
                                .sftpShared.transferredBytes(for: item)
                            transferredBytes = Int64(usedBytes)
                        } else {
                            transferredBytes += Int64(payload.transferredBytes)
                        }
                        if transferredBytes >= maximumDataBytes {
                            reachedDataLimit = true
                        }
                    } else {
                        failedCount += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch RemoteVideoThumbnailGenerationError.trafficBudgetExhausted {
                    reachedDataLimit = true
                    reachedPreviouslyUsedDataLimit = true
                    let trafficBudget = service.connection.kind == .sftp
                        ? RemoteVideoThumbnailTrafficBudget.sftpShared
                        : RemoteVideoThumbnailTrafficBudget.shared
                    let usedBytes = await trafficBudget.transferredBytes(for: item)
                    transferredBytes = max(transferredBytes, Int64(usedBytes))
                } catch {
                    failedCount += 1
                }
                completedCount += 1

                if reachedDataLimit { break }
            }

            let limitText = service.connection.kind == .sftp
                ? "\(maximumDataBytes / 1_000_000) MB"
                : "\(maximumDataBytes / (1_024 * 1_024)) MB"
            let suffix: String
            if reachedPreviouslyUsedDataLimit {
                suffix = " · 이 폴더의 \(limitText) 한도가 이미 소진됨"
            } else if reachedDataLimit {
                suffix = " · \(limitText) 한도에서 중지"
            } else {
                suffix = ""
            }
            let trafficText = ByteCountFormatter.string(
                fromByteCount: transferredBytes,
                countStyle: .file
            )
            statusMessage = "썸네일 \(generatedCount)개 생성, \(cachedCount)개 건너뜀"
                + (failedCount > 0 ? ", \(failedCount)개 실패" : "")
                + " · \(trafficText) 사용"
                + suffix
        } catch is CancellationError {
            statusMessage = "썸네일 미리 생성을 중지했습니다."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func collectCandidates(
        rootItems: [RemoteFileItem],
        rootPath: String,
        recursively: Bool,
        service: any RemoteFileService
    ) async throws -> [RemoteFileItem] {
        var candidates = eligibleItems(in: rootItems, service: service)
        guard recursively else { return candidates }

        var pendingDirectories = rootItems.filter(\.isDirectory)
        var visitedPaths: Set<String> = [rootPath]
        while !pendingDirectories.isEmpty {
            try Task.checkCancellation()
            try validateRuntimeConditions(requiresExternalPower: true)
            let directory = pendingDirectories.removeFirst()
            guard visitedPaths.insert(directory.path).inserted else { continue }
            currentItemName = "\(directory.name) 폴더 검색 중"

            let children = try await service.list(directory: directory.path)
                .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
            candidates.append(contentsOf: eligibleItems(in: children, service: service))
            pendingDirectories.append(contentsOf: children.filter(\.isDirectory))
        }
        return candidates
    }

    private func eligibleItems(
        in items: [RemoteFileItem],
        service: any RemoteFileService
    ) -> [RemoteFileItem] {
        switch service.connection.kind {
        case .synology:
            return items.filter { !$0.isDirectory && ($0.isImage || $0.isVideo) }
        case .sftp:
            // SFTP photos would require their complete originals. Only bounded
            // video range reads are eligible for unattended preheating.
            return items.filter { !$0.isDirectory && $0.isVideo }
        }
    }

    private func thumbnailData(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async throws -> ThumbnailPreheatPayload? {
        do {
            if let data = try await service.thumbnailData(for: item, size: .small),
               !data.isEmpty {
                let transferredBytes = estimatedTransferBytes(
                    for: item,
                    service: service
                ).map(Int.init) ?? data.count
                return ThumbnailPreheatPayload(
                    data: data,
                    transferredBytes: transferredBytes
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard canGenerateBoundedVideoThumbnail(for: item, service: service) else {
                throw error
            }
        }

        guard canGenerateBoundedVideoThumbnail(for: item, service: service) else {
            return nil
        }
        let generated = try await RemoteVideoThumbnailGenerator.generate(
            for: item,
            service: service,
            size: .small
        )
        return ThumbnailPreheatPayload(
            data: generated.data,
            transferredBytes: generated.transferredBytes
        )
    }

    private func canGenerateBoundedVideoThumbnail(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) -> Bool {
        item.isVideo
            && service.connection.kind == .synology
            && service.supportsRangeStreaming
    }

    private func estimatedTransferBytes(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) -> Int64? {
        guard service.connection.kind == .sftp else { return nil }
        let upperBound: Int64 = 320 * 1_024
        guard let size = item.size, size > 0 else { return upperBound }
        return min(size, upperBound)
    }

    private func maximumDataBytes(for service: any RemoteFileService) -> Int64 {
        service.connection.kind == .synology
            ? Self.maximumSynologyDataBytes
            : Self.maximumSFTPDataBytes
    }

    private func validateRuntimeConditions(requiresExternalPower: Bool) throws {
        guard appIsActive else { throw ThumbnailPreheatError.appInactive }
        guard ThumbnailNetworkMonitor.shared.isUnmeteredWiFi else {
            throw ThumbnailPreheatError.wifiRequired
        }
        guard requiresExternalPower else { return }
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return
        case .unknown, .unplugged:
            throw ThumbnailPreheatError.powerRequired
        @unknown default:
            throw ThumbnailPreheatError.powerRequired
        }
    }

    private func resetProgress() {
        completedCount = 0
        totalCount = 0
        generatedCount = 0
        cachedCount = 0
        failedCount = 0
        transferredBytes = 0
        currentItemName = nil
        statusMessage = nil
        errorMessage = nil
    }
}

private struct ThumbnailPreheatPayload {
    let data: Data
    let transferredBytes: Int
}

private enum ThumbnailPreheatError: LocalizedError {
    case wifiRequired
    case powerRequired
    case appInactive

    var errorDescription: String? {
        switch self {
        case .wifiRequired:
            "데이터 사용을 막기 위해 요금이 부과되지 않는 Wi‑Fi에 연결해 주세요."
        case .powerRequired:
            "충전기를 연결한 상태에서 썸네일 미리 생성을 시작해 주세요."
        case .appInactive:
            "NasFinder가 화면에 열려 있을 때만 썸네일을 미리 만들 수 있습니다."
        }
    }
}
