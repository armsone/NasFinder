import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    private struct DisplayRequest: Equatable {
        let query: String
        let sortOptions: FileBrowserSortOptions
    }

    private enum LayoutStyle: String, CaseIterable, Identifiable {
        case list
        case smallThumbnails
        case largeThumbnails

        var id: String { rawValue }

        var title: String {
            switch self {
            case .list:
                "\u{BAA9}\u{B85D} \u{BCF4}\u{AE30}"
            case .smallThumbnails:
                "\u{C791}\u{C740} \u{C378}\u{B124}\u{C77C}"
            case .largeThumbnails:
                "\u{D070} \u{C378}\u{B124}\u{C77C}"
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
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("fileBrowserLayoutStyle") private var storedLayoutStyle = LayoutStyle.smallThumbnails.rawValue
    @AppStorage("fileBrowserSortField") private var storedSortField = FileBrowserSortField.name.rawValue
    @AppStorage("fileBrowserSortDirection") private var storedSortDirection = FileBrowserSortDirection.ascending.rawValue
    @AppStorage("fileBrowserNamePriority") private var storedNamePriority = FileBrowserNamePriority.numbersFirst.rawValue
    @AppStorage("fileBrowserFoldersFirst") private var foldersFirst = true
    @StateObject private var viewModel: FileBrowserViewModel
    @StateObject private var shareCoordinator = RemoteFileShareCoordinator()
    @StateObject private var operationCoordinator: FileOperationCoordinator
    @State private var previewItem: RemoteFileItem?
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<RemoteFileItem.ID> = []
    @State private var pendingDeleteItems: [RemoteFileItem] = []
    @State private var renameItem: RemoteFileItem?
    @State private var renameText = ""
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isImportingFiles = false
    @State private var isShowingMorePanel = false
    @State private var searchText = ""

    @MainActor
    init(
        connection: RemoteConnection,
        path: String,
        service: any RemoteFileService,
        title: String,
        operationCoordinator: FileOperationCoordinator = FileOperationCoordinator()
    ) {
        _viewModel = StateObject(
            wrappedValue: FileBrowserViewModel(connection: connection, path: path, service: service)
        )
        _operationCoordinator = StateObject(wrappedValue: operationCoordinator)
        self.title = title
    }

    private let title: String

    var body: some View {
        VStack(spacing: 0) {
            currentPathBar
            Divider()

            Group {
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
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SkyBreezeTheme.contentBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "현재 폴더 검색"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button("완료") {
                        endSelection()
                    }
                    .disabled(shareCoordinator.isPreparing)
                } else {
                    Button {
                        isShowingMorePanel = true
                    } label: {
                        Label("더 보기", systemImage: "ellipsis.circle")
                    }
                    .disabled(operationCoordinator.isBusy)
                    .accessibilityHint("파일 작업, 새로 고침과 보기 설정 메뉴를 엽니다.")
                    .popover(
                        isPresented: $isShowingMorePanel,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        browserMorePanel
                    }
                }
            }
        }
        .refreshable {
            guard !operationCoordinator.isBusy else { return }
            await viewModel.load()
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
        .task { await viewModel.load() }
        .overlay(alignment: .bottom) {
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
            }
        } message: {
            Text(
                shareCoordinator.errorMessage
                    ?? operationCoordinator.errorMessage
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
        .alert("이름 변경", isPresented: renameAlertBinding) {
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
        }
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

    private var layoutStyle: LayoutStyle {
        LayoutStyle(rawValue: storedLayoutStyle) ?? .smallThumbnails
    }

    private var sortOptions: FileBrowserSortOptions {
        FileBrowserSortOptions(
            field: FileBrowserSortField(rawValue: storedSortField) ?? .name,
            direction: FileBrowserSortDirection(rawValue: storedSortDirection) ?? .ascending,
            namePriority: FileBrowserNamePriority(rawValue: storedNamePriority) ?? .numbersFirst,
            foldersFirst: foldersFirst
        )
    }

    private var sortMenuTitle: String {
        "\(sortOptions.field.title) · \(sortOptions.direction.title)"
    }

    private var browserMorePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MorePanelSectionTitle("파일 작업")

                Button {
                    performMorePanelAction { isSelecting = true }
                } label: {
                    MorePanelRow(title: "선택", systemImage: "checkmark.circle")
                }

                if viewModel.service.capabilities.contains(.upload) {
                    Button {
                        performMorePanelAction {
                            guard canBeginUserPresentation else { return }
                            isImportingFiles = true
                        }
                    } label: {
                        MorePanelRow(title: "이 폴더에 업로드", systemImage: "arrow.up.doc")
                    }
                    .disabled(!canBeginUserPresentation)
                }

                if viewModel.service.capabilities.contains(.createFolder) {
                    Button {
                        performMorePanelAction {
                            guard canBeginUserPresentation else { return }
                            newFolderName = ""
                            isCreatingFolder = true
                        }
                    } label: {
                        MorePanelRow(title: "새 폴더", systemImage: "folder.badge.plus")
                    }
                    .disabled(!canBeginUserPresentation)
                }

                if let clipboard = operationCoordinator.clipboard {
                    Button {
                        performMorePanelAction {
                            operationCoordinator.paste(
                                into: viewModel.path,
                                using: viewModel.service
                            ) {
                                await viewModel.reloadAfterCurrentLoad()
                            }
                        }
                    } label: {
                        MorePanelRow(title: "붙여넣기", systemImage: "doc.on.clipboard")
                    }
                    .disabled(
                        clipboard.connectionID != viewModel.connection.id
                            || !viewModel.service.capabilities.supports(
                                clipboard.mode == .copy ? .copy : .move
                            )
                    )

                    Button {
                        performMorePanelAction {
                            operationCoordinator.clearClipboard()
                        }
                    } label: {
                        MorePanelRow(title: "클립보드 비우기", systemImage: "xmark.bin")
                    }
                }

                Divider().padding(.vertical, 6)

                Button {
                    performMorePanelAction {
                        Task { await viewModel.load() }
                    }
                } label: {
                    MorePanelRow(title: "새로 고침", systemImage: "arrow.clockwise")
                }

                Divider().padding(.vertical, 6)
                MorePanelSectionTitle("보기 설정")

                Menu {
                    ForEach(LayoutStyle.allCases) { style in
                        Button {
                            storedLayoutStyle = style.rawValue
                            isShowingMorePanel = false
                        } label: {
                            Label(
                                style.title,
                                systemImage: layoutStyle == style
                                    ? "checkmark"
                                    : style.systemImage
                            )
                        }
                    }
                } label: {
                    MorePanelRow(
                        title: layoutStyle.title,
                        systemImage: layoutStyle.systemImage,
                        showsDisclosure: true
                    )
                }

                Menu {
                    Section("기준") {
                        ForEach(FileBrowserSortField.allCases) { field in
                            Button {
                                storedSortField = field.rawValue
                            } label: {
                                Label(
                                    field.title,
                                    systemImage: sortOptions.field == field
                                        ? "checkmark"
                                        : sortSystemImage(for: field)
                                )
                            }
                        }
                    }

                    Section("순서") {
                        ForEach(FileBrowserSortDirection.allCases) { direction in
                            Button {
                                storedSortDirection = direction.rawValue
                            } label: {
                                Label(
                                    direction.title,
                                    systemImage: sortOptions.direction == direction
                                        ? "checkmark"
                                        : direction == .ascending ? "arrow.up" : "arrow.down"
                                )
                            }
                        }
                    }

                    if sortOptions.field == .name {
                        Section("이름 우선") {
                            ForEach(FileBrowserNamePriority.allCases) { priority in
                                Button {
                                    storedNamePriority = priority.rawValue
                                } label: {
                                    if sortOptions.namePriority == priority {
                                        Label(priority.title, systemImage: "checkmark")
                                    } else {
                                        Text(priority.title)
                                    }
                                }
                            }
                        }
                    }

                    Toggle("폴더 먼저", isOn: $foldersFirst)
                } label: {
                    MorePanelRow(
                        title: sortMenuTitle,
                        systemImage: "arrow.up.arrow.down",
                        showsDisclosure: true
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.visible)
        .frame(width: 340, height: 380)
        .presentationCompactAdaptation(.popover)
        .buttonStyle(.plain)
        .accessibilityLabel("파일 작업과 보기 설정")
    }

    private func performMorePanelAction(
        _ action: @escaping @MainActor () -> Void
    ) {
        isShowingMorePanel = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            action()
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
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.tint)

            Text(viewModel.connection.name)
                .fontWeight(.semibold)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(viewModel.path)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)

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
        }

        return [
            GridItem(
                .adaptive(minimum: minimum, maximum: maximum),
                spacing: spacing,
                alignment: .top
            )
        ]
    }

    private func sortSystemImage(for field: FileBrowserSortField) -> String {
        switch field {
        case .name: "textformat"
        case .modifiedDate: "calendar"
        case .size: "internaldrive"
        case .kind: "doc.on.doc"
        }
    }

    private var list: some View {
        List(displayedItems) { item in
            listItem(item)
        }
        .listStyle(.plain)
    }

    private func gridItem(_ item: RemoteFileItem, style: LayoutStyle) -> some View {
        ZStack(alignment: .topTrailing) {
            destination(for: item) {
                RemoteFileGridCell(
                    item: item,
                    service: viewModel.service,
                    isLarge: style == .largeThumbnails
                )
            }
            .contextMenu {
                if !isSelecting {
                    itemContextMenu(for: item)
                }
            }

            if isSelecting {
                selectionIndicator(isSelected: selectedItemIDs.contains(item.id))
                    .padding(style == .largeThumbnails ? 8 : 4)
            }
        }
    }

    private func listItem(_ item: RemoteFileItem) -> some View {
        HStack(spacing: 8) {
            destination(for: item) {
                RemoteFileListRow(item: item, service: viewModel.service)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                if !isSelecting {
                    itemContextMenu(for: item)
                }
            }

            if isSelecting {
                selectionIndicator(isSelected: selectedItemIDs.contains(item.id))
            }
        }
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2.weight(.semibold))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .background(.regularMaterial, in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func itemContextMenu(for item: RemoteFileItem) -> some View {
        Section("파일 작업") {
            Button {
                beginQuickSelection(with: item)
            } label: {
                Label("선택", systemImage: "checkmark.circle")
            }
            .disabled(
                selectionInteractionsAreBlocked
                    || hasBlockingPresentation
                    || hasPendingError
            )

            if viewModel.service.capabilities.supports(.copy) {
                Button {
                    operationCoordinator.placeOnClipboard([item], mode: .copy)
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .disabled(selectionInteractionsAreBlocked)
            }

            if hasAdditionalItemActions(for: item) {
                Menu {
                    additionalItemActions(for: item)
                } label: {
                    Label("추가 작업", systemImage: "ellipsis")
                }
            }
        }

        Section("정보") {
            Label(item.name, systemImage: item.systemImage)

            Label(
                item.browserKindAndSizeLabel,
                systemImage: item.isDirectory ? "folder" : "internaldrive"
            )

            if let modifiedAt = item.modifiedAt {
                Label {
                    Text(
                        modifiedAt,
                        format: .dateTime.year().month().day().hour().minute()
                    )
                } icon: {
                    Image(systemName: "calendar")
                }
            } else {
                Label("수정 시간 알 수 없음", systemImage: "calendar")
            }
        }
    }

    private func hasAdditionalItemActions(for item: RemoteFileItem) -> Bool {
        viewModel.service.capabilities.supports(.move)
            || viewModel.service.capabilities.contains(.rename)
            || !item.isDirectory
            || viewModel.service.capabilities.contains(.delete)
    }

    @ViewBuilder
    private func additionalItemActions(for item: RemoteFileItem) -> some View {
        if viewModel.service.capabilities.supports(.move) {
            Button {
                operationCoordinator.placeOnClipboard([item], mode: .move)
            } label: {
                Label("이동", systemImage: "folder")
            }
            .disabled(selectionInteractionsAreBlocked)
        }

        if viewModel.service.capabilities.contains(.rename) {
            Button {
                guard canBeginUserPresentation else { return }
                renameText = item.name
                renameItem = item
            } label: {
                Label("이름 변경", systemImage: "pencil")
            }
            .disabled(!canBeginUserPresentation)
        }

        if !item.isDirectory {
            Button {
                guard canBeginUserPresentation else { return }
                shareCoordinator.prepare(items: [item], using: viewModel.service)
            } label: {
                Label("공유", systemImage: "square.and.arrow.up")
            }
            .disabled(!canBeginUserPresentation)
        }

        if viewModel.service.capabilities.contains(.delete) {
            Divider()
            Button(role: .destructive) {
                guard canBeginUserPresentation else { return }
                pendingDeleteItems = [item]
            } label: {
                Label("삭제", systemImage: "trash")
            }
            .disabled(!canBeginUserPresentation)
        }
    }

    @ViewBuilder
    private func destination<Label: View>(
        for item: RemoteFileItem,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if isSelecting {
            Button {
                toggleSelection(for: item)
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .disabled(shareCoordinator.isPreparing)
            .accessibilityLabel(
                "\(item.name), \(selectedItemIDs.contains(item.id) ? "선택됨" : "선택하지 않음")"
            )
        } else if item.isDirectory {
            NavigationLink {
                FileBrowserView(
                    connection: viewModel.connection,
                    path: item.path,
                    service: viewModel.service,
                    title: item.name,
                    operationCoordinator: operationCoordinator
                )
            } label: {
                label()
            }
        } else {
            Button {
                guard canBeginUserPresentation else { return }
                previewItem = item
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .disabled(!canBeginUserPresentation)
        }
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
        let mediaItems = displayedItems.filter { $0.isImage || $0.isVideo }
        return mediaItems.contains(item) ? mediaItems : [item]
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
                }
            }
        )
    }

    private var errorTitle: String {
        if shareCoordinator.errorMessage != nil {
            return "파일을 공유할 수 없습니다"
        }
        if operationCoordinator.errorMessage != nil {
            return "파일 작업을 완료하지 못했습니다"
        }
        return "오류"
    }

    /// All user-driven modal entry points use this gate. In particular, a
    /// Share preparation remains in selection mode until its sheet is ready,
    /// so its asynchronous completion cannot race a preview or edit confirmation.
    private var canBeginUserPresentation: Bool {
        !shareCoordinator.isPreparing
            && !operationCoordinator.isBusy
            && !hasBlockingPresentation
            && !hasPendingError
    }

    private var selectionInteractionsAreBlocked: Bool {
        shareCoordinator.isPreparing || operationCoordinator.isBusy
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
            || (viewModel.errorMessage != nil && !viewModel.items.isEmpty)
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

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 9 : 6) {
            RemoteThumbnailView(item: item, service: service, size: thumbnailRequestSize)
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

    var body: some View {
        HStack(spacing: 12) {
            RemoteThumbnailView(
                item: item,
                service: service,
                size: CGSize(width: thumbnailSide, height: thumbnailSide)
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
