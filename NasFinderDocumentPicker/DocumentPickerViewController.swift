import SwiftUI
import UIKit
import UniformTypeIdentifiers

@available(iOS, deprecated: 14.0, message: "Compatibility UI for document import hosts")
final class NasFinderDocumentPickerViewController: UIDocumentPickerExtensionViewController {
    private var hostingController: UIHostingController<DocumentPickerRootView>?
    private var model: DocumentPickerModel?

    override var providerIdentifier: String {
        "com.armsone.nasfinder.fileprovider"
    }

    override var documentStorageURL: URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NasFinderFileProviderIdentifiers.appGroup
        ) else {
            return nil
        }
        let storageURL = containerURL.appendingPathComponent(
            "File Provider Storage",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )
        return storageURL
    }

    override func prepareForPresentation(in mode: UIDocumentPickerMode) {
        super.prepareForPresentation(in: mode)

        let model = DocumentPickerModel(
            pickerMode: mode,
            documentStorageURL: documentStorageURL
        ) { [weak self] url in
            self?.dismissGrantingAccess(to: url)
        }
        self.model = model

        let hostingController = UIHostingController(
            rootView: DocumentPickerRootView(model: model)
        )
        hostingController.view.backgroundColor = .systemGroupedBackground
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController

        Task { await model.loadConnections() }
    }
}

@MainActor
final class DocumentPickerModel: ObservableObject {
    struct ConnectionContext: Identifiable {
        let connection: ProviderConnection
        let backend: any ProviderRemoteBackend

        var id: UUID { connection.id }
    }

    struct DirectoryLevel: Identifiable {
        let id = UUID()
        let name: String
        let path: String
    }

