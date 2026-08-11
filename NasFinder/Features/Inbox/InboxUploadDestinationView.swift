import SwiftUI

/// Lets an inbox upload choose one saved connection and then walk only that
/// connection's folders before committing the upload into the visible path.
struct InboxUploadDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionStore: ConnectionStore

    @StateObject private var operationCoordinator = FileOperationCoordinator()

    let sources: [LocalUploadSource]
    let onUploadCompleted: (() -> Void)?

    init(
        sources: [LocalUploadSource],
        onUploadCompleted: (() -> Void)? = nil
    ) {
        self.sources = sources
        self.onUploadCompleted = onUploadCompleted
    }

    var body: some View {
        NavigationStack {
            Group {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView {
                        Label("연결된 NAS가 없습니다", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("먼저 NasFinder에 Synology NAS 또는 SFTP 서버를 추가해 주세요.")
                    }
                } else {
                    List(connectionStore.connections) { connection in
                        NavigationLink {
                            InboxUploadConnectionView(
                                connection: connection,
                                sources: sources,
                                operationCoordinator: operationCoordinator,
                                onUploadCompleted: completeUpload
                            )
                        } label: {
                            connectionRow(connection)
                        }
                        .disabled(operationCoordinator.isWorking)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("NAS로 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                    .disabled(operationCoordinator.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(operationCoordinator.isWorking)
    }

    private func completeUpload() {
        onUploadCompleted?()
        dismiss()
    }

    private func connectionRow(_ connection: RemoteConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connection.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name)
                    .font(.headline)
                Text(connection.endpointDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(connection.normalizedRootPath, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connection.name), \(connection.kind.title)")
        .accessibilityValue("시작 폴더 \(connection.normalizedRootPath)")
        .accessibilityHint("업로드할 폴더를 선택합니다.")
    }
}

private struct InboxUploadConnectionView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var service: (any RemoteFileService)? = nil
    @State private var didResolveService = false

    let connection: RemoteConnection
    let sources: [LocalUploadSource]
    @ObservedObject var operationCoordinator: FileOperationCoordinator
    let onUploadCompleted: () -> Void

    var body: some View {
        Group {
            if !didResolveService {
                ProgressView("연결을 준비하는 중…")
            } else if let service {
                InboxUploadFolderView(
                    connection: connection,
                    path: connection.normalizedRootPath,
                    service: service,
                    sources: sources,
                    operationCoordinator: operationCoordinator,
                    onUploadCompleted: onUploadCompleted
                )
            } else {
                ContentUnavailableView {
                    Label("로그인 정보 없음", systemImage: "key.slash")
                } description: {
                    Text("연결을 수정해 비밀번호를 다시 저장한 뒤 시도해 주세요.")
                }
                .navigationTitle(connection.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            resolveServiceIfNeeded()
        }
    }

    @MainActor
    private func resolveServiceIfNeeded() {
        guard !didResolveService else { return }
        defer { didResolveService = true }
        guard let credential = try? connectionStore.credential(for: connection) else {
            return
        }
        let resolvedService = RemoteFileServiceFactory.make(
            connection: connection,
            credential: credential
        )
        guard resolvedService.capabilities.contains(.upload) else { return }
        service = resolvedService
    }
}

private struct InboxUploadFolderView: View {
    @StateObject private var viewModel: FileBrowserViewModel

    private let connection: RemoteConnection
    private let service: any RemoteFileService
    private let sources: [LocalUploadSource]
    @ObservedObject private var operationCoordinator: FileOperationCoordinator
    private let onUploadCompleted: () -> Void

    @MainActor
    init(
        connection: RemoteConnection,
        path: String,
        service: any RemoteFileService,
        sources: [LocalUploadSource],
        operationCoordinator: FileOperationCoordinator,
        onUploadCompleted: @escaping () -> Void
    ) {
        self.connection = connection
        self.service = service
        self.sources = sources
        self.onUploadCompleted = onUploadCompleted
        _operationCoordinator = ObservedObject(wrappedValue: operationCoordinator)
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
            } else if let errorMessage = viewModel.errorMessage,
                      viewModel.items.isEmpty {
                ContentUnavailableView {
                    Label("폴더를 열 수 없습니다", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("다시 시도") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(operationCoordinator.isBusy)
                }
            } else if folders.isEmpty {
                ContentUnavailableView {
                    Label("하위 폴더가 없습니다", systemImage: "folder")
                } description: {
                    Text("아래 버튼을 눌러 현재 폴더에 파일을 업로드할 수 있습니다.")
                }
            } else {
                List(folders) { folder in
                    NavigationLink {
                        InboxUploadFolderView(
                            connection: connection,
                            path: folder.path,
                            service: service,
                            sources: sources,
                            operationCoordinator: operationCoordinator,
                            onUploadCompleted: onUploadCompleted
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .foregroundStyle(.primary)
                                if let modifiedAt = folder.modifiedAt {
                                    Text(modifiedAt, format: .dateTime.year().month().day())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(SkyBreezeTheme.folderBlue)
                        }
                    }
                    .disabled(operationCoordinator.isBusy)
                }
                .listStyle(.plain)
                .refreshable {
                    guard !operationCoordinator.isBusy else { return }
                    await viewModel.load()
                }
            }
        }
        .navigationTitle(currentFolderName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(operationCoordinator.isWorking)
        .safeAreaInset(edge: .bottom) {
            operationBar
        }
        .task {
            await viewModel.load()
        }
        .alert("파일을 업로드할 수 없습니다", isPresented: operationErrorBinding) {
            Button("확인", role: .cancel) {
                operationCoordinator.dismissError()
            }
        } message: {
            Text(operationCoordinator.errorMessage ?? "")
        }
    }

    private var folders: [RemoteFileItem] {
        viewModel.displayedItems.filter(\.isDirectory)
    }

    private var currentFolderName: String {
        let name = (viewModel.path as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == "/" {
            return connection.name
        }
        return name
    }

    private var operationBar: some View {
        VStack(spacing: 10) {
            if operationCoordinator.isWorking {
                FileOperationProgressBanner(
                    title: operationCoordinator.operationTitle ?? "파일 업로드 중…",
                    progress: operationCoordinator.progress,
                    onCancel: operationCoordinator.cancel
                )
            } else if let statusMessage = operationCoordinator.statusMessage {
                FileOperationStatusBanner(
                    message: statusMessage,
                    onDismiss: operationCoordinator.dismissStatus
                )
            }

            Button {
                uploadIntoCurrentFolder()
            } label: {
                Label(uploadButtonTitle, systemImage: "arrow.up.doc.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sources.isEmpty || operationCoordinator.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var uploadButtonTitle: String {
        sources.count == 1
            ? "이 폴더에 업로드"
            : "\(sources.count)개 파일을 이 폴더에 업로드"
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationCoordinator.errorMessage != nil },
            set: { if !$0 { operationCoordinator.dismissError() } }
        )
    }

    private func uploadIntoCurrentFolder() {
        operationCoordinator.upload(
            sources,
            into: viewModel.path,
            using: service,
            conflictPolicy: .keepBoth
        ) {
            await viewModel.reloadAfterCurrentLoad()
            onUploadCompleted()
        }
    }
}
