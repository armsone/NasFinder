import SwiftUI
import UIKit
import UniformTypeIdentifiers

typealias ReturnToDashboardAction = @MainActor @Sendable () -> Void

enum FileBrowserDownloadPolicy {
    static func downloadableItems(from items: [RemoteFileItem]) -> [RemoteFileItem] {
        items.filter { !$0.isDirectory }
    }
}

private struct ReturnToDashboardKey: EnvironmentKey {
    static let defaultValue: ReturnToDashboardAction = {}
}

extension EnvironmentValues {
    var returnToDashboard: ReturnToDashboardAction {
        get { self[ReturnToDashboardKey.self] }
        set { self[ReturnToDashboardKey.self] = newValue }
    }
}

struct FileBrowserPathComponent: Identifiable, Equatable {
    let path: String
    let title: String

    var id: String { path }
}

enum FileBrowserPathNavigation {
    static func components(currentPath: String, rootPath: String) -> [FileBrowserPathComponent] {
        let root = normalized(rootPath)
        let current = normalized(currentPath)
        guard current == root || current.hasPrefix(root == "/" ? "/" : root + "/") else {
            return [FileBrowserPathComponent(path: current, title: current)]
        }

        var result = [FileBrowserPathComponent(path: root, title: root)]
        guard current != root else { return result }
        let remainder = String(current.dropFirst(root == "/" ? 1 : root.count + 1))
        var accumulated = root
        for name in remainder.split(separator: "/").map(String.init) {
            accumulated = accumulated == "/" ? "/\(name)" : "\(accumulated)/\(name)"
            result.append(FileBrowserPathComponent(path: accumulated, title: name))
        }
        return result
    }

    static func parent(
        currentPath: String,
        rootPath: String
    ) -> FileBrowserPathComponent? {
        let pathComponents = components(
            currentPath: currentPath,
            rootPath: rootPath
        )
        guard pathComponents.count > 1 else { return nil }
        return pathComponents.dropLast().last
    }

    private static func normalized(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }
}

