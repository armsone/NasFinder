import SwiftUI

/// Walks PhoneHard's own folder tree (root, user-created folders, and the physical Music
/// folder) so a move or copy can pick any existing folder as its destination. Nothing is
/// created here; `SharedInboxStore` validates containment and conflicts when it commits.
struct InboxDestinationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inboxStore: SharedInboxStore
    /// `nil` when the picker only reports the chosen folder through `onPickDestination`.
    let operation: InboxFileOperation?
    let excludedPaths: Set<String>
    var title: String?
    /// Receives the chosen folder (`nil` is the PhoneHard root) instead of running a
    /// move or copy; the presenter closes the picker.
    var onPickDestination: ((String?) -> Void)?

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            InboxDestinationFolderView(
                path: nil,
                displayName: "폰하드",
                inboxStore: inboxStore,
                excludedPaths: excludedPaths,
                isWorking: $isWorking,
                onChoose: performOperation
            )
            .navigationTitle(title ?? (operation?.kind == .move ? "이동" : "복사"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Group {
                        Button("취소") { dismiss() }
                            .disabled(isWorking)
                    }
                    .uiBarFont()
                }
            }
            .alert("작업을 완료하지 못했습니다", isPresented: errorBinding) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func performOperation(destinationPath: String?) {
        guard !isWorking else { return }
        if let onPickDestination {
            onPickDestination(destinationPath)
            return
        }
        guard let operation else { return }
        isWorking = true
        Task {
            switch operation.kind {
            case .move:
                await inboxStore.move(operation.records, toFolder: destinationPath)
            case .copy:
                await inboxStore.copy(operation.records, toFolder: destinationPath)
            }
            isWorking = false
            if let failure = inboxStore.errorMessage {
                errorMessage = failure
                inboxStore.errorMessage = nil
            } else {
                dismiss()
            }
        }
    }
}

private struct DestinationFolderOption: Identifiable {
    let id: String
    let name: String
    let path: String
}

private struct InboxDestinationFolderView: View {
    let path: String?
    let displayName: String
    @ObservedObject var inboxStore: SharedInboxStore
    let excludedPaths: Set<String>
    @Binding var isWorking: Bool
    let onChoose: (String?) -> Void

    var body: some View {
        List {
            if folderOptions.isEmpty {
                ContentUnavailableView {
                    Label("하위 폴더가 없습니다", systemImage: "folder")
                } description: {
                    Text("아래 버튼으로 이 폴더를 선택할 수 있습니다.")
                }
            } else {
                ForEach(folderOptions) { option in
                    NavigationLink {
                        InboxDestinationFolderView(
                            path: option.path,
                            displayName: option.name,
                            inboxStore: inboxStore,
                            excludedPaths: excludedPaths,
                            isWorking: $isWorking,
                            onChoose: onChoose
                        )
                    } label: {
                        Label(option.name, systemImage: "folder.fill")
                    }
                    .disabled(isWorking)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: ui(8)) {
                if isWorking {
                    ProgressView()
                }
                Button {
                    onChoose(path)
                } label: {
                    Label("이 폴더를 선택", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
            }
            .padding(.horizontal, ui(16))
            .padding(.vertical, ui(10))
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var folderOptions: [DestinationFolderOption] {
        var options = inboxStore.children(of: path)
            .filter(\.isDirectory)
            .filter { !excludedPaths.contains($0.storedFilename) }
            .map {
                DestinationFolderOption(
                    id: $0.storedFilename,
                    name: $0.originalFilename,
                    path: $0.storedFilename
                )
            }

        if path == nil,
           inboxStore.musicFolderExists,
           !options.contains(where: { $0.path == SharedInbox.musicDirectoryName }),
           !excludedPaths.contains(SharedInbox.musicDirectoryName) {
            options.append(
                DestinationFolderOption(
                    id: SharedInbox.musicDirectoryName,
                    name: "Music",
                    path: SharedInbox.musicDirectoryName
                )
            )
        }

        return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
