import SwiftUI
import UIKit

struct SuperThumbnailMark: View {
    var compact = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 8 : 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.indigo, Color.blue, Color.cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: compact ? 3 : 8, style: .continuous)
                .fill(.white.opacity(0.16))
                .stroke(.white.opacity(0.88), lineWidth: compact ? 1.1 : 2.4)
                .frame(width: compact ? 19 : 52, height: compact ? 15 : 40)
                .offset(x: compact ? -2 : -6, y: compact ? 2 : 6)

            Image(systemName: "photo.fill")
                .font(.system(size: compact ? 11 : 29, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
                .offset(x: compact ? -2 : -6, y: compact ? 2 : 6)

            Image(systemName: "wand.and.stars")
                .font(.system(size: compact ? 11 : 28, weight: .bold))
                .foregroundStyle(.white, Color.yellow)
                .rotationEffect(.degrees(-14))
                .offset(x: compact ? 7 : 19, y: compact ? -7 : -19)
        }
        .frame(width: compact ? 30 : 82, height: compact ? 30 : 82)
        .shadow(color: Color.blue.opacity(compact ? 0.12 : 0.28), radius: compact ? 3 : 14)
        .accessibilityHidden(true)
    }
}

struct SuperThumbnailLink: View {
    @State private var statistics = SuperThumbnailStatistics.empty

