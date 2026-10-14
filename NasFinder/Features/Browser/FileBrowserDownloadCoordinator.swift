import SwiftUI
import UniformTypeIdentifiers

/// Where a download lands. The user always picks one before any transfer starts.
enum RemoteDownloadDestination {
    /// A PhoneHard folder's `storedFilename`; `nil` is the PhoneHard root.
    case phoneHard(folderPath: String?)
    /// A folder the user picked in the system picker. Security-scoped: only this
    /// folder is ever written to.
    case externalFolder(URL)
    /// Staged for the system share sheet only. Nothing is saved for the user, and
    /// nothing leaves the device until they pick a target in that sheet.
    case shareSheet

    var title: String {
        switch self {
        case .phoneHard: "폰하드"
        case .externalFolder(let url): url.lastPathComponent
        case .shareSheet: "공유"
        }
    }
}

enum RemoteDownloadDestinationStep {
    case choosing
    case phoneHardFolder
    case externalFolder
    case readOnlyFolder
}

struct RemoteDownloadSummary {
    let destinationTitle: String
    var savedFileCount = 0
    var savedFolderCount = 0
    /// Names (relative to the selection) that could not be listed, received or saved.
    var failedNames: [String] = []
    /// Entries left out on purpose: unsafe names, repeated paths and over-deep trees.
    var skippedNames: [String] = []
    var wasCancelled = false
    /// Set only for `.shareSheet`: the staged items to hand to the share sheet and the
    /// temporary directory that owns them. Left empty unless everything arrived.
    var isForSharing = false
    var sharedURLs: [URL] = []
    var shareDirectoryURL: URL?

    var isCompleteSuccess: Bool {
        !wasCancelled && failedNames.isEmpty && skippedNames.isEmpty
    }

    var message: String {
        var parts: [String] = []
        let saved = savedDescription
        if isForSharing {
            // A share never hands over part of a folder as if it were all of it.
            parts.append(
                wasCancelled
                    ? "공유 준비를 취소했습니다. 임시로 받은 항목은 지웠습니다."
                    : "일부 항목을 받지 못해 공유를 시작하지 않았습니다. 임시로 받은 항목은 지웠습니다."
            )
        } else if wasCancelled {
            parts.append(
                saved.isEmpty
                    ? "다운로드를 취소했습니다. 저장된 항목은 없습니다."
                    : "다운로드를 취소했습니다. 이미 받은 \(saved)는 \(destinationTitle)에 그대로 있습니다."
            )
        } else if saved.isEmpty {
            parts.append("\(destinationTitle)에 저장한 항목이 없습니다.")
        } else {
            parts.append("\(saved)를 \(destinationTitle)에 저장했습니다.")
        }
        if !failedNames.isEmpty {
            parts.append("받지 못한 항목 \(failedNames.count)개: \(Self.sample(failedNames))")
        }
        if !skippedNames.isEmpty {
            parts.append("건너뛴 항목 \(skippedNames.count)개: \(Self.sample(skippedNames))")
        }
        return parts.joined(separator: "\n")
    }

    private var savedDescription: String {
        var parts: [String] = []
        if savedFileCount > 0 { parts.append("파일 \(savedFileCount)개") }
        if savedFolderCount > 0 { parts.append("폴더 \(savedFolderCount)개") }
        return parts.joined(separator: ", ")
    }

    private static func sample(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) 외 \(names.count - 3)개" : shown
    }
}

