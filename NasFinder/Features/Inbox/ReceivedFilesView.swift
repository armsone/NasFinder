import AVFoundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

enum ReceivedFilesLayoutStyle: String, CaseIterable, Identifiable {
    case details
    case thumbnails
    case posters
    case overflow

    var id: String { rawValue }

    static let selectableCases: [Self] = [.details, .thumbnails, .posters]

    var title: String {
        switch self {
        case .details: "자세히"
        case .thumbnails: "썸네일"
        case .posters: "포스터"
        case .overflow: "플로잉"
        }
    }

    var systemImage: String {
        switch self {
        case .details: "list.bullet"
        case .thumbnails: "square.grid.3x3"
        case .posters: "square.grid.2x2"
        case .overflow: "rectangle.stack.fill"
        }
    }
}

enum ReceivedFilesLayoutPresentationPolicy {
    /// iPhone enters 플로잉 automatically from a landscape poster page; iPad and
    /// Mac list it as an explicit fourth mode (`allowsExplicitOverflow`).
    static func normalizedSelection(
        _ rawValue: String,
        allowsExplicitOverflow: Bool = false
    ) -> ReceivedFilesLayoutStyle {
        guard let style = ReceivedFilesLayoutStyle(rawValue: rawValue), style != .overflow else {
            if rawValue == ReceivedFilesLayoutStyle.overflow.rawValue {
                return allowsExplicitOverflow ? .overflow : .posters
            }
            return .details
        }
        return style
    }

    static func presentedStyle(
        selectedStyle: ReceivedFilesLayoutStyle,
        contentSize: CGSize,
        isSelecting: Bool,
        hasRecords: Bool,
        isPhone: Bool = true
    ) -> ReceivedFilesLayoutStyle {
        if selectedStyle == .overflow {
            return hasRecords && !isSelecting ? .overflow : .posters
        }
        return isPhone
            && selectedStyle == .posters
            && FileBrowserOverflowPresentationPolicy.shouldPresentPosterAsOverflow(
                contentSize: contentSize,
                isSelecting: isSelecting,
                hasItems: hasRecords
            )
            ? .overflow
            : selectedStyle
    }

    static func usesCoverFlowChrome(
        presentedStyle: ReceivedFilesLayoutStyle,
        isSelecting: Bool,
        hasRecords: Bool
    ) -> Bool {
        presentedStyle == .overflow && !isSelecting && hasRecords
    }
}

enum InboxFileOperationKind {
    case move
    case copy
}

struct InboxFileOperation: Identifiable {
    let id = UUID()
    let kind: InboxFileOperationKind
    let records: [SharedInboxRecord]
}

/// PhoneHard's earlier own screen. The dashboard now opens `PhoneHardBrowserView`, the
/// shared browser, instead; this stays as it was and is not routed to.
struct ReceivedFilesView: View {
    @Environment(\.trailerProjectSink) private var projectSink
    private struct UploadabilityTaskID: Hashable {
        let records: [SharedInboxRecord]
        let refreshGeneration: Int
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var webHardController: WebHardServerController
    @AppStorage("receivedFilesLayoutStyle.v1") private var storedLayoutStyle =
        ReceivedFilesLayoutStyle.details.rawValue
    @AppStorage("receivedFilesOverflowDark.v1") private var overflowUsesDarkBackground = false
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue
    @State private var previewItem: RemoteFileItem?
    @State private var inlineMusic = InlineMusicPlayback()
    @State private var trailerSelection: VideoTrailerSelection?
    /// `nil` is the PhoneHard root; otherwise a folder's `storedFilename`, including the
    /// physical Music folder, which now navigates through this same mechanism.
    @State private var currentPath: String?
    @State private var overflowReturnStyle: ReceivedFilesLayoutStyle?
    @State private var isSelecting = false
    @State private var selectedRecordIDs: Set<SharedInboxRecord.ID> = []
    @State private var uploadableRecordIDs: Set<SharedInboxRecord.ID> = []
    @State private var uploadabilityRefreshGeneration = 0
    @State private var pendingUploadSources: [LocalUploadSource] = []
    @State private var isChoosingUploadDestination = false
    @State private var isImportingFromFiles = false
    @State private var isImportingFromGooglePhotos = false
    @State private var pendingDeletion: [SharedInboxRecord]?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var pendingFileOperation: InboxFileOperation?
    @State private var contentSize = CGSize.zero

    // The modifier chain is split into the stages below, each its own `some View`, so the
    // compiler type-checks them separately. Modifier order is body's original order.
    var body: some View {
        alertingContent
            .sheet(item: $pendingFileOperation) { operation in
                InboxDestinationPickerView(
                    inboxStore: inboxStore,
                    operation: operation,
                    excludedPaths: excludedDestinationPaths(for: operation.records)
                )
            }
            .routesTrailerSelection($trailerSelection, service: { LocalInboxFileService(records: inboxStore.records) }, sink: projectSink)
            .fullScreenCover(item: trailerCoverBinding($trailerSelection, sink: projectSink), onDismiss: { reloadInbox() }) { selection in
                VideoTrailerView(items: selection.items, service: LocalInboxFileService(records: inboxStore.records),
                                 mode: selection.mode)
            }
            .fullScreenCover(item: $previewItem) { item in
                previewCover(for: item)
            }
            .sheet(
                isPresented: $isChoosingUploadDestination,
                onDismiss: {
                    pendingUploadSources = []
                    endSelection()
                }
            ) {
                InboxUploadDestinationView(sources: pendingUploadSources)
            }
            .navigationDestination(isPresented: $isImportingFromGooglePhotos) {
                GooglePhotosImportFlowView(inboxStore: inboxStore)
            }
            .onChange(of: isImportingFromGooglePhotos) { _, isPresented in
                if !isPresented { reloadInbox() }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if inboxStore.records.isEmpty {
            emptyInboxContent
        } else {
            receivedFilesContent
        }
    }

    private var emptyInboxContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                connectionPanel

                ContentUnavailableView {
                    Label("폰하드가 비어 있습니다", systemImage: "tray")
                } description: {
                    Text("내가 저장하거나 다른 기기에서 보낸 파일이 이곳에 모입니다.")
                } actions: {
                    Button("파일 가져오기", systemImage: "doc.badge.plus") {
                        isImportingFromFiles = true
                    }
                    .buttonStyle(PorcelainProminentButtonStyle())

                    Button("Google 포토에서 가져오기", systemImage: "photo.badge.arrow.down") {
                        isImportingFromGooglePhotos = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, ui(44))
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable { reloadInbox() }
    }

    private var navigationTitleText: String {
        if isSelecting {
            return "\(selectedRecords.count)개 선택"
        }
        return isEnamel && currentPath == nil ? "" : currentFolderDisplayName
    }

    private var navigationContent: some View {
        Group {
            rootContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyBreezeBackground())
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(
            FileBrowserCoverFlowChromeModifier(isActive: usesCoverFlowChrome)
        )
        .toolbar { toolbarContent }
        .overlay { coverFlowNavigationOverlay }
    }

    private var importingContent: some View {
        navigationContent
            .modifier(
                ReceivedFilesImporterModifier(
                    isPresented: $isImportingFromFiles,
                    importFiles: { urls in importPickedFiles(urls) },
                    importFailed: { error in handleFileImportFailure(error) }
                )
            )
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    uploadSelectionBar
                }
            }
    }