    var body: some View {
        NavigationLink {
            SuperThumbnailView()
        } label: {
            HStack(spacing: 11) {
                SuperThumbnailMark(compact: true)
                Text("Super Thumbnail")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatted(statistics.cacheBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    let videoCount: Int
    let totalBytes: Int64
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
    @State private var screenAwakeActivityID = UUID()
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

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                folderSelection
                vaultOptions
                requirements
                startButton
                statisticsGrid
                vaultRemovalLink
                resetLink
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Super Thumbnail")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isSelectingFolder) {
            SuperThumbnailFolderPickerView { selected in
                selection = selected
                saveSelection(selected)
                hasPendingSession = false
                assessCompactJob(for: selected)
                isSelectingFolder = false
            }
            .environmentObject(connectionStore)
        }
        .fullScreenCover(isPresented: $isShowingProgress) {
            SuperThumbnailProgressView(
                preheater: preheater,
                folderTitle: selection?.title ?? "Selected Folder",
                onCancel: preheater.cancel,
                onClose: {
                    hasPendingSession = preheater.completedCount < preheater.totalCount
                        || preheater.failedCount > 0
                    isShowingProgress = false
                    Task { await refreshStatistics() }
                }
            )
            .interactiveDismissDisabled(preheater.isRunning)
        }
        .alert("Reset Super Thumbnail?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) {
                Task {
                    await SuperThumbnailCache.shared.reset()
                    await refreshStatistics()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Super Cache \(formatted(statistics.cacheBytes))와 "
                    + "Network Usage 기록을 초기화합니다. Original Video는 삭제하지 않습니다."
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
        .onAppear {
            ScreenAwakeController.shared.beginForcedActivity(screenAwakeActivityID)
        }
        .onDisappear {
            ScreenAwakeController.shared.finishForcedActivity(screenAwakeActivityID)
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

    private var hero: some View {
        HStack(alignment: .center, spacing: 14) {
            SuperThumbnailMark()
                .scaleEffect(0.55)
                .frame(width: 50, height: 50)
            Text("폴더를 선택하면 더 많은 Video에 Thumbnail을 만듭니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var statisticsGrid: some View {
        HStack(spacing: 16) {
            Label(
                "Network \(formatted(statistics.lifetimeNetworkBytes))",
                systemImage: "network"
            )
            Spacer()
            Label(
                "Cache \(formatted(statistics.cacheBytes))",
                systemImage: "internaldrive"
            )
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var vaultOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("NAS Vault", selection: $nasVaultEnabled) {
                    Text("NAS Vault").tag(true)
                    Text("Not").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Picker("Save", selection: $nasVaultTimingRaw) {
                    Text("Now").tag(SuperThumbnailVaultTiming.now.rawValue)
                    Text("Later").tag(SuperThumbnailVaultTiming.later.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .disabled(!nasVaultEnabled)
                .opacity(nasVaultEnabled ? 1 : 0.42)
            }
            Text(vaultOptionDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
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
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isSelectingFolder = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(SkyBreezeTheme.folderBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection?.title ?? "폴더 선택")
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(primaryInk)
                        Text(selection?.path ?? "NAS와 Folder를 선택하세요")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(
                    SkyBreezeTheme.thumbnailSurface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            Text("하위 폴더 포함 · 완료된 항목은 다시 만들지 않음")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            if !historySelections.isEmpty {
                historyPanel
            }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("최근 작업")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ScrollView(.vertical, showsIndicators: historySelections.count > 3) {
                LazyVStack(spacing: 7) {
                    ForEach(Array(historySelections.enumerated()), id: \.element.id) {
                        index, previous in
                        historyRow(previous, index: index)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(historySelections.count) * 64, 206))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func historyRow(
        _ previous: SuperThumbnailSelection,
        index: Int
    ) -> some View {
        Button {
            reportSelection = previous
            isShowingReport = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: index == 0 ? "clock.fill" : "clock")
                    .font(.caption)
                    .foregroundStyle(historyTint(for: index).opacity(0.78))
                    .frame(width: 24, height: 24)
                    .background(
                        historyTint(for: index).opacity(0.10),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(previous.title)
                        .font(.subheadline)
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                    Text(previous.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("보고서")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        historyTint(for: index).opacity(0.09),
                        in: Capsule()
                    )
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                historyTint(for: index).opacity(index == 0 ? 0.055 : 0.035),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(historyTint(for: index).opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func historyTint(for index: Int) -> Color {
        index == 0 ? Color.indigo : Color.teal
    }

    private var requirements: some View {
        HStack(spacing: 16) {
            requirementStatus(title: "Wi‑Fi", satisfied: hasWiFi)
            requirementStatus(title: "Power", satisfied: hasExternalPower)
            Spacer()
            Text(requirementSummary)
                .foregroundStyle(canStart ? Color.green : Color.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }

    private func requirementStatus(
        title: String,
        satisfied: Bool
    ) -> some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(satisfied ? Color.green : Color.secondary)
        }
    }

    private var startButton: some View {
        Button(action: startProcessing) {
            Label(
                isPreparing
                    ? "Preparing…"
                    : startButtonTitle,
                systemImage: "sparkles.rectangle.stack.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .font(.body.weight(.medium))
        .disabled(!canStart || isPreparing)
    }

    private var resetLink: some View {
        Button {
            isConfirmingReset = true
        } label: {
            Label("Super Cache 초기화", systemImage: "arrow.counterclockwise")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
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
            } else {
                Label("선택 폴더 NAS Vault 삭제", systemImage: "trash")
            }
        }
        .font(.footnote)
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
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        case .unknown, .unplugged: return false
        @unknown default: return false
        }
    }

    private var canStart: Bool {
        selection != nil
            && (hasStandardConditions || compactJobAssessment != nil)
            && !isAssessingCompactJob
            && !preheater.isRunning
    }

    private var hasStandardConditions: Bool {
        hasWiFi && hasExternalPower
    }

    private var usesCompactOverride: Bool {
        !hasStandardConditions && compactJobAssessment != nil
    }

    private var requirementSummary: String {
        if hasStandardConditions { return "Ready" }
        if let compactJobAssessment {
            return "Compact · \(compactJobAssessment.videoCount) Videos · "
                + formatted(compactJobAssessment.totalBytes)
        }
        if isAssessingCompactJob { return "Checking…" }
        return "Wi‑Fi + Power 필요"
    }

    private var startButtonTitle: String {
        if usesCompactOverride { return "Force Start Compact Job" }
        return hasPendingSession ? "Resume Super Thumbnail" : "Start Super Thumbnail"
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
        launchProcessing(
            selection: selection,
            allowsConstrainedRun: usesCompactOverride
        )
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
        allowsConstrainedRun: Bool
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
                let items = try await service.list(directory: selection.path)
                    .filter {
                        RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name)
                    }
                isShowingProgress = true
                preheater.start(
                    rootItems: items,
                    rootPath: selection.path,
                    recursively: true,
                    requiresExternalPower: true,
                    allowsConstrainedRun: allowsConstrainedRun,
                    generationMode: .completeFile,
                    vaultOptions: SuperThumbnailVaultOptions(
                        isEnabled: nasVaultEnabled,
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
            preparationError = "이전 미완료 작업을 계속하려면 Wi‑Fi와 충전 연결이 필요합니다."
            return
        }
        launchProcessing(
            selection: resumeSelection,
            allowsConstrainedRun: false
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
                let credential = try connectionStore.credential(
                    for: selection.connection
                )
                let service = RemoteFileServiceFactory.make(
                    connection: selection.connection,
                    credential: credential
                )
                var pendingPaths = [selection.path]
                var visitedPaths = Set<String>()
                var videoCount = 0
                var totalBytes: Int64 = 0
                let maximumBytes: Int64 = 1_024 * 1_024 * 1_024

                while let path = pendingPaths.first {
                    pendingPaths.removeFirst()
                    guard visitedPaths.insert(path).inserted else { continue }
                    let children = try await service.list(directory: path)
                        .filter {
                            RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name)
                        }
                    pendingPaths.append(contentsOf: children.filter(\.isDirectory).map(\.path))
                    for video in children where video.isVideo {
                        guard let size = video.size, size >= 0 else { return }
                        videoCount += 1
                        totalBytes += size
                        guard videoCount < 20, totalBytes <= maximumBytes else { return }
                    }
                }
                guard compactAssessmentID == assessmentID,
                      selection == self.selection else { return }
                compactJobAssessment = CompactJobAssessment(
                    videoCount: videoCount,
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    SuperThumbnailMark(compact: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("작업 보고서")
                            .font(.headline.weight(.medium))
                        Label(selection.title, systemImage: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(selection.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let report {
                    reportSummary(report)
                    reportActions(report)
                    if !report.failures.isEmpty {
                        failureSummary(report.failures)
                    }
                } else if isLoading {
                    ProgressView("보고서 불러오는 중…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ContentUnavailableView(
                        "저장된 보고서 없음",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("이 폴더의 Super Thumbnail 기록이 없습니다.")
                    )
                    selectFolderButton
                }
            }
            .padding(18)
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
        VStack(spacing: 10) {
            if report.hasWorkToResume {
                Button {
                    dismiss()
                    onResume()
                } label: {
                    Label("미완료 다시 진행", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            selectFolderButton
        }
    }

    private var selectFolderButton: some View {
        Button {
            dismiss()
            onSelect()
        } label: {
            Label("이 폴더 선택", systemImage: "folder.badge.checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func reportSummary(
        _ report: SuperThumbnailSessionReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("총계")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(report.totalCount)개")
                    .font(.title3.monospacedDigit())
            }
            if report.cachedCount > 0 {
                HStack {
                    Text("이미 완료")
                    Spacer()
                    Text("\(report.cachedCount)개")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(15)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func stageRow(
        seconds: Int,
        success: Int,
        remaining: Int
    ) -> some View {
        HStack {
            Text("\(seconds)초")
                .font(.subheadline.monospacedDigit().weight(.medium))
            Spacer()
            Text("성공 \(success)")
            Text("남음 \(remaining)")
                .foregroundStyle(remaining == 0 ? Color.secondary : Color.primary)
        }
        .font(.caption.monospacedDigit())
    }

    private func failureSummary(
        _ failures: [SuperThumbnailFailureRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("미완료 파일")
                .font(.subheadline.weight(.medium))
            ForEach(failures) { failure in
                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(failure.fileExtension.isEmpty ? "기타" : failure.fileExtension)
                        Text(failure.fileSize.map(formattedBytes) ?? "크기 미상")
                        Text(failure.durationSeconds.map(formattedDuration) ?? "길이 미상")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Text(failure.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if failure.id != failures.last?.id { Divider() }
            }
        }
        .padding(15)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
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
    let onCancel: () -> Void
    let onClose: () -> Void
    @State private var screenAwakeActivityID = UUID()
    @State private var isOverflowExpanded = true
    @State private var isFailurePanelExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 9) {
                        SuperThumbnailMark(compact: true)
                        Text("Super Processing")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 7) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(SkyBreezeTheme.folderBlue.opacity(0.78))
                        Text(folderTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    if let pauseReason = preheater.pauseReason {
                        Text(pauseReason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    overallProgressPanel

                    VStack(spacing: 0) {
                        currentFilenameRow
                        currentItemWaitPanel(
                            startedAt: preheater.currentItemStartedAt
                        )
                        etaPanel
                    }
                    HStack(spacing: 18) {
                        progressMetric("Created", preheater.generatedCount)
                        progressMetric("Already Done", preheater.cachedCount)
                        progressMetric("Failed", preheater.failedCount)
                    }
                    if preheater.vaultRestoredCount > 0 || preheater.vaultStoredCount > 0 {
                        Text(
                            "NAS Vault · 가져옴 \(preheater.vaultRestoredCount) · "
                                + "보관 \(preheater.vaultStoredCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    if let vaultErrorMessage = preheater.vaultErrorMessage {
                        Text("NAS Vault 보관 대기 · \(vaultErrorMessage)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    if !preheater.recentGeneratedThumbnails.isEmpty {
                        overflowPanel
                    }
                    if preheater.isRunning, preheater.failedCount > 0 {
                        failurePanel
                    }
                    Text(
                        "Session Network · "
                            + formattedProgressBytes(
                                preheater.transferredBytes
                                    + preheater.currentItemTransferredBytes
                            )
                    )
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if !preheater.isRunning, preheater.totalCount > 0 {
                        completionReportPanel
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 26)
            }
            .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button(role: preheater.isRunning ? .destructive : nil) {
                    preheater.isRunning ? onCancel() : onClose()
                } label: {
                    Text(preheater.isRunning ? "Cancel Processing" : "Close")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ScreenAwakeController.shared.beginForcedActivity(screenAwakeActivityID)
            }
            .onDisappear {
                ScreenAwakeController.shared.finishForcedActivity(screenAwakeActivityID)
            }
        }
    }

    private var overallProgressPanel: some View {
        VStack(spacing: 9) {
            ProgressView(value: preheater.fractionCompleted ?? 0)
                .progressViewStyle(.linear)
                .tint(Color.blue.opacity(0.72))
            Text("\(preheater.completedCount) / \(preheater.totalCount)")
                .font(.title3.monospacedDigit().weight(.regular))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
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
        .font(.subheadline)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(filename)
    }

    private func progressMetric(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.headline.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var etaPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.blue)
            Text("남은 시간")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formattedETA)
                .font(.headline.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(14)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var coverFlow: some View {
        HStack(alignment: .bottom, spacing: -8) {
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
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .animation(
            .spring(response: 0.42, dampingFraction: 0.86),
            value: preheater.recentGeneratedThumbnails.count
        )
    }

    private var overflowPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack")
                Text("Overflow")
                Spacer()
                Image(
                    systemName: isOverflowExpanded
                        ? "chevron.up"
                        : "chevron.down"
                )
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

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
        .padding(.horizontal, 12)
        .padding(.vertical, isOverflowExpanded ? 10 : 9)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) {
                isOverflowExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Overflow")
        .accessibilityHint(
            isOverflowExpanded ? "탭하여 숨기기" : "탭하여 보기"
        )
        .accessibilityAddTraits(.isButton)
    }

    private var failurePanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                Text("실패 \(preheater.failedCount)건")
                Spacer()
                Image(
                    systemName: isFailurePanelExpanded
                        ? "chevron.up"
                        : "chevron.down"
                )
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)

            if isFailurePanelExpanded {
                ForEach(preheater.failedItemNames, id: \.self) { detail in
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            Color.orange.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
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
            return "Calculating…"
        }
        if seconds <= 0 { return "Almost done" }
        let minutes = max(Int(ceil(seconds / 60)), 1)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours) hr"
            : "\(hours) hr \(remainingMinutes) min"
    }

    private var currentItemTransferText: String {
        let current = formattedRangeMegabytes(
            preheater.currentItemTransferredBytes
        )
        let total = formattedRangeMegabytes(preheater.currentItemTotalBytes)
        return "Range \(current) / \(total)"
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
            VStack(spacing: 6) {
                HStack {
                    Text(preheater.isRunning ? currentPassTitle : statusTitle)
                    Spacer()
                    Text(String(format: "%02ds 남음", remaining))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                ProgressView(
                    value: preheater.isRunning ? min(elapsed / limit, 1) : 1
                )
                    .progressViewStyle(.linear)
                    .tint(.indigo.opacity(0.72))
                Text(currentItemTransferText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
            .background(
                Color.indigo.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    private var currentPassTitle: String {
        switch preheater.currentItemAttempt {
        case 0: return "빠른 처리"
        case 1: return "재시도"
        default: return "최종 복구"
        }
    }

    private var completionReportPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("처리 결과")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("총계")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(preheater.totalCount)개")
                        .font(.title3.monospacedDigit().weight(.regular))
                        .foregroundStyle(.primary)
                }
                Divider().opacity(0.65)
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
            .padding(12)
            .background(
                Color.blue.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

            if !preheater.failedItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("실패 요약")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange.opacity(0.88))
                    Text(failureSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                failureTable
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            SkyBreezeTheme.thumbnailSurface,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private func stageMetric(
        seconds: Int,
        success: Int,
        remaining: Int
    ) -> some View {
        VStack(spacing: 3) {
            Text("\(seconds)초")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("성공 \(success)")
                .font(.subheadline.monospacedDigit().weight(.regular))
                .foregroundStyle(.primary)
            Text("남음 \(remaining)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(
                    remaining == 0 ? Color.secondary : Color.primary
                )
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
                    failureCell("파일 이름", width: 220, isHeader: true)
                    failureCell("종류", width: 58, isHeader: true)
                    failureCell("크기", width: 82, isHeader: true)
                    failureCell("길이", width: 70, isHeader: true)
                    failureCell("실패 사유", width: 210, isHeader: true)
                }
                ForEach(Array(preheater.failedItems.enumerated()), id: \.element.id) {
                    index, failure in
                    GridRow {
                        failureCell(failure.name, width: 220, shaded: index.isMultiple(of: 2))
                        failureCell(
                            failure.fileExtension.isEmpty ? "—" : failure.fileExtension,
                            width: 58,
                            shaded: index.isMultiple(of: 2)
                        )
                        failureCell(
                            failure.fileSize.map {
                                formattedProgressBytes($0)
                            } ?? "—",
                            width: 82,
                            shaded: index.isMultiple(of: 2)
                        )
                        failureCell(
                            failure.durationSeconds.map {
                                formattedDuration($0)
                            } ?? "—",
                            width: 70,
                            shaded: index.isMultiple(of: 2)
                        )
                        failureCell(
                            failure.reason,
                            width: 210,
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
            .font(isHeader ? .caption2.weight(.medium) : .caption2)
            .foregroundStyle(isHeader ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .background(
                isHeader
                    ? Color.secondary.opacity(0.08)
                    : shaded ? Color.secondary.opacity(0.035) : Color.clear
            )
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 0.5)
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

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: imageWidth, height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
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
            .frame(width: titleWidth, height: 96, alignment: .bottomLeading)

            Text(filename)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
                .truncationMode(.tail)
                .frame(width: titleWidth, height: 16, alignment: .leading)
        }
        .frame(width: titleWidth, alignment: .leading)
        .zIndex(Double(totalCount - index))
    }

    private var borderColor: Color {
        index == 0 ? Color.blue.opacity(0.5) : Color.white.opacity(0.72)
    }

    private var widthFactor: CGFloat {
        max(0.6, 1 - CGFloat(index) * 0.1)
    }

    private var imageWidth: CGFloat {
        96 * widthFactor
    }

    private var imageHeight: CGFloat {
        96 * widthFactor
    }

    private var titleWidth: CGFloat {
        max(imageWidth, 64)
    }
}

private struct SuperThumbnailFolderPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionStore: ConnectionStore
    let onSelect: (SuperThumbnailSelection) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "No NAS Connections",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("먼저 Dashboard에서 NAS Connection을 추가해 주세요.")
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.name).foregroundStyle(.primary)
                                    Text(connection.normalizedRootPath)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: connection.kind.systemImage)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select NAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                ContentUnavailableView("Credentials Required", systemImage: "key.slash")
            } else {
                ProgressView("Connecting…")
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
                ProgressView("Loading Folders…")
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                ContentUnavailableView(
                    "Folder Unavailable",
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
                        Label(folder.name, systemImage: "folder.fill")
                            .foregroundStyle(.primary)
                    }
                }
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
                Label("Select This Folder", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
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
