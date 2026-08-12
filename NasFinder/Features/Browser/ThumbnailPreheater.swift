import Foundation
import Network
import UIKit

extension Notification.Name {
    static let thumbnailNetworkPathDidChange = Notification.Name(
        "thumbnailNetworkPathDidChange"
    )
}

enum ThumbnailPreheatPolicy {
    static func allowsConstrainedNetwork(
        for generationMode: RemoteVideoThumbnailGenerationMode
    ) -> Bool {
        generationMode == .bounded
    }

    static func canGenerate(
        item: RemoteFileItem,
        connectionKind: ConnectionKind,
        supportsRangeStreaming: Bool
    ) -> Bool {
        guard !item.isDirectory else { return false }
        switch connectionKind {
        case .synology:
            return item.isImage || item.isVideo
        case .sftp, .smb, .webDAV, .ftp:
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

private struct SuperThumbnailWorkItem {
    let item: RemoteFileItem
    let attempt: Int
}

final class ThumbnailNetworkMonitor: @unchecked Sendable {
    static let shared = ThumbnailNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.armsone.nasfinder.thumbnail-network")
    private let lock = NSLock()
    private var currentPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            let wasUnmeteredWiFi = self.currentPath.map(Self.isUnmeteredWiFi)
            self.currentPath = path
            let isUnmeteredWiFi = Self.isUnmeteredWiFi(path)
            self.lock.unlock()
            if isUnmeteredWiFi, wasUnmeteredWiFi == false {
                Task {
                    await RemoteVideoThumbnailTrafficBudget.cellularShared.reset()
                }
            }
            NotificationCenter.default.post(
                name: .thumbnailNetworkPathDidChange,
                object: nil
            )
        }
        monitor.start(queue: queue)
    }

    var isUnmeteredWiFi: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let currentPath else { return false }
        return Self.isUnmeteredWiFi(currentPath)
    }

    private static func isUnmeteredWiFi(_ path: NWPath) -> Bool {
        path.status == .satisfied
            && path.usesInterfaceType(.wifi)
            && !path.isExpensive
    }
}