    private var lifecycleContent: some View {
        importingContent
            .task {
                reloadInbox()
                openPendingPreviewIfNeeded()
            }
            .onAppear {
                normalizeStoredLayoutStyle()
                reloadInbox()
            }
            .task(id: uploadabilityTaskID) {
                await refreshUploadability()
            }
            .onChange(of: currentRecordIDs) { _, validRecordIDs in
                selectedRecordIDs.formIntersection(validRecordIDs)
            }
            .onChange(of: webHardController.thumbnailGeneration) { _, _ in
                reloadInbox()
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
    }

    private var measuredContent: some View {
        lifecycleContent
            .background { contentSizeReader }
    }

    private var contentSizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateOrientation(for: proxy.size)
                }
                .onChange(of: proxy.size) { _, size in
                    updateOrientation(for: size)
                }
        }
        .allowsHitTesting(false)
    }

    private var alertingContent: some View {
        measuredContent
            .alert("음악을 재생할 수 없습니다", isPresented: Binding(
                get: { inlineMusic.failure != nil },
                set: { if !$0 { inlineMusic.failure = nil } }
            )) {
                Button("확인", role: .cancel) { inlineMusic.failure = nil }
            } message: {
                Text(inlineMusic.failure ?? "")
            }
            .onDisappear { inlineMusic.stop() }
            .alert("폰하드 오류", isPresented: errorBinding) {
                Button("확인", role: .cancel) {
                    inboxStore.errorMessage = nil
                }
            } message: {
                Text(inboxStore.errorMessage ?? "")
            }
            .alert(
                "선택한 항목을 지울까요?",
                isPresented: deletionConfirmationBinding,
                presenting: pendingDeletion
            ) { recordsToDelete in
                Button("취소", role: .cancel) { pendingDeletion = nil }
                Button("지우기", role: .destructive) {
                    confirmDeletion(of: recordsToDelete)
                }
            } message: { recordsToDelete in
                Text(deletionConfirmationMessage(for: recordsToDelete))
            }
            .alert("새 폴더", isPresented: $isCreatingFolder) {
                TextField("폴더 이름", text: $newFolderName)
                Button("취소", role: .cancel) {}
                Button("만들기") {
                    createFolder()
                }
                .disabled(newFolderNameIsBlank)
            } message: {
                Text("\(currentFolderDisplayName) 안에 새 폴더를 만듭니다.")
            }
    }

    private func previewCover(for item: RemoteFileItem) -> some View {
        let records = inboxStore.records
        let service = LocalInboxFileService(records: records)
        // Music is handed over as the audio item it is: the dedicated player opens it in
        // its audio mode (`isPlayerMedia`), with pinned controls, and it plays on its own
        // rather than in a sequence.
        return RemotePreviewView(
            item: item,
            sequentialItems: sequentialMediaItems(from: records, including: item),
            service: service
        )
    }

    private var currentRecordIDs: Set<SharedInboxRecord.ID> {
        Set(inboxStore.records.map(\.id))
    }

    private var newFolderNameIsBlank: Bool {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func importPickedFiles(_ urls: [URL]) {
        Task {
            await inboxStore.importFromFiles(urls)
        }
    }

    private func handleFileImportFailure(_ error: Error) {
        let cocoaError = error as NSError
        guard !(cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == CocoaError.Code.userCancelled.rawValue) else {
            return
        }
        inboxStore.errorMessage =
            "파일을 선택하지 못했습니다: \(error.localizedDescription)"
    }

    private func openPendingPreviewIfNeeded() {
        if let recordID = inboxStore.consumePendingPreviewRecordID(),
           let record = inboxStore.records.first(where: { $0.id == recordID }) {
            previewItem = LocalInboxFileService.remoteItem(for: record)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !usesCoverFlowChrome {
            if isSelecting {
                selectionLeadingToolbarItem
                selectionTrailingToolbarItems
            } else {
                normalLeadingToolbarItem
                normalTrailingToolbarItems
            }
        }
    }

    @ToolbarContentBuilder
    private var selectionLeadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Group {
                Button(allRecordsAreSelected ? "전체 해제" : "전체 선택") {
                    toggleAllSelection()
                }
            }
            .uiBarFont()
        }
    }

    @ToolbarContentBuilder
    private var selectionTrailingToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Group {
                Button("이동", systemImage: "folder") {
                    pendingFileOperation = InboxFileOperation(kind: .move, records: selectedRecords)
                }
                .disabled(selectedRecords.isEmpty)

                Button("복사", systemImage: "doc.on.doc") {
                    pendingFileOperation = InboxFileOperation(kind: .copy, records: selectedRecords)
                }
                .disabled(selectedRecords.isEmpty)

                Button("지우기", systemImage: "trash", role: .destructive) {
                    requestDeletion(of: selectedRecords)
                }
                .disabled(selectedRecords.isEmpty)

                Button("완료") {
                    endSelection()
                }
            }
            .uiBarFont()
        }
    }

    @ToolbarContentBuilder
    private var normalLeadingToolbarItem: some ToolbarContent {
        if currentPath != nil {
            ToolbarItem(placement: .topBarLeading) {
                Group {
                    Button {
                        navigateUp()
                    } label: {
                        Label("위로", systemImage: "chevron.left")
                    }
                    .accessibilityLabel("\(parentFolderDisplayName) 폴더로 이동")
                }
                .uiBarFont()
            }
        } else if isEnamel {
            ToolbarItem(placement: .principal) {
                Group {
                    HStack(spacing: ui(8)) {
                        PhoneHardMark(size: uiBar(26))
                        Text("폰하드")
                            .uiBarFont(.headline)
                            .foregroundStyle(.primary)
                    }
                }
                .uiBarFont()
            }
        }
    }

    @ToolbarContentBuilder
    private var normalTrailingToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Group {
                if !inboxStore.records.isEmpty {
                    layoutMenu
                }

                newItemMenu

                if !inboxStore.records.isEmpty {
                    Button("선택") {
                        isSelecting = true
                    }
                }
            }
            .uiBarFont()
        }
    }

    private var layoutMenu: some View {
        Menu {
            ForEach(
                isPhoneIdiom
                    ? ReceivedFilesLayoutStyle.selectableCases
                    : ReceivedFilesLayoutStyle.allCases
            ) { style in
                Button {
                    if style == .overflow {
                        if layoutStyle != .overflow { overflowReturnStyle = layoutStyle }
                    } else {
                        overflowReturnStyle = nil
                    }
                    storedLayoutStyle = style.rawValue
                } label: {
                    layoutMenuRowLabel(for: style)
                }
            }
        } label: {
            Image(systemName: layoutStyle.systemImage)
        }
        .accessibilityLabel("보기")
    }

    @ViewBuilder
    private func layoutMenuRowLabel(for style: ReceivedFilesLayoutStyle) -> some View {
        Label(style.title, systemImage: style.systemImage)
        if layoutStyle == style {
            Image(systemName: "checkmark")
        }
    }

    private var newItemMenu: some View {
        Menu {
            Button("새 폴더", systemImage: "folder.badge.plus") {
                newFolderName = ""
                isCreatingFolder = true
            }
            Button("파일에서 가져오기", systemImage: "doc.badge.plus") {
                isImportingFromFiles = true
            }
            Button("Google 포토에서 가져오기", systemImage: "photo.badge.arrow.down") {
                isImportingFromGooglePhotos = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("폰하드 메뉴")
    }

    @ViewBuilder
    private var receivedFilesContent: some View {
        switch presentedLayoutStyle {
        case .details:
            List {
                if !isSelecting {
                    WebHardConnectionPanel()
                        .frame(maxWidth: ui(760))
                        .listRowInsets(
                            EdgeInsets(top: ui(12), leading: ui(16), bottom: ui(12), trailing: ui(16))
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if showsSyntheticMusicFolder {
                    syntheticMusicFolderRow
                        .listRowBackground(Color.clear)
                }

                ForEach(currentLevelFolders) { folder in
                    folderRow(folder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelecting {
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    requestDeletion(of: [folder])
                                }
                            }
                        }
                        .contextMenu { recordContextMenu(folder) }
                        .listRowBackground(Color.clear)
                }

                ForEach(currentLevelFiles) { record in
                    receivedFileRow(record)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelecting {
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    requestDeletion(of: [record])
                                }
                            }
                        }
                        .contextMenu { recordContextMenu(record) }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { reloadInbox() }
        case .thumbnails, .posters:
            ScrollView {
                VStack(spacing: 0) {
                    connectionPanel

                    if showsSyntheticMusicFolder {
                        syntheticMusicFolderRow
                            .padding(.horizontal, ui(16))
                            .padding(.top, ui(6))
                    }

                    if !currentLevelFolders.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(currentLevelFolders) { folder in
                                folderRow(folder)
                                    .contextMenu { recordContextMenu(folder) }
                            }
                        }
                        .padding(.horizontal, ui(16))
                        .padding(.top, ui(6))
                    }

                    LazyVGrid(
                        columns: gridColumns,
                        spacing: ui(presentedLayoutStyle == .posters ? 20 : 14)
                    ) {
                        ForEach(currentLevelFiles) { record in
                            receivedFileTile(record, poster: presentedLayoutStyle == .posters)
                                .contextMenu { recordContextMenu(record) }
                        }
                    }
                    .padding(ui(16))
                }
            }
            .refreshable { reloadInbox() }
        case .overflow:
            overflowContent
        }
    }

    /// Overflow keeps its existing flat coverflow of files, but a folder's own
    /// subfolders are still listed above it so a newly created folder is never
    /// invisible or unreachable just because this layout is selected.
    @ViewBuilder
    private var overflowContent: some View {
        FileBrowserCoverFlowView(
            items: inboxStore.records.filter { !$0.isDirectory },
            usesDarkBackground: $overflowUsesDarkBackground,
            itemName: { $0.originalFilename },
            thumbnail: { record, size, _, _ in
                let item = LocalInboxFileService.remoteItem(for: record)
                let squareSize = ReceivedFilesThumbnailPolicy.squareSize(size)
                return receivedFileArtwork(
                    for: item,
                    record: record,
                    requestSize: squareSize
                )
            },
            onActivate: activate,
            onShowActions: nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            if !currentLevelFolders.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(currentLevelFolders) { folder in
                            folderRow(folder)
                                .contextMenu { recordContextMenu(folder) }
                        }
                    }
                    .padding(.horizontal, ui(16))
                    .padding(.vertical, ui(6))
                }
                .frame(maxHeight: ui(220))
                .background(.bar)
            }
        }
    }

    private var usesCoverFlowChrome: Bool {
        ReceivedFilesLayoutPresentationPolicy.usesCoverFlowChrome(
            presentedStyle: presentedLayoutStyle,
            isSelecting: isSelecting,
            hasRecords: !inboxStore.records.isEmpty
        )
    }

    @ViewBuilder
    private var coverFlowNavigationOverlay: some View {
        if usesCoverFlowChrome {
            FileBrowserCoverFlowNavigationChrome(
                usesDarkBackground: overflowUsesDarkBackground
            ) { containerWidth in
                HStack(spacing: FileBrowserCoverFlowChromePolicy.itemSpacing) {
                    Button {
                        closeOverflowOrDismiss()
                    } label: {
                        FileBrowserCoverFlowChromeIcon(
                            kind: .back,
                            usesDarkBackground: overflowUsesDarkBackground
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("폰하드 닫기")

                    Button {
                        dismiss()
                    } label: {
                        Text("폰하드")
                            .font(.ui(.subheadline).weight(.medium))
                            .foregroundStyle(
                                FileBrowserCoverFlowChromePolicy.foreground(
                                    usesDarkBackground: overflowUsesDarkBackground
                                )
                            )
                            .lineLimit(1)
                            .frame(
                                maxWidth: FileBrowserCoverFlowChromePolicy
                                    .titleMaximumWidth(containerWidth: containerWidth),
                                minHeight: FileBrowserCoverFlowChromePolicy.buttonSize,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("폰하드, 첫 화면으로 이동")

                    Spacer(minLength: ui(8))

                    Menu {
                        ForEach(FileBrowserCoverFlowBackground.allCases) { background in
                            Button {
                                withAnimation(.easeInOut(duration: 0.20)) {
                                    overflowUsesDarkBackground = background.usesDarkBackground
                                }
                            } label: {
                                Text(background.title)
                                if background.usesDarkBackground == overflowUsesDarkBackground {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        FileBrowserCoverFlowChromeIcon(
                            kind: .more,
                            usesDarkBackground: overflowUsesDarkBackground
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("배경 선택")
                }
            }
        }
    }

    @ViewBuilder
    private var connectionPanel: some View {
        if !isSelecting {
            WebHardConnectionPanel()
                .frame(maxWidth: ui(760))
                .padding(.horizontal, ui(16))
                .padding(.top, ui(12))
                .padding(.bottom, ui(10))
        }
    }

    private var layoutStyle: ReceivedFilesLayoutStyle {
        ReceivedFilesLayoutPresentationPolicy.normalizedSelection(
            storedLayoutStyle,
            allowsExplicitOverflow: !isPhoneIdiom
        )
    }

    /// Direct children of `currentPath`: never a grandchild, so one screen is always
    /// exactly one folder level.
    private var currentLevelRecords: [SharedInboxRecord] {
        inboxStore.children(of: currentPath)
    }

    private var currentLevelFolders: [SharedInboxRecord] {
        currentLevelRecords
            .filter(\.isDirectory)
            .sorted { $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending }
    }

    private var currentLevelFiles: [SharedInboxRecord] {
        currentLevelRecords.filter { !$0.isDirectory }
    }

    /// PhoneHard's physical Music folder has no manifest folder record of its own, so it
    /// is shown as one synthetic row at the root only, navigating exactly like any other
    /// folder. The overflow layout has no place for folder rows at all, and a real folder
    /// or file already named Music already is that row, so both skip the synthetic one.
    private var showsSyntheticMusicFolder: Bool {
        currentPath == nil
            && presentedLayoutStyle != .overflow
            && inboxStore.musicFolderExists
            && !currentLevelRecords.contains { $0.storedFilename == SharedInbox.musicDirectoryName }
    }

    /// What the list, selection and "전체 선택" act on: never a record that is not on screen.
    private var visibleRecords: [SharedInboxRecord] {
        presentedLayoutStyle == .overflow
            ? inboxStore.records.filter { !$0.isDirectory }
            : currentLevelFolders + currentLevelFiles
    }

    private var syntheticMusicFolderRow: some View {
        Button {
            navigateInto(SharedInbox.musicDirectoryName)
        } label: {
            folderRowLabel(
                name: "Music",
                childCount: inboxStore.children(of: SharedInbox.musicDirectoryName).count,
                isSelected: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Music 폴더 열기")
    }

    private func folderRow(_ folder: SharedInboxRecord) -> some View {
        Button {
            if isSelecting {
                toggleSelection(of: folder)
            } else {
                navigateInto(folder.storedFilename)
            }
        } label: {
            HStack(spacing: ui(12)) {
                if isSelecting {
                    Image(
                        systemName: selectedRecordIDs.contains(folder.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.ui(.title3))
                    .foregroundStyle(
                        selectedRecordIDs.contains(folder.id) ? Color.accentColor : .secondary
                    )
                    .accessibilityHidden(true)
                }
                folderRowLabel(
                    name: folder.originalFilename,
                    childCount: inboxStore.children(of: folder.storedFilename).count,
                    isSelected: selectedRecordIDs.contains(folder.id)
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelecting ? selectionAccessibilityLabel(for: folder) : folder.originalFilename
        )
    }

    private func folderRowLabel(name: String, childCount: Int, isSelected: Bool) -> some View {
        HStack(spacing: ui(12)) {
            Image(systemName: "folder.fill")
                .font(.ui(.title3))
                .foregroundStyle(Color.accentColor)
                .frame(width: ui(56), height: ui(44))
            VStack(alignment: .leading, spacing: ui(4)) {
                Text(name)
                    .foregroundStyle(.primary)
                Text("\(childCount)개 항목")
                    .font(.ui(.caption))
                    .foregroundStyle(PorcelainMetrics.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.ui(.caption))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var presentedLayoutStyle: ReceivedFilesLayoutStyle {
        ReceivedFilesLayoutPresentationPolicy.presentedStyle(
            selectedStyle: layoutStyle,
            contentSize: contentSize,
            isSelecting: isSelecting,
            hasRecords: !inboxStore.records.isEmpty,
            isPhone: isPhoneIdiom
        )
    }

    private var isPhoneIdiom: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// iPad/Mac close an explicitly chosen 플로잉 back to the previous view mode
    /// in the same folder; iPhone keeps its existing dismiss.
    private func closeOverflowOrDismiss() {
        guard !isPhoneIdiom, layoutStyle == .overflow else {
            dismiss()
            return
        }
        storedLayoutStyle = (overflowReturnStyle ?? .posters).rawValue
        overflowReturnStyle = nil
    }

    private var isEnamel: Bool {
        false // 예전 에나멜 장식은 6개 테마에 없다.
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: ui(layoutStyle == .posters ? 164 : 104)), spacing: ui(14))]
    }

    private func normalizeStoredLayoutStyle() {
        let normalized = ReceivedFilesLayoutPresentationPolicy
            .normalizedSelection(storedLayoutStyle)
        if storedLayoutStyle != normalized.rawValue {
            storedLayoutStyle = normalized.rawValue
        }
    }

    private func updateOrientation(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = size
    }

    @ViewBuilder
    private func recordContextMenu(_ record: SharedInboxRecord) -> some View {
        if !isSelecting {
            if !record.isDirectory {
                let item = LocalInboxFileService.remoteItem(for: record)
                if item.isTrailerEligible {
                    Button("예고편 보기", systemImage: "film") { trailerSelection = VideoTrailerSelection(items: [item]) }
                }
                if item.isVideo {
                    Button("뮤직비디오", systemImage: "music.note") {
                        trailerSelection = VideoTrailerSelection(items: [item], mode: .mediaMusic)
                    }
                }
                if isUploadableFile(record) {
                    Button("NAS로 보내기", systemImage: "arrow.up.doc") {
                        beginUpload(of: [record])
                    }
                }

                if let fileURL = try? SharedInbox.fileURL(for: record) {
                    ShareLink(item: fileURL) {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Button("이동", systemImage: "folder") {
                pendingFileOperation = InboxFileOperation(kind: .move, records: [record])
            }
            Button("복사", systemImage: "doc.on.doc") {
                pendingFileOperation = InboxFileOperation(kind: .copy, records: [record])
            }

            Button("삭제", systemImage: "trash", role: .destructive) {
                requestDeletion(of: [record])
            }
        }
    }

    private func activate(_ record: SharedInboxRecord) {
        if isSelecting {
            toggleSelection(of: record)
        } else {
            previewItem = LocalInboxFileService.remoteItem(for: record)
        }
    }

    private func receivedFileTile(_ record: SharedInboxRecord, poster: Bool) -> some View {
        let item = LocalInboxFileService.remoteItem(for: record)
        let selected = selectedRecordIDs.contains(record.id)
        let requestSide: CGFloat = poster ? 360 : 220
        let requestSize = ReceivedFilesThumbnailPolicy.squareSize(
            CGSize(width: requestSide, height: requestSide)
        )

        return Button {
            activate(record)
        } label: {
            VStack(alignment: .leading, spacing: ui(poster ? 9 : 6)) {
                GeometryReader { proxy in
                    let containerSize = ReceivedFilesThumbnailPolicy.squareContainerSize(
                        forWidth: proxy.size.width
                    )

                    receivedFileArtwork(
                        for: item,
                        record: record,
                        requestSize: requestSize
                    )
                    .frame(width: containerSize.width, height: containerSize.height)
                }
                .aspectRatio(1, contentMode: .fit)
                .background(.quaternary.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: ui(poster ? 15 : 11)))
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.ui(.title2))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .padding(ui(8))
                    }
                }

                Text(record.originalFilename)
                    .font(poster ? .ui(.headline) : .ui(.caption))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                LocalInboxSizeLabel(record: record, item: item, playback: inlineMusic)
                    .font(.ui(.caption2))
                    .foregroundStyle(PorcelainMetrics.secondary)

                if poster {
                    Text(record.importedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelecting ? selectionAccessibilityLabel(for: record) : record.originalFilename
        )
    }

    private func receivedFileRow(_ record: SharedInboxRecord) -> some View {
        let item = LocalInboxFileService.remoteItem(for: record)

        return HStack(spacing: ui(12)) {
            Button {
                if isSelecting {
                    toggleSelection(of: record)
                } else {
                    inlineMusic.stop()
                    previewItem = item
                }
            } label: {
                HStack(spacing: ui(12)) {
                    if isSelecting {
                        Image(
                            systemName: selectedRecordIDs.contains(record.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.ui(.title3))
                        .foregroundStyle(
                            selectedRecordIDs.contains(record.id) ? Color.accentColor : .secondary
                        )
                        .accessibilityHidden(true)
                    }

                    leadingPreview(for: item, record: record)

                    VStack(alignment: .leading, spacing: ui(4)) {
                        Text(record.originalFilename)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        HStack(spacing: ui(7)) {
                            LocalInboxSizeLabel(record: record, item: item, playback: inlineMusic)
                            Text(record.importedAt, format: .dateTime
                                .year().month().day().hour().minute())
                        }
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isSelecting
                    ? selectionAccessibilityLabel(for: record)
                    : record.originalFilename
            )
            .accessibilityValue(
                ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)
            )

            if !isSelecting, let fileURL = try? SharedInbox.fileURL(for: record) {
                ShareLink(item: fileURL) {
                    ThemedSymbol(systemName: "square.and.arrow.up", size: ui(22))
                        .frame(width: ui(38), height: ui(38))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(record.originalFilename) 공유")
            }
        }
        .padding(.vertical, ui(3))
    }

    private var uploadSelectionBar: some View {
        VStack(spacing: ui(10)) {
            HStack(spacing: ui(10)) {
                Button("예고편 보기", systemImage: "film") {
                    let clips = selectedRecords.map { LocalInboxFileService.remoteItem(for: $0) }
                    guard !clips.isEmpty, clips.allSatisfy(\.isTrailerEligible) else { return }
                    trailerSelection = VideoTrailerSelection(items: clips)
                    endSelection()
                }
                Button("뮤직비디오", systemImage: "music.note") {
                    let clips = selectedRecords.map { LocalInboxFileService.remoteItem(for: $0) }
                    guard !clips.isEmpty, clips.allSatisfy(\.isTrailerEligible) else { return }
                    trailerSelection = VideoTrailerSelection(items: clips, mode: .mediaMusic)
                    endSelection()
                }
            }
            .buttonStyle(.bordered)
            .disabled(selectedRecords.isEmpty || !selectedRecords.allSatisfy { LocalInboxFileService.remoteItem(for: $0).isTrailerEligible })
            Button("NAS로 보내기", systemImage: "arrow.up.doc") {
                beginUpload(of: selectedUploadableRecords)
            }
            .buttonStyle(PorcelainProminentButtonStyle())
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(selectedUploadableRecords.isEmpty)
            .accessibilityLabel("선택한 파일 \(selectedUploadableRecords.count)개를 NAS로 보내기")
        }
        .padding(.horizontal, ui(16))
        .padding(.top, ui(10))
        .padding(.bottom, ui(8))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedRecords: [SharedInboxRecord] {
        visibleRecords.filter {
            selectedRecordIDs.contains($0.id)
        }
    }

    private var selectedUploadableRecords: [SharedInboxRecord] {
        selectedRecords.filter(isUploadableFile)
    }

    private var uploadabilityTaskID: UploadabilityTaskID {
        UploadabilityTaskID(
            records: inboxStore.records,
            refreshGeneration: uploadabilityRefreshGeneration
        )
    }

    private var allRecordsAreSelected: Bool {
        let recordIDs = Set(visibleRecords.map(\.id))
        return !recordIDs.isEmpty && selectedRecordIDs == recordIDs
    }

    private func toggleAllSelection() {
        if allRecordsAreSelected {
            selectedRecordIDs.removeAll()
        } else {
            selectedRecordIDs = Set(visibleRecords.map(\.id))
        }
    }

    private func navigateInto(_ storedPath: String) {
        selectedRecordIDs.removeAll()
        currentPath = storedPath
    }

    private func navigateUp() {
        selectedRecordIDs.removeAll()
        currentPath = SharedInboxStore.parentPath(of: currentPath ?? "")
    }

    private var currentFolderDisplayName: String {
        guard let currentPath else { return "폰하드" }
        if currentPath == SharedInbox.musicDirectoryName { return "Music" }
        return inboxStore.records.first { $0.storedFilename == currentPath }?.originalFilename
            ?? (currentPath as NSString).lastPathComponent
    }

    private var parentFolderDisplayName: String {
        guard let parentPath = SharedInboxStore.parentPath(of: currentPath ?? "") else {
            return "폰하드"
        }
        if parentPath == SharedInbox.musicDirectoryName { return "Music" }
        return inboxStore.records.first { $0.storedFilename == parentPath }?.originalFilename
            ?? (parentPath as NSString).lastPathComponent
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newFolderName = ""
        Task {
            await inboxStore.createFolder(named: name, in: currentPath)
        }
    }

    /// A folder's own descendants are never offered as its destination, which also keeps
    /// the picker from ever producing a move/copy into the source itself.
    private func excludedDestinationPaths(for records: [SharedInboxRecord]) -> Set<String> {
        var excluded = Set<String>()
        for record in records where record.isDirectory {
            excluded.insert(record.storedFilename)
        }
        return excluded
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    /// Reloads PhoneHard from disk before showing the confirmation, so neither a file just
    /// dropped in by WebHard nor a hidden file is missing from what the alert promises to
    /// delete, then re-resolves the selection by `id` against that fresh snapshot. Context
    /// menu, swipe, and multi-select deletion all funnel through here so every entry point
    /// confirms against the same up-to-date state before the user ever sees the alert; the
    /// actual delete only runs afterward, from `confirmDeletion`, once the user agrees.
    private func requestDeletion(of recordsToDelete: [SharedInboxRecord]) {
        guard !recordsToDelete.isEmpty else { return }
        reloadInbox()
        let latestByID = Dictionary(uniqueKeysWithValues: inboxStore.records.map { ($0.id, $0) })
        let refreshedRecords = recordsToDelete.compactMap { latestByID[$0.id] }
        guard !refreshedRecords.isEmpty else { return }
        pendingDeletion = refreshedRecords
    }

    private func deletionConfirmationMessage(for recordsToDelete: [SharedInboxRecord]) -> String {
        let folderCount = recordsToDelete.filter(\.isDirectory).count
        guard folderCount > 0 else {
            return "선택한 \(recordsToDelete.count)개 항목이 이 기기에서 삭제됩니다."
        }
        let descendantCount = recordsToDelete
            .filter(\.isDirectory)
            .reduce(into: 0) { total, folder in
                total += inboxStore.descendantCount(of: folder.storedFilename)
            }
        return descendantCount > 0
            ? "선택한 \(recordsToDelete.count)개 항목과 폴더 안의 모든 항목(\(descendantCount)개)이 이 기기에서 삭제됩니다."
            : "선택한 \(recordsToDelete.count)개 항목이 이 기기에서 삭제됩니다."
    }

    private func confirmDeletion(of recordsToDelete: [SharedInboxRecord]) {
        pendingDeletion = nil
        guard !recordsToDelete.isEmpty else { return }
        inboxStore.delete(recordsToDelete)
        if isSelecting { endSelection() }
    }

    private func toggleSelection(of record: SharedInboxRecord) {
        if selectedRecordIDs.contains(record.id) {
            selectedRecordIDs.remove(record.id)
        } else {
            selectedRecordIDs.insert(record.id)
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedRecordIDs.removeAll()
    }

    private func reloadInbox() {
        inboxStore.reload()
        uploadabilityRefreshGeneration &+= 1
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        uploadabilityRefreshGeneration &+= 1
    }

    private func refreshUploadability() async {
        let records = inboxStore.records
        let refreshGeneration = uploadabilityRefreshGeneration
        let uploadableIDs = await Task.detached(priority: .utility) {
            Set(records.compactMap { record -> SharedInboxRecord.ID? in
                guard let url = try? SharedInbox.fileURL(for: record),
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey]
                      ),
                      values.isRegularFile == true else { return nil }
                return record.id
            })
        }.value
        guard !Task.isCancelled,
              inboxStore.records == records,
              uploadabilityRefreshGeneration == refreshGeneration else { return }
        uploadableRecordIDs = uploadableIDs
    }

    private func beginUpload(of records: [SharedInboxRecord]) {
        guard !records.isEmpty else { return }

        do {
            var preparedSources: [LocalUploadSource] = []
            for record in records {
                let url = try SharedInbox.fileURL(for: record)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                preparedSources.append(
                    LocalUploadSource(url: url, preferredName: record.originalFilename)
                )
            }
            guard !preparedSources.isEmpty else {
                throw ReceivedFileUploadError.folderUnsupported(
                    records.first?.originalFilename ?? "선택한 항목"
                )
            }
            pendingUploadSources = preparedSources
            isChoosingUploadDestination = true
        } catch {
            pendingUploadSources = []
            inboxStore.errorMessage = "NAS로 보낼 파일을 준비하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func isUploadableFile(_ record: SharedInboxRecord) -> Bool {
        uploadableRecordIDs.contains(record.id)
    }

    private func selectionAccessibilityLabel(for record: SharedInboxRecord) -> String {
        guard isUploadableFile(record) else {
            return "\(record.originalFilename), 폴더는 NAS 전송 선택 불가"
        }
        return "\(record.originalFilename), \(selectedRecordIDs.contains(record.id) ? "선택됨" : "선택하지 않음")"
    }

    @ViewBuilder
    private func leadingPreview(
        for item: RemoteFileItem,
        record: SharedInboxRecord
    ) -> some View {
        let size = ReceivedFilesThumbnailPolicy.squareSize(CGSize(width: 56, height: 56))
        let shape = RoundedRectangle(cornerRadius: ui(9))

        receivedFileArtwork(for: item, record: record, requestSize: size)
        .frame(width: ui(size.width), height: ui(size.height))
        .background(.quaternary.opacity(0.55), in: shape)
        .clipShape(shape)
        .overlay {
            if item.isAudio, !isSelecting, let url = try? SharedInbox.fileURL(for: record) {
                InlineMusicThumbnailControl(playback: inlineMusic, id: item.id, name: record.originalFilename) {
                    inlineMusic.toggle(id: item.id, localURL: url)
                }
            }
        }
        .accessibilityHidden(!(item.isAudio && !isSelecting))
    }

    @ViewBuilder
    private func receivedFileArtwork(
        for item: RemoteFileItem,
        record: SharedInboxRecord,
        requestSize: CGSize
    ) -> some View {
        if item.isImage || item.isVideo || item.contentType.conforms(to: .pdf) {
            LocalInboxThumbnailView(record: record, item: item, size: requestSize)
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: ui(min(requestSize.width, requestSize.height) * 0.42)))
                .foregroundStyle(iconColor(for: item))
        }
    }

    private func sequentialMediaItems(
        from records: [SharedInboxRecord],
        including item: RemoteFileItem
    ) -> [RemoteFileItem] {
        guard item.isImage || item.isVideo else { return [item] }

        let relatedItems = records.map { LocalInboxFileService.remoteItem(for: $0) }
        return relatedItems.contains(item) ? relatedItems : [item]
    }

    private func iconColor(for item: RemoteFileItem) -> Color {
        if item.isImage { return .blue }
        if item.isVideo { return .pink }
        return .secondary
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { inboxStore.errorMessage != nil },
            set: { if !$0 { inboxStore.errorMessage = nil } }
        )
    }
}

enum ReceivedFilesThumbnailPolicy {
    static func squareSize(_ proposedSize: CGSize) -> CGSize {
        let side = max(proposedSize.width, proposedSize.height)
        return CGSize(width: side, height: side)
    }

    static func squareContainerSize(forWidth width: CGFloat) -> CGSize {
        let side = max(0, width)
        return CGSize(width: side, height: side)
    }
}

/// The file size and, right after it, the playing time of a video or music file. The
/// time appears only once the file's own length has been read; before that, and for a
/// file whose length cannot be read, there is just the size. Photos and other files
/// are never read for this.
private struct LocalInboxSizeLabel: View {
    let record: SharedInboxRecord
    let item: RemoteFileItem
    var playback: InlineMusicPlayback?

    @State private var loadedSeconds: Double?

    var body: some View {
        let seconds = loadedSeconds
            ?? LocalInboxMediaDurationCache.shared.known(LocalInboxMediaDurationCache.key(for: item))
        HStack(spacing: ui(7)) {
            Text(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))
            if let playback, item.isAudio {
                InlineMusicTimeText(playback: playback, id: item.id, fallbackTotal: seconds)
            } else if let seconds {
                Text(Self.playingTime(seconds))
                    .monospacedDigit()
                    .accessibilityLabel("재생 시간 \(Self.playingTime(seconds))")
            }
        }
        .task(id: LocalInboxMediaDurationCache.key(for: item)) {
            guard item.isVideo || item.isAudio else {
                loadedSeconds = nil
                return
            }
            loadedSeconds = await LocalInboxMediaDurationCache.shared.seconds(for: record, item: item)
        }
    }

    /// mm:ss, or h:mm:ss from one hour.
    static func playingTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Playing times already read, keyed like the thumbnail cache by the file's id, date
/// and size, so drawing a row again or scrolling it back in never reads the file again.
/// A file that reported no usable length is remembered as such and not retried.
@MainActor
private final class LocalInboxMediaDurationCache {
    static let shared = LocalInboxMediaDurationCache()

    private var results: [String: Double?] = [:]
    private var loads: [String: Task<Double?, Never>] = [:]

    static func key(for item: RemoteFileItem) -> String {
        "\(item.id)|\(item.modifiedAt?.timeIntervalSince1970 ?? 0)|\(item.size ?? -1)"
    }

    func known(_ key: String) -> Double? {
        results[key] ?? nil
    }

    func seconds(for record: SharedInboxRecord, item: RemoteFileItem) async -> Double? {
        await seconds(for: item) { try? SharedInbox.fileURL(for: record) }
    }

    func seconds(for item: RemoteFileItem, fileURL resolve: () async -> URL?) async -> Double? {
        let key = Self.key(for: item)
        if let known = results[key] { return known }
        if let running = loads[key] { return await running.value }
        guard let fileURL = await resolve() else { return nil }
        let load = Task.detached(priority: .utility) { () -> Double? in
            guard let duration = try? await AVURLAsset(url: fileURL).load(.duration) else { return nil }
            let seconds = duration.seconds
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        loads[key] = load
        let seconds = await load.value
        loads[key] = nil
        results.updateValue(seconds, forKey: key)
        return seconds
    }
}

/// The playing time of a PhoneHard video or music file for the shared browser's rows,
/// shown right after the file size there. Read once per file through the same cache
/// and drawn as nothing until the length is known.
struct LocalInboxDurationLabel: View {
    let item: RemoteFileItem

    @State private var loadedSeconds: Double?

    var body: some View {
        let seconds = loadedSeconds
            ?? LocalInboxMediaDurationCache.shared.known(LocalInboxMediaDurationCache.key(for: item))
        ZStack {
            if let seconds {
                Text(LocalInboxSizeLabel.playingTime(seconds))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("재생 시간 \(LocalInboxSizeLabel.playingTime(seconds))")
            }
        }
        .task(id: LocalInboxMediaDurationCache.key(for: item)) {
            guard item.isVideo || item.isAudio else {
                loadedSeconds = nil
                return
            }
            loadedSeconds = await LocalInboxMediaDurationCache.shared.seconds(for: item) {
                try? await LocalInboxFileService().download(item)
            }
        }
    }
}

private struct LocalInboxThumbnailView: View {
    let record: SharedInboxRecord
    let item: RemoteFileItem
    let size: CGSize

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.systemImage)
                    .font(.ui(.title2))
                    .foregroundStyle(PorcelainMetrics.secondary)
            }

            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.ui(.title3))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(ui(5))
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: thumbnailTaskID) {
            await loadThumbnail()
        }
    }

    private var thumbnailTaskID: String {
        "\(record.id.uuidString)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    @MainActor
    private func loadThumbnail() async {
        image = nil
        isLoading = true
        defer { isLoading = false }

        guard let fileURL = try? SharedInbox.fileURL(for: record) else { return }
        let maximumPixelSize = Int(
            ceil(max(size.width, size.height) * UIScreen.main.scale)
        )
        let cacheKey = RemoteThumbnailCacheKey.remoteData(
            for: item,
            size: thumbnailSize(for: maximumPixelSize)
        )
        if let cachedData = await SuperThumbnailCache.shared.data(forKey: cacheKey),
           let cachedImage = try? await RemoteThumbnailImageDecoder.downsample(
            data: cachedData,
            maximumPixelSize: maximumPixelSize
           ) {
            guard !Task.isCancelled else { return }
            image = UIImage(cgImage: cachedImage.image)
            return
        }

        if item.isImage,
           let decodedImage = await LocalInboxImageThumbnailGenerator.generate(
            fileURL: fileURL,
            maximumPixelSize: maximumPixelSize
           ) {
            guard !Task.isCancelled else { return }
            image = decodedImage
            await storeInSuperThumbnailCache(decodedImage, forKey: cacheKey)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }
        guard !Task.isCancelled else { return }
        image = representation.uiImage
        await storeInSuperThumbnailCache(representation.uiImage, forKey: cacheKey)
    }

    private func thumbnailSize(for maximumPixelSize: Int) -> RemoteThumbnailSize {
        if maximumPixelSize <= 360 { return .small }
        if maximumPixelSize <= 1_024 { return .medium }
        return .large
    }

    private func storeInSuperThumbnailCache(_ image: UIImage, forKey key: String) async {
        guard let data = image.jpegData(compressionQuality: 0.84) else { return }
        await SuperThumbnailCache.shared.store(data, forKey: key)
    }
}

private struct LocalInboxSendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private enum LocalInboxImageThumbnailGenerator {
    static func generate(fileURL: URL, maximumPixelSize: Int) async -> UIImage? {
        let boundedMaximumPixelSize = max(maximumPixelSize, 1)
        let decoded = await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as LocalInboxSendableCGImage? }
            return autoreleasepool {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(
                    fileURL as CFURL,
                    sourceOptions
                ), CGImageSourceGetCount(source) > 0 else { return nil }

                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: boundedMaximumPixelSize,
                ] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbnailOptions
                ) else { return nil }
                return LocalInboxSendableCGImage(image: image)
            }
        }.value
        guard !Task.isCancelled, let decoded else { return nil }
        return UIImage(cgImage: decoded.image)
    }
}

private struct ReceivedFilesImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let importFiles: ([URL]) -> Void
    let importFailed: (Error) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.data, .content],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    importFiles(urls)
                case .failure(let error):
                    importFailed(error)
                }
            }
            .fileDialogConfirmationLabel("가져오기")
            .fileDialogMessage("나의 iPhone 또는 iCloud Drive에서 파일을 선택하세요.")
    }
}

/// PhoneHard as a file service: the files this app keeps on the device, read and changed
/// through `SharedInbox` only. It backs the same browser, preview and trailer screens a
/// network connection does. Nothing here talks to a server.
struct LocalInboxFileService: RemoteFileService {
    static let connectionID = UUID(uuidString: "8E89F463-1601-4A4A-9890-0E7429A5DA94")!
    static let rootPath = "/"

    /// What the shared screens are handed where they expect a connection. It is never
    /// saved with the user's connections and has no account, credential or address; the
    /// kind only selects the photo-and-video rules those screens already apply.
    static let phoneHardConnection = RemoteConnection(
        id: connectionID,
        name: "폰하드",
        kind: .synology,
        host: "localhost",
        username: "",
        rootPath: rootPath
    )

    let connection = LocalInboxFileService.phoneHardConnection

    /// Copy and move are done in place on the device by `SharedInbox`, which is what the
    /// "server side" options mean for a service with no transfer of its own.
    let capabilities: RemoteFileServiceCapabilities = [
        .createFolder,
        .rename,
        .delete,
        .recursiveDelete,
        .upload,
        .serverSideCopy,
        .serverSideMove,
    ]

    /// Records handed over by a caller that addresses files by record id.
    private let recordsByPath: [String: SharedInboxRecord]

    init(records: [SharedInboxRecord] = []) {
        recordsByPath = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id.uuidString, $0) }
        )
    }

    /// `nil` keeps the flat list of the records this service was created with. A path
    /// lists exactly one folder level of PhoneHard as it is on disk now.
    func list(directory path: String?) async throws -> [RemoteFileItem] {
        guard let path else {
            return recordsByPath.values
                .sorted { $0.importedAt > $1.importedAt }
                .map { Self.remoteItem(for: $0) }
        }
        let parent = Self.storedPath(forBrowserPath: path)
        return try SharedInbox.records()
            .filter { Self.parentStoredPath(of: $0.storedFilename) == parent }
            .map { Self.browserItem(for: $0) }
    }

    /// The stored file itself, never a copy: callers only read it.
    func download(_ item: RemoteFileItem) async throws -> URL {
        let record = try storedRecord(for: item)
        guard !record.isDirectory else { throw LocalInboxFileError.recordNotFound }
        let url = try SharedInbox.fileURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalInboxFileError.recordNotFound
        }
        return url
    }

    /// Made on the device from the stored file, so the browser's thumbnails need no
    /// network. `nil` for a file with nothing to draw.
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        guard !item.isDirectory, item.supportsQuickLookThumbnail, !item.isAudio else { return nil }
        let fileURL = try await download(item)
        let maximumPixelSize: Int
        switch size {
        case .small: maximumPixelSize = 360
        case .medium: maximumPixelSize = 1_024
        case .large: maximumPixelSize = 1_600
        }
        if item.isImage,
           let image = await LocalInboxImageThumbnailGenerator.generate(
            fileURL: fileURL,
            maximumPixelSize: maximumPixelSize
           ) {
            return image.jpegData(compressionQuality: 0.84)
        }
        let side = CGFloat(maximumPixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: side, height: side),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        try Task.checkCancellation()
        return representation.uiImage.jpegData(compressionQuality: 0.84)
    }

    func testConnection() async throws {}

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        try context.checkCancellation()
        let record = try SharedInbox.createFolder(
            named: name,
            in: Self.storedPath(forBrowserPath: directoryPath)
        )
        return Self.browserItem(for: record)
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        try context.checkCancellation()
        let record = try storedRecord(for: item)
        try rejectMusicFolderRelocation(of: record)
        return Self.browserItem(for: try SharedInbox.renameItem(record, to: newName))
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try context.checkCancellation()
        try SharedInbox.delete(try storedRecord(for: item))
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .delete,
            outcomes: [.succeeded(sourcePath: item.path)]
        )
    }

    /// Adds a copy of `localURL` to the folder under a name nothing there uses yet. The
    /// picked file is only read, and nothing already in PhoneHard is replaced.
    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try context.checkCancellation()
        let folderPath = Self.storedPath(forBrowserPath: directoryPath)
        var name = preferredName ?? localURL.lastPathComponent
        // Reserved at the PhoneHard root only; inside a folder it is an ordinary name.
        if folderPath == nil, name.caseInsensitiveCompare("manifest.json") == .orderedSame {
            name = "manifest (가져옴).json"
        }
        let contentTypeIdentifier = try? localURL
            .resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier

        // Coordinated like every other import, so a file still in iCloud is fetched first.
        var imported: Result<SharedInboxRecord, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: localURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            imported = Result {
                try SharedInbox.importTemporaryItem(
                    at: coordinatedURL,
                    originalFilename: name,
                    contentTypeIdentifier: contentTypeIdentifier,
                    intoFolder: folderPath
                )
            }
        }
        if let coordinationError { throw coordinationError }
        guard let imported else { throw LocalInboxFileError.recordNotFound }
        let item = Self.browserItem(for: try imported.get())
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [
                .succeeded(
                    sourcePath: localURL.path,
                    destinationPath: item.path,
                    resultingItem: item
                ),
            ]
        )
    }

    /// The original stays as it is; a name already used in the folder gets a new one.
    func copy(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try context.checkCancellation()
        let copies = try SharedInbox.copyItem(
            try storedRecord(for: item),
            toFolder: Self.storedPath(forBrowserPath: directoryPath)
        )
        let copiedItem = copies.first.map { Self.browserItem(for: $0) }
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .copy,
            outcomes: [
                .succeeded(
                    sourcePath: item.path,
                    destinationPath: copiedItem?.path,
                    resultingItem: copiedItem
                ),
            ]
        )
    }

    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try context.checkCancellation()
        let record = try storedRecord(for: item)
        try rejectMusicFolderRelocation(of: record)
        let movedItem = Self.browserItem(
            for: try SharedInbox.moveItem(
                record,
                toFolder: Self.storedPath(forBrowserPath: directoryPath)
            )
        )
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .move,
            outcomes: [
                .succeeded(
                    sourcePath: item.path,
                    destinationPath: movedItem.path,
                    resultingItem: movedItem
                ),
            ]
        )
    }

    /// An item addressed by record id, as the screens that are handed records use it.
    static func remoteItem(for record: SharedInboxRecord) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: record.id.uuidString,
            name: record.originalFilename,
            kind: .file,
            size: record.byteCount,
            modifiedAt: record.importedAt,
            contentTypeIdentifier: record.contentTypeIdentifier
        )
    }

    /// An item addressed by where it is stored, as the browser lists it: a folder's path
    /// is what its own listing is asked for.
    static func browserItem(for record: SharedInboxRecord) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: rootPath + record.storedFilename,
            name: record.originalFilename,
            kind: record.isDirectory ? .folder : .file,
            size: record.isDirectory ? nil : record.byteCount,
            modifiedAt: record.importedAt,
            contentTypeIdentifier: record.contentTypeIdentifier
        )
    }

    /// A browser path as `SharedInbox` names it; `nil` is the PhoneHard root.
    static func storedPath(forBrowserPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parentStoredPath(of storedFilename: String) -> String? {
        let parent = (storedFilename as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// A browser item carries everything `SharedInbox` matches a stored item by, so it
    /// is addressed by where it is stored without reading the manifest again.
    private func storedRecord(for item: RemoteFileItem) throws -> SharedInboxRecord {
        if let record = recordsByPath[item.path] { return record }
        guard item.connectionID == Self.connectionID,
              item.path.hasPrefix(Self.rootPath),
              let storedFilename = Self.storedPath(forBrowserPath: item.path) else {
            throw LocalInboxFileError.recordNotFound
        }
        return SharedInboxRecord(
            id: UUID(),
            originalFilename: item.name,
            storedFilename: storedFilename,
            contentTypeIdentifier: item.contentTypeIdentifier,
            byteCount: item.size ?? 0,
            importedAt: item.modifiedAt ?? Date(),
            isDirectory: item.isDirectory
        )
    }

    /// Music picked for a video is looked for in the root Music folder by that name.
    private func rejectMusicFolderRelocation(of record: SharedInboxRecord) throws {
        if record.storedFilename == SharedInbox.musicDirectoryName {
            throw LocalInboxFileError.musicFolderFixed
        }
    }
}

private enum LocalInboxFileError: LocalizedError {
    case recordNotFound
    case musicFolderFixed

    var errorDescription: String? {
        switch self {
        case .recordNotFound:
            "폰하드 파일을 찾을 수 없습니다. 목록을 새로 고친 뒤 다시 시도하세요."
        case .musicFolderFixed:
            "Music 폴더는 뮤직비디오가 음악을 찾는 폴더라 이름을 바꾸거나 옮길 수 없습니다. 안의 파일은 그대로 다룰 수 있습니다."
        }
    }
}

private enum ReceivedFileUploadError: LocalizedError {
    case folderUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .folderUnsupported(let name):
            "\(name)은(는) 폴더입니다. 현재는 파일만 NAS로 보낼 수 있습니다."
        }
    }
}