private struct FileBrowserPageTitle: View {
    let title: String
    @ObservedObject var trafficTracker: PageNetworkTrafficTracker

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 7) {
                trafficValue(
                    symbol: "arrow.up",
                    value: trafficTracker.uploadedByteCount,
                    accessibilityLabel: "올림"
                )
                trafficValue(
                    symbol: "arrow.down",
                    value: trafficTracker.downloadedByteCount,
                    accessibilityLabel: "내림"
                )
                trafficValue(
                    symbol: "sum",
                    value: trafficTracker.totalByteCount,
                    accessibilityLabel: "합계"
                )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: 230, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func trafficValue(
        symbol: String,
        value: Int64,
        accessibilityLabel: String
    ) -> some View {
        Label {
            Text(PageNetworkTrafficTracker.formatted(value))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } icon: {
            Image(systemName: symbol)
                .font(.caption2)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .layoutPriority(1)
        .accessibilityLabel(
            "\(accessibilityLabel) \(PageNetworkTrafficTracker.formatted(value))"
        )
    }
}

struct FileBrowserView: View {
    private struct DisplayRequest: Equatable {
        let query: String
        let sortOptions: FileBrowserSortOptions
    }

    private enum LayoutStyle: String, CaseIterable, Identifiable {
        case list
        case smallThumbnails
        case largeThumbnails
        case coverFlow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .list:
                "자세히"
            case .smallThumbnails:
                "작은 썸네일"
            case .largeThumbnails:
                "포스터"
            case .coverFlow:
                "오버플로우"
            }
        }

        var systemImage: String {
            switch self {
            case .list:
                "list.bullet"
            case .smallThumbnails:
                "square.grid.3x3"
            case .largeThumbnails:
                "square.grid.2x2"
            case .coverFlow:
                "rectangle.stack.fill"
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.returnToDashboard) private var returnToDashboard
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @AppStorage("fileBrowserLayoutStyle") private var storedLayoutStyle = LayoutStyle.smallThumbnails.rawValue
    @AppStorage("fileBrowserSortField") private var storedSortField = FileBrowserSortField.name.rawValue
    @AppStorage("fileBrowserSortDirection") private var storedSortDirection = FileBrowserSortDirection.ascending.rawValue
    @AppStorage("fileBrowserNamePriority") private var storedNamePriority = FileBrowserNamePriority.numbersFirst.rawValue
    @AppStorage("fileBrowserFoldersFirst") private var foldersFirst = true
    @AppStorage("browser.coverFlowBackground.v1") private var coverFlowUsesDarkBackground = false
    @StateObject private var viewModel: FileBrowserViewModel
    @StateObject private var trafficTracker: PageNetworkTrafficTracker
    @StateObject private var shareCoordinator = RemoteFileShareCoordinator()
    @StateObject private var operationCoordinator: FileOperationCoordinator
    @StateObject private var thumbnailPreheater = ThumbnailPreheater()
    @StateObject private var interactionCoordinator = FileBrowserInteractionCoordinator()
    @ObservedObject private var thumbnailActivity = RemoteThumbnailActivityTracker.shared
    @State private var previewItem: RemoteFileItem?
    @State private var navigatedFolder: RemoteFileItem?
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<RemoteFileItem.ID> = []
    @State private var pendingDeleteItems: [RemoteFileItem] = []
    @State private var renameItem: RemoteFileItem?
    @State private var renameText = ""
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isImportingFiles = false
    @State private var searchText = ""
    @State private var thumbnailReloadVersion = 0
    @State private var isRequestingCoverFlowOrientation = false
    @State private var coverFlowEnteredFromPoster = false
    @State private var suppressAutomaticCoverFlowUntil = Date.distantPast
    @State private var ownsAutomaticThumbnailPreheat = false
    @State private var automaticThumbnailRestartTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadItemName: String?
    @State private var downloadCompletedCount = 0
    @State private var downloadTotalCount = 0
    @State private var downloadErrorMessage: String?

    @MainActor
    init(
        connection: RemoteConnection,
        path: String,
        service: any RemoteFileService,
        title: String,
        operationCoordinator: FileOperationCoordinator = FileOperationCoordinator(),
        trafficTracker: PageNetworkTrafficTracker? = nil,
        returnToDashboardAction: ReturnToDashboardAction? = nil
    ) {
        let tracker = trafficTracker ?? PageNetworkTrafficTracker()
        let measuredService: any RemoteFileService
        if service is TrafficMeasuringRemoteFileService {
            measuredService = service
        } else {
            measuredService = TrafficMeasuringRemoteFileService(base: service, tracker: tracker)
        }
        _viewModel = StateObject(
            wrappedValue: FileBrowserViewModel(
                connection: connection,
                path: path,
                service: measuredService
            )
        )
        _trafficTracker = StateObject(wrappedValue: tracker)
        _operationCoordinator = StateObject(wrappedValue: operationCoordinator)
        self.title = title
        self.explicitReturnToDashboardAction = returnToDashboardAction
    }

    private let title: String
    private let explicitReturnToDashboardAction: ReturnToDashboardAction?

    private var dashboardAction: ReturnToDashboardAction {
        explicitReturnToDashboardAction ?? returnToDashboard
    }

    var body: some View {
        AnyView(
            VStack(spacing: 0) {
                if layoutStyle != .coverFlow {
                    currentPathBar
                    thumbnailProgressLine
                }
                browserContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
            .modifier(
                FileBrowserNavigationAppearanceModifier(
                    isCoverFlow: layoutStyle == .coverFlow
                )
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(
                FileBrowserCoverFlowChromeModifier(
                    isActive: layoutStyle == .coverFlow
                )
            )
            .modifier(
                FileBrowserSearchModifier(
                    isEnabled: layoutStyle != .coverFlow,
                    text: $searchText
                )
            )
            .toolbar { browserToolbar }
            .overlay { coverFlowNavigationOverlay }
        )
        .navigationDestination(item: $navigatedFolder) { item in
            FileBrowserView(
                connection: viewModel.connection,
                path: item.path,
                service: viewModel.service,
                title: item.name,
                operationCoordinator: operationCoordinator,
                trafficTracker: trafficTracker,
                returnToDashboardAction: dashboardAction
            )
        }
        .refreshable {
            await refreshCurrentPage()
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.data, .content],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                operationCoordinator.upload(
                    urls,
                    into: viewModel.path,
                    using: viewModel.service,
                    conflictPolicy: .keepBoth
                ) {
                    await viewModel.reloadAfterCurrentLoad()
                }
            case .failure(let error):
                let cocoaError = error as NSError
                guard !(error is CancellationError),
                      !(cocoaError.domain == NSCocoaErrorDomain
                        && cocoaError.code == CocoaError.Code.userCancelled.rawValue) else {
                    return
                }
                operationCoordinator.errorMessage = error.localizedDescription
            }
        }
        .fileDialogConfirmationLabel("업로드")
        .fileDialogMessage("현재 폴더에 올릴 파일을 선택하세요.")
        .onChange(of: displayRequest, initial: true) { _, request in
            viewModel.configureDisplay(
                matching: request.query,
                options: request.sortOptions
            )
        }
        .onAppear {
            if storedLayoutStyle == LayoutStyle.coverFlow.rawValue {
                storedLayoutStyle = LayoutStyle.largeThumbnails.rawValue
                coverFlowEnteredFromPoster = false
            }
            trafficTracker.reset()
            thumbnailActivity.beginNewSession()
            connectionStore.rememberBrowserLocation(
                connection: viewModel.connection,
                path: viewModel.path,
                title: title
            )
        }
        .onChange(of: layoutStyle, initial: true) { _, style in
            updateCoverFlowOrientation(for: style)
        }
        .modifier(
            FileBrowserDeviceRotationModifier(
                onChange: handleDeviceOrientationChange
            )
        )
        .task {
            await RemoteThumbnailDiskCache.shared.clearTransientFailures()
            await viewModel.load()
            guard !Task.isCancelled, !viewModel.items.isEmpty else { return }
            ownsAutomaticThumbnailPreheat = true
            thumbnailPreheater.start(
                rootItems: viewModel.items,
                rootPath: viewModel.path,
                recursively: false,
                requiresExternalPower: false,
                allowsConstrainedRun: true,
                generationMode: .bounded,
                service: viewModel.service
            )
        }
        .overlay(alignment: .bottom) {
            browserStatusOverlay
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shareCoordinator.isPreparing)
        .alert(errorTitle, isPresented: errorBinding) {
            Button("확인", role: .cancel) {
                viewModel.errorMessage = nil
                shareCoordinator.errorMessage = nil
                operationCoordinator.dismissError()
                thumbnailPreheater.errorMessage = nil
                downloadErrorMessage = nil
            }
        } message: {
            Text(
                shareCoordinator.errorMessage
                    ?? operationCoordinator.errorMessage
                    ?? thumbnailPreheater.errorMessage
                    ?? downloadErrorMessage
                    ?? viewModel.errorMessage
                    ?? ""
            )
        }
        .sheet(
            item: $shareCoordinator.preparedShare,
            onDismiss: { shareCoordinator.shareSheetDidDismiss() }
        ) { preparedShare in
            RemoteFileActivityView(fileURLs: preparedShare.fileURLs)
        }
        .fullScreenCover(item: $previewItem) { item in
            RemotePreviewView(
                item: item,
                sequentialItems: sequentialPreviewItems(for: item),
                service: viewModel.service
            )
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                let items = pendingDeleteItems
                pendingDeleteItems = []
                operationCoordinator.delete(items, using: viewModel.service) {
                    await viewModel.reloadAfterCurrentLoad()
                }
                endSelection()
            }
            Button("취소", role: .cancel) {
                pendingDeleteItems = []
            }
        } message: {
            Text("폴더를 선택한 경우 안의 파일도 함께 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .alert("이름 수정", isPresented: renameAlertBinding) {
            TextField("새 이름", text: $renameText)
            Button("취소", role: .cancel) {
                renameItem = nil
            }
            Button("변경") {
                guard let item = renameItem else { return }
                let name = renameText
                renameItem = nil
                operationCoordinator.rename(item, to: name, using: viewModel.service) {
                    await viewModel.reloadAfterCurrentLoad()
                }
            }
        }
        .alert("새 폴더", isPresented: $isCreatingFolder) {
            TextField("폴더 이름", text: $newFolderName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                let name = newFolderName
                operationCoordinator.createFolder(
                    named: name,
                    in: viewModel.path,
                    using: viewModel.service
                ) {
                    await viewModel.reloadAfterCurrentLoad()
                }
            }
        }
        .onDisappear {
            ownsAutomaticThumbnailPreheat = false
            automaticThumbnailRestartTask?.cancel()
            automaticThumbnailRestartTask = nil
            shareCoordinator.cancelPreparation()
            cancelDownload()
            thumbnailPreheater.cancel()
            if isRequestingCoverFlowOrientation {
                FileBrowserOrientationController.endCoverFlow()
                isRequestingCoverFlowOrientation = false
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            thumbnailPreheater.updateAppIsActive(phase == .active)
        }
        .modifier(
            ThumbnailNetworkChangeModifier(
                onChange: restartAutomaticThumbnailPreheatingForNetworkChange
            )
        )
        .onChange(of: viewModel.items.map(\.id)) { _, visibleIDs in
            selectedItemIDs.formIntersection(visibleIDs)
            if isSelecting, viewModel.items.isEmpty {
                endSelection()
            }
        }
        .onChange(of: shareCoordinator.preparedShare?.id) { _, preparedID in
            if preparedID != nil {
                endSelection(allowDuringSharePreparation: true)
            }
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if layoutStyle != .coverFlow {
                Button(action: dashboardAction) {
                    FileBrowserPageTitle(title: title, trafficTracker: trafficTracker)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("\(title), 첫 화면으로 이동")
                .accessibilityHint("NasFinder 첫 화면으로 돌아갑니다.")
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if layoutStyle != .coverFlow {
                if isSelecting {
                    Button("완료") {
                        endSelection()
                    }
                    .disabled(shareCoordinator.isPreparing)
                } else {
                    regularMoreButton
                }
            }
        }
    }

    private var regularMoreButton: some View {
        Button {
            interactionCoordinator.showBrowserPanel()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SkyBreezeTheme.accent)
                .frame(width: 32, height: 32)
                .background(SkyBreezeTheme.accent.opacity(0.16), in: Circle())
                .overlay {
                    Circle().stroke(
                        SkyBreezeTheme.accent.opacity(0.48),
                        lineWidth: 1
                    )
                }
        }
        .disabled(operationCoordinator.isBusy)
        .accessibilityLabel("더 보기")
        .accessibilityHint("파일 작업, 새로 고침과 보기 설정 메뉴를 엽니다.")
        .popover(
            item: $interactionCoordinator.panel,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) { panel in
            interactionPanel(panel)
                .onDisappear {
                    interactionCoordinator.panelDidDisappear()
                }
        }
    }

    @ViewBuilder
    private var coverFlowNavigationOverlay: some View {
        if layoutStyle == .coverFlow {
            GeometryReader { geometry in
                HStack(spacing: 8) {
                    coverFlowBackButton

                    Button(action: dashboardAction) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(coverFlowChromeForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                            .frame(
                                maxWidth: min(geometry.size.width * 0.44, 340),
                                minHeight: 44,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title), 첫 화면으로 이동")
                    .accessibilityHint("NasFinder 첫 화면으로 돌아갑니다.")

                    Spacer(minLength: 8)
                    coverFlowMoreButton
                }
                .padding(.horizontal, 12)
                .padding(.top, geometry.safeAreaInsets.top + 4)
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.easeInOut(duration: 0.20), value: coverFlowUsesDarkBackground)
            }
        }
    }

    private var coverFlowBackButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(coverFlowChromeForeground)
        .background(coverFlowChromeBackground, in: Circle())
        .overlay {
            Circle().stroke(coverFlowChromeBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(coverFlowUsesDarkBackground ? 0.40 : 0.10), radius: 8, y: 2)
        .accessibilityLabel("이전 폴더")
    }

    private var coverFlowMoreButton: some View {
        Button {
            interactionCoordinator.showBrowserPanel()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SkyBreezeTheme.accent)
        .background(coverFlowChromeBackground, in: Circle())
        .overlay {
            Circle().stroke(coverFlowChromeBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(coverFlowUsesDarkBackground ? 0.40 : 0.10), radius: 8, y: 2)
        .disabled(operationCoordinator.isBusy)
        .accessibilityLabel("더 보기")
        .popover(
            item: $interactionCoordinator.panel,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) { panel in
            interactionPanel(panel)
                .onDisappear {
                    interactionCoordinator.panelDidDisappear()
                }
        }
    }

    private var coverFlowChromeForeground: Color {
        coverFlowUsesDarkBackground ? .white.opacity(0.88) : .black.opacity(0.82)
    }

    private var coverFlowChromeBackground: Color {
        coverFlowUsesDarkBackground ? .white.opacity(0.10) : .white.opacity(0.92)
    }

    private var coverFlowChromeBorder: Color {
        coverFlowUsesDarkBackground ? .white.opacity(0.16) : .black.opacity(0.10)
    }

    @ViewBuilder
    private var browserStatusOverlay: some View {
        if layoutStyle != .coverFlow {
            VStack(spacing: 8) {
                if shareCoordinator.isPreparing {
                    SharePreparationBanner(
                        itemName: shareCoordinator.preparingItemName,
                        completedCount: shareCoordinator.completedCount,
                        totalCount: shareCoordinator.totalCount
                    ) {
                        shareCoordinator.cancelPreparation()
                    }
                }

                if downloadTask != nil {
                    FileOperationProgressBanner(
                        title: "받은 파일에 저장 중…",
                        progress: RemoteOperationProgress(
                            operationID: UUID(),
                            operation: .copy,
                            phase: .reading,
                            unit: .items,
                            completedUnitCount: Int64(downloadCompletedCount),
                            totalUnitCount: Int64(downloadTotalCount),
                            currentPath: downloadItemName
                        ),
                        onCancel: cancelDownload
                    )
                }

                if operationCoordinator.isWorking {
                    FileOperationProgressBanner(
                        title: operationCoordinator.operationTitle ?? "파일 작업 중…",
                        progress: operationCoordinator.progress,
                        onCancel: operationCoordinator.cancel
                    )
                } else if let status = operationCoordinator.statusMessage {
                    FileOperationStatusBanner(
                        message: status,
                        onDismiss: operationCoordinator.dismissStatus
                    )
                }

            }
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("불러오는 중…")
        } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
            ContentUnavailableView {
                Label("폴더를 열 수 없습니다", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("다시 시도") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if viewModel.items.isEmpty {
            ContentUnavailableView("빈 폴더", systemImage: "folder")
        } else if displayedItems.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch layoutStyle {
            case .list:
                list
            case .smallThumbnails, .largeThumbnails:
                thumbnailGrid(for: layoutStyle)
            case .coverFlow:
                FileBrowserCoverFlowView(
                    items: displayedItems,
                    service: viewModel.service,
                    thumbnailReloadVersion: thumbnailReloadVersion,
                    usesDarkBackground: $coverFlowUsesDarkBackground,
                    onActivate: activate,
                    onShowActions: showItemPanel
                )
            }
        }
    }

    private var layoutStyle: LayoutStyle {
        LayoutStyle(rawValue: storedLayoutStyle) ?? .smallThumbnails
    }

    private var availableLayoutStyles: [LayoutStyle] {
        LayoutStyle.allCases.filter { $0 != .coverFlow }
    }

    private func updateCoverFlowOrientation(for style: LayoutStyle) {
        if style == .coverFlow,
           !coverFlowEnteredFromPoster,
           !isRequestingCoverFlowOrientation {
            FileBrowserOrientationController.beginCoverFlow()
            isRequestingCoverFlowOrientation = true
        } else if (style != .coverFlow || coverFlowEnteredFromPoster),
                  isRequestingCoverFlowOrientation {
            FileBrowserOrientationController.endCoverFlow()
            isRequestingCoverFlowOrientation = false
        }
    }

    private func handleDeviceOrientationChange(_ orientation: UIDeviceOrientation) {
        guard Date.now >= suppressAutomaticCoverFlowUntil else { return }
        if orientation.isLandscape,
           layoutStyle == .largeThumbnails {
            coverFlowEnteredFromPoster = true
            storedLayoutStyle = LayoutStyle.coverFlow.rawValue
        } else if orientation.isPortrait,
                  layoutStyle == .coverFlow,
                  coverFlowEnteredFromPoster {
            storedLayoutStyle = LayoutStyle.largeThumbnails.rawValue
            coverFlowEnteredFromPoster = false
        }
    }

    private func startThumbnailPreheating(
        for item: RemoteFileItem,
        recursively: Bool,
        generationMode: RemoteVideoThumbnailGenerationMode = .bounded
    ) {
        ownsAutomaticThumbnailPreheat = false
        if item.isDirectory {
            Task {
                do {
                    let children = try await viewModel.service.list(directory: item.path)
                        .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
                    thumbnailPreheater.start(
                        rootItems: children,
                        rootPath: item.path,
                        recursively: recursively,
                        requiresExternalPower: recursively
                            || generationMode == .completeFile,
                        allowsConstrainedRun: ThumbnailPreheatPolicy
                            .allowsConstrainedNetwork(for: generationMode),
                        generationMode: generationMode,
                        service: viewModel.service
                    )
                } catch {
                    thumbnailPreheater.errorMessage = error.localizedDescription
                }
            }
            return
        }

        thumbnailPreheater.start(
            rootItems: [item],
            rootPath: viewModel.path,
            recursively: false,
            allowsConstrainedRun: ThumbnailPreheatPolicy
                .allowsConstrainedNetwork(for: generationMode),
            generationMode: generationMode,
            service: viewModel.service
        )
    }

    private func restartAutomaticThumbnailPreheatingForNetworkChange() {
        guard ownsAutomaticThumbnailPreheat,
              !viewModel.items.isEmpty else { return }
        automaticThumbnailRestartTask?.cancel()
        thumbnailPreheater.cancel()
        automaticThumbnailRestartTask = Task { @MainActor in
            while thumbnailPreheater.isRunning {
                guard !Task.isCancelled else { return }
                await Task.yield()
            }
            guard !Task.isCancelled,
                  ownsAutomaticThumbnailPreheat,
                  !viewModel.items.isEmpty else { return }
            thumbnailPreheater.start(
                rootItems: viewModel.items,
                rootPath: viewModel.path,
                recursively: false,
                requiresExternalPower: false,
                allowsConstrainedRun: true,
                generationMode: .bounded,
                service: viewModel.service
            )
            automaticThumbnailRestartTask = nil
        }
    }

    private var sortOptions: FileBrowserSortOptions {
        FileBrowserSortOptions(
            field: FileBrowserSortField(rawValue: storedSortField) ?? .name,
            direction: FileBrowserSortDirection(rawValue: storedSortDirection) ?? .ascending,
            namePriority: FileBrowserNamePriority(rawValue: storedNamePriority) ?? .numbersFirst,
            foldersFirst: foldersFirst
        )
    }

    @ViewBuilder
    private func interactionPanel(_ panel: FileBrowserInteractionCoordinator.Panel) -> some View {
        switch panel {
        case .browser:
            browserMorePanel
        case .item(let item):
            contextActionPopover(for: item)
        }
    }

    private var browserMorePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MorePanelSectionTitle("파일 작업")

                HStack(spacing: 4) {
                    CompactPanelButton(title: "선택", systemImage: "checkmark.circle") {
                        performMorePanelAction { isSelecting = true }
                    }

                    CompactPanelButton(title: "붙여넣기", systemImage: "doc.on.clipboard") {
                        performMorePanelAction(performPasteAction)
                    }
                    .disabled(!canPerformPasteAction)

                    CompactPanelButton(title: "새 폴더", systemImage: "folder.badge.plus") {
                        performMorePanelAction {
                            guard canBeginUserPresentation else { return }
                            newFolderName = ""
                            isCreatingFolder = true
                        }
                    }
                    .disabled(
                        !viewModel.service.capabilities.contains(.createFolder)
                            || !canBeginUserPresentation
                    )

                    CompactPanelButton(title: "새로고침", systemImage: "arrow.clockwise") {
                        performMorePanelAction {
                            Task { await refreshCurrentPage() }
                        }
                    }
                }

                Divider()
                    .overlay(Color(uiColor: .separator).opacity(0.32))
                    .padding(.vertical, 6)
                MorePanelSectionTitle("보기")

                HStack(spacing: 4) {
                    ForEach(availableLayoutStyles) { style in
                        CompactPanelButton(
                            title: style.title,
                            systemImage: style.systemImage,
                            isSelected: layoutStyle == style
                        ) {
                            performMorePanelAction {
                                coverFlowEnteredFromPoster = false
                                suppressAutomaticCoverFlowUntil = Date.now.addingTimeInterval(0.8)
                                storedLayoutStyle = style.rawValue
                            }
                        }
                    }
                }

                if layoutStyle == .coverFlow {
                    CompactPanelOptionRow(title: "배경") {
                        HStack(spacing: 4) {
                            ForEach(FileBrowserCoverFlowBackground.allCases) { background in
                                CompactPanelOptionButton(
                                    title: background.title,
                                    isSelected: background.usesDarkBackground
                                        == coverFlowUsesDarkBackground
                                ) {
                                    withAnimation(.easeInOut(duration: 0.20)) {
                                        coverFlowUsesDarkBackground =
                                            background.usesDarkBackground
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()
                    .overlay(Color(uiColor: .separator).opacity(0.32))
                    .padding(.vertical, 6)
                MorePanelSectionTitle("정렬")

                CompactPanelOptionRow(title: "기준") {
                    HStack(spacing: 4) {
                        ForEach(FileBrowserSortField.allCases) { field in
                            CompactPanelOptionButton(
                                title: field.title,
                                isSelected: sortOptions.field == field
                            ) {
                                storedSortField = field.rawValue
                            }
                        }
                    }
                }

                CompactPanelOptionRow(title: "순서") {
                    HStack(spacing: 4) {
                        ForEach(FileBrowserSortDirection.allCases) { direction in
                            CompactPanelOptionButton(
                                title: direction.title,
                                isSelected: sortOptions.direction == direction
                            ) {
                                storedSortDirection = direction.rawValue
                            }
                        }
                    }
                }

                CompactPanelOptionRow(title: "이름 우선") {
                    HStack(spacing: 4) {
                        ForEach(FileBrowserNamePriority.allCases) { priority in
                            CompactPanelOptionButton(
                                title: priority.title,
                                isSelected: sortOptions.namePriority == priority
                            ) {
                                storedNamePriority = priority.rawValue
                            }
                        }
                    }
                    .opacity(sortOptions.field == .name ? 1 : 0.38)
                    .disabled(sortOptions.field != .name)
                }

                CompactPanelOptionRow(title: "폴더 먼저") {
                    HStack(spacing: 4) {
                        CompactPanelOptionButton(title: "끔", isSelected: !foldersFirst) {
                            foldersFirst = false
                        }
                        CompactPanelOptionButton(title: "켬", isSelected: foldersFirst) {
                            foldersFirst = true
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.visible)
        .frame(width: 340, height: 460)
        .background(Color(uiColor: .systemBackground))
        .presentationCompactAdaptation(.popover)
        .buttonStyle(.plain)
        .accessibilityLabel("파일 작업과 보기 설정")
    }

    private func performMorePanelAction(
        _ action: @escaping @MainActor () -> Void
    ) {
        interactionCoordinator.dismissPanel(then: action)
    }

    private func refreshCurrentPage() async {
        guard !operationCoordinator.isBusy else { return }
        await CompatibilityRemoteVideoThumbnailGenerator.cancelAll()
        await RemoteThumbnailDiskCache.shared.removeData(for: viewModel.items)

        await viewModel.reloadAfterCurrentLoad()
        await RemoteVideoThumbnailTrafficBudget.shared.reset()
        await RemoteVideoThumbnailTrafficBudget.sftpShared.reset()
        thumbnailActivity.beginNewSession()
        thumbnailReloadVersion &+= 1
        ownsAutomaticThumbnailPreheat = true
        thumbnailPreheater.start(
            rootItems: viewModel.items,
            rootPath: viewModel.path,
            recursively: false,
            requiresExternalPower: false,
            allowsConstrainedRun: true,
            service: viewModel.service
        )
    }

    private var canPerformPasteAction: Bool {
        if let clipboard = operationCoordinator.clipboard {
            return clipboard.connectionID == viewModel.connection.id
                && viewModel.service.capabilities.supports(
                    clipboard.mode == .copy ? .copy : .move
                )
        }
        return viewModel.service.capabilities.contains(.upload)
            && canBeginUserPresentation
    }

    private func performPasteAction() {
        if operationCoordinator.clipboard != nil {
            operationCoordinator.paste(
                into: viewModel.path,
                using: viewModel.service
            ) {
                await viewModel.reloadAfterCurrentLoad()
            }
        } else if viewModel.service.capabilities.contains(.upload),
                  canBeginUserPresentation {
            isImportingFiles = true
        }
    }

    private var displayedItems: [RemoteFileItem] {
        viewModel.displayedItems
    }

    private var displayRequest: DisplayRequest {
        DisplayRequest(query: searchText, sortOptions: sortOptions)
    }

    private var currentPathBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if let parentPathComponent {
                        NavigationLink {
                            pathDestination(
                                path: parentPathComponent.path,
                                title: parentPathTitle(parentPathComponent)
                            )
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SkyBreezeTheme.accent)
                                .frame(width: 36, height: 28)
                                .background(
                                    SkyBreezeTheme.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("상위 폴더")
                        .accessibilityHint("\(parentPathComponent.title) 폴더로 이동합니다.")
                    }

                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.tint)

                    NavigationLink {
                        pathDestination(
                            path: viewModel.connection.normalizedRootPath,
                            title: viewModel.connection.name
                        )
                    } label: {
                        Text(viewModel.connection.name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.path == viewModel.connection.normalizedRootPath)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    ForEach(Array(pathComponents.enumerated()), id: \.element.id) { index, component in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        NavigationLink {
                            pathDestination(path: component.path, title: component.title)
                        } label: {
                            Text(component.title)
                        }
                        .buttonStyle(.plain)
                        .fontDesign(.monospaced)
                        .foregroundStyle(component.path == viewModel.path ? .primary : .secondary)
                        .disabled(component.path == viewModel.path)
                    }
                }
                .lineLimit(1)
            }
            .contentShape(Rectangle())

            Text(itemCountLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(viewModel.connection.name), 현재 경로 \(viewModel.path), \(itemCountLabel)"
        )
    }

    private var pathComponents: [FileBrowserPathComponent] {
        FileBrowserPathNavigation.components(
            currentPath: viewModel.path,
            rootPath: viewModel.connection.normalizedRootPath
        )
    }

    private var parentPathComponent: FileBrowserPathComponent? {
        FileBrowserPathNavigation.parent(
            currentPath: viewModel.path,
            rootPath: viewModel.connection.normalizedRootPath
        )
    }

    private func parentPathTitle(_ component: FileBrowserPathComponent) -> String {
        component.path == viewModel.connection.normalizedRootPath
            ? viewModel.connection.name
            : component.title
    }

    private func pathDestination(path: String, title: String) -> some View {
        FileBrowserView(
            connection: viewModel.connection,
            path: path,
            service: viewModel.service,
            title: title,
            operationCoordinator: operationCoordinator,
            trafficTracker: trafficTracker,
            returnToDashboardAction: dashboardAction
        )
    }

    private var thumbnailProgressLine: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color(uiColor: .separator).opacity(0.38)

                    if thumbnailActivity.isActive {
                        SkyBreezeTheme.accent
                            .frame(
                                width: geometry.size.width
                                    * thumbnailActivity.fractionCompleted
                            )
                            .animation(
                                .easeOut(duration: 0.18),
                                value: thumbnailActivity.fractionCompleted
                            )
                    }
                }
            }
            .frame(height: 3)

            if let limitMessage = thumbnailActivity.limitMessage {
                Text(limitMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            thumbnailActivity.limitMessage ?? "현재 화면 썸네일 만드는 중"
        )
        .accessibilityValue(
            thumbnailActivity.isActive
                ? "\(Int((thumbnailActivity.fractionCompleted * 100).rounded()))퍼센트"
                : "대기 중"
        )
        .accessibilityHidden(
            !thumbnailActivity.isActive && thumbnailActivity.limitMessage == nil
        )
    }

    private var itemCountLabel: String {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            return "\(displayedItems.count)/\(viewModel.items.count)개"
        }
        return "\(viewModel.items.count)개"
    }

    private func thumbnailGrid(for style: LayoutStyle) -> some View {
        ScrollView {
            LazyVGrid(
                columns: columns(for: style),
                spacing: style == .largeThumbnails ? 20 : 12
            ) {
                ForEach(displayedItems) { item in
                    gridItem(item, style: style)
                }
            }
            .padding(style == .largeThumbnails ? 16 : 10)
        }
    }

    private func columns(for style: LayoutStyle) -> [GridItem] {
        let minimum: CGFloat
        let maximum: CGFloat
        let spacing: CGFloat

        switch style {
        case .list:
            minimum = 320
            maximum = 600
            spacing = 12
        case .smallThumbnails:
            minimum = dynamicTypeSize.isAccessibilitySize ? 118 : 78
            maximum = dynamicTypeSize.isAccessibilitySize ? 155 : 104
            spacing = 8
        case .largeThumbnails:
            minimum = dynamicTypeSize.isAccessibilitySize ? 270 : 158
            maximum = 340
            spacing = 16
        case .coverFlow:
            minimum = 320
            maximum = 600
            spacing = 12
        }

        return [
            GridItem(
                .adaptive(minimum: minimum, maximum: maximum),
                spacing: spacing,
                alignment: .top
            )
        ]
    }

    private var list: some View {
        List(displayedItems) { item in
            listItem(item)
        }
        .listStyle(.plain)
    }

    private func gridItem(_ item: RemoteFileItem, style: LayoutStyle) -> some View {
        ZStack(alignment: .topTrailing) {
            RemoteFileGridCell(
                item: item,
                service: viewModel.service,
                isLarge: style == .largeThumbnails,
                thumbnailReloadVersion: thumbnailReloadVersion
            )

            if isSelecting {
                selectionIndicator(isSelected: selectedItemIDs.contains(item.id))
                    .padding(style == .largeThumbnails ? 8 : 4)
            }
        }
        .contentShape(Rectangle())
        .gesture(itemInteractionGesture(for: item))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(item) }
        .accessibilityAction(named: "작업 보기") { showItemPanel(for: item) }
    }

    private func listItem(_ item: RemoteFileItem) -> some View {
        HStack(spacing: 8) {
            RemoteFileListRow(
                item: item,
                service: viewModel.service,
                thumbnailReloadVersion: thumbnailReloadVersion
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelecting {
                selectionIndicator(isSelected: selectedItemIDs.contains(item.id))
            }
        }
        .contentShape(Rectangle())
        .gesture(itemInteractionGesture(for: item))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(item) }
        .accessibilityAction(named: "작업 보기") { showItemPanel(for: item) }
    }

    private func itemInteractionGesture(for item: RemoteFileItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 20)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first:
                    showItemPanel(for: item)
                case .second:
                    activate(item)
                }
            }
    }

    private func showItemPanel(for item: RemoteFileItem) {
        guard !isSelecting else { return }
        interactionCoordinator.showItemPanel(item)
    }

    private func activate(_ item: RemoteFileItem) {
        switch FileBrowserInteractionCoordinator.activation(
            for: item,
            isSelecting: isSelecting
        ) {
        case .toggleSelection:
            guard !shareCoordinator.isPreparing else { return }
            toggleSelection(for: item)
        case .openFolder:
            navigatedFolder = item
        case .preview:
            guard canBeginUserPresentation else { return }
            previewItem = item
        }
    }

    private func contextActionPopover(for item: RemoteFileItem) -> some View {
        itemActionPanel(for: item)
            .frame(width: 340)
            .presentationCompactAdaptation(.popover)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2.weight(.semibold))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .background(.regularMaterial, in: Circle())
            .accessibilityHidden(true)
    }

    private func itemActionPanel(for item: RemoteFileItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.isDirectory ? "폴더 작업" : "파일 작업")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 4) {
                CompactPanelButton(title: "선택", systemImage: "checkmark.circle") {
                    performContextPanelAction { beginQuickSelection(with: item) }
                }
                .disabled(
                    selectionInteractionsAreBlocked
                        || hasBlockingPresentation
                        || hasPendingError
                )

                CompactPanelButton(title: "복사", systemImage: "doc.on.doc") {
                    performContextPanelAction {
                        operationCoordinator.placeOnClipboard([item], mode: .copy)
                    }
                }
                .disabled(
                    !viewModel.service.capabilities.supports(.copy)
                        || selectionInteractionsAreBlocked
                )

                CompactPanelButton(title: "이동", systemImage: "folder") {
                    performContextPanelAction {
                        operationCoordinator.placeOnClipboard([item], mode: .move)
                    }
                }
                .disabled(
                    !viewModel.service.capabilities.supports(.move)
                        || selectionInteractionsAreBlocked
                )

                CompactPanelButton(title: "수정", systemImage: "pencil") {
                    performContextPanelAction {
                        guard canBeginUserPresentation else { return }
                        renameText = item.name
                        renameItem = item
                    }
                }
                .disabled(
                    !viewModel.service.capabilities.contains(.rename)
                        || !canBeginUserPresentation
                )

                CompactPanelButton(
                    title: "삭제",
                    systemImage: "trash",
                    tint: .red
                ) {
                    performContextPanelAction {
                        guard canBeginUserPresentation else { return }
                        pendingDeleteItems = [item]
                    }
                }
                .disabled(
                    !viewModel.service.capabilities.contains(.delete)
                        || !canBeginUserPresentation
                )
            }

            HStack(spacing: 4) {
                CompactPanelButton(
                    title: favoriteStore.contains(item) ? "별 해제" : "즐겨찾기",
                    systemImage: favoriteStore.contains(item) ? "star.slash" : "star"
                ) {
                    performContextPanelAction {
                        favoriteStore.toggle(item)
                    }
                }

                if !item.isDirectory {
                    CompactPanelButton(title: "받기", systemImage: "arrow.down.circle") {
                        performContextPanelAction {
                            downloadToInbox([item])
                        }
                    }
                    .disabled(downloadTask != nil)

                    CompactPanelButton(title: "공유", systemImage: "square.and.arrow.up") {
                        performContextPanelAction {
                            guard canBeginUserPresentation else { return }
                            shareCoordinator.prepare(items: [item], using: viewModel.service)
                        }
                    }
                    .disabled(!canBeginUserPresentation)
                }

                if thumbnailPreheater.isRunning {
                    CompactPanelButton(title: "생성 중지", systemImage: "stop.circle", tint: .red) {
                        performContextPanelAction {
                            ownsAutomaticThumbnailPreheat = false
                            automaticThumbnailRestartTask?.cancel()
                            automaticThumbnailRestartTask = nil
                            thumbnailPreheater.cancel()
                        }
                    }
                } else if !item.isDirectory,
                          ThumbnailPreheatPolicy.canGenerate(
                    item: item,
                    connectionKind: viewModel.service.connection.kind,
                    supportsRangeStreaming: viewModel.service.supportsRangeStreaming
                ) {
                    CompactPanelButton(title: "이 파일 썸네일", systemImage: "photo.stack") {
                        performContextPanelAction {
                            startThumbnailPreheating(for: item, recursively: false)
                        }
                    }
                }
            }

            itemInformationPanel(item)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .buttonStyle(.plain)
    }

    private func itemInformationPanel(_ item: RemoteFileItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CompactInformationRow(title: "이름", value: item.name)
            CompactInformationRow(title: "미디어", value: item.browserMediaLabel)
            CompactInformationRow(title: "특징", value: item.browserFeatureLabel)
            CompactInformationRow(title: "생성/수정", value: item.browserDateLabel)
            CompactInformationRow(
                title: "크기",
                value: item.browserFormattedSize ?? (item.isDirectory ? "폴더" : "알 수 없음")
            )
        }
        .padding(10)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func performContextPanelAction(
        _ action: @escaping @MainActor () -> Void
    ) {
        interactionCoordinator.dismissPanel(then: action)
    }

    private var selectedItems: [RemoteFileItem] {
        viewModel.items.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectedFiles: [RemoteFileItem] {
        selectedItems.filter { !$0.isDirectory }
    }

    private var allVisibleItemsAreSelected: Bool {
        !displayedItems.isEmpty
            && displayedItems.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    private var selectionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label("\(selectedItemIDs.count)개 선택", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(selectedItemIDs.isEmpty ? .secondary : .primary)

                Spacer()

                Button(selectAllButtonTitle) {
                    toggleSelectAll()
                }
                .font(.subheadline.weight(.semibold))
                .disabled(displayedItems.isEmpty || selectionInteractionsAreBlocked)
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    if viewModel.service.capabilities.supports(.copy) {
                        selectionActionButton("복사", systemImage: "doc.on.doc") {
                            operationCoordinator.placeOnClipboard(selectedItems, mode: .copy)
                            endSelection()
                        }
                    }

                    if viewModel.service.capabilities.supports(.move) {
                        selectionActionButton("이동", systemImage: "folder") {
                            operationCoordinator.placeOnClipboard(selectedItems, mode: .move)
                            endSelection()
                        }
                    }

                    if viewModel.service.capabilities.contains(.delete) {
                        selectionActionButton("삭제", systemImage: "trash", role: .destructive) {
                            guard canBeginUserPresentation else { return }
                            pendingDeleteItems = selectedItems
                        }
                    }

                    selectionActionButton("공유", systemImage: "square.and.arrow.up") {
                        guard canBeginUserPresentation else { return }
                        let files = selectedFiles
                        guard !files.isEmpty else { return }
                        guard files.count == selectedItems.count else {
                            shareCoordinator.errorMessage = "폴더는 직접 공유할 수 없습니다. 파일만 선택해 주세요."
                            return
                        }
                        shareCoordinator.prepare(items: files, using: viewModel.service)
                    }
                    .disabled(selectedFiles.isEmpty || shareCoordinator.isPreparing)

                    selectionActionButton("받기", systemImage: "arrow.down.circle") {
                        let files = selectedFiles
                        guard !files.isEmpty else { return }
                        downloadToInbox(files)
                        endSelection()
                    }
                    .disabled(selectedFiles.isEmpty || downloadTask != nil)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectAllButtonTitle: String {
        if allVisibleItemsAreSelected {
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "전체 해제"
                : "검색 결과 해제"
        }
        return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "전체 선택"
            : "검색 결과 선택"
    }

    private func selectionActionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2)
            }
            .frame(minWidth: 58)
        }
        .buttonStyle(.plain)
        .disabled(
            selectedItemIDs.isEmpty
                || selectionInteractionsAreBlocked
                || hasBlockingPresentation
                || hasPendingError
        )
    }

    private func toggleSelection(for item: RemoteFileItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func toggleSelectAll() {
        let visibleIDs = Set(displayedItems.map(\.id))
        if allVisibleItemsAreSelected {
            selectedItemIDs.subtract(visibleIDs)
        } else {
            selectedItemIDs.formUnion(visibleIDs)
        }
    }

    private func beginQuickSelection(with item: RemoteFileItem) {
        guard !selectionInteractionsAreBlocked,
              !hasBlockingPresentation,
              !hasPendingError else { return }

        let wasInserted = selectedItemIDs.insert(item.id).inserted
        isSelecting = true
        if wasInserted {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func endSelection(allowDuringSharePreparation: Bool = false) {
        guard allowDuringSharePreparation || !shareCoordinator.isPreparing else { return }
        isSelecting = false
        selectedItemIDs.removeAll()
    }

    private func sequentialPreviewItems(for item: RemoteFileItem) -> [RemoteFileItem] {
        guard item.isImage || item.isVideo else { return [item] }
        return displayedItems.contains(item) ? displayedItems : [item]
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: {
                guard !hasBlockingPresentation,
                      !shareCoordinator.isPreparing else { return false }
                return hasPendingError
            },
            set: {
                if !$0 {
                    viewModel.errorMessage = nil
                    shareCoordinator.errorMessage = nil
                    operationCoordinator.dismissError()
                    thumbnailPreheater.errorMessage = nil
                    downloadErrorMessage = nil
                }
            }
        )
    }

    private var errorTitle: String {
        if downloadErrorMessage != nil {
            return "파일을 받을 수 없습니다"
        }
        if shareCoordinator.errorMessage != nil {
            return "파일을 공유할 수 없습니다"
        }
        if operationCoordinator.errorMessage != nil {
            return "파일 작업을 완료하지 못했습니다"
        }
        if thumbnailPreheater.errorMessage != nil {
            return "썸네일을 미리 만들 수 없습니다"
        }
        return "오류"
    }

    /// All user-driven modal entry points use this gate. In particular, a
    /// Share preparation remains in selection mode until its sheet is ready,
    /// so its asynchronous completion cannot race a preview or edit confirmation.
    private var canBeginUserPresentation: Bool {
        !shareCoordinator.isPreparing
            && !operationCoordinator.isBusy
            && !thumbnailPreheater.isRunning
            && !hasBlockingPresentation
            && !hasPendingError
    }

    private var selectionInteractionsAreBlocked: Bool {
        shareCoordinator.isPreparing || operationCoordinator.isBusy || downloadTask != nil
    }

    private var hasBlockingPresentation: Bool {
        shareCoordinator.preparedShare != nil
            || previewItem != nil
            || !pendingDeleteItems.isEmpty
            || renameItem != nil
            || isCreatingFolder
            || isImportingFiles
    }

    private var hasPendingError: Bool {
        shareCoordinator.errorMessage != nil
            || operationCoordinator.errorMessage != nil
            || thumbnailPreheater.errorMessage != nil
            || downloadErrorMessage != nil
            || (viewModel.errorMessage != nil && !viewModel.items.isEmpty)
    }

    private func downloadToInbox(_ items: [RemoteFileItem]) {
        let files = FileBrowserDownloadPolicy.downloadableItems(from: items)
        guard !files.isEmpty, downloadTask == nil else { return }
        downloadCompletedCount = 0
        downloadTotalCount = files.count
        downloadErrorMessage = nil
        downloadTask = Task { @MainActor in
            do {
                for item in files {
                    try Task.checkCancellation()
                    downloadItemName = item.name
                    let url = try await viewModel.service.download(item)
                    try Task.checkCancellation()
                    _ = try await inboxStore.importDownloadedFile(
                        at: url,
                        originalFilename: item.name,
                        contentTypeIdentifier: item.contentTypeIdentifier
                    )
                    downloadCompletedCount += 1
                }
                operationCoordinator.statusMessage = files.count == 1
                    ? "받은 파일에 저장했습니다."
                    : "파일 \(files.count)개를 받은 파일에 저장했습니다."
            } catch is CancellationError {
                // 사용자가 취소한 경우 완료된 파일은 그대로 보존합니다.
            } catch {
                downloadErrorMessage = "\(downloadItemName ?? "파일")을 받지 못했습니다: \(error.localizedDescription)"
            }
            downloadTask = nil
            downloadItemName = nil
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadItemName = nil
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeleteItems.isEmpty },
            set: { if !$0 { pendingDeleteItems = [] } }
        )
    }

    private var deleteConfirmationTitle: String {
        "\(pendingDeleteItems.count)개 항목을 삭제할까요?"
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )
    }
}

