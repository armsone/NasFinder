import SwiftUI
import UIKit

struct SuperThumbnailMark: View {
    var compact = false
    var body: some View {
        InterfaceIcon(systemName: "nf.super_thumbnail", size: ui(compact ? 30 : 82))
            .accessibilityHidden(true)
    }
}

struct SuperThumbnailLink: View {
    @State private var statistics = SuperThumbnailStatistics.empty
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        NavigationLink {
            SuperThumbnailView()
        } label: {
            HStack(spacing: ui(11)) {
                SuperThumbnailMark(compact: true)
                Text("Super Thumbnail")
                    .font(.ui(.subheadline))
                    .foregroundStyle(PorcelainMetrics.secondary)
                Spacer()
                Text(formatted(statistics.cacheBytes))
                    .font(.ui(.caption))
                    .foregroundStyle(PorcelainMetrics.secondary)
            }
        }
        .task { statistics = await SuperThumbnailCache.shared.statistics() }
        .onReceive(
            NotificationCenter.default.publisher(for: .superThumbnailCacheDidChange)
        ) { _ in
            Task { statistics = await SuperThumbnailCache.shared.statistics() }
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

private struct SuperThumbnailSelection: Equatable {
    let connection: RemoteConnection
    let path: String
    let title: String

    var id: String { "\(connection.id.uuidString)|\(path)" }
}

private struct CompactJobAssessment: Equatable {
    let mediaCount: Int
    let totalBytes: Int64
}

enum SuperThumbnailHiddenStartPolicy {
    static let requiredTapCount = 10
    static let visibleCountdownStart = 5

    static func remainingTapCount(after tapCount: Int) -> Int? {
        guard tapCount >= visibleCountdownStart,
              tapCount < requiredTapCount else { return nil }
        return requiredTapCount - tapCount
    }
}

private struct SuperThumbnailHistoryEntry: Codable, Equatable {
    let connectionID: String
    let path: String
    let title: String
}

struct SuperThumbnailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var connectionStore: ConnectionStore

    @StateObject private var preheater = ThumbnailPreheater()
    @State private var statistics = SuperThumbnailStatistics.empty
    @State private var selection: SuperThumbnailSelection?
    @State private var isSelectingFolder = false
    @State private var isShowingProgress = false
    @State private var isPreparing = false
    @State private var isConfirmingReset = false
    @State private var isConfirmingVaultRemoval = false
    @State private var isRemovingVault = false
    @State private var vaultResultMessage: String?
    @State private var eligibilityVersion = 0
    @State private var preparationError: String?
    @State private var compactJobAssessment: CompactJobAssessment?
    @State private var isAssessingCompactJob = false
    @State private var compactAssessmentID = UUID()
    @State private var hiddenStartTapCount = 0
    @State private var reportSelection: SuperThumbnailSelection?
    @State private var isShowingReport = false
    @AppStorage("superThumbnail.lastConnectionID.v1") private var lastConnectionID = ""
    @AppStorage("superThumbnail.lastPath.v1") private var lastPath = ""
    @AppStorage("superThumbnail.lastTitle.v1") private var lastTitle = ""
    @AppStorage("superThumbnail.previousConnectionID.v1")
    private var previousConnectionID = ""
    @AppStorage("superThumbnail.previousPath.v1") private var previousPath = ""
    @AppStorage("superThumbnail.previousTitle.v1") private var previousTitle = ""
    @AppStorage("superThumbnail.folderHistory.v1") private var folderHistoryJSON = ""
    @AppStorage("superThumbnail.hasPendingSession.v1") private var hasPendingSession = false
    @AppStorage("superThumbnail.nasVaultEnabled.v1") private var nasVaultEnabled = true
    @AppStorage("superThumbnail.nasVaultTiming.v1")
    private var nasVaultTimingRaw = SuperThumbnailVaultTiming.now.rawValue
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        ScrollView {
            VStack(spacing: ui(16)) {
                setupPanel
                actionPanel
                if !historySelections.isEmpty {
                    historyPanel
                }
                storagePanel
            }
            .padding(.horizontal, ui(18))
            .padding(.top, ui(12))
            .padding(.bottom, ui(24))
        }
        .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Group {
                    Text("Super Thumbnail")
                        .uiBarFont(.subheadline, weight: .medium)
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
                .uiBarFont()
            }
        }
        .sheet(isPresented: $isSelectingFolder) {
            SuperThumbnailFolderPickerView(onCancel: { isSelectingFolder = false }) { selected in
                selection = selected
                saveSelection(selected)
                hasPendingSession = false
                hiddenStartTapCount = 0
                assessCompactJob(for: selected)
                isSelectingFolder = false
            }
            .environmentObject(connectionStore)
        }
        .fullScreenCover(isPresented: $isShowingProgress) {
            SuperThumbnailProgressView(
                preheater: preheater,
                folderTitle: selection?.title ?? "Selected Folder",
                sessionKey: selection?.id ?? "",
                onCancel: {
                    preheater.cancel()
                    hasPendingSession = true
                    isShowingProgress = false
                    Task { await refreshStatistics() }
                },
                onClose: {
                    hasPendingSession = preheater.completedCount < preheater.totalCount
                        || preheater.failedCount > 0
                        || preheater.vaultPendingCount > 0
                        || preheater.vaultFailedCount > 0
                        || preheater.errorMessage != nil
                    isShowingProgress = false
                    Task { await refreshStatistics() }
                }
            )
            .interactiveDismissDisabled(preheater.isRunning)
        }
        .alert("Super Thumbnail을 초기화할까요?", isPresented: $isConfirmingReset) {
            Button("초기화", role: .destructive) {
                Task {
                    await SuperThumbnailCache.shared.reset()
                    await refreshStatistics()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(
                "Super Cache \(formatted(statistics.cacheBytes))와 "
                    + "누적 네트워크 사용 기록을 초기화합니다. 원본 영상은 삭제하지 않습니다."
            )
        }
        .alert("Super Thumbnail을 시작할 수 없습니다", isPresented: errorBinding) {
            Button("확인", role: .cancel) { preparationError = nil }
        } message: {
            Text(preparationError ?? "")
        }
        .alert("NAS Vault", isPresented: vaultResultBinding) {
            Button("확인", role: .cancel) { vaultResultMessage = nil }
        } message: {
            Text(vaultResultMessage ?? "")
        }
        .confirmationDialog(
            "선택한 폴더와 하위 폴더의 NAS 보관본을 삭제할까요?",
            isPresented: $isConfirmingVaultRemoval,
            titleVisibility: .visible
        ) {
            Button("NAS 보관본 삭제", role: .destructive) {
                removeSelectedVaults()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("원본 영상과 이 아이폰의 Super Cache는 삭제되지 않습니다.")
        }
        .navigationDestination(isPresented: $isShowingReport) {
            if let reportSelection {
                SuperThumbnailReportView(
                    selection: reportSelection,
                    onSelect: { selectPreviousFolder(reportSelection) },
                    onResume: { resumePreviousWork(reportSelection) }
                )
            }
        }
        .task(id: connectionStore.connections.count) {
            await refreshStatistics()
        }
        .onDisappear {
            hiddenStartTapCount = 0
        }
        .onChange(of: hiddenStartGestureAvailable) { _, isAvailable in
            if !isAvailable { hiddenStartTapCount = 0 }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            preheater.updateAppIsActive(phase == .active)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.batteryStateDidChangeNotification
            )
        ) { _ in eligibilityVersion &+= 1 }
        .onReceive(
            NotificationCenter.default.publisher(for: .thumbnailNetworkPathDidChange)
        ) { _ in eligibilityVersion &+= 1 }
        .onReceive(
            NotificationCenter.default.publisher(for: .superThumbnailCacheDidChange)
        ) { _ in
            Task { await refreshStatistics() }
        }
    }

    private var setupPanel: some View {
        VStack(spacing: 0) {
            folderSelection
            Divider().padding(.horizontal, ui(16))
            hero
            Divider().padding(.horizontal, ui(16))
            vaultOptions
        }
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(18), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
        }
    }

