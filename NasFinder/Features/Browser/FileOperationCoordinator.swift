import Combine
import CryptoKit
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
    /// Identifies one staging. A paste that finishes after the user staged
    /// something else must not clear or replace that newer clipboard.
    let token: UUID
    let connectionID: UUID
    var items: [RemoteFileItem]
    let mode: FileClipboardMode
    /// The service the items were listed from, kept in memory only so a paste
    /// into another storage reads from the original endpoint and never from
    /// the destination or whichever connection is active later.
    let sourceService: (any RemoteFileService)?

    init(
        token: UUID = UUID(),
        connectionID: UUID,
        items: [RemoteFileItem],
        mode: FileClipboardMode,
        sourceService: (any RemoteFileService)? = nil
    ) {
        self.token = token
        self.connectionID = connectionID
        self.items = items
        self.mode = mode
        self.sourceService = sourceService
    }
}

/// One in-memory clipboard shared by every browser, so items staged in
/// PhoneHard stay staged while the user goes to a NAS folder and back.
/// Nothing here is persisted.
///
/// A privacy mode change empties it at once, like the selections the app
/// shell drops with the screen tree, so nothing staged in one mode is still
/// offered in the other. A paste already running keeps its own snapshot.
@MainActor
final class SharedFileClipboard {
    static let shared = SharedFileClipboard()

    @Published private(set) var payload: FileClipboardPayload?

    private var privacyModeSubscription: AnyCancellable?

    private init() {
        // `epoch` publishes synchronously inside `PrivacyMode.setActive`,
        // on the main actor, before the new screen tree is built.
        privacyModeSubscription = PrivacyMode.shared.$epoch
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.clear() }
    }

    func stage(_ payload: FileClipboardPayload) {
        self.payload = payload
    }

    func clear() {
        payload = nil
    }

    /// Keeps only `remaining` items of the staging `token`; a newer staging
    /// is left untouched.
    func retain(_ remaining: [RemoteFileItem], ofStaging token: UUID) {
        guard let payload, payload.token == token else { return }
        if remaining.isEmpty {
            self.payload = nil
        } else {
            var updated = payload
            updated.items = remaining
            self.payload = updated
        }
    }
}

struct LocalUploadSource: Sendable, Hashable {
    let url: URL
    let preferredName: String

    init(url: URL, preferredName: String? = nil) {
        self.url = url
        if let preferredName, !preferredName.isEmpty {
            self.preferredName = preferredName
        } else {
            self.preferredName = url.lastPathComponent
        }
    }
}

@MainActor
final class FileOperationCoordinator: ObservableObject {
    @Published private(set) var clipboard: FileClipboardPayload?
    @Published private(set) var progress: RemoteOperationProgress?
    @Published private(set) var operationTitle: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private var activeTask: Task<Void, Never>?
    private var activeRefreshID: UUID?
    private var activeRunID: UUID?
    private let screenAwakeActivityID = UUID()

    var isBusy: Bool { isWorking || isRefreshing }

    init() {
        SharedFileClipboard.shared.$payload.assign(to: &$clipboard)
    }

    func placeOnClipboard(
        _ items: [RemoteFileItem],
        mode: FileClipboardMode,
        using service: (any RemoteFileService)? = nil
    ) {
        guard let connectionID = items.first?.connectionID else { return }
        let sameConnectionItems = items.filter { $0.connectionID == connectionID }
        guard !sameConnectionItems.isEmpty else { return }
        // Only a service of the items' own connection may be their source.
        let sourceService = service.flatMap {
            $0.connection.id == connectionID ? $0 : nil
        }
        SharedFileClipboard.shared.stage(
            FileClipboardPayload(
                connectionID: connectionID,
                items: sameConnectionItems,
                mode: mode,
                sourceService: sourceService
            )
        )
        statusMessage = "\(sameConnectionItems.count)개 항목 \(mode.title) 준비"
        errorMessage = nil
    }

    func clearClipboard() {
        SharedFileClipboard.shared.clear()
    }

    /// Whether the staged items can be pasted into a folder of `service`.
    func canPaste(into service: any RemoteFileService) -> Bool {
        guard let clipboard, !clipboard.items.isEmpty else { return false }
        guard !Self.hasHiddenOrigin(clipboard) else { return false }
        if clipboard.connectionID == service.connection.id {
            return service.capabilities.supports(
                clipboard.mode == .copy ? .copy : .move
            )
        }
        return Self.crossStorageBlocker(for: clipboard, into: service) == nil
    }

    func upload(
        _ localURLs: [URL],
        into directoryPath: String,
        using service: any RemoteFileService,
        conflictPolicy: RemoteConflictPolicy = .keepBoth,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        upload(
            localURLs.map { LocalUploadSource(url: $0) },
            into: directoryPath,
            using: service,
            conflictPolicy: conflictPolicy,
            onCompletion: onCompletion
        )
    }

