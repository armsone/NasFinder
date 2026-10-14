import SwiftUI
import UIKit
import UniformTypeIdentifiers

typealias ReturnToDashboardAction = @MainActor @Sendable () -> Void

enum FileBrowserDownloadPolicy {
    static func downloadableItems(from items: [RemoteFileItem]) -> [RemoteFileItem] {
        items.filter { !$0.isDirectory }
    }
}

private struct FileBrowserBackTouchTarget: UIViewRepresentable {
    let goBack: () -> Void
    let goHome: ReturnToDashboardAction

    func makeCoordinator() -> Coordinator {
        Coordinator(goBack: goBack, goHome: goHome)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 30
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // A recognized long press must never also navigate back on release.
        tap.require(toFail: longPress)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.goBack = goBack
        context.coordinator.goHome = goHome
    }

    @MainActor
    final class Coordinator: NSObject {
        var goBack: () -> Void
        var goHome: ReturnToDashboardAction

        init(goBack: @escaping () -> Void, goHome: @escaping ReturnToDashboardAction) {
            self.goBack = goBack
            self.goHome = goHome
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            goHome()
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            goBack()
        }
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
                .uiBarFont(.headline)
                .lineLimit(1)

            HStack(spacing: ui(7)) {
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
            .uiBarFont(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: ui(230), minHeight: uiBar(44))
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
                .uiBarFont(.caption2)
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
    @State private var trailerSelection: VideoTrailerSelection?
    @State private var folderTrailerScopeChoice: RemoteFileItem?
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
    @State private var isSearchPresented = false
    @State private var thumbnailReloadVersion = 0
    @State private var isRequestingCoverFlowOrientation = false
    @State private var coverFlowEnteredFromPoster = false
    @State private var suppressAutomaticCoverFlowUntil = Date.distantPast
    @State private var browserContentSize = CGSize.zero
    @StateObject private var downloadCoordinator = RemoteDownloadCoordinator()
    @State private var pendingDownloadItems: [RemoteFileItem] = []
    @State private var downloadDestinationStep: RemoteDownloadDestinationStep?
    @State private var folderTrailerScopeMode = VideoTrailerMode.trailer
    @State private var downloadErrorMessage: String?
    /// A folder share is being received; its share sheet opens when that finishes.
    @State private var isStagingFolderShare = false
    @State private var isImportingFromGooglePhotos = false
    @State private var pendingNASUploadSources: [LocalUploadSource] = []
    @State private var isChoosingNASUploadDestination = false

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
        // PhoneHard reads files already on the device; none of that is network traffic.
        if service is TrafficMeasuringRemoteFileService || service is LocalInboxFileService {
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

    /// PhoneHard, the storage on this device, opened in this same browser.
    private var isPhoneHard: Bool {
        viewModel.connection.id == LocalInboxFileService.connectionID
    }

    /// "서버 열기" belongs to PhoneHard as a whole, so it sits at its root only and
    /// starts folded.
    private var showsPhoneHardServerPanel: Bool {
        isPhoneHard && viewModel.path == LocalInboxFileService.rootPath && !isSelecting
    }

    private var phoneHardServerPanel: some View {
        WebHardConnectionPanel()
            .frame(maxWidth: ui(760))
            .frame(maxWidth: .infinity)
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
                    isCoverFlow: layoutStyle == .coverFlow,
                    usesDarkBackground: coverFlowUsesDarkBackground
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
                    isEnabled: true,
                    text: $searchText,
                    isPresented: $isSearchPresented
                )
            )
            .toolbar { browserToolbar }
            .overlay { coverFlowNavigationOverlay }
        )
        .navigationBarBackButtonHidden(true)
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
                    urls.map { LocalUploadSource(url: $0) },
                    into: viewModel.path,
                    using: viewModel.service,
                    conflictPolicy: .keepBoth,
                    operationName: isPhoneHard ? "가져오기" : "업로드"
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
        .fileDialogConfirmationLabel(isPhoneHard ? "가져오기" : "업로드")
        .fileDialogMessage(
            isPhoneHard ? "현재 폴더로 가져올 파일을 선택하세요." : "현재 폴더에 올릴 파일을 선택하세요."
        )
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
            // Only a saved connection can be reopened from the dashboard logo.
            if !isPhoneHard {
                connectionStore.rememberBrowserLocation(
                    connection: viewModel.connection,
                    path: viewModel.path,
                    title: title
                )
            }
        }
        .onChange(of: layoutStyle, initial: true) { _, style in
            updateCoverFlowOrientation(for: style)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateBrowserContentSize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in
                        updateBrowserContentSize(size)
                    }
            }
        }
        .task {
            await RemoteThumbnailDiskCache.shared.clearTransientFailures()
            await viewModel.load()
        }
        .overlay(alignment: .bottom) {
            browserStatusOverlay
        }
        .modifier(
            RemoteDownloadDestinationFlow(
                step: $downloadDestinationStep,
                inboxStore: inboxStore,
                itemCount: pendingDownloadItems.count,
                onChoose: startDownload
            )
        )
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
        .fullScreenCover(item: $trailerSelection) { selection in
            VideoTrailerView(items: selection.items, service: viewModel.service, mode: selection.mode)
        }
        .modifier(
            FileBrowserPhoneHardModifier(
                isPhoneHard: isPhoneHard,
                items: viewModel.items,
                inboxStore: inboxStore,
                isImportingFromGooglePhotos: $isImportingFromGooglePhotos,
                isChoosingNASUploadDestination: $isChoosingNASUploadDestination,
                nasUploadSources: pendingNASUploadSources,
                reloadItems: { await viewModel.reloadAfterCurrentLoad() },
                nasUploadDidClose: {
                    pendingNASUploadSources = []
                    endSelection()
                }
            )
        )
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
        .confirmationDialog(
            folderTrailerScopeMode == .mediaMusic ? "음악을 입힐 범위" : "예고편에 포함할 범위",
            isPresented: Binding(
                get: { folderTrailerScopeChoice != nil },
                set: { if !$0 { folderTrailerScopeChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("현재 폴더만") {
                if let folder = folderTrailerScopeChoice {
                    folderTrailerScopeChoice = nil
                    collectFolderTrailerCandidates(folder, recursive: false)
                }
            }
            Button("하위 폴더 포함") {
                if let folder = folderTrailerScopeChoice {
                    folderTrailerScopeChoice = nil
                    collectFolderTrailerCandidates(folder, recursive: true)
                }
            }
            Button("취소", role: .cancel) { folderTrailerScopeChoice = nil }
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
        .onChange(of: viewModel.items.map(\.id)) { _, visibleIDs in
            selectedItemIDs.formIntersection(visibleIDs)
            if isSelecting, viewModel.items.isEmpty {
                endSelection()
            }
            reconcileAutomaticCoverFlow()
        }
        .onChange(of: isSelecting) { _, _ in
            reconcileAutomaticCoverFlow()
        }
        .onChange(of: shareCoordinator.preparedShare?.id) { _, preparedID in
            if preparedID != nil {
                endSelection(allowDuringSharePreparation: true)
            }
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Group {
                if layoutStyle != .coverFlow {
                    browserBackButton
                }
            }
            .uiBarFont()
        }

        ToolbarItem(placement: .principal) {
            Group {
                if layoutStyle != .coverFlow {
                    Button {
                        isSearchPresented = true
                    } label: {
                        FileBrowserPageTitle(title: title, trafficTracker: trafficTracker)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("\(title), 검색")
                    .accessibilityHint("현재 폴더에서 파일을 검색합니다.")
                }
            }
            .uiBarFont()
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Group {
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
            .uiBarFont()
        }
    }

    private var browserBackButton: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: ui(17), weight: .semibold))
            .foregroundStyle(SkyBreezeTheme.accent)
            .frame(width: ui(32), height: ui(32))
            .background(SkyBreezeTheme.accent.opacity(0.12), in: Circle())
            .frame(width: uiBar(44), height: uiBar(44))
            .overlay {
                FileBrowserBackTouchTarget(
                    goBack: { dismiss() },
                    goHome: dashboardAction
                )
                .accessibilityHidden(true)
            }
            .accessibilityLabel("이전 폴더")
            .accessibilityHint("길게 누르면 NasFinder 첫 화면으로 바로 이동합니다.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                dismiss()
            }
            .accessibilityAction(named: "NasFinder 첫 화면") {
                dashboardAction()
            }
    }

    private var regularMoreButton: some View {
        Button {
            interactionCoordinator.showBrowserPanel()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: ui(15), weight: .bold))
                .foregroundStyle(SkyBreezeTheme.accent)
                .frame(width: ui(32), height: ui(32))
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
        .modifier(panelPopover(for: .browser) { browserMorePanel })
    }

    @ViewBuilder
    private var coverFlowNavigationOverlay: some View {
        if layoutStyle == .coverFlow {
            FileBrowserCoverFlowNavigationChrome(
                usesDarkBackground: coverFlowUsesDarkBackground
            ) { containerWidth in
                HStack(spacing: FileBrowserCoverFlowChromePolicy.itemSpacing) {
                    coverFlowBackButton

                    Button {
                        isSearchPresented = true
                    } label: {
                        Text(title)
                            .font(.ui(.subheadline).weight(.medium))
                            .foregroundStyle(
                                FileBrowserCoverFlowChromePolicy.foreground(
                                    usesDarkBackground: coverFlowUsesDarkBackground
                                )
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                            .frame(
                                maxWidth: FileBrowserCoverFlowChromePolicy
                                    .titleMaximumWidth(containerWidth: containerWidth),
                                minHeight: FileBrowserCoverFlowChromePolicy.buttonSize,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title), 검색")
                    .accessibilityHint("현재 폴더에서 파일을 검색합니다.")

                    Spacer(minLength: ui(8))
                    coverFlowMoreButton
                }
            }
        }
    }

    private var coverFlowBackButton: some View {
        FileBrowserCoverFlowChromeIcon(
            kind: .back,
            usesDarkBackground: coverFlowUsesDarkBackground
        )
        .overlay {
            FileBrowserBackTouchTarget(
                goBack: { dismiss() },
                goHome: dashboardAction
            )
            .accessibilityHidden(true)
        }
        .accessibilityLabel("이전 폴더")
        .accessibilityHint("길게 누르면 NasFinder 첫 화면으로 바로 이동합니다.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            dismiss()
        }
        .accessibilityAction(named: "NasFinder 첫 화면") {
            dashboardAction()
        }
    }

    private var coverFlowMoreButton: some View {
        Button {
            interactionCoordinator.showBrowserPanel()
        } label: {
            FileBrowserCoverFlowChromeIcon(
                kind: .more,
                usesDarkBackground: coverFlowUsesDarkBackground
            )
        }
        .buttonStyle(.plain)
        .disabled(operationCoordinator.isBusy)
        .accessibilityLabel("더 보기")
        .modifier(panelPopover(for: .browser) { browserMorePanel })
    }

    @ViewBuilder
    private var browserStatusOverlay: some View {
        if layoutStyle != .coverFlow || shareCoordinator.isPreparing {
            VStack(spacing: ui(8)) {
                if shareCoordinator.isPreparing {
                    SharePreparationBanner(
                        itemName: shareCoordinator.preparingItemName,
                        completedCount: shareCoordinator.completedCount,
                        totalCount: shareCoordinator.totalCount,
                        progress: shareCoordinator.downloadProgress,
                        isStaging: shareCoordinator.isStaging
                    ) {
                        shareCoordinator.cancelPreparation()
                    }
                }

                if downloadCoordinator.isRunning {
                    SharePreparationBanner(
                        itemName: downloadCoordinator.isCancelling
                            ? "취소하는 중…"
                            : downloadCoordinator.currentItemName,
                        completedCount: downloadCoordinator.completedCount,
                        totalCount: downloadCoordinator.totalCount,
                        progress: downloadCoordinator.byteProgress,
                        isStaging: false,
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
            .padding(.all, MacUIScale.defaultPadding)
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
            if showsPhoneHardServerPanel {
                ScrollView {
                    VStack(spacing: 0) {
                        phoneHardServerPanel
                            .padding(.horizontal, ui(16))
                            .padding(.vertical, ui(12))
                        ContentUnavailableView("빈 폴더", systemImage: "folder")
                            .padding(.vertical, ui(44))
                    }
                }
            } else {
                ContentUnavailableView("빈 폴더", systemImage: "folder")
            }
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
                    usesDarkBackground: $coverFlowUsesDarkBackground,
                    itemName: { $0.name },
                    thumbnail: { item, size, role, sharedLoader in
                        RemoteThumbnailView(
                            item: item,
                            service: viewModel.service,
                            size: size,
                            reloadVersion: thumbnailReloadVersion,
                            displayMode: FileBrowserCoverFlowPolicy
                                .thumbnailDisplayMode(for: role),
                            sharedLoader: sharedLoader
                        )
                    },
                    onActivate: activate,
                    onShowActions: showItemPanel,
                    actionsPopover: { item in
                        panelPopover(for: .item(item)) {
                            AnyView(contextActionPopover(for: item))
                        }
                    }
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

    private func updateBrowserContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        browserContentSize = size
        reconcileAutomaticCoverFlow()
    }

    private func reconcileAutomaticCoverFlow() {
        guard Date.now >= suppressAutomaticCoverFlowUntil else { return }
        let shouldPresent = FileBrowserOverflowPresentationPolicy
            .shouldPresentPosterAsOverflow(
                contentSize: browserContentSize,
                isSelecting: isSelecting,
                hasItems: !displayedItems.isEmpty
            )
        if shouldPresent,
           layoutStyle == .largeThumbnails {
            coverFlowEnteredFromPoster = true
            storedLayoutStyle = LayoutStyle.coverFlow.rawValue
        } else if !shouldPresent,
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

    /// Checks the folder's immediate children. If it contains subfolders, asks the user
    /// whether to include them before building the trailer selection; otherwise proceeds
    /// immediately with the immediate-only default.
    private func buildFolderTrailerSelection(
        _ folder: RemoteFileItem,
        mode: VideoTrailerMode = .trailer
    ) {
        Task {
            do {
                let children = try await viewModel.service.list(directory: folder.path)
                    .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
                if children.contains(where: \.isDirectory) {
                    folderTrailerScopeMode = mode
                    folderTrailerScopeChoice = folder
                } else {
                    let candidates = children.filter { !$0.isDirectory && $0.isTrailerEligible }
                    guard !candidates.isEmpty else {
                        downloadErrorMessage = Self.emptyFolderMediaMessage(for: mode)
                        return
                    }
                    trailerSelection = VideoTrailerSelection(items: candidates, mode: mode)
                }
            } catch {
                downloadErrorMessage = "폴더 내용을 확인하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    /// Reads the folder's children; when `recursive` is true, also walks immediate
    /// subfolders (depth-first, tracking visited paths to avoid cycles/duplicates from
    /// symlink-like providers). Non-media files are skipped silently; files that fail
    /// actual decode validation are skipped individually while the trailer is being
    /// built, without aborting the rest of the batch.
    private func collectFolderTrailerCandidates(_ folder: RemoteFileItem, recursive: Bool) {
        let mode = folderTrailerScopeMode
        Task {
            do {
                var candidates: [RemoteFileItem] = []
                var visitedPaths: Set<String> = []
                try await appendFolderTrailerCandidates(folder, recursive: recursive,
                    visitedPaths: &visitedPaths, into: &candidates)
                guard !candidates.isEmpty else {
                    downloadErrorMessage = Self.emptyFolderMediaMessage(for: mode)
                    return
                }
                trailerSelection = VideoTrailerSelection(items: candidates, mode: mode)
            } catch {
                downloadErrorMessage = "폴더 내용을 확인하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    private static func emptyFolderMediaMessage(for mode: VideoTrailerMode) -> String {
        mode == .mediaMusic
            ? "이 폴더에 음악을 입힐 수 있는 사진이나 영상이 없습니다."
            : "이 폴더에 예고편으로 쓸 수 있는 사진이나 영상이 없습니다."
    }

    private func appendFolderTrailerCandidates(
        _ folder: RemoteFileItem, recursive: Bool,
        visitedPaths: inout Set<String>, into candidates: inout [RemoteFileItem]
    ) async throws {
        guard !visitedPaths.contains(folder.path) else { return }
        visitedPaths.insert(folder.path)
        let children = try await viewModel.service.list(directory: folder.path)
            .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
        candidates.append(contentsOf: children.filter { !$0.isDirectory && $0.isTrailerEligible })
        guard recursive else { return }
        for subfolder in children where subfolder.isDirectory {
            try await appendFolderTrailerCandidates(subfolder, recursive: true,
                visitedPaths: &visitedPaths, into: &candidates)
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

    private func panelPopover<PanelContent: View>(
        for panel: FileBrowserInteractionCoordinator.Panel,
        @ViewBuilder content: @escaping () -> PanelContent
    ) -> FileBrowserPanelPopover<PanelContent> {
        FileBrowserPanelPopover(
            coordinator: interactionCoordinator,
            panel: panel,
            panelContent: content
        )
    }

    private var browserMorePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MorePanelSectionTitle("파일 작업")

                HStack(spacing: ui(4)) {
                    CompactPanelButton(title: "선택", systemImage: "checkmark.circle") {
                        performMorePanelAction { isSelecting = true }
                    }

                    // With nothing to paste this button picks files for the current
                    // folder; PhoneHard says so, since that is how files are brought in.
                    CompactPanelButton(
                        title: isPhoneHard && operationCoordinator.clipboard == nil
                            ? "가져오기"
                            : "붙여넣기",
                        systemImage: isPhoneHard && operationCoordinator.clipboard == nil
                            ? "doc.badge.plus"
                            : "doc.on.clipboard"
                    ) {
                        performMorePanelAction(performPasteAction)
                    }
                    .disabled(!canPerformPasteAction)

                    if isPhoneHard {
                        CompactPanelButton(title: "Google 포토", systemImage: "photo.badge.arrow.down") {
                            performMorePanelAction {
                                guard canBeginUserPresentation else { return }
                                isImportingFromGooglePhotos = true
                            }
                        }
                        .disabled(!canBeginUserPresentation)
                    }

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
                    .padding(.vertical, ui(6))
                MorePanelSectionTitle("보기")

                HStack(spacing: ui(4)) {
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
                        HStack(spacing: ui(4)) {
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
                    .padding(.vertical, ui(6))
                MorePanelSectionTitle("정렬")

                CompactPanelOptionRow(title: "기준") {
                    HStack(spacing: ui(4)) {
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
                    HStack(spacing: ui(4)) {
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
                    HStack(spacing: ui(4)) {
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
                    HStack(spacing: ui(4)) {
                        CompactPanelOptionButton(title: "끔", isSelected: !foldersFirst) {
                            foldersFirst = false
                        }
                        CompactPanelOptionButton(title: "켬", isSelected: foldersFirst) {
                            foldersFirst = true
                        }
                    }
                }
            }
            .padding(.horizontal, ui(12))
            .padding(.vertical, ui(10))
        }
        .scrollIndicators(.visible)
        // An ideal size instead of a fixed one: a window smaller than the panel shrinks it and
        // the content scrolls, rather than the panel being cut off at the window edge.
        .frame(idealWidth: ui(340), maxWidth: ui(340), idealHeight: ui(460), maxHeight: ui(460))
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
        HStack(spacing: ui(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ui(5)) {
                    if let parentPathComponent {
                        NavigationLink {
                            pathDestination(
                                path: parentPathComponent.path,
                                title: parentPathTitle(parentPathComponent)
                            )
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.ui(.caption).weight(.bold))
                                .foregroundStyle(SkyBreezeTheme.accent)
                                .frame(width: ui(36), height: ui(28))
                                .background(
                                    SkyBreezeTheme.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: ui(7))
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
                        .font(.ui(.caption2).weight(.bold))
                        .foregroundStyle(.tertiary)

                    ForEach(Array(pathComponents.enumerated()), id: \.element.id) { index, component in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: ui(8), weight: .bold))
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
        .font(.ui(.caption))
        .padding(.horizontal, ui(12))
        .padding(.vertical, ui(8))
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
            .frame(height: ui(3))

            if let limitMessage = thumbnailActivity.limitMessage {
                Text(limitMessage)
                    .font(.ui(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ui(12))
                    .padding(.vertical, ui(4))
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
            if showsPhoneHardServerPanel {
                phoneHardServerPanel
                    .padding(.horizontal, ui(16))
                    .padding(.top, ui(12))
            }
            LazyVGrid(
                columns: columns(for: style),
                spacing: ui(style == .largeThumbnails ? 20 : 12)
            ) {
                ForEach(displayedItems) { item in
                    gridItem(item, style: style)
                }
            }
            .padding(ui(style == .largeThumbnails ? 16 : 10))
        }
    }

    private func columns(for style: LayoutStyle) -> [GridItem] {
        let minimum: CGFloat
        let maximum: CGFloat
        let spacing: CGFloat

        switch style {
        case .list:
            minimum = ui(320)
            maximum = ui(600)
            spacing = ui(12)
        case .smallThumbnails:
            minimum = ui(dynamicTypeSize.isAccessibilitySize ? 118 : 78)
            maximum = ui(dynamicTypeSize.isAccessibilitySize ? 155 : 104)
            spacing = ui(8)
        case .largeThumbnails:
            minimum = ui(dynamicTypeSize.isAccessibilitySize ? 270 : 158)
            maximum = ui(340)
            spacing = ui(16)
        case .coverFlow:
            minimum = ui(320)
            maximum = ui(600)
            spacing = ui(12)
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
        List {
            if showsPhoneHardServerPanel {
                phoneHardServerPanel
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(displayedItems) { item in
                listItem(item)
            }
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
                    .padding(ui(style == .largeThumbnails ? 8 : 4))
            }
        }
        .contentShape(Rectangle())
        .gesture(itemInteractionGesture(for: item))
        .modifier(panelPopover(for: .item(item)) { contextActionPopover(for: item) })
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(item) }
        .accessibilityAction(named: "작업 보기") { showItemPanel(for: item) }
    }

    private func listItem(_ item: RemoteFileItem) -> some View {
        HStack(spacing: ui(8)) {
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
        .modifier(panelPopover(for: .item(item)) { contextActionPopover(for: item) })
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
        // The panel keeps its natural size while the window has room for it and scrolls when it
        // does not, so no part of it is cut off at the window edge.
        ViewThatFits(in: .vertical) {
            itemActionPanel(for: item)
            ScrollView {
                itemActionPanel(for: item)
            }
        }
        .frame(idealWidth: ui(340), maxWidth: ui(340))
        .presentationCompactAdaptation(.popover)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.ui(.title2).weight(.semibold))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .background(.regularMaterial, in: Circle())
            .accessibilityHidden(true)
    }

    private func itemActionPanel(for item: RemoteFileItem) -> some View {
        VStack(alignment: .leading, spacing: ui(12)) {
            Text(item.isDirectory ? "폴더 작업" : "파일 작업")
                .font(.ui(.subheadline).weight(.semibold))

            HStack(spacing: ui(4)) {
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

            HStack(spacing: ui(4)) {
                CompactPanelButton(
                    title: favoriteStore.contains(item) ? "별 해제" : "즐겨찾기",
                    systemImage: favoriteStore.contains(item) ? "star.slash" : "star"
                ) {
                    performContextPanelAction {
                        favoriteStore.toggle(item)
                    }
                }

                // Files and folders share the same names and order here. A folder gathers
                // the photos and videos inside it for the same trailer and music screens.
                // Both stay in place for every item; one that is neither a photo nor a
                // video dims them, with the reason below.
                CompactPanelButton(title: "예고편 보기", systemImage: "film") {
                    performContextPanelAction {
                        guard canBeginUserPresentation else { return }
                        if item.isDirectory {
                            buildFolderTrailerSelection(item)
                        } else {
                            trailerSelection = VideoTrailerSelection(items: [item])
                        }
                    }
                }
                .disabled(!acceptsMediaActions(item) || !canBeginUserPresentation)

                // The whole photo or video gets the music; no scenes are picked from it.
                CompactPanelButton(title: "음악 입히기", systemImage: "music.note") {
                    performContextPanelAction {
                        guard canBeginUserPresentation else { return }
                        if item.isDirectory {
                            buildFolderTrailerSelection(item, mode: .mediaMusic)
                        } else {
                            trailerSelection = VideoTrailerSelection(items: [item], mode: .mediaMusic)
                        }
                    }
                }
                .disabled(!acceptsMediaActions(item) || !canBeginUserPresentation)

                CompactPanelButton(title: "다운로드", systemImage: "arrow.down.circle") {
                    performContextPanelAction {
                        requestDownload([item])
                    }
                }
                .disabled(downloadCoordinator.isRunning || !canBeginUserPresentation)

                // A folder is received through the download staging first and then handed
                // to the same share sheet; nothing is sent anywhere until the user picks a
                // target there.
                CompactPanelButton(title: "공유", systemImage: "square.and.arrow.up") {
                    performContextPanelAction {
                        requestShare([item])
                    }
                }
                .disabled(
                    !canBeginUserPresentation
                        || (item.isDirectory && downloadCoordinator.isRunning)
                )

                if thumbnailPreheater.isRunning {
                    CompactPanelButton(title: "생성 중지", systemImage: "stop.circle", tint: .red) {
                        performContextPanelAction {
                            thumbnailPreheater.cancel()
                        }
                    }
                } else {
                    // Always shown under the same name; dimmed with the reason below when
                    // this connection or item cannot have thumbnails made.
                    CompactPanelButton(title: "썸네일 만들기", systemImage: "photo.stack") {
                        performContextPanelAction {
                            startThumbnailPreheating(for: item, recursively: false)
                        }
                    }
                    .disabled(thumbnailUnavailableReason(for: item) != nil)
                }
            }

            let unavailableNotes = unavailableActionNotes(for: item)
            if !unavailableNotes.isEmpty {
                VStack(alignment: .leading, spacing: ui(2)) {
                    ForEach(unavailableNotes, id: \.self) { note in
                        Text(note)
                            .font(.ui(.caption2))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            itemInformationPanel(item)
        }
        .padding(.horizontal, ui(16))
        .padding(.top, ui(4))
        .padding(.bottom, ui(16))
        .buttonStyle(.plain)
    }

    /// Why an action in the panel is dimmed or missing for this item, so an unavailable
    /// action never looks like one that simply did nothing.
    private func unavailableActionNotes(for item: RemoteFileItem) -> [String] {
        var notes: [String] = []
        let capabilities = viewModel.service.capabilities
        var unsupported: [String] = []
        if !capabilities.supports(.copy) { unsupported.append("복사") }
        if !capabilities.supports(.move) { unsupported.append("이동") }
        if !capabilities.contains(.rename) { unsupported.append("수정") }
        if !capabilities.contains(.delete) { unsupported.append("삭제") }
        if !unsupported.isEmpty {
            notes.append("이 연결은 \(unsupported.joined(separator: "·"))을(를) 지원하지 않습니다.")
        }
        if !acceptsMediaActions(item) {
            notes.append("예고편 보기와 음악 입히기는 사진, 영상과 폴더에서 쓸 수 있습니다.")
        }
        if !thumbnailPreheater.isRunning, let reason = thumbnailUnavailableReason(for: item) {
            notes.append(reason)
        }
        if downloadCoordinator.isRunning {
            notes.append(
                item.isDirectory
                    ? "진행 중인 다운로드가 끝나면 새로 다운로드하거나 폴더를 공유할 수 있습니다."
                    : "진행 중인 다운로드가 끝나면 새로 다운로드할 수 있습니다."
            )
        }
        return notes
    }

    /// Trailer and music take photos and videos, or a folder for what is inside it.
    private func acceptsMediaActions(_ item: RemoteFileItem) -> Bool {
        item.isTrailerEligible || item.isDirectory
    }

    /// Why "썸네일 만들기" is dimmed for this item, or `nil` when the existing thumbnail
    /// engine can take it. A folder uses the same engine on the media directly inside it,
    /// so it follows the same per-connection conditions as a file.
    private func thumbnailUnavailableReason(for item: RemoteFileItem) -> String? {
        let service = viewModel.service
        switch service.connection.kind {
        case .dropbox, .oneDrive, .googleDrive:
            return "이 연결은 썸네일 만들기를 지원하지 않습니다."
        case .synology:
            if item.isDirectory || item.isImage || item.isVideo { return nil }
            return "썸네일 만들기는 사진과 영상에서만 쓸 수 있습니다."
        case .sftp, .smb, .webDAV, .ftp:
            guard service.supportsRangeStreaming else {
                return "이 연결은 부분 전송을 지원하지 않아 썸네일 만들기를 쓸 수 없습니다."
            }
            if item.isDirectory {
                return nil
            }
            return ThumbnailPreheatPolicy.canGenerate(
                item: item,
                connectionKind: service.connection.kind,
                supportsRangeStreaming: service.supportsRangeStreaming
            )
                ? nil
                : "이 연결에서 썸네일 만들기는 크기를 알 수 있는 영상에서만 쓸 수 있습니다."
        }
    }

    private func itemInformationPanel(_ item: RemoteFileItem) -> some View {
        VStack(alignment: .leading, spacing: ui(4)) {
            CompactInformationRow(title: "이름", value: item.name)
            CompactInformationRow(title: "미디어", value: item.browserMediaLabel)
            CompactInformationRow(title: "특징", value: item.browserFeatureLabel)
            CompactInformationRow(title: "생성/수정", value: item.browserDateLabel)
            CompactInformationRow(
                title: "크기",
                value: item.browserFormattedSize ?? (item.isDirectory ? "폴더" : "알 수 없음")
            )
        }
        .padding(ui(10))
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: ui(12), style: .continuous)
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
        VStack(spacing: ui(8)) {
            HStack(spacing: ui(12)) {
                Label("\(selectedItemIDs.count)개 선택", systemImage: "checkmark.circle.fill")
                    .font(.ui(.subheadline).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(selectedItemIDs.isEmpty ? .secondary : .primary)

                Spacer()

                Button(selectAllButtonTitle) {
                    toggleSelectAll()
                }
                .font(.ui(.subheadline).weight(.semibold))
                .disabled(displayedItems.isEmpty || selectionInteractionsAreBlocked)
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ui(20)) {
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

                    selectionActionButton("예고편 보기", systemImage: "film") {
                        guard canBeginUserPresentation else { return }
                        let clips = selectedItems.filter(\.isTrailerEligible)
                        guard !clips.isEmpty, clips.count == selectedItems.count else { return }
                        trailerSelection = VideoTrailerSelection(items: clips)
                        endSelection()
                    }
                    .disabled(selectedItems.isEmpty || !selectedItems.allSatisfy(\.isTrailerEligible))

                    selectionActionButton("음악 입히기", systemImage: "music.note") {
                        guard canBeginUserPresentation else { return }
                        let clips = selectedItems.filter(\.isTrailerEligible)
                        guard !clips.isEmpty, clips.count == selectedItems.count else { return }
                        trailerSelection = VideoTrailerSelection(items: clips, mode: .mediaMusic)
                        endSelection()
                    }
                    .disabled(selectedItems.isEmpty || !selectedItems.allSatisfy(\.isTrailerEligible))

                    // Files and folders alike; the save location is asked for first and
                    // the selection is kept until a download actually starts.
                    selectionActionButton("다운로드", systemImage: "arrow.down.circle") {
                        requestDownload(selectedItems)
                    }
                    .disabled(selectedItems.isEmpty || downloadCoordinator.isRunning)

                    selectionActionButton("공유", systemImage: "square.and.arrow.up") {
                        requestShare(selectedItems)
                    }
                    .disabled(selectedItems.isEmpty || shareCoordinator.isPreparing)

                    // PhoneHard's own way out to a network connection, as before.
                    if isPhoneHard {
                        selectionActionButton("NAS로 보내기", systemImage: "arrow.up.doc") {
                            beginNASUpload(of: selectedFiles)
                        }
                        .disabled(selectedFiles.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let note = selectionUnavailableNote {
                Text(note)
                    .font(.ui(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ui(16))
        .padding(.top, ui(10))
        .padding(.bottom, ui(8))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Why an action in the selection bar is dimmed for what is selected now.
    private var selectionUnavailableNote: String? {
        guard !selectedItems.isEmpty else { return nil }
        if !selectedItems.allSatisfy(\.isTrailerEligible) {
            return "예고편 보기와 음악 입히기는 사진과 영상만 선택했을 때 쓸 수 있습니다."
        }
        if isPhoneHard, selectedFiles.isEmpty {
            return "NAS로 보내기는 파일만 보낼 수 있습니다."
        }
        return nil
    }

    /// Hands the selected PhoneHard files to the existing send-to-connection screen. The
    /// stored files are only read from there.
    private func beginNASUpload(of files: [RemoteFileItem]) {
        guard !files.isEmpty, canBeginUserPresentation else { return }
        let service = viewModel.service
        Task {
            var sources: [LocalUploadSource] = []
            for file in files {
                if let url = try? await service.download(file) {
                    sources.append(LocalUploadSource(url: url, preferredName: file.name))
                }
            }
            guard !sources.isEmpty else {
                downloadErrorMessage = "NAS로 보낼 파일을 준비하지 못했습니다. 목록을 새로 고친 뒤 다시 시도하세요."
                return
            }
            pendingNASUploadSources = sources
            isChoosingNASUploadDestination = true
        }
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
            VStack(spacing: ui(2)) {
                Image(systemName: systemImage)
                    .font(.ui(.body).weight(.semibold))
                Text(title)
                    .font(.ui(.caption2))
            }
            .frame(minWidth: ui(58))
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
            && !isStagingFolderShare
            && !operationCoordinator.isBusy
            && !hasBlockingPresentation
            && !hasPendingError
    }

    private var selectionInteractionsAreBlocked: Bool {
        shareCoordinator.isPreparing || operationCoordinator.isBusy || downloadCoordinator.isRunning
    }

    private var hasBlockingPresentation: Bool {
        shareCoordinator.preparedShare != nil
            || previewItem != nil
            || trailerSelection != nil
            || !pendingDeleteItems.isEmpty
            || renameItem != nil
            || isCreatingFolder
            || isImportingFiles
            || isImportingFromGooglePhotos
            || isChoosingNASUploadDestination
            || downloadDestinationStep != nil
    }

    private var hasPendingError: Bool {
        shareCoordinator.errorMessage != nil
            || operationCoordinator.errorMessage != nil
            || thumbnailPreheater.errorMessage != nil
            || downloadErrorMessage != nil
            || (viewModel.errorMessage != nil && !viewModel.items.isEmpty)
    }

    /// Every download entry point, for files and folders alike, comes through here and
    /// asks for the save location first. Nothing is transferred until one is chosen.
    private func requestDownload(_ items: [RemoteFileItem]) {
        guard !items.isEmpty,
              !downloadCoordinator.isRunning,
              canBeginUserPresentation else { return }
        pendingDownloadItems = items
        downloadDestinationStep = .choosing
    }

    private func startDownload(to destination: RemoteDownloadDestination) {
        let items = pendingDownloadItems
        pendingDownloadItems = []
        guard !items.isEmpty, !downloadCoordinator.isRunning else { return }
        downloadErrorMessage = nil
        endSelection()
        downloadCoordinator.start(
            items: items,
            service: viewModel.service,
            destination: destination,
            inboxStore: inboxStore
        ) { summary in
            if summary.isCompleteSuccess {
                operationCoordinator.statusMessage = summary.message
            } else if summary.wasCancelled,
                      summary.failedNames.isEmpty,
                      summary.skippedNames.isEmpty {
                operationCoordinator.statusMessage = summary.message
            } else {
                downloadErrorMessage = summary.message
            }
        }
    }

    private func cancelDownload() {
        downloadCoordinator.cancel()
    }

    /// Every share entry point. Files alone keep the existing share preparation; a
    /// selection with a folder is received whole through the download staging and then
    /// shown in the same share sheet. Either way nothing is sent until the user chooses
    /// a target in that sheet, and an incomplete folder is never offered.
    private func requestShare(_ items: [RemoteFileItem]) {
        guard !items.isEmpty, canBeginUserPresentation else { return }
        guard items.contains(where: \.isDirectory) else {
            shareCoordinator.prepare(items: items, using: viewModel.service)
            return
        }
        guard !downloadCoordinator.isRunning else { return }
        downloadErrorMessage = nil
        isStagingFolderShare = true
        endSelection()
        downloadCoordinator.start(
            items: items,
            service: viewModel.service,
            destination: .shareSheet,
            inboxStore: inboxStore
        ) { summary in
            isStagingFolderShare = false
            if let directoryURL = summary.shareDirectoryURL {
                shareCoordinator.present(
                    stagedURLs: summary.sharedURLs,
                    temporaryDirectoryURL: directoryURL
                )
            } else if summary.wasCancelled,
                      summary.failedNames.isEmpty,
                      summary.skippedNames.isEmpty {
                operationCoordinator.statusMessage = summary.message
            } else {
                downloadErrorMessage = summary.message
            }
        }
        // A start that was refused never reports back.
        if !downloadCoordinator.isRunning { isStagingFolderShare = false }
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

/// What only PhoneHard adds to the shared browser, kept in one place: its list and the
/// rest of the app stay in step, and its two own sheets (Google Photos import and
/// sending files on to a network connection) are presented from here.
private struct FileBrowserPhoneHardModifier: ViewModifier {
    let isPhoneHard: Bool
    let items: [RemoteFileItem]
    @ObservedObject var inboxStore: SharedInboxStore
    @Binding var isImportingFromGooglePhotos: Bool
    @Binding var isChoosingNASUploadDestination: Bool
    let nasUploadSources: [LocalUploadSource]
    let reloadItems: @MainActor () async -> Void
    let nasUploadDidClose: () -> Void

    func body(content: Content) -> some View {
        content
            // PhoneHard is also changed from outside this screen (a download saved to
            // it, a finished trailer, the web server), and the dashboard counts what is
            // in it.
            .onChange(of: items) { _, _ in
                if isPhoneHard { inboxStore.reload() }
            }
            .onChange(of: inboxStore.records) { _, _ in
                guard isPhoneHard else { return }
                Task { await reloadItems() }
            }
            .sheet(
                isPresented: $isImportingFromGooglePhotos,
                onDismiss: { inboxStore.reload() }
            ) {
                GooglePhotosImportFlowView(inboxStore: inboxStore)
            }
            .sheet(
                isPresented: $isChoosingNASUploadDestination,
                onDismiss: nasUploadDidClose
            ) {
                InboxUploadDestinationView(sources: nasUploadSources)
            }
    }
}

private struct RemoteFileGridCell: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: RemoteFileItem
    let service: any RemoteFileService
    let isLarge: Bool
    let thumbnailReloadVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: ui(isLarge ? 9 : 6)) {
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
                    in: RoundedRectangle(cornerRadius: ui(isLarge ? 15 : 11))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ui(isLarge ? 15 : 11))
                        .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: ui(isLarge ? 15 : 11)))

            Text(item.name)
                .font(isLarge ? .ui(.headline) : .ui(.caption))
                .fontWeight(isLarge ? .semibold : .regular)
                .foregroundStyle(SkyBreezeTheme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(isLarge ? 0.85 : 0.72)
                .allowsTightening(true)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity)

            if item.isDirectory {
                FolderItemCountLabel(
                    item: item,
                    service: service,
                    generation: thumbnailReloadVersion,
                    style: isLarge ? .caption : .caption2
                )
                .foregroundStyle(.secondary)
            }

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
        HStack(spacing: ui(12)) {
            RemoteThumbnailView(
                item: item,
                service: service,
                size: CGSize(
                    width: thumbnailSide / MacUIScale.factor,
                    height: thumbnailSide / MacUIScale.factor
                ),
                reloadVersion: thumbnailReloadVersion
            )
                .frame(width: thumbnailSide, height: thumbnailSide)
                .background(SkyBreezeTheme.thumbnailSurface, in: RoundedRectangle(cornerRadius: ui(9)))
                .overlay {
                    RoundedRectangle(cornerRadius: ui(9))
                        .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: ui(9)))

            VStack(alignment: .leading, spacing: ui(4)) {
                Text(item.name)
                    .font(.ui(.body))
                    .foregroundStyle(SkyBreezeTheme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)

                if item.isDirectory {
                    FolderItemCountLabel(
                        item: item,
                        service: service,
                        generation: thumbnailReloadVersion,
                        style: .caption
                    )
                    .foregroundStyle(.secondary)
                }

                RemoteFileMetadataView(
                    item: item,
                    showsModifiedDate: true,
                    includesTime: true,
                    compact: false
                )
            }
        }
        .padding(.vertical, ui(2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.browserAccessibilityLabel)
    }

    private var thumbnailSide: CGFloat {
        ui(dynamicTypeSize.isAccessibilitySize ? 50 : 58)
    }
}

private struct RemoteFileMetadataView: View {
    let item: RemoteFileItem
    let showsModifiedDate: Bool
    let includesTime: Bool
    let compact: Bool

    /// A PhoneHard video or music file shows its playing time right after its size; the
    /// file is on the device, so reading its length costs no transfer.
    private var showsPlayingTime: Bool {
        item.connectionID == LocalInboxFileService.connectionID && item.isPlayerMedia
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui(2)) {
            if !item.isDirectory {
                if compact {
                    HStack(spacing: ui(4)) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: ui(9), weight: .semibold))
                            .accessibilityLabel(item.browserKindLabel)

                        Text(item.browserFormattedSize ?? "크기 정보 없음")
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .allowsTightening(true)
                            .monospacedDigit()
                            .layoutPriority(1)

                        if showsPlayingTime {
                            LocalInboxDurationLabel(item: item)
                        }
                    }
                } else if showsPlayingTime {
                    HStack(spacing: ui(7)) {
                        Text(item.browserKindAndSizeLabel)
                            .lineLimit(2)
                        LocalInboxDurationLabel(item: item)
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
        .font(compact ? .ui(.caption2) : .ui(.caption))
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
    @Published private(set) var isPreparing = false
    @Published private(set) var preparingItemName: String?
    @Published private(set) var downloadProgress: RemoteDownloadProgress?
    @Published private(set) var isStaging = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published var preparedShare: PreparedRemoteFileShare?
    @Published var errorMessage: String?

    private var preparationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var presentedTemporaryDirectoryURL: URL?

    func prepare(items: [RemoteFileItem], using service: any RemoteFileService) {
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty,
              preparationTask == nil,
              preparedShare == nil else { return }

        let currentOperationID = UUID()
        operationID = currentOperationID
        isPreparing = true
        preparingItemName = files.first?.name
        downloadProgress = RemoteDownloadProgress(
            completedByteCount: 0,
            totalByteCount: files.first?.size
        )
        isStaging = false
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
                    self.isStaging = false
                    self.downloadProgress = RemoteDownloadProgress(
                        completedByteCount: 0,
                        totalByteCount: item.size
                    )
                    // Other thumbnail downloads must not evict this file before staging.
                    await DownloadCache.shared.protect(item)
                    let stagedURL: URL
                    do {
                        let downloadedURL = try await service.download(item) { [weak self] update in
                            await self?.updateProgress(update, operationID: currentOperationID)
                        }
                        try Task.checkCancellation()
                        self.isStaging = true
                        let baseFilename = Self.safeFilename(
                            item.name,
                            fallbackURL: downloadedURL
                        )
                        let filename = Self.uniqueFilename(
                            baseFilename,
                            usedFilenames: &usedFilenames
                        )
                        stagedURL = temporaryDirectoryURL.appending(
                            path: filename,
                            directoryHint: .notDirectory
                        )
                        try await Self.stageForSharing(
                            downloadedURL: downloadedURL,
                            stagedURL: stagedURL
                        )
                    } catch {
                        await DownloadCache.shared.release(item)
                        throw error
                    }
                    await DownloadCache.shared.release(item)
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

    /// Presents items that were already fully staged under `temporaryDirectoryURL`, which
    /// this coordinator then owns and removes once the sheet closes.
    func present(stagedURLs: [URL], temporaryDirectoryURL: URL) {
        guard !stagedURLs.isEmpty,
              preparationTask == nil,
              preparedShare == nil else {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            }
            return
        }
        errorMessage = nil
        presentedTemporaryDirectoryURL = temporaryDirectoryURL
        preparedShare = PreparedRemoteFileShare(
            fileURLs: stagedURLs,
            temporaryDirectoryURL: temporaryDirectoryURL
        )
    }

    func cancelPreparation() {
        operationID = nil
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
        downloadProgress = nil
        isStaging = false
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
        isPreparing = false
        preparingItemName = nil
        downloadProgress = nil
        isStaging = false
    }

    private func updateProgress(_ progress: RemoteDownloadProgress, operationID: UUID) {
        guard self.operationID == operationID else { return }
        downloadProgress = progress
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
        HStack(spacing: ui(12)) {
            if let fraction = preheater.fractionCompleted {
                ProgressView(value: fraction)
                    .frame(width: ui(54))
            } else {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: ui(2)) {
                Text(preheater.totalCount == 0 ? "미디어 폴더 검색 중…" : "썸네일 미리 만드는 중…")
                    .font(.ui(.subheadline).weight(.semibold))
                Text(progressDescription)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: ui(8))

            Button("중지", role: .cancel) {
                preheater.cancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(ui(14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ui(16)))
        .overlay {
            RoundedRectangle(cornerRadius: ui(16))
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
            .font(.ui(.subheadline).weight(.bold))
            .foregroundStyle(.primary)
            .textCase(.uppercase)
            .padding(.horizontal, ui(8))
            .padding(.vertical, ui(6))
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
            VStack(spacing: ui(3)) {
                Image(systemName: systemImage)
                    .font(.system(size: ui(19), weight: .medium))
                    .frame(width: ui(24), height: ui(24))

                Text(title)
                    .font(.system(size: ui(10), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(isSelected ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .frame(height: ui(52))
            .background(
                isSelected ? SkyBreezeTheme.accent : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: ui(10), style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ui(10), style: .continuous)
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
        VStack(alignment: .leading, spacing: ui(5)) {
            Text(title)
                .font(.ui(.caption2).weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, ui(2))

            content
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, ui(5))
    }
}

private struct CompactPanelOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: ui(12), weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : Color(uiColor: .label)
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: ui(44))
                .background(
                    isSelected
                        ? SkyBreezeTheme.accent
                        : Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: ui(10), style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ui(10), style: .continuous)
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
        HStack(alignment: .firstTextBaseline, spacing: ui(8)) {
            Text(title)
                .font(.ui(.caption2))
                .foregroundStyle(.tertiary)
                .frame(width: ui(54), alignment: .leading)

            Text(value)
                .font(.ui(.caption))
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
        HStack(spacing: ui(12)) {
            Image(systemName: systemImage)
                .frame(width: ui(22))
                .foregroundStyle(.tint)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: ui(8))

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.ui(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, ui(8))
        .padding(.vertical, ui(10))
    }
}

private struct SharePreparationBanner: View {
    let itemName: String?
    let completedCount: Int
    let totalCount: Int
    let progress: RemoteDownloadProgress?
    let isStaging: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ui(10)) {
            HStack(spacing: ui(8)) {
                Text(isStaging ? "공유 준비 중" : "내려받는 중")
                    .font(.ui(.subheadline).weight(.semibold))
                    .layoutPriority(1)

                if totalCount > 1 {
                    Text("\(min(completedCount + 1, totalCount)) / \(totalCount)")
                        .font(.ui(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: ui(4))

                Button("취소", role: .cancel, action: onCancel)
                    .font(.ui(.caption).weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, ui(12))
                    .padding(.vertical, ui(6))
                    .background(.red.opacity(0.1), in: Capsule())
                    .frame(minHeight: ui(44))
                    .contentShape(Rectangle())
            }

            Text(itemName ?? "파일 준비 중")
                .font(.ui(.subheadline))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: ui(6)) {
                HStack(alignment: .firstTextBaseline, spacing: ui(8)) {
                    if let progress {
                        Text(byteProgressDescription(progress))
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: ui(4))

                    if let fraction = progress?.fractionCompleted {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.ui(.caption).weight(.semibold))
                    }
                }
                .monospacedDigit()

                if let fraction = progress?.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, ui(16))
        .padding(.vertical, ui(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ui(16)))
        .overlay {
            RoundedRectangle(cornerRadius: ui(16))
                .stroke(.separator.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }

    private func byteProgressDescription(_ progress: RemoteDownloadProgress) -> String {
        let received = ByteCountFormatter.string(
            fromByteCount: progress.completedByteCount,
            countStyle: .file
        )
        guard let total = progress.totalByteCount else { return received }
        return "\(received) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

struct FileOperationProgressBanner: View {
    let title: String
    let progress: RemoteOperationProgress?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: ui(12)) {
            if let fraction = progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .frame(width: ui(54))
            } else {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title)
                    .font(.ui(.subheadline).weight(.semibold))
                    .lineLimit(1)
                if let progress {
                    Text(progressDescription(progress))
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: ui(8))

            Button("취소", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(ui(14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ui(16)))
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
        HStack(spacing: ui(10)) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.ui(.subheadline).weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: ui(8))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("상태 메시지 닫기")
        }
        .padding(ui(14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ui(16)))
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