    private var actionPanel: some View {
        VStack(spacing: ui(12)) {
            requirements
            startButton
        }
        .padding(ui(14))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(18), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
        }
    }

    private var storagePanel: some View {
        VStack(spacing: ui(12)) {
            statisticsGrid
            Divider()
            VStack(spacing: ui(8)) {
                vaultRemovalLink
                resetLink
            }
            .frame(maxWidth: .infinity)
        }
        .padding(ui(14))
        .background(
            SkyBreezeTheme.thumbnailSurface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: ui(16), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ui(16), style: .continuous)
                .stroke(SkyBreezeTheme.thumbnailBorder.opacity(0.7), lineWidth: 1)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: ui(14)) {
            SuperThumbnailMark()
                .scaleEffect(0.44)
                .frame(width: ui(40), height: ui(40))
            Text("선택한 폴더의 영상과 사진 썸네일을 미리 만듭니다.")
                .font(.system(size: ui(15)))
                .foregroundStyle(PorcelainMetrics.secondary)
                .lineSpacing(ui(2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ui(16))
        .frame(minHeight: ui(72))
    }

    private var statisticsGrid: some View {
        HStack(spacing: ui(16)) {
            Label(
                "네트워크 \(formatted(statistics.lifetimeNetworkBytes))",
                interfaceSystemImage: "network"
            )
            Spacer()
            Label(
                "캐시 \(formatted(statistics.cacheBytes))",
                interfaceSystemImage: "internaldrive"
            )
        }
        .font(.ui(.caption2))
        .foregroundStyle(PorcelainMetrics.secondary)
        .padding(.horizontal, ui(4))
    }

    private var vaultOptions: some View {
        VStack(alignment: .leading, spacing: ui(10)) {
            Toggle(isOn: $nasVaultEnabled) {
                Label("NAS에도 보관", interfaceSystemImage: "externaldrive.fill")
                    .font(.ui(.subheadline).weight(.regular))
                    .foregroundStyle(.primary.opacity(0.82))
            }
            .frame(minHeight: ui(36))

            if nasVaultEnabled {
                Divider()
                HStack(spacing: ui(12)) {
                    Text("보관 시점")
                        .font(.ui(.subheadline))
                        .foregroundStyle(PorcelainMetrics.secondary)
                    Spacer()
                    Menu {
                        Button("폴더별 완료 즉시") {
                            nasVaultTimingRaw = SuperThumbnailVaultTiming.now.rawValue
                        }
                        Button("작업 완료 후 한 번에") {
                            nasVaultTimingRaw = SuperThumbnailVaultTiming.later.rawValue
                        }
                    } label: {
                        Text(vaultTiming == .now ? "즉시" : "나중에")
                            .font(.ui(.subheadline).weight(.medium))
                            .foregroundStyle(SkyBreezeTheme.accent)
                    }
                }
                .frame(minHeight: ui(36))
            }
            Text(vaultOptionDescription)
                .font(.ui(.caption))
                .foregroundStyle(PorcelainMetrics.secondary)
        }
        .padding(ui(16))
    }

    private var vaultOptionDescription: String {
        guard nasVaultEnabled else {
            return "이 아이폰의 Super Cache에만 저장합니다."
        }
        return vaultTiming == .now
            ? "각 폴더가 완료될 때마다 NAS에 보관합니다."
            : "모든 작업이 완료된 뒤 NAS에 한 번에 보관합니다."
    }

    private var vaultTiming: SuperThumbnailVaultTiming {
        SuperThumbnailVaultTiming(rawValue: nasVaultTimingRaw) ?? .now
    }

    private var folderSelection: some View {
        Button {
            isSelectingFolder = true
        } label: {
            VStack(alignment: .leading, spacing: ui(7)) {
                HStack(spacing: ui(12)) {
                    Image(interfaceSystemName: "folder.fill")
                        .foregroundStyle(SkyBreezeTheme.folderBlue)
                    VStack(alignment: .leading, spacing: ui(2)) {
                        Text(selection?.title ?? "처리할 폴더 선택")
                            .font(.system(size: ui(17), weight: .medium))
                            .foregroundStyle(primaryInk)
                        Text(selection?.path ?? "NAS 폴더를 선택하세요")
                            .font(.ui(.caption2))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(interfaceSystemName: "chevron.right", pointSize: 12)
                        .font(.ui(.caption).bold())
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
                .padding(ui(16))
                .frame(minHeight: ui(72))
                Text("하위 폴더 포함 · 완료된 항목은 다시 만들지 않음")
                    .font(.ui(.caption2))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .padding(.leading, ui(4))
                    .padding(.horizontal, ui(16))
                    .padding(.bottom, ui(12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("NAS에서 처리할 폴더를 선택합니다.")
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: ui(10)) {
            Text("최근 작업")
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
            List {
                ForEach(Array(historySelections.enumerated()), id: \.element.id) {
                    index, previous in
                    historyRow(previous, index: index)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("삭제", interfaceSystemImage: "trash", role: .destructive) {
                                removeHistorySelection(previous)
                            }
                        }
                        .listRowInsets(
                            EdgeInsets(top: 0, leading: 0, bottom: ui(7), trailing: 0)
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(historySelections.count) * ui(64), ui(206)))
            .clipShape(RoundedRectangle(cornerRadius: ui(15), style: .continuous))
        }
        .padding(ui(14))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(18), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
        }
    }

    private func historyRow(
        _ previous: SuperThumbnailSelection,
        index: Int
    ) -> some View {
        Button {
            reportSelection = previous
            isShowingReport = true
        } label: {
            HStack(spacing: ui(11)) {
                Image(interfaceSystemName: index == 0 ? "clock.fill" : "clock", pointSize: 12)
                    .font(.ui(.caption))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .frame(width: ui(24), height: ui(24))
                    .background(
                        Color.secondary.opacity(0.08),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text(previous.title)
                        .font(.ui(.subheadline))
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                    Text(previous.path)
                        .font(.ui(.caption2))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: ui(8))
                Image(interfaceSystemName: "chevron.right", pointSize: 12)
                    .font(.ui(.caption).bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, ui(12))
            .padding(.vertical, ui(8))
            .frame(maxWidth: .infinity, minHeight: ui(56), alignment: .leading)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: ui(14)))
            .overlay {
                RoundedRectangle(cornerRadius: ui(14), style: .continuous)
                    .stroke(SkyBreezeTheme.thumbnailBorder.opacity(0.7), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("작업 보고서를 열고 이어서 할 수 있습니다. 왼쪽으로 쓸어 삭제합니다.")
    }

    private var requirements: some View {
        HStack(spacing: ui(7)) {
            Image(interfaceSystemName: canStart ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(canStart ? PorcelainMetrics.accent : Color.secondary)
            Text(requirementSummary)
                .foregroundStyle(PorcelainMetrics.secondary)
        }
        .font(.system(size: ui(13)))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, ui(4))
    }

    private var startButton: some View {
        Button(action: startProcessing) {
            Label(
                isPreparing
                    ? "준비 중…"
                    : startButtonTitle,
                interfaceSystemImage: "sparkles.rectangle.stack.fill"
            )
            .frame(maxWidth: .infinity)
            .frame(height: ui(54))
        }
        .buttonStyle(PorcelainProminentButtonStyle(cornerRadius: 14))
        .font(.ui(.body).weight(.medium))
        .disabled(!canStart || isPreparing)
        .overlay {
            if hiddenStartGestureAvailable {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: registerHiddenStartTap)
                    .accessibilityHidden(true)
            }
        }
    }

    private var resetLink: some View {
        Button {
            isConfirmingReset = true
        } label: {
            Label("Super Cache 초기화", interfaceSystemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .font(.ui(.footnote))
        .foregroundStyle(PorcelainMetrics.secondary)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(statistics.fileCount == 0 && statistics.lifetimeNetworkBytes == 0)
    }

    private var vaultRemovalLink: some View {
        Button(role: .destructive) {
            isConfirmingVaultRemoval = true
        } label: {
            if isRemovingVault {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label("선택 폴더 NAS Vault 삭제", interfaceSystemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.ui(.footnote))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selection == nil || isRemovingVault || preheater.isRunning)
    }

    private var hasWiFi: Bool {
        _ = eligibilityVersion
        return ThumbnailNetworkMonitor.shared.isUnmeteredWiFi
    }

    private var hasExternalPower: Bool {
        _ = eligibilityVersion
        return ThumbnailRuntimePolicy.hasExternalPower(
            batteryState: UIDevice.current.batteryState
        )
    }

    private var canStart: Bool {
        selection != nil
            && (hasStandardConditions || compactJobAssessment != nil)
            && !isAssessingCompactJob
            && !preheater.isRunning
            && !preheater.isCancellationRequested
    }

    private var hasStandardConditions: Bool {
        hasWiFi && hasExternalPower
    }

    private var hiddenStartGestureAvailable: Bool {
        selection != nil
            && !hasStandardConditions
            && compactJobAssessment == nil
            && !isAssessingCompactJob
            && !isPreparing
            && !preheater.isRunning
            && !preheater.isCancellationRequested
    }

    private var usesCompactOverride: Bool {
        !hasStandardConditions && compactJobAssessment != nil
    }

    private var requirementSummary: String {
        if selection == nil { return "먼저 처리할 폴더를 선택하세요." }
        if hasStandardConditions { return "시작할 준비가 됐습니다." }
        if let remaining = SuperThumbnailHiddenStartPolicy.remainingTapCount(
            after: hiddenStartTapCount
        ) {
            return "제한 없이 시작하려면 \(remaining)번 더 누르세요."
        }
        if let compactJobAssessment {
            return "소규모 작업 · 미디어 \(compactJobAssessment.mediaCount)개 · "
                + formatted(compactJobAssessment.totalBytes)
        }
        if isAssessingCompactJob { return "폴더를 확인하고 있습니다." }
        return "Wi‑Fi 연결과 충전을 기다립니다."
    }

    private var startButtonTitle: String {
        if usesCompactOverride { return "소규모 작업 시작" }
        return hasPendingSession ? "미완료 작업 이어서 하기" : "시작"
    }

    private var primaryInk: Color {
        Color.primary
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { preparationError != nil },
            set: { if !$0 { preparationError = nil } }
        )
    }

    private var vaultResultBinding: Binding<Bool> {
        Binding(
            get: { vaultResultMessage != nil },
            set: { if !$0 { vaultResultMessage = nil } }
        )
    }

    private func startProcessing() {
        guard let selection, canStart else { return }
        hiddenStartTapCount = 0
        launchProcessing(
            selection: selection,
            allowsConstrainedRun: usesCompactOverride,
            resumeExistingVault: hasPendingSession
        )
    }

    private func registerHiddenStartTap() {
        guard let selection, hiddenStartGestureAvailable else {
            hiddenStartTapCount = 0
            return
        }
        hiddenStartTapCount += 1
        if hiddenStartTapCount >= SuperThumbnailHiddenStartPolicy.requiredTapCount {
            hiddenStartTapCount = 0
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            launchProcessing(
                selection: selection,
                allowsConstrainedRun: true,
                resumeExistingVault: hasPendingSession
            )
        } else if hiddenStartTapCount >= SuperThumbnailHiddenStartPolicy.visibleCountdownStart {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func removeSelectedVaults() {
        guard let selection else { return }
        isRemovingVault = true
        Task {
            defer { isRemovingVault = false }
            do {
                let credential = try connectionStore.credential(for: selection.connection)
                let service = RemoteFileServiceFactory.make(
                    connection: selection.connection,
                    credential: credential
                )
                let removed = try await SuperThumbnailVault.shared.removeVaults(
                    startingAt: selection.path,
                    service: service
                )
                vaultResultMessage = removed == 0
                    ? "삭제할 NAS 보관본이 없습니다."
                    : "NAS 보관본 \(removed)개를 삭제했습니다. 이 아이폰의 캐시는 유지됩니다."
            } catch {
                vaultResultMessage = "NAS 보관본을 삭제하지 못했습니다. \(error.localizedDescription)"
            }
        }
    }

    private func launchProcessing(
        selection: SuperThumbnailSelection,
        allowsConstrainedRun: Bool,
        resumeExistingVault: Bool = false
    ) {
        isPreparing = true
        hasPendingSession = true
        Task {
            defer { isPreparing = false }
            do {
                let credential = try connectionStore.credential(
                    for: selection.connection
                )
                let service = RemoteFileServiceFactory.make(
                    connection: selection.connection,
                    credential: credential
                )
                let savedReport = resumeExistingVault
                    ? await SuperThumbnailQueueStore.shared.report(
                        sessionKey: selection.id
                    )
                    : nil
                let savedResumeItems = resumeExistingVault
                    ? await SuperThumbnailQueueStore.shared.resumeItems(
                        sessionKey: selection.id,
                        connectionID: selection.connection.id
                    )
                    : []
                let resumesSavedItems = !savedResumeItems.isEmpty
                let items = resumesSavedItems
                    ? savedResumeItems
                    : try await service.list(directory: selection.path)
                        .filter {
                            RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name)
                        }
                let runScope = SuperThumbnailMediaScope.videosAndPhotos
                let shouldUseVault = nasVaultEnabled
                    || savedReport?.vaultFolders.isEmpty == false
                if shouldUseVault != nasVaultEnabled {
                    nasVaultEnabled = shouldUseVault
                }
                isShowingProgress = true
                preheater.start(
                    rootItems: items,
                    rootPath: selection.path,
                    recursively: !resumesSavedItems,
                    requiresExternalPower: true,
                    allowsConstrainedRun: allowsConstrainedRun,
                    generationMode: .completeFile,
                    mediaScope: runScope,
                    preservesUnobservedSessionItems: resumesSavedItems,
                    vaultOptions: SuperThumbnailVaultOptions(
                        isEnabled: shouldUseVault,
                        timing: vaultTiming
                    ),
                    service: service
                )
            } catch {
                preparationError = error.localizedDescription
            }
        }
    }

    private func resumePreviousWork(_ resumeSelection: SuperThumbnailSelection) {
        selection = resumeSelection
        saveSelection(resumeSelection)
        hasPendingSession = true
        guard hasStandardConditions else {
            assessCompactJob(for: resumeSelection)
            preparationError = "Wi‑Fi 연결과 충전을 기다립니다."
            return
        }
        launchProcessing(
            selection: resumeSelection,
            allowsConstrainedRun: false,
            resumeExistingVault: true
        )
    }

    private func selectPreviousFolder(
        _ previousSelection: SuperThumbnailSelection
    ) {
        selection = previousSelection
        saveSelection(previousSelection)
        assessCompactJob(for: previousSelection)
    }

    private func saveSelection(_ selection: SuperThumbnailSelection) {
        // 프라이버시 모드이거나 비공개 연결이면 마지막/최근 위치를 새로 기록하지 않는다(기존 값은 그대로 둔다).
        guard !PrivacyMode.currentlyActive, selection.connection.isPrivate != true else { return }
        let isDifferent = lastConnectionID != selection.connection.id.uuidString
            || lastPath != selection.path
        if isDifferent, !lastConnectionID.isEmpty, !lastPath.isEmpty {
            previousConnectionID = lastConnectionID
            previousPath = lastPath
            previousTitle = lastTitle
        }
        lastConnectionID = selection.connection.id.uuidString
        lastPath = selection.path
        lastTitle = selection.title

        let selectedEntry = SuperThumbnailHistoryEntry(
            connectionID: selection.connection.id.uuidString,
            path: selection.path,
            title: selection.title
        )
        var entries = decodedHistoryEntries.filter {
            $0.connectionID != selectedEntry.connectionID || $0.path != selectedEntry.path
        }
        entries.insert(selectedEntry, at: 0)
        if let encoded = try? JSONEncoder().encode(Array(entries.prefix(10))),
           let json = String(data: encoded, encoding: .utf8) {
            folderHistoryJSON = json
        }
    }

    private func removeHistorySelection(_ selection: SuperThumbnailSelection) {
        let connectionID = selection.connection.id.uuidString
        let entries = decodedHistoryEntries.filter {
            $0.connectionID != connectionID || $0.path != selection.path
        }
        if let encoded = try? JSONEncoder().encode(entries),
           let json = String(data: encoded, encoding: .utf8) {
            folderHistoryJSON = json
        }
        if lastConnectionID == connectionID, lastPath == selection.path {
            lastConnectionID = ""
            lastPath = ""
            lastTitle = ""
        }
        if previousConnectionID == connectionID, previousPath == selection.path {
            previousConnectionID = ""
            previousPath = ""
            previousTitle = ""
        }
    }

    private func assessCompactJob(for selection: SuperThumbnailSelection) {
        compactJobAssessment = nil
        isAssessingCompactJob = true
        let assessmentID = UUID()
        compactAssessmentID = assessmentID
        Task {
            defer {
                if compactAssessmentID == assessmentID {
                    isAssessingCompactJob = false
                }
            }
            do {
                let credential = try connectionStore.credential(for: selection.connection)
                let service = RemoteFileServiceFactory.make(
                    connection: selection.connection,
                    credential: credential
                )
                var pendingPaths = [selection.path]
                var visitedPaths = Set<String>()
                var mediaCount = 0
                var totalBytes: Int64 = 0
                let maximumBytes: Int64 = 1_024 * 1_024 * 1_024

                while let path = pendingPaths.first {
                    pendingPaths.removeFirst()
                    guard visitedPaths.insert(path).inserted else { continue }
                    let children = try await service.list(directory: path)
                        .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
                    pendingPaths.append(contentsOf: children.filter(\.isDirectory).map(\.path))
                    for item in children where item.isVideo || item.isImage {
                        guard let size = item.size, size >= 0 else { return }
                        mediaCount += 1
                        totalBytes += size
                        guard mediaCount < 20, totalBytes <= maximumBytes else { return }
                    }
                }
                guard compactAssessmentID == assessmentID,
                      selection == self.selection,
                      mediaCount > 0 else { return }
                compactJobAssessment = CompactJobAssessment(
                    mediaCount: mediaCount,
                    totalBytes: totalBytes
                )
            } catch {
                // Standard Wi-Fi + Power processing remains available.
            }
        }
    }

    private var historySelections: [SuperThumbnailSelection] {
        let saved = decodedHistoryEntries.map {
            storedSelection(
                connectionID: $0.connectionID,
                path: $0.path,
                title: $0.title
            )
        }
        let legacy = [
            storedSelection(
                connectionID: lastConnectionID,
                path: lastPath,
                title: lastTitle
            ),
            storedSelection(
                connectionID: previousConnectionID,
                path: previousPath,
                title: previousTitle
            ),
        ]
        return (saved + legacy)
        .compactMap { $0 }
        .reduce(into: [SuperThumbnailSelection]()) { result, candidate in
            guard result.count < 10, !result.contains(candidate) else { return }
            result.append(candidate)
        }
    }

    private var decodedHistoryEntries: [SuperThumbnailHistoryEntry] {
        guard let data = folderHistoryJSON.data(using: .utf8),
              let entries = try? JSONDecoder().decode(
                  [SuperThumbnailHistoryEntry].self,
                  from: data
              ) else { return [] }
        return Array(entries.prefix(10))
    }

    private func storedSelection(
        connectionID: String,
        path: String,
        title: String
    ) -> SuperThumbnailSelection? {
        guard !connectionID.isEmpty,
              !path.isEmpty,
              let connection = connectionStore.connections.first(where: {
                  $0.id.uuidString == connectionID
              }) else { return nil }
        return SuperThumbnailSelection(
            connection: connection,
            path: path,
            title: title.isEmpty ? (path as NSString).lastPathComponent : title
        )
    }

    @MainActor
    private func refreshStatistics() async {
        statistics = await SuperThumbnailCache.shared.statistics()
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

private struct SuperThumbnailReportView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: SuperThumbnailSelection
    let onSelect: () -> Void
    let onResume: () -> Void
    @State private var report: SuperThumbnailSessionReport?
    @State private var isLoading = true
    @State private var isStageDetailExpanded = false
    @State private var isVaultDetailExpanded = false
    @State private var isFailureDetailExpanded = false
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        ScrollView {
            VStack(alignment: .leading, spacing: ui(16)) {
                HStack(spacing: ui(10)) {
                    SuperThumbnailMark(compact: true)
                    VStack(alignment: .leading, spacing: ui(2)) {
                        Text("작업 보고서")
                            .font(.ui(.headline).weight(.medium))
                        Label(selection.title, interfaceSystemImage: "folder.fill")
                            .font(.ui(.caption))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .lineLimit(1)
                        Text(selection.path)
                            .font(.ui(.caption2))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let report {
                    reportHeadline(report)
                    reportActions(report)
                    DisclosureGroup("처리 단계 상세", isExpanded: $isStageDetailExpanded) {
                        reportSummary(report)
                            .padding(.top, ui(8))
                    }
                    if !report.vaultFolders.isEmpty {
                        DisclosureGroup("NAS 보관 상세", isExpanded: $isVaultDetailExpanded) {
                            vaultSummary(report)
                                .padding(.top, ui(8))
                        }
                    }
                    if !report.failures.isEmpty {
                        DisclosureGroup("미완료 파일 \(report.failures.count)개", isExpanded: $isFailureDetailExpanded) {
                            failureSummary(report.failures)
                                .padding(.top, ui(8))
                        }
                    }
                } else if isLoading {
                    ProgressView("보고서 불러오는 중…")
                        .frame(maxWidth: .infinity, minHeight: ui(180))
                } else {
                    ContentUnavailableView(
                        "저장된 보고서 없음",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("이 폴더의 Super Thumbnail 기록이 없습니다.")
                    )
                    selectFolderButton
                }
            }
            .padding(ui(18))
        }
        .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
        .navigationTitle("Super Thumbnail")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selection.id) {
            isLoading = true
            report = await SuperThumbnailQueueStore.shared.report(
                sessionKey: selection.id
            )
            isLoading = false
        }
    }

    @ViewBuilder
    private func reportActions(_ report: SuperThumbnailSessionReport) -> some View {
        VStack(spacing: ui(10)) {
            if report.hasWorkToResume {
                Button {
                    dismiss()
                    onResume()
                } label: {
                    Label("미완료 작업 이어서 하기", interfaceSystemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: ui(54))
                }
                .buttonStyle(PorcelainProminentButtonStyle(cornerRadius: 14))
            }
            selectFolderButton
        }
    }

    private var selectFolderButton: some View {
        Button {
            dismiss()
            onSelect()
        } label: {
            Label("이 폴더 다시 선택", interfaceSystemImage: "folder.badge.checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func reportHeadline(_ report: SuperThumbnailSessionReport) -> some View {
        let incompleteCount = report.pendingCount
            + report.vaultPendingCount
            + report.vaultFailedCount
        let lastVerifiedText = report.vaultLastVerifiedAt.map {
            " · 마지막 확인 \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? ""
        return VStack(alignment: .leading, spacing: ui(5)) {
            Text(incompleteCount > 0 ? "미완료 \(incompleteCount)개" : "모두 완료")
                .font(.system(size: ui(24), weight: .semibold))
                .foregroundStyle(.primary)
            Text(
                "실패 \(report.failures.count) · 업로드 대기 \(report.vaultPendingCount + report.vaultFailedCount)"
                    + lastVerifiedText
            )
            .font(.system(size: ui(13)))
            .foregroundStyle(PorcelainMetrics.secondary)
            Text("이어하기 순서 · 실패한 썸네일 → 업로드 대기 → 신규·변경 → 전체 확인")
                .font(.ui(.caption))
                .foregroundStyle(PorcelainMetrics.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ui(16))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(16), style: .continuous)
        )
    }

    private func reportSummary(
        _ report: SuperThumbnailSessionReport
    ) -> some View {
        VStack(alignment: .leading, spacing: ui(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text("총계")
                    .font(.ui(.subheadline))
                    .foregroundStyle(PorcelainMetrics.secondary)
                Spacer()
                Text("\(report.totalCount)개")
                    .font(.ui(.title3).monospacedDigit())
            }
            if report.cachedCount > 0 {
                HStack {
                    Text("이미 완료")
                    Spacer()
                    Text("\(report.cachedCount)개")
                }
                .font(.ui(.caption))
                .foregroundStyle(PorcelainMetrics.secondary)
            }
            if report.photoSuccessCount > 0 {
                HStack {
                    Text("사진 미리보기")
                    Spacer()
                    Text("성공 \(report.photoSuccessCount)개")
                }
                .font(.ui(.caption))
                .foregroundStyle(PorcelainMetrics.secondary)
            }
            Divider()
            stageRow(
                seconds: 5,
                success: count(report.successCounts, at: 0),
                remaining: count(report.remainingCounts, at: 0)
            )
            stageRow(
                seconds: 20,
                success: count(report.successCounts, at: 1),
                remaining: count(report.remainingCounts, at: 1)
            )
            stageRow(
                seconds: 40,
                success: count(report.successCounts, at: 2),
                remaining: count(report.remainingCounts, at: 2)
            )
        }
        .padding(ui(15))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(16), style: .continuous)
        )
    }

    private func stageRow(
        seconds: Int,
        success: Int,
        remaining: Int
    ) -> some View {
        HStack {
            Text("\(seconds)초")
                .font(.ui(.subheadline).monospacedDigit().weight(.medium))
            Spacer()
            Text("시도 \(success + remaining)")
            Text("성공 \(success)")
        }
        .font(.ui(.caption).monospacedDigit())
    }

    private func vaultSummary(
        _ report: SuperThumbnailSessionReport
    ) -> some View {
        VStack(alignment: .leading, spacing: ui(11)) {
            HStack {
                Label("NAS Vault", interfaceSystemImage: "externaldrive.fill")
                    .font(.ui(.subheadline).weight(.medium))
                Spacer()
                Text("보관 \(report.vaultUploadedCount) · 대기 \(report.vaultPendingCount) · 실패 \(report.vaultFailedCount)")
                    .font(.ui(.caption).monospacedDigit())
                    .foregroundStyle(PorcelainMetrics.secondary)
            }
            Text(
                "이어하기 순서 · 생성 실패 \(report.failures.count) → "
                    + "업로드 미완료 \(report.vaultPendingCount + report.vaultFailedCount) → "
                    + "신규·변경 \(max(report.pendingCount - report.failures.count, 0)) → 전체 확인"
            )
            .font(.ui(.caption))
            .foregroundStyle(PorcelainMetrics.secondary)

            ForEach(report.vaultFolders) { folder in
                Divider()
                VStack(alignment: .leading, spacing: ui(4)) {
                    Text((folder.path as NSString).lastPathComponent.isEmpty
                        ? folder.path
                        : (folder.path as NSString).lastPathComponent)
                        .font(.ui(.caption).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: ui(10)) {
                        Text("보관 \(folder.uploadedCount)/\(folder.totalCount)")
                        if folder.waitingThumbnailCount > 0 {
                            Text("생성 대기 \(folder.waitingThumbnailCount)")
                        }
                        if folder.pendingCount > 0 {
                            Text("업로드 대기 \(folder.pendingCount)")
                        }
                        if folder.failedCount > 0 {
                            Text("실패 \(folder.failedCount)")
                        }
                    }
                    .font(.ui(.caption2).monospacedDigit())
                    .foregroundStyle(PorcelainMetrics.secondary)
                    if let errorDescription = folder.errorDescription {
                        Text(errorDescription)
                            .font(.ui(.caption2))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if let verifiedAt = report.vaultLastVerifiedAt {
                Text("마지막 전체 확인 · \(verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.ui(.caption2))
                    .foregroundStyle(PorcelainMetrics.secondary)
            }
        }
        .padding(ui(15))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(16), style: .continuous)
        )
    }

    private func failureSummary(
        _ failures: [SuperThumbnailFailureRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            Text("미완료 파일")
                .font(.ui(.subheadline).weight(.medium))
            ForEach(failures) { failure in
                VStack(alignment: .leading, spacing: ui(5)) {
                    Text(failure.name)
                        .font(.ui(.caption))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: ui(8)) {
                        Text(failure.fileExtension.isEmpty ? "기타" : failure.fileExtension)
                        Text(failure.fileSize.map(formattedBytes) ?? "크기 미상")
                        Text(failure.durationSeconds.map(formattedDuration) ?? "길이 미상")
                    }
                    .font(.ui(.caption2).monospacedDigit())
                    .foregroundStyle(PorcelainMetrics.secondary)
                    Text(failure.reason)
                        .font(.ui(.caption2))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .lineLimit(2)
                }
                if failure.id != failures.last?.id { Divider() }
            }
        }
        .padding(ui(15))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(16), style: .continuous)
        )
    }

    private func count(_ values: [Int], at index: Int) -> Int {
        values.indices.contains(index) ? values[index] : 0
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        return String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3_600,
            (totalSeconds % 3_600) / 60,
            totalSeconds % 60
        )
    }
}

private struct SuperThumbnailProgressView: View {
    @ObservedObject var preheater: ThumbnailPreheater
    let folderTitle: String
    let sessionKey: String
    let onCancel: () -> Void
    let onClose: () -> Void
    @State private var isOverflowExpanded = true
    @State private var isFailurePanelExpanded = false
    @State private var isDetailsExpanded = false
    @State private var vaultReport: SuperThumbnailSessionReport?
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        NavigationStack {
            ScrollView {
                VStack(spacing: ui(14)) {
                    HStack(spacing: ui(9)) {
                        SuperThumbnailMark(compact: true)
                        Text(progressTitle)
                            .font(.system(size: ui(17), weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: ui(7)) {
                        Image(interfaceSystemName: "folder.fill", pointSize: 12)
                            .font(.ui(.caption))
                            .foregroundStyle(SkyBreezeTheme.folderBlue.opacity(0.78))
                        Text(folderTitle)
                            .font(.ui(.subheadline))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    if let pauseReason = preheater.pauseReason {
                        Text(pauseReason)
                            .font(.ui(.caption))
                            .foregroundStyle(PorcelainMetrics.warn)
                            .multilineTextAlignment(.center)
                    }

                    if let errorMessage = preheater.errorMessage {
                        Label(errorMessage, interfaceSystemImage: "exclamationmark.triangle.fill")
                            .font(.ui(.callout))
                            .foregroundStyle(PorcelainMetrics.danger)
                            .multilineTextAlignment(.center)
                            .padding(ui(14))
                            .frame(maxWidth: .infinity)
                            .background(
                                PorcelainMetrics.danger.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: ui(14), style: .continuous)
                            )
                    }

                    overallProgressPanel
                    currentFilenameRow
                    currentItemWaitPanel(startedAt: preheater.currentItemStartedAt)
                    HStack(spacing: ui(18)) {
                        progressMetric("완료", preheater.generatedCount)
                        progressMetric("건너뜀", preheater.cachedCount)
                        progressMetric("실패", preheater.failedCount)
                    }
                    if preheater.vaultRestoredCount > 0
                        || preheater.vaultStoredCount > 0
                        || preheater.vaultPendingCount > 0
                        || preheater.vaultFailedCount > 0 {
                        Text("NAS 보관 \(preheater.vaultStoredCount)/\(preheater.generatedCount + preheater.cachedCount) · 대기 \(preheater.vaultPendingCount)")
                        .font(.ui(.caption).monospacedDigit())
                        .foregroundStyle(PorcelainMetrics.secondary)
                    }
                    if let vaultErrorMessage = preheater.vaultErrorMessage {
                        Text("NAS 보관 대기 · \(vaultErrorMessage)")
                            .font(.ui(.caption))
                            .foregroundStyle(PorcelainMetrics.warn)
                            .multilineTextAlignment(.center)
                    }
                    DisclosureGroup("세부 정보", isExpanded: $isDetailsExpanded) {
                        VStack(spacing: ui(10)) {
                            if let workPhase = preheater.workPhase {
                                Text(workPhase)
                                    .font(.ui(.caption))
                                    .foregroundStyle(PorcelainMetrics.secondary)
                            }
                            etaPanel
                            if let verifiedAt = preheater.vaultLastVerifiedAt {
                                Text("NAS 전체 확인 · \(verifiedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.ui(.caption2))
                                    .foregroundStyle(PorcelainMetrics.secondary)
                            }
                            if !preheater.recentGeneratedThumbnails.isEmpty {
                                overflowPanel
                            }
                            if preheater.isRunning, preheater.failedCount > 0 {
                                failurePanel
                            }
                            Text("세션 네트워크 · " + formattedProgressBytes(preheater.transferredBytes + preheater.currentItemTransferredBytes))
                                .font(.ui(.footnote).monospacedDigit())
                                .foregroundStyle(PorcelainMetrics.secondary)
                        }
                        .padding(.top, ui(10))
                    }
                    .font(.ui(.subheadline))
                    .foregroundStyle(PorcelainMetrics.secondary)

                    if !preheater.isRunning, preheater.totalCount > 0 {
                        completionReportPanel
                    }
                }
                .padding(.horizontal, ui(22))
                .padding(.top, ui(20))
                .padding(.bottom, ui(26))
            }
            .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Group {
                    if preheater.isRunning {
                        Button(role: .destructive, action: onCancel) {
                            HStack(spacing: ui(8)) {
                                if preheater.isCancellationRequested {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(
                                    preheater.isCancellationRequested
                                        ? "중단하는 중…"
                                        : "작업 중단"
                                )
                            }
                                .font(.ui(.subheadline).weight(.medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: ui(54))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .disabled(preheater.isCancellationRequested)
                    } else {
                        Button(action: onClose) {
                            Text(preheater.errorMessage == nil ? "완료" : "닫기")
                                .frame(maxWidth: .infinity)
                                .frame(height: ui(54))
                        }
                        .buttonStyle(PorcelainProminentButtonStyle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, ui(24))
                .padding(.vertical, ui(12))
                .background(.ultraThinMaterial)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: preheater.isRunning) {
                guard !preheater.isRunning, !sessionKey.isEmpty else { return }
                vaultReport = await SuperThumbnailQueueStore.shared.report(
                    sessionKey: sessionKey
                )
            }
        }
    }

    private var progressTitle: String {
        if preheater.isRunning { return "썸네일 만드는 중" }
        if preheater.errorMessage != nil { return "처리하지 못했습니다" }
        return "처리 완료"
    }

    private var overallProgressPanel: some View {
        VStack(spacing: ui(9)) {
            Text("\(preheater.completedCount) / \(preheater.totalCount)")
                .font(.system(size: ui(28), weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            ProgressView(value: preheater.fractionCompleted ?? 0)
                .progressViewStyle(.linear)
                .tint(PorcelainMetrics.accent.opacity(0.72))
                .frame(height: ui(6))
        }
        .padding(ui(16))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(15), style: .continuous)
        )
    }

    private var currentFilenameRow: some View {
        let filename = preheater.currentItemName ?? "처리 준비 중"
        let fileExtension = (filename as NSString).pathExtension
        let stem = fileExtension.isEmpty
            ? filename
            : (filename as NSString).deletingPathExtension

        return HStack(spacing: 0) {
            Text(stem)
                .lineLimit(1)
                .truncationMode(.tail)
            if !fileExtension.isEmpty {
                Text(".\(fileExtension)")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: ui(38), maxHeight: ui(38))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(filename)
    }

    private func progressMetric(_ title: String, _ value: Int) -> some View {
        VStack(spacing: ui(3)) {
            Text("\(value)")
                .font(.ui(.headline).monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
            Text(title).font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.secondary)
        }
    }

    private var etaPanel: some View {
        HStack(spacing: ui(12)) {
            Image(interfaceSystemName: "clock")
                .foregroundStyle(PorcelainMetrics.accent)
            Text("남은 시간")
                .font(.ui(.subheadline))
                .foregroundStyle(PorcelainMetrics.secondary)
            Spacer()
            Text(formattedETA)
                .font(.ui(.headline).monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(ui(14))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(16), style: .continuous)
        )
    }

    private var coverFlow: some View {
        HStack(alignment: .bottom, spacing: ui(-8)) {
            ForEach(
                Array(latestThumbnails.prefix(5).enumerated()),
                id: \.element.id
            ) { index, preview in
                if let image = UIImage(data: preview.data) {
                    SuperThumbnailCoverCard(
                        image: image,
                        filename: preview.name,
                        index: index,
                        totalCount: min(latestThumbnails.count, 5)
                    )
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ui(4))
        .padding(.vertical, ui(8))
        .animation(
            .spring(response: 0.42, dampingFraction: 0.86),
            value: preheater.recentGeneratedThumbnails.count
        )
    }

    private var overflowPanel: some View {
        VStack(spacing: ui(6)) {
            HStack(spacing: ui(7)) {
                Image(interfaceSystemName: "rectangle.stack")
                Text("미리보기")
                Spacer()
                Image(
                    systemName: isOverflowExpanded
                        ? "chevron.up"
                        : "chevron.down"
                )
            }
            .font(.ui(.caption).weight(.medium))
            .foregroundStyle(PorcelainMetrics.secondary)

            if isOverflowExpanded {
                coverFlow
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        )
                    )
            }
        }
        .padding(.horizontal, ui(12))
        .padding(.vertical, ui(isOverflowExpanded ? 10 : 9))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(14), style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) {
                isOverflowExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("미리보기")
        .accessibilityHint(
            isOverflowExpanded ? "탭하여 숨기기" : "탭하여 보기"
        )
        .accessibilityAddTraits(.isButton)
    }

    private var failurePanel: some View {
        VStack(alignment: .leading, spacing: ui(7)) {
            HStack(spacing: ui(7)) {
                Image(interfaceSystemName: "exclamationmark.triangle")
                Text("실패 \(preheater.failedCount)건")
                Spacer()
                Image(
                    systemName: isFailurePanelExpanded
                        ? "chevron.up"
                        : "chevron.down"
                )
            }
            .font(.ui(.caption).weight(.medium))
            .foregroundStyle(PorcelainMetrics.warn)

            if isFailurePanelExpanded {
                ForEach(preheater.failedItemNames, id: \.self) { detail in
                    Text(detail)
                        .font(.ui(.caption2))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ui(11))
        .background(
            PorcelainMetrics.warn.opacity(0.07),
            in: RoundedRectangle(cornerRadius: ui(13), style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFailurePanelExpanded.toggle()
            }
        }
        .accessibilityAddTraits(.isButton)
    }

    private var latestThumbnails: [GeneratedThumbnailPreview] {
        Array(preheater.recentGeneratedThumbnails.reversed())
    }

    private var formattedETA: String {
        guard let seconds = preheater.estimatedTimeRemaining else {
            return "계산 중…"
        }
        if seconds <= 0 { return "거의 완료" }
        let minutes = max(Int(ceil(seconds / 60)), 1)
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours)시간"
            : "\(hours)시간 \(remainingMinutes)분"
    }

    private var currentItemTransferText: String {
        let current = formattedRangeMegabytes(
            preheater.currentItemTransferredBytes
        )
        let total = formattedRangeMegabytes(preheater.currentItemTotalBytes)
        return preheater.currentItemIsPhoto
            ? "미리보기 \(current) / \(total)"
            : "범위 \(current) / \(total)"
    }

    private func formattedRangeMegabytes(_ bytes: Int64) -> String {
        String(
            format: "%.1f MB",
            Double(max(bytes, 0)) / Double(1_024 * 1_024)
        )
    }

    private func formattedProgressBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    private func currentItemWaitPanel(startedAt: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = startedAt.map {
                max(context.date.timeIntervalSince($0), 0)
            } ?? 0
            let limit = max(preheater.currentItemTimeLimit, 1)
            let remaining = preheater.isRunning
                ? max(Int(ceil(limit - elapsed)), 0)
                : 0
            VStack(spacing: ui(6)) {
                HStack {
                    Text(preheater.isRunning ? currentPassTitle : statusTitle)
                    Spacer()
                    Text(String(format: "%02ds 남음", remaining))
                }
                .font(.ui(.caption2).monospacedDigit())
                .foregroundStyle(PorcelainMetrics.secondary)
                ProgressView(
                    value: preheater.isRunning ? min(elapsed / limit, 1) : 1
                )
                    .progressViewStyle(.linear)
                    .tint(PorcelainMetrics.accent.opacity(0.72))
                Text(currentItemTransferText)
                    .font(.ui(.caption2).monospacedDigit())
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, ui(12))
            .padding(.vertical, ui(10))
            .frame(maxWidth: .infinity, minHeight: ui(76), maxHeight: ui(76))
            .background(
                PorcelainMetrics.accent.opacity(0.045),
                in: RoundedRectangle(cornerRadius: ui(12), style: .continuous)
            )
        }
    }

    private var currentPassTitle: String {
        if preheater.currentItemIsPhoto { return "사진 미리보기" }
        switch preheater.currentItemAttempt {
        case 0: return "빠른 처리"
        case 1: return "재시도"
        default: return "최종 복구"
        }
    }

    private var completionReportPanel: some View {
        VStack(alignment: .leading, spacing: ui(14)) {
            Text("처리 결과")
                .font(.ui(.subheadline).weight(.medium))
                .foregroundStyle(.primary)

            VStack(spacing: ui(10)) {
                HStack(alignment: .firstTextBaseline) {
                    Text("총계")
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                    Spacer()
                    Text("\(preheater.totalCount)개")
                        .font(.ui(.title3).monospacedDigit().weight(.regular))
                        .foregroundStyle(.primary)
                }
                Divider().opacity(0.65)
                if preheater.photoSuccessCount > 0 {
                    HStack {
                        Text("사진 미리보기")
                            .foregroundStyle(PorcelainMetrics.secondary)
                        Spacer()
                        Text("성공 \(preheater.photoSuccessCount)")
                            .monospacedDigit()
                    }
                    .font(.ui(.caption))
                }
                HStack(spacing: 0) {
                    stageMetric(
                        seconds: 5,
                        success: normalizedSuccessCounts[0],
                        remaining: completionRemainingCounts[0]
                    )
                    stageMetric(
                        seconds: 20,
                        success: normalizedSuccessCounts[1],
                        remaining: completionRemainingCounts[1]
                    )
                    stageMetric(
                        seconds: 40,
                        success: normalizedSuccessCounts[2],
                        remaining: completionRemainingCounts[2]
                    )
                }
            }
            .padding(ui(12))
            .background(
                PorcelainMetrics.accent.opacity(0.035),
                in: RoundedRectangle(cornerRadius: ui(12), style: .continuous)
            )

            if let vaultReport, !vaultReport.vaultFolders.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: ui(9)) {
                    HStack {
                        Label("NAS Vault", interfaceSystemImage: "externaldrive.fill")
                            .font(.ui(.caption).weight(.medium))
                        Spacer()
                        Text(
                            "보관 \(vaultReport.vaultUploadedCount) · "
                                + "대기 \(vaultReport.vaultPendingCount) · "
                                + "실패 \(vaultReport.vaultFailedCount)"
                        )
                        .font(.ui(.caption2).monospacedDigit())
                        .foregroundStyle(PorcelainMetrics.secondary)
                    }
                    ForEach(vaultReport.vaultFolders) { folder in
                        HStack(spacing: ui(8)) {
                            Text((folder.path as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(folder.uploadedCount)/\(folder.totalCount)")
                            if folder.pendingCount > 0 {
                                Text("대기 \(folder.pendingCount)")
                            }
                            if folder.failedCount > 0 {
                                Text("실패 \(folder.failedCount)")
                            }
                        }
                        .font(.ui(.caption2).monospacedDigit())
                        .foregroundStyle(PorcelainMetrics.secondary)
                    }
                    if let verifiedAt = vaultReport.vaultLastVerifiedAt {
                        Text(
                            "마지막 전체 확인 · "
                                + verifiedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        .font(.ui(.caption2))
                        .foregroundStyle(PorcelainMetrics.secondary)
                    }
                }
            }

            if !preheater.failedItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: ui(5)) {
                    Text("실패 요약")
                        .font(.ui(.subheadline).weight(.medium))
                        .foregroundStyle(.orange.opacity(0.88))
                    Text(failureSummaryText)
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
                failureTable
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ui(14))
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: ui(15), style: .continuous)
        )
    }

    private func stageMetric(
        seconds: Int,
        success: Int,
        remaining: Int
    ) -> some View {
        VStack(spacing: ui(3)) {
            Text("\(seconds)초")
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
            Text("시도 \(success + remaining)")
                .font(.ui(.caption2).monospacedDigit())
                .foregroundStyle(PorcelainMetrics.secondary)
            Text("성공 \(success)")
                .font(.ui(.subheadline).monospacedDigit().weight(.regular))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private var normalizedSuccessCounts: [Int] {
        (0..<3).map { index in
            preheater.successAttemptCounts.indices.contains(index)
                ? preheater.successAttemptCounts[index]
                : 0
        }
    }

    private var completionRemainingCounts: [Int] {
        let unresolved = max(
            preheater.totalCount
                - preheater.cachedCount
                - preheater.photoSuccessCount
                - normalizedSuccessCounts.reduce(0, +),
            0
        )
        return [
            normalizedSuccessCounts[1] + normalizedSuccessCounts[2] + unresolved,
            normalizedSuccessCounts[2] + unresolved,
            unresolved,
        ]
    }

    private var failureSummaryText: String {
        let typeCounts = Dictionary(grouping: preheater.failedItems) {
            $0.fileExtension.isEmpty ? "기타" : $0.fileExtension
        }
        let types = typeCounts.keys.sorted().map {
            "\($0) \(typeCounts[$0]?.count ?? 0)개"
        }.joined(separator: " · ")
        let durations = preheater.failedItems.compactMap(\.durationSeconds)
        let durationText: String
        if let minimum = durations.min(), let maximum = durations.max() {
            durationText = minimum == maximum
                ? "길이 \(formattedDuration(minimum))"
                : "길이 \(formattedDuration(minimum))–\(formattedDuration(maximum))"
        } else {
            durationText = "영상 길이 확인 불가"
        }
        return "종류: \(types) · \(durationText)"
    }

    private var failureTable: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    failureCell("파일 이름", width: ui(220), isHeader: true)
                    failureCell("종류", width: ui(58), isHeader: true)
                    failureCell("크기", width: ui(82), isHeader: true)
                    failureCell("길이", width: ui(70), isHeader: true)
                    failureCell("실패 사유", width: ui(210), isHeader: true)
                }
                ForEach(Array(preheater.failedItems.enumerated()), id: \.element.id) {
                    index, failure in
                    GridRow {
                        failureCell(failure.name, width: ui(220), shaded: index.isMultiple(of: 2))
                        failureCell(
                            failure.fileExtension.isEmpty ? "—" : failure.fileExtension,
                            width: ui(58),
                            shaded: index.isMultiple(of: 2)
                        )
                        failureCell(
                            failure.fileSize.map {
                                formattedProgressBytes($0)
                            } ?? "—",
                            width: ui(82),
                            shaded: index.isMultiple(of: 2)
                        )
                        failureCell(
                            failure.durationSeconds.map {
                                formattedDuration($0)
                            } ?? "—",
                            width: ui(70),
                            shaded: index.isMultiple(of: 2)
                        )
                        failureCell(
                            failure.reason,
                            width: ui(210),
                            shaded: index.isMultiple(of: 2)
                        )
                    }
                }
            }
            .overlay {
                Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
            }
        }
    }

    private func failureCell(
        _ text: String,
        width: CGFloat,
        isHeader: Bool = false,
        shaded: Bool = false
    ) -> some View {
        Text(text)
            .font(isHeader ? .ui(.caption2).weight(.medium) : .ui(.caption2))
            .foregroundStyle(isHeader ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, ui(7))
            .padding(.vertical, ui(7))
            .background(
                isHeader
                    ? Color.secondary.opacity(0.08)
                    : shaded ? Color.secondary.opacity(0.035) : Color.clear
            )
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: ui(0.5))
            }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3_600,
                (total % 3_600) / 60,
                total % 60
            )
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var statusTitle: String {
        if preheater.isRunning { return "Creating Super Thumbnails" }
        if preheater.statusMessage?.contains("중지") == true { return "Processing Stopped" }
        return preheater.failedCount == 0 ? "Processing Complete" : "Completed with Attention"
    }
}

private struct SuperThumbnailCoverCard: View {
    let image: UIImage
    let filename: String
    let index: Int
    let totalCount: Int
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        VStack(spacing: ui(6)) {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: imageWidth, height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ui(8), style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ui(8))
                            .stroke(borderColor, lineWidth: index == 0 ? 1.5 : 1)
                    }
                    .rotation3DEffect(
                        .degrees(index == 0 ? 0 : -Double(index) * 3.2),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .leading
                    )
                    .shadow(
                        color: .black.opacity(index == 0 ? 0.14 : 0.08),
                        radius: index == 0 ? 6 : 3,
                        y: 2
                    )
            }
            .frame(width: titleWidth, height: ui(96), alignment: .bottomLeading)

            Text(filename)
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
                .truncationMode(.tail)
                .frame(width: titleWidth, height: ui(16), alignment: .leading)
        }
        .frame(width: titleWidth, alignment: .leading)
        .zIndex(Double(totalCount - index))
    }

    private var borderColor: Color {
        index == 0 ? PorcelainMetrics.accent.opacity(0.5) : Color.white.opacity(0.72)
    }

    private var widthFactor: CGFloat {
        max(0.6, 1 - CGFloat(index) * 0.1)
    }

    private var imageWidth: CGFloat {
        ui(96) * widthFactor
    }

    private var imageHeight: CGFloat {
        ui(96) * widthFactor
    }

    private var titleWidth: CGFloat {
        max(imageWidth, ui(64))
    }
}

private struct SuperThumbnailFolderPickerView: View {
    let onCancel: () -> Void
    @EnvironmentObject private var connectionStore: ConnectionStore
    let onSelect: (SuperThumbnailSelection) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "연결된 NAS가 없습니다",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("먼저 첫 화면에서 NAS 연결을 추가해 주세요.")
                    )
                } else {
                    List(connectionStore.connections) { connection in
                        NavigationLink {
                            SuperThumbnailConnectionRoot(
                                connection: connection,
                                onSelect: onSelect
                            )
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: ui(2)) {
                                    Text(connection.name).foregroundStyle(.primary)
                                    Text(connection.normalizedRootPath)
                                        .font(.ui(.caption2))
                                        .foregroundStyle(PorcelainMetrics.secondary)
                                }
                            } icon: {
                                Image(interfaceSystemName: connection.kind.systemImage)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(SkyBreezeBackground())
            .navigationTitle("NAS 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Group {
                        Button("취소", action: onCancel)
                    }
                    .uiBarFont()
                }
            }
        }
    }
}

private struct SuperThumbnailConnectionRoot: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var service: (any RemoteFileService)?
    @State private var didResolve = false

    let connection: RemoteConnection
    let onSelect: (SuperThumbnailSelection) -> Void

    var body: some View {
        Group {
            if let service {
                SuperThumbnailFolderBrowser(
                    connection: connection,
                    path: connection.normalizedRootPath,
                    service: service,
                    onSelect: onSelect
                )
            } else if didResolve {
                ContentUnavailableView("로그인 정보가 필요합니다", systemImage: "key.slash")
            } else {
                ProgressView("연결하는 중…")
            }
        }
        .task { resolve() }
    }

    private func resolve() {
        guard !didResolve else { return }
        defer { didResolve = true }
        guard let credential = try? connectionStore.credential(for: connection) else { return }
        service = RemoteFileServiceFactory.make(
            connection: connection,
            credential: credential
        )
    }
}