    @Published private(set) var connections: [ConnectionContext] = []
    @Published private(set) var selectedConnection: ConnectionContext?
    @Published private(set) var directoryStack: [DirectoryLevel] = []
    @Published private(set) var items: [ProviderRemoteNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var downloadingItem: ProviderRemoteNode?
    @Published private(set) var errorMessage: String?

    private let finish: (URL) -> Void
    private let pickerMode: UIDocumentPickerMode
    private let documentStorageURL: URL?
    private var operationTask: Task<Void, Never>?

    init(
        pickerMode: UIDocumentPickerMode,
        documentStorageURL: URL?,
        finish: @escaping (URL) -> Void
    ) {
        self.pickerMode = pickerMode
        self.documentStorageURL = documentStorageURL
        self.finish = finish
    }

    var title: String {
        directoryStack.last?.name ?? selectedConnection?.connection.name ?? "NasFinder"
    }

    var canNavigateBack: Bool {
        selectedConnection != nil
    }

    func loadConnections() async {
        operationTask?.cancel()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try Self.loadConnectionContexts()
            connections = loaded
            if loaded.count == 1, let only = loaded.first {
                await selectConnection(only)
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func selectConnection(_ context: ConnectionContext) async {
        selectedConnection = context
        directoryStack = [
            DirectoryLevel(
                name: context.connection.name,
                path: context.connection.normalizedRootPath
            )
        ]
        await loadCurrentDirectory()
    }

    func select(_ item: ProviderRemoteNode) async {
        if item.isDirectory {
            directoryStack.append(DirectoryLevel(name: item.name, path: item.path))
            await loadCurrentDirectory()
        } else {
            await download(item)
        }
    }

    func navigateBack() async {
        guard selectedConnection != nil else { return }
        if directoryStack.count > 1 {
            directoryStack.removeLast()
            await loadCurrentDirectory()
        } else {
            operationTask?.cancel()
            selectedConnection = nil
            directoryStack = []
            items = []
            errorMessage = nil
        }
    }

    func retry() async {
        if selectedConnection == nil {
            await loadConnections()
        } else {
            await loadCurrentDirectory()
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func thumbnailData(
        for item: ProviderRemoteNode,
        size: ProviderThumbnailSize
    ) async -> Data? {
        guard !item.isDirectory,
              Self.supportsThumbnail(filename: item.name),
              let context = selectedConnection else { return nil }
        let key = ProviderThumbnailCache.key(
            for: item,
            connectionID: context.connection.id,
            size: size
        )
        let cache = ProviderThumbnailCache()
        if let cached = cache.data(forKey: key) { return cached }

        do {
            let data = try await DocumentPickerThumbnailRequestLimiter.shared.withPermit {
                try Task.checkCancellation()
                return try await context.backend.thumbnail(path: item.path, size: size)
            }
            guard let data else { return nil }
            try Task.checkCancellation()
            cache.store(data, forKey: key)
            return data
        } catch {
            return nil
        }
    }

    func cancelDownload() {
        operationTask?.cancel()
        operationTask = nil
        downloadingItem = nil
    }

    private func loadCurrentDirectory() async {
        guard let backend = selectedConnection?.backend,
              let directory = directoryStack.last?.path else { return }
        operationTask?.cancel()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            items = try await backend.list(directory: directory)
                .filter { !$0.name.hasPrefix(".") }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func download(_ item: ProviderRemoteNode) async {
        guard let backend = selectedConnection?.backend else { return }
        operationTask?.cancel()
        downloadingItem = item
        errorMessage = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let destination = try downloadDestination(filename: item.name)
                try await backend.download(path: item.path, to: destination)
                try Task.checkCancellation()
                downloadingItem = nil
                finish(destination)
            } catch is CancellationError {
                downloadingItem = nil
            } catch {
                downloadingItem = nil
                errorMessage = Self.message(for: error)
            }
        }
        operationTask = task
        await task.value
    }

    private static func loadConnectionContexts() throws -> [ConnectionContext] {
        guard let defaults = UserDefaults(
            suiteName: NasFinderFileProviderIdentifiers.appGroup
        ), let data = defaults.data(
            forKey: NasFinderFileProviderIdentifiers.connectionStorageKey
        ) else {
            return []
        }

        let stored = try JSONDecoder().decode([ProviderConnection].self, from: data)
        return try stored.compactMap { connection in
            let backend: any ProviderRemoteBackend
            switch connection.kind {
            case .synology:
                backend = SynologyProviderBackend(
                    connection: connection,
                    password: try SharedKeychainCredentialReader().password(for: connection.id)
                )
            case .sftp:
                backend = SFTPProviderBackend(
                    connection: connection,
                    password: try SharedKeychainCredentialReader().password(for: connection.id)
                )
            case .smb, .webDAV, .ftp, .dropbox, .oneDrive, .googleDrive:
                return nil
            }
            return ConnectionContext(connection: connection, backend: backend)
        }
    }

    private func downloadDestination(filename: String) throws -> URL {
        let root: URL
        if pickerMode == .open {
            guard let documentStorageURL else {
                throw CocoaError(.fileNoSuchFile)
            }
            root = documentStorageURL
        } else {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NasFinderFileProviderIdentifiers.appGroup
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            root = container.appendingPathComponent("DocumentPickerImports", isDirectory: true)
        }
        let directory = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let safeName = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
    }

    private static func message(for error: Error) -> String {
        let description = (error as NSError).localizedDescription
        if description.isEmpty { return "파일을 불러오지 못했습니다." }
        return description
    }

    private static func supportsThumbnail(filename: String) -> Bool {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        return type?.conforms(to: .image) == true
            || type?.conforms(to: .movie) == true
            || type?.conforms(to: .video) == true
    }
}

private enum DocumentPickerLayoutStyle: String, CaseIterable, Identifiable {
    case list
    case smallThumbnails
    case largeThumbnails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "자세히"
        case .smallThumbnails: "작은 썸네일"
        case .largeThumbnails: "포스터"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .smallThumbnails: "square.grid.3x3"
        case .largeThumbnails: "square.grid.2x2"
        }
    }
}

private struct DocumentPickerRootView: View {
    @ObservedObject var model: DocumentPickerModel
    @AppStorage(
        "documentPickerLayoutStyle",
        store: UserDefaults(suiteName: NasFinderFileProviderIdentifiers.appGroup)
    ) private var storedLayoutStyle = DocumentPickerLayoutStyle.smallThumbnails.rawValue

    var body: some View {
        NavigationStack {
            Group {
                if model.selectedConnection == nil {
                    connectionList
                } else {
                    fileList
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.canNavigateBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await model.navigateBack() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.headline)
                        }
                        .accessibilityLabel("이전")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(DocumentPickerLayoutStyle.allCases) { style in
                                Button {
                                    storedLayoutStyle = style.rawValue
                                } label: {
                                    Label(style.title, systemImage: style.systemImage)
                                }
                            }
                        } label: {
                            Image(systemName: layoutStyle.systemImage)
                        }
                        .accessibilityLabel("보기 방식")
                    }
                }
            }
            .overlay {
                if model.isLoading && model.items.isEmpty {
                    ProgressView("불러오는 중…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(item: Binding(
                get: { model.downloadingItem.map(DownloadPresentation.init) },
                set: { if $0 == nil { model.cancelDownload() } }
            )) { presentation in
                DownloadSheet(
                    item: presentation.item,
                    cancel: model.cancelDownload
                )
                .presentationDetents([.height(210)])
                .interactiveDismissDisabled()
            }
            .alert("파일을 불러오지 못했습니다", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )) {
                Button("다시 시도") { Task { await model.retry() } }
                Button("확인", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var connectionList: some View {
        List {
            if model.connections.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "연결이 없습니다",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("NasFinder 앱에서 Synology 또는 SFTP 연결을 먼저 추가하세요.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("연결") {
                    ForEach(model.connections) { context in
                        Button {
                            Task { await model.selectConnection(context) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: context.connection.kind == .synology
                                      ? "externaldrive.connected.to.line.below"
                                      : "network.badge.shield.half.filled")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(context.connection.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(context.connection.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .refreshable { await model.loadConnections() }
    }

    private var fileList: some View {
        Group {
            switch layoutStyle {
            case .list:
                List(model.items, id: \.path) { item in
                    pickerItemButton(item, style: .list)
                }
            case .smallThumbnails, .largeThumbnails:
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: layoutStyle == .largeThumbnails ? 18 : 13) {
                        ForEach(model.items, id: \.path) { item in
                            pickerItemButton(item, style: layoutStyle)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .refreshable { await model.retry() }
    }

    private var layoutStyle: DocumentPickerLayoutStyle {
        DocumentPickerLayoutStyle(rawValue: storedLayoutStyle) ?? .smallThumbnails
    }

    private var gridColumns: [GridItem] {
        let minimum: CGFloat = layoutStyle == .largeThumbnails ? 148 : 88
        return [GridItem(.adaptive(minimum: minimum, maximum: minimum * 1.35), spacing: 12)]
    }

    private func pickerItemButton(
        _ item: ProviderRemoteNode,
        style: DocumentPickerLayoutStyle
    ) -> some View {
        Button {
            Task { await model.select(item) }
        } label: {
            DocumentPickerItemView(item: item, model: model, style: style)
        }
        .buttonStyle(.plain)
    }

}

private struct DocumentPickerItemView: View {
    let item: ProviderRemoteNode
    @ObservedObject var model: DocumentPickerModel
    let style: DocumentPickerLayoutStyle

    var body: some View {
        if style == .list {
            HStack(spacing: 12) {
                preview(side: 56, size: .small, cornerRadius: 9)
                metadata
                Spacer(minLength: 8)
                Image(systemName: item.isDirectory ? "chevron.right" : "arrow.down.circle")
                    .foregroundStyle(item.isDirectory ? Color.secondary : Color.accentColor)
            }
            .contentShape(Rectangle())
        } else {
            VStack(alignment: .leading, spacing: style == .largeThumbnails ? 9 : 6) {
                preview(
                    side: style == .largeThumbnails ? 180 : 104,
                    size: style == .largeThumbnails ? .medium : .small,
                    cornerRadius: style == .largeThumbnails ? 15 : 11
                )
                metadata
            }
            .contentShape(Rectangle())
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(style == .largeThumbnails ? .headline : (style == .list ? .body : .caption))
                .fontWeight(style == .largeThumbnails ? .semibold : .regular)
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let size = item.size, !item.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func preview(
        side: CGFloat,
        size: ProviderThumbnailSize,
        cornerRadius: CGFloat
    ) -> some View {
        DocumentPickerThumbnailView(item: item, model: model, requestedSize: size)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: style == .list ? side : .infinity)
            .frame(width: style == .list ? side : nil, height: style == .list ? side : nil)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct DocumentPickerThumbnailView: View {
    let item: ProviderRemoteNode
    @ObservedObject var model: DocumentPickerModel
    let requestedSize: ProviderThumbnailSize
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholderIcon)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                    .padding(item.isDirectory ? 12 : 22)
            }
        }
        .clipped()
        .task(id: "\(item.path)|\(requestedSize.rawValue)") {
            guard !item.isDirectory else { return }
            if let data = await model.thumbnailData(for: item, size: requestedSize),
               !Task.isCancelled {
                image = UIImage(data: data)
            }
        }
    }

    private var placeholderIcon: String {
        if item.isDirectory { return "folder.fill" }
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return "film"
        }
        if type?.conforms(to: .audio) == true { return "waveform" }
        return "doc"
    }
}

private actor DocumentPickerThumbnailRequestLimiter {
    static let shared = DocumentPickerThumbnailRequestLimiter(maximumConcurrentRequests: 3)

    private let maximumConcurrentRequests: Int
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentRequests: Int) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        if activeRequests < maximumConcurrentRequests {
            activeRequests += 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func release() {
        if waiters.isEmpty {
            activeRequests = max(0, activeRequests - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct DownloadPresentation: Identifiable {
    let item: ProviderRemoteNode
    var id: String { item.path }
}

private struct DownloadSheet: View {
    let item: ProviderRemoteNode
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 5) {
                Text("파일을 가져오는 중")
                    .font(.headline)
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = item.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("취소", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
        }
        .padding(24)
    }
}