/// Downloads files and whole folder trees through the existing `RemoteFileService`
/// `list`/`download` calls. Each selected item is staged in a task-owned temporary
/// directory and only then added to the destination under a unique name, so nothing the
/// user already has is overwritten or mixed into, and the remote originals are only read.
@MainActor
final class RemoteDownloadCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var currentItemName: String?
    @Published private(set) var byteProgress: RemoteDownloadProgress?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0

    private var task: Task<Void, Never>?
    private var operationID: UUID?

    /// Remote trees deeper than this are treated as a link loop and not followed.
    private static let maximumFolderDepth = 48

    func start(
        items: [RemoteFileItem],
        service: any RemoteFileService,
        destination: RemoteDownloadDestination,
        inboxStore: SharedInboxStore,
        onFinish: @escaping @MainActor (RemoteDownloadSummary) -> Void
    ) {
        let roots = Self.topLevelItems(items)
        guard !roots.isEmpty, task == nil else { return }

        let currentOperationID = UUID()
        operationID = currentOperationID
        isRunning = true
        isCancelling = false
        currentItemName = roots.first?.name
        byteProgress = nil
        completedCount = 0
        totalCount = roots.filter { !$0.isDirectory }.count

        task = Task {
            let stagingRootURL = FileManager.default.temporaryDirectory
                .appending(path: "NasFinderDownloads", directoryHint: .isDirectory)
                .appending(path: currentOperationID.uuidString, directoryHint: .isDirectory)
            var scopedURL: URL?
            if case .externalFolder(let url) = destination,
               url.startAccessingSecurityScopedResource() {
                scopedURL = url
            }
            var summary = RemoteDownloadSummary(destinationTitle: destination.title)
            // The share coordinator's own temporary root, so its stale-directory sweep
            // and its removal after the sheet closes cover these items too.
            let shareDirectoryURL = FileManager.default.temporaryDirectory
                .appending(path: "NasFinderShares", directoryHint: .isDirectory)
                .appending(path: currentOperationID.uuidString, directoryHint: .isDirectory)
            if case .shareSheet = destination { summary.isForSharing = true }

            for (index, root) in roots.enumerated() {
                if Task.isCancelled {
                    summary.wasCancelled = true
                    break
                }
                guard let name = Self.safeComponent(root.name) else {
                    summary.skippedNames.append(root.name)
                    continue
                }
                let stagedURL = stagingRootURL
                    .appending(path: String(index), directoryHint: .isDirectory)
                    .appending(
                        path: name,
                        directoryHint: root.isDirectory ? .isDirectory : .notDirectory
                    )
                var stagedFileCount = 0
                var stagedFolderCount = 0
                var isStaged = false
                let failureCountBefore = summary.failedNames.count
                do {
                    try await Self.createDirectory(at: stagedURL.deletingLastPathComponent())
                    if root.isDirectory {
                        try await Self.createDirectory(at: stagedURL)
                        isStaged = true
                        stagedFolderCount = 1
                        try await stageFolder(
                            root,
                            at: stagedURL,
                            service: service,
                            fileCount: &stagedFileCount,
                            folderCount: &stagedFolderCount,
                            summary: &summary
                        )
                    } else {
                        try await stageFile(root, at: stagedURL, service: service)
                        isStaged = true
                        stagedFileCount = 1
                        completedCount += 1
                    }
                } catch {
                    if RemoteRequestCancellation.isCancellation(error) || Task.isCancelled {
                        summary.wasCancelled = true
                    } else {
                        summary.failedNames.append(root.name)
                        if !root.isDirectory { completedCount += 1 }
                    }
                }

                // A folder interrupted by cancellation keeps the files that had already
                // fully arrived; one with nothing received is dropped with the staging.
                // A folder whose own listing failed is reported as failed rather than saved
                // as if it were an empty folder.
                let isUnreadFolder = root.isDirectory
                    && stagedFileCount == 0
                    && stagedFolderCount == 1
                    && summary.failedNames.count > failureCountBefore
                let shouldCommit = isStaged
                    && !isUnreadFolder
                    && !(summary.wasCancelled && stagedFileCount == 0)
                    && !(summary.isForSharing && summary.wasCancelled)
                if shouldCommit {
                    do {
                        switch destination {
                        case .phoneHard(let folderPath):
                            try await inboxStore.importDownloadedItem(
                                at: stagedURL,
                                originalName: name,
                                contentTypeIdentifier: root.isDirectory
                                    ? nil
                                    : root.contentTypeIdentifier,
                                intoFolder: folderPath
                            )
                        case .externalFolder(let folderURL):
                            try await Self.export(stagedURL, named: name, into: folderURL)
                        case .shareSheet:
                            let sharedURL = shareDirectoryURL
                                .appending(path: String(index), directoryHint: .isDirectory)
                                .appending(
                                    path: name,
                                    directoryHint: root.isDirectory ? .isDirectory : .notDirectory
                                )
                            try await Self.moveStagedItem(at: stagedURL, to: sharedURL)
                            summary.sharedURLs.append(sharedURL)
                        }
                        summary.savedFileCount += stagedFileCount
                        summary.savedFolderCount += stagedFolderCount
                    } catch {
                        summary.failedNames.append(
                            "\(root.name) (\(error.localizedDescription))"
                        )
                    }
                }
                if summary.wasCancelled { break }
            }

            // Only this operation's own staging copies are removed. URLs returned by
            // `download` belong to the cache or to PhoneHard itself and are never touched.
            await Self.removeStaging(at: stagingRootURL)
            scopedURL?.stopAccessingSecurityScopedResource()
            if summary.isForSharing {
                if summary.isCompleteSuccess, !summary.sharedURLs.isEmpty {
                    summary.shareDirectoryURL = shareDirectoryURL
                } else {
                    summary.sharedURLs = []
                    await Self.removeStaging(at: shareDirectoryURL)
                }
            }

            if self.operationID == currentOperationID {
                self.operationID = nil
                self.task = nil
                self.isRunning = false
                self.isCancelling = false
                self.currentItemName = nil
                self.byteProgress = nil
            }
            onFinish(summary)
        }
    }

    /// Stops receiving. Files that already fully arrived are kept; the task then removes
    /// its own temporary staging before it reports.
    func cancel() {
        guard let task, !isCancelling else { return }
        isCancelling = true
        task.cancel()
    }

    /// Walks the whole remote tree under `root`, keeping its structure and empty folders.
    /// Everything the service lists is taken, dot-prefixed names included: the browser's
    /// display filter is not applied to a folder the user asked to download whole.
    /// A failed listing or file is recorded and the rest continues; only cancellation
    /// stops the walk.
    private func stageFolder(
        _ root: RemoteFileItem,
        at rootURL: URL,
        service: any RemoteFileService,
        fileCount: inout Int,
        folderCount: inout Int,
        summary: inout RemoteDownloadSummary
    ) async throws {
        struct PendingFolder {
            let item: RemoteFileItem
            let url: URL
            let relativePath: String
            let depth: Int
        }

        var visitedPaths: Set<String> = [Self.normalizedPath(root.path)]
        var visitedIDs: Set<RemoteFileItem.ID> = [root.id]
        var pending = [
            PendingFolder(item: root, url: rootURL, relativePath: root.name, depth: 0)
        ]

        while let folder = pending.popLast() {
            try Task.checkCancellation()
            currentItemName = folder.item.name

            let children: [RemoteFileItem]
            do {
                children = try await service.list(directory: folder.item.path)
                    .sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
            } catch {
                if RemoteRequestCancellation.isCancellation(error) || Task.isCancelled {
                    throw CancellationError()
                }
                summary.failedNames.append(folder.relativePath + "/")
                continue
            }

            totalCount += children.filter { !$0.isDirectory }.count
            var usedNames: Set<String> = []
            for child in children {
                try Task.checkCancellation()
                let relativePath = folder.relativePath + "/" + child.name
                guard let safeName = Self.safeComponent(child.name) else {
                    summary.skippedNames.append(relativePath)
                    if !child.isDirectory { completedCount += 1 }
                    continue
                }
                let name = Self.uniqueName(safeName, usedNames: &usedNames)
                let childURL = folder.url.appending(
                    path: name,
                    directoryHint: child.isDirectory ? .isDirectory : .notDirectory
                )
                guard Self.isContained(childURL, in: rootURL) else {
                    summary.skippedNames.append(relativePath)
                    if !child.isDirectory { completedCount += 1 }
                    continue
                }

                if child.isDirectory {
                    // The model carries no link flag, so a link loop shows up as a
                    // repeated path or identifier, or as an implausibly deep tree.
                    guard folder.depth + 1 <= Self.maximumFolderDepth,
                          visitedPaths.insert(Self.normalizedPath(child.path)).inserted,
                          visitedIDs.insert(child.id).inserted else {
                        summary.skippedNames.append(relativePath + "/")
                        continue
                    }
                    do {
                        try await Self.createDirectory(at: childURL)
                        folderCount += 1
                        pending.append(
                            PendingFolder(
                                item: child,
                                url: childURL,
                                relativePath: relativePath,
                                depth: folder.depth + 1
                            )
                        )
                    } catch {
                        summary.failedNames.append(relativePath + "/")
                    }
                } else {
                    do {
                        try await stageFile(child, at: childURL, service: service)
                        fileCount += 1
                    } catch {
                        if RemoteRequestCancellation.isCancellation(error) || Task.isCancelled {
                            throw CancellationError()
                        }
                        summary.failedNames.append(relativePath)
                    }
                    completedCount += 1
                }
            }
        }
    }

    private func stageFile(
        _ item: RemoteFileItem,
        at stagedURL: URL,
        service: any RemoteFileService
    ) async throws {
        try Task.checkCancellation()
        let currentOperationID = operationID
        currentItemName = item.name
        byteProgress = RemoteDownloadProgress(completedByteCount: 0, totalByteCount: item.size)
        // Other thumbnail downloads must not evict this file before it is staged.
        await DownloadCache.shared.protect(item)
        do {
            let downloadedURL = try await service.download(item) { [weak self] update in
                await self?.updateProgress(update, operationID: currentOperationID)
            }
            try Task.checkCancellation()
            try await Self.copyDownloadedFile(at: downloadedURL, to: stagedURL)
        } catch {
            await DownloadCache.shared.release(item)
            throw error
        }
        await DownloadCache.shared.release(item)
    }

    private func updateProgress(_ progress: RemoteDownloadProgress, operationID: UUID?) {
        guard operationID != nil, self.operationID == operationID else { return }
        byteProgress = progress
    }

    // MARK: - Selection and names

    /// Drops repeated items and anything already covered by a selected ancestor folder,
    /// so a folder and its own child are never downloaded twice.
    nonisolated static func topLevelItems(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        var seenIDs: Set<RemoteFileItem.ID> = []
        var seenPaths: Set<String> = []
        let unique = items.filter {
            seenIDs.insert($0.id).inserted
                && seenPaths.insert(normalizedPath($0.path)).inserted
        }
        let folderPaths = unique.filter(\.isDirectory).map { normalizedPath($0.path) }
        return unique.filter { item in
            let path = normalizedPath(item.path)
            return !folderPaths.contains { folderPath in
                folderPath != path
                    && path.hasPrefix(folderPath == "/" ? "/" : folderPath + "/")
            }
        }
    }

    nonisolated static func normalizedPath(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// A single local path component for a remote name, or `nil` when the name cannot be
    /// one. Local paths are only ever built from these, never from a remote path. Only
    /// `.` and `..` themselves are refused; other dot-prefixed names are ordinary items.
    nonisolated static func safeComponent(_ name: String) -> String? {
        let cleaned = String(
            String.UnicodeScalarView(
                name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            )
        )
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned != ".",
              cleaned != "..",
              cleaned.utf8.count <= 255 else { return nil }
        return cleaned
    }

    nonisolated static func uniqueName(
        _ name: String,
        usedNames: inout Set<String>
    ) -> String {
        func key(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.lowercased()
        }
        guard usedNames.contains(key(name)) else {
            usedNames.insert(key(name))
            return name
        }
        let filenameExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var suffix = 2
        while true {
            let candidate = filenameExtension.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(filenameExtension)"
            if !usedNames.contains(key(candidate)) {
                usedNames.insert(key(candidate))
                return candidate
            }
            suffix += 1
        }
    }

    nonisolated static func isContained(_ url: URL, in rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Whether the picked folder can take new items. Checked under its security scope
    /// before anything is downloaded, so a read-only provider is reported up front.
    nonisolated static func isWritableFolder(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
        guard values?.isDirectory == true, values?.volumeIsReadOnly != true else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    // MARK: - File work

    private nonisolated static func createDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
        }.value
    }

    /// Copies, never moves or links: the downloaded URL may be the shared cache entry or
    /// the user's own stored PhoneHard file.
    private nonisolated static func copyDownloadedFile(
        at downloadedURL: URL,
        to stagedURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard downloadedURL.isFileURL,
                  fileManager.fileExists(atPath: downloadedURL.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            do {
                try fileManager.copyItem(at: downloadedURL, to: stagedURL)
            } catch {
                try? fileManager.removeItem(at: stagedURL)
                throw error
            }
        }.value
    }

    /// Hands a fully staged item over to the share directory. Both are this app's own
    /// temporary locations, so a move is enough and nothing of the user's is involved.
    private nonisolated static func moveStagedItem(
        at stagedURL: URL,
        to sharedURL: URL
    ) async throws {
        try await createDirectory(at: sharedURL.deletingLastPathComponent())
        try await Task.detached(priority: .utility) {
            try FileManager.default.moveItem(at: stagedURL, to: sharedURL)
        }.value
    }

    private nonisolated static func removeStaging(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    /// Adds the staged file or folder tree to the user-picked folder under a name nothing
    /// there uses yet. An existing item is never replaced or merged into.
    private nonisolated static func export(
        _ stagedURL: URL,
        named name: String,
        into folderURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let filenameExtension = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var lastError: Error = CocoaError(.fileWriteFileExists)

            for attempt in 1...9_999 {
                let candidate: String
                if attempt == 1 {
                    candidate = name
                } else {
                    candidate = filenameExtension.isEmpty
                        ? "\(stem) (\(attempt))"
                        : "\(stem) (\(attempt)).\(filenameExtension)"
                }
                let destinationURL = folderURL.appendingPathComponent(candidate)
                guard isContained(destinationURL, in: folderURL) else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                if fileManager.fileExists(atPath: destinationURL.path) { continue }

                var bodyError: Error?
                var coordinationError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: destinationURL,
                    options: [],
                    error: &coordinationError
                ) { coordinatedURL in
                    do {
                        try fileManager.copyItem(at: stagedURL, to: coordinatedURL)
                    } catch {
                        bodyError = error
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let bodyError else { return }
                if (bodyError as? CocoaError)?.code == .fileWriteFileExists {
                    // Another writer took the name first; its item is left untouched.
                    lastError = bodyError
                    continue
                }
                try? fileManager.removeItem(at: destinationURL)
                throw bodyError
            }
            throw lastError
        }.value
    }
}

/// The destination steps shared by every download entry point: first "폰하드" or
/// "다른 폴더", then the matching folder picker. Dismissing any step ends the flow
/// without starting a download.
struct RemoteDownloadDestinationFlow: ViewModifier {
    @Binding var step: RemoteDownloadDestinationStep?
    @ObservedObject var inboxStore: SharedInboxStore
    let itemCount: Int
    let onChoose: (RemoteDownloadDestination) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                // Kept on its own view so it never competes with the browser's upload
                // importer.
                Color.clear
                    .fileImporter(
                        isPresented: binding(for: .externalFolder),
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        handlePickedFolder(result)
                    }
                    .fileDialogConfirmationLabel("여기에 저장")
                    .fileDialogMessage("다운로드를 저장할 폴더를 선택하세요.")
            }
            .confirmationDialog(
                "저장 위치",
                isPresented: binding(for: .choosing),
                titleVisibility: .visible
            ) {
                Button("폰하드") { choosePhoneHard() }
                Button("다른 폴더") { step = .externalFolder }
                Button("취소", role: .cancel) { step = nil }
            } message: {
                Text("\(itemCount)개 항목을 저장할 위치를 먼저 선택하세요. 폴더는 하위 폴더와 파일을 모두 받습니다.")
            }
            .sheet(isPresented: binding(for: .phoneHardFolder)) {
                InboxDestinationPickerView(
                    inboxStore: inboxStore,
                    operation: nil,
                    excludedPaths: [],
                    title: "다운로드",
                    onPickDestination: { folderPath in
                        step = nil
                        onChoose(.phoneHard(folderPath: folderPath))
                    }
                )
            }
            .alert("이 폴더에는 저장할 수 없습니다", isPresented: binding(for: .readOnlyFolder)) {
                Button("폰하드에 저장") { choosePhoneHard() }
                Button("다른 폴더 선택") { step = .externalFolder }
                Button("취소", role: .cancel) { step = nil }
            } message: {
                Text("선택한 위치는 읽기 전용이거나 쓰기를 허용하지 않습니다. 폰하드나 다른 폴더를 선택하세요.")
            }
    }

    private func binding(for target: RemoteDownloadDestinationStep) -> Binding<Bool> {
        Binding(
            get: { step == target },
            set: { isPresented in
                // A later step may already have replaced this one; only a plain dismissal
                // ends the flow.
                if !isPresented, step == target { step = nil }
            }
        )
    }

    private func choosePhoneHard() {
        inboxStore.reload()
        step = .phoneHardFolder
    }

    private func handlePickedFolder(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                step = nil
                return
            }
            guard RemoteDownloadCoordinator.isWritableFolder(url) else {
                step = .readOnlyFolder
                return
            }
            step = nil
            onChoose(.externalFolder(url))
        case .failure:
            // Cancelling the system picker, or a provider that cannot hand out the
            // folder, ends here without a download.
            step = nil
        }
    }
}