private struct RemoteFileGridCell: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: RemoteFileItem
    let service: any RemoteFileService
    let isLarge: Bool
    let thumbnailReloadVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 9 : 6) {
            RemoteThumbnailView(
                item: item,
                service: service,
                size: thumbnailRequestSize,
                reloadVersion: thumbnailReloadVersion
            )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(
                    SkyBreezeTheme.thumbnailSurface,
                    in: RoundedRectangle(cornerRadius: isLarge ? 15 : 11)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: isLarge ? 15 : 11)
                        .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: isLarge ? 15 : 11))

            Text(item.name)
                .font(isLarge ? .headline : .caption)
                .fontWeight(isLarge ? .semibold : .regular)
                .foregroundStyle(SkyBreezeTheme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(isLarge ? 0.85 : 0.72)
                .allowsTightening(true)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity)

            RemoteFileMetadataView(
                item: item,
                showsModifiedDate: isLarge,
                includesTime: isLarge,
                compact: !isLarge
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.browserAccessibilityLabel)
    }

    private var thumbnailRequestSize: CGSize {
        if isLarge {
            return CGSize(width: 280, height: 280)
        }
        return CGSize(width: 104, height: 104)
    }
}

private struct RemoteFileListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: RemoteFileItem
    let service: any RemoteFileService
    let thumbnailReloadVersion: Int

    var body: some View {
        HStack(spacing: 12) {
            RemoteThumbnailView(
                item: item,
                service: service,
                size: CGSize(width: thumbnailSide, height: thumbnailSide),
                reloadVersion: thumbnailReloadVersion
            )
                .frame(width: thumbnailSide, height: thumbnailSide)
                .background(SkyBreezeTheme.thumbnailSurface, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(SkyBreezeTheme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)

                RemoteFileMetadataView(
                    item: item,
                    showsModifiedDate: true,
                    includesTime: true,
                    compact: false
                )
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.browserAccessibilityLabel)
    }

    private var thumbnailSide: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 50 : 58
    }
}

