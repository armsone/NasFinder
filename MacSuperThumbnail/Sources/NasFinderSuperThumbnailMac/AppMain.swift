import AppKit
import ImageIO
import SwiftUI

@main
struct NasFinderSuperThumbnailMacApp: App {
    @StateObject private var model = SuperThumbnailMacModel.shared
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        WindowGroup {
            SuperThumbnailMacView(model: model)
                .frame(minWidth: 760, minHeight: 610)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Toggle("업데이트 자동 다운로드", isOn: Binding(
                    get: { updateController.automaticDownloadEnabled },
                    set: updateController.setAutomaticDownloadEnabled
                ))
                Button("업데이트 확인…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                Button(UpdatePreferenceLogic.statusText(automaticDownloadEnabled: updateController.automaticDownloadEnabled)) {}
                    .disabled(true)
            }
            CommandMenu("작업") {
                Menu("동시 작업자 수") {
                    Picker("동시 작업자 수", selection: Binding(
                        get: { model.concurrencyPreference },
                        set: { model.setConcurrencyPreference($0) }
                    )) {
                        ForEach(SuperThumbnailWorkerPreference.allCases) { pref in
                            Text(pref.menuTitle).tag(pref)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
final class SuperThumbnailMacModel: ObservableObject {
    static let shared = SuperThumbnailMacModel()

    @Published var selectedFolder: URL?
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var hasPendingResume = false
    @Published var cleanupPhase: VaultCleanupPhase = .idle
    @Published var discoveryPhase: MediaDiscoveryPhase = .idle
    @Published var totalCount = 0
    @Published var completedCount = 0
    @Published var generatedCount = 0
    @Published var cachedCount = 0
    @Published var failedCount = 0
    @Published var currentName = "Finder에서 NAS 또는 미디어 폴더를 선택하세요."
    @Published var status = ""
    @Published var totalSourceBytes: Int64 = 0
    @Published var checkedSourceBytes: Int64 = 0
    @Published var thumbnailBytes: Int64 = 0
    @Published var averageSecondsPerItem = 0.0
    @Published var previewItems: [SuperThumbnailMacPreviewItem] = []
    @Published var jobs: [SuperThumbnailJob] = []
    @Published var activeJobID: UUID? = nil
    @Published var concurrencyPreference: SuperThumbnailWorkerPreference = .auto

    private var task: Task<Void, Never>?
    private let workerID = "mac-\(UUID().uuidString)"
    private let defaults = UserDefaults.standard

    var progress: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    var estimatedRemainingText: String {
        guard isRunning, completedCount > 0, averageSecondsPerItem > 0 else { return "계산 중" }
        let seconds = Int(Double(max(totalCount - completedCount, 0)) * averageSecondsPerItem)
        if seconds >= 3_600 {
            return "약 \(seconds / 3_600)시간 \((seconds % 3_600) / 60)분"
        }
        if seconds >= 60 { return "약 \(seconds / 60)분" }
        return "약 \(seconds)초"
    }

    var checkedDataText: String { byteText(checkedSourceBytes) + " / " + byteText(totalSourceBytes) }
    var thumbnailDataText: String { byteText(thumbnailBytes) }

    init() {
        restoreConcurrencyPreference()
        restoreLastFolder()
    }

    private func restoreConcurrencyPreference() {
        if let raw = defaults.string(forKey: "macSuperThumbnail.concurrencyPreference"),
           let pref = SuperThumbnailWorkerPreference(rawValue: raw) {
            concurrencyPreference = pref
        }
    }

    func setConcurrencyPreference(_ preference: SuperThumbnailWorkerPreference) {
        concurrencyPreference = preference
        defaults.set(preference.rawValue, forKey: "macSuperThumbnail.concurrencyPreference")
    }

    func restoreLastFolder() {
        guard let path = defaults.string(forKey: "lastSelectedFolder") else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        selectedFolder = url
        hasPendingResume = true
        currentName = "‘\(url.lastPathComponent)’ 폴더를 다시 선택했습니다."
        if jobs.isEmpty {
            jobs.append(SuperThumbnailJob(folderURL: url, status: .queued))
        }
        refreshPreviews()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "수퍼썸네일을 만들 폴더 선택"
        panel.message = "Finder에 연결된 NAS 폴더나 Mac의 미디어 폴더를 선택하세요. 여러 폴더를 선택할 수 있습니다."
        panel.prompt = "이 폴더 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        if urls.count == 1, let singleURL = urls.first {
            setOrEnqueueFolder(singleURL)
        } else {
            for url in urls {
                enqueueFolder(url)
            }
        }
    }

    func setOrEnqueueFolder(_ url: URL) {
        selectedFolder = url
        defaults.set(url.path, forKey: "lastSelectedFolder")
        hasPendingResume = true
        currentName = "‘\(url.lastPathComponent)’ 폴더를 처리할 준비가 됐습니다."
        status = ""
        cleanupPhase = .idle
        discoveryPhase = .idle
        refreshPreviews()

        if jobs.isEmpty {
            jobs.append(SuperThumbnailJob(folderURL: url, status: .queued))
        } else if !isRunning, jobs.count == 1, jobs[0].status.isTerminal || jobs[0].status == .queued {
            jobs[0] = SuperThumbnailJob(folderURL: url, status: .queued)
        } else if !jobs.contains(where: { $0.folderURL.standardizedFileURL == url.standardizedFileURL && !$0.status.isTerminal }) {
            jobs.append(SuperThumbnailJob(folderURL: url, status: .queued))
        }
    }

    func enqueueFolder(_ url: URL, isFresh: Bool = false) {
        if selectedFolder == nil {
            selectedFolder = url
            defaults.set(url.path, forKey: "lastSelectedFolder")
            hasPendingResume = true
            currentName = "‘\(url.lastPathComponent)’ 폴더를 처리할 준비가 됐습니다."
            refreshPreviews()
        }
        if !jobs.contains(where: { $0.folderURL.standardizedFileURL == url.standardizedFileURL && !$0.status.isTerminal }) {
            jobs.append(SuperThumbnailJob(folderURL: url, isFresh: isFresh, status: .queued))
        }
    }

    func removeJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].id == activeJobID && isRunning {
            cancel()
        }
        jobs.remove(at: index)
    }

    func clearCompletedJobs() {
        jobs.removeAll(where: { $0.status.isTerminal && $0.id != activeJobID })
    }

    func selectJob(_ job: SuperThumbnailJob) {
        selectedFolder = job.folderURL
        refreshPreviews()
    }

    func refreshPreviews() {
        guard let root = selectedFolder else {
            previewItems = []
            return
        }
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) {
                VaultProcessor.discoverExistingPreviews(in: root)
            }.value
            guard let self else { return }
            guard self.selectedFolder?.standardizedFileURL == root.standardizedFileURL else { return }
            self.previewItems = items
        }
    }

    func start() {
        runQueue(freshOverride: false)
    }

    func startFresh() {
        runQueue(freshOverride: true)
    }

    private func runQueue(freshOverride: Bool) {
        guard !isRunning else { return }

        // If jobs is empty but selectedFolder exists, populate single job
        if let root = selectedFolder, jobs.isEmpty {
            jobs.append(SuperThumbnailJob(folderURL: root, isFresh: freshOverride, status: .queued))
        } else if let root = selectedFolder, !jobs.contains(where: { !$0.status.isTerminal }) {
            jobs.append(SuperThumbnailJob(folderURL: root, isFresh: freshOverride, status: .queued))
        }

        if freshOverride {
            if let targetIdx = jobs.firstIndex(where: { $0.folderURL.standardizedFileURL == selectedFolder?.standardizedFileURL && !$0.status.isTerminal }) {
                jobs[targetIdx].isFresh = true
            } else if let firstQueued = jobs.firstIndex(where: { $0.status == .queued }) {
                jobs[firstQueued].isFresh = true
            }
        }

        guard jobs.contains(where: { $0.status == .queued || $0.status == .paused }) else { return }

        isRunning = true
        isPaused = false
        hasPendingResume = true
        let worker = workerID

        task = Task { [weak self] in
            guard let self else { return }
            await self.executeQueue(worker: worker)
        }
    }

    private func executeQueue(worker: String) async {
        while isRunning {
            guard let jobIndex = jobs.firstIndex(where: { $0.status == .queued || $0.status == .paused }) else {
                break
            }

            var job = jobs[jobIndex]
            let root = job.folderURL
            selectedFolder = root
            activeJobID = job.id
            job.status = .running
            jobs[jobIndex] = job

            resetProgress()
            if job.isFresh {
                previewItems.removeAll()
            } else {
                refreshPreviews()
            }

            status = job.isFresh ? "기존 .NasFinder-Vault 보관본을 정리하는 중…" : "사진과 영상을 찾는 중…"
            let isNetworkOrRemovable = SuperThumbnailConcurrencyPolicy.isNetworkOrRemovable(url: root)

            do {
                // 1. Fresh Cleanup Phase if requested
                if job.isFresh {
                    cleanupPhase = .discovering
                    currentName = "기존 보관본을 정리하는 중입니다."
                    let discovery = Task.detached(priority: .userInitiated) {
                        try VaultProcessor.discoverVaultDirectories(in: root)
                    }
                    let vaults = try await withTaskCancellationHandler {
                        try await discovery.value
                    } onCancel: {
                        discovery.cancel()
                    }
                    try Task.checkCancellation()

                    cleanupPhase = .removing(completed: 0, total: vaults.count)
                    var removedCount = 0
                    for vault in vaults {
                        try Task.checkCancellation()
                        let removed = try await Task.detached(priority: .userInitiated) {
                            try VaultProcessor.removeVaultDirectory(at: vault, within: root)
                        }.value
                        if removed {
                            removedCount += 1
                            cleanupPhase = .removing(completed: removedCount, total: vaults.count)
                        }
                    }
                    try Task.checkCancellation()
                    cleanupPhase = .idle
                    status = "기존 보관본 \(removedCount)개 정리 완료. 사진과 영상을 찾는 중…"
                }

                // 2. Discovery Phase
                discoveryPhase = .discoveringFiles
                currentName = "사진과 영상을 찾는 중입니다."
                let mediaDiscovery = Task.detached(priority: .userInitiated) {
                    try VaultProcessor.discoverMedia(in: root)
                }
                let files = try await withTaskCancellationHandler {
                    try await mediaDiscovery.value
                } onCancel: {
                    mediaDiscovery.cancel()
                }
                try Task.checkCancellation()

                discoveryPhase = .discoveringFolders
                let folderDiscovery = Task.detached(priority: .userInitiated) {
                    try VaultProcessor.discoverFolders(in: root)
                }
                let folders = try await withTaskCancellationHandler {
                    try await folderDiscovery.value
                } onCancel: {
                    folderDiscovery.cancel()
                }
                try Task.checkCancellation()
                discoveryPhase = .idle

                totalCount = files.count + folders.count
                totalSourceBytes = files.reduce(0) { $0 + $1.size }

                if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[idx].totalCount = totalCount
                }

                if files.isEmpty && folders.isEmpty {
                    status = "이 폴더에서 지원되는 사진이나 영상을 찾지 못했습니다."
                    currentName = ""
                    hasPendingResume = false
                    if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[idx].status = .completed
                        self.jobs[idx].statusMessage = status
                    }
                    continue
                }

                _ = try await Task.detached(priority: .utility) {
                    try VaultProcessor.registerWorker(worker, root: root)
                }.value
                status = "파일 \(files.count)개와 폴더 \(folders.count)개의 수퍼썸네일을 확인합니다."

                let started = Date()

                // 3. Process Media Files with Bounded Structured Concurrency
                await self.processMediaFilesBounded(
                    files: files,
                    worker: worker,
                    started: started,
                    isNetworkOrRemovable: isNetworkOrRemovable,
                    jobID: job.id
                )
                try Task.checkCancellation()

                // 4. Process Folders Deepest-First by Depth Barriers
                var folderGeneratedCount = 0
                var folderEmptyCount = 0
                var folderFailedCount = 0
                let folderTileCache = FolderSheetTileCache()
                let depthGroups = FolderDepthGrouping.groupDeepestFirst(folders: folders)

                await self.processFolderDepthGroupsBounded(
                    depthGroups: depthGroups,
                    worker: worker,
                    tileCache: folderTileCache,
                    started: started,
                    isNetworkOrRemovable: isNetworkOrRemovable,
                    jobID: job.id,
                    folderGeneratedCount: &folderGeneratedCount,
                    folderEmptyCount: &folderEmptyCount,
                    folderFailedCount: &folderFailedCount
                )
                try Task.checkCancellation()

                let finalStatus = "완료: 새로 생성 \(generatedCount)개 · 기존/다른 기기 \(cachedCount)개 · 실패 \(failedCount)개"
                    + " · 폴더 생성 \(folderGeneratedCount)개 · 빈 폴더 \(folderEmptyCount)개"
                    + (folderFailedCount > 0 ? " · 폴더 실패 \(folderFailedCount)개" : "")
                status = finalStatus
                currentName = "처리가 완료되었습니다."
                hasPendingResume = false

                if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[idx].status = .completed
                    self.jobs[idx].completedCount = completedCount
                    self.jobs[idx].generatedCount = generatedCount
                    self.jobs[idx].cachedCount = cachedCount
                    self.jobs[idx].failedCount = failedCount
                    self.jobs[idx].statusMessage = finalStatus
                }
            } catch is CancellationError {
                status = "작업을 중단했습니다. 다음 실행에서 이어서 확인할 수 있습니다."
                refreshPreviews()
                if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[idx].status = .cancelled
                    self.jobs[idx].statusMessage = status
                    self.jobs[idx].completedCount = completedCount
                }
                break
            } catch {
                status = "시작하지 못했습니다: \(error.localizedDescription)"
                refreshPreviews()
                if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[idx].status = .failed(error.localizedDescription)
                    self.jobs[idx].statusMessage = status
                }
            }
        }

        cleanupPhase = .idle
        discoveryPhase = .idle
        isRunning = false
        isPaused = false
        activeJobID = nil
        task = nil
    }

    private func currentEffectiveWorkerLimit(isNetworkOrRemovable: Bool) -> Int {
        SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
            preference: concurrencyPreference,
            isNetworkOrRemovable: isNetworkOrRemovable,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private func currentEffectiveFolderWorkerLimit(isNetworkOrRemovable: Bool) -> Int {
        SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
            preference: concurrencyPreference,
            isNetworkOrRemovable: isNetworkOrRemovable,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private func processMediaFilesBounded(
        files: [MediaFile],
        worker: String,
        started: Date,
        isNetworkOrRemovable: Bool,
        jobID: UUID
    ) async {
        guard !files.isEmpty else { return }

        await withTaskGroup(of: MediaFileProcessingOutcome.self) { group in
            var fileIndex = 0
            let total = files.count
            var inFlight = 0
            let initialLimit = currentEffectiveWorkerLimit(isNetworkOrRemovable: isNetworkOrRemovable)

            while fileIndex < total && inFlight < initialLimit {
                let file = files[fileIndex]
                fileIndex += 1
                inFlight += 1
                group.addTask {
                    await VaultProcessor.processMediaItem(file, workerID: worker)
                }
            }

            while inFlight > 0 {
                guard let outcome = await group.next() else { break }
                inFlight -= 1

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                self.applyFileOutcome(outcome, started: started, jobID: jobID)

                while self.isPaused && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                let effectiveLimit = self.currentEffectiveWorkerLimit(isNetworkOrRemovable: isNetworkOrRemovable)
                while fileIndex < total && inFlight < effectiveLimit && !self.isPaused && !Task.isCancelled {
                    let file = files[fileIndex]
                    fileIndex += 1
                    inFlight += 1
                    group.addTask {
                        await VaultProcessor.processMediaItem(file, workerID: worker)
                    }
                }
            }
        }
    }

    private func applyFileOutcome(
        _ outcome: MediaFileProcessingOutcome,
        started: Date,
        jobID: UUID
    ) {
        let file = outcome.file
        currentName = file.url.lastPathComponent
        switch outcome.result {
        case .success(let result):
            generatedCount += result.generated ? 1 : 0
            cachedCount += result.alreadyCached ? 1 : 0
            thumbnailBytes += result.thumbnailBytes
            if let preview = outcome.previewItem {
                addPreviewItem(preview, isNewlyGenerated: result.generated)
            }
        case .failure(let error):
            if !(error is CancellationError) {
                failedCount += 1
            }
        }
        completedCount += 1
        checkedSourceBytes += file.size
        averageSecondsPerItem = Date().timeIntervalSince(started) / Double(completedCount)

        if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
            self.jobs[idx].completedCount = completedCount
            self.jobs[idx].generatedCount = generatedCount
            self.jobs[idx].cachedCount = cachedCount
            self.jobs[idx].failedCount = failedCount
        }
    }

    private func processFolderDepthGroupsBounded(
        depthGroups: [[FolderEntry]],
        worker: String,
        tileCache: FolderSheetTileCache,
        started: Date,
        isNetworkOrRemovable: Bool,
        jobID: UUID,
        folderGeneratedCount: inout Int,
        folderEmptyCount: inout Int,
        folderFailedCount: inout Int
    ) async {
        for depthGroup in depthGroups {
            if Task.isCancelled { break }
            while isPaused && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled { break }

            let folderLimit = currentEffectiveFolderWorkerLimit(isNetworkOrRemovable: isNetworkOrRemovable)

            await withTaskGroup(of: FolderProcessingOutcome.self) { group in
                var folderIndex = 0
                let total = depthGroup.count
                var inFlight = 0

                while folderIndex < total && inFlight < folderLimit {
                    let folder = depthGroup[folderIndex]
                    folderIndex += 1
                    inFlight += 1
                    group.addTask {
                        await VaultProcessor.processFolderItem(
                            folder,
                            workerID: worker,
                            tileCache: tileCache
                        )
                    }
                }

                while inFlight > 0 {
                    guard let outcome = await group.next() else { break }
                    inFlight -= 1

                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }

                    self.applyFolderOutcome(
                        outcome,
                        started: started,
                        jobID: jobID,
                        folderGeneratedCount: &folderGeneratedCount,
                        folderEmptyCount: &folderEmptyCount,
                        folderFailedCount: &folderFailedCount
                    )

                    while self.isPaused && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }

                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }

                    let currentLimit = self.currentEffectiveFolderWorkerLimit(isNetworkOrRemovable: isNetworkOrRemovable)
                    while folderIndex < total && inFlight < currentLimit && !self.isPaused && !Task.isCancelled {
                        let nextFolder = depthGroup[folderIndex]
                        folderIndex += 1
                        inFlight += 1
                        group.addTask {
                            await VaultProcessor.processFolderItem(
                                nextFolder,
                                workerID: worker,
                                tileCache: tileCache
                            )
                        }
                    }
                }
            }
        }
    }

    private func applyFolderOutcome(
        _ outcome: FolderProcessingOutcome,
        started: Date,
        jobID: UUID,
        folderGeneratedCount: inout Int,
        folderEmptyCount: inout Int,
        folderFailedCount: inout Int
    ) {
        let folder = outcome.folder
        currentName = "폴더 · \(folder.url.lastPathComponent)"
        switch outcome.result {
        case .success(let result):
            switch result.state {
            case .generated:
                generatedCount += 1
                folderGeneratedCount += 1
                thumbnailBytes += result.thumbnailBytes
                if let preview = outcome.previewItem {
                    addPreviewItem(preview, isNewlyGenerated: true)
                }
            case .emptyIndexed:
                cachedCount += 1
                folderEmptyCount += 1
            }
        case .failure(let error):
            if !(error is CancellationError) {
                failedCount += 1
                folderFailedCount += 1
            }
        }
        completedCount += 1
        averageSecondsPerItem = Date().timeIntervalSince(started) / Double(completedCount)

        if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
            self.jobs[idx].completedCount = completedCount
            self.jobs[idx].generatedCount = generatedCount
            self.jobs[idx].cachedCount = cachedCount
            self.jobs[idx].failedCount = failedCount
        }
    }

    private func addPreviewItem(_ item: SuperThumbnailMacPreviewItem, isNewlyGenerated: Bool) {
        previewItems = SuperThumbnailPreviewOrdering.prepending(
            item,
            to: previewItems,
            promotesExisting: isNewlyGenerated
        )
    }

    /// Pauses or resumes the active queue execution and updates the active nonterminal job's status.
    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        if let targetIndex = (activeJobID.flatMap { id in jobs.firstIndex(where: { $0.id == id && !$0.status.isTerminal }) }
            ?? jobs.firstIndex(where: { isPaused ? $0.status == .running : $0.status == .paused })) {
            jobs[targetIndex].status = isPaused ? .paused : .running
        }
        status = isPaused
            ? "일시정지했습니다. ‘계속’을 누르면 현재 위치부터 이어갑니다."
            : "작업을 계속합니다…"
    }

    func cancel() {
        guard isRunning else { return }
        status = "현재 파일을 정리한 뒤 중단합니다…"
        task?.cancel()
    }

    private func resetProgress() {
        cleanupPhase = .idle
        discoveryPhase = .idle
        totalCount = 0
        completedCount = 0
        generatedCount = 0
        cachedCount = 0
        failedCount = 0
        totalSourceBytes = 0
        checkedSourceBytes = 0
        thumbnailBytes = 0
        averageSecondsPerItem = 0
    }

    private func byteText(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

struct SuperThumbnailMacView: View {
    @ObservedObject var model: SuperThumbnailMacModel
    @State private var isConfirmingFresh = false
    @AppStorage("macSuperThumbnail.isPreviewExpanded") private var isPreviewExpanded = true
    /// Persisted strip height chosen with the resize handle (points).
    @AppStorage("macSuperThumbnail.previewHeight") private var storedPreviewHeight =
        Double(SuperThumbnailPreviewSizing.defaultHeight)
    @State private var dragStartHeight: CGFloat?
    @State private var isHoveringResizeHandle = false
    @FocusState private var isResizeHandleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        folderCard
                        if model.jobs.count > 1 {
                            queueCard
                        }
                        if model.cleanupPhase.isActive {
                            cleanupCard
                        } else if model.discoveryPhase.isActive {
                            discoveryCard
                        } else {
                            progressCard
                        }
                        previewCard(availableHeight: geometry.size.height)
                    }
                    .padding(28)
                }
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("수퍼썸네일을 처음부터 다시 만들까요?", isPresented: $isConfirmingFresh) {
            Button("새로하기", role: .destructive) {
                model.startFresh()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 폴더와 모든 하위 폴더의 .NasFinder-Vault 보관본만 삭제하고 처음부터 다시 만듭니다. 원본 사진과 영상은 삭제되지 않습니다.")
        }
    }

    private var concurrencySummaryText: String {
        let pref = model.concurrencyPreference
        let isThermal = SuperThumbnailConcurrencyPolicy.isThermalThrottled(thermalState: ProcessInfo.processInfo.thermalState)
        if pref == .auto {
            let isNet = model.selectedFolder.map { SuperThumbnailConcurrencyPolicy.isNetworkOrRemovable(url: $0) } ?? false
            let limit = SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                preference: .auto,
                isNetworkOrRemovable: isNet
            )
            return isThermal ? "동시: 자동 (1개·발열 제한)" : "동시: 자동 (\(limit)개)"
        } else {
            return isThermal ? "동시: \(pref.displayName) (1개·발열 제한)" : "동시: \(pref.displayName)"
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("NasFinder").font(.title2.bold())
                Text("Super Thumbnail for Mac").foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("동시 작업 수", selection: Binding(
                    get: { model.concurrencyPreference },
                    set: { model.setConcurrencyPreference($0) }
                )) {
                    ForEach(SuperThumbnailWorkerPreference.allCases) { pref in
                        Text(pref.menuTitle).tag(pref)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                    Text(concurrencySummaryText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("동시 처리 작업자 수를 설정합니다. 기본값은 자동(네트워크 2, 로컬 4, 발열 시 1)입니다.")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.bar)
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("작업 폴더", systemImage: "folder.fill").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedFolder?.path ?? "선택된 폴더 없음")
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("Finder에 마운트된 NAS 폴더나 Mac의 미디어 폴더를 선택할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("폴더 선택", action: model.chooseFolder)
                    .disabled(model.isRunning)
                    .accessibilityLabel("작업 폴더 선택")
            }
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("작업 대기열 (\(model.jobs.count))", systemImage: "list.bullet.rectangle.fill")
                    .font(.headline)
                Spacer()
                if model.jobs.contains(where: { $0.status.isTerminal }) {
                    Button("완료 항목 정리", action: model.clearCompletedJobs)
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .disabled(model.isRunning)
                }
            }
            VStack(spacing: 8) {
                ForEach(model.jobs) { job in
                    jobRow(job)
                }
            }
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func jobRow(_ job: SuperThumbnailJob) -> some View {
        let isActive = job.id == model.activeJobID && model.isRunning
        let isSelected = job.folderURL.standardizedFileURL == model.selectedFolder?.standardizedFileURL
        return HStack(spacing: 12) {
            Image(systemName: job.isFresh ? "sparkles.rectangle.stack" : "folder.fill")
                .foregroundStyle(isActive ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.folderName)
                        .font(.subheadline.weight(isActive || isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if job.isFresh {
                        Text("새로하기")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(job.folderURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            jobStatusBadge(job)
            if job.status == .queued && !model.isRunning {
                Button {
                    model.removeJob(id: job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("대기열에서 제거")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.isRunning {
                model.selectJob(job)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.1) : (isSelected ? Color.primary.opacity(0.04) : Color.clear))
        )
    }

    private func jobStatusBadge(_ job: SuperThumbnailJob) -> some View {
        HStack(spacing: 6) {
            switch job.status {
            case .queued:
                Text("대기 중")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView()
                    .controlSize(.mini)
                Text("\(job.completedCount)/\(job.totalCount)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.blue)
            case .paused:
                Text("일시정지")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("완료")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            case .cancelled:
                Text("중단됨")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("실패")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            }
        }
    }

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("보관본 정리 중", systemImage: "trash.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
                Spacer()
                if model.cleanupPhase.isDeterminate {
                    Text(model.cleanupPhase.countText)
                        .font(.title3.monospacedDigit().bold())
                }
            }
            if model.cleanupPhase.isDeterminate {
                ProgressView(value: model.cleanupPhase.fractionCompleted)
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .scaleEffect(y: 1.6)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .scaleEffect(y: 1.6)
            }
            Text(model.cleanupPhase.activityText)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("기존 보관본 정리 진행")
        .accessibilityValue(model.cleanupPhase.accessibilityValueText)
    }

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MediaDiscoverySearchingIndicator()
                Text(MediaDiscoveryPhase.titleText)
                    .font(.title.bold())
                    .foregroundStyle(.blue)
                Spacer()
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.blue)
                .scaleEffect(y: 1.6)
            Text(model.discoveryPhase.activityText)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.discoveryPhase)
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.discoveryPhase.accessibilityLabelText)
        .accessibilityValue(model.discoveryPhase.accessibilityValueText)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("생성 진행", systemImage: "photo.stack.fill").font(.headline)
                Spacer()
                Text("\(model.completedCount.formatted()) / \(model.totalCount.formatted())")
                    .font(.title3.monospacedDigit().bold())
            }
            ProgressView(value: model.progress)
            Text(model.currentName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 24) {
                metric("새로 생성", model.generatedCount)
                metric("기존", model.cachedCount)
                metric("실패", model.failedCount)
                Spacer()
                infoMetric("남은 예상시간", model.estimatedRemainingText)
                infoMetric("확인한 대상 용량", model.checkedDataText)
                infoMetric("썸네일 용량", model.thumbnailDataText)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func previewCard(availableHeight: CGFloat) -> some View {
        let previewHeight = SuperThumbnailPreviewSizing.clamped(
            CGFloat(storedPreviewHeight),
            availableHeight: availableHeight
        )
        return VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("미리보기", systemImage: "rectangle.stack.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !model.previewItems.isEmpty {
                        Text("(\(model.previewItems.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isPreviewExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("미리보기 영역")
            .accessibilityHint(isPreviewExpanded ? "미리보기를 접습니다." : "미리보기를 펼칩니다.")

            if isPreviewExpanded {
                if model.previewItems.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundStyle(.tertiary)
                        Text(model.isRunning ? "썸네일을 생성하면 여기에 표시됩니다." : "생성된 수퍼썸네일이 여기에 표시됩니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    previewStrip(height: previewHeight)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    previewResizeHandle(height: previewHeight, availableHeight: availableHeight)
                }
            }
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func previewResizeHandle(height: CGFloat, availableHeight: CGFloat) -> some View {
        let isActive = dragStartHeight != nil || isHoveringResizeHandle || isResizeHandleFocused
        return HStack(spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            Capsule()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.7))
                .frame(width: 48, height: 5)
            Text("드래그해 크기 조절")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor.opacity(isResizeHandleFocused ? 0.8 : 0), lineWidth: 2)
        )
        .onHover { hovering in
            isHoveringResizeHandle = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else if dragStartHeight == nil {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHoveringResizeHandle {
                isHoveringResizeHandle = false
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let base = dragStartHeight ?? height
                    if dragStartHeight == nil {
                        dragStartHeight = base
                    }
                    setPreviewHeight(
                        SuperThumbnailPreviewSizing.resized(
                            from: base,
                            dragTranslation: value.translation.height,
                            availableHeight: availableHeight
                        )
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    if !isHoveringResizeHandle {
                        NSCursor.pop()
                    }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                setPreviewHeight(SuperThumbnailPreviewSizing.defaultHeight, animated: true)
            }
        )
        .focusable()
        .focused($isResizeHandleFocused)
        .onKeyPress(.downArrow) {
            stepPreviewHeight(.increment, current: height, availableHeight: availableHeight)
            return .handled
        }
        .onKeyPress(.upArrow) {
            stepPreviewHeight(.decrement, current: height, availableHeight: availableHeight)
            return .handled
        }
        .help("위아래로 드래그해 미리보기 크기를 바꿉니다. 두 번 클릭하면 기본 크기로 돌아갑니다.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("미리보기 크기 조절")
        .accessibilityValue(SuperThumbnailPreviewSizing.heightText(height))
        .accessibilityHint("값을 올리면 미리보기와 썸네일이 커지고, 내리면 작아집니다.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                stepPreviewHeight(.increment, current: height, availableHeight: availableHeight)
            case .decrement:
                stepPreviewHeight(.decrement, current: height, availableHeight: availableHeight)
            @unknown default:
                break
            }
        }
    }

    private func stepPreviewHeight(
        _ direction: SuperThumbnailPreviewSizing.StepDirection,
        current: CGFloat,
        availableHeight: CGFloat
    ) {
        setPreviewHeight(
            SuperThumbnailPreviewSizing.stepped(current, direction, availableHeight: availableHeight),
            animated: true
        )
    }

    private func setPreviewHeight(_ height: CGFloat, animated: Bool = false) {
        let clamped = SuperThumbnailPreviewSizing.clamped(height)
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) {
                storedPreviewHeight = Double(clamped)
            }
        } else {
            storedPreviewHeight = Double(clamped)
        }
    }

    private func previewStrip(height: CGFloat) -> some View {
        let items = model.previewItems
        let cardSide = SuperThumbnailPreviewSizing.cardSide(forStripHeight: height)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .bottom, spacing: -14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MacThumbnailCard(item: item, index: index, totalCount: items.count, baseSide: cardSide)
                            .id(item.id)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal: .opacity
                                )
                            )
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 28)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86),
                    value: items
                )
            }
            .frame(height: height)
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: .underPageBackgroundColor),
                        Color(nsColor: .windowBackgroundColor).opacity(0.6),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .onChange(of: items.first?.id) { _, newest in
                guard let newest else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                    proxy.scrollTo(newest, anchor: .leading)
                }
            }
            .accessibilityLabel("생성된 수퍼썸네일 미리보기, 최신 항목이 왼쪽에 표시됩니다")
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func infoMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(value).font(.callout.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text("각 미디어 폴더의 .NasFinder-Vault에 iPhone과 호환되는 JPEG를 저장합니다. 중단하거나 앱을 닫아도 같은 폴더에서 이어갈 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if model.isRunning {
                    Button(model.isPaused ? "계속" : "일시정지", action: model.togglePause)
                        .accessibilityLabel(model.isPaused ? "계속하기" : "일시정지")
                    Button("중단", role: .destructive, action: model.cancel)
                        .accessibilityLabel("작업 중단")
                }
                Spacer()
                if !model.isRunning {
                    Button("새로하기") {
                        isConfirmingFresh = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.selectedFolder == nil && !model.jobs.contains(where: { !$0.status.isTerminal }))
                    .accessibilityLabel("새로하기")
                    .accessibilityHint("선택한 폴더의 기존 .NasFinder-Vault를 삭제하고 처음부터 다시 만듭니다.")
                }
                Button(model.hasPendingResume ? "이어하기" : "수퍼썸네일 만들기", action: model.start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled((model.selectedFolder == nil && !model.jobs.contains(where: { !$0.status.isTerminal })) || model.isRunning)
                    .accessibilityLabel(model.hasPendingResume ? "이어하기" : "수퍼썸네일 만들기")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
    }
}