    func upload(
        _ sources: [LocalUploadSource],
        into directoryPath: String,
        using service: any RemoteFileService,
        conflictPolicy: RemoteConflictPolicy = .keepBoth,
        operationName: String = "업로드",
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        guard !sources.isEmpty,
              !isWorking,
              service.capabilities.contains(.upload) else { return }

        start(title: "\(sources.count)개 파일 \(operationName) 중…") { [weak self] in
            guard let self else { return }

            var succeededCount = 0
            var failureMessages: [String] = []
            var wasCancelled = false

            for (index, source) in sources.enumerated() {
                self.operationTitle = sources.count == 1
                    ? "\(source.preferredName) \(operationName) 중…"
                    : "\(index + 1)/\(sources.count) • \(source.preferredName) \(operationName) 중…"

                do {
                    try Task.checkCancellation()

                    // File importers return security-scoped URLs. Hold one
                    // access token only while that file is being uploaded so
                    // large selections do not exhaust the process allowance.
                    let didStartAccess = source.url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccess {
                            source.url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let result = try await service.upload(
                        localURL: source.url,
                        to: directoryPath,
                        preferredName: source.preferredName,
                        conflictPolicy: conflictPolicy,
                        context: self.operationContext()
                    )

                    if !result.succeeded.isEmpty {
                        succeededCount += 1
                    }
                    if result.wasCancelled {
                        failureMessages.append(
                            contentsOf: Self.actionableCancellationIssueMessages(
                                from: result,
                                preferredName: source.preferredName
                            )
                        )
                        wasCancelled = true
                        break
                    }
                    failureMessages.append(
                        contentsOf: Self.issueMessages(
                            from: result,
                            preferredName: source.preferredName
                        )
                    )
                } catch let interruption as RemoteOperationInterruptedError {
                    if !interruption.partialResult.succeeded.isEmpty {
                        succeededCount += 1
                    }
                    if interruption.reason == .cancelled {
                        failureMessages.append(
                            contentsOf: Self.actionableCancellationIssueMessages(
                                from: interruption.partialResult,
                                preferredName: source.preferredName
                            )
                        )
                        wasCancelled = true
                        break
                    }
                    failureMessages.append(
                        contentsOf: Self.issueMessages(
                            from: interruption.partialResult,
                            preferredName: source.preferredName
                        )
                    )
                    if interruption.partialResult.failures.isEmpty {
                        failureMessages.append(
                            "\(source.preferredName): \(interruption.localizedDescription)"
                        )
                    }
                } catch is CancellationError {
                    wasCancelled = true
                    break
                } catch {
                    failureMessages.append(
                        "\(source.preferredName): \(error.localizedDescription)"
                    )
                }
            }

            if wasCancelled || Task.isCancelled {
                self.presentCancellationSummary(
                    succeededCount: succeededCount,
                    operationName: operationName,
                    failureMessages: failureMessages
                )
                // The remote mutation is already stopped. Refresh separately
                // so a disconnected server cannot trap the user in this sheet.
                self.beginRefresh(onCompletion)
                return
            }

            await onCompletion()
            self.presentSummary(
                succeededCount: succeededCount,
                totalCount: sources.count,
                operationName: operationName,
                failureMessages: failureMessages
            )
        }
    }

    func paste(
        into directoryPath: String,
        using service: any RemoteFileService,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        // An immutable snapshot: staging something new while this runs must
        // neither change what is transferred nor be cleared by this paste.
        guard let clipboard, !clipboard.items.isEmpty, !isWorking else { return }
        guard !Self.hasHiddenOrigin(clipboard) else {
            errorMessage = "붙여넣을 수 없는 항목이 있습니다. 원본 폴더에서 다시 복사·이동을 선택해 주세요."
            return
        }
        guard clipboard.connectionID == service.connection.id else {
            pasteAcrossStorage(clipboard, into: directoryPath, using: service, onCompletion: onCompletion)
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

                    // A root only counts as done when nothing in it was
                    // skipped, failed or cancelled; otherwise it stays staged.
                    if !result.succeeded.isEmpty,
                       result.failures.isEmpty,
                       result.skipped.isEmpty,
                       !result.wasCancelled {
                        succeededIDs.insert(item.id)
                    }
                    let issues = (result.failures + result.skipped).compactMap(\.issue?.message)
                    failureMessages.append(contentsOf: issues)
                    if !succeededIDs.contains(item.id), !result.wasCancelled, issues.isEmpty {
                        failureMessages.append("\(item.name): 일부 항목을 완료하지 못했습니다.")
                    }
                    if result.wasCancelled {
                        wasCancelled = true
                        break
                    }
                } catch let interruption as RemoteOperationInterruptedError {
                    failureMessages.append(
                        contentsOf: (interruption.partialResult.failures
                            + interruption.partialResult.skipped).compactMap(\.issue?.message)
                    )
                    if interruption.reason == .cancelled {
                        wasCancelled = true
                        break
                    }
                    failureMessages.append("\(item.name): \(interruption.localizedDescription)")
                } catch is CancellationError {
                    wasCancelled = true
                    break
                } catch {
                    failureMessages.append("\(item.name): \(error.localizedDescription)")
                }
            }

            if clipboard.mode == .move {
                SharedFileClipboard.shared.retain(
                    clipboard.items.filter { !succeededIDs.contains($0.id) },
                    ofStaging: clipboard.token
                )
            }

            if wasCancelled || Task.isCancelled {
                if failureMessages.isEmpty {
                    self.statusMessage = "\(succeededIDs.count)개 완료 후 작업을 취소했습니다."
                } else {
                    self.errorMessage = "\(succeededIDs.count)개 완료 후 작업을 취소했습니다.\n"
                        + failureMessages.prefix(3).joined(separator: "\n")
                }
                self.beginRefresh(onCompletion)
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

    /// Whether a staged root is hidden in the current mode, for example made
    /// private after it was staged. Such a clipboard is never pasted.
    private static func hasHiddenOrigin(_ clipboard: FileClipboardPayload) -> Bool {
        clipboard.items.contains {
            PrivacyMode.hides(connectionID: $0.connectionID, path: $0.path)
        }
    }

    /// Why `clipboard` cannot go into `destination` from another storage, or
    /// `nil` when it can. Files and folders are transferred one by one through
    /// the existing download and upload of each service; nothing is zipped.
    private static func crossStorageBlocker(
        for clipboard: FileClipboardPayload,
        into destination: any RemoteFileService
    ) -> String? {
        guard let source = clipboard.sourceService,
              source.connection.id == clipboard.connectionID else {
            return "원본 연결 정보가 없어 다른 저장소로 붙여넣을 수 없습니다. 원본 폴더에서 다시 복사·이동을 선택해 주세요."
        }
        let hasFolder = clipboard.items.contains(where: \.isDirectory)
        guard destination.capabilities.contains(.upload),
              !hasFolder || destination.capabilities.contains(.createFolder) else {
            return "이 위치는 다른 저장소의 항목을 받을 수 없습니다."
        }
        if clipboard.mode == .move {
            guard source.capabilities.contains(.delete),
                  !hasFolder || source.capabilities.contains(.recursiveDelete) else {
                return "원본 연결이 삭제를 지원하지 않아 이동할 수 없습니다. 복사를 사용해 주세요."
            }
        }
        return nil
    }

    /// Copies, or moves, the staged roots from their own source service into
    /// `destination`. A moved root's source is deleted only after every
    /// destination file was read back with the staged SHA-256 and byte count,
    /// and only if the source still lists exactly what was transferred and
    /// its files read freshly to the same proofs. Anything less keeps the
    /// source and leaves that root staged.
    private func pasteAcrossStorage(
        _ clipboard: FileClipboardPayload,
        into directoryPath: String,
        using destination: any RemoteFileService,
        onCompletion: @escaping @MainActor () async -> Void
    ) {
        if let blocker = Self.crossStorageBlocker(for: clipboard, into: destination) {
            errorMessage = blocker
            return
        }
        guard let source = clipboard.sourceService else { return }

        start(title: "\(clipboard.items.count)개 항목 \(clipboard.mode.title) 중…") { [weak self] in
            guard let self else { return }
            let transfer = CrossStorageTransfer(
                source: source,
                destination: destination,
                mode: clipboard.mode,
                context: self.operationContext()
            )
            var completedIDs: Set<RemoteFileItem.ID> = []
            var wasCancelled = false

            for (index, item) in clipboard.items.enumerated() {
                self.operationTitle = clipboard.items.count == 1
                    ? "\(item.name) \(clipboard.mode.title) 중…"
                    : "\(index + 1)/\(clipboard.items.count) • \(item.name) \(clipboard.mode.title) 중…"
                let messageCount = transfer.messages.count
                do {
                    try Task.checkCancellation()
                    if try await transfer.transferRoot(item, into: directoryPath) {
                        completedIDs.insert(item.id)
                    } else if transfer.messages.count == messageCount {
                        transfer.messages.append("\(item.name): 완료를 확인하지 못했습니다.")
                    }
                } catch {
                    if CrossStorageTransfer.isCancellation(error) {
                        wasCancelled = true
                        break
                    }
                    transfer.messages.append("\(item.name): \(error.localizedDescription)")
                }
            }
            transfer.removeStaging()

            if clipboard.mode == .move {
                SharedFileClipboard.shared.retain(
                    clipboard.items.filter { !completedIDs.contains($0.id) },
                    ofStaging: clipboard.token
                )
            }

            if wasCancelled || Task.isCancelled {
                self.presentCancellationSummary(
                    succeededCount: completedIDs.count,
                    operationName: clipboard.mode.title,
                    failureMessages: transfer.messages
                )
                self.beginRefresh(onCompletion)
                return
            }
            await onCompletion()
            self.presentSummary(
                succeededCount: completedIDs.count,
                totalCount: clipboard.items.count,
                operationName: clipboard.mode.title,
                failureMessages: transfer.messages
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
                self.beginRefresh(onCompletion)
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
        guard activeTask == nil, activeRefreshID == nil else { return }
        activeRunID = UUID()
        isWorking = true
        operationTitle = title
        progress = nil
        errorMessage = nil
        statusMessage = nil
        ScreenAwakeController.shared.beginActivity(screenAwakeActivityID)
        let activityID = screenAwakeActivityID

        activeTask = Task { [weak self] in
            defer {
                ScreenAwakeController.shared.finishActivity(activityID)
            }
            await operation()
            guard let self else { return }
            self.activeTask = nil
            self.activeRunID = nil
            self.isWorking = false
            self.operationTitle = nil
            self.progress = nil
        }
    }

    private func beginRefresh(_ refresh: @escaping @MainActor () async -> Void) {
        guard activeRefreshID == nil else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        isRefreshing = true

        Task { @MainActor [weak self] in
            await refresh()
            guard let self, self.activeRefreshID == refreshID else { return }
            self.activeRefreshID = nil
            self.isRefreshing = false
        }
    }

    private func operationContext() -> RemoteOperationContext {
        // A late progress report of an earlier run must not overwrite the
        // progress of the operation that is running now.
        let runID = activeRunID
        return RemoteOperationContext { [weak self] progress in
            await MainActor.run {
                guard let self, self.activeRunID == runID else { return }
                self.progress = progress
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

    private func presentCancellationSummary(
        succeededCount: Int,
        operationName: String,
        failureMessages: [String]
    ) {
        let summary = "\(succeededCount)개 완료 후 \(operationName)를 취소했습니다."
        if failureMessages.isEmpty {
            statusMessage = summary
        } else {
            errorMessage = summary + "\n" + failureMessages.prefix(3).joined(separator: "\n")
        }
    }

    private static func issueMessages(
        from result: RemoteOperationResult,
        preferredName: String
    ) -> [String] {
        (result.failures + result.skipped).map { outcome in
            let message = outcome.issue?.message ?? "작업 결과를 확인할 수 없습니다."
            return preferredName.isEmpty ? message : "\(preferredName): \(message)"
        }
    }

    /// A backend can represent an ordinary cancellation as a failed outcome so
    /// the affected path is retained in its partial result. Do not turn that
    /// bookkeeping outcome into an error alert. A failed rollback, however,
    /// means cleanup really did fail and must remain visible to the user.
    private static func actionableCancellationIssueMessages(
        from result: RemoteOperationResult,
        preferredName: String
    ) -> [String] {
        guard result.rollbackState == .failed else { return [] }
        return issueMessages(from: result, preferredName: preferredName)
    }
}

/// Moves clipboard roots between two different storages with the download
/// and upload each service already has, one file at a time.
///
/// The source tree is listed completely before anything is written, so a
/// destination inside the source can never make the walk loop. A folder is
/// created under a new name when the name is taken, so nothing existing is
/// merged into or replaced. Each file upload asks for `.keepBoth`.
///
/// The URL a source download returns is only ever read: it can be the
/// user's stored original itself. Each file is streamed from it once into a
/// write-once copy in this transfer's own staging folder while its SHA-256
/// and byte count are taken, and only that copy is uploaded, so a source
/// that changes during the upload cannot change what was sent.
@MainActor
private final class CrossStorageTransfer {
    private struct Node {
        let item: RemoteFileItem
        /// Empty for a file.
        let children: [Node]
    }

    /// Exact contents of one staged file.
    private struct FileProof: Equatable, Sendable {
        let byteCount: Int64
        let sha256: Data
    }

    private struct Expectation {
        let name: String
        let destinationPath: String?
        let destinationID: RemoteFileItem.ID?
        let isDirectory: Bool
        /// The staged bytes the destination file must read back as.
        let proof: FileProof?
    }

    private static let maximumDepth = 64
    /// Bytes read at once while staging or hashing a local file.
    nonisolated private static let fileChunkByteCount = 1_048_576
    /// Bytes asked for at once when a service reads a range of a file.
    private static let rangeChunkByteCount = 4 * 1_048_576

    let source: any RemoteFileService
    let destination: any RemoteFileService
    let mode: FileClipboardMode
    let context: RemoteOperationContext
    /// User-facing problems in the order they happened.
    var messages: [String] = []
    /// Proofs of the staged bytes, by source item, for the move re-check.
    private var sourceProofs: [RemoteFileItem.ID: FileProof] = [:]
    /// Owned by this transfer alone; nothing outside it is ever removed.
    private let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("NasFinder-CrossStorage-\(UUID().uuidString)", isDirectory: true)

    init(
        source: any RemoteFileService,
        destination: any RemoteFileService,
        mode: FileClipboardMode,
        context: RemoteOperationContext
    ) {
        self.source = source
        self.destination = destination
        self.mode = mode
        self.context = context
    }

    /// Removes this transfer's staging folder once the operation settled.
    /// Source originals, download URLs and destination copies stay as they are.
    func removeStaging() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    /// `true` only when the root is completely done: its whole tree was
    /// listed back at the destination, every file read back with the staged
    /// proof, and for a move the source, still listed and read with the same
    /// proofs, was then deleted. Throws only for cancellation.
    func transferRoot(_ item: RemoteFileItem, into directoryPath: String) async throws -> Bool {
        // A root must belong to the captured source connection and have a
        // name and path that cannot leave the folder it was listed in.
        guard item.connectionID == source.connection.id,
              Self.isSafeName(item.name),
              Self.pathComponents(of: item.path) != nil else {
            messages.append("\(item.name): \(CrossStorageTransferError.unsafeName(item.name).localizedDescription)")
            return false
        }
        let root: Node
        do {
            root = try await snapshot(item, depth: 0)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            messages.append("\(item.name): 원본 목록을 읽지 못했습니다. \(error.localizedDescription)")
            return false
        }
        // Nothing is written unless the listing is the whole stored tree.
        guard try await coversStoredTree(root) else {
            messages.append("\(item.name): 원본 목록을 읽지 못했습니다.")
            return false
        }

        var verified = false
        if item.isDirectory {
            let existingNames: [String]
            do {
                existingNames = try await destination.list(directory: directoryPath).map(\.name)
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                messages.append("\(item.name): 대상 폴더를 읽지 못했습니다. \(error.localizedDescription)")
                return false
            }
            let name = Self.uniqueName(for: item.name, existingNames: existingNames)
            let copied = try await copyFolder(root, named: name, into: directoryPath)
            if copied.verified, let folder = copied.folder {
                verified = try await verify(
                    [
                        Expectation(
                            name: name,
                            destinationPath: folder.path,
                            destinationID: folder.id,
                            isDirectory: true,
                            proof: nil
                        ),
                    ],
                    in: directoryPath
                )
            }
        } else if let expectation = try await copyFileReportingFailure(item, into: directoryPath) {
            verified = try await verify([expectation], in: directoryPath)
        }

        guard verified else {
            if mode == .move {
                messages.append("\(item.name): 전송을 모두 확인하지 못해 원본을 그대로 두었습니다.")
            }
            return false
        }
        guard mode == .move else { return true }
        return try await deleteSourceIfUnchanged(root)
    }

    // MARK: Source

    private func snapshot(_ item: RemoteFileItem, depth: Int) async throws -> Node {
        try Task.checkCancellation()
        guard item.isDirectory else { return Node(item: item, children: []) }
        guard depth < Self.maximumDepth else {
            throw CrossStorageTransferError.tooDeep(item.name)
        }
        var children: [Node] = []
        for child in try await source.list(directory: item.path) {
            // Only a listed entry of the same connection exactly one level
            // below `item` is followed; anything else fails the whole root.
            guard child.connectionID == source.connection.id,
                  Self.isSafeName(child.name),
                  Self.isImmediateChild(child.path, of: item.path) else {
                throw CrossStorageTransferError.unsafeName(child.name)
            }
            children.append(try await snapshot(child, depth: depth + 1))
        }
        return Node(item: item, children: children.sorted { $0.item.id < $1.item.id })
    }

    /// Lists `root` again from its parent and, for a folder, its whole tree.
    /// `nil` when any entry was added, removed or differs from the snapshot.
    private func unchangedTree(_ root: Node) async throws -> Node? {
        try Task.checkCancellation()
        let item = root.item
        let siblings = try await source.list(directory: Self.parentPath(of: item.path))
        let matches = siblings.filter { $0.id == item.id }
        guard matches.count == 1,
              let current = matches.first,
              Self.sameMetadata(current, item) else { return nil }
        let fresh: Node
        if item.isDirectory {
            fresh = try await snapshot(current, depth: 0)
        } else {
            fresh = Node(item: current, children: [])
        }
        guard Self.sameTree(fresh, root),
              try await coversStoredTree(fresh) else { return nil }
        return fresh
    }

    /// For PhoneHard, whether `root` holds every stored item at and below
    /// its path in the manifest, with the same metadata. A listing made in
    /// ordinary mode leaves private descendants out, and the recursive
    /// delete of a move would take them along unseen, so any stored item the
    /// tree lacks fails the whole root. Only manifest metadata is read, and
    /// a manifest that cannot be read counts as not covered without passing
    /// on its error, which could name a hidden item. Throws only for
    /// cancellation. Other services list their whole tree and are not
    /// checked here.
    private func coversStoredTree(_ root: Node) async throws -> Bool {
        guard source.connection.id == LocalInboxFileService.connectionID else { return true }
        try Task.checkCancellation()
        guard let rootStored = LocalInboxFileService.storedPath(forBrowserPath: root.item.path) else {
            return false
        }
        let records: [SharedInboxRecord]
        do {
            records = try await Self.offMainActor { try SharedInbox.records() }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            return false
        }
        try Task.checkCancellation()
        let stored = records
            .filter { $0.storedFilename == rootStored || $0.storedFilename.hasPrefix(rootStored + "/") }
            .map { LocalInboxFileService.browserItem(for: $0) }
        let listed = Self.items(in: root)
        guard stored.count == listed.count else { return false }
        var listedByID: [RemoteFileItem.ID: RemoteFileItem] = [:]
        for item in listed {
            guard listedByID.updateValue(item, forKey: item.id) == nil else { return false }
        }
        for item in stored {
            guard let match = listedByID.removeValue(forKey: item.id),
                  Self.sameMetadata(match, item) else { return false }
        }
        return listedByID.isEmpty
    }

    /// Deletes the source root only if it still lists exactly what was
    /// transferred, every file in it reads freshly to its staged proof, and
    /// it still lists the same once those reads are done. A changed, added,
    /// removed or unreadable entry keeps it.
    ///
    /// This narrows but does not close the window between the last listing
    /// and `delete`: the services have no conditional delete.
    private func deleteSourceIfUnchanged(_ root: Node) async throws -> Bool {
        let item = root.item
        let keptMessage = "\(item.name): 복사는 끝났지만 원본이 전송 중에 바뀌었거나 확인되지 않아 원본을 그대로 두었습니다."
        do {
            guard let fresh = try await unchangedTree(root) else {
                messages.append(keptMessage)
                return false
            }
            for file in Self.files(in: fresh) {
                try Task.checkCancellation()
                guard let proof = sourceProofs[file.id] else {
                    messages.append(keptMessage)
                    return false
                }
                let currentProof = try await freshProof(
                    of: file,
                    from: source,
                    expectedByteCount: proof.byteCount
                )
                guard currentProof == proof else {
                    messages.append(keptMessage)
                    return false
                }
            }
            // A proof reads at most the staged byte count, so a file that
            // grew or changed while the proofs were read is only seen in its
            // listing. List the root and its whole tree again right before
            // deleting.
            guard try await unchangedTree(root) != nil else {
                messages.append(keptMessage)
                return false
            }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            messages.append("\(keptMessage) \(error.localizedDescription)")
            return false
        }

        try Task.checkCancellation()
        do {
            let result = try await source.delete(
                item,
                recursive: item.isDirectory,
                context: context
            )
            guard !result.succeeded.isEmpty,
                  result.failures.isEmpty,
                  result.skipped.isEmpty,
                  !result.wasCancelled else {
                let detail = (result.failures + result.skipped).compactMap(\.issue?.message).first
                messages.append(
                    "\(item.name): 복사는 끝났지만 원본 삭제를 마치지 못했습니다."
                        + (detail.map { " \($0)" } ?? "")
                )
                return false
            }
            return true
        } catch {
            if Self.isCancellation(error) {
                messages.append("\(item.name): 복사는 끝났지만 원본 삭제 중 취소되었습니다. 원본 일부가 남아 있을 수 있습니다.")
                throw CancellationError()
            }
            messages.append("\(item.name): 복사는 끝났지만 원본을 삭제하지 못했습니다. \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Destination

    /// Creates `name` in `parentPath` and fills it. `verified` is true only
    /// when every descendant was written and listed back.
    private func copyFolder(
        _ node: Node,
        named name: String,
        into parentPath: String
    ) async throws -> (folder: RemoteFileItem?, verified: Bool) {
        try Task.checkCancellation()
        let folder: RemoteFileItem
        do {
            folder = try await destination.createFolder(
                named: name,
                in: parentPath,
                context: context
            )
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            messages.append("\(node.item.name): 폴더를 만들지 못했습니다. \(error.localizedDescription)")
            return (nil, false)
        }

        var expectations: [Expectation] = []
        var allWritten = true
        for child in node.children {
            try Task.checkCancellation()
            if child.item.isDirectory {
                let copied = try await copyFolder(child, named: child.item.name, into: folder.path)
                allWritten = allWritten && copied.verified
                if let childFolder = copied.folder {
                    expectations.append(
                        Expectation(
                            name: child.item.name,
                            destinationPath: childFolder.path,
                            destinationID: childFolder.id,
                            isDirectory: true,
                            proof: nil
                        )
                    )
                }
            } else if let expectation = try await copyFileReportingFailure(child.item, into: folder.path) {
                expectations.append(expectation)
            } else {
                allWritten = false
            }
        }
        guard allWritten else { return (folder, false) }
        let verified = try await verify(expectations, in: folder.path)
        return (folder, verified)
    }

    private func copyFileReportingFailure(
        _ item: RemoteFileItem,
        into directoryPath: String
    ) async throws -> Expectation? {
        do {
            return try await copyFile(item, into: directoryPath)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            messages.append("\(item.name): \(error.localizedDescription)")
            return nil
        }
    }

    private func copyFile(
        _ item: RemoteFileItem,
        into directoryPath: String
    ) async throws -> Expectation {
        try Task.checkCancellation()
        let context = self.context
        let operation: RemoteOperationKind = mode == .copy ? .copy : .move
        let name = item.name
        // PhoneHard hands out its stored file itself here, so this URL is
        // only ever read and never removed or moved.
        let downloadedURL = try await source.download(item) { progress in
            await context.report(
                operation: operation,
                phase: .reading,
                unit: .bytes,
                completedUnitCount: progress.completedByteCount,
                totalUnitCount: progress.totalByteCount,
                currentPath: name
            )
        }

        try Task.checkCancellation()
        let stagedURL = try makeStagingURL(named: item.name)
        // The proof outlives the staged copy; only the proof is compared later.
        defer { removeStagedFile(at: stagedURL) }
        let proof: FileProof
        do {
            let didStartAccess = downloadedURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    downloadedURL.stopAccessingSecurityScopedResource()
                }
            }
            let values = try downloadedURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CrossStorageTransferError.unreadableLocalCopy
            }
            proof = try await Self.offMainActor {
                try Self.stage(downloadedURL, to: stagedURL)
            }
        }
        try RemoteDownloadIntegrityError.validate(
            expectedByteCount: item.size,
            actualByteCount: proof.byteCount
        )
        sourceProofs[item.id] = proof

        try Task.checkCancellation()
        let result = try await destination.upload(
            localURL: stagedURL,
            to: directoryPath,
            preferredName: item.name,
            conflictPolicy: .keepBoth,
            context: context
        )
        if result.wasCancelled { throw CancellationError() }
        guard result.failures.isEmpty,
              result.skipped.isEmpty,
              result.succeeded.count == 1,
              let outcome = result.succeeded.first,
              let resultingPath = outcome.resultingItem?.path ?? outcome.destinationPath else {
            throw CrossStorageTransferError.notConfirmed(
                (result.failures + result.skipped).compactMap(\.issue?.message).first
            )
        }
        return Expectation(
            name: item.name,
            destinationPath: resultingPath,
            destinationID: outcome.resultingItem?.id,
            isDirectory: false,
            proof: proof
        )
    }

    /// Lists `directoryPath` once and checks that every expected entry is
    /// there exactly once at the path or item the destination returned, with
    /// the right kind. A file is then read back from the destination and must
    /// have the staged SHA-256 and byte count; a listed size is only used to
    /// fail early, and a missing one does not matter when the bytes match.
    private func verify(
        _ expectations: [Expectation],
        in directoryPath: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard !expectations.isEmpty else { return true }
        let listed: [RemoteFileItem]
        do {
            listed = try await destination.list(directory: directoryPath)
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            messages.append("전송 결과 목록을 확인하지 못했습니다. \(error.localizedDescription)")
            return false
        }

        var allMatched = true
        for expectation in expectations {
            try Task.checkCancellation()
            let matches = listed.filter { candidate in
                if let id = expectation.destinationID, candidate.id == id { return true }
                guard let path = expectation.destinationPath else { return false }
                return Self.normalized(candidate.path) == Self.normalized(path)
            }
            guard matches.count == 1, let found = matches.first else {
                messages.append("\(expectation.name): 대상에서 전송 결과를 정확히 찾지 못했습니다.")
                allMatched = false
                continue
            }
            guard found.isDirectory == expectation.isDirectory else {
                messages.append("\(expectation.name): 대상 항목의 종류가 원본과 다릅니다.")
                allMatched = false
                continue
            }
            guard !expectation.isDirectory else { continue }
            guard let proof = expectation.proof else {
                messages.append("\(expectation.name): 보낸 내용을 확인할 기준이 없습니다.")
                allMatched = false
                continue
            }
            if let size = found.size, size != proof.byteCount {
                messages.append("\(expectation.name): 대상 파일 크기가 원본과 다릅니다.")
                allMatched = false
                continue
            }
            do {
                let received = try await freshProof(
                    of: found,
                    from: destination,
                    expectedByteCount: proof.byteCount
                )
                guard received == proof else {
                    messages.append("\(expectation.name): 대상 파일 내용이 보낸 내용과 다릅니다.")
                    allMatched = false
                    continue
                }
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                messages.append("\(expectation.name): 대상 파일 내용을 다시 읽어 확인하지 못했습니다. \(error.localizedDescription)")
                allMatched = false
            }
        }
        return allMatched
    }

    // MARK: Content proofs

    /// Reads `item` from `service` now and returns the SHA-256 and byte count
    /// of what it holds. A service with range reads is read in bounded
    /// ranges, so no download cache can stand in for its current bytes.
    /// Without range reads only PhoneHard is read, through its `download`,
    /// which hands out the stored file itself; that URL is only read. Any
    /// other service may hand out a cached copy, so it is not proof of the
    /// current bytes and this throws. A file longer than `expectedByteCount`
    /// gives a different byte count; when that cannot be ruled out this
    /// throws instead.
    private func freshProof(
        of item: RemoteFileItem,
        from service: any RemoteFileService,
        expectedByteCount: Int64
    ) async throws -> FileProof {
        try Task.checkCancellation()
        guard service.supportsRangeStreaming else {
            guard service is LocalInboxFileService else {
                throw CrossStorageTransferError.contentUnverifiable
            }
            let url = try await service.download(item)
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try await Self.offMainActor { try Self.hashFile(at: url) }
        }

        let operation: RemoteOperationKind = mode == .copy ? .copy : .move
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < expectedByteCount {
            try Task.checkCancellation()
            let length = Int(min(Int64(Self.rangeChunkByteCount), expectedByteCount - offset))
            let chunk = try await service.readRange(of: item, offset: offset, length: length)
            guard chunk.count <= length else {
                throw CrossStorageTransferError.contentUnverifiable
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
            await context.report(
                operation: operation,
                phase: .reading,
                unit: .bytes,
                completedUnitCount: offset,
                totalUnitCount: expectedByteCount,
                currentPath: item.name
            )
        }
        if offset == expectedByteCount, item.size != expectedByteCount {
            // Without a listed size only one more byte shows the file did not grow.
            try Task.checkCancellation()
            let extra = try await service.readRange(of: item, offset: offset, length: 1)
            if !extra.isEmpty {
                return FileProof(byteCount: offset + Int64(extra.count), sha256: Data())
            }
        }
        return FileProof(byteCount: offset, sha256: Data(hasher.finalize()))
    }

    /// A new, empty folder in this transfer's staging root for one file.
    private func makeStagingURL(named name: String) throws -> URL {
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CrossStorageTransferError.stagingFailed
        }
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    /// Removes the per-file staging folder of `stagedURL`, never anything
    /// outside this transfer's staging root.
    private func removeStagedFile(at stagedURL: URL) {
        let folder = stagedURL.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == stagingRoot.standardizedFileURL.path else {
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs blocking file work away from the main actor and passes a
    /// cancellation of the caller on to it.
    private static func offMainActor<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Streams `sourceURL` into a new file at `stagedURL`, hashing the same
    /// bytes it writes. The copy is written once here and never opened for
    /// writing again. It keeps ordinary owner permissions on purpose:
    /// PhoneHard imports an upload with `copyItem`, which would carry a
    /// read-only mode over to the user's stored file. `sourceURL` is only read.
    nonisolated private static func stage(_ sourceURL: URL, to stagedURL: URL) throws -> FileProof {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        guard !FileManager.default.fileExists(atPath: stagedURL.path),
              FileManager.default.createFile(atPath: stagedURL.path, contents: nil) else {
            throw CrossStorageTransferError.stagingFailed
        }
        let output = try FileHandle(forWritingTo: stagedURL)
        defer { try? output.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool {
                try input.read(upToCount: fileChunkByteCount) ?? Data()
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            byteCount += Int64(chunk.count)
        }
        try output.synchronize()
        try output.close()
        return FileProof(byteCount: byteCount, sha256: Data(hasher.finalize()))
    }

    /// SHA-256 and byte count of the file at `url`, read in bounded chunks.
    nonisolated private static func hashFile(at url: URL) throws -> FileProof {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CrossStorageTransferError.unreadableLocalCopy
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool {
                try input.read(upToCount: fileChunkByteCount) ?? Data()
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        return FileProof(byteCount: byteCount, sha256: Data(hasher.finalize()))
    }

    // MARK: Helpers

    static func isCancellation(_ error: Error) -> Bool {
        if let interruption = error as? RemoteOperationInterruptedError {
            return interruption.reason == .cancelled
        }
        return RemoteRequestCancellation.isCancellation(error)
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            // A separator on SMB and some FTP servers.
            && !name.contains("\\")
            && !name.contains("\0")
    }

    /// The components of `path` in the conventions of `RemotePath`, or `nil`
    /// when it has `..`, a NUL or is empty.
    private static func pathComponents(of path: String) -> [String]? {
        guard let canonical = try? RemotePath.normalize(path, within: path) else { return nil }
        return canonical.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    /// Whether `childPath` is exactly one safe component below `parentPath`
    /// in the same root style. The last component is not compared with the
    /// listed name: PhoneHard stores an item under its own file name.
    private static func isImmediateChild(_ childPath: String, of parentPath: String) -> Bool {
        guard let parent = pathComponents(of: parentPath),
              (try? RemotePath.normalize(childPath, within: parentPath)) != nil,
              let child = pathComponents(of: childPath),
              child.count == parent.count + 1,
              let last = child.last else { return false }
        return isSafeName(last)
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func parentPath(of path: String) -> String {
        let parent = (normalized(path) as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private static func uniqueName(for name: String, existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        for index in 1...9_999 {
            let candidate = "\(name) (\(index))"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return "\(name) (\(UUID().uuidString.prefix(8)))"
    }

    private static func sameMetadata(_ lhs: RemoteFileItem, _ rhs: RemoteFileItem) -> Bool {
        lhs.id == rhs.id
            && lhs.connectionID == rhs.connectionID
            && normalized(lhs.path) == normalized(rhs.path)
            && lhs.kind == rhs.kind
            && lhs.size == rhs.size
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.revisionIdentifier == rhs.revisionIdentifier
    }

    private static func sameTree(_ lhs: Node, _ rhs: Node) -> Bool {
        guard sameMetadata(lhs.item, rhs.item),
              lhs.children.count == rhs.children.count else { return false }
        return zip(lhs.children, rhs.children).allSatisfy { sameTree($0, $1) }
    }

    private static func files(in node: Node) -> [RemoteFileItem] {
        guard node.item.isDirectory else { return [node.item] }
        return node.children.flatMap { files(in: $0) }
    }

    /// `node` itself and every folder and file below it.
    private static func items(in node: Node) -> [RemoteFileItem] {
        [node.item] + node.children.flatMap { items(in: $0) }
    }
}

private enum CrossStorageTransferError: LocalizedError {
    case unsafeName(String)
    case tooDeep(String)
    case unreadableLocalCopy
    case stagingFailed
    case contentUnverifiable
    case notConfirmed(String?)

    var errorDescription: String? {
        switch self {
        case .unsafeName(let name):
            "'\(name)'은(는) 안전하게 옮길 수 없는 이름이라 전송하지 않았습니다."
        case .tooDeep(let name):
            "'\(name)' 폴더가 너무 깊어 전송하지 않았습니다."
        case .unreadableLocalCopy:
            "원본 파일을 읽지 못했습니다."
        case .stagingFailed:
            "전송용 임시 사본을 만들지 못했습니다."
        case .contentUnverifiable:
            "파일 내용을 확인할 수 없습니다."
        case .notConfirmed(let detail):
            detail ?? "업로드 결과를 확인할 수 없습니다."
        }
    }
}
