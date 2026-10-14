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
        case .overflow: "오버플로우"
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
    static func normalizedSelection(_ rawValue: String) -> ReceivedFilesLayoutStyle {
        guard let style = ReceivedFilesLayoutStyle(rawValue: rawValue), style != .overflow else {
            return rawValue == ReceivedFilesLayoutStyle.overflow.rawValue ? .posters : .details
        }
        return style
    }

    static func presentedStyle(
        selectedStyle: ReceivedFilesLayoutStyle,
        contentSize: CGSize,
        isSelecting: Bool,
        hasRecords: Bool
    ) -> ReceivedFilesLayoutStyle {
        selectedStyle == .posters
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

struct ReceivedFilesView: View {
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
        AppThemePreference.system.rawValue
    @State private var previewItem: RemoteFileItem?
    @State private var trailerSelection: VideoTrailerSelection?
    /// `nil` is the PhoneHard root; otherwise a folder's `storedFilename`, including the
    /// physical Music folder, which now navigates through this same mechanism.
    @State private var currentPath: String?
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
            .fullScreenCover(item: $trailerSelection, onDismiss: { reloadInbox() }) { selection in
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
            .sheet(
                isPresented: $isImportingFromGooglePhotos,
                onDismiss: {
                    reloadInbox()
                }
            ) {
                GooglePhotosImportFlowView(inboxStore: inboxStore)
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
                    .buttonStyle(.borderedProminent)

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
            ForEach(ReceivedFilesLayoutStyle.selectableCases) { style in
                Button {
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
                        dismiss()
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
        ReceivedFilesLayoutPresentationPolicy.normalizedSelection(storedLayoutStyle)
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
                    .foregroundStyle(.secondary)
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
            hasRecords: !inboxStore.records.isEmpty
        )
    }

    private var isEnamel: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
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
                    Button("음악 입히기", systemImage: "music.note") {
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

                Text(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))
                    .font(.ui(.caption2))
                    .foregroundStyle(.secondary)

                if poster {
                    Text(record.importedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
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
                            Text(ByteCountFormatter.string(
                                fromByteCount: record.byteCount,
                                countStyle: .file
                            ))
                            Text(record.importedAt, format: .dateTime
                                .year().month().day().hour().minute())
                        }
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
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
                    Image(systemName: "square.and.arrow.up")
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
                Button("음악 입히기", systemImage: "music.note") {
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
            .buttonStyle(.borderedProminent)
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
        .accessibilityHidden(true)
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
                    .foregroundStyle(.secondary)
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

struct LocalInboxFileService: RemoteFileService {
    static let connectionID = UUID(uuidString: "8E89F463-1601-4A4A-9890-0E7429A5DA94")!

    let connection = RemoteConnection(
        id: connectionID,
        name: "폰하드",
        kind: .synology,
        host: "localhost",
        username: ""
    )

    private let recordsByPath: [String: SharedInboxRecord]

    init(records: [SharedInboxRecord]) {
        recordsByPath = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id.uuidString, $0) }
        )
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        recordsByPath.values
            .sorted { $0.importedAt > $1.importedAt }
            .map { Self.remoteItem(for: $0) }
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        guard let record = recordsByPath[item.path] else {
            throw LocalInboxFileError.recordNotFound
        }
        return try SharedInbox.fileURL(for: record)
    }

    func testConnection() async throws {}

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
}

private enum LocalInboxFileError: LocalizedError {
    case recordNotFound

    var errorDescription: String? {
        "폰하드 파일을 찾을 수 없습니다. 목록을 새로 고친 뒤 다시 시도하세요."
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
