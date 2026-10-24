import Combine
import Foundation
import UniformTypeIdentifiers

private struct FilesImportResult: Sendable {
    let records: [SharedInboxRecord]
    let failedFilenames: [String]
    let saveError: String?
}

@MainActor
final class SharedInboxStore: ObservableObject {
    /// 지금 모드에서 보이는 폰하드 기록. 목록·개수·용량·선택지는 이 값을 쓴다.
    @Published private(set) var records: [SharedInboxRecord] = []
    /// 비공개를 포함한 전체 기록. 삭제·이동·정리 같은 변경 동작은 항상 전체 매니페스트가 대상이다.
    private(set) var allRecords: [SharedInboxRecord] = []
    nonisolated(unsafe) private var modeObserver: NSObjectProtocol?
    @Published var errorMessage: String?
    @Published var shouldPresentInbox = false
    @Published private(set) var pendingPreviewRecordID: UUID?
    /// Whether PhoneHard's physical Music folder exists, even while it is still empty.
    @Published private(set) var musicFolderExists = false

    init() {
        reload()
        modeObserver = NotificationCenter.default.addObserver(
            forName: PrivacyMode.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisible() }
        }
    }

    deinit {
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }

    private func refreshVisible() {
        let scope = PrivateScope(records: allRecords)
        PrivacyMode.shared.setPrivatePhoneHard(scope)
        records = PrivacyMode.currentlyActive ? allRecords : allRecords.filter { !scope.contains($0) }
    }

    /// 사용자가 직접 고른 공개/비공개 전환. 같은 레코드의 플래그만 바꾼다(id·위치·순서 불변).
    @discardableResult
    func setPrivate(_ record: SharedInboxRecord, _ isPrivate: Bool) -> Bool {
        do {
            try SharedInbox.setPrivate(record, isPrivate)
            reload()
            errorMessage = nil
            return true
        } catch {
            reload()
            errorMessage = "공개 범위를 바꾸지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    func reload() {
        musicFolderExists = SharedInbox.musicDirectoryExists()
        do {
            allRecords = try SharedInbox.records().sorted {
                if $0.importedAt == $1.importedAt {
                    return $0.originalFilename.localizedStandardCompare($1.originalFilename)
                        == .orderedAscending
                }
                return $0.importedAt > $1.importedAt
            }
            refreshVisible()
            errorMessage = nil
        } catch {
            errorMessage = "폰하드 파일 목록을 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 일반 모드에서 폴더를 지우면 지금 보이지 않는 비공개 항목까지 함께 지워진다 → 그 경우 지우지 않는다.
    private func hasHiddenDescendants(_ record: SharedInboxRecord) -> Bool {
        guard record.isDirectory, !PrivacyMode.currentlyActive else { return false }
        let scope = PrivateScope(records: allRecords)
        return allRecords.contains {
            $0.storedFilename.hasPrefix(record.storedFilename + "/") && scope.contains($0)
        }
    }

    private static let hiddenDescendantMessage = "폴더 안에 이 모드에서 보이지 않는 항목이 있어 삭제하지 않았습니다."

    func delete(_ record: SharedInboxRecord) {
        guard !hasHiddenDescendants(record) else {
            errorMessage = Self.hiddenDescendantMessage
            return
        }
        do {
            try SharedInbox.delete(record)
            reload()
            errorMessage = nil
        } catch {
            let deletionErrorMessage = "\(record.originalFilename)을(를) 삭제하지 못했습니다: \(error.localizedDescription)"
            reload()
            errorMessage = deletionErrorMessage
        }
    }

    /// Deleting a folder also removes every descendant on disk and in the manifest, so
    /// the in-memory list is always reloaded from disk afterward rather than trimmed by
    /// hand; a hand-trimmed list would otherwise keep showing a deleted folder's children.
    func delete(_ recordsToDelete: [SharedInboxRecord]) {
        guard !recordsToDelete.isEmpty else { return }

        var failedFilenames: [String] = []
        for record in recordsToDelete {
            if hasHiddenDescendants(record) {
                failedFilenames.append(record.originalFilename)
                continue
            }
            do {
                try SharedInbox.delete(record)
            } catch {
                failedFilenames.append(record.originalFilename)
            }
        }

        reload()
        errorMessage = failedFilenames.isEmpty
            ? nil
            : "일부 파일을 삭제하지 못했습니다: \(failedFilenames.joined(separator: ", "))"
    }

    /// Children directly inside `path` (`nil` is the PhoneHard root). Never includes
    /// grandchildren, so folder navigation only ever shows one level at a time.
    func children(of path: String?) -> [SharedInboxRecord] {
        records.filter { Self.parentPath(of: $0.storedFilename) == path }
    }

    static func parentPath(of storedFilename: String) -> String? {
        let parent = (storedFilename as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// Count of every real file and folder physically on disk under `storedFilename`
    /// (the folder itself is not included), hidden ones included, since those are exactly
    /// what a recursive delete removes. Reads disk metadata directly rather than the
    /// manifest, which is reconciled with `.skipsHiddenFiles` and would otherwise miss
    /// hidden files or anything just dropped in by another process (e.g. a WebHard
    /// upload) before the next reload. Callers should `reload()` immediately before
    /// reading it so the folder itself is known to still exist.
    func descendantCount(of storedFilename: String) -> Int {
        (try? SharedInbox.descendantCount(of: storedFilename)) ?? 0
    }

    @discardableResult
    func createFolder(named name: String, in parentPath: String?, isPrivate: Bool? = nil) async -> Bool {
        let flag = isPrivate == true ? true : PrivacyMode.shared.newRecordFlag
        do {
            try await Task.detached(priority: .userInitiated) {
                try SharedInbox.createFolder(named: name, in: parentPath, isPrivate: flag)
            }.value
            reload()
            errorMessage = nil
            return true
        } catch {
            reload()
            errorMessage = "폴더를 만들지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    /// Moves every selected record into `destinationPath`, keeping each `id`. Stops
    /// counting a record as failed only once its own move actually threw; every attempted
    /// record (success or failure) is reflected accurately in `errorMessage`.
    func move(_ recordsToMove: [SharedInboxRecord], toFolder destinationPath: String?) async {
        guard !recordsToMove.isEmpty else { return }
        var failedNames: [String] = []
        for record in recordsToMove {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SharedInbox.moveItem(record, toFolder: destinationPath)
                }.value
            } catch {
                failedNames.append(record.originalFilename)
            }
        }
        reload()
        errorMessage = failedNames.isEmpty
            ? nil
            : "일부 항목을 이동하지 못했습니다: \(failedNames.joined(separator: ", "))"
    }

    /// Copies every selected record into `destinationPath`. Every copy (including the
    /// whole subtree of a copied folder) gets brand-new ids; originals are never touched.
    func copy(_ recordsToCopy: [SharedInboxRecord], toFolder destinationPath: String?) async {
        guard !recordsToCopy.isEmpty else { return }
        var failedNames: [String] = []
        for record in recordsToCopy {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SharedInbox.copyItem(record, toFolder: destinationPath)
                }.value
            } catch {
                failedNames.append(record.originalFilename)
            }
        }
        reload()
        errorMessage = failedNames.isEmpty
            ? nil
            : "일부 항목을 복사하지 못했습니다: \(failedNames.joined(separator: ", "))"
    }

    func sceneDidBecomeActive() {
        reload()
    }

    func handleOpenURL(_ url: URL) async {
        if Self.isInboxURL(url) {
            reload()
            pendingPreviewRecordID = Self.recordID(from: url)
            shouldPresentInbox = true
            return
        }

        guard url.isFileURL else { return }
        let flag = PrivacyMode.shared.newRecordFlag
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [.contentTypeKey])
                let record = try SharedInbox.importTemporaryFile(
                    at: url,
                    originalFilename: url.lastPathComponent,
                    contentTypeIdentifier: values.contentType?.identifier,
                    isPrivate: flag
                )
                // importTemporaryFile가 숨김 스테이징 → 이름 확정 → 매니페스트 기록(비공개 표시 포함)을 한 번에 끝낸다.
                return record
            }.value
            reload()
            pendingPreviewRecordID = record.id
            shouldPresentInbox = true
        } catch {
            errorMessage = "파일을 NasFinder로 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func importFromFiles(_ urls: [URL]) async -> Int {
        guard !urls.isEmpty else { return 0 }
        let flag = PrivacyMode.shared.newRecordFlag

        let result = await Task.detached(priority: .userInitiated) {
            var importedRecords: [SharedInboxRecord] = []
            var failedFilenames: [String] = []

            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }

                do {
                    let values = try url.resourceValues(forKeys: [.contentTypeKey])
                    let record = try SharedInbox.importTemporaryFile(
                        at: url,
                        originalFilename: url.lastPathComponent,
                        contentTypeIdentifier: values.contentType?.identifier,
                        isPrivate: flag
                    )
                    importedRecords.append(record)
                } catch {
                    failedFilenames.append(url.lastPathComponent)
                }
            }

            // 파일마다 가져오기와 기록이 한 번에 끝나므로(실패한 파일은 failedFilenames) 따로 묶어서 기록하지 않는다.
            return FilesImportResult(
                records: importedRecords,
                failedFilenames: failedFilenames,
                saveError: nil
            )
        }.value

        reload()

        if let saveError = result.saveError {
            errorMessage = "선택한 파일을 보관하지 못했습니다: \(saveError)"
        } else if !result.failedFilenames.isEmpty {
            let failedCount = result.failedFilenames.count
            errorMessage = "\(failedCount)개 파일을 가져오지 못했습니다."
        } else {
            errorMessage = nil
        }

        return result.records.count
    }

    /// `nil`은 "지정 안 함"이라 호출 시점의 모드를 따르고, 명시한 `false`는 실제로 고정된 공개 출처라 모드를 다시 읽지 않는다.
    /// 비동기 작업은 시작할 때 고정한 값을 항상 명시해서 넘긴다.
    private static func resolvedFlag(_ isPrivate: Bool?) -> Bool? {
        guard let isPrivate else { return PrivacyMode.shared.newRecordFlag }
        return isPrivate ? true : nil
    }

    @discardableResult
    func importDownloadedFile(
        at url: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        isPrivate: Bool? = nil
    ) async throws -> SharedInboxRecord {
        // 작업 시작 시점의 출처를 한 번 잡는다. 이후 모드가 바뀌어도 이 파일의 공개 범위는 바뀌지 않는다.
        let flag = Self.resolvedFlag(isPrivate)
        let record = try await Task.detached(priority: .userInitiated) {
            let record = try SharedInbox.importTemporaryFile(
                at: url,
                originalFilename: originalFilename,
                contentTypeIdentifier: contentTypeIdentifier,
                isPrivate: flag
            )
            return record
        }.value
        reload()
        return record
    }

    /// Adds a staged download, a single file or a whole folder tree, to `folderPath`
    /// (`nil` is the PhoneHard root) under a name nothing there uses yet; existing items
    /// are never replaced or merged into. The staged item is copied, so the caller keeps
    /// ownership of its temporary copy. It is written to the chosen folder from the
    /// start, never to the root first, so a download into a subfolder cannot collide with
    /// a root name or be left behind there by a failed move. A folder is committed as a
    /// folder record; the files and folders inside it are adopted from disk by the reload
    /// that follows, so the manifest, the list and the physical tree agree.
    @discardableResult
    func importDownloadedItem(
        at url: URL,
        originalName: String,
        contentTypeIdentifier: String?,
        intoFolder folderPath: String?,
        isPrivate: Bool? = nil
    ) async throws -> SharedInboxRecord {
        defer { reload() }
        let flag = Self.resolvedFlag(isPrivate)
        return try await Task.detached(priority: .userInitiated) {
            // `manifest.json` is reserved at the PhoneHard root only and would drop out
            // of the list there; inside a folder it is an ordinary name.
            let preferredName = folderPath == nil
                && originalName.caseInsensitiveCompare("manifest.json") == .orderedSame
                ? "manifest (다운로드).json"
                : originalName
            return try SharedInbox.importTemporaryItem(
                at: url,
                originalFilename: preferredName,
                contentTypeIdentifier: contentTypeIdentifier,
                intoFolder: folderPath,
                isPrivate: flag
            )
        }.value
    }

    /// Stores a downloaded music file in PhoneHard's Music folder and commits it to the
    /// normal manifest. Existing audio records stay where they are.
    @discardableResult
    func importMusicFile(
        at url: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        isPrivate: Bool? = nil
    ) async throws -> SharedInboxRecord {
        let flag = Self.resolvedFlag(isPrivate)
        let record = try await Task.detached(priority: .userInitiated) {
            let record = try SharedInbox.importTemporaryMusicFile(
                at: url,
                originalFilename: originalFilename,
                contentTypeIdentifier: contentTypeIdentifier,
                isPrivate: flag
            )
            return record
        }.value
        reload()
        return record
    }

    func consumePendingPreviewRecordID() -> UUID? {
        defer { pendingPreviewRecordID = nil }
        return pendingPreviewRecordID
    }

    /// Clears only navigation requested for the current presentation. Stored
    /// PhoneHard files and errors remain untouched.
    func resetTransientPresentation() {
        shouldPresentInbox = false
        pendingPreviewRecordID = nil
    }

    private static func isInboxURL(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("nasfinder") == .orderedSame else {
            return false
        }

        if url.host?.caseInsensitiveCompare("inbox") == .orderedSame {
            return true
        }

        return url.pathComponents.contains {
            $0.caseInsensitiveCompare("inbox") == .orderedSame
        }
    }

    private static func recordID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawID = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}
