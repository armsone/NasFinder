import SwiftUI
import UIKit

@available(iOS, deprecated: 14.0, message: "Compatibility UI for document import hosts")
final class NasFinderDocumentPickerViewController: UIDocumentPickerExtensionViewController {
    private var hostingController: UIHostingController<DocumentPickerRootView>?
    private var model: DocumentPickerModel?

    override func prepareForPresentation(in mode: UIDocumentPickerMode) {
        super.prepareForPresentation(in: mode)

        let model = DocumentPickerModel { [weak self] url in
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
    private var operationTask: Task<Void, Never>?

    init(finish: @escaping (URL) -> Void) {
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
                let destination = try Self.downloadDestination(filename: item.name)
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

    private static func downloadDestination(filename: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NasFinderFileProviderIdentifiers.appGroup
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = container
            .appendingPathComponent("DocumentPickerImports", isDirectory: true)
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
}

private struct DocumentPickerRootView: View {
    @ObservedObject var model: DocumentPickerModel

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
        List(model.items, id: \.path) { item in
            Button {
                Task { await model.select(item) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: item.isDirectory ? "folder.fill" : icon(for: item.name))
                        .font(.title3)
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        if let size = item.size, !item.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: item.isDirectory ? "chevron.right" : "arrow.down.circle")
                        .foregroundStyle(item.isDirectory ? Color.secondary : Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .refreshable { await model.retry() }
    }

    private func icon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp"].contains(ext) {
            return "photo"
        }
        if ["mp4", "mov", "mkv", "avi", "wmv", "mpg", "mpeg", "m4v"].contains(ext) {
            return "film"
        }
        if ["mp3", "m4a", "wav", "flac", "aac"].contains(ext) {
            return "waveform"
        }
        return "doc"
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