/// Continuously animated “searching” glyph for the discovery card.
struct MediaDiscoverySearchingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSweeping = false

    var body: some View {
        Group {
            if reduceMotion {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(isSweeping ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isSweeping)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .onAppear { isSweeping = true }
                .onDisappear { isSweeping = false }
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

struct MacThumbnailCard: View {
    let item: SuperThumbnailMacPreviewItem
    var index = 0
    var totalCount = 1
    var baseSide: CGFloat = 112
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isNewest: Bool { index == 0 }
    private var depth: CGFloat { CGFloat(min(index, 4)) }
    private var side: CGFloat { baseSide * max(0.72, 1 - depth * 0.07) }
    private var labelWidth: CGFloat { max(side, 72) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                MacThumbnailImage(
                    fileURL: item.vaultFileURL,
                    maxPixelSize: SuperThumbnailPreviewSizing.maxPixelSize(forCardSide: baseSide)
                )
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isNewest ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.55),
                            lineWidth: isNewest ? 1.5 : 1
                        )
                )

                if item.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                        .accessibilityLabel("폴더")
                }
            }
            .rotation3DEffect(
                .degrees(reduceMotion || isNewest ? 0 : -Double(depth) * 3.2),
                axis: (x: 0, y: 1, z: 0),
                anchor: .leading
            )
            .shadow(
                color: .black.opacity(isNewest ? 0.22 : 0.12),
                radius: isNewest ? 8 : 4,
                y: 2
            )
            .frame(width: labelWidth, height: baseSide, alignment: .bottomLeading)

            Text(item.name)
                .font(isNewest ? .caption.weight(.medium) : .caption2)
                .foregroundStyle(isNewest ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: labelWidth, alignment: .leading)
        }
        .zIndex(Double(totalCount - index))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isFolder ? "폴더 \(item.name)" : item.name)
        .accessibilityValue(isNewest ? "가장 최근 생성" : "")
    }
}

struct MacThumbnailImage: View {
    let fileURL: URL
    var maxPixelSize = 160
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.08)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .task(id: "\(fileURL.path)#\(maxPixelSize)") {
            let maxPixelSize = maxPixelSize
            let fileURL = fileURL
            let decoded: NSImage? = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
            if decoded != nil || image == nil {
                image = decoded
            }
        }
    }
}