@MainActor
final class ThumbnailPreheater: ObservableObject {
    static let maximumSynologyDataBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumCellularDataBytes: Int64 = 24 * 1_024 * 1_024
    static let maximumCompleteFileDataBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    static let maximumSFTPDataBytes: Int64 = 18_000_000

    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var generatedCount = 0
    @Published private(set) var cachedCount = 0
    @Published private(set) var vaultRestoredCount = 0
    @Published private(set) var vaultStoredCount = 0
    @Published private(set) var vaultErrorMessage: String?
    @Published private(set) var failedCount = 0
    @Published private(set) var failedItemNames: [String] = []
    @Published private(set) var failedItems: [SuperThumbnailFailureRecord] = []
    @Published private(set) var successAttemptCounts = [0, 0, 0]
    @Published private(set) var transferredBytes: Int64 = 0
    @Published private(set) var currentItemTransferredBytes: Int64 = 0
    @Published private(set) var currentItemTotalBytes: Int64 = 0
    @Published private(set) var currentItemName: String?
    @Published private(set) var currentItemStartedAt: Date?
    @Published private(set) var currentItemAttempt = 0
    @Published private(set) var currentItemTimeLimit: TimeInterval = 5
    @Published private(set) var queuedFastCount = 0
    @Published private(set) var queuedRetryCount = 0
    @Published private(set) var queuedRecoveryCount = 0
    @Published private(set) var estimatedTimeRemaining: TimeInterval?
    @Published private(set) var pauseReason: String?
    @Published private(set) var recentGeneratedThumbnails: [GeneratedThumbnailPreview] = []
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var appIsActive = true
    private var etaEstimator = ThumbnailETAEstimator()
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
    }

    func start(
        rootItems: [RemoteFileItem],
        rootPath: String,
        recursively: Bool,
        requiresExternalPower powerOverride: Bool? = nil,
        allowsConstrainedRun: Bool = false,
        generationMode: RemoteVideoThumbnailGenerationMode = .bounded,
        vaultOptions: SuperThumbnailVaultOptions = .init(
            isEnabled: false,
            timing: .later
        ),
        service: any RemoteFileService
    ) {
        guard !isRunning else { return }
        let requiresExternalPower = powerOverride
            ?? ThumbnailPreheatPolicy.requiresExternalPower(
                rootItems: rootItems,
                recursively: recursively
            )
        do {
            try validateRuntimeConditions(
                requiresExternalPower: requiresExternalPower,
                allowsConstrainedRun: allowsConstrainedRun
            )
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
                allowsConstrainedRun: allowsConstrainedRun,
                generationMode: generationMode,
                vaultOptions: vaultOptions,
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
        allowsConstrainedRun: Bool,
        generationMode: RemoteVideoThumbnailGenerationMode,
        vaultOptions: SuperThumbnailVaultOptions,
        service: any RemoteFileService
    ) async {
        defer {
            ScreenAwakeController.shared.finishActivity(screenAwakeActivityID)
            isRunning = false
            currentItemName = nil
            currentItemTransferredBytes = 0
            currentItemTotalBytes = 0
            currentItemStartedAt = nil
            pauseReason = nil
            task = nil
        }

        do {
            let collectedCandidates = try await collectCandidates(
                rootItems: rootItems,
                rootPath: rootPath,
                recursively: recursively,
                allowsConstrainedRun: allowsConstrainedRun,
                service: service
            )
            let candidates = generationMode == .completeFile
                ? collectedCandidates.filter(\.isVideo)
                : collectedCandidates
            let vaultRun = SuperThumbnailVaultRun(
                options: generationMode == .completeFile
                    ? vaultOptions
                    : .init(isEnabled: false, timing: .later),
                items: candidates,
                service: service
            )
            totalCount = candidates.count
            estimatedTimeRemaining = etaEstimator.totalEstimate(
                for: candidates,
                processingPath: { item in
                    predictedProcessingPath(
                        for: item,
                        service: service,
                        generationMode: generationMode
                    )
                }
            )
            let maximumDataBytes = maximumDataBytes(
                for: service,
                generationMode: generationMode,
                allowsConstrainedRun: allowsConstrainedRun
            )
            var appliedMaximumDataBytes = maximumDataBytes

            let queueSessionKey = "\(service.connection.id.uuidString)|\(rootPath)"
            let savedAttempts = generationMode == .completeFile
                ? await SuperThumbnailQueueStore.shared.attempts(
                    for: candidates,
                    sessionKey: queueSessionKey
                )
                : [:]
            if generationMode == .completeFile,
               let savedReport = await SuperThumbnailQueueStore.shared.report(
                   sessionKey: queueSessionKey
               ) {
                successAttemptCounts = normalizedSuccessCounts(
                    savedReport.successCounts
                )
                failedItems = savedReport.failures
                failedItemNames = savedReport.failures.map {
                    "\($0.name) · \($0.reason)"
                }
                failedCount = failedItems.count
            }
            var pendingCandidates: [RemoteFileItem] = []
            if generationMode == .completeFile {
                for item in candidates {
                    var cachedData = await cachedThumbnailData(for: item)
                    if cachedData == nil,
                       let restored = await vaultRun.restoredData(for: item),
                       UIImage(data: restored) != nil {
                        cachedData = restored
                        vaultRestoredCount += 1
                        await SuperThumbnailCache.shared.store(
                            restored,
                            forKey: RemoteThumbnailCacheKey.remoteData(
                                for: item,
                                size: .small
                            )
                        )
                    }
                    if let cachedData {
                        cachedCount += 1
                        completedCount += 1
                        appendRecentThumbnail(name: item.name, data: cachedData)
                        let transition = await SuperThumbnailQueueStore.shared.markCached(
                            item,
                            sessionKey: queueSessionKey
                        )
                        if let previousAttempt = transition.previousSuccessAttempt,
                           successAttemptCounts.indices.contains(previousAttempt) {
                            successAttemptCounts[previousAttempt] = max(
                                successAttemptCounts[previousAttempt] - 1,
                                0
                            )
                        }
                        if transition.removedFailure {
                            failedItems.removeAll { $0.itemID == item.id }
                            failedItemNames = failedItems.map {
                                "\($0.name) · \($0.reason)"
                            }
                            failedCount = failedItems.count
                        }
                        applyVaultResult(await vaultRun.markCompleted(
                            item,
                            localData: Self.localSuperThumbnailData
                        ))
                    } else {
                        pendingCandidates.append(item)
                    }
                }
            } else {
                pendingCandidates = candidates
            }
            var workQueue: [SuperThumbnailWorkItem] = (0...2).flatMap {
                attempt -> [SuperThumbnailWorkItem] in
                pendingCandidates.compactMap {
                    item -> SuperThumbnailWorkItem? in
                    let savedAttempt = savedAttempts[item.id] ?? 0
                    guard savedAttempt == attempt else { return nil }
                    return SuperThumbnailWorkItem(item: item, attempt: attempt)
                }
            }
            var workIndex = 0
            updateQueueCounts(workQueue, from: workIndex)
            var reachedDataLimit = false
            var reachedPreviouslyUsedDataLimit = false
            while workIndex < workQueue.count {
                let work = workQueue[workIndex]
                workIndex += 1
                let item = work.item
                try Task.checkCancellation()
                let usesCellularBudget = allowsConstrainedRun
                    && generationMode == .bounded
                    && !ThumbnailNetworkMonitor.shared.isUnmeteredWiFi
                let itemMaximumDataBytes = usesCellularBudget
                    ? Self.maximumCellularDataBytes
                    : maximumDataBytes
                appliedMaximumDataBytes = min(
                    appliedMaximumDataBytes,
                    itemMaximumDataBytes
                )
                if usesCellularBudget,
                   !(await RemoteVideoThumbnailTrafficBudget.cellularShared
                    .hasCapacity()) {
                    reachedDataLimit = true
                    reachedPreviouslyUsedDataLimit = true
                    break
                }
                try await waitForRuntimeConditions(
                    requiresExternalPower: requiresExternalPower,
                    allowsConstrainedRun: allowsConstrainedRun
                )
                currentItemName = item.name
                currentItemTransferredBytes = 0
                currentItemTotalBytes = 0
                currentItemStartedAt = nil
                currentItemAttempt = work.attempt
                currentItemTimeLimit = superThumbnailTimeLimit(
                    for: work.attempt,
                    generationMode: generationMode
                )

                let cacheKey = RemoteThumbnailCacheKey.remoteData(for: item, size: .small)
                var cachedThumbnailData: Data?
                for candidateKey in RemoteThumbnailCacheKey.allRemoteDataKeys(for: item) {
                    var data = await SuperThumbnailCache.shared.data(
                        forKey: candidateKey
                    )
                    if data == nil {
                        data = await RemoteThumbnailDiskCache.shared.data(
                            forKey: candidateKey
                        )
                    }
                    if let data, UIImage(data: data) != nil {
                        cachedThumbnailData = data
                        break
                    }
                }
                if let cachedThumbnailData {
                    cachedCount += 1
                    completedCount += 1
                    if generationMode == .completeFile {
                        appendRecentThumbnail(
                            name: item.name,
                            data: cachedThumbnailData
                        )
                        applyVaultResult(await vaultRun.markCompleted(
                            item,
                            localData: Self.localSuperThumbnailData
                        ))
                    }
                    estimatedTimeRemaining = etaEstimator.totalEstimate(
                        for: workQueue.dropFirst(workIndex).map { $0.item },
                        processingPath: { remainingItem in
                            predictedProcessingPath(
                                for: remainingItem,
                                service: service,
                                generationMode: generationMode
                            )
                        }
                    )
                    continue
                }
                let diskCacheGeneration = generationMode == .completeFile
                    ? await SuperThumbnailCache.shared.currentGeneration()
                    : await RemoteThumbnailDiskCache.shared.currentGeneration()

                currentItemStartedAt = Date()
                if generationMode == .completeFile {
                    currentItemTotalBytes = Int64(
                        superThumbnailMaximumBytes(for: work.attempt)
                    )
                }

                let estimatedBytes = estimatedTransferBytes(for: item, service: service)
                if let estimatedBytes,
                   transferredBytes + estimatedBytes > itemMaximumDataBytes {
                    reachedDataLimit = true
                    break
                }

                let activityID = UUID()
                RemoteThumbnailActivityTracker.shared.begin(activityID)
                defer { RemoteThumbnailActivityTracker.shared.finish(activityID) }
                let processingStartedAt = Date()
                var observedDuration: TimeInterval?
                var observedPath = predictedProcessingPath(
                    for: item,
                    service: service,
                    generationMode: generationMode
                )
                var deferredForLater = false

                do {
                    if let payload = try await thumbnailData(
                        for: item,
                        service: service,
                        generationMode: generationMode,
                        attempt: work.attempt,
                        usesCellularBudget: usesCellularBudget
                    ) {
                        observedDuration = payload.mediaDurationSeconds
                        observedPath = payload.processingPath
                        _ = try await RemoteThumbnailImageDecoder.downsample(
                            data: payload.data,
                            maximumPixelSize: 192
                        )
                        if generationMode == .completeFile {
                            await SuperThumbnailCache.shared.store(
                                payload.data,
                                forKey: cacheKey,
                                expectedGeneration: diskCacheGeneration
                            )
                            await SuperThumbnailCache.shared.addNetworkUsage(
                                Int64(payload.transferredBytes)
                            )
                        } else {
                            await RemoteThumbnailDiskCache.shared.store(
                                payload.data,
                                forKey: cacheKey,
                                expectedGeneration: diskCacheGeneration
                            )
                        }
                        generatedCount += 1
                        if generationMode == .completeFile {
                            successAttemptCounts[work.attempt] += 1
                            failedItems.removeAll { $0.itemID == item.id }
                            failedItemNames = failedItems.map {
                                "\($0.name) · \($0.reason)"
                            }
                            failedCount = failedItems.count
                            await SuperThumbnailQueueStore.shared.recordSuccess(
                                item,
                                sessionKey: queueSessionKey,
                                attempt: work.attempt
                            )
                        }
                        if generationMode == .completeFile {
                            appendRecentThumbnail(
                                name: item.name,
                                data: payload.data
                            )
                        }
                        if service.connection.kind == .sftp {
                            let usedBytes = await RemoteVideoThumbnailTrafficBudget
                                .sftpShared.transferredBytes(for: item)
                            transferredBytes = Int64(usedBytes)
                        } else {
                            transferredBytes += Int64(payload.transferredBytes)
                        }
                        if transferredBytes >= itemMaximumDataBytes {
                            reachedDataLimit = true
                        }
                    } else {
                        throw RemoteVideoThumbnailGenerationError
                            .imageGenerationFailed
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch RemoteVideoThumbnailGenerationError.trafficBudgetExhausted {
                    reachedDataLimit = true
                    reachedPreviouslyUsedDataLimit = true
                    let trafficBudget = generationMode == .completeFile
                        ? RemoteVideoThumbnailTrafficBudget.completeFileShared
                        : service.connection.kind == .sftp
                            ? RemoteVideoThumbnailTrafficBudget.sftpShared
                            : RemoteVideoThumbnailTrafficBudget.shared
                    let usedBytes = await trafficBudget.transferredBytes(for: item)
                    transferredBytes = max(transferredBytes, Int64(usedBytes))
                } catch {
                    if generationMode == .completeFile,
                       work.attempt < 2 {
                        enqueueForNextPass(
                            SuperThumbnailWorkItem(
                                item: item,
                                attempt: work.attempt + 1
                            ),
                            in: &workQueue,
                            after: workIndex
                        )
                        await SuperThumbnailQueueStore.shared.deferItem(
                            item,
                            sessionKey: queueSessionKey,
                            nextAttempt: work.attempt + 1
                        )
                        deferredForLater = true
                    } else {
                        let failure = failureRecord(
                            for: item,
                            durationSeconds: observedDuration,
                            reason: error.localizedDescription
                        )
                        failedItems.removeAll { $0.itemID == item.id }
                        failedItems.append(failure)
                        failedItems.sort {
                            $0.name.localizedStandardCompare($1.name)
                                == .orderedAscending
                        }
                        failedItemNames = failedItems.map {
                            "\($0.name) · \($0.reason)"
                        }
                        failedCount = failedItems.count
                        if generationMode == .completeFile {
                            await SuperThumbnailQueueStore.shared.recordFailure(
                                item,
                                sessionKey: queueSessionKey,
                                durationSeconds: observedDuration,
                                reason: error.localizedDescription
                            )
                        }
                    }
                    if generationMode == .completeFile {
                        let attemptBytes = currentItemTransferredBytes
                        transferredBytes += attemptBytes
                        await SuperThumbnailCache.shared.addNetworkUsage(
                            attemptBytes
                        )
                    }
                }
                if deferredForLater {
                    updateQueueCounts(workQueue, from: workIndex)
                    currentItemTransferredBytes = 0
                    currentItemTotalBytes = 0
                    currentItemStartedAt = nil
                    estimatedTimeRemaining = etaEstimator.totalEstimate(
                        for: workQueue.dropFirst(workIndex).map { $0.item },
                        processingPath: { remainingItem in
                            predictedProcessingPath(
                                for: remainingItem,
                                service: service,
                                generationMode: generationMode
                            )
                        }
                    )
                    continue
                }
                updateEstimatedTime(
                    item: item,
                    processingDuration: Date().timeIntervalSince(processingStartedAt),
                    mediaDurationSeconds: observedDuration,
                    processingPath: observedPath,
                    remainingItems: workQueue.dropFirst(workIndex).map { $0.item },
                    service: service,
                    generationMode: generationMode
                )
                completedCount += 1
                if generationMode == .completeFile {
                    applyVaultResult(await vaultRun.markCompleted(
                        item,
                        localData: Self.localSuperThumbnailData
                    ))
                }
                currentItemTransferredBytes = 0
                currentItemTotalBytes = 0
                currentItemStartedAt = nil
                updateQueueCounts(workQueue, from: workIndex)

                if reachedDataLimit { break }
            }

            if generationMode == .completeFile {
                applyVaultResult(await vaultRun.finish(
                    localData: Self.localSuperThumbnailData
                ))
            }

            let limitText = service.connection.kind == .sftp
                && appliedMaximumDataBytes == Self.maximumSFTPDataBytes
                ? "\(appliedMaximumDataBytes / 1_000_000) MB"
                : "\(appliedMaximumDataBytes / (1_024 * 1_024)) MB"
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
        allowsConstrainedRun: Bool,
        service: any RemoteFileService
    ) async throws -> [RemoteFileItem] {
        var candidates = eligibleItems(in: rootItems, service: service)
        guard recursively else { return candidates }

        var pendingDirectories = rootItems.filter(\.isDirectory)
        var visitedPaths: Set<String> = [rootPath]
        while !pendingDirectories.isEmpty {
            try Task.checkCancellation()
            try await waitForRuntimeConditions(
                requiresExternalPower: true,
                allowsConstrainedRun: allowsConstrainedRun
            )
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
        case .sftp, .smb, .webDAV, .ftp:
            // Generic network photos would require their complete originals. Only bounded
            // video range reads are eligible for unattended preheating.
            return items.filter { !$0.isDirectory && $0.isVideo }
        }
    }

    private func thumbnailData(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        generationMode: RemoteVideoThumbnailGenerationMode,
        attempt: Int = 0,
        usesCellularBudget: Bool = false
    ) async throws -> ThumbnailPreheatPayload? {
        if generationMode != .completeFile,
           !RemoteVideoThumbnailRoutingPolicy.bypassesBackendThumbnail(
               for: item,
               service: service
           ) {
            do {
                let data = try await backendThumbnailData(
                    for: item,
                    service: service,
                    size: .small,
                    usesCellularBudget: usesCellularBudget
                )
                if let data,
                   !data.isEmpty {
                    do {
                        _ = try await RemoteThumbnailImageDecoder.downsample(
                            data: data,
                            maximumPixelSize: 192
                        )
                        let transferredBytes = estimatedTransferBytes(
                            for: item,
                            service: service
                        ).map(Int.init) ?? data.count
                        return ThumbnailPreheatPayload(
                            data: data,
                            transferredBytes: transferredBytes,
                            mediaDurationSeconds: nil,
                            processingPath: .backend
                        )
                    } catch {
                        guard canGenerateBoundedVideoThumbnail(
                            for: item,
                            service: service
                        ) else {
                            throw error
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard canGenerateBoundedVideoThumbnail(for: item, service: service) else {
                    throw error
                }
            }
        }

        guard canGenerateBoundedVideoThumbnail(for: item, service: service) else {
            return nil
        }
        let generated = try await RemoteVideoThumbnailGenerator.generate(
            for: item,
            service: service,
            size: .small,
            trafficBudget: generationMode == .completeFile
                ? superThumbnailTrafficBudget(for: attempt)
                : usesCellularBudget
                    ? RemoteVideoThumbnailTrafficBudget.cellularShared
                : RemoteVideoThumbnailRoutingPolicy.trafficBudget(for: service),
            mode: generationMode,
            timeout: generationMode == .completeFile
                ? .seconds(superThumbnailTimeLimit(for: attempt))
                : RemoteVideoThumbnailGenerator.defaultGenerationTimeout,
            progress: { [weak self] transferred, total in
                Task { @MainActor [weak self] in
                    self?.currentItemTransferredBytes = transferred
                    self?.currentItemTotalBytes = total
                }
            }
        )
        return ThumbnailPreheatPayload(
            data: generated.data,
            transferredBytes: generated.transferredBytes,
            mediaDurationSeconds: generated.mediaDurationSeconds,
            processingPath: generated.processingPath
        )
    }

    private func backendThumbnailData(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        usesCellularBudget: Bool
    ) async throws -> Data? {
        guard usesCellularBudget else {
            return try await service.thumbnailData(for: item, size: size)
        }
        let budget = RemoteVideoThumbnailTrafficBudget.cellularShared
        guard let lease = await budget.lease(for: item) else {
            throw RemoteVideoThumbnailGenerationError.trafficBudgetExhausted
        }
        do {
            let data = try await service.thumbnailData(
                for: item,
                size: size,
                maximumByteCount: lease.maximumBytes
            )
            await budget.finish(
                lease,
                transferredBytes: data == nil
                    ? lease.maximumBytes
                    : min(data?.count ?? 0, lease.maximumBytes)
            )
            return data
        } catch {
            // A streamed response may consume bytes before it fails. Charging
            // the reservation prevents repeated failures bypassing the cap.
            await budget.finish(
                lease,
                transferredBytes: lease.maximumBytes
            )
            throw error
        }
    }

    private func cachedThumbnailData(for item: RemoteFileItem) async -> Data? {
        for key in RemoteThumbnailCacheKey.allRemoteDataKeys(for: item) {
            var data = await SuperThumbnailCache.shared.data(forKey: key)
            if data == nil {
                data = await RemoteThumbnailDiskCache.shared.data(forKey: key)
            }
            if let data, UIImage(data: data) != nil { return data }
        }
        return nil
    }

    private static let localSuperThumbnailData:
        @Sendable (RemoteFileItem) async -> Data? = { item in
            for key in RemoteThumbnailCacheKey.allRemoteDataKeys(for: item) {
                if let data = await SuperThumbnailCache.shared.data(forKey: key),
                   UIImage(data: data) != nil {
                    return data
                }
            }
            return nil
        }

    private func applyVaultResult(_ result: SuperThumbnailVaultStoreResult) {
        vaultStoredCount += result.storedCount
        if let errorDescription = result.errorDescription {
            vaultErrorMessage = errorDescription
        }
    }

    private func normalizedSuccessCounts(_ counts: [Int]) -> [Int] {
        (0..<3).map { index in
            counts.indices.contains(index) ? max(counts[index], 0) : 0
        }
    }

    private func failureRecord(
        for item: RemoteFileItem,
        durationSeconds: TimeInterval?,
        reason: String
    ) -> SuperThumbnailFailureRecord {
        SuperThumbnailFailureRecord(
            itemID: item.id,
            name: item.name,
            fileExtension: (item.name as NSString).pathExtension.uppercased(),
            fileSize: item.size,
            durationSeconds: durationSeconds,
            reason: reason
        )
    }

    private func updateQueueCounts(
        _ queue: [SuperThumbnailWorkItem],
        from index: Int
    ) {
        let pending = queue.dropFirst(index)
        queuedFastCount = pending.lazy.filter { $0.attempt == 0 }.count
        queuedRetryCount = pending.lazy.filter { $0.attempt == 1 }.count
        queuedRecoveryCount = pending.lazy.filter { $0.attempt == 2 }.count
    }

    private func enqueueForNextPass(
        _ work: SuperThumbnailWorkItem,
        in queue: inout [SuperThumbnailWorkItem],
        after currentIndex: Int
    ) {
        let remainingRange = min(currentIndex, queue.endIndex)..<queue.endIndex
        let insertionIndex = remainingRange.first(where: {
            queue[$0].attempt > work.attempt
        }) ?? queue.endIndex
        queue.insert(work, at: insertionIndex)
    }

    private func superThumbnailTimeLimit(
        for attempt: Int,
        generationMode: RemoteVideoThumbnailGenerationMode = .completeFile
    ) -> TimeInterval {
        guard generationMode == .completeFile else {
            return 20
        }
        switch attempt {
        case 0: return 5
        case 1: return 20
        default: return 40
        }
    }

    private func superThumbnailMaximumBytes(for attempt: Int) -> Int {
        switch attempt {
        case 0: return 24 * 1_024 * 1_024
        case 1: return 40 * 1_024 * 1_024
        default: return 64 * 1_024 * 1_024
        }
    }

    private func superThumbnailTrafficBudget(
        for attempt: Int
    ) -> RemoteVideoThumbnailTrafficBudget {
        switch attempt {
        case 0: return .completeFileFastPass
        case 1: return .completeFileRetryPass
        default: return .completeFileRecoveryPass
        }
    }

    private func predictedProcessingPath(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        generationMode: RemoteVideoThumbnailGenerationMode
    ) -> RemoteVideoThumbnailProcessingPath {
        let fallback: RemoteVideoThumbnailProcessingPath
        if generationMode == .completeFile {
            fallback = .compatibilityRange
        } else if RemoteVideoThumbnailRoutingPolicy.bypassesBackendThumbnail(
            for: item,
            service: service
        ) {
            fallback = CompatibilityVideoFormatPolicy.prefersCompatibilityPlayer(for: item)
                ? .compatibilityRange
                : .avFoundationRange
        } else {
            fallback = .backend
        }
        return etaEstimator.preferredProcessingPath(for: item, fallback: fallback)
    }

    private func canGenerateBoundedVideoThumbnail(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) -> Bool {
        RemoteVideoThumbnailRoutingPolicy.canGenerateBoundedThumbnail(
            for: item,
            service: service
        )
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

    private func maximumDataBytes(
        for service: any RemoteFileService,
        generationMode: RemoteVideoThumbnailGenerationMode,
        allowsConstrainedRun: Bool
    ) -> Int64 {
        if generationMode == .completeFile {
            return Self.maximumCompleteFileDataBytes
        }
        if allowsConstrainedRun,
           !ThumbnailNetworkMonitor.shared.isUnmeteredWiFi {
            return Self.maximumCellularDataBytes
        }
        return service.connection.kind == .synology
            ? Self.maximumSynologyDataBytes
            : Self.maximumSFTPDataBytes
    }

    private func validateRuntimeConditions(
        requiresExternalPower: Bool,
        allowsConstrainedRun: Bool
    ) throws {
        guard appIsActive else { throw ThumbnailPreheatError.appInactive }
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel >= 0, batteryLevel <= 0.2 {
            throw ThumbnailPreheatError.lowBattery
        }
        if allowsConstrainedRun { return }
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

    private func waitForRuntimeConditions(
        requiresExternalPower: Bool,
        allowsConstrainedRun: Bool
    ) async throws {
        while true {
            try Task.checkCancellation()
            if !appIsActive {
                pauseReason = "앱 화면으로 돌아오면 계속합니다"
                try await Task.sleep(for: .seconds(1))
                continue
            }
            let batteryLevel = UIDevice.current.batteryLevel
            if batteryLevel >= 0, batteryLevel <= 0.2 {
                throw ThumbnailPreheatError.lowBattery
            }
            if allowsConstrainedRun {
                pauseReason = nil
                return
            }

            let hasWiFi = ThumbnailNetworkMonitor.shared.isUnmeteredWiFi
            let hasPower: Bool
            if requiresExternalPower {
                switch UIDevice.current.batteryState {
                case .charging, .full:
                    hasPower = true
                case .unknown, .unplugged:
                    hasPower = false
                @unknown default:
                    hasPower = false
                }
            } else {
                hasPower = true
            }
            if hasWiFi, hasPower {
                pauseReason = nil
                return
            }
            if !hasWiFi, !hasPower {
                pauseReason = "Wi‑Fi와 충전 연결을 기다리는 중"
            } else if !hasWiFi {
                pauseReason = "Wi‑Fi 연결을 기다리는 중"
            } else {
                pauseReason = "충전 연결을 기다리는 중"
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func resetProgress() {
        completedCount = 0
        totalCount = 0
        generatedCount = 0
        cachedCount = 0
        vaultRestoredCount = 0
        vaultStoredCount = 0
        vaultErrorMessage = nil
        failedCount = 0
        failedItemNames = []
        failedItems = []
        successAttemptCounts = [0, 0, 0]
        transferredBytes = 0
        currentItemTransferredBytes = 0
        currentItemTotalBytes = 0
        currentItemName = nil
        currentItemStartedAt = nil
        currentItemAttempt = 0
        currentItemTimeLimit = 5
        queuedFastCount = 0
        queuedRetryCount = 0
        queuedRecoveryCount = 0
        pauseReason = nil
        estimatedTimeRemaining = nil
        recentGeneratedThumbnails = []
        statusMessage = nil
        errorMessage = nil
    }

    private func updateEstimatedTime(
        item: RemoteFileItem,
        processingDuration: TimeInterval,
        mediaDurationSeconds: TimeInterval?,
        processingPath: RemoteVideoThumbnailProcessingPath,
        remainingItems: [RemoteFileItem],
        service: any RemoteFileService,
        generationMode: RemoteVideoThumbnailGenerationMode
    ) {
        guard processingDuration > 0 else { return }
        etaEstimator.record(
            item: item,
            mediaDurationSeconds: mediaDurationSeconds,
            processingPath: processingPath,
            elapsedSeconds: processingDuration
        )
        guard !remainingItems.isEmpty else {
            estimatedTimeRemaining = 0
            return
        }
        let target = etaEstimator.totalEstimate(
            for: remainingItems,
            processingPath: { remainingItem in
                predictedProcessingPath(
                    for: remainingItem,
                    service: service,
                    generationMode: generationMode
                )
            }
        )

        guard let previous = estimatedTimeRemaining else {
            estimatedTimeRemaining = target
            return
        }
        let elapsedBaseline = max(previous - processingDuration, 0)
        let blended = elapsedBaseline * 0.72 + target * 0.28
        let maximumRise = max(10, elapsedBaseline * 0.08)
        let maximumDrop = max(15, elapsedBaseline * 0.18)
        estimatedTimeRemaining = min(
            max(blended, max(elapsedBaseline - maximumDrop, 0)),
            elapsedBaseline + maximumRise
        )
    }

    private func appendRecentThumbnail(name: String, data: Data) {
        recentGeneratedThumbnails.append(
            GeneratedThumbnailPreview(name: name, data: data)
        )
        if recentGeneratedThumbnails.count > 20 {
            recentGeneratedThumbnails.removeFirst(
                recentGeneratedThumbnails.count - 20
            )
        }
    }
}

struct GeneratedThumbnailPreview: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
}

private struct ThumbnailETAEstimator {
    private struct Observation: Codable {
        let itemKey: String
        let fileExtension: String
        let sizeBytes: Int64?
        let mediaDurationSeconds: TimeInterval?
        let processingPath: RemoteVideoThumbnailProcessingPath
        let elapsedSeconds: TimeInterval
        let recordedAt: Date
    }

    private static let storageKey = "thumbnailETA.observations.v2"
    private static let maximumObservationCount = 160
    private var observations: [Observation]

    init(userDefaults: UserDefaults = .standard) {
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Observation].self, from: data) {
            observations = decoded.filter {
                $0.elapsedSeconds.isFinite && $0.elapsedSeconds > 0
            }
        } else {
            observations = []
        }
    }

    mutating func record(
        item: RemoteFileItem,
        mediaDurationSeconds: TimeInterval?,
        processingPath: RemoteVideoThumbnailProcessingPath,
        elapsedSeconds: TimeInterval,
        userDefaults: UserDefaults = .standard
    ) {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return }
        let key = itemKey(for: item)
        observations.removeAll {
            $0.itemKey == key && $0.processingPath == processingPath
        }
        observations.append(
            Observation(
                itemKey: key,
                fileExtension: fileExtension(for: item),
                sizeBytes: item.size,
                mediaDurationSeconds: validDuration(mediaDurationSeconds),
                processingPath: processingPath,
                elapsedSeconds: elapsedSeconds,
                recordedAt: Date()
            )
        )
        if observations.count > Self.maximumObservationCount {
            observations.removeFirst(
                observations.count - Self.maximumObservationCount
            )
        }
        if let data = try? JSONEncoder().encode(observations) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    func totalEstimate(
        for items: [RemoteFileItem],
        processingPath: (RemoteFileItem) -> RemoteVideoThumbnailProcessingPath
    ) -> TimeInterval {
        items.reduce(0) { total, item in
            total + estimate(for: item, processingPath: processingPath(item))
        }
    }

    func preferredProcessingPath(
        for item: RemoteFileItem,
        fallback: RemoteVideoThumbnailProcessingPath
    ) -> RemoteVideoThumbnailProcessingPath {
        let key = itemKey(for: item)
        if let exact = observations.last(where: { $0.itemKey == key }) {
            return exact.processingPath
        }
        let extensionName = fileExtension(for: item)
        return observations.last(where: { $0.fileExtension == extensionName })?
            .processingPath ?? fallback
    }

    private func estimate(
        for item: RemoteFileItem,
        processingPath: RemoteVideoThumbnailProcessingPath
    ) -> TimeInterval {
        let extensionName = fileExtension(for: item)
        let exactDuration = observations
            .last(where: { $0.itemKey == itemKey(for: item) })?
            .mediaDurationSeconds
        let extensionDurations = observations.compactMap { observation in
            observation.fileExtension == extensionName
                ? observation.mediaDurationSeconds
                : nil
        }.sorted()
        let typicalDuration = extensionDurations.isEmpty
            ? nil
            : extensionDurations[extensionDurations.count / 2]
        let knownDuration = exactDuration ?? typicalDuration
        let exact = observations.filter {
            $0.processingPath == processingPath
                && $0.fileExtension == extensionName
        }
        let candidates = exact.isEmpty
            ? observations.filter { $0.processingPath == processingPath }
            : exact
        guard !candidates.isEmpty else {
            return defaultEstimate(
                sizeBytes: item.size,
                durationSeconds: knownDuration,
                processingPath: processingPath
            )
        }

        let recent = Array(candidates.suffix(24))
        var weightedSeconds = 0.0
        var totalWeight = 0.0
        for (index, sample) in recent.enumerated() {
            let recencyWeight = 1 + Double(index) / Double(max(recent.count, 1))
            let extensionWeight = sample.fileExtension == extensionName ? 2.5 : 1
            let adjusted = adjustedElapsed(
                sample,
                targetSize: item.size,
                targetDuration: knownDuration
            )
            let weight = recencyWeight * extensionWeight
            weightedSeconds += adjusted * weight
            totalWeight += weight
        }
        return min(max(weightedSeconds / max(totalWeight, 1), 0.4), 600)
    }

    private func adjustedElapsed(
        _ observation: Observation,
        targetSize: Int64?,
        targetDuration: TimeInterval?
    ) -> TimeInterval {
        var factor = 1.0
        if let sourceSize = observation.sizeBytes,
           sourceSize > 0,
           let targetSize,
           targetSize > 0 {
            let exponent = observation.processingPath == .compatibilityLocalFile
                ? 0.82
                : 0.2
            factor *= pow(Double(targetSize) / Double(sourceSize), exponent)
        }
        if let sourceDuration = observation.mediaDurationSeconds,
           sourceDuration > 0,
           let targetDuration,
           targetDuration > 0 {
            factor *= pow(targetDuration / sourceDuration, 0.14)
        }
        return observation.elapsedSeconds * min(max(factor, 0.35), 3.2)
    }

    private func defaultEstimate(
        sizeBytes: Int64?,
        durationSeconds: TimeInterval?,
        processingPath: RemoteVideoThumbnailProcessingPath
    ) -> TimeInterval {
        let gigabytes = Double(max(sizeBytes ?? 0, 0)) / 1_073_741_824
        let hours = max(durationSeconds ?? 0, 0) / 3_600
        switch processingPath {
        case .backend:
            return 1.8 + min(gigabytes, 8) * 0.18
        case .avFoundationRange:
            return 5.5 + min(gigabytes, 8) * 0.9 + min(hours, 6) * 0.4
        case .compatibilityRange:
            return 13 + min(gigabytes, 8) * 2.2 + min(hours, 6) * 1.2
        case .compatibilityLocalFile:
            return 10 + min(gigabytes, 12) * 18 + min(hours, 6)
        }
    }

    private func itemKey(for item: RemoteFileItem) -> String {
        let version = item.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(item.id)|\(version)|\(item.size ?? -1)"
    }

    private func fileExtension(for item: RemoteFileItem) -> String {
        let value = (item.name as NSString).pathExtension.lowercased()
        return value.isEmpty ? "unknown" : value
    }

    private func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

private struct ThumbnailPreheatPayload {
    let data: Data
    let transferredBytes: Int
    let mediaDurationSeconds: TimeInterval?
    let processingPath: RemoteVideoThumbnailProcessingPath
}

private enum ThumbnailPreheatError: LocalizedError {
    case wifiRequired
    case powerRequired
    case appInactive
    case lowBattery

    var errorDescription: String? {
        switch self {
        case .wifiRequired:
            "데이터 사용을 막기 위해 요금이 부과되지 않는 Wi‑Fi에 연결해 주세요."
        case .powerRequired:
            "충전기를 연결한 상태에서 썸네일 미리 생성을 시작해 주세요."
        case .appInactive:
            "NasFinder가 화면에 열려 있을 때만 썸네일을 미리 만들 수 있습니다."
        case .lowBattery:
            "배터리가 20% 이하라서 Super Thumbnail 작업을 취소했습니다."
        }
    }
}
