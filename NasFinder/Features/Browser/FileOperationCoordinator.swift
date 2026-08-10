import Foundation

enum FileClipboardMode: String, Sendable {
    case copy
    case move

    var title: String {
        switch self {
        case .copy: "복사"
        case .move: "이동"
        }
    }
}

struct FileClipboardPayload: Sendable {
    let connectionID: UUID
    var items: [RemoteFileItem]
    let mode: FileClipboardMode
}

@MainActor
final class FileOperationCoordinator: ObservableObject {
    @Published private(set) var clipboard: FileClipboardPayload?
    @Published private(set) var progress: RemoteOperationProgress?
    @Published private(set) var operationTitle: String?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private var activeTask: Task<Void, Never>?

    func placeOnClipboard(_ items: [RemoteFileItem], mode: FileClipboardMode) {
        guard let connectionID = items.first?.connectionID else { return }
        let sameConnectionItems = items.filter { $0.connectionID == connectionID }
        guard !sameConnectionItems.isEmpty else { return }
        clipboard = FileClipboardPayload(
            connectionID: connectionID,
            items: sameConnectionItems,
            mode: mode
        )
        statusMessage = "\(sameConnectionItems.count)개 항목 \(mode.title) 준비"
        errorMessage = nil
    }

    func clearClipboard() {
        clipboard = nil
    }

    func paste(
        into directoryPath: String,
        using service: any RemoteFileService,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        guard let clipboard, !clipboard.items.isEmpty, !isWorking else { return }
        guard clipboard.connectionID == service.connection.id else {
            errorMessage = "다른 서버 간 복사·이동은 안전한 검증 전송 단계에서 지원할 예정입니다."
            return
        }

        start(title: "\(clipboard.items.count)개 항목 \(clipboard.mode.title) 중…") { [weak self] in
            guard let self else { return }
            var succeededIDs: Set<RemoteFileItem.ID> = []
            var failureMessages: [String] = []
            var wasCancelled = false

            for item in clipboard.items {
                do {
                    try Task.checkCancellation()
                    let context = self.operationContext()
                    let result: RemoteOperationResult
                    switch clipboard.mode {
                    case .copy:
                        result = try await service.copy(
                            item,
                            to: directoryPath,
                            conflictPolicy: .keepBoth,
                            strategy: .automatic,
                            context: context
                        )
                    case .move:
                        result = try await service.move(
                            item,
                            to: directoryPath,
                            conflictPolicy: .keepBoth,
                            strategy: .automatic,
                            context: context
                        )
                    }

                    if !result.succeeded.isEmpty {
                        succeededIDs.insert(item.id)
                    }
                    failureMessages.append(contentsOf: result.failures.compactMap(\.issue?.message))
                } catch is CancellationError {
                    wasCancelled = true
                    break
                } catch {
                    failureMessages.append("\(item.name): \(error.localizedDescription)")
                }
            }

            if clipboard.mode == .move {
                let remaining = clipboard.items.filter { !succeededIDs.contains($0.id) }
                self.clipboard = remaining.isEmpty
                    ? nil
                    : FileClipboardPayload(
                        connectionID: clipboard.connectionID,
                        items: remaining,
                        mode: .move
                    )
            }

            if wasCancelled || Task.isCancelled {
                self.statusMessage = "\(succeededIDs.count)개 완료 후 작업을 취소했습니다."
                Task { await onCompletion() }
                return
            }
            await onCompletion()
            self.presentSummary(
                succeededCount: succeededIDs.count,
                totalCount: clipboard.items.count,
                operationName: clipboard.mode.title,
                failureMessages: failureMessages
            )
        }
    }

    func delete(
        _ items: [RemoteFileItem],
        using service: any RemoteFileService,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        guard !items.isEmpty, !isWorking else { return }
        start(title: "\(items.count)개 항목 삭제 중…") { [weak self] in
            guard let self else { return }
            var succeededCount = 0
            var failureMessages: [String] = []
            var wasCancelled = false

            for item in items {
                do {
                    try Task.checkCancellation()
                    let result = try await service.delete(
                        item,
                        recursive: item.isDirectory,
                        context: self.operationContext()
                    )
                    if !result.succeeded.isEmpty { succeededCount += 1 }
                    failureMessages.append(contentsOf: result.failures.compactMap(\.issue?.message))
                } catch is CancellationError {
                    wasCancelled = true
                    break
                } catch {
                    failureMessages.append("\(item.name): \(error.localizedDescription)")
                }
            }

            if wasCancelled || Task.isCancelled {
                self.statusMessage = "\(succeededCount)개 완료 후 삭제를 취소했습니다."
                Task { await onCompletion() }
                return
            }
            await onCompletion()
            self.presentSummary(
                succeededCount: succeededCount,
                totalCount: items.count,
                operationName: "삭제",
                failureMessages: failureMessages
            )
        }
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        using service: any RemoteFileService,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        guard !isWorking else { return }
        start(title: "폴더 만드는 중…") { [weak self] in
            guard let self else { return }
            do {
                _ = try await service.createFolder(
                    named: name,
                    in: directoryPath,
                    context: self.operationContext()
                )
                await onCompletion()
                self.statusMessage = "폴더를 만들었습니다."
            } catch is CancellationError {
                self.statusMessage = "폴더 만들기를 취소했습니다."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        using service: any RemoteFileService,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        guard !isWorking else { return }
        start(title: "이름 변경 중…") { [weak self] in
            guard let self else { return }
            do {
                _ = try await service.rename(
                    item,
                    to: newName,
                    context: self.operationContext()
                )
                await onCompletion()
                self.statusMessage = "이름을 변경했습니다."
            } catch is CancellationError {
                self.statusMessage = "이름 변경을 취소했습니다."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func dismissStatus() {
        statusMessage = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    private func start(
        title: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard activeTask == nil else { return }
        isWorking = true
        operationTitle = title
        progress = nil
        errorMessage = nil
        statusMessage = nil

        activeTask = Task { [weak self] in
            await operation()
            guard let self else { return }
            self.activeTask = nil
            self.isWorking = false
            self.operationTitle = nil
            self.progress = nil
        }
    }

    private func operationContext() -> RemoteOperationContext {
        RemoteOperationContext { [weak self] progress in
            await MainActor.run {
                self?.progress = progress
            }
        }
    }

    private func presentSummary(
        succeededCount: Int,
        totalCount: Int,
        operationName: String,
        failureMessages: [String]
    ) {
        if failureMessages.isEmpty {
            statusMessage = "\(succeededCount)개 항목 \(operationName) 완료"
        } else {
            let failureCount = max(totalCount - succeededCount, failureMessages.count)
            errorMessage = "\(succeededCount)개 성공, \(failureCount)개 실패\n"
                + failureMessages.prefix(3).joined(separator: "\n")
        }
    }
}