private struct RemoteFileMetadataView: View {
    let item: RemoteFileItem
    let showsModifiedDate: Bool
    let includesTime: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !item.isDirectory {
                if compact {
                    HStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityLabel(item.browserKindLabel)

                        Text(item.browserFormattedSize ?? "크기 정보 없음")
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .allowsTightening(true)
                            .monospacedDigit()
                            .layoutPriority(1)
                    }
                } else {
                    Text(item.browserKindAndSizeLabel)
                        .lineLimit(2)
                }
            }

            if showsModifiedDate, let modifiedAt = item.modifiedAt {
                if includesTime {
                    Text(
                        modifiedAt,
                        format: .dateTime
                            .year()
                            .month()
                            .day()
                            .hour()
                            .minute()
                    )
                } else {
                    Text(modifiedAt, format: .dateTime.year().month().day())
                }
            }
        }
        .font(compact ? .caption2 : .caption)
        .foregroundStyle(SkyBreezeTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension RemoteFileItem {
    var browserMediaLabel: String {
        if isDirectory { return "폴더" }
        if isImage { return "사진" }
        if isVideo { return "비디오" }
        if contentType.conforms(to: .audio) { return "오디오" }
        return "파일"
    }

    var browserFeatureLabel: String {
        if isDirectory { return "하위 항목을 담는 폴더" }
        let filenameExtension = (name as NSString).pathExtension.uppercased()
        let description = contentType.localizedDescription ?? "파일"
        guard !filenameExtension.isEmpty else { return description }
        return "\(filenameExtension) · \(description)"
    }

    var browserDateLabel: String {
        guard let modifiedAt else { return "알 수 없음" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var browserKindLabel: String {
        if isDirectory {
            return "\u{D3F4}\u{B354}"
        }

        let filenameExtension = (name as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !filenameExtension.isEmpty {
            return filenameExtension.uppercased()
        }

        if let localizedDescription = contentType.localizedDescription,
           !localizedDescription.isEmpty {
            return localizedDescription
        }
        return "\u{D30C}\u{C77C}"
    }

    var browserKindAndSizeLabel: String {
        guard !isDirectory, let browserFormattedSize else { return browserKindLabel }
        return "\(browserKindLabel) • \(browserFormattedSize)"
    }

    var browserFormattedSize: String? {
        guard !isDirectory, let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var browserAccessibilityLabel: String {
        var parts = [name, browserKindLabel]
        if !isDirectory, let size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modifiedAt {
            let formattedDate = DateFormatter.localizedString(
                from: modifiedAt,
                dateStyle: .medium,
                timeStyle: .short
            )
            parts.append("\u{C218}\u{C815}\u{C77C} \(formattedDate)")
        }
        return parts.joined(separator: ", ")
    }
}

@MainActor
private final class RemoteFileShareCoordinator: ObservableObject {
    @Published private(set) var preparingItemName: String?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published var preparedShare: PreparedRemoteFileShare?
    @Published var errorMessage: String?

    private var preparationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var presentedTemporaryDirectoryURL: URL?

    var isPreparing: Bool { preparationTask != nil }

    func prepare(items: [RemoteFileItem], using service: any RemoteFileService) {
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty,
              preparationTask == nil,
              preparedShare == nil else { return }

        let currentOperationID = UUID()
        operationID = currentOperationID
        preparingItemName = files.first?.name
        completedCount = 0
        totalCount = files.count
        errorMessage = nil
        Self.cleanStaleShareDirectories()

        preparationTask = Task { [weak self] in
            let temporaryDirectoryURL = FileManager.default.temporaryDirectory
                .appending(path: "NasFinderShares", directoryHint: .isDirectory)
                .appending(path: currentOperationID.uuidString, directoryHint: .isDirectory)
            do {
                try await Self.createShareDirectory(at: temporaryDirectoryURL)

                var stagedURLs: [URL] = []
                var usedFilenames: Set<String> = []
                for (index, item) in files.enumerated() {
                    try Task.checkCancellation()
                    guard let self,
                          self.operationID == currentOperationID else {
                        throw CancellationError()
                    }
                    self.preparingItemName = item.name

                    let downloadedURL = try await service.download(item)
                    try Task.checkCancellation()
                    let baseFilename = Self.safeFilename(
                        item.name,
                        fallbackURL: downloadedURL
                    )
                    let filename = Self.uniqueFilename(
                        baseFilename,
                        usedFilenames: &usedFilenames
                    )
                    let stagedURL = temporaryDirectoryURL.appending(
                        path: filename,
                        directoryHint: .notDirectory
                    )
                    try await Self.stageForSharing(
                        downloadedURL: downloadedURL,
                        stagedURL: stagedURL
                    )
                    stagedURLs.append(stagedURL)
                    self.completedCount = index + 1
                }

                guard let self,
                      self.operationID == currentOperationID else {
                    await Self.removeShareDirectory(at: temporaryDirectoryURL)
                    return
                }
                self.presentedTemporaryDirectoryURL = temporaryDirectoryURL
                self.preparedShare = PreparedRemoteFileShare(
                    fileURLs: stagedURLs,
                    temporaryDirectoryURL: temporaryDirectoryURL
                )
                self.finish(operationID: currentOperationID)
            } catch is CancellationError {
                await Self.removeShareDirectory(at: temporaryDirectoryURL)
                self?.finish(operationID: currentOperationID)
            } catch {
                await Self.removeShareDirectory(at: temporaryDirectoryURL)
                guard let self,
                      self.operationID == currentOperationID else { return }
                self.errorMessage = error.localizedDescription
                self.finish(operationID: currentOperationID)
            }
        }
    }

    func cancelPreparation() {
        operationID = nil
        preparationTask?.cancel()
        preparationTask = nil
        preparingItemName = nil
        completedCount = 0
        totalCount = 0
    }

    func shareSheetDidDismiss() {
        preparedShare = nil
        guard let presentedTemporaryDirectoryURL else { return }
        self.presentedTemporaryDirectoryURL = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: presentedTemporaryDirectoryURL)
        }
    }

    private func finish(operationID completedOperationID: UUID) {
        guard operationID == completedOperationID else { return }
        operationID = nil
        preparationTask = nil
        preparingItemName = nil
    }

    private static func createShareDirectory(at url: URL) async throws {
        try await performCancellableFileWork {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
        }
    }

    private static func stageForSharing(
        downloadedURL: URL,
        stagedURL: URL
    ) async throws {
        try await performCancellableFileWork {
            let fileManager = FileManager.default
            guard downloadedURL.isFileURL,
                  fileManager.fileExists(atPath: downloadedURL.path) else {
                throw RemoteFileShareError.downloadedFileMissing
            }

            do {
                try fileManager.linkItem(at: downloadedURL, to: stagedURL)
            } catch {
                let source = try FileHandle(forReadingFrom: downloadedURL)
                defer { try? source.close() }
                guard fileManager.createFile(atPath: stagedURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let destination = try FileHandle(forWritingTo: stagedURL)
                defer { try? destination.close() }

                while true {
                    try Task.checkCancellation()
                    let data = try source.read(upToCount: 1_024 * 1_024) ?? Data()
                    guard !data.isEmpty else { break }
                    try destination.write(contentsOf: data)
                }
                try destination.synchronize()
            }
        }
    }

    private static func removeShareDirectory(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    private static func performCancellableFileWork<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func cleanStaleShareDirectories() {
        Task.detached(priority: .background) {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appending(
                path: "NasFinderShares",
                directoryHint: .isDirectory
            )
            let urls = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let expirationDate = Date().addingTimeInterval(-24 * 60 * 60)
            for url in urls {
                let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if (date ?? .distantPast) < expirationDate {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    private static func safeFilename(_ filename: String, fallbackURL: URL) -> String {
        let basename = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !basename.isEmpty, basename != ".", basename != ".." {
            return basename
        }

        let fallback = fallbackURL.lastPathComponent
        return fallback.isEmpty ? "NasFinder File" : fallback
    }

    private static func uniqueFilename(
        _ filename: String,
        usedFilenames: inout Set<String>
    ) -> String {
        let key = filename.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        guard usedFilenames.contains(key) else {
            usedFilenames.insert(key)
            return filename
        }

        let filenameExtension = (filename as NSString).pathExtension
        let basename = (filename as NSString).deletingPathExtension
        var suffix = 2
        while true {
            let candidate = filenameExtension.isEmpty
                ? "\(basename) (\(suffix))"
                : "\(basename) (\(suffix)).\(filenameExtension)"
            let candidateKey = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if !usedFilenames.contains(candidateKey) {
                usedFilenames.insert(candidateKey)
                return candidate
            }
            suffix += 1
        }
    }
}

private struct PreparedRemoteFileShare: Identifiable {
    let id = UUID()
    let fileURLs: [URL]
    let temporaryDirectoryURL: URL
}

private enum RemoteFileShareError: LocalizedError {
    case downloadedFileMissing

    var errorDescription: String? {
        "내려받은 파일을 찾을 수 없습니다. 다시 시도해 주세요."
    }
}

private struct ThumbnailPreheatProgressBanner: View {
    @ObservedObject var preheater: ThumbnailPreheater

    var body: some View {
        HStack(spacing: 12) {
            if let fraction = preheater.fractionCompleted {
                ProgressView(value: fraction)
                    .frame(width: 54)
            } else {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(preheater.totalCount == 0 ? "미디어 폴더 검색 중…" : "썸네일 미리 만드는 중…")
                    .font(.subheadline.weight(.semibold))
                Text(progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("중지", role: .cancel) {
                preheater.cancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }

    private var progressDescription: String {
        var parts: [String] = []
        if preheater.totalCount > 0 {
            parts.append("\(preheater.completedCount) / \(preheater.totalCount)")
        }
        if preheater.transferredBytes > 0 {
            parts.append(Self.byteFormatter.string(fromByteCount: preheater.transferredBytes))
        }
        if let currentItemName = preheater.currentItemName {
            parts.append(currentItemName)
        }
        return parts.isEmpty ? "준비 중" : parts.joined(separator: " • ")
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()
}

private struct MorePanelSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

private struct CompactPanelButton: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var tint = Color(uiColor: .label)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(isSelected ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                isSelected ? SkyBreezeTheme.accent : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected
                            ? SkyBreezeTheme.accent
                            : Color(uiColor: .separator).opacity(0.24),
                        lineWidth: 0.75
                    )
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

private struct CompactPanelOptionRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)

            content
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 5)
    }
}

private struct CompactPanelOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : Color(uiColor: .label)
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    isSelected
                        ? SkyBreezeTheme.accent
                        : Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected
                                ? SkyBreezeTheme.accent
                                : Color(uiColor: .separator).opacity(0.24),
                            lineWidth: 0.75
                        )
                }
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CompactInformationRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }
}

private struct MorePanelRow: View {
    let title: String
    let systemImage: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(.tint)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

private struct SharePreparationBanner: View {
    let itemName: String?
    let completedCount: Int
    let totalCount: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()

            VStack(alignment: .leading, spacing: 2) {
                Text("공유할 파일을 내려받는 중…")
                    .font(.subheadline.weight(.semibold))
                Text(progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("취소", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }

    private var progressDescription: String {
        let name = itemName ?? "파일 준비 중"
        guard totalCount > 1 else { return name }
        return "\(completedCount) / \(totalCount) • \(name)"
    }
}

struct FileOperationProgressBanner: View {
    let title: String
    let progress: RemoteOperationProgress?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .frame(width: 54)
            } else {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let progress {
                    Text(progressDescription(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button("취소", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }

    private func progressDescription(_ progress: RemoteOperationProgress) -> String {
        if progress.unit == .bytes,
           let total = progress.totalUnitCount,
           total > 0 {
            let completedText = ByteCountFormatter.string(
                fromByteCount: progress.completedUnitCount,
                countStyle: .file
            )
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(completedText) / \(totalText)"
        }
        if let total = progress.totalUnitCount {
            return "\(progress.completedUnitCount) / \(total)"
        }
        return progress.phase.localizedTitle
    }
}

struct FileOperationStatusBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("상태 메시지 닫기")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }
}

private extension RemoteOperationPhase {
    var localizedTitle: String {
        switch self {
        case .preparing: "준비 중"
        case .reading: "읽는 중"
        case .writing: "쓰는 중"
        case .committing: "반영 중"
        case .deleting: "삭제 중"
        case .rollingBack: "복구 중"
        case .completed: "완료"
        }
    }
}

private struct ThumbnailNetworkChangeModifier: ViewModifier {
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(
                for: .thumbnailNetworkPathDidChange
            )
        ) { _ in
            onChange()
        }
    }
}

private struct FileBrowserCoverFlowChromeModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isActive)
            .toolbar(isActive ? .hidden : .visible, for: .navigationBar)
    }
}

private struct RemoteFileActivityView: UIViewControllerRepresentable {
    let fileURLs: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: fileURLs,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
