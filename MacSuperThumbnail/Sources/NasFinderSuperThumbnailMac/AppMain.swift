import AppKit
import ImageIO
import SwiftUI

@main
struct NasFinderSuperThumbnailMacApp: App {
    @StateObject private var model = SuperThumbnailMacModel()
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
        }
    }
}

@MainActor
final class SuperThumbnailMacModel: ObservableObject {
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
        restoreLastFolder()
    }

    func restoreLastFolder() {
        guard let path = defaults.string(forKey: "lastSelectedFolder") else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        selectedFolder = url
        hasPendingResume = true
        currentName = "‘\(url.lastPathComponent)’ 폴더를 다시 선택했습니다."
        refreshPreviews()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "수퍼썸네일을 만들 폴더 선택"
        panel.message = "Finder에 연결된 NAS 폴더나 Mac의 미디어 폴더를 선택하세요."
        panel.prompt = "이 폴더 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url
        defaults.set(url.path, forKey: "lastSelectedFolder")
        hasPendingResume = true
        currentName = "‘\(url.lastPathComponent)’ 폴더를 처리할 준비가 됐습니다."
        status = ""
        cleanupPhase = .idle
        discoveryPhase = .idle
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
        run(fresh: false)
    }

    func startFresh() {
        run(fresh: true)
    }

    private func run(fresh: Bool) {
        guard let root = selectedFolder, !isRunning else { return }
        resetProgress()
        if fresh {
            previewItems.removeAll()
        }
        isRunning = true
        isPaused = false
        hasPendingResume = true
        status = fresh ? "기존 .NasFinder-Vault 보관본을 정리하는 중…" : "사진과 영상을 찾는 중…"
        let worker = workerID

        task = Task { [weak self] in
            guard let self else { return }
            do {
                if fresh {
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

                // Discovery is its own visible phase: media files first, then
                // folders. Detached tasks do not inherit cancellation, so each
                // pass is cancelled explicitly to keep “중단” responsive.
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
                if files.isEmpty, folders.isEmpty {
                    status = "이 폴더에서 지원되는 사진이나 영상을 찾지 못했습니다."
                    currentName = ""
                    isRunning = false
                    hasPendingResume = false
                    return
                }
                _ = try await Task.detached(priority: .utility) {
                    try VaultProcessor.registerWorker(worker, root: root)
                }.value
                status = "파일 \(files.count)개와 폴더 \(folders.count)개의 수퍼썸네일을 확인합니다."

                let started = Date()
                for file in files {
                    try Task.checkCancellation()
                    while isPaused {
                        try await Task.sleep(for: .milliseconds(200))
                        try Task.checkCancellation()
                    }
                    currentName = file.url.lastPathComponent
                    do {
                        let result = try await VaultProcessor.process(file, workerID: worker)
                        generatedCount += result.generated ? 1 : 0
                        cachedCount += result.alreadyCached ? 1 : 0
                        thumbnailBytes += result.thumbnailBytes

                        let vault = file.url.deletingLastPathComponent()
                            .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
                        if let filename = try? NasFinderVaultCompatibility.thumbnailFilename(for: file.url) {
                            let thumbnailURL = vault.appendingPathComponent(filename)
                            if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                                addPreviewItem(
                                    SuperThumbnailMacPreviewItem(
                                        id: SuperThumbnailPreviewOrdering.canonicalID(for: thumbnailURL),
                                        name: file.url.lastPathComponent,
                                        isFolder: false,
                                        vaultFileURL: thumbnailURL
                                    ),
                                    isNewlyGenerated: result.generated
                                )
                            }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedCount += 1
                    }
                    completedCount += 1
                    checkedSourceBytes += file.size
                    averageSecondsPerItem = Date().timeIntervalSince(started) / Double(completedCount)
                }

                // Folders run after files and deepest-first so each parent
                // sheet can reuse child file thumbnails and child folder
                // sheets that already exist in the vault.
                var folderGeneratedCount = 0
                var folderEmptyCount = 0
                var folderFailedCount = 0
                // Unblurred child tiles for this run so a parent sheet never
                // re-blurs an already blurred child sheet.
                let folderTileCache = FolderSheetTileCache()
                for folder in folders {
                    try Task.checkCancellation()
                    while isPaused {
                        try await Task.sleep(for: .milliseconds(200))
                        try Task.checkCancellation()
                    }
                    currentName = "폴더 · \(folder.url.lastPathComponent)"
                    do {
                        let result = try await Task.detached(priority: .utility) {
                            try VaultProcessor.processFolder(
                                folder,
                                workerID: worker,
                                tileCache: folderTileCache
                            )
                        }.value
                        switch result.state {
                        case .generated:
                            generatedCount += 1
                            folderGeneratedCount += 1
                            thumbnailBytes += result.thumbnailBytes

                            let parentVault = folder.url.deletingLastPathComponent()
                                .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
                            let sheetURL = parentVault.appendingPathComponent(
                                NasFinderVaultCompatibility.folderThumbnailFilename(folderName: folder.url.lastPathComponent)
                            )
                            if FileManager.default.fileExists(atPath: sheetURL.path) {
                                addPreviewItem(
                                    SuperThumbnailMacPreviewItem(
                                        id: SuperThumbnailPreviewOrdering.canonicalID(for: sheetURL),
                                        name: folder.url.lastPathComponent,
                                        isFolder: true,
                                        vaultFileURL: sheetURL
                                    ),
                                    isNewlyGenerated: true
                                )
                            }
                        case .emptyIndexed:
                            cachedCount += 1
                            folderEmptyCount += 1
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedCount += 1
                        folderFailedCount += 1
                    }
                    completedCount += 1
                    averageSecondsPerItem = Date().timeIntervalSince(started) / Double(completedCount)
                }
                status = "완료: 새로 생성 \(generatedCount)개 · 기존/다른 기기 \(cachedCount)개 · 실패 \(failedCount)개"
                    + " · 폴더 생성 \(folderGeneratedCount)개 · 빈 폴더 \(folderEmptyCount)개"
                    + (folderFailedCount > 0 ? " · 폴더 실패 \(folderFailedCount)개" : "")
                currentName = "처리가 완료되었습니다."
                hasPendingResume = false
            } catch is CancellationError {
                status = "작업을 중단했습니다. 다음 실행에서 이어서 확인할 수 있습니다."
                refreshPreviews()
            } catch {
                status = "시작하지 못했습니다: \(error.localizedDescription)"
                refreshPreviews()
            }
            cleanupPhase = .idle
            discoveryPhase = .idle
            isRunning = false
            isPaused = false
            task = nil
        }
    }

    private func addPreviewItem(_ item: SuperThumbnailMacPreviewItem, isNewlyGenerated: Bool) {
        previewItems = SuperThumbnailPreviewOrdering.prepending(
            item,
            to: previewItems,
            promotesExisting: isNewlyGenerated
        )
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
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
                    Text("Finder에 마운트된 NAS 폴더를 선택할 수 있습니다.")
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

    /// Horizontal divider under the strip. Drag it down to enlarge the
    /// preview and its thumbnails, up to shrink them. Keyboard users can
    /// focus it and press ↑/↓; VoiceOver exposes it as an adjustable control.
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

    /// Mac adaptation of the iPhone "overflow" cover flow: cards overlap
    /// toward the right, the newest one leads at full size on the far left,
    /// and the strip scrolls so the full history stays reachable.
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
                    .disabled(model.selectedFolder == nil)
                    .accessibilityLabel("새로하기")
                    .accessibilityHint("선택한 폴더의 기존 .NasFinder-Vault를 삭제하고 처음부터 다시 만듭니다.")
                }
                Button(model.hasPendingResume ? "이어하기" : "수퍼썸네일 만들기", action: model.start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedFolder == nil || model.isRunning)
                    .accessibilityLabel(model.hasPendingResume ? "이어하기" : "수퍼썸네일 만들기")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
    }
}

/// Continuously animated “searching” glyph for the discovery card. With
/// Reduce Motion enabled the custom sweep is dropped and a standard circular
/// `ProgressView` takes its place so ongoing work stays visible.
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
    /// Side of the newest card; older cards shrink from this value.
    var baseSide: CGFloat = 112
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isNewest: Bool { index == 0 }
    /// Tilt and shrink taper off after a few cards so a long strip stays
    /// readable instead of collapsing into a sliver.
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
        // Re-decode when the strip grows into a larger pixel bucket; the
        // previous image stays on screen until the sharper one arrives.
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