private struct SuperThumbnailFolderBrowser: View {
    @StateObject private var viewModel: FileBrowserViewModel
    let connection: RemoteConnection
    let service: any RemoteFileService
    let onSelect: (SuperThumbnailSelection) -> Void

    init(
        connection: RemoteConnection,
        path: String,
        service: any RemoteFileService,
        onSelect: @escaping (SuperThumbnailSelection) -> Void
    ) {
        self.connection = connection
        self.service = service
        self.onSelect = onSelect
        _viewModel = StateObject(
            wrappedValue: FileBrowserViewModel(
                connection: connection,
                path: path,
                service: service
            )
        )
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("폴더를 불러오는 중…")
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                ContentUnavailableView(
                    "폴더를 열 수 없습니다",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
            } else {
                List(folders) { folder in
                    NavigationLink {
                        SuperThumbnailFolderBrowser(
                            connection: connection,
                            path: folder.path,
                            service: service,
                            onSelect: onSelect
                        )
                    } label: {
                        Label(folder.name, interfaceSystemImage: "folder.fill")
                            .foregroundStyle(.primary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(SkyBreezeBackground())
            }
        }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                onSelect(
                    SuperThumbnailSelection(
                        connection: connection,
                        path: viewModel.path,
                        title: currentTitle
                    )
                )
            } label: {
                Label("이 폴더 선택", interfaceSystemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PorcelainProminentButtonStyle())
            .controlSize(.large)
            .padding(.all, MacUIScale.defaultPadding)
            .background(.ultraThinMaterial)
        }
        .task { await viewModel.load() }
    }

    private var folders: [RemoteFileItem] {
        viewModel.displayedItems.filter(\.isDirectory)
    }

    private var currentTitle: String {
        let name = (viewModel.path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? connection.name : name
    }
}
